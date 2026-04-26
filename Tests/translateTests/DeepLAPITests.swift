@preconcurrency import Foundation
import XCTest
@testable import translate

final class DeepLAPITests: XCTestCase {

    // MARK: - Form decoder

    func testFormDecodeSingleText() throws {
        let body = "text=Hallo&target_lang=EN&source_lang=DE"
        let request = try DeepLRequest.fromForm(body)
        XCTAssertEqual(request.texts, ["Hallo"])
        XCTAssertEqual(request.targetLang, "EN")
        XCTAssertEqual(request.sourceLang, "DE")
    }

    func testFormDecodeMultipleTextsAndPercentEscapes() throws {
        let body = "text=Hallo&text=Welt&text=Hello%20World&target_lang=DE"
        let request = try DeepLRequest.fromForm(body)
        XCTAssertEqual(request.texts, ["Hallo", "Welt", "Hello World"])
        XCTAssertEqual(request.targetLang, "DE")
        XCTAssertNil(request.sourceLang)
    }

    func testFormDecodeAuthKeyExtractedAndRemovedFromTexts() throws {
        let body = "auth_key=abc&text=hi&target_lang=EN"
        let request = try DeepLRequest.fromForm(body)
        XCTAssertEqual(request.authKey, "abc")
        XCTAssertEqual(request.texts, ["hi"])
    }

    func testFormDecodeRejectsMissingTargetLang() {
        XCTAssertThrowsError(try DeepLRequest.fromForm("text=Hallo"))
    }

    func testFormDecodeRejectsMissingText() {
        XCTAssertThrowsError(try DeepLRequest.fromForm("target_lang=EN"))
    }

    // MARK: - JSON decoder

    func testJSONDecodeArrayText() throws {
        let json = #"{"text":["Hallo","Welt"],"target_lang":"EN","source_lang":"DE"}"#
        let request = try DeepLRequest.fromJSON(Data(json.utf8))
        XCTAssertEqual(request.texts, ["Hallo", "Welt"])
        XCTAssertEqual(request.targetLang, "EN")
        XCTAssertEqual(request.sourceLang, "DE")
    }

    func testJSONDecodeStringText() throws {
        let json = #"{"text":"Hallo","target_lang":"DE"}"#
        let request = try DeepLRequest.fromJSON(Data(json.utf8))
        XCTAssertEqual(request.texts, ["Hallo"])
        XCTAssertEqual(request.targetLang, "DE")
    }

    // MARK: - Response shape

    func testResponseEncoderShape() {
        let payload = DeepLResponse(translations: [
            .init(detectedSourceLanguage: "DE", text: "Hello", billedCharacters: 5),
            .init(detectedSourceLanguage: "DE", text: "World", billedCharacters: 5)
        ])
        let encoded = payload.toJSON()
        // exact, byte-stable shape -- the official deepl Python SDK reads
        // detected_source_language, text, and billed_characters.
        XCTAssertEqual(
            encoded,
            #"{"translations":[{"detected_source_language":"DE","text":"Hello","billed_characters":5},{"detected_source_language":"DE","text":"World","billed_characters":5}]}"#
        )
    }

    func testResponseEncoderEscapesQuotes() {
        let payload = DeepLResponse(translations: [
            .init(detectedSourceLanguage: "DE", text: "say \"hi\"", billedCharacters: 7)
        ])
        let encoded = payload.toJSON()
        XCTAssertTrue(encoded.contains(#"\"hi\""#))
    }

    // MARK: - Lang code mapping (DeepL uppercase -> BCP-47)

    func testNormalizeLangCodes() {
        XCTAssertEqual(DeepLRequest.normalizeLang("EN"), "en")
        XCTAssertEqual(DeepLRequest.normalizeLang("EN-US"), "en")
        XCTAssertEqual(DeepLRequest.normalizeLang("EN-GB"), "en-GB")
        XCTAssertEqual(DeepLRequest.normalizeLang("DE"), "de")
        XCTAssertEqual(DeepLRequest.normalizeLang("PT-BR"), "pt")
        XCTAssertEqual(DeepLRequest.normalizeLang("PT-PT"), "pt-PT")
        XCTAssertEqual(DeepLRequest.normalizeLang("ZH"), "zh")
        XCTAssertNil(DeepLRequest.normalizeLang(""))
    }
}
