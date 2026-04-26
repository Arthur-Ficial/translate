@preconcurrency import ArgumentParser
@preconcurrency import Foundation
import Darwin

public enum OutputFormat: String, ExpressibleByArgument, Sendable {
    case plain
    case json
    case ndjson

    public init?(argument: String) {
        self.init(rawValue: argument)
    }
}

public struct TranslationRecord: Sendable, Equatable {
    public let from: String
    public let to: String
    public let src: String
    public let dst: String
    public let conf: Double

    public init(from: String, to: String, src: String, dst: String, conf: Double) {
        self.from = from
        self.to = to
        self.src = src
        self.dst = dst
        self.conf = conf
    }
}

public typealias OutputSink = @Sendable (String) -> Void

public enum Stdio: Sendable {
    public static func stdout(_ string: String) {
        FileHandle.standardOutput.write(Data(string.utf8))
        fflush(Darwin.stdout)
    }

    public static func stderr(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
        fflush(Darwin.stderr)
    }
}

public final class OutputWriter: @unchecked Sendable {
    private let format: OutputFormat
    private let sink: OutputSink
    private var jsonStarted = false
    private var jsonCount = 0

    public init(format: OutputFormat, sink: @escaping OutputSink = Stdio.stdout) {
        self.format = format
        self.sink = sink
    }

    public func write(record: TranslationRecord) {
        switch format {
        case .plain:
            sink(record.dst)

        case .ndjson:
            sink(StableJSON.object(record) + "\n")

        case .json:
            if !jsonStarted {
                sink("[")
                jsonStarted = true
            }

            if jsonCount > 0 {
                sink(",")
            }

            sink(StableJSON.object(record))
            jsonCount += 1
        }
    }

    public func writeLiteral(_ literal: String) {
        guard format == .plain else { return }
        sink(literal)
    }

    public func finish() {
        guard format == .json else { return }

        if jsonStarted {
            sink("]\n")
        } else {
            sink("[]\n")
        }

        jsonStarted = false
        jsonCount = 0
    }
}

public enum OutputRenderer: Sendable {
    public static func writeRecords(
        _ records: [TranslationRecord],
        format: OutputFormat,
        plainTrailingNewline: Bool
    ) {
        switch format {
        case .plain:
            for record in records {
                Stdio.stdout(record.dst)
                if plainTrailingNewline {
                    Stdio.stdout("\n")
                }
            }

        case .ndjson:
            for record in records {
                Stdio.stdout(StableJSON.object(record) + "\n")
            }

        case .json:
            if records.count == 1, let record = records.first {
                Stdio.stdout(StableJSON.object(record) + "\n")
            } else {
                let body = records.map(StableJSON.object).joined(separator: ",")
                Stdio.stdout("[\(body)]\n")
            }
        }
    }
}

public enum StableJSON: Sendable {
    public static func object(_ record: TranslationRecord) -> String {
        """
        {"from":\(string(record.from)),"to":\(string(record.to)),"src":\(string(record.src)),"dst":\(string(record.dst)),"conf":\(formatNumber(record.conf))}
        """
    }

    public static func string(_ value: String) -> String {
        var output = "\""

        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22:
                output += "\\\""
            case 0x5C:
                output += "\\\\"
            case 0x08:
                output += "\\b"
            case 0x0C:
                output += "\\f"
            case 0x0A:
                output += "\\n"
            case 0x0D:
                output += "\\r"
            case 0x09:
                output += "\\t"
            case 0x00...0x1F:
                output += String(
                    format: "\\u%04X",
                    locale: Locale(identifier: "en_US_POSIX"),
                    scalar.value
                )
            default:
                output += String(scalar)
            }
        }

        output += "\""
        return output
    }

    public static func formatNumber(_ value: Double) -> String {
        guard value.isFinite else {
            return "null"
        }

        var formatted = String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )

        while formatted.contains(".") && formatted.last == "0" {
            formatted.removeLast()
        }

        if formatted.last == "." {
            formatted.removeLast()
        }

        return formatted
    }
}
