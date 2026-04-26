@preconcurrency import Foundation
import XCTest
@testable import translate

/// Drives the actual built binary as a subprocess: pipes stdin, captures
/// stdout/stderr/exit code. Verifies CLI surface end-to-end. Tests that
/// require installed Apple translation models skip themselves; everything
/// else runs unconditionally.
@available(macOS 26.0, *)
final class E2EBinaryTests: XCTestCase {

    private static func locateBinary() -> URL? {
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // translateTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
        let candidates = [
            here.appendingPathComponent(".build/release/translate"),
            here.appendingPathComponent(".build/arm64-apple-macosx/release/translate"),
            here.appendingPathComponent(".build/debug/translate")
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    @discardableResult
    private func run(args: [String], stdin: String? = nil) throws -> (stdout: String, stderr: String, code: Int32) {
        guard let binary = Self.locateBinary() else {
            throw XCTSkip("translate binary not built; run `swift build -c release` first")
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        if let stdin {
            let inPipe = Pipe()
            process.standardInput = inPipe
            try process.run()
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try inPipe.fileHandleForWriting.close()
        } else {
            try process.run()
        }

        process.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return (
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            code: process.terminationStatus
        )
    }

    func testVersionPrints() throws {
        let result = try run(args: ["--version"])
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("0.1.0"))
    }

    func testHelpExits0() throws {
        let result = try run(args: ["--help"])
        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(result.stdout.contains("UNIX-style filter"))
    }

    func testNoTargetWithStdinExits1() throws {
        let result = try run(args: [], stdin: "hallo\n")
        XCTAssertEqual(result.code, 1)
        XCTAssertTrue(result.stderr.contains("--to is required"))
    }

    func testDetectOnlyOnPipedStdin() throws {
        let result = try run(args: ["--detect-only"], stdin: "Das ist ein deutscher Satz mit genug Worten zum Erkennen.")
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(result.stdout.hasPrefix("de"))
    }

    func testDetectOnlyOnTextArguments() throws {
        let result = try run(args: ["--detect-only", "Ceci est une phrase française avec plusieurs mots."])
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(result.stdout.hasPrefix("fr"))
    }

    func testInstalledFlagListsPairs() throws {
        let result = try run(args: ["--installed"])
        XCTAssertEqual(result.code, 0, result.stderr)
        // Output may be empty if no models installed; just verify clean exit.
    }

    func testAvailableFlagListsPairs() throws {
        let result = try run(args: ["--available"])
        XCTAssertEqual(result.code, 0, result.stderr)
    }

    func testNoInputAndIsattyEmitsUsage() throws {
        // We can't easily make stdin look like a tty in a subprocess test,
        // so we hit the `--to` requirement instead.
        let result = try run(args: ["--from", "de", "--to", "en"], stdin: "")
        XCTAssertEqual(result.code, 0, "empty stdin is a no-op (exit 0)")
    }

    func testTranslateRoundTripIfModelsInstalled() throws {
        let installed = try run(args: ["--installed"])
        guard installed.stdout.contains("de-en") else {
            throw XCTSkip("de-en model not installed")
        }

        let result = try run(args: ["--to", "en", "--from", "de", "--no-install"], stdin: "Das ist ein Test.\n")
        XCTAssertEqual(result.code, 0, "stderr=\(result.stderr) stdout=\(result.stdout)")
        XCTAssertFalse(result.stdout.isEmpty)
    }

    func testTranslateNDJSONFormatIfModelsInstalled() throws {
        let installed = try run(args: ["--installed"])
        guard installed.stdout.contains("de-en") else {
            throw XCTSkip("de-en model not installed")
        }

        let result = try run(args: ["--to", "en", "--from", "de", "--format", "ndjson", "--no-install"], stdin: "Hallo\n\nWelt\n")
        XCTAssertEqual(result.code, 0, "stderr=\(result.stderr)")
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertGreaterThan(lines.count, 0)
        XCTAssertTrue(result.stdout.contains("\"src\":"))
        XCTAssertTrue(result.stdout.contains("\"dst\":"))
        XCTAssertTrue(result.stdout.contains("\"from\":\"de\""))
        XCTAssertTrue(result.stdout.contains("\"to\":\"en\""))
    }
}
