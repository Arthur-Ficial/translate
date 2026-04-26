@preconcurrency import Foundation

public enum StreamToken: Sendable, Equatable {
    case unit(String)
    case literal(String)
}

public enum StreamMode: Sendable {
    case paragraphs
    case lines
}

public struct UTF8StreamDecoder: Sendable {
    private var pending: [UInt8] = []

    public init() {}

    public mutating func decode(_ data: Data) throws -> String {
        pending.append(contentsOf: data)

        guard !pending.isEmpty else {
            return ""
        }

        let maxCarry = min(3, pending.count)

        for carry in 0...maxCarry {
            let prefixCount = pending.count - carry
            guard prefixCount > 0 else { continue }

            let prefix = Data(pending.prefix(prefixCount))
            if let string = String(data: prefix, encoding: .utf8) {
                pending = Array(pending.suffix(carry))
                return string
            }
        }

        if pending.count <= 3 {
            return ""
        }

        throw TranslateError.input("input is not valid UTF-8")
    }

    public mutating func finish() throws -> String {
        guard !pending.isEmpty else {
            return ""
        }

        guard let string = String(data: Data(pending), encoding: .utf8) else {
            throw TranslateError.input("input ended with incomplete or invalid UTF-8")
        }

        pending.removeAll(keepingCapacity: false)
        return string
    }
}

public struct ParagraphSplitter: Sendable {
    private var buffer = ""

    public init() {}

    public mutating func feed(_ chunk: String) -> [StreamToken] {
        buffer.append(chunk)
        var tokens: [StreamToken] = []

        while let separator = firstBlankLineRange(in: buffer) {
            let paragraph = String(buffer[..<separator.lowerBound])
            let literal = String(buffer[separator])

            if !paragraph.isEmpty {
                tokens.append(.unit(paragraph))
            }

            tokens.append(.literal(literal))
            buffer.removeSubrange(buffer.startIndex..<separator.upperBound)
        }

        return tokens
    }

    public mutating func finish() -> [StreamToken] {
        guard !buffer.isEmpty else {
            return []
        }

        let paragraph = buffer
        buffer.removeAll(keepingCapacity: false)
        return [.unit(paragraph)]
    }

    private func firstBlankLineRange(in text: String) -> Range<String.Index>? {
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "\n" else {
                index = text.index(after: index)
                continue
            }

            var probe = text.index(after: index)

            while probe < text.endIndex {
                let character = text[probe]
                if character == " " || character == "\t" || character == "\r" {
                    probe = text.index(after: probe)
                } else {
                    break
                }
            }

            if probe < text.endIndex, text[probe] == "\n" {
                return index..<text.index(after: probe)
            }

            index = text.index(after: index)
        }

        return nil
    }
}

public struct LineSplitter: Sendable {
    private var buffer = ""

    public init() {}

    public mutating func feed(_ chunk: String) -> [StreamToken] {
        buffer.append(chunk)
        var tokens: [StreamToken] = []

        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            tokens.append(.unit(line))
            tokens.append(.literal("\n"))
            buffer.removeSubrange(buffer.startIndex...newline)
        }

        return tokens
    }

    public mutating func finish() -> [StreamToken] {
        guard !buffer.isEmpty else {
            return []
        }

        let line = buffer
        buffer.removeAll(keepingCapacity: false)
        return [.unit(line)]
    }
}

@available(macOS 26.0, *)
public struct StreamProcessor: Sendable {
    public let chunkSize: Int

    public init(chunkSize: Int = 64 * 1024) {
        self.chunkSize = chunkSize
    }

