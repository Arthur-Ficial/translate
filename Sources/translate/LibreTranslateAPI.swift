@preconcurrency import Foundation

public struct LibreTranslateRequest: Sendable {
    public let q: [String]
    public let qWasArray: Bool
    public let source: String
    public let target: String
    public let format: String
    public let apiKey: String?

    public init(q: [String], qWasArray: Bool, source: String, target: String, format: String, apiKey: String?) {
        self.q = q
        self.qWasArray = qWasArray
        self.source = source
        self.target = target
        self.format = format
        self.apiKey = apiKey
    }

    public static func fromJSON(_ data: Data) throws -> LibreTranslateRequest {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslateError.usage("LibreTranslate: invalid JSON")
        }

        let qList: [String]
        let qWasArray: Bool
        if let array = object["q"] as? [String] {
            qList = array
            qWasArray = true
        } else if let single = object["q"] as? String {
            qList = [single]
            qWasArray = false
        } else {
            throw TranslateError.usage("LibreTranslate: missing q")
        }

        guard let target = object["target"] as? String, !target.isEmpty else {
            throw TranslateError.usage("LibreTranslate: missing target")
        }
        let source = (object["source"] as? String) ?? "auto"
        let format = (object["format"] as? String) ?? "text"
        let apiKey = object["api_key"] as? String

        return LibreTranslateRequest(
            q: qList,
            qWasArray: qWasArray,
            source: source,
            target: target,
            format: format,
            apiKey: apiKey
        )
    }

    public static func fromForm(_ body: String) throws -> LibreTranslateRequest {
        let pairs = FormDecoder.parse(body)
        let qList = pairs.values(for: "q")
        guard !qList.isEmpty else {
            throw TranslateError.usage("LibreTranslate: missing q")
        }
        guard let target = pairs.first(for: "target"), !target.isEmpty else {
            throw TranslateError.usage("LibreTranslate: missing target")
        }
        let source = pairs.first(for: "source") ?? "auto"
        let format = pairs.first(for: "format") ?? "text"
        let apiKey = pairs.first(for: "api_key")
        return LibreTranslateRequest(
            q: qList,
            qWasArray: qList.count > 1,
            source: source,
            target: target,
            format: format,
            apiKey: apiKey
        )
    }
}

public struct LibreDetectedLanguage: Sendable {
    public let language: String
    public let confidence: Int

    public init(language: String, confidence: Int) {
        self.language = language
        self.confidence = confidence
    }
}

public enum LibreTranslateResponse: Sendable {
    case singleString(translatedText: String, detectedLanguage: LibreDetectedLanguage?)
    case array(translatedTexts: [String], detectedLanguage: LibreDetectedLanguage?)

    public static func single(translatedText: String, detectedLanguage: LibreDetectedLanguage?) -> LibreTranslateResponse {
        .singleString(translatedText: translatedText, detectedLanguage: detectedLanguage)
    }

    public func toJSON() -> String {
        switch self {
        case let .singleString(text, detected):
            let textPart = "\"translatedText\":\(StableJSON.string(text))"
            if let detected {
                let detectedPart = "\"detectedLanguage\":{\"confidence\":\(detected.confidence),\"language\":\(StableJSON.string(detected.language))}"
                return "{\(detectedPart),\(textPart)}"
            }
            return "{\(textPart)}"

        case let .array(texts, detected):
            let inner = texts.map(StableJSON.string).joined(separator: ",")
            let textPart = "\"translatedText\":[\(inner)]"
            if let detected {
                let detectedPart = "\"detectedLanguage\":{\"confidence\":\(detected.confidence),\"language\":\(StableJSON.string(detected.language))}"
                return "{\(detectedPart),\(textPart)}"
            }
            return "{\(textPart)}"
        }
    }
}

public struct LibreDetectResponse: Sendable {
    public let items: [LibreDetectedLanguage]

    public init(items: [LibreDetectedLanguage]) {
        self.items = items
    }

    public func toJSON() -> String {
        let body = items.map { item in
            "{\"confidence\":\(item.confidence),\"language\":\(StableJSON.string(item.language))}"
        }.joined(separator: ",")
        return "[\(body)]"
    }
}

public struct LibreLanguageEntry: Sendable {
    public let code: String
    public let name: String
    public let targets: [String]

    public init(code: String, name: String, targets: [String]) {
        self.code = code
        self.name = name
        self.targets = targets
    }
}

public struct LibreLanguagesResponse: Sendable {
    public let items: [LibreLanguageEntry]

    public init(items: [LibreLanguageEntry]) {
        self.items = items
    }

    public func toJSON() -> String {
        let body = items.map { entry in
            let targets = entry.targets.map(StableJSON.string).joined(separator: ",")
            return "{\"code\":\(StableJSON.string(entry.code)),\"name\":\(StableJSON.string(entry.name)),\"targets\":[\(targets)]}"
        }.joined(separator: ",")
        return "[\(body)]"
    }
}
