@preconcurrency import ArgumentParser
@preconcurrency import Foundation
import Darwin

@main
public enum TranslateMain: Sendable {
    public static func main() async {
        // Hard-block every URLSession HTTP/HTTPS/WS/WSS attempt at runtime.
        // translate is 100% on-device by promise -- this is the enforcement.
        NetworkGuard.install()

        do {
            var command = try TranslateCommand.parse()
            try await command.run()
            Darwin.exit(EXIT_SUCCESS)
        } catch let error as TranslateError {
            Stdio.stderr(error.description + "\n")
            Darwin.exit(error.exitCode)
        } catch {
            TranslateCommand.exit(withError: error)
        }
    }
}
