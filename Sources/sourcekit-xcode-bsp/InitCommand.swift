import ArgumentParser
import Foundation
import SourceKitXcodeBSP

/// Interactively generates a `buildServer.json` in the current directory.
struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Interactively generate a buildServer.json in the current directory."
    )

    func run() throws {
        let cwd = FileManager.default.currentDirectoryPath
        let outPath = (cwd as NSString).appendingPathComponent("buildServer.json")

        if FileManager.default.fileExists(atPath: outPath) {
            guard askYesNo("buildServer.json already exists. Overwrite?", default: false) else {
                say("Aborted; existing buildServer.json left unchanged.")
                return
            }
        }

        // Auto-detect a workspace/project in the current directory as the default.
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: cwd)) ?? []
        let detectedWorkspace = entries.first { $0.hasSuffix(".xcworkspace") }
            ?? entries.first { $0.hasSuffix(".xcodeproj") }

        let workspace = askRequired(
            "Workspace (.xcodeproj or .xcworkspace)",
            default: detectedWorkspace
        )
        let platform = ask(
            "Platform (iphonesimulator, macosx, …; empty = let SwiftBuild choose)",
            default: "iphonesimulator"
        )
        let buildRoot = ask("Build root", default: ".build/derived-data")

        // Point argv at the binary running this command so the client launches the same one.
        let binary = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "sourcekit-xcode-bsp"

        let json = try ConfigLoader.renderConfig(
            argv: [binary],
            workspace: workspace,
            platform: platform.isEmpty ? nil : platform,
            buildRoot: buildRoot.isEmpty ? nil : buildRoot
        )

        try (json + "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
        say("\nWrote \(outPath)")
        say("Advanced options (serviceBundlePath) can be added by hand.")
    }

    // MARK: - Prompts
    //
    // Prompts and confirmations go to stderr so a generated/piped buildServer.json on
    // stdout (if ever redirected) stays clean; answers are read from stdin.

    /// Prompts with a default; empty input returns the default.
    private func ask(_ label: String, default def: String) -> String {
        write("\(label) [\(def)]: ")
        let input = (readLine() ?? "").trimmingCharacters(in: .whitespaces)
        return input.isEmpty ? def : input
    }

    /// Prompts for a required value, reusing `default` when provided and input is empty.
    private func askRequired(_ label: String, default def: String?) -> String {
        while true {
            if let def, !def.isEmpty {
                write("\(label) [\(def)]: ")
            } else {
                write("\(label): ")
            }
            let input = (readLine() ?? "").trimmingCharacters(in: .whitespaces)
            if !input.isEmpty { return input }
            if let def, !def.isEmpty { return def }
            write("  (required — please enter a value)\n")
        }
    }

    /// Yes/no prompt; empty input returns the default.
    private func askYesNo(_ label: String, default def: Bool) -> Bool {
        write("\(label) [\(def ? "Y/n" : "y/N")]: ")
        let input = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if input.isEmpty { return def }
        return input.hasPrefix("y")
    }

    private func write(_ s: String) {
        FileHandle.standardError.write(Data(s.utf8))
    }

    private func say(_ s: String) {
        write(s + "\n")
    }
}
