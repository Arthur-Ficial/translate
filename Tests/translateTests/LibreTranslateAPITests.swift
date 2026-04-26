@preconcurrency import Foundation
import XCTest
@testable import translate

final class LibreTranslateAPITests: XCTestCase {

    // MARK: - Request decode

    func testJSONDecodeStringQ() throws {
        let json = #"{"q":"Hallo Welt","source":"de","target":"en","format":"text"}"#
        let request = try LibreTranslateRequest.fromJSON(Data(json.utf8))
        XCTAssertEqual(request.q, ["Hallo Welt"])
        XCTAssertEqual(request.source, "de")
        XCTAssertEqual(request.target, "en")
        XCTAssertFalse(request.qWasArray)
    }

    func testJSONDecodeArrayQ() throws {
        let json = #"{"q":["a","b","c"],"source":"de","target":"en"}"#
        let request = try LibreTranslateRequest.fromJSON(Data(json.utf8))
        XCTAssertEqual(request.q, ["a", "b", "c"])
        XCTAssertTrue(request.qWasArray)
    }

    func testJSONDecodeAutoSource() throws {
        let json = #"{"q":"Hello","source":"auto","target":"de"}"#
        let request = try LibreTranslateRequest.fromJSON(Data(json.utf8))
        XCTAssertEqual(request.source, "auto")
    }

    func testFormDecode() throws {
        let body = "q=Hallo&source=de&target=en&format=text&api_key=abc"
        let request = try LibreTranslateRequest.fromForm(body)
        XCTAssertEqual(request.q, ["Hallo"])
        XCTAssertEqual(request.source, "de")
        XCTAssertEqual(request.target, "en")
        XCTAssertEqual(request.apiKey, "abc")
    }

    func testJSONDecodeRejectsMissingTarget() {
        let json = #"{"q":"Hallo","source":"de"}"#
        XCTAssertThrowsError(try LibreTranslateRequest.fromJSON(Data(json.utf8)))
    }

    // MARK: - Response shape

    func testResponseStringQEncoding() {
        let response = LibreTranslateResponse.single(
            translatedText: "Hello",
            detectedLanguage: nil
        )
        XCTAssertEqual(response.toJSON(), #"{"translatedText":"Hello"}"#)
    }

    func testResponseStringQWithDetectionEncoding() {
        let response = LibreTranslateResponse.single(
            translatedText: "Hello",
            detectedLanguage: .init(language: "de", confidence: 97)
        )
        XCTAssertEqual(
            response.toJSON(),
            #"{"detectedLanguage":{"confidence":97,"language":"de"},"translatedText":"Hello"}"#
        )
    }

    func testResponseArrayQEncoding() {
        let response = LibreTranslateResponse.array(
            translatedTexts: ["Hello", "World"],
            detectedLanguage: nil
        )
        XCTAssertEqual(
            response.toJSON(),
            #"{"translatedText":["Hello","World"]}"#
        )
    }

    // MARK: - /detect endpoint shape

    func testDetectResponseEncoding() {
        let response = LibreDetectResponse(items: [
            .init(language: "de", confidence: 97),
            .init(language: "en", confidence: 3)
        ])
        XCTAssertEqual(
            response.toJSON(),
            #"[{"confidence":97,"language":"de"},{"confidence":3,"language":"en"}]"#
        )
    }

    // MARK: - /languages endpoint shape

    func testLanguagesResponseEncoding() {
        let response = LibreLanguagesResponse(items: [
            .init(code: "en", name: "English", targets: ["de", "fr"])
        ])
        XCTAssertEqual(
            response.toJSON(),
            #"[{"code":"en","name":"English","targets":["de","fr"]}]"#
        )
    }
}
