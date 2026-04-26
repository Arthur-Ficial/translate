@preconcurrency import Foundation
@preconcurrency import Hummingbird

/// Translate HTTP server — drop-in replacement for DeepL `/v2/*`,
/// LibreTranslate `/translate /detect /languages`, and Google
/// `/language/translate/v2/*`. Uses Apple's on-device translation. No
/// network egress for inference.
@available(macOS 26.0, *)
public final class TranslateServer: @unchecked Sendable {
    public let translator: any Translating
    public let detector: LanguageDetector
    public let host: String
    public let port: Int
    public let apiKey: String?

    private var serviceTask: Task<Void, any Error>?
    private let stopHandle = StopHandle()

    public init(
        translator: any Translating,
        detector: LanguageDetector,
        host: String = "127.0.0.1",
        port: Int = 8989,
        apiKey: String? = nil
    ) {
        self.translator = translator
        self.detector = detector
        self.host = host
        self.port = port
        self.apiKey = apiKey
    }

    public func run() async throws {
        let router = Router()

        // CORS preflight for any browser client. Match on .options method only.
        router.on("/", method: .options) { _, _ in
            TranslateServer.corsPreflight()
        }
        router.on("/{path*}", method: .options) { _, _ in
            TranslateServer.corsPreflight()
        }

        router.get("/health") { _, _ in
            TranslateServer.jsonResponse(
                "{\"ok\":true,\"service\":\"translate\"}"
            )
        }
        router.get("/healthz") { _, _ in
            TranslateServer.jsonResponse("{\"ok\":true}")
        }

        // DeepL surface
        router.post("/v2/translate") { [translator, detector] request, context in
            try await TranslateServer.handleDeepL(
                request: request,
                context: context,
                translator: translator,
                detector: detector
            )
        }
        router.get("/v2/languages") { _, _ in
            TranslateServer.languagesJSON(scheme: .deepL)
        }
        router.get("/v2/usage") { _, _ in
            TranslateServer.jsonResponse(
                "{\"character_count\":0,\"character_limit\":1000000000}"
            )
        }

        // LibreTranslate surface
        router.post("/translate") { [translator, detector] request, context in
            try await TranslateServer.handleLibre(
                request: request,
                context: context,
                translator: translator,
                detector: detector
            )
        }
        router.post("/detect") { [detector] request, context in
            try await TranslateServer.handleLibreDetect(
                request: request,
                context: context,
                detector: detector
            )
        }
        router.get("/languages") { _, _ in
            TranslateServer.languagesJSON(scheme: .libre)
        }
        router.get("/spec") { _, _ in
            TranslateServer.jsonResponse(
                "{\"openapi\":\"3.0.0\",\"info\":{\"title\":\"translate\",\"version\":\"0.1.1\"},\"paths\":{\"/translate\":{},\"/detect\":{},\"/languages\":{}}}"
            )
        }
        router.get("/frontend/settings") { _, _ in
            TranslateServer.jsonResponse(
                "{\"apiKeys\":false,\"charLimit\":-1,\"frontendTimeout\":500,\"keyRequired\":false,\"language\":{\"source\":{\"code\":\"auto\",\"name\":\"Auto Detect\"},\"target\":{\"code\":\"en\",\"name\":\"English\"}},\"suggestions\":false,\"supportedFilesFormat\":[]}"
            )
        }

        // Google v2 surface
        router.post("/language/translate/v2") { [translator, detector] request, context in
            try await TranslateServer.handleGoogle(
                request: request,
                context: context,
                translator: translator,
                detector: detector
            )
        }
        router.get("/language/translate/v2/languages") { _, _ in
            TranslateServer.languagesJSON(scheme: .google)
        }

        let app = Application(
            router: router,
            configuration: .init(address: .hostname(host, port: port))
        )

        let task = Task { try await app.runService() }
        serviceTask = task

        try await stopHandle.wait()
        task.cancel()
        _ = try? await task.value
    }

    public func stop() async {
        await stopHandle.signal()
    }

    // MARK: - Handlers

