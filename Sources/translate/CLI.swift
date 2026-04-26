@preconcurrency import ArgumentParser
@preconcurrency import Foundation
import Darwin

public struct TranslateCommand: AsyncParsableCommand, Sendable {
    public static let configuration = CommandConfiguration(
        commandName: "translate",
        abstract: "Fast on-device translation using Apple Translation.",
        discussion: """
        translate is a UNIX-style filter: it reads text from positional arguments,
        --file, or stdin; writes translated text to stdout; and writes errors or
        progress to stderr.
        """,
        version: "0.1.0"
    )

    @Option(name: .long, help: "Target language, as a BCP-47 identifier such as de, en, ja, or de-AT.")
    public var to: String?

    @Option(name: .long, help: "Source language. If omitted, NaturalLanguage detects it once from the input prefix.")
    public var from: String?

    @Flag(name: .long, help: "Print detected language code and confidence, then exit without translating.")
    public var detectOnly: Bool = false

    @Option(name: .long, help: "Output format: plain, json, or ndjson.")
    public var format: OutputFormat = .plain

    @Flag(name: .long, inversion: .prefixedNo, help: "Preserve newline structure. Enabled by default.")
    public var preserveNewlines: Bool = true

    @Flag(name: .long, help: "Treat each stdin line as an independent unit.")
    public var batch: Bool = false

    @Option(name: .customLong("file"), help: "Translate a UTF-8 file. Repeatable.")
    public var files: [String] = []

    @Option(name: .long, help: "Install/download a model pair such as de-en, de-AT-en, or pt-BR-en-US.")
    public var install: String?

    @Flag(name: .long, help: "List installed language pairs and exit.")
    public var installed: Bool = false

    @Flag(name: .long, help: "List supported language pairs and exit.")
    public var available: Bool = false

    @Flag(name: .customLong("no-install"), help: "Fail if the model is missing instead of preparing/downloading it.")
    public var noInstall: Bool = false

    @Option(name: .long, help: "Comma-separated language hints for short input detection, for example de,en,fr.")
    public var langs: String?

    @Flag(name: .long, help: "Suppress progress messages on stderr. Errors still print.")
    public var quiet: Bool = false

    @Flag(name: .long, help: "Run as an HTTP server exposing DeepL, LibreTranslate, and Google v2 compatible endpoints.")
    public var serve: Bool = false

    @Option(name: .long, help: "TCP port for --serve. Default: 8989.")
    public var port: Int = 8989

    @Option(name: .long, help: "Bind address for --serve. Default: 127.0.0.1.")
    public var host: String = "127.0.0.1"

    @Option(name: .long, help: "Optional API key required by clients. If unset, the server accepts any caller.")
    public var apiKey: String?

    @Argument(help: "Text arguments. If provided, each argument is translated and emitted on its own output line.")
    public var text: [String] = []

    public init() {}

    public mutating func run() async throws {
        guard #available(macOS 26.0, *) else {
            throw TranslateError.unsupportedOS
        }

        let manager = ModelManager(quiet: quiet)

        if serve {
            let server = TranslateServer(
                translator: AppleTranslator(),
                detector: LanguageDetector(hints: LanguageList.parse(langs)),
                host: host,
                port: port,
                apiKey: apiKey
            )
            if !quiet {
                Stdio.stderr("translate: serving on http://\(host):\(port)\n")
            }
            try await server.run()
            return
        }

        if let pair = install {
            try await manager.install(pairSpec: pair)
            return
        }

        if installed {
            try await manager.printInstalledPairs()
            return
        }

        if available {
            try await manager.printAvailablePairs()
            return
        }

        let options = CLIOptions(
            to: to,
            from: from,
            detectOnly: detectOnly,
            format: format,
            preserveNewlines: preserveNewlines,
            batch: batch,
            files: files,
            noInstall: noInstall,
            langs: LanguageList.parse(langs),
            quiet: quiet,
            text: text
        )

        let runner = TranslateRunner(translator: AppleTranslator())
        try await runner.run(options)
    }
}

public struct CLIOptions: Sendable {
    public let to: String?
    public let from: String?
    public let detectOnly: Bool
    public let format: OutputFormat
    public let preserveNewlines: Bool
    public let batch: Bool
    public let files: [String]
    public let noInstall: Bool
    public let langs: [String]
    public let quiet: Bool
    public let text: [String]

    public init(
        to: String?,
        from: String?,
        detectOnly: Bool,
        format: OutputFormat,
        preserveNewlines: Bool,
        batch: Bool,
        files: [String],
        noInstall: Bool,
        langs: [String],
        quiet: Bool,
        text: [String]
    ) {
        self.to = to
        self.from = from
        self.detectOnly = detectOnly
        self.format = format
        self.preserveNewlines = preserveNewlines
        self.batch = batch
        self.files = files
        self.noInstall = noInstall
        self.langs = langs
        self.quiet = quiet
        self.text = text
    }
}

