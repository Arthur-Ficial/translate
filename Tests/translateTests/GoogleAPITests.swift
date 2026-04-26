@preconcurrency import Foundation
import XCTest
@testable import translate

final class GoogleAPITests: XCTestCase {

    // MARK: - Form decode

    func testFormDecodeSingleText() throws {
        let body = "q=Hallo&target=en&source=de&format=text"
        let request = try GoogleRequest.fromForm(body)
        XCTAssertEqual(request.qs, ["Hallo"])
        XCTAssertEqual(request.target, "en")
        XCTAssertEqual(request.source, "de")
    }

    func testFormDecodeMultipleQ() throws {
        let body = "q=Hallo&q=Welt&q=Foo&target=en"
        let request = try GoogleRequest.fromForm(body)
        XCTAssertEqual(request.qs, ["Hallo", "Welt", "Foo"])
    }

    // MARK: - JSON decode

    func testJSONDecodeArrayQ() throws {
        let json = #"{"q":["a","b"],"target":"en","source":"de"}"#
        let request = try GoogleRequest.fromJSON(Data(json.utf8))
        XCTAssertEqual(request.qs, ["a", "b"])
        XCTAssertEqual(request.target, "en")
        XCTAssertEqual(request.source, "de")
    }

    func testJSONDecodeStringQ() throws {
        let json = #"{"q":"Hallo","target":"en"}"#
        let request = try GoogleRequest.fromJSON(Data(json.utf8))
        XCTAssertEqual(request.qs, ["Hallo"])
    }

    func testFormDecodeRejectsMissingTarget() {
        XCTAssertThrowsError(try GoogleRequest.fromForm("q=Hallo"))
    }

    // MARK: - Response shape

    func testResponseEncoderShape() {
        let payload = GoogleResponse(translations: [
            .init(translatedText: "Hello", detectedSourceLanguage: "de"),
            .init(translatedText: "World", detectedSourceLanguage: "de")
        ])
        XCTAssertEqual(
            payload.toJSON(),
            #"{"data":{"translations":[{"detectedSourceLanguage":"de","translatedText":"Hello"},{"detectedSourceLanguage":"de","translatedText":"World"}]}}"#
        )
    }

    func testResponseEncoderOmitsDetectedSourceWhenNil() {
        let payload = GoogleResponse(translations: [
            .init(translatedText: "Hello", detectedSourceLanguage: nil)
        ])
        XCTAssertEqual(
            payload.toJSON(),
            #"{"data":{"translations":[{"translatedText":"Hello"}]}}"#
        )
    }
}
