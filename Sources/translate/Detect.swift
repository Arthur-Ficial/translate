@preconcurrency import Foundation
@preconcurrency import NaturalLanguage

public struct DetectionResult: Sendable, Equatable {
    public let languageCode: String
    public let confidence: Double

    public init(languageCode: String, confidence: Double) {
        self.languageCode = languageCode
        self.confidence = confidence
    }
}

public struct LanguageDetector: Sendable {
    public let hints: [String]

    public init(hints: [String] = []) {
        self.hints = hints
    }

    public func detect(in input: String) throws -> DetectionResult {
        let sample = input.prefixUTF8Bytes(2048)
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            throw TranslateError.input("empty input; cannot detect language")
        }

        let recognizer = NLLanguageRecognizer()

        let constraints = hints
            .map { Locale.Language(identifier: $0).minimalIdentifier }
            .map { NLLanguage(rawValue: $0) }

        if !constraints.isEmpty {
            recognizer.languageConstraints = constraints
        }

        recognizer.processString(sample)

        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        guard let best = hypotheses.max(by: { $0.value < $1.value }) else {
            throw TranslateError.input("could not detect language; pass --from explicitly")
        }

        let languageCode = best.key.rawValue
        let confidence = best.value

        if confidence < 0.5 && trimmed.count < 20 {
            throw TranslateError.input("ambiguous short input; pass --from explicitly")
        }

        return DetectionResult(
            languageCode: Locale.Language(identifier: languageCode).minimalIdentifier,
            confidence: confidence
        )
    }
}

public extension String {
    func prefixUTF8Bytes(_ maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }

        let prefixBytes = Array(self.utf8.prefix(maxBytes))
        guard let decoded = String(data: Data(prefixBytes), encoding: .utf8) else {
            return String(decoding: prefixBytes, as: UTF8.self)
        }

        return decoded
    }
}