    private static func handleDeepL(
        request: Request,
        context: some RequestContext,
        translator: any Translating,
        detector: LanguageDetector
    ) async throws -> Response {
        let parsed: DeepLRequest
        do {
            parsed = try await readDeepLBody(request: request)
        } catch let error as TranslateError {
            return deepLErrorResponse(.badRequest, message: error.description)
        } catch {
            return deepLErrorResponse(.badRequest, message: error.localizedDescription)
        }

        guard let target = DeepLRequest.normalizeLang(parsed.targetLang) else {
            return deepLErrorResponse(.badRequest, message: "invalid target_lang")
        }

        let sourceCodeOpt = parsed.sourceLang.flatMap(DeepLRequest.normalizeLang)
        let detection: DetectionResult
        if let sourceCode = sourceCodeOpt {
            detection = DetectionResult(
                languageCode: Locale.Language(identifier: sourceCode).minimalIdentifier,
                confidence: 1.0
            )
        } else {
            let joined = parsed.texts.joined(separator: "\n")
            do {
                detection = try detector.detect(in: joined)
            } catch {
                return deepLErrorResponse(.badRequest, message: "could not detect source language")
            }
        }

        let sourceLang = Locale.Language(identifier: detection.languageCode)
        let targetLang = Locale.Language(identifier: target)

        do {
            try await translator.prepare(source: sourceLang, target: targetLang, noInstall: false, quiet: true)
        } catch let error as TranslateError {
            return deepLErrorResponse(.badRequest, message: error.description)
        } catch {
            return deepLErrorResponse(.badRequest, message: error.localizedDescription)
        }

        let translated: [String]
        do {
            translated = try await translator.translate(
                units: parsed.texts,
                source: sourceLang,
                target: targetLang,
                preserveNewlines: true
            )
        } catch {
            return deepLErrorResponse(.badRequest, message: error.localizedDescription)
        }

        let detectedUpper = detection.languageCode.uppercased()
        let response = DeepLResponse(translations: zip(parsed.texts, translated).map { src, dst in
            DeepLTranslation(
                detectedSourceLanguage: detectedUpper,
                text: dst,
                billedCharacters: src.count
            )
        })

        return jsonResponse(response.toJSON())
    }

    private static func handleLibre(
        request: Request,
        context: some RequestContext,
        translator: any Translating,
        detector: LanguageDetector
    ) async throws -> Response {
        let parsed: LibreTranslateRequest
        do {
            parsed = try await readLibreBody(request: request)
        } catch {
            return errorResponse(.badRequest, message: error.localizedDescription)
        }

        let target = Locale.Language(identifier: parsed.target)

        let detection: DetectionResult
        if parsed.source != "auto", !parsed.source.isEmpty {
            detection = DetectionResult(
                languageCode: Locale.Language(identifier: parsed.source).minimalIdentifier,
                confidence: 1.0
            )
        } else {
            let joined = parsed.q.joined(separator: "\n")
            do {
                detection = try detector.detect(in: joined)
            } catch {
                return errorResponse(.badRequest, message: "could not detect source language")
            }
        }

        let source = Locale.Language(identifier: detection.languageCode)

        do {
            try await translator.prepare(source: source, target: target, noInstall: false, quiet: true)
        } catch let error as TranslateError {
            return errorResponse(.badRequest, message: error.description)
        } catch {
            return errorResponse(.badRequest, message: error.localizedDescription)
        }

        let translated: [String]
        do {
            translated = try await translator.translate(
                units: parsed.q,
                source: source,
                target: target,
                preserveNewlines: true
            )
        } catch {
            return errorResponse(.badRequest, message: error.localizedDescription)
        }

        let detectedField: LibreDetectedLanguage? = (parsed.source == "auto")
            ? .init(language: detection.languageCode, confidence: Int((detection.confidence * 100).rounded()))
            : nil

        let payload: LibreTranslateResponse
        if parsed.qWasArray {
            payload = .array(translatedTexts: translated, detectedLanguage: detectedField)
        } else {
            payload = .single(translatedText: translated.first ?? "", detectedLanguage: detectedField)
        }

        return jsonResponse(payload.toJSON())
    }

