@preconcurrency import Foundation
import XCTest
@testable import translate

@available(macOS 26.0, *)
final class ModelsTests: XCTestCase {
    func testLanguagePairSpecRoundTrip() {
        let pair = LanguagePair(
            source: Locale.Language(identifier: "de"),
            target: Locale.Language(identifier: "en")
        )
        XCTAssertEqual(pair.spec, "de-en")
    }

    func testLanguagePairRegionalSpec() {
        // `Locale.Language.minimalIdentifier` strips region suffixes that aren't
        // strictly needed (e.g. "en-US" -> "en"), but keeps "de-AT" because the
        // Austrian variant is distinct from the German default.
        let pair = LanguagePair(
            source: Locale.Language(identifier: "de-AT"),
            target: Locale.Language(identifier: "en-US")
        )
        XCTAssertTrue(pair.spec.hasPrefix("de-AT-"))
        XCTAssertTrue(pair.spec.hasSuffix("-en") || pair.spec.hasSuffix("-en-US"))
    }

    func testRoundTripIfModelsInstalled() async throws {
        let manager = ModelManager(quiet: true)
        let de = Locale.Language(identifier: "de")
        let en = Locale.Language(identifier: "en")

        guard await manager.status(source: de, target: en) == .installed,
              await manager.status(source: en, target: de) == .installed else {
            throw XCTSkip("de-en and en-de models are not installed")
        }

        let translator = AppleTranslator()

        try await translator.prepare(source: de, target: en, noInstall: true, quiet: true)
        let english = try await translator.translate(
            units: ["Das ist ein fester Absatz für einen Round-Trip-Test."],
            source: de,
            target: en,
            preserveNewlines: true
        )

        try await translator.prepare(source: en, target: de, noInstall: true, quiet: true)
        let german = try await translator.translate(
            units: english,
            source: en,
            target: de,
            preserveNewlines: true
        )

        XCTAssertFalse(english[0].isEmpty)
        XCTAssertFalse(german[0].isEmpty)
        XCTAssertLessThan(german[0].count, 500)
    }

    func testBatchVsSingleIfModelInstalled() async throws {
        let manager = ModelManager(quiet: true)
        let de = Locale.Language(identifier: "de")
        let en = Locale.Language(identifier: "en")

        guard await manager.status(source: de, target: en) == .installed else {
            throw XCTSkip("de-en model is not installed")
        }

        let units = Array(repeating: "Hallo Welt.", count: 32)
        let translator = AppleTranslator()

        try await translator.prepare(source: de, target: en, noInstall: true, quiet: true)

        let singleClock = ContinuousClock()
        let singleStart = singleClock.now
        var single: [String] = []
        for unit in units {
            let result = try await translator.translate(
                units: [unit],
                source: de,
                target: en,
                preserveNewlines: true
            )
            single.append(result[0])
        }
        let singleDuration = singleStart.duration(to: singleClock.now)

        let batchClock = ContinuousClock()
        let batchStart = batchClock.now
        let batch = try await translator.translate(
            units: units,
            source: de,
            target: en,
            preserveNewlines: true
        )
        let batchDuration = batchStart.duration(to: batchClock.now)

        XCTAssertEqual(single, batch)

        let singleNanos = Double(singleDuration.components.seconds) * 1_000_000_000
            + Double(singleDuration.components.attoseconds) / 1_000_000_000
        let batchNanos = Double(batchDuration.components.seconds) * 1_000_000_000
            + Double(batchDuration.components.attoseconds) / 1_000_000_000

        XCTAssertLessThanOrEqual(batchNanos, singleNanos * 1.5)
    }

    func testMissingModelWithNoInstallThrowsExitFourIfMissing() async throws {
        let manager = ModelManager(quiet: true)
        let source = Locale.Language(identifier: "de")
        let target = Locale.Language(identifier: "ja")

        guard await manager.status(source: source, target: target) == .supported else {
            throw XCTSkip("de-ja is not a supported-but-missing model on this machine")
        }

        let translator = AppleTranslator()

        do {
            try await translator.prepare(source: source, target: target, noInstall: true, quiet: true)
            XCTFail("expected modelNotInstalled")
        } catch let error as TranslateError {
            XCTAssertEqual(error.exitCode, 4)
        }
    }
}
