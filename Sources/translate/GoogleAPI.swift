@preconcurrency import Foundation

public struct GoogleRequest: Sendable {
    public let qs: [String]
    public let target: String
    public let source: String?
    public let format: String?
    public let apiKey: String?

    public init(qs: [String], target: String, source: String?, format: String?, apiKey: String?) {
        self.qs = qs
        self.target = target
        self.source = source
        self.format = format
        self.apiKey = apiKey
    }

    public static func fromForm(_ body: String) throws -> GoogleRequest {
        let pairs = FormDecoder.parse(body)
        let qs = pairs.values(for: "q")
        guard !qs.isEmpty else {
            throw TranslateError.usage("Google: missing q")
        }
        guard let target = pairs.first(for: "target"), !target.isEmpty else {
            throw TranslateError.usage("Google: missing target")
        }
        return GoogleRequest(
            qs: qs,
            target: target,
            source: pairs.first(for: "source"),
            format: pairs.first(for: "format"),
            apiKey: pairs.first(for: "key")
        )
    }

    public static func fromJSON(_ data: Data) throws -> GoogleRequest {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslateError.usage("Google: invalid JSON")
        }

        let qs: [String]
        if let array = object["q"] as? [String] {
            qs = array
        } else if let single = object["q"] as? String {
            qs = [single]
        } else {
            throw TranslateError.usage("Google: missing q")
        }

        guard let target = object["target"] as? String, !target.isEmpty else {
            throw TranslateError.usage("Google: missing target")
        }

        return GoogleRequest(
            qs: qs,
            target: target,
            source: object["source"] as? String,
            format: object["format"] as? String,
            apiKey: object["key"] as? String
        )
    }
}

public struct GoogleTranslation: Sendable {
    public let translatedText: String
    public let detectedSourceLanguage: String?

    public init(translatedText: String, detectedSourceLanguage: String?) {
        self.translatedText = translatedText
        self.detectedSourceLanguage = detectedSourceLanguage
    }
}

public struct GoogleResponse: Sendable {
    public let translations: [GoogleTranslation]

    public init(translations: [GoogleTranslation]) {
        self.translations = translations
    }

    public func toJSON() -> String {
        let body = translations.map { item in
            if let detected = item.detectedSourceLanguage {
                return "{\"detectedSourceLanguage\":\(StableJSON.string(detected)),\"translatedText\":\(StableJSON.string(item.translatedText))}"
            }
            return "{\"translatedText\":\(StableJSON.string(item.translatedText))}"
        }.joined(separator: ",")
        return "{\"data\":{\"translations\":[\(body)]}}"
    }
}
