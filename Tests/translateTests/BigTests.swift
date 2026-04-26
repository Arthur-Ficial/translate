@preconcurrency import Foundation
import XCTest
@testable import translate

/// Heavy / stress / multi-language coverage. Spec demands tests that hold up
/// to large inputs, many language pairs, and adversarial masker content.
@available(macOS 26.0, *)
final class BigTests: XCTestCase {

    // MARK: - Detection across many languages

    func testDetectionAcrossManyLanguages() throws {
        let detector = LanguageDetector()
        let samples: [(prefix: String, sample: String)] = [
            ("de", "Das ist ein deutscher Satz mit mehr als zwanzig Zeichen."),
            ("en", "This is an English sentence with plenty of words."),
            ("fr", "Ceci est une phrase française avec plusieurs mots clairs."),
            ("es", "Este es un texto en español con suficientes palabras."),
            ("it", "Questa è una frase italiana con abbastanza parole."),
            ("pt", "Este é um texto em português com palavras suficientes."),
            ("nl", "Dit is een Nederlandse zin met genoeg woorden."),
            ("pl", "To jest zdanie po polsku z wystarczającą liczbą słów."),
            ("ru", "Это предложение на русском языке с достаточным количеством слов."),
            ("ja", "これは日本語の文章で、翻訳テストのために十分な長さがあります。"),
            ("ko", "이것은 한국어 문장이며 번역 테스트를 위해 충분히 깁니다."),
            ("zh", "这是一个用于翻译测试的中文句子，有足够的字符数量。"),
            ("ar", "هذه جملة باللغة العربية تحتوي على عدد كافٍ من الكلمات."),
            ("hi", "यह हिन्दी का वाक्य है जिसमें पर्याप्त शब्द हैं।"),
            ("th", "นี่คือประโยคภาษาไทยที่มีคำเพียงพอสำหรับการทดสอบ"),
            ("tr", "Bu yeterince kelime içeren bir Türkçe cümledir."),
            ("uk", "Це речення українською мовою з достатньою кількістю слів."),
            ("vi", "Đây là một câu tiếng Việt với đủ số lượng từ để kiểm tra.")
        ]

        var detected = 0
        for (expected, sample) in samples {
            let result = try detector.detect(in: sample)
            if result.languageCode.prefix(2) == expected[expected.startIndex..<expected.index(expected.startIndex, offsetBy: 2)] {
                detected += 1
            } else {
                XCTFail("expected \(expected) but got \(result.languageCode) for: \(sample.prefix(30))")
            }
        }
        XCTAssertEqual(detected, samples.count)
    }

    // MARK: - LanguagePair specs over many regions and scripts

    func testLanguagePairSpecsForCommonPairs() {
        // macOS's `Locale.Language.minimalIdentifier` normalizes BCP-47 by
        // dropping defaults: e.g. `zh-Hans` -> `zh`, `pt-BR` -> `pt`,
        // `en-US` -> `en`. We match that reality, not idealized BCP-47.
        let pairs: [(String, String, String)] = [
            ("de", "en", "de-en"),
            ("en", "de", "en-de"),
            ("ja", "en", "ja-en"),
            ("zh-Hans", "en", "zh-en"),
            ("zh-Hant", "en", "zh-TW-en"),
            ("pt-BR", "en", "pt-en"),
            ("pt-PT", "en", "pt-PT-en"),
            ("es-MX", "en", "es-MX-en"),
            ("ar", "en", "ar-en"),
            ("ko", "en", "ko-en"),
            ("ru", "en", "ru-en")
        ]
        for (src, tgt, expected) in pairs {
            let pair = LanguagePair(
                source: Locale.Language(identifier: src),
                target: Locale.Language(identifier: tgt)
            )
            XCTAssertEqual(pair.spec, expected, "\(src) -> \(tgt)")
        }
    }

    // MARK: - Masker stress: many tokens, mixed protected spans

