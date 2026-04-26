@preconcurrency import Foundation
import XCTest
@testable import translate

final class MaskerTests: XCTestCase {
    func testProtectsUrlsEmailsAndBackticks() {
        let segments = TranslationMasker.segments(
            in: "Hallo `code` https://example.com a@b.com Welt",
            preserveNewlines: true
        )

        XCTAssertTrue(segments.contains(.init(text: "`code`", isTranslatable: false)))
        XCTAssertTrue(segments.contains(.init(text: "https://example.com", isTranslatable: false)))
        XCTAssertTrue(segments.contains(.init(text: "a@b.com", isTranslatable: false)))
    }

    func testProtectsFencedCodeBlocks() {
        let input = """
        Hallo
        ```swift
        let x = 1
        ```
        Welt
        """
        let segments = TranslationMasker.segments(in: input, preserveNewlines: true)
        let fences = segments.filter { $0.text.contains("```") && !$0.isTranslatable }
        XCTAssertFalse(fences.isEmpty, "fenced code block must be protected")
    }

    func testProtectsUnterminatedBacktickRunToEndOfInput() {
        let segments = TranslationMasker.segments(in: "Hallo `unfinished", preserveNewlines: true)
        let last = segments.last
        XCTAssertEqual(last?.isTranslatable, false)
        XCTAssertEqual(last?.text.hasPrefix("`"), true)
    }

    func testPreserveNewlinesSplitsTranslatableRuns() {
        let segments = TranslationMasker.segments(in: "a\n\nb", preserveNewlines: true)
        let translatables = segments.filter(\.isTranslatable)
        let literals = segments.filter { !$0.isTranslatable }
        XCTAssertEqual(translatables.map(\.text), ["a", "b"])
        XCTAssertEqual(literals.map(\.text).joined(), "\n\n")
    }

    func testNoPreserveNewlinesKeepsContiguous() {
        let segments = TranslationMasker.segments(in: "a\n\nb", preserveNewlines: false)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].isTranslatable, true)
        XCTAssertEqual(segments[0].text, "a\n\nb")
    }

    func testRoundTripReassemblyIsLossless() {
        let originals = [
            "Hallo Welt",
            "click `here` to https://example.com see a@b.com",
            "line one\nline two\n\nparagraph two",
            "no special tokens here at all"
        ]
        for original in originals {
            let pieces = TranslationMasker.segments(in: original, preserveNewlines: true)
                .map(\.text)
                .joined()
            XCTAssertEqual(pieces, original, "masker must preserve every byte")
        }
    }

    func testEmptyInputReturnsEmptySegment() {
        let segments = TranslationMasker.segments(in: "", preserveNewlines: true)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "")
        XCTAssertEqual(segments[0].isTranslatable, false)
    }
}
