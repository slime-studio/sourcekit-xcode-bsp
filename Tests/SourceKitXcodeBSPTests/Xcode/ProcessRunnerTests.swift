import Foundation
import Testing
@testable import SourceKitXcodeBSP

@Suite("ProcessRunner")
struct ProcessRunnerTests {

    @Test("Captures stdout and stderr separately")
    func capturesBothStreams() async throws {
        let output = try await ProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf out; printf err 1>&2"]
        )

        #expect(String(bytes: output.stdout, encoding: .utf8) == "out")
        #expect(String(bytes: output.stderr, encoding: .utf8) == "err")
    }

    @Test("Throws nonZeroExit, carrying the output, when the process fails")
    func throwsOnNonZeroExit() async throws {
        await #expect(throws: ProcessRunner.RunError.self) {
            try await ProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exit 3"]
            )
        }
    }

    @Test("Throws launchFailed for a nonexistent executable")
    func throwsOnLaunchFailure() async throws {
        await #expect(throws: ProcessRunner.RunError.self) {
            try await ProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/nonexistent/binary"),
                arguments: []
            )
        }
    }

    /// Guards against draining pipes byte-by-byte.
    ///
    /// `FileHandle.bytes` suspends once per byte, which made a ~90KB payload — the size of an
    /// `xcodebuild -showBuildSettings -json` dump — take minutes instead of milliseconds, and
    /// silently blew the DerivedData resolver's deadline. The elapsed-time bound is set absurdly
    /// loose on purpose: chunked reads finish this in well under a second, while the byte-by-byte
    /// pathology would need many minutes, so the assertion separates the two without being
    /// sensitive to machine speed.
    @Test("Reads a payload far larger than the pipe buffer promptly and completely")
    func readsLargeOutputPromptly() async throws {
        let byteCount = 1_048_576
        let clock = ContinuousClock()

        var output: ProcessRunner.Output?
        let elapsed = try await clock.measure {
            output = try await ProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "head -c \(byteCount) /dev/zero | tr '\\0' 'a'"]
            )
        }

        #expect(try #require(output).stdout.count == byteCount)
        #expect(elapsed < .seconds(30))
    }

    // MARK: - Slow and stalled producers
    //
    // `availableData` returns empty only at real EOF, blocking otherwise. These pin that: if an
    // idle gap were ever mistaken for EOF, the drain loop would stop early and truncate output.

    @Test("Captures every chunk when writes are separated by idle gaps, including before and after output")
    func capturesAcrossIdleGaps() async throws {
        let out = try await ProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 0.4; printf a; sleep 0.6; printf b; sleep 0.4; printf c; sleep 0.6"]
        )

        #expect(String(bytes: out.stdout, encoding: .utf8) == "abc")
    }

    @Test("Interleaves slow oversized stdout and stderr without deadlock or loss")
    func handlesSlowOversizedBothStreams() async throws {
        // Each stream exceeds the pipe buffer, written in delayed bursts. If either pipe went
        // undrained the child would block writing to a full pipe and never exit, so this is the
        // regression test for draining concurrently with execution.
        let script = """
        for _ in 1 2 3; do
          head -c 40000 /dev/zero | tr '\\0' 'o'
          head -c 40000 /dev/zero | tr '\\0' 'e' 1>&2
          sleep 0.3
        done
        """

        let out = try await ProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script]
        )

        #expect(out.stdout.count == 120_000)
        #expect(out.stderr.count == 120_000)
        #expect(out.stdout.allSatisfy { $0 == UInt8(ascii: "o") })
        #expect(out.stderr.allSatisfy { $0 == UInt8(ascii: "e") })
    }

    @Test("Cancelling while a drain is blocked on a stalled process unwinds and kills the child")
    func cancellationUnwindsBlockedDrain() async throws {
        let marker = "pr-hang-\(UUID().uuidString)"
        let task = Task {
            try await ProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                // Writes nothing and never exits, so the drain blocks in availableData.
                arguments: ["-c", "# \(marker)\nsleep 600"]
            )
        }
        try await Task.sleep(for: .milliseconds(600))
        task.cancel()

        let elapsed = await ContinuousClock().measure { _ = await task.result }
        #expect(elapsed < .seconds(20))

        // SIGTERM must actually reap the child; an orphan holding the pipe open would leave the
        // drain thread blocked indefinitely.
        try await Task.sleep(for: .milliseconds(600))
        let check = try await ProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "pgrep -fl '\(marker)' | grep -v pgrep | wc -l"]
        )
        let survivors = String(bytes: check.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(survivors == "0")
    }

    // MARK: - Read failures

    @Test("Reports a read failure as a Result instead of raising an uncatchable ObjC exception")
    func surfacesReadFailure() async throws {
        // `availableData` would raise NSFileHandleOperationException here, which Swift cannot
        // catch, crashing the process. `read(upToCount:)` throws a Swift error instead.
        let pipe = Pipe()
        let handle = pipe.fileHandleForReading
        try handle.close()

        let result = await ProcessRunner.drain(handle)

        switch result {
        case let .success(data):
            Issue.record("Expected a read failure, got \(data.count) bytes")
        case .failure:
            break
        }
    }

    @Test("Reads a normal stream to completion through the Result path")
    func drainSucceedsOnNormalStream() async throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("hello".utf8))
        try pipe.fileHandleForWriting.close()

        let result = await ProcessRunner.drain(pipe.fileHandleForReading)

        #expect(try result.get() == Data("hello".utf8))
    }
}
