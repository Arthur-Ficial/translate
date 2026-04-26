@preconcurrency import Foundation
import XCTest
@testable import translate

final class ErrorTests: XCTestCase {
    func testExitCodes() {
        XCTAssertEqual(TranslateError.usage("x").exitCode, 1)
        XCTAssertEqual(TranslateError.input("x").exitCode, 1)
        XCTAssertEqual(TranslateError.translationFailure("x").exitCode, 2)
        XCTAssertEqual(TranslateError.io("x").exitCode, 2)
        XCTAssertEqual(TranslateError.unsupportedOS.exitCode, 3)
        XCTAssertEqual(TranslateError.modelNotInstalled("de-en").exitCode, 4)
        XCTAssertEqual(TranslateError.unsupportedPair("de-zz").exitCode, 5)
    }

    func testDescriptionsArePrefixedWithToolName() {
        XCTAssertTrue(TranslateError.usage("foo").description.hasPrefix("translate: "))
        XCTAssertTrue(TranslateError.input("foo").description.hasPrefix("translate: "))
        XCTAssertTrue(TranslateError.translationFailure("oops").description.contains("translation failed"))
        XCTAssertTrue(TranslateError.unsupportedOS.description.contains("macOS 26"))
        XCTAssertTrue(TranslateError.modelNotInstalled("de-en").description.contains("--install"))
        XCTAssertTrue(TranslateError.unsupportedPair("de-zz").description.contains("--available"))
    }
}
