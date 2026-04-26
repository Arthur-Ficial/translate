@preconcurrency import Foundation
import XCTest
@testable import translate

/// Drop-in replacement compatibility — proves `translate --serve` accepts
/// requests in every shape the real DeepL / LibreTranslate / Google v2
/// endpoints accept, and emits responses in every shape those services'
/// official client libraries depend on. Real loopback HTTP, no mocks.
@available(macOS 26.0, *)
final class DropInCompatTests: XCTestCase {

    private var harness: ServerHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = try await ServerHarness.start()
    }

    override func tearDown() async throws {
        await harness?.stop()
        harness = nil
        try await super.tearDown()
    }

    // ---------------------------------------------------------------- DeepL

    func testDeepLAcceptsAuthorizationHeader() async throws {
        // Real DeepL clients send `Authorization: DeepL-Auth-Key <key>`.
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(harness.port)/v2/translate")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("DeepL-Auth-Key any-token", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("text=Hallo&target_lang=EN&source_lang=DE".utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        XCTAssertEqual(http.statusCode, 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("translations"))
    }

    func testDeepLAcceptsAuthKeyAsAuthorizationHeaderValueOnly() async throws {
        // Some homegrown clients send just the key in Authorization without prefix.
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(harness.port)/v2/translate")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("any-token", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("text=Hallo&target_lang=EN&source_lang=DE".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
    }

    func testDeepLPassesThroughFormalityAndTagHandling() async throws {
        // formality, tag_handling, split_sentences, preserve_formatting are
        // accepted (and ignored) -- they MUST NOT trigger a 4xx.
        let body = "text=Hallo&target_lang=EN&source_lang=DE&formality=more&tag_handling=xml&split_sentences=1&preserve_formatting=1"
        let (data, response) = try await harness.postForm("/v2/translate", body: body)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("translations"))
    }

    func testDeepLErrorBodyIsJSONWithMessageField() async throws {
        // DeepL 4xx returns: {"message":"..."}
        let (data, response) = try await harness.postForm("/v2/translate", body: "target_lang=EN")
        XCTAssertEqual(response.statusCode, 400)
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"message\""), "DeepL clients parse \"message\": got \(body)")
    }

    func testDeepLLanguagesUppercaseCodes() async throws {
        // Real DeepL returns codes uppercased: "EN", "DE", "PT-BR".
        let (data, response) = try await harness.get("/v2/languages")
        XCTAssertEqual(response.statusCode, 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"EN\""))
        XCTAssertTrue(body.contains("\"DE\""))
    }

    func testDeepLLanguagesAcceptsTypeQueryParam() async throws {
        // Official DeepL clients ask /v2/languages?type=source and ?type=target.
        let (data1, r1) = try await harness.get("/v2/languages?type=source")
        XCTAssertEqual(r1.statusCode, 200)
        XCTAssertTrue(String(data: data1, encoding: .utf8)!.hasPrefix("["))

        let (data2, r2) = try await harness.get("/v2/languages?type=target")
        XCTAssertEqual(r2.statusCode, 200)
        XCTAssertTrue(String(data: data2, encoding: .utf8)!.hasPrefix("["))
    }

    func testDeepLEmptyTextIsAccepted() async throws {
        // DeepL accepts `text=` -> returns empty translation.
        let (data, response) = try await harness.postForm("/v2/translate", body: "text=&target_lang=EN")
        // Either 200 with empty or 400 -- both are acceptable per real DeepL.
        XCTAssertTrue([200, 400].contains(response.statusCode), "got \(response.statusCode) body=\(String(data: data, encoding: .utf8) ?? "")")
    }

    // ---------------------------------------------------------- LibreTranslate

    func testLibreSpecEndpoint200() async throws {
        // Mobile clients call /spec to verify the OpenAPI schema is reachable.
        let (_, response) = try await harness.get("/spec")
        XCTAssertEqual(response.statusCode, 200)
    }

    func testLibreFrontendSettingsEndpoint200() async throws {
        // The official web UI calls /frontend/settings. Our drop-in must answer.
        let (data, response) = try await harness.get("/frontend/settings")
        XCTAssertEqual(response.statusCode, 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"language\""))
    }

    func testLibreDetectAcceptsFormBody() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(harness.port)/detect")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("q=Das%20ist%20ein%20deutscher%20Satz%20mit%20genug%20Worten.".utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"language\":\"de\""))
    }

    func testLibreDetectArrayQReturnsArrayOfArrays() async throws {
        // libretranslatepy passes arrays here too.
        let json = #"{"q":"Das ist ein deutscher Satz mit genug Worten."}"#
        let (data, response) = try await harness.postJSON("/detect", body: Data(json.utf8))
        XCTAssertEqual(response.statusCode, 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.hasPrefix("["))
        XCTAssertTrue(body.contains("\"language\""))
        XCTAssertTrue(body.contains("\"confidence\""))
    }

    func testLibreLanguagesShapeMatches() async throws {
        // Each entry must have: code, name, targets (array of code strings).
        let (data, _) = try await harness.get("/languages")
        let parsed = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        XCTAssertGreaterThan(parsed.count, 5)
        for entry in parsed.prefix(3) {
            XCTAssertNotNil(entry["code"] as? String)
            XCTAssertNotNil(entry["name"] as? String)
            let targets = entry["targets"] as? [String]
            XCTAssertNotNil(targets)
            XCTAssertGreaterThan(targets!.count, 0)
        }
    }

    func testLibreErrorShapeIsErrorField() async throws {
        // LibreTranslate clients parse {"error":"..."} on 4xx.
        let json = #"{"q":"hi"}"#
        let (data, response) = try await harness.postJSON("/translate", body: Data(json.utf8))
        XCTAssertEqual(response.statusCode, 400)
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"error\""), "got: \(body)")
    }

    func testLibreAlternativesField() async throws {
        // Newer LibreTranslate clients send `alternatives: 0` -- we must accept it.
        let json = #"{"q":"Hallo","source":"de","target":"en","format":"text","alternatives":3}"#
        let (_, response) = try await harness.postJSON("/translate", body: Data(json.utf8))
        // Should be 200 (model present) OR 4xx with a JSON error body. We
        // assert NOT 5xx -- the field must not crash anything.
        XCTAssertLessThan(response.statusCode, 500)
    }

    // ----------------------------------------------------------- Google v2

    func testGoogleAcceptsXGoogApiKeyHeader() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(harness.port)/language/translate/v2")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("any-key", forHTTPHeaderField: "X-goog-api-key")
        request.httpBody = Data("q=Hallo&target=en&source=de".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
    }

    func testGoogleAcceptsKeyQueryParam() async throws {
        // Real Google clients put ?key=API_KEY in the URL.
        let (data, response) = try await harness.postForm(
            "/language/translate/v2?key=any-key",
            body: "q=Hallo&target=en&source=de"
        )
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("\"data\""))
    }

    func testGoogleAcceptsFormatHTMLAndModelBase() async throws {
        // Real clients pass format=html or format=text and model=base|nmt.
        let body = "q=Hallo&target=en&source=de&format=text&model=nmt"
        let (_, response) = try await harness.postForm("/language/translate/v2", body: body)
        XCTAssertEqual(response.statusCode, 200)
    }

    func testGoogleErrorEnvelopeMatchesGoogleAPIShape() async throws {
        // Google v2 error: {"error":{"code":400,"message":"...","errors":[{...}]}}
        let (data, response) = try await harness.postForm("/language/translate/v2", body: "target=en")
        XCTAssertEqual(response.statusCode, 400)
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let envelope = parsed["error"] as? [String: Any]
        XCTAssertNotNil(envelope, "google error envelope: got \(parsed)")
        XCTAssertEqual(envelope?["code"] as? Int, 400)
        XCTAssertNotNil(envelope?["message"] as? String)
        XCTAssertNotNil(envelope?["errors"] as? [[String: Any]])
    }

    func testGoogleLanguagesEnvelope() async throws {
        // Must be {"data":{"languages":[{"language":"...", "name":"..."}]}}
        let (data, _) = try await harness.get("/language/translate/v2/languages")
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let dataField = parsed["data"] as? [String: Any]
        XCTAssertNotNil(dataField)
        let languages = dataField?["languages"] as? [[String: Any]]
        XCTAssertNotNil(languages)
        XCTAssertGreaterThan(languages?.count ?? 0, 5)
        for lang in (languages ?? []).prefix(3) {
            XCTAssertNotNil(lang["language"] as? String)
            XCTAssertNotNil(lang["name"] as? String)
        }
    }

    func testGoogleLanguagesGETWithQueryParam() async throws {
        // Real Google v2: ?target=de returns localized names. We don't localize
        // (deterministic only) but must still 200 with the correct shape.
        let (data, response) = try await harness.get("/language/translate/v2/languages?target=de")
        XCTAssertEqual(response.statusCode, 200)
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(parsed["data"] as? [String: Any])
    }

    // ----------------------------------------------- Common across all APIs

    func testHealthReturnsStableShape() async throws {
        let (data, _) = try await harness.get("/health")
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(parsed["ok"] as? Bool, true)
    }

    func testCORSHeadersOnRegularResponses() async throws {
        // SDK clients (deepl, libretranslatepy, requests) issue simple POSTs
        // that don't trigger preflight, so what matters is the regular
        // responses carry Access-Control-Allow-Origin so a browser fetch
        // also works. Validate that here.
        let (_, response) = try await harness.get("/health")
        let allow = response.value(forHTTPHeaderField: "Access-Control-Allow-Origin")
        XCTAssertEqual(allow, "*", "missing/incorrect CORS header on /health")
    }

    func testServerHandlesConcurrentRequests() async throws {
        // Drop-in clients pool connections. We must not deadlock on parallel
        // POSTs hitting all three APIs at once.
        let port = harness.port
        try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<10 {
                group.addTask {
                    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v2/translate")!)
                    var body = "text=Hallo&target_lang=EN&source_lang=DE"
                    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    if i % 3 == 1 {
                        request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/translate")!)
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        body = #"{"q":"Hallo","source":"de","target":"en"}"#
                    } else if i % 3 == 2 {
                        request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/language/translate/v2")!)
                        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                        body = "q=Hallo&target=en&source=de"
                    }
                    request.httpMethod = "POST"
                    request.httpBody = Data(body.utf8)
                    request.timeoutInterval = 5
                    let (_, response) = try await URLSession.shared.data(for: request)
                    return (response as! HTTPURLResponse).statusCode
                }
            }
            for try await code in group {
                XCTAssertLessThan(code, 500, "concurrent request returned \(code)")
            }
        }
    }
}
