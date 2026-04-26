@preconcurrency import Foundation

/// Decoded form of a DeepL `/v2/translate` request. We accept both
/// form-encoded and JSON bodies because the official DeepL clients (Python
/// `deepl`, Node `deepl-node`) send form-encoded; some third-party tools
/// post JSON.
public struct DeepLRequest: Sendable {
    public let texts: [String]
    public let targetLang: String
    public let sourceLang: String?
    public let authKey: String?

    public init(texts: [String], targetLang: String, sourceLang: String?, authKey: String?) {
        self.texts = texts
        self.targetLang = targetLang
        self.sourceLang = sourceLang
        self.authKey = authKey
    }

    public static func fromForm(_ body: String) throws -> DeepLRequest {
        let pairs = FormDecoder.parse(body)
        let texts = pairs.values(for: "text")
        guard !texts.isEmpty else {
            throw TranslateError.usage("DeepL: missing text")
        }
        guard let target = pairs.first(for: "target_lang"), !target.isEmpty else {
            throw TranslateError.usage("DeepL: missing target_lang")
        }
        let source = pairs.first(for: "source_lang")
        let authKey = pairs.first(for: "auth_key")
        return DeepLRequest(texts: texts, targetLang: target, sourceLang: source, authKey: authKey)
    }

    public static func fromJSON(_ data: Data) throws -> DeepLRequest {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslateError.usage("DeepL: invalid JSON")
        }

        let texts: [String]
        if let array = object["text"] as? [String] {
            texts = array
        } else if let single = object["text"] as? String {
            texts = [single]
        } else {
            throw TranslateError.usage("DeepL: missing text")
        }

        guard let target = object["target_lang"] as? String, !target.isEmpty else {
            throw TranslateError.usage("DeepL: missing target_lang")
        }
        let source = object["source_lang"] as? String
        let authKey = object["auth_key"] as? String

        return DeepLRequest(
            texts: texts,
            targetLang: target,
            sourceLang: source,
            authKey: authKey
        )
    }

    /// DeepL uses uppercase ISO-639-1 codes ("EN", "DE", "PT-BR"). Map to
    /// the BCP-47 minimal identifier that the Apple translation framework
    /// uses. Returns nil for empty input.
    public static func normalizeLang(_ code: String) -> String? {
        guard !code.isEmpty else { return nil }
        let parts = code.split(separator: "-").map { $0.lowercased() }
        guard let first = parts.first else { return nil }

        // Re-uppercase the region if present so BCP-47 conventions hold for
        // identifiers Apple's framework recognizes (e.g. "pt-BR", "en-GB").
        if parts.count >= 2 {
            let region = parts[1].uppercased()
            let candidate = "\(first)-\(region)"
            return Locale.Language(identifier: candidate).minimalIdentifier
        }
        return Locale.Language(identifier: first).minimalIdentifier
    }
}

public struct DeepLTranslation: Sendable {
    public let detectedSourceLanguage: String
    public let text: String
    public let billedCharacters: Int

    public init(detectedSourceLanguage: String, text: String, billedCharacters: Int) {
        self.detectedSourceLanguage = detectedSourceLanguage
        self.text = text
        self.billedCharacters = billedCharacters
    }
}

public struct DeepLResponse: Sendable {
    public let translations: [DeepLTranslation]

    public init(translations: [DeepLTranslation]) {
        self.translations = translations
    }

    public func toJSON() -> String {
        let body = translations.map { item in
            "{\"detected_source_language\":\(StableJSON.string(item.detectedSourceLanguage)),\"text\":\(StableJSON.string(item.text)),\"billed_characters\":\(item.billedCharacters)}"
        }.joined(separator: ",")
        return "{\"translations\":[\(body)]}"
    }
}
