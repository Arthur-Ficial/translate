@preconcurrency import Foundation
import XCTest
@testable import translate

/// Real HTTP integration tests: spin up the actual translate server on a
/// random port, then drive every API surface (DeepL, LibreTranslate, Google,
/// /health, /v1/languages, /detect) with URLSession. These tests do NOT
/// require any installed Apple translation models because they use a
/// `FakeTranslator` that uppercases input.
@available(macOS 26.0, *)
final class ServerTests: XCTestCase {

    private var harness: ServerHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = try await ServerHarness.start()
    }

    override func tearDown() async throws {
        await harness?.stop()
        harness = nil
        try await super.tearDown()
    }

    // MARK: - /health

    func testHealthReturns200WithJSON() async throws {
        let (data, response) = try await harness.get("/health")
        XCTAssertEqual(response.statusCode, 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"ok\":true"))
    }

    func testHealthzAlias() async throws {
        let (_, response) = try await harness.get("/healthz")
        XCTAssertEqual(response.statusCode, 200)
    }

    // MARK: - DeepL

    func testDeepLSingleTranslate() async throws {
        let body = "text=Hallo&target_lang=EN&source_lang=DE"
        let (data, response) = try await harness.postForm(
            "/v2/translate",
            body: body
        )
        XCTAssertEqual(response.statusCode, 200)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(
            json,
            #"{"translations":[{"detected_source_language":"DE","text":"HALLO"}]}"#
        )
    }

    func testDeepLMultipleTexts() async throws {
        let body = "text=Hallo&text=Welt&target_lang=EN&source_lang=DE"
        let (data, response) = try await harness.postForm(
            "/v2/translate",
            body: body
        )
        XCTAssertEqual(response.statusCode, 200)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"text\":\"HALLO\""))
        XCTAssertTrue(json.contains("\"text\":\"WELT\""))
    }

    func testDeepLJSONBody() async throws {
        let body = #"{"text":["Hallo","Welt"],"target_lang":"EN","source_lang":"DE"}"#
        let (data, response) = try await harness.postJSON(
            "/v2/translate",
            body: Data(body.utf8)
        )
        XCTAssertEqual(response.statusCode, 200)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"text\":\"HALLO\""))
        XCTAssertTrue(json.contains("\"text\":\"WELT\""))
    }

    func testDeepLMissingTargetLangIs400() async throws {
        let (_, response) = try await harness.postForm(
            "/v2/translate",
            body: "text=Hallo"
        )
        XCTAssertEqual(response.statusCode, 400)
    }

    func testDeepLLanguagesEndpoint() async throws {
        let (data, response) = try await harness.get("/v2/languages")
        XCTAssertEqual(response.statusCode, 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        // Shape: array of {language, name}
        XCTAssertTrue(body.hasPrefix("["))
        XCTAssertTrue(body.contains("\"language\""))
        XCTAssertTrue(body.contains("\"name\""))
    }

    func testDeepLUsageEndpoint() async throws {
        let (data, response) = try await harness.get("/v2/usage")
        XCTAssertEqual(response.statusCode, 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("character_count"))
        XCTAssertTrue(body.contains("character_limit"))
    }

    // MARK: - LibreTranslate

    func testLibreSingleQ() async throws {
        let json = #"{"q":"Hallo","source":"de","target":"en","format":"text"}"#
        let (data, response) = try await harness.postJSON(
            "/translate",
            body: Data(json.utf8)
        )
        XCTAssertEqual(response.statusCode, 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(body, #"{"translatedText":"HALLO"}"#)
    }

    func testLibreArrayQ() async throws {
        let json = #"{"q":["Hallo","Welt"],"source":"de","target":"en"}"#
        let (data, response) = try await harness.postJSON(
            "/translate",
            body: Data(json.utf8)
        )
        XCTAssertEqual(response.statusCode, 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(body, #"{"translatedText":["HALLO","WELT"]}"#)
    }

    func testLibreAutoDetectIncludesDetectionField() async throws {
        let json = #"{"q":"Das ist ein deutscher Satz mit genug Worten.","source":"auto","target":"en"}"#
        let (data, response) = try await harness.postJSON(
            "/translate",
            body: Data(json.utf8)
        )
        XCTAssertEqual(response.statusCode, 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"detectedLanguage\""))
        XCTAssertTrue(body.contains("\"language\":\"de\""))
        XCTAssertTrue(body.contains("\"translatedText\":"))
    }

    func testLibreDetectEndpoint() async throws {
        let json = #"{"q":"Das ist ein deutscher Satz mit genug Worten."}"#
        let (data, response) = try await harness.postJSON(
            "/detect",
            body: Data(json.utf8)
        )
        XCTAssertEqual(response.statusCode, 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.hasPrefix("["))
        XCTAssertTrue(body.contains("\"language\":\"de\""))
        XCTAssertTrue(body.contains("\"confidence\""))
    }

    func testLibreLanguagesEndpoint() async throws {
        let (data, response) = try await harness.get("/languages")
        XCTAssertEqual(response.statusCode, 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.hasPrefix("["))
        XCTAssertTrue(body.contains("\"code\""))
        XCTAssertTrue(body.contains("\"name\""))
        XCTAssertTrue(body.contains("\"targets\""))
    }

    // MARK: - Google v2

    func testGoogleSingleQ() async throws {
        let body = "q=Hallo&target=en&source=de"
        let (data, response) = try await harness.postForm(
            "/language/translate/v2",
            body: body
        )
        XCTAssertEqual(response.statusCode, 200)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(
            json,
            #"{"data":{"translations":[{"detectedSourceLanguage":"de","translatedText":"HALLO"}]}}"#
        )
    }

    func testGoogleMultipleQ() async throws {
        let body = "q=Hallo&q=Welt&target=en&source=de"
        let (data, response) = try await harness.postForm(
            "/language/translate/v2",
            body: body
        )
        XCTAssertEqual(response.statusCode, 200)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"translatedText\":\"HALLO\""))
        XCTAssertTrue(json.contains("\"translatedText\":\"WELT\""))
    }

    func testGoogleJSONBody() async throws {
        let body = #"{"q":"Hallo","target":"en","source":"de"}"#
        let (data, response) = try await harness.postJSON(
            "/language/translate/v2",
            body: Data(body.utf8)
        )
        XCTAssertEqual(response.statusCode, 200)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"translatedText\":\"HALLO\""))
    }

    func testGoogleMissingTargetIs400() async throws {
        let (_, response) = try await harness.postForm(
            "/language/translate/v2",
            body: "q=Hallo"
        )
        XCTAssertEqual(response.statusCode, 400)
    }

    func testGoogleLanguagesEndpoint() async throws {
        let (data, response) = try await harness.get("/language/translate/v2/languages")
        XCTAssertEqual(response.statusCode, 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"data\""))
        XCTAssertTrue(body.contains("\"languages\""))
    }

    // MARK: - 404 + method-not-allowed

    func testUnknownPathReturns404() async throws {
        let (_, response) = try await harness.get("/nope")
        XCTAssertEqual(response.statusCode, 404)
    }
}
