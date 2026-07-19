import Foundation
import SWBUtil

/// Runs subprocesses and captures their output. Not tied to any particular caller —
/// domain-specific failures should be translated at the call site.
public actor ProcessRunner {
    public struct Output: Sendable {
        public let stdout: Data
        public let stderr: Data
    }

    public enum RunError: Error, Sendable {
        /// The process could not be launched (bad executable path, permissions, etc.),
        /// or the surrounding task was cancelled before/while it ran.
        case launchFailed(underlying: any Error)
        /// The process launched and ran to completion but exited with a non-zero status.
        case nonZeroExit(terminationStatus: Int32, output: Output)
    }

    public init() {}

    public func run(executableURL: URL, arguments: [String]) async throws -> Output {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        // Drain both pipes concurrently with the process running, rather than after
        // it exits, so output larger than the pipe buffer can't deadlock the process
        // (it would block writing to a full pipe that nothing is reading yet).
        let stdoutTask = Task {
            var stdoutBuffer: [UInt8] = []
            do {
                for try await byte in stdoutPipe.fileHandleForReading.bytes {
                    stdoutBuffer.append(byte)
                }
            } catch {}
            return Data(stdoutBuffer)
        }
        let stderrTask = Task {
            var stderrBuffer: [UInt8] = []
            do {
                for try await byte in stderrPipe.fileHandleForReading.bytes {
                    stderrBuffer.append(byte)
                }
            } catch {}
            return Data(stderrBuffer)
        }

        do {
            // SWBUtil's run(interruptible:) suspends until the process actually
            // exits (via terminationHandler) and propagates task cancellation as
            // SIGTERM. Foundation's own Process.run() only launches the process
            // and returns immediately.
            try await process.run(interruptible: true)
        } catch {
            throw RunError.launchFailed(underlying: error)
        }

        let output = await Output(stdout: stdoutTask.value, stderr: stderrTask.value)

        guard process.terminationStatus == 0 else {
            throw RunError.nonZeroExit(terminationStatus: process.terminationStatus, output: output)
        }

        return output
    }
}
