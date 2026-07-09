import BuildServerProtocol
import Foundation
import LanguageServerProtocol
import LanguageServerProtocolTransport
import os // for OSAllocatedUnfairLock; logging uses StderrLogger
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
                platform: config.platform,
                indexingEnabled: config.indexingEnabled ?? true
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

            // Pre-generate the build description before the server starts.
            //
            // SWBBuildServer.initialize() enqueues scheduleRegeneratingBuildDescription()
            // asynchronously after responding to build/initialize. sourcekit-lsp then
            // fires workspace/buildTargets immediately — before the async generation
            // finishes — and gets "No build description" every time.
            //
            // Generating the description here warms the SwiftBuild disk cache.
            // SWBBuildServer.scheduleRegeneratingBuildDescription then becomes a
            // near-instant cache hit and buildDescriptionID is set before the LSP
            // can race to workspace/buildTargets.
            try await prewarmBuildDescription(session: session, buildRequest: buildRequest)

            // Start server and wait for exit. The server loads the workspace
            // internally when build/initialize arrives (containerPath pifSource).
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

    private func makeBuildRequest(buildRoot: String, platform: String?, indexingEnabled: Bool) -> SWBBuildRequest {
        var buildRequest = SWBBuildRequest()
        buildRequest.parameters.arenaInfo = SWBArenaInfo(
            derivedDataPath: buildRoot,
            buildProductsPath: (buildRoot as NSString).appendingPathComponent("Products"),
            buildIntermediatesPath: (buildRoot as NSString).appendingPathComponent("Intermediates.noindex"),
            pchPath: buildRoot,
            indexRegularBuildProductsPath: buildRoot,
            indexRegularBuildIntermediatesPath: buildRoot,
            indexPCHPath: buildRoot,
            indexDataStoreFolderPath: buildRoot,
            indexEnableDataStore: indexingEnabled
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

    /// Pre-generates the build description so the SwiftBuild cache is warm before
    /// `SWBBuildServer` starts. This mirrors the preparation request that
    /// `SWBBuildServer.preparationRequest(for:)` produces so the cached result is
    /// reused when `scheduleRegeneratingBuildDescription` fires after
    /// `build/initialize`.
    private func prewarmBuildDescription(
        session: any BuildServiceSessionProviding,
        buildRequest: SWBBuildRequest
    ) async throws {
        guard let realSession = session as? RealBuildServiceSession else {
            // Test doubles skip the prewarm.
            return
        }

        logger.info("Pre-warming build description...")

        // Mirror the preparation request shape that SWBBuildServer builds internally.
        var prepRequest = buildRequest
        prepRequest.buildCommand = .prepareForIndexing(
            buildOnlyTheseTargets: nil,
            enableIndexBuildArena: true
        )
        prepRequest.enableIndexBuildArena = true
        prepRequest.continueBuildingAfterErrors = true
        prepRequest.parameters.action = "indexbuild"
        var overrides = buildRequest.parameters.overrides.commandLine ?? SWBSettingsTable()
        overrides.set(value: "YES", for: "ONLY_ACTIVE_ARCH")
        overrides.set(value: "NO", for: "INDEX_ENABLE_OPTIMIZATION_LEVEL_OVERRIDE")
        prepRequest.parameters.overrides.commandLine = overrides
        for i in prepRequest.configuredTargets.indices {
            prepRequest.configuredTargets[i].parameters?.action = "indexbuild"
            var t = prepRequest.configuredTargets[i].parameters?.overrides.commandLine ?? SWBSettingsTable()
            t.set(value: "YES", for: "ONLY_ACTIVE_ARCH")
            t.set(value: "NO", for: "INDEX_ENABLE_OPTIMIZATION_LEVEL_OVERRIDE")
            prepRequest.configuredTargets[i].parameters?.overrides.commandLine = t
        }

        try await realSession.session.setSystemInfo(.default())

        let op = try await realSession.session.createBuildOperationForBuildDescriptionOnly(
            request: prepRequest,
            delegate: NoopPlanningDelegate()
        )
        for try await event in try await op.start() {
            if case .reportBuildDescription(_) = event {
                logger.info("Build description ready")
            }
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

        // Create watcher before continuation to ensure it's retained
        let watcher = WorkspaceWatcher(
            workspacePath: workspacePath,
            onChange: {} // Placeholder, will be replaced
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Guard against double-resume: exitHandler and closeHandler can both fire
            let resumed = OSAllocatedUnfairLock(initialState: false)

            @Sendable func finish(
                _ result: Result<Void, any Error>,
                closeConnection: Bool
            ) {
                watcher?.stop()
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

            // Configure watcher callback now that we have server reference
            watcher?.setOnChange { [server] in
                Task {
                    logger.info("Project changed, reloading workspace...")
                    connection.send(OnBuildLogMessageNotification(
                        type: .log,
                        message: "Reloading workspace...",
                        structure: .begin(.init(title: "Reloading workspace"))
                    ))
                    // Reload workspace on session then notify server to regenerate
                    // build description (.session pifSource uses sessionPIFURI).
                    try? await realSession.session.loadWorkspace(containerPath: workspacePath)
                    let notification = OnWatchedFilesDidChangeNotification(
                        changes: [FileEvent(uri: SWBBuildServer.sessionPIFURI, type: .changed)]
                    )
                    await server.handle(notification: notification)
                }
            }
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

/// No-op delegate used during build description prewarm.
private final class NoopPlanningDelegate: SWBPlanningOperationDelegate, Sendable {
    func provisioningTaskInputs(
        targetGUID: String,
        provisioningSourceData: SWBProvisioningTaskInputsSourceData
    ) async -> SWBProvisioningTaskInputs {
        SWBProvisioningTaskInputs()
    }

    func executeExternalTool(
        commandLine: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) async throws -> SWBExternalToolResult {
        .deferred
    }
}