    private static func handleLibreDetect(
        request: Request,
        context: some RequestContext,
        detector: LanguageDetector
    ) async throws -> Response {
        let bodyData = try await readBodyData(request: request)
        let bodyString = String(data: bodyData, encoding: .utf8) ?? ""

        let q: String
        if let object = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
           let value = object["q"] as? String {
            q = value
        } else {
            let pairs = FormDecoder.parse(bodyString)
            q = pairs.first(for: "q") ?? ""
        }

        guard !q.isEmpty else {
            return errorResponse(.badRequest, message: "missing q")
        }

        let result: DetectionResult
        do {
            result = try detector.detect(in: q)
        } catch {
            return errorResponse(.badRequest, message: "could not detect source language")
        }

        let response = LibreDetectResponse(items: [
            .init(language: result.languageCode, confidence: Int((result.confidence * 100).rounded()))
        ])
        return jsonResponse(response.toJSON())
    }

    private static func handleGoogle(
        request: Request,
        context: some RequestContext,
        translator: any Translating,
        detector: LanguageDetector
    ) async throws -> Response {
        let parsed: GoogleRequest
        do {
            parsed = try await readGoogleBody(request: request)
        } catch let error as TranslateError {
            return googleErrorResponse(.badRequest, message: error.description, reason: "required")
        } catch {
            return googleErrorResponse(.badRequest, message: error.localizedDescription, reason: "required")
        }

        let target = Locale.Language(identifier: parsed.target)

        let detection: DetectionResult
        if let sourceCode = parsed.source, !sourceCode.isEmpty {
            detection = DetectionResult(
                languageCode: Locale.Language(identifier: sourceCode).minimalIdentifier,
                confidence: 1.0
            )
        } else {
            let joined = parsed.qs.joined(separator: "\n")
            do {
                detection = try detector.detect(in: joined)
            } catch {
                return googleErrorResponse(.badRequest, message: "could not detect source language")
            }
        }

        let source = Locale.Language(identifier: detection.languageCode)

        do {
            try await translator.prepare(source: source, target: target, noInstall: false, quiet: true)
        } catch let error as TranslateError {
            return googleErrorResponse(.badRequest, message: error.description)
        } catch {
            return googleErrorResponse(.badRequest, message: error.localizedDescription)
        }

        let translated: [String]
        do {
            translated = try await translator.translate(
                units: parsed.qs,
                source: source,
                target: target,
                preserveNewlines: true
            )
        } catch {
            return googleErrorResponse(.badRequest, message: error.localizedDescription)
        }

        let translations = translated.map { text in
            GoogleTranslation(translatedText: text, detectedSourceLanguage: detection.languageCode)
        }
        let payload = GoogleResponse(translations: translations)

        return jsonResponse(payload.toJSON())
    }

    // MARK: - Body readers

    private static func readBodyData(request: Request) async throws -> Data {
        var data = Data()
        for try await chunk in request.body {
            chunk.withUnsafeReadableBytes { buffer in
                data.append(contentsOf: buffer)
            }
        }
        return data
    }

