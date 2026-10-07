@preconcurrency import ArgumentParser
@preconcurrency import Foundation
@preconcurrency import FoundationModels
@preconcurrency import Translation

@available(macOS 26.0, *)
public enum PairStatus: String, Sendable {
    case installed
    case supported
    case unsupported
}

@available(macOS 26.0, *)
public struct LanguagePair: Sendable, Equatable {
    public let source: Locale.Language
    public let target: Locale.Language

    public var spec: String {
        "\(source.minimalIdentifier)-\(target.minimalIdentifier)"
    }

    public init(source: Locale.Language, target: Locale.Language) {
        self.source = source
        self.target = target
    }
}

/// Translation strategy selector. `low` is the deterministic lowLatency path
/// and the default; `high` opts into Apple Intelligence highFidelity
/// (macOS 26.4+), which is slower and not guaranteed byte-stable.
public enum Quality: String, ExpressibleByArgument, CaseIterable, Sendable {
    case low
    case high

    public init?(argument: String) {
        self.init(rawValue: argument)
    }
}

@available(macOS 26.0, *)
public struct ModelManager: Sendable {
    public let quiet: Bool
    public let quality: Quality

    public init(quiet: Bool = false, quality: Quality = .low) {
        self.quiet = quiet
        self.quality = quality
    }

    public func status(source: Locale.Language, target: Locale.Language) async -> PairStatus {
        let availability = TranslationSupport.availability(quality: quality)
        let status = await availability.status(from: source, to: target)

        switch status {
        case .installed:
            return .installed
        case .supported:
            return .supported
        case .unsupported:
            return .unsupported
        @unknown default:
            return .unsupported
        }
    }

    public func prepare(source: Locale.Language, target: Locale.Language) async throws {
        let session = TranslationSupport.installedSession(source: source, target: target, quality: quality)
        try await session.prepareTranslation()

        let after = await status(source: source, target: target)
        guard after == .installed else {
            throw TranslateError.translationFailure(
                "model preparation completed but \(source.minimalIdentifier)-\(target.minimalIdentifier) is not installed"
            )
        }
    }

    public func install(pairSpec: String) async throws {
        let pair = try await parsePair(pairSpec)

        switch await status(source: pair.source, target: pair.target) {
        case .installed:
            if !quiet {
                Stdio.stderr("translate: \(pair.spec) already installed\n")
            }

        case .supported:
            if !quiet {
                Stdio.stderr("translate: installing \(pair.spec)\n")
            }
            try await prepare(source: pair.source, target: pair.target)

        case .unsupported:
            throw TranslateError.unsupportedPair(pair.spec)
        }
    }

    public func printInstalledPairs() async throws {
        let pairs = await allPairs(includeSupported: false)
        for pair in pairs {
            Stdio.stdout(pair + "\n")
        }
    }

    public func printAvailablePairs() async throws {
        let pairs = await allPairs(includeSupported: true)
        for pair in pairs {
            Stdio.stdout(pair + "\n")
        }
    }

    private func allPairs(includeSupported: Bool) async -> [String] {
        let availability = TranslationSupport.availability(quality: quality)
        let languages = await availability.supportedLanguages

        var output: [String] = []

        for source in languages {
            for target in languages where source != target {
                let status = await availability.status(from: source, to: target)

                switch status {
                case .installed:
                    output.append("\(source.minimalIdentifier)-\(target.minimalIdentifier)")

                case .supported:
                    if includeSupported {
                        output.append("\(source.minimalIdentifier)-\(target.minimalIdentifier)")
                    }

                case .unsupported:
                    continue

                @unknown default:
                    continue
                }
            }
        }

        return output.sorted()
    }

    private func parsePair(_ spec: String) async throws -> LanguagePair {
        let parts = spec.split(separator: "-").map(String.init)
        guard parts.count >= 2 else {
            throw TranslateError.usage("--install expects a pair like de-en")
        }

        var fallback: LanguagePair?

        for split in 1..<parts.count {
            let sourceCode = parts[..<split].joined(separator: "-")
            let targetCode = parts[split...].joined(separator: "-")

            let pair = LanguagePair(
                source: Locale.Language(identifier: sourceCode),
                target: Locale.Language(identifier: targetCode)
            )

            if fallback == nil {
                fallback = pair
            }

            let pairStatus = await status(source: pair.source, target: pair.target)
            if pairStatus != .unsupported {
                return pair
            }
        }

        if let fallback {
            return fallback
        }

        throw TranslateError.usage("--install expects a pair like de-en")
    }
}

@available(macOS 26.0, *)
public enum TranslationSupport: Sendable {
    @available(macOS 26.4, *)
    public static func strategy(for quality: Quality) -> TranslationSession.Strategy {
        switch quality {
        case .low:
            return .lowLatency
        case .high:
            return .highFidelity
        }
    }

    public static func availability(quality: Quality = .low) -> LanguageAvailability {
        if #available(macOS 26.4, *) {
            return LanguageAvailability(preferredStrategy: strategy(for: quality))
        } else {
            return LanguageAvailability()
        }
    }

    public static func configuration(
        source: Locale.Language,
        target: Locale.Language,
        quality: Quality = .low
    ) -> TranslationSession.Configuration {
        if #available(macOS 26.4, *) {
            return TranslationSession.Configuration(
                source: source,
                target: target,
                preferredStrategy: strategy(for: quality)
            )
        } else {
            return TranslationSession.Configuration(source: source, target: target)
        }
    }

    public static func installedSession(
        source: Locale.Language,
        target: Locale.Language,
        quality: Quality = .low
    ) -> TranslationSession {
        if #available(macOS 26.4, *) {
            return TranslationSession(
                installedSource: source,
                target: target,
                preferredStrategy: strategy(for: quality)
            )
        } else {
            return TranslationSession(installedSource: source, target: target)
        }
    }

    /// Reasons `--quality high` will silently run the lowLatency models
    /// instead. Apple's API gives no signal for this, so we check the
    /// preconditions ourselves and warn on stderr. Empty means no known
    /// reason to fall back.
    public static func highFidelityFallbackReason() -> String? {
        guard #available(macOS 26.4, *) else {
            return "highFidelity needs macOS 26.4 or newer"
        }

        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is not enabled"
        case .unavailable(.deviceNotEligible):
            return "this Mac is not eligible for Apple Intelligence"
        case .unavailable(.modelNotReady):
            return "Apple Intelligence models are not ready yet"
        case .unavailable:
            return "Apple Intelligence is unavailable"
        }
    }
}
