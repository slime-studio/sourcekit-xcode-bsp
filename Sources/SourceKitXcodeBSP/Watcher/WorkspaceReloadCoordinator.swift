import Foundation

/// Coalesces and serializes workspace reload work.
///
/// Matching file-change bursts schedule one reload; further matches while a reload
/// is in flight request a single follow-up pass after the current one finishes.
public actor WorkspaceReloadCoordinator {
    private var isReloading = false
    private var pendingReload = false
    private var isCancelled = false
    private let reload: @Sendable () async -> Void

    public init(reload: @escaping @Sendable () async -> Void) {
        self.reload = reload
    }

    /// Requests a reload. Concurrent callers coalesce into at most one in-flight
    /// reload plus one trailing reload.
    public func requestReload() async {
        guard !isCancelled, !Task.isCancelled else { return }

        if isReloading {
            pendingReload = true
            return
        }

        isReloading = true
        defer { isReloading = false }

        repeat {
            guard !isCancelled, !Task.isCancelled else { return }
            pendingReload = false
            await reload()
        } while pendingReload
    }

    /// Stops further reloads. In-flight work should also observe `Task.isCancelled`.
    public func cancel() {
        isCancelled = true
        pendingReload = false
    }
}