    public func process(
        handle: FileHandle,
        sourceOverride: String?,
        targetCode: String,
        hints: [String],
        translator: any Translating,
        writer: OutputWriter,
        noInstall: Bool,
        quiet: Bool,
        preserveNewlines: Bool,
        batch: Bool
    ) async throws {
        var decoder = UTF8StreamDecoder()

        let firstData = try handle.read(upToCount: chunkSize) ?? Data()
        guard !firstData.isEmpty else {
            return
        }

        let firstChunk = try decoder.decode(firstData)

        let detection: DetectionResult
        if let sourceOverride, !sourceOverride.isEmpty {
            detection = DetectionResult(
                languageCode: Locale.Language(identifier: sourceOverride).minimalIdentifier,
                confidence: 1.0
            )
        } else {
            detection = try LanguageDetector(hints: hints).detect(in: firstChunk)
        }

        let source = Locale.Language(identifier: detection.languageCode)
        let target = Locale.Language(identifier: targetCode)

        try await translator.prepare(
            source: source,
            target: target,
            noInstall: noInstall,
            quiet: quiet
        )

        if batch {
            var splitter = LineSplitter()
            try await emit(
                splitter.feed(firstChunk),
                source: source,
                target: target,
                detection: detection,
                translator: translator,
                writer: writer,
                preserveNewlines: preserveNewlines
            )

            while true {
                let data = try handle.read(upToCount: chunkSize) ?? Data()
                if data.isEmpty { break }

                let chunk = try decoder.decode(data)
                try await emit(
                    splitter.feed(chunk),
                    source: source,
                    target: target,
                    detection: detection,
                    translator: translator,
                    writer: writer,
                    preserveNewlines: preserveNewlines
                )
            }

            let tail = try decoder.finish()
            if !tail.isEmpty {
                try await emit(
                    splitter.feed(tail),
                    source: source,
                    target: target,
                    detection: detection,
                    translator: translator,
                    writer: writer,
                    preserveNewlines: preserveNewlines
                )
            }

            try await emit(
                splitter.finish(),
                source: source,
                target: target,
                detection: detection,
                translator: translator,
                writer: writer,
                preserveNewlines: preserveNewlines
            )
        } else {
            var splitter = ParagraphSplitter()
            try await emit(
                splitter.feed(firstChunk),
                source: source,
                target: target,
                detection: detection,
                translator: translator,
                writer: writer,
                preserveNewlines: preserveNewlines
            )

            while true {
                let data = try handle.read(upToCount: chunkSize) ?? Data()
                if data.isEmpty { break }

                let chunk = try decoder.decode(data)
                try await emit(
                    splitter.feed(chunk),
                    source: source,
                    target: target,
                    detection: detection,
                    translator: translator,
                    writer: writer,
                    preserveNewlines: preserveNewlines
                )
            }

            let tail = try decoder.finish()
            if !tail.isEmpty {
                try await emit(
                    splitter.feed(tail),
                    source: source,
                    target: target,
                    detection: detection,
                    translator: translator,
                    writer: writer,
                    preserveNewlines: preserveNewlines
                )
            }

            try await emit(
                splitter.finish(),
                source: source,
                target: target,
                detection: detection,
                translator: translator,
                writer: writer,
                preserveNewlines: preserveNewlines
            )
        }
    }

    private func emit(
        _ tokens: [StreamToken],
        source: Locale.Language,
        target: Locale.Language,
        detection: DetectionResult,
        translator: any Translating,
        writer: OutputWriter,
        preserveNewlines: Bool
    ) async throws {
        guard !tokens.isEmpty else { return }

        let unitTexts = tokens.compactMap { token -> String? in
            if case let .unit(text) = token { return text }
            return nil
        }

        let translated = try await translator.translate(
            units: unitTexts,
            source: source,
            target: target,
            preserveNewlines: preserveNewlines
        )

        var translatedIndex = 0

        for token in tokens {
            switch token {
            case let .literal(text):
                writer.writeLiteral(text)

            case let .unit(src):
                let dst = translated[translatedIndex]
                translatedIndex += 1

                writer.write(
                    record: TranslationRecord(
                        from: source.minimalIdentifier,
                        to: target.minimalIdentifier,
                        src: src,
                        dst: dst,
                        conf: detection.confidence
                    )
                )
            }
        }
    }
}
