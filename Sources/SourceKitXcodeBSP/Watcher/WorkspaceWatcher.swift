import Foundation

private let logger = StderrLogger(category: "watcher")

/// Watches workspace directory for project structure changes using FSEvents.
public final class WorkspaceWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private var context: WatcherContext

    /// Creates a watcher for the given workspace.
    ///
    /// Uses FSEvents to recursively watch the directory containing the workspace,
    /// then filters events to exact canonical metadata paths (ignoring `.git`,
    /// `.build`, DerivedData, package checkouts, etc.) and debounces bursts.
    ///
    /// - Parameters:
    ///   - workspacePath: Path to `.xcworkspace` or `.xcodeproj`.
    ///   - debounceInterval: Quiet period before delivering `onChange`.
    ///   - onChange: Called when project structure changes.
    public init?(
        workspacePath: String,
        debounceInterval: TimeInterval = 0.5,
        onChange: @escaping @Sendable () -> Void
    ) {
        let url = URL(fileURLWithPath: workspacePath)
        let watchPath = url.deletingLastPathComponent().path
        let filter = WorkspaceChangeFilter(workspacePath: workspacePath)

        context = WatcherContext(
            filter: filter,
            debounceInterval: debounceInterval,
            onChange: onChange
        )

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
        logger.info(
            "Watching \(watchPath) for \(filter.allowedPaths.count) canonical metadata path(s)"
        )
    }

    deinit {
        stop()
    }

    public func start() {
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, context.queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        context.cancelPending()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

/// Context for FSEvents callback: exact-path filtering + trailing debounce.
final class WatcherContext: @unchecked Sendable {
    let filter: WorkspaceChangeFilter
    let debounceInterval: TimeInterval
    let queue: DispatchQueue
    let onChange: @Sendable () -> Void

    private let lock = NSLock()
    private var pendingWorkItem: DispatchWorkItem?

    init(
        filter: WorkspaceChangeFilter,
        debounceInterval: TimeInterval,
        onChange: @escaping @Sendable () -> Void,
        queue: DispatchQueue = DispatchQueue(label: "sourcekit-xcode-bsp.watcher", qos: .utility)
    ) {
        self.filter = filter
        self.debounceInterval = debounceInterval
        self.onChange = onChange
        self.queue = queue
    }

    func handle(paths: [String]) {
        guard paths.contains(where: { filter.isRelevantChange(path: $0) }) else { return }
        scheduleDebouncedChange()
    }

    func cancelPending() {
        lock.lock()
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        lock.unlock()
    }

    private func scheduleDebouncedChange() {
        // FSEvents callbacks already run on `queue`; keep scheduling on the same queue.
        lock.lock()
        pendingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pendingWorkItem = nil
            self.lock.unlock()
            self.onChange()
        }
        pendingWorkItem = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
        lock.unlock()
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
    context.handle(paths: paths)
}
