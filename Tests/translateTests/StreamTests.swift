@preconcurrency import Foundation
import XCTest
@testable import translate

final class StreamTests: XCTestCase {
    func testUTF8StreamDecoderHandlesSplitMultiByteScalar() throws {
        var decoder = UTF8StreamDecoder()
        let euro = "€"
        let bytes = Array(euro.utf8)
        XCTAssertEqual(bytes.count, 3)

        let first = try decoder.decode(Data(bytes.prefix(2)))
        XCTAssertEqual(first, "")

        let second = try decoder.decode(Data(bytes.suffix(1)))
        XCTAssertEqual(second, euro)

        let tail = try decoder.finish()
        XCTAssertEqual(tail, "")
    }

    func testUTF8StreamDecoderEmptyInputs() throws {
        var decoder = UTF8StreamDecoder()
        XCTAssertEqual(try decoder.decode(Data()), "")
        XCTAssertEqual(try decoder.finish(), "")
    }

    func testUTF8StreamDecoderInvalidMidStreamThrows() {
        var decoder = UTF8StreamDecoder()
        // 0xC0 is never a valid UTF-8 byte under any continuation pattern.
        XCTAssertThrowsError(try decoder.decode(Data([0xC0, 0xC1, 0xC2, 0xC3, 0xC4])))
    }

    func testParagraphSplitterEmitsParagraphsAndKeepsLiteralSeparator() {
        var splitter = ParagraphSplitter()
        let tokens = splitter.feed("hallo\n\nwelt")
        let units = tokens.compactMap { token -> String? in
            if case let .unit(text) = token { return text } else { return nil }
        }
        let literals = tokens.compactMap { token -> String? in
            if case let .literal(text) = token { return text } else { return nil }
        }
        XCTAssertEqual(units, ["hallo"])
        XCTAssertEqual(literals.joined(), "\n\n")

        let tail = splitter.finish()
        XCTAssertEqual(tail.count, 1)
        if case let .unit(text) = tail[0] {
            XCTAssertEqual(text, "welt")
        } else {
            XCTFail("expected unit token in finish()")
        }
    }

    func testParagraphSplitterHandlesMultipleParagraphs() {
        var splitter = ParagraphSplitter()
        let tokens = splitter.feed("a\n\nb\n\nc\n\n")
        let units = tokens.compactMap { token -> String? in
            if case let .unit(text) = token { return text } else { return nil }
        }
        XCTAssertEqual(units, ["a", "b", "c"])
        XCTAssertTrue(splitter.finish().isEmpty)
    }

    func testLineSplitterEmitsOneTokenPerNewline() {
        var splitter = LineSplitter()
        let tokens = splitter.feed("alpha\nbeta\ngamma")
        let units = tokens.compactMap { token -> String? in
            if case let .unit(text) = token { return text } else { return nil }
        }
        XCTAssertEqual(units, ["alpha", "beta"])

        let tail = splitter.finish()
        if case let .unit(text) = tail.first {
            XCTAssertEqual(text, "gamma")
        } else {
            XCTFail("expected trailing unit")
        }
    }

    @available(macOS 26.0, *)
    func testStreamingProducesPlainOutputForBothParagraphs() async throws {
        let input = Pipe()
        let capture = LockedBuffer()
        let writer = OutputWriter(format: .plain) { text in
            capture.append(text)
        }

        let processor = StreamProcessor(chunkSize: 16)
        let translator = FakeTranslator()

        let task = Task {
            try await processor.process(
                handle: input.fileHandleForReading,
                sourceOverride: "de",
                targetCode: "en",
                hints: [],
                translator: translator,
                writer: writer,
                noInstall: true,
                quiet: true,
                preserveNewlines: true,
                batch: false
            )
        }

        input.fileHandleForWriting.write(Data("hallo\n\nwelt".utf8))
        try input.fileHandleForWriting.close()
        try await task.value

        XCTAssertTrue(capture.value.contains("HALLO"))
        XCTAssertTrue(capture.value.contains("WELT"))
        XCTAssertTrue(capture.value.contains("\n\n"), "literal paragraph separator must pass through")
    }

    @available(macOS 26.0, *)
    func testStreamingNDJSONEmitsOneRecordPerParagraph() async throws {
        let input = Pipe()
        let capture = LockedBuffer()
        let writer = OutputWriter(format: .ndjson) { capture.append($0) }
        let processor = StreamProcessor(chunkSize: 64)
        let translator = FakeTranslator()

        let task = Task {
            try await processor.process(
                handle: input.fileHandleForReading,
                sourceOverride: "de",
                targetCode: "en",
                hints: [],
                translator: translator,
                writer: writer,
                noInstall: true,
                quiet: true,
                preserveNewlines: true,
                batch: false
            )
        }

        input.fileHandleForWriting.write(Data("hallo\n\nwelt\n\nfoo".utf8))
        try input.fileHandleForWriting.close()
        try await task.value

        let lines = capture.value.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(capture.value.contains("\"src\":\"hallo\""))
        XCTAssertTrue(capture.value.contains("\"src\":\"welt\""))
        XCTAssertTrue(capture.value.contains("\"src\":\"foo\""))
    }

    @available(macOS 26.0, *)
    func testStreamingBatchModeTranslatesPerLine() async throws {
        let input = Pipe()
        let capture = LockedBuffer()
        let writer = OutputWriter(format: .plain) { capture.append($0) }
        let processor = StreamProcessor(chunkSize: 32)
        let translator = FakeTranslator()

        let task = Task {
            try await processor.process(
                handle: input.fileHandleForReading,
                sourceOverride: "de",
                targetCode: "en",
                hints: [],
                translator: translator,
                writer: writer,
                noInstall: true,
                quiet: true,
                preserveNewlines: true,
                batch: true
            )
        }

        input.fileHandleForWriting.write(Data("eins\nzwei\ndrei\n".utf8))
        try input.fileHandleForWriting.close()
        try await task.value

        XCTAssertTrue(capture.value.contains("EINS"))
        XCTAssertTrue(capture.value.contains("ZWEI"))
        XCTAssertTrue(capture.value.contains("DREI"))
    }
}
