@preconcurrency import Foundation
@testable import translate

/// Brings up a real translate HTTP server on a random free port for
/// integration tests. Uses URLSession for client requests so we exercise the
/// actual TCP loopback path, not in-process fakes.
@available(macOS 26.0, *)
final class ServerHarness: @unchecked Sendable {
    private let server: TranslateServer
    private let task: Task<Void, Error>
    let port: Int

    private init(server: TranslateServer, task: Task<Void, Error>, port: Int) {
        self.server = server
        self.task = task
        self.port = port
    }

    static func start() async throws -> ServerHarness {
        let translator = FakeTranslator()
        let detector = LanguageDetector()

        // Probe a free TCP port via a temporary BSD socket. We then close the
        // socket and pass the number to the server. The race window is small;
        // if the server can't bind we retry once.
        let port = try ServerHarness.allocatePort()

        let server = TranslateServer(
            translator: translator,
            detector: detector,
            host: "127.0.0.1",
            port: port,
            apiKey: nil
        )

        let task = Task { try await server.run() }

        // Wait for /health to come up (max 5s).
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let alive = (try? await ServerHarness.ping(port: port)) ?? false
            if alive {
                return ServerHarness(server: server, task: task, port: port)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        task.cancel()
        throw TranslateError.translationFailure("test server failed to start on port \(port)")
    }

    func stop() async {
        await server.stop()
        task.cancel()
        _ = try? await task.value
    }

    private static func ping(port: Int) async throws -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.0
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private static func allocatePort() throws -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw TranslateError.io("could not create probe socket") }
        defer { Darwin.close(socket) }

        var reuse: Int32 = 1
        _ = Darwin.setsockopt(
            socket,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // kernel picks
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)

        let bindResult = withUnsafePointer(to: &addr) { rawPtr -> Int32 in
            rawPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(socket, sockPtr, length)
            }
        }
        guard bindResult == 0 else {
            throw TranslateError.io("bind() failed in probe")
        }

        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getResult = withUnsafeMutablePointer(to: &bound) { rawPtr -> Int32 in
            rawPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.getsockname(socket, sockPtr, &boundLen)
            }
        }
        guard getResult == 0 else {
            throw TranslateError.io("getsockname() failed in probe")
        }

        let port = Int(UInt16(bigEndian: bound.sin_port))
        guard port > 0 else { throw TranslateError.io("kernel returned port 0") }
        return port
    }

    // MARK: - Client helpers

    func get(_ path: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslateError.io("non-HTTP response")
        }
        return (data, http)
    }

    func postForm(_ path: String, body: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslateError.io("non-HTTP response")
        }
        return (data, http)
    }

    func postJSON(_ path: String, body: Data) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslateError.io("non-HTTP response")
        }
        return (data, http)
    }
}
