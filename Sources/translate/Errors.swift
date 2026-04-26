@preconcurrency import Foundation

public enum TranslateError: Error, CustomStringConvertible, Sendable {
    case usage(String)
    case input(String)
    case translationFailure(String)
    case unsupportedOS
    case modelNotInstalled(String)
    case unsupportedPair(String)
    case io(String)

    public var exitCode: Int32 {
        switch self {
        case .usage, .input:
            return 1
        case .translationFailure, .io:
            return 2
        case .unsupportedOS:
            return 3
        case .modelNotInstalled:
            return 4
        case .unsupportedPair:
            return 5
        }
    }

    public var description: String {
        switch self {
        case let .usage(message):
            return "translate: \(message)"
        case let .input(message):
            return "translate: \(message)"
        case let .translationFailure(message):
            return "translate: translation failed: \(message)"
        case .unsupportedOS:
            return "translate: unsupported OS: macOS 26 Tahoe or newer is required"
        case let .modelNotInstalled(pair):
            return "translate: model for \(pair) is not installed; run `translate --install \(pair)` or omit --no-install"
        case let .unsupportedPair(pair):
            return "translate: unsupported language pair \(pair); run `translate --available`"
        case let .io(message):
            return "translate: I/O error: \(message)"
        }
    }
}