    private static func readDeepLBody(request: Request) async throws -> DeepLRequest {
        let data = try await readBodyData(request: request)
        let contentType = request.headers[.contentType] ?? ""

        if contentType.contains("application/json") {
            return try DeepLRequest.fromJSON(data)
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        return try DeepLRequest.fromForm(body)
    }

    private static func readLibreBody(request: Request) async throws -> LibreTranslateRequest {
        let data = try await readBodyData(request: request)
        let contentType = request.headers[.contentType] ?? ""

        if contentType.contains("application/x-www-form-urlencoded") {
            let body = String(data: data, encoding: .utf8) ?? ""
            return try LibreTranslateRequest.fromForm(body)
        }
        // Default LibreTranslate is JSON
        return try LibreTranslateRequest.fromJSON(data)
    }

    private static func readGoogleBody(request: Request) async throws -> GoogleRequest {
        let data = try await readBodyData(request: request)
        let contentType = request.headers[.contentType] ?? ""

        if contentType.contains("application/json") {
            return try GoogleRequest.fromJSON(data)
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        return try GoogleRequest.fromForm(body)
    }

    // MARK: - Languages catalog

    public enum LanguagesScheme: Sendable {
        case deepL, libre, google
    }

    public static func languagesJSON(scheme: LanguagesScheme) -> Response {
        let codes: [(String, String)] = [
            ("ar", "Arabic"), ("bg", "Bulgarian"), ("cs", "Czech"), ("da", "Danish"),
            ("de", "German"), ("el", "Greek"), ("en", "English"), ("es", "Spanish"),
            ("et", "Estonian"), ("fi", "Finnish"), ("fr", "French"), ("hi", "Hindi"),
            ("hu", "Hungarian"), ("id", "Indonesian"), ("it", "Italian"), ("ja", "Japanese"),
            ("ko", "Korean"), ("lt", "Lithuanian"), ("lv", "Latvian"), ("nb", "Norwegian"),
            ("nl", "Dutch"), ("pl", "Polish"), ("pt", "Portuguese"), ("ro", "Romanian"),
            ("ru", "Russian"), ("sk", "Slovak"), ("sl", "Slovenian"), ("sv", "Swedish"),
            ("th", "Thai"), ("tr", "Turkish"), ("uk", "Ukrainian"), ("vi", "Vietnamese"),
            ("zh", "Chinese")
        ]

        let json: String
        switch scheme {
        case .deepL:
            let body = codes.map { code, name in
                "{\"language\":\(StableJSON.string(code.uppercased())),\"name\":\(StableJSON.string(name))}"
            }.joined(separator: ",")
            json = "[\(body)]"

        case .libre:
            let body = codes.map { code, name in
                let targets = codes.map { $0.0 }.filter { $0 != code }
                let targetsJSON = targets.map(StableJSON.string).joined(separator: ",")
                return "{\"code\":\(StableJSON.string(code)),\"name\":\(StableJSON.string(name)),\"targets\":[\(targetsJSON)]}"
            }.joined(separator: ",")
            json = "[\(body)]"

        case .google:
            let body = codes.map { code, name in
                "{\"language\":\(StableJSON.string(code)),\"name\":\(StableJSON.string(name))}"
            }.joined(separator: ",")
            json = "{\"data\":{\"languages\":[\(body)]}}"
        }

        return jsonResponse(json)
    }

    /// LibreTranslate error shape: `{"error":"message"}`.
    private static func errorResponse(_ status: HTTPResponse.Status, message: String) -> Response {
        let body = "{\"error\":\(StableJSON.string(message))}"
        return jsonResponse(body, status: status)
    }

    /// DeepL error shape: `{"message":"..."}`.
    private static func deepLErrorResponse(_ status: HTTPResponse.Status, message: String) -> Response {
        let body = "{\"message\":\(StableJSON.string(message))}"
        return jsonResponse(body, status: status)
    }

    /// Google v2 error envelope: `{"error":{"code":N,"message":"...","errors":[{"message":"...","domain":"global","reason":"..."}]}}`.
    private static func googleErrorResponse(_ status: HTTPResponse.Status, message: String, reason: String = "invalid") -> Response {
        let inner = "{\"message\":\(StableJSON.string(message)),\"domain\":\"global\",\"reason\":\(StableJSON.string(reason))}"
        let body = "{\"error\":{\"code\":\(status.code),\"message\":\(StableJSON.string(message)),\"errors\":[\(inner)]}}"
        return jsonResponse(body, status: status)
    }

    private static func jsonResponse(_ body: String, status: HTTPResponse.Status = .ok) -> Response {
        Response(
            status: status,
            headers: [
                .contentType: "application/json",
                .accessControlAllowOrigin: "*",
                .accessControlAllowHeaders: "Authorization, Content-Type, X-goog-api-key, DeepL-Auth-Key",
                .accessControlAllowMethods: "GET, POST, OPTIONS",
                .accessControlExposeHeaders: "Content-Type"
            ],
            body: .init(byteBuffer: .init(string: body))
        )
    }

    private static func corsPreflight() -> Response {
        Response(
            status: .noContent,
            headers: [
                .accessControlAllowOrigin: "*",
                .accessControlAllowHeaders: "Authorization, Content-Type, X-goog-api-key, DeepL-Auth-Key",
                .accessControlAllowMethods: "GET, POST, OPTIONS",
                .accessControlMaxAge: "86400"
            ]
        )
    }
}

// MARK: - Stop coordination

private actor StopHandle {
    private var continuation: CheckedContinuation<Void, Never>?
    private var alreadyStopped = false

    func wait() async throws {
        if alreadyStopped { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func signal() {
        guard !alreadyStopped else { return }
        alreadyStopped = true
        continuation?.resume()
        continuation = nil
    }
}
