@preconcurrency import Foundation
import XCTest
@testable import translate

final class DetectTests: XCTestCase {
    func testDetectionKnownLanguages() throws {
        let detector = LanguageDetector()

        let german = try detector.detect(in: "Das ist ein kurzer deutscher Satz über die Welt.")
        XCTAssertEqual(german.languageCode.prefix(2), "de")
        XCTAssertGreaterThan(german.confidence, 0.0)

        let french = try detector.detect(in: "Ceci est une phrase française avec plusieurs mots.")
        XCTAssertEqual(french.languageCode.prefix(2), "fr")

        let japanese = try detector.detect(in: "これは日本語の文章です。翻訳のテストです。")
        XCTAssertEqual(japanese.languageCode.prefix(2), "ja")

        let english = try detector.detect(in: "This is a short English sentence about the world.")
        XCTAssertEqual(english.languageCode.prefix(2), "en")
    }

    func testDetectionVeryShortAmbiguousInputThrows() {
        let detector = LanguageDetector()
        XCTAssertThrowsError(try detector.detect(in: "?"))
    }

    func testDetectionEmptyInputThrows() {
        let detector = LanguageDetector()
        XCTAssertThrowsError(try detector.detect(in: ""))
        XCTAssertThrowsError(try detector.detect(in: "   \n  \t  "))
    }

    func testDetectionWithHintsConstrainsResult() throws {
        let detector = LanguageDetector(hints: ["de", "fr"])
        let result = try detector.detect(in: "Bonjour le monde, comment ça va aujourd'hui ?")
        XCTAssertTrue(["de", "fr"].contains(String(result.languageCode.prefix(2))))
    }

    func testPrefixUTF8BytesNeverSplitsScalar() {
        let unicode = "Hallo Welt 🌍 العالم"
        let cut = unicode.prefixUTF8Bytes(15)
        XCTAssertNotNil(String(data: Data(cut.utf8), encoding: .utf8))
    }

    func testPrefixUTF8BytesZero() {
        XCTAssertEqual("anything".prefixUTF8Bytes(0), "")
    }
}
