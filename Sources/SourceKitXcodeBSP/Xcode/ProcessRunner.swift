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
        /// A pipe could not be read to completion. Surfaced rather than swallowed: returning the
        /// partial output would hand the caller silently truncated data, which is far harder to
        /// diagnose than a failure.
        case outputReadFailed(underlying: any Error)
    }

    public init() {}

    /// Size of each read. Large enough that a typical payload needs only a handful of reads,
    /// small enough not to over-allocate for the common tiny output.
    private static let readChunkSize = 64 * 1024

    /// Reads `handle` to EOF in chunks, reporting a read failure instead of truncating.
    ///
    /// Two deliberate API choices:
    ///
    /// - Not `FileHandle.bytes`: that async sequence suspends once per *byte*, so a payload the
    ///   size of an `xcodebuild -showBuildSettings -json` dump (~90KB) took minutes rather than
    ///   milliseconds.
    /// - Not `availableData`: it signals read errors by raising an Objective-C
    ///   `NSFileHandleOperationException`, which Swift cannot catch — a read error would crash
    ///   the process instead of surfacing. `read(upToCount:)` throws a Swift error for the same
    ///   conditions and returns `nil` at end of file.
    ///
    /// Both block until data arrives, so this runs on a global queue to keep blocking off the
    /// cooperative thread pool.
    static func drain(_ handle: FileHandle) async -> Result<Data, any Error> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<Data, any Error>, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var data = Data()
                do {
                    // nil means EOF; an empty chunk is treated the same, since the documented
                    // end-of-file signal has varied between `nil` and empty `Data`.
                    while let chunk = try handle.read(upToCount: readChunkSize), !chunk.isEmpty {
                        data.append(chunk)
                    }
                    continuation.resume(returning: .success(data))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

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
        let stdoutTask = Task { await Self.drain(stdoutPipe.fileHandleForReading) }
        let stderrTask = Task { await Self.drain(stderrPipe.fileHandleForReading) }

        do {
            // SWBUtil's run(interruptible:) suspends until the process actually
            // exits (via terminationHandler) and propagates task cancellation as
            // SIGTERM. Foundation's own Process.run() only launches the process
            // and returns immediately.
            try await process.run(interruptible: true)
        } catch {
            throw RunError.launchFailed(underlying: error)
        }

        let stdoutResult = await stdoutTask.value
        let stderrResult = await stderrTask.value
        let output: Output
        do {
            output = Output(stdout: try stdoutResult.get(), stderr: try stderrResult.get())
        } catch {
            throw RunError.outputReadFailed(underlying: error)
        }

        guard process.terminationStatus == 0 else {
            throw RunError.nonZeroExit(terminationStatus: process.terminationStatus, output: output)
        }

        return output
    }
}