    func testMaskerHandlesManyMixedTokensInOneInput() {
        let input = """
        Hallo Welt, see https://example.com/path?q=1 and `code` and a@b.com.
        Then ```swift
        let answer = 42
        ```
        finally inline `x` plus another https://foo.bar/baz#frag and root@host.tld.
        """

        let segments = TranslationMasker.segments(in: input, preserveNewlines: true)

        // Round-trip lossless reassembly.
        XCTAssertEqual(segments.map(\.text).joined(), input)

        // Every URL, email, backtick span, and fence is present and protected.
        let protected = segments.filter { !$0.isTranslatable }.map(\.text)
        XCTAssertTrue(protected.contains(where: { $0 == "https://example.com/path?q=1" }))
        XCTAssertTrue(protected.contains(where: { $0 == "`code`" }))
        XCTAssertTrue(protected.contains(where: { $0 == "a@b.com" }))
        XCTAssertTrue(protected.contains(where: { $0.contains("```swift") && $0.contains("```") }))
        XCTAssertTrue(protected.contains(where: { $0 == "`x`" }))
        XCTAssertTrue(protected.contains(where: { $0 == "https://foo.bar/baz#frag" }))
        XCTAssertTrue(protected.contains(where: { $0 == "root@host.tld" }))
    }

    func testMaskerWithThousandTokensInLine() {
        // Build a synthetic input with 500 `token` spans interleaved with text.
        var pieces: [String] = []
        for index in 0..<500 {
            pieces.append("word\(index) `tag\(index)`")
        }
        let input = pieces.joined(separator: " ")

        let segments = TranslationMasker.segments(in: input, preserveNewlines: true)
        let backtickCount = segments.filter { !$0.isTranslatable && $0.text.first == "`" }.count
        XCTAssertEqual(backtickCount, 500)

        // Lossless reassembly.
        XCTAssertEqual(segments.map(\.text).joined(), input)
    }

    // MARK: - JSON robustness: many escapes, surrogates, control chars

    func testStableJSONStringSurvivesEveryControlCodepoint() {
        for codepoint in 0..<0x20 {
            let scalar = Unicode.Scalar(codepoint)!
            let input = String(scalar)
            let output = StableJSON.string(input)
            XCTAssertTrue(output.hasPrefix("\""))
            XCTAssertTrue(output.hasSuffix("\""))
            // Either short escape (\b \f \n \r \t) or \uXXXX form.
            let inner = String(output.dropFirst().dropLast())
            XCTAssertTrue(inner.hasPrefix("\\"), "control \(codepoint) must be escaped, got: \(inner)")
        }
    }

    func testStableJSONStringSupportsSupplementaryPlane() {
        // Emoji 🌍 (U+1F30D) is in supplementary plane and must round-trip as-is.
        let earth = "🌍 العالم 你好"
        XCTAssertEqual(StableJSON.string(earth), "\"\(earth)\"")
    }

    func testStableJSONNumberPrecision() {
        XCTAssertEqual(StableJSON.formatNumber(0.0), "0")
        XCTAssertEqual(StableJSON.formatNumber(-0.5), "-0.5")
        XCTAssertEqual(StableJSON.formatNumber(1.234567), "1.234567")
        XCTAssertEqual(StableJSON.formatNumber(100.0), "100")
        XCTAssertEqual(StableJSON.formatNumber(0.000001), "0.000001")
        // Below printf precision => rounds to "0".
        XCTAssertEqual(StableJSON.formatNumber(0.00000001), "0")
    }

    // MARK: - UTF-8 streaming with very long, scalar-split input

