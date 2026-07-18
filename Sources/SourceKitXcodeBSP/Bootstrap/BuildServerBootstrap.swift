import BuildServerProtocol
import Foundation
import LanguageServerProtocol
import LanguageServerProtocolTransport
import os
import SwiftBuild

/// Error types for bootstrap failures.
public enum BootstrapError: Error, Sendable {
    case sessionCreationFailed(Error)
    case workspaceLoadFailed(Error)
    case serverExit(code: Int)
}

extension BootstrapError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .sessionCreationFailed(error):
            "Failed to create build service session: \(error)"
        case let .workspaceLoadFailed(error):
            "Failed to load workspace: \(error)"
        case let .serverExit(code):
            "Build server exited with code \(code)"
        }
    }
}

private let logger = StderrLogger(category: "bootstrap")

/// Orchestrates the setup and running of the BSP server.
public struct BuildServerBootstrap: Sendable {
    public init() {}

    /// Starts the BSP server with the given configuration.
    ///
    /// - Parameters:
    ///   - config: Server configuration from buildServer.json.
    ///   - workspacePath: Absolute path to the workspace.
    ///   - buildRoot: Path to build artifacts directory.
    ///   - connection: JSON-RPC connection for client communication.
    ///   - serviceProvider: Provider for creating build service sessions.
    /// - Throws: `BootstrapError` on failure.
    public func start(
        config: BuildServerConfig,
        workspacePath: String,
        buildRoot: String,
        connection: JSONRPCConnection,
        serviceProvider: any BuildServiceProviding
    ) async throws {
        // Create session
        let session = try await createSession(serviceProvider: serviceProvider)

        var runError: (any Error)?
        do {
            var buildRequest = makeBuildRequest(
                buildRoot: buildRoot,
                platform: config.platform
            )

            // Load workspace and populate configured targets before creating the server.
            // Using .session pifSource means SWBBuildServer skips loadWorkspace on
            // build/initialize — so this is the one and only loadWorkspace call.
            // The correct PIF GUIDs come from workspaceInfo(), not the raw project file.
            try await populateTargets(
                session: session,
                buildRequest: &buildRequest,
                workspacePath: workspacePath
            )

            // Start server and wait for exit.
            try await runServer(
                session: session,
                buildRequest: buildRequest,
                workspacePath: workspacePath,
                connection: connection
            )
        } catch {
            runError = error
        }

        do {
            try await session.close()
        } catch {
            logger.error("Failed to close build service session: \(error)")
            if runError == nil {
                runError = error
            }
        }

        await serviceProvider.close()

        if let runError {
            throw runError
        }
    }

    // MARK: - Private Helpers

    private func createSession(
        serviceProvider: any BuildServiceProviding
    ) async throws -> any BuildServiceSessionProviding {
        let (sessionResult, diagnostics) = await serviceProvider.createSession(
            name: "sourcekit-xcode-bsp",
            cachePath: nil,
            inferiorProductsPath: nil,
            environment: nil
        )

        for diagnostic in diagnostics {
            logger.info("Diagnostic: \(diagnostic)")
        }

        switch sessionResult {
        case let .success(session):
            return session
        case let .failure(error):
            throw BootstrapError.sessionCreationFailed(error)
        }
    }

    private func makeBuildRequest(buildRoot: String, platform: String?) -> SWBBuildRequest {
        var buildRequest = SWBBuildRequest()
        // INDEX_ENABLE_DATA_STORE is always on; not exposed as config (unclear BSP semantics).
        buildRequest.parameters.arenaInfo = SWBArenaInfo(
            derivedDataPath: buildRoot,
            buildProductsPath: (buildRoot as NSString).appendingPathComponent("Products"),
            buildIntermediatesPath: (buildRoot as NSString).appendingPathComponent("Intermediates.noindex"),
            pchPath: buildRoot,
            indexRegularBuildProductsPath: buildRoot,
            indexRegularBuildIntermediatesPath: buildRoot,
            indexPCHPath: buildRoot,
            indexDataStoreFolderPath: buildRoot,
            indexEnableDataStore: true
        )

        if let platform {
            buildRequest.parameters.activeRunDestination = Self.makeRunDestination(for: platform)
        }

        return buildRequest
    }

    private func populateTargets(
        session: any BuildServiceSessionProviding,
        buildRequest: inout SWBBuildRequest,
        workspacePath: String
    ) async throws {
        do {
            try await session.loadWorkspace(containerPath: workspacePath)
        } catch {
            throw BootstrapError.workspaceLoadFailed(error)
        }
        let targets = try await session.workspaceInfo().targetInfos
        logger.info("Adding \(targets.count) configured targets")
        for target in targets {
            buildRequest.add(target: SWBConfiguredTarget(guid: target.guid))
        }
    }

