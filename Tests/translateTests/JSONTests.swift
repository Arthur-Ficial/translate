@preconcurrency import Foundation
import XCTest
@testable import translate

final class JSONTests: XCTestCase {
    func testRecordShape() {
        let record = TranslationRecord(
            from: "de",
            to: "en",
            src: "Hallo",
            dst: "Hello",
            conf: 0.97
        )

        XCTAssertEqual(
            StableJSON.object(record),
            #"{"from":"de","to":"en","src":"Hallo","dst":"Hello","conf":0.97}"#
        )
    }

    func testStringEscapesQuotesBackslashesAndControl() {
        XCTAssertEqual(StableJSON.string("a\"b"), "\"a\\\"b\"")
        XCTAssertEqual(StableJSON.string("c\\d"), "\"c\\\\d\"")
        XCTAssertEqual(StableJSON.string("e\nf"), "\"e\\nf\"")
        XCTAssertEqual(StableJSON.string("g\tH"), "\"g\\tH\"")
        XCTAssertEqual(StableJSON.string("\r"), "\"\\r\"")
        XCTAssertEqual(StableJSON.string("\u{08}"), "\"\\b\"")
        XCTAssertEqual(StableJSON.string("\u{0C}"), "\"\\f\"")
        XCTAssertEqual(StableJSON.string("\u{01}"), "\"\\u0001\"")
        XCTAssertEqual(StableJSON.string("\u{1F}"), "\"\\u001F\"")
    }

    func testStringPreservesNonASCII() {
        XCTAssertEqual(StableJSON.string("Welt 🌍"), "\"Welt 🌍\"")
        XCTAssertEqual(StableJSON.string("العالم"), "\"العالم\"")
    }

    func testNumberFormatTrimsTrailingZeros() {
        XCTAssertEqual(StableJSON.formatNumber(0.97), "0.97")
        XCTAssertEqual(StableJSON.formatNumber(0.5), "0.5")
        XCTAssertEqual(StableJSON.formatNumber(1.0), "1")
        XCTAssertEqual(StableJSON.formatNumber(0.123456), "0.123456")
    }

    func testNumberFormatHandlesNonFiniteAsNull() {
        XCTAssertEqual(StableJSON.formatNumber(Double.nan), "null")
        XCTAssertEqual(StableJSON.formatNumber(Double.infinity), "null")
    }

    func testRecordWithEscapedSourceAndDest() {
        let record = TranslationRecord(
            from: "en",
            to: "de",
            src: "say \"hi\"\n",
            dst: "sag \"hallo\"\n",
            conf: 0.5
        )
        XCTAssertEqual(
            StableJSON.object(record),
            #"{"from":"en","to":"de","src":"say \"hi\"\n","dst":"sag \"hallo\"\n","conf":0.5}"#
        )
    }

    func testLanguageListParse() {
        XCTAssertEqual(LanguageList.parse(nil), [])
        XCTAssertEqual(LanguageList.parse(""), [])
        XCTAssertEqual(LanguageList.parse("de"), ["de"])
        XCTAssertEqual(LanguageList.parse("de, fr ,en"), ["de", "fr", "en"])
        XCTAssertEqual(LanguageList.parse("de,,en"), ["de", "en"])
    }
}
