import Foundation

private let logger = StderrLogger(category: "watcher")

/// Watches workspace directory for project structure changes using FSEvents.
public final class WorkspaceWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private var context: WatcherContext

    /// Creates a watcher for the given workspace.
    ///
    /// Uses FSEvents to recursively watch the directory containing the workspace,
    /// filtering for relevant project files (project.pbxproj, Package.resolved, etc).
    ///
    /// - Parameters:
    ///   - workspacePath: Path to `.xcworkspace` or `.xcodeproj`.
    ///   - onChange: Called when project structure changes.
    public init?(
        workspacePath: String,
        onChange: @escaping @Sendable () -> Void
    ) {
        let url = URL(fileURLWithPath: workspacePath)
        let watchPath = url.deletingLastPathComponent().path

        context = WatcherContext(onChange: onChange)

        var fsContext = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(context).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let stream = FSEventStreamCreate(
            nil,
            fsEventCallback,
            &fsContext,
            [watchPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else {
            logger.error("Failed to create FSEventStream")
            return nil
        }

        self.stream = stream
    }

    deinit {
        stop()
    }

    /// Updates the change callback. Call before start().
    public func setOnChange(_ onChange: @escaping @Sendable () -> Void) {
        context.onChange = onChange
    }

    public func start() {
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

/// Context for FSEvents callback.
private final class WatcherContext: @unchecked Sendable {
    var onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func isRelevantChange(path: String) -> Bool {
        let filename = (path as NSString).lastPathComponent
        return filename == "project.pbxproj"
            || filename == "contents.xcworkspacedata"
            || filename == "Package.resolved"
            || filename == "Package.swift"
    }
}

/// FSEvents callback function.
private func fsEventCallback(
    streamRef _: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents _: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags _: UnsafePointer<FSEventStreamEventFlags>,
    eventIds _: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let context = Unmanaged<WatcherContext>.fromOpaque(info).takeUnretainedValue()

    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []

    for path in paths {
        if context.isRelevantChange(path: path) {
            context.onChange()
            return // Only trigger once per batch
        }
    }
}
