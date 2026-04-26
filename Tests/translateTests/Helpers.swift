@preconcurrency import Foundation
@testable import translate

@available(macOS 26.0, *)
actor FakeTranslator: Translating {
    private(set) var prepareCalls = 0
    private(set) var translateCalls = 0

    func prepare(
        source: Locale.Language,
        target: Locale.Language,
        noInstall: Bool,
        quiet: Bool
    ) async throws {
        prepareCalls += 1
    }

    func translate(
        units: [String],
        source: Locale.Language,
        target: Locale.Language,
        preserveNewlines: Bool
    ) async throws -> [String] {
        translateCalls += 1
        return units.map { $0.uppercased() }
    }
}

final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func append(_ string: String) {
        lock.lock()
        storage.append(string)
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