public enum LanguageList: Sendable {
    public static func parse(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

@available(macOS 26.0, *)
public struct TranslateRunner: Sendable {
    public let translator: any Translating

    public init(translator: any Translating) {
        self.translator = translator
    }

    public func run(_ options: CLIOptions) async throws {
        if options.detectOnly {
            try await runDetectOnly(options)
            return
        }

        guard let targetCode = options.to, !targetCode.isEmpty else {
            throw TranslateError.usage("--to is required unless --detect-only, --install, --installed, or --available is used")
        }

        if !options.text.isEmpty {
            try await runTextArguments(options, targetCode: targetCode)
            return
        }

        let writer = OutputWriter(format: options.format)

        if !options.files.isEmpty {
            for path in options.files {
                let url = URL(fileURLWithPath: path)
                let handle: FileHandle
                do {
                    handle = try FileHandle(forReadingFrom: url)
                } catch {
                    throw TranslateError.input("could not open \(path): \(error.localizedDescription)")
                }

                defer {
                    try? handle.close()
                }

                try await StreamProcessor().process(
                    handle: handle,
                    sourceOverride: options.from,
                    targetCode: targetCode,
                    hints: options.langs,
                    translator: translator,
                    writer: writer,
                    noInstall: options.noInstall,
                    quiet: options.quiet,
                    preserveNewlines: options.preserveNewlines,
                    batch: options.batch
                )
            }

            writer.finish()
            return
        }

        guard isatty(STDIN_FILENO) == 0 else {
            throw TranslateError.usage("no input: pass text arguments, use --file, or pipe UTF-8 text on stdin")
        }

        try await StreamProcessor().process(
            handle: FileHandle.standardInput,
            sourceOverride: options.from,
            targetCode: targetCode,
            hints: options.langs,
            translator: translator,
            writer: writer,
            noInstall: options.noInstall,
            quiet: options.quiet,
            preserveNewlines: options.preserveNewlines,
            batch: options.batch
        )
        writer.finish()
    }

    private func runTextArguments(_ options: CLIOptions, targetCode: String) async throws {
        let target = Locale.Language(identifier: targetCode)
        let detection: DetectionResult

        if let sourceCode = options.from, !sourceCode.isEmpty {
            detection = DetectionResult(
                languageCode: Locale.Language(identifier: sourceCode).minimalIdentifier,
                confidence: 1.0
            )
        } else {
            let joined = options.text.joined(separator: "\n")
            detection = try LanguageDetector(hints: options.langs).detect(in: joined)
        }

        let source = Locale.Language(identifier: detection.languageCode)

        try await translator.prepare(
            source: source,
            target: target,
            noInstall: options.noInstall,
            quiet: options.quiet
        )

        let translated = try await translator.translate(
            units: options.text,
            source: source,
            target: target,
            preserveNewlines: options.preserveNewlines
        )

        let records = zip(options.text, translated).map { src, dst in
            TranslationRecord(
                from: source.minimalIdentifier,
                to: target.minimalIdentifier,
                src: src,
                dst: dst,
                conf: detection.confidence
            )
        }

        OutputRenderer.writeRecords(records, format: options.format, plainTrailingNewline: true)
    }

    private func runDetectOnly(_ options: CLIOptions) async throws {
        let detector = LanguageDetector(hints: options.langs)

        if !options.text.isEmpty {
            let result = try detector.detect(in: options.text.joined(separator: "\n"))
            Stdio.stdout("\(result.languageCode)\t\(StableJSON.formatNumber(result.confidence))\n")
            return
        }

        if !options.files.isEmpty {
            for path in options.files {
                let sample = try readDetectionPrefix(path: path)
                let result = try detector.detect(in: sample)
                Stdio.stdout("\(result.languageCode)\t\(StableJSON.formatNumber(result.confidence))\n")
            }
            return
        }

        guard isatty(STDIN_FILENO) == 0 else {
            throw TranslateError.usage("--detect-only needs text arguments, --file, or piped stdin")
        }

        let data = try FileHandle.standardInput.read(upToCount: 4096) ?? Data()
        guard !data.isEmpty else {
            throw TranslateError.input("empty stdin; nothing to detect")
        }

        guard let sample = String(data: data, encoding: .utf8) else {
            throw TranslateError.input("stdin is not valid UTF-8")
        }

        let result = try detector.detect(in: sample)
        Stdio.stdout("\(result.languageCode)\t\(StableJSON.formatNumber(result.confidence))\n")
    }

    private func readDetectionPrefix(path: String) throws -> String {
        let url = URL(fileURLWithPath: path)

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw TranslateError.input("could not open \(path): \(error.localizedDescription)")
        }

        defer {
            try? handle.close()
        }

        let data = try handle.read(upToCount: 4096) ?? Data()
        guard !data.isEmpty else {
            throw TranslateError.input("\(path) is empty; nothing to detect")
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw TranslateError.input("\(path) is not valid UTF-8")
        }

        return text
    }
}
