@preconcurrency import ArgumentParser
@preconcurrency import Foundation
import Darwin

@main
public enum TranslateMain: Sendable {
    public static func main() async {
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