    private func runServer(
        session: any BuildServiceSessionProviding,
        buildRequest: SWBBuildRequest,
        workspacePath: String,
        connection: JSONRPCConnection
    ) async throws {
        guard let realSession = session as? RealBuildServiceSession else {
            fatalError("runServer requires RealBuildServiceSession")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Guard against double-resume: exitHandler and closeHandler can both fire
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let reloadTasks = OSAllocatedUnfairLock(initialState: [Task<Void, Never>]())
            // Retained across finish / onChange; set after coordinator is created.
            let watcherBox = OSAllocatedUnfairLock<WorkspaceWatcher?>(initialState: nil)
            let coordinatorBox = OSAllocatedUnfairLock<WorkspaceReloadCoordinator?>(initialState: nil)

            @Sendable func finish(
                _ result: Result<Void, any Error>,
                closeConnection: Bool
            ) {
                let tasks = reloadTasks.withLock { tasks -> [Task<Void, Never>] in
                    let copy = tasks
                    tasks.removeAll()
                    return copy
                }
                for task in tasks {
                    task.cancel()
                }
                if let coordinator = coordinatorBox.withLock({ $0 }) {
                    Task { await coordinator.cancel() }
                }
                watcherBox.withLock { $0 }?.stop()

                let alreadyResumed = resumed.withLock { val -> Bool in
                    if val { return true }
                    val = true
                    return false
                }
                guard !alreadyResumed else { return }
                if closeConnection {
                    connection.close()
                }
                switch result {
                case .success:
                    continuation.resume()
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }

            // .session pifSource: workspace was already loaded in populateTargets,
            // so scheduleRegeneratingBuildDescription skips loadWorkspace and goes
            // straight to createBuildOperationForBuildDescriptionOnly.
            let server = SWBBuildServer(
                session: realSession.session,
                buildRequest: buildRequest,
                connectionToClient: connection,
                exitHandler: { code in
                    if code != 0 {
                        logger.error("Build server exited with code \(code)")
                        finish(.failure(BootstrapError.serverExit(code: code)), closeConnection: true)
                    } else {
                        finish(.success(()), closeConnection: true)
                    }
                }
            )

            // Coalesce FSEvents bursts and serialize loadWorkspace + regenerate so
            // overlapping client/server notifications cannot interleave reloads.
            let reloadCoordinator = WorkspaceReloadCoordinator { [server] in
                guard !Task.isCancelled else { return }
                logger.info("Project changed, reloading workspace...")
                connection.send(OnBuildLogMessageNotification(
                    type: .log,
                    message: "Reloading workspace...",
                    structure: .begin(.init(title: "Reloading workspace"))
                ))
                // Reload workspace on session then notify server to regenerate
                // build description (.session pifSource uses sessionPIFURI).
                // handle() only schedules regenerate on SWB's serial queue and
                // returns; we cannot await that work from here, so a trailing
                // loadWorkspace may still overlap an in-flight regenerate.
                do {
                    try await realSession.session.loadWorkspace(containerPath: workspacePath)
                    guard !Task.isCancelled else { return }
                    let notification = OnWatchedFilesDidChangeNotification(
                        changes: [FileEvent(uri: SWBBuildServer.sessionPIFURI, type: .changed)]
                    )
                    await server.handle(notification: notification)
                    connection.send(OnBuildLogMessageNotification(
                        type: .log,
                        message: "Workspace load finished; build description regeneration scheduled",
                        structure: .end(.init())
                    ))
                } catch is CancellationError {
                    return
                } catch {
                    logger.error("Workspace reload failed: \(error)")
                    connection.send(OnBuildLogMessageNotification(
                        type: .error,
                        message: "Workspace reload failed: \(error)",
                        structure: .end(.init())
                    ))
                }
            }
            coordinatorBox.withLock { $0 = reloadCoordinator }

            let watcher = WorkspaceWatcher(
                workspacePath: workspacePath,
                onChange: {
                    let task = Task {
                        await reloadCoordinator.requestReload()
                    }
                    reloadTasks.withLock { $0.append(task) }
                }
            )
            watcherBox.withLock { $0 = watcher }
            watcher?.start()

            connection.start(receiveHandler: server) {
                finish(.success(()), closeConnection: false)
            }
        }
    }
}

public extension BuildServerBootstrap {
    /// Creates run destination info for the given platform.
    static func makeRunDestination(for platform: String) -> SWBRunDestinationInfo {
        let sdk = platform
        let arch: String
        let supportedArchs: [String]

        switch platform {
        case "macosx":
            arch = "arm64"
            supportedArchs = ["arm64", "x86_64"]
        case "iphoneos", "iphonesimulator":
            arch = "arm64"
            supportedArchs = ["arm64"]
        case "watchos", "watchsimulator":
            arch = "arm64_32"
            supportedArchs = ["arm64_32"]
        case "appletvos", "appletvsimulator":
            arch = "arm64"
            supportedArchs = ["arm64"]
        case "xros", "xrsimulator":
            arch = "arm64"
            supportedArchs = ["arm64"]
        default:
            arch = "arm64"
            supportedArchs = ["arm64"]
        }

        return SWBRunDestinationInfo(
            platform: platform,
            sdk: sdk,
            sdkVariant: nil,
            targetArchitecture: arch,
            supportedArchitectures: supportedArchs,
            disableOnlyActiveArch: false
        )
    }
}

