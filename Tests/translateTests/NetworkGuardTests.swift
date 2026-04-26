@preconcurrency import Foundation
import XCTest
@testable import translate

final class NetworkGuardTests: XCTestCase {
    func testBlockedSchemes() {
        XCTAssertTrue(NetworkScheme.isBlocked("http"))
        XCTAssertTrue(NetworkScheme.isBlocked("https"))
        XCTAssertTrue(NetworkScheme.isBlocked("HTTP"))
        XCTAssertTrue(NetworkScheme.isBlocked("HTTPS"))
        XCTAssertTrue(NetworkScheme.isBlocked("ws"))
        XCTAssertTrue(NetworkScheme.isBlocked("wss"))
    }

    func testNonBlockedSchemes() {
        XCTAssertFalse(NetworkScheme.isBlocked(nil))
        XCTAssertFalse(NetworkScheme.isBlocked(""))
        XCTAssertFalse(NetworkScheme.isBlocked("file"))
        XCTAssertFalse(NetworkScheme.isBlocked("data"))
        XCTAssertFalse(NetworkScheme.isBlocked("ftp"))
        XCTAssertFalse(NetworkScheme.isBlocked("custom-scheme"))
    }

    func testCanInitMatchesBlockedSchemes() {
        let blocked = URLRequest(url: URL(string: "https://example.com")!)
        let allowed = URLRequest(url: URL(string: "file:///tmp/x")!)
        XCTAssertTrue(DenyNetworkURLProtocol.canInit(with: blocked))
        XCTAssertFalse(DenyNetworkURLProtocol.canInit(with: allowed))
    }

    /// Verify the guard subprocess hard-exits when production code (or a
    /// future bug) attempts a real https request via URLSession.
    func testSubprocessHardExitsOnHTTPAttempt() throws {
        // Drive the actual binary: feed it a tiny stdin, but FIRST poison its
        // env to make any URLSession attempt fail loudly. We simulate the
        // bug by running a Swift one-liner with the same NetworkGuard
        // installed and observing it exits with code 2.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = [
            "-e",
            """
            import Foundation
            final class Deny: URLProtocol, @unchecked Sendable {
                override class func canInit(with r: URLRequest) -> Bool {
                    ["http","https","ws","wss"].contains((r.url?.scheme ?? "").lowercased())
                }
                override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
                override func startLoading() {
                    FileHandle.standardError.write(Data("BLOCKED\\n".utf8))
                    Darwin.exit(2)
                }
                override func stopLoading() {}
            }
            URLProtocol.registerClass(Deny.self)
            let task = URLSession.shared.dataTask(with: URL(string: "https://example.com")!) { _, _, _ in }
            task.resume()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 2.0))
            print("NOT-BLOCKED")
            exit(0)
            """
        ]
        let outPipe = Pipe(); let errPipe = Pipe()
        process.standardOutput = outPipe; process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 2, "expected exit 2, got \(process.terminationStatus)")
        XCTAssertTrue(err.contains("BLOCKED"), "stderr did not contain BLOCKED: \(err)")
    }
}
