@preconcurrency import Foundation
@preconcurrency import Translation

@available(macOS 26.0, *)
public protocol Translating: Sendable {
    func prepare(
        source: Locale.Language,
        target: Locale.Language,
        noInstall: Bool,
        quiet: Bool
    ) async throws

    func translate(
        units: [String],
        source: Locale.Language,
        target: Locale.Language,
        preserveNewlines: Bool
    ) async throws -> [String]
}

@available(macOS 26.0, *)
public actor AppleTranslator: Translating {
    private var session: TranslationSession?
    private var preparedSource: Locale.Language?
    private var preparedTarget: Locale.Language?

    public init() {}

    public func prepare(
        source: Locale.Language,
        target: Locale.Language,
        noInstall: Bool,
        quiet: Bool
    ) async throws {
        if preparedSource == source, preparedTarget == target, session != nil {
            return
        }

        let manager = ModelManager(quiet: quiet)
        let status = await manager.status(source: source, target: target)

        switch status {
        case .installed:
            break

        case .supported:
            if noInstall {
                throw TranslateError.modelNotInstalled("\(source.minimalIdentifier)-\(target.minimalIdentifier)")
            }

            if !quiet {
                Stdio.stderr("translate: preparing \(source.minimalIdentifier)-\(target.minimalIdentifier) model\n")
            }

            try await manager.prepare(source: source, target: target)

        case .unsupported:
            throw TranslateError.unsupportedPair("\(source.minimalIdentifier)-\(target.minimalIdentifier)")
        }

        session = TranslationSupport.installedSession(source: source, target: target)
        preparedSource = source
        preparedTarget = target
    }

    public func translate(
        units: [String],
        source: Locale.Language,
        target: Locale.Language,
        preserveNewlines: Bool
    ) async throws -> [String] {
        try await prepare(source: source, target: target, noInstall: false, quiet: true)

        guard let session else {
            throw TranslateError.translationFailure("translation session was not prepared")
        }

        var plans: [[TranslationSegment]] = units.map {
            TranslationMasker.segments(in: $0, preserveNewlines: preserveNewlines)
        }

        var requestLocations: [(unitIndex: Int, segmentIndex: Int)] = []
        var requestTexts: [String] = []

        for unitIndex in plans.indices {
            for segmentIndex in plans[unitIndex].indices {
                let segment = plans[unitIndex][segmentIndex]
                guard segment.isTranslatable else { continue }

                let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                requestLocations.append((unitIndex, segmentIndex))
                requestTexts.append(segment.text)
            }
        }

        let translatedSegments: [String]
        do {
            translatedSegments = try await translateTexts(requestTexts, using: session)
        } catch {
            throw TranslateError.translationFailure(error.localizedDescription)
        }

        for index in translatedSegments.indices {
            let location = requestLocations[index]
            plans[location.unitIndex][location.segmentIndex] = TranslationSegment(
                text: translatedSegments[index],
                isTranslatable: false
            )
        }

        return plans.map { segments in
            segments.map(\.text).joined()
        }
    }

    private func translateTexts(
        _ texts: [String],
        using session: TranslationSession
    ) async throws -> [String] {
        guard !texts.isEmpty else { return [] }

        if texts.count == 1 {
            let response = try await session.translate(texts[0])
            return [response.targetText]
        }

        let requests = texts.enumerated().map { index, text in
            TranslationSession.Request(
                sourceText: text,
                clientIdentifier: String(index)
            )
        }

        let responses = try await session.translations(from: requests)
        return responses.map(\.targetText)
    }
}

public struct TranslationSegment: Sendable, Equatable {
    public let text: String
    public let isTranslatable: Bool

    public init(text: String, isTranslatable: Bool) {
        self.text = text
        self.isTranslatable = isTranslatable
    }
}

public enum TranslationMasker: Sendable {
    public static func segments(
        in text: String,
        preserveNewlines: Bool
    ) -> [TranslationSegment] {
        guard !text.isEmpty else {
            return [TranslationSegment(text: "", isTranslatable: false)]
        }

        let protectedRanges = mergedProtectedRanges(in: text)
        var output: [TranslationSegment] = []
        var cursor = text.startIndex

        for range in protectedRanges {
            if cursor < range.lowerBound {
                appendTranslatable(
                    String(text[cursor..<range.lowerBound]),
                    preserveNewlines: preserveNewlines,
                    to: &output
                )
            }

            output.append(
                TranslationSegment(
                    text: String(text[range]),
                    isTranslatable: false
                )
            )

            cursor = range.upperBound
        }

        if cursor < text.endIndex {
            appendTranslatable(
                String(text[cursor..<text.endIndex]),
                preserveNewlines: preserveNewlines,
                to: &output
            )
        }

        return output
    }

    private static func appendTranslatable(
        _ text: String,
        preserveNewlines: Bool,
        to output: inout [TranslationSegment]
    ) {
        guard preserveNewlines else {
            output.append(TranslationSegment(text: text, isTranslatable: true))
            return
        }

        var buffer = ""
        var newlineBuffer = ""

        func flushBuffer() {
            if !buffer.isEmpty {
                output.append(TranslationSegment(text: buffer, isTranslatable: true))
                buffer.removeAll(keepingCapacity: true)
            }
        }

        func flushNewlines() {
            if !newlineBuffer.isEmpty {
                output.append(TranslationSegment(text: newlineBuffer, isTranslatable: false))
                newlineBuffer.removeAll(keepingCapacity: true)
            }
        }

        for character in text {
            if character.isNewline {
                flushBuffer()
                newlineBuffer.append(character)
            } else {
                flushNewlines()
                buffer.append(character)
            }
        }

        flushBuffer()
        flushNewlines()
    }

    private static func mergedProtectedRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        ranges.append(contentsOf: backtickRanges(in: text))
        ranges.append(contentsOf: regexRanges(in: text, pattern: #"https?://[^\s<>"']+|www\.[^\s<>"']+"#))
        ranges.append(contentsOf: regexRanges(in: text, pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#))

        ranges.sort {
            if $0.lowerBound == $1.lowerBound {
                return $0.upperBound < $1.upperBound
            }
            return $0.lowerBound < $1.lowerBound
        }

        var merged: [Range<String.Index>] = []

        for range in ranges {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }

            if range.lowerBound <= last.upperBound {
                let combined = last.lowerBound..<max(last.upperBound, range.upperBound)
                merged[merged.count - 1] = combined
            } else {
                merged.append(range)
            }
        }

        return merged
    }

    private static func backtickRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "`" else {
                index = text.index(after: index)
                continue
            }

            let start = index

            if text[start...].hasPrefix("```") {
                guard let bodyStart = text.index(start, offsetBy: 3, limitedBy: text.endIndex) else {
                    ranges.append(start..<text.endIndex)
                    break
                }

                if let close = text.range(of: "```", range: bodyStart..<text.endIndex) {
                    ranges.append(start..<close.upperBound)
                    index = close.upperBound
                } else {
                    ranges.append(start..<text.endIndex)
                    break
                }
            } else {
                let bodyStart = text.index(after: start)

                if let close = text[bodyStart...].firstIndex(of: "`") {
                    let end = text.index(after: close)
                    ranges.append(start..<end)
                    index = end
                } else {
                    ranges.append(start..<text.endIndex)
                    break
                }
            }
        }

        return ranges
    }

    private static func regexRanges(in text: String, pattern: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)

        return regex.matches(in: text, range: nsRange).compactMap { match in
            Range(match.range, in: text)
        }
    }
}