    func testUTF8StreamDecoderLargeInputWithMultiByteScalars() throws {
        var decoder = UTF8StreamDecoder()
        let big = String(repeating: "Hallo Welt 🌍 العالم 你好。", count: 100)
        let bytes = Array(big.utf8)

        // Feed in 7-byte chunks (often splits multi-byte scalars).
        var rebuilt = ""
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 7, bytes.count)
            let chunk = Data(bytes[offset..<end])
            rebuilt += try decoder.decode(chunk)
            offset = end
        }
        rebuilt += try decoder.finish()
        XCTAssertEqual(rebuilt, big)
    }

    // MARK: - Streaming pipeline: paragraphs + ndjson + many records

    func testStreamingNDJSONOver100Paragraphs() async throws {
        let count = 100
        let body = (0..<count).map { "para\($0) text body" }.joined(separator: "\n\n")

        let input = Pipe()
        let capture = LockedBuffer()
        let writer = OutputWriter(format: .ndjson) { capture.append($0) }
        let processor = StreamProcessor(chunkSize: 256)
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
        input.fileHandleForWriting.write(Data(body.utf8))
        try input.fileHandleForWriting.close()
        try await task.value

        let lines = capture.value.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, count)
        XCTAssertTrue(capture.value.contains("\"src\":\"para0 text body\""))
        XCTAssertTrue(capture.value.contains("\"src\":\"para99 text body\""))
    }

    func testStreamingBatchOver500ShortLines() async throws {
        let count = 500
        let body = (0..<count).map { "line\($0)" }.joined(separator: "\n") + "\n"

        let input = Pipe()
        let capture = LockedBuffer()
        let writer = OutputWriter(format: .plain) { capture.append($0) }
        let processor = StreamProcessor(chunkSize: 1024)
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
        input.fileHandleForWriting.write(Data(body.utf8))
        try input.fileHandleForWriting.close()
        try await task.value

        // Every original line gets uppercased by FakeTranslator, plus a
        // literal "\n" separator after each.
        XCTAssertTrue(capture.value.contains("LINE0"))
        XCTAssertTrue(capture.value.contains("LINE499"))
        let nlCount = capture.value.filter { $0 == "\n" }.count
        XCTAssertEqual(nlCount, count)
    }

    // MARK: - Masker preserves and protects spans across the full pipeline

    func testMaskerSegmentsTransparentToReassembly() {
        let inputs = [
            "Click https://x.io and email a@b.io and run `ls`.",
            "Mix ```fenced\nwith\ncontent\n``` and `inline` and a@x.com.",
            "Just plain text with no protected tokens.",
            "Many tokens: `a` `b` `c` https://1 https://2 https://3 e@f.g h@i.j",
        ]
        for input in inputs {
            let segments = TranslationMasker.segments(in: input, preserveNewlines: true)
            XCTAssertEqual(segments.map(\.text).joined(), input,
                           "lossless reassembly for: \(input)")
            // Protected spans must contain only protected tokens.
            for segment in segments where !segment.isTranslatable {
                let body = segment.text
                let isUrl = body.contains("://") || body.hasPrefix("www.")
                let isEmail = body.contains("@") && body.contains(".")
                let isCode = body.contains("`")
                let isNewline = body.allSatisfy { $0.isNewline }
                let isEmpty = body.isEmpty
                XCTAssertTrue(isUrl || isEmail || isCode || isNewline || isEmpty,
                              "non-translatable but not a known protected span: \(body)")
            }
        }
    }

    // MARK: - Round-trip on real Apple translator (requires installed pairs)

    func testRoundTripDeEnEnDeIfInstalled() async throws {
        let manager = ModelManager(quiet: true)
        let de = Locale.Language(identifier: "de")
        let en = Locale.Language(identifier: "en")

        guard await manager.status(source: de, target: en) == .installed,
              await manager.status(source: en, target: de) == .installed else {
            throw XCTSkip("de-en + en-de not installed")
        }

        let translator = AppleTranslator()
        try await translator.prepare(source: de, target: en, noInstall: true, quiet: true)
        let mid = try await translator.translate(
            units: ["Das ist ein einfacher Satz für einen Round-Trip-Test."],
            source: de,
            target: en,
            preserveNewlines: true
        )
        XCTAssertFalse(mid[0].isEmpty)

        try await translator.prepare(source: en, target: de, noInstall: true, quiet: true)
        let back = try await translator.translate(
            units: mid,
            source: en,
            target: de,
            preserveNewlines: true
        )
        XCTAssertFalse(back[0].isEmpty)
    }

    func testRoundTripFrEnIfInstalled() async throws {
        let manager = ModelManager(quiet: true)
        let fr = Locale.Language(identifier: "fr")
        let en = Locale.Language(identifier: "en")

        guard await manager.status(source: fr, target: en) == .installed else {
            throw XCTSkip("fr-en not installed")
        }
        let translator = AppleTranslator()
        try await translator.prepare(source: fr, target: en, noInstall: true, quiet: true)
        let result = try await translator.translate(
            units: ["Bonjour le monde, comment ça va aujourd'hui ?"],
            source: fr,
            target: en,
            preserveNewlines: true
        )
        XCTAssertFalse(result[0].isEmpty)
    }

    func testRoundTripJaEnIfInstalled() async throws {
        let manager = ModelManager(quiet: true)
        let ja = Locale.Language(identifier: "ja")
        let en = Locale.Language(identifier: "en")

        guard await manager.status(source: ja, target: en) == .installed else {
            throw XCTSkip("ja-en not installed")
        }
        let translator = AppleTranslator()
        try await translator.prepare(source: ja, target: en, noInstall: true, quiet: true)
        let result = try await translator.translate(
            units: ["これは翻訳のテストです。"],
            source: ja,
            target: en,
            preserveNewlines: true
        )
        XCTAssertFalse(result[0].isEmpty)
    }
}
