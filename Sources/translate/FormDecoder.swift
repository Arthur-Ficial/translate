@preconcurrency import Foundation

/// Minimal application/x-www-form-urlencoded parser. Preserves repeated
/// keys (DeepL and Google both use repeated `text` / `q` for batch).
public enum FormDecoder: Sendable {
    public static func parse(_ body: String) -> FormPairs {
        var pairs: [(String, String)] = []
        let segments = body.split(separator: "&", omittingEmptySubsequences: true)
        for segment in segments {
            let kv = segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard !kv.isEmpty else { continue }
            let key = decode(String(kv[0]))
            let value = kv.count > 1 ? decode(String(kv[1])) : ""
            pairs.append((key, value))
        }
        return FormPairs(pairs: pairs)
    }

    private static func decode(_ string: String) -> String {
        // Form encoding maps + to space; URL decoding does the rest.
        let pluses = string.replacingOccurrences(of: "+", with: " ")
        return pluses.removingPercentEncoding ?? pluses
    }
}

public struct FormPairs: Sendable {
    public let pairs: [(String, String)]

    public init(pairs: [(String, String)]) {
        self.pairs = pairs
    }

    public func values(for key: String) -> [String] {
        pairs.compactMap { $0.0 == key ? $0.1 : nil }
    }

    public func first(for key: String) -> String? {
        pairs.first { $0.0 == key }?.1
    }
}
