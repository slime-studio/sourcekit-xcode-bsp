import Foundation

/// Lightweight logger that writes to standard error.
///
/// A BSP server is launched as a subprocess by its client (e.g. sourcekit-lsp), which
/// captures the server's `stderr` and surfaces it in the client's own logs. Apple's
/// unified logging (`os.Logger`) does not show up there, so we log to stderr instead so
/// our messages are visible alongside the client's logs.
public struct StderrLogger: Sendable {
    /// Subsystem-style category included in each line (e.g. "bootstrap", "watcher").
    public let category: String

    public init(category: String) {
        self.category = category
    }

    public func info(_ message: @autoclosure () -> String) {
        write(level: "info", message())
    }

    public func error(_ message: @autoclosure () -> String) {
        write(level: "error", message())
    }

    private func write(level: String, _ message: String) {
        // One write per line keeps lines from interleaving under concurrency, since a
        // single small write to a pipe is delivered atomically (<= PIPE_BUF).
        let line = "[xcode-bsp:\(category)] \(level): \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
