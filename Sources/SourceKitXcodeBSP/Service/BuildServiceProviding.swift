import Foundation
import SwiftBuild

/// Protocol for creating build service sessions.
/// Abstracts `SWBBuildService` for testability.
public protocol BuildServiceProviding: Sendable {
    /// Creates a new build service session.
    ///
    /// - Parameters:
    ///   - name: Session name for identification.
    ///   - cachePath: Optional path for caching.
    ///   - inferiorProductsPath: Optional path for inferior products.
    ///   - environment: Optional environment variables.
    /// - Returns: A tuple of the session result and any diagnostics as strings.
    func createSession(
        name: String,
        cachePath: String?,
        inferiorProductsPath: String?,
        environment: [String: String]?
    ) async -> (Result<any BuildServiceSessionProviding, any Error>, [String])

    /// Closes the underlying build service and releases any associated resources.
    func close() async
}

extension BuildServiceProviding {
    public func close() async {}
}

/// Protocol for build service session operations.
/// Abstracts `SWBBuildServiceSession` for testability.
public protocol BuildServiceSessionProviding: Sendable {
    /// Loads a workspace or project from the given path.
    ///
    /// - Parameter containerPath: Path to `.xcworkspace` or `.xcodeproj`.
    func loadWorkspace(containerPath: String) async throws

    /// Returns information about the loaded workspace.
    ///
    /// - Returns: Workspace information including target metadata.
    func workspaceInfo() async throws -> SWBWorkspaceInfo

    /// Closes the build service session and releases resources held by Swift Build.
    func close() async throws
}

// MARK: - Factory

/// Configures the process environment and vends a `BuildServiceProviding` instance.
///
/// SwiftBuild reads service configuration from environment variables before the
/// out-of-process `SWBBuildService` launches, so all env setup must happen here,
/// before `make()` calls `SWBBuildService(connectionMode: .outOfProcess)`.
public struct BuildServiceProviderFactory: Sendable {
    public let serviceBundlePath: String?
    public let synchronousBuildDescriptionSerialization: Bool
    private let environment: any EnvironmentRepository

    public init(
        serviceBundlePath: String? = nil,
        synchronousBuildDescriptionSerialization: Bool = true,
        environment: any EnvironmentRepository = ProcessEnvironmentRepository()
    ) {
        self.serviceBundlePath = serviceBundlePath
        self.synchronousBuildDescriptionSerialization = synchronousBuildDescriptionSerialization
        self.environment = environment
    }

    public func make() async throws -> any BuildServiceProviding {
        configureEnvironment()
        let service = try await SWBBuildService(connectionMode: .outOfProcess, serviceBundleURL: nil)
        return RealBuildServiceProvider(service: service)
    }

    private func configureEnvironment() {
        // Always set explicitly so our config wins over any inherited environment value.
        environment.set(
            "UseSynchronousBuildDescriptionSerialization",
            value: synchronousBuildDescriptionSerialization ? "YES" : "NO",
            overwrite: true
        )
        if let serviceBundlePath {
            // An explicit path from the config is authoritative — overwrite any inherited value.
            environment.set("SWBBUILDSERVICE_PATH", value: serviceBundlePath, overwrite: true)
        } else if let execURL = Bundle.main.executableURL {
            let serviceURL = execURL.deletingLastPathComponent()
                .appendingPathComponent("SWBBuildServiceBundle")
            if FileManager.default.isExecutableFile(atPath: serviceURL.path) {
                // overwrite: false so an explicit SWBBUILDSERVICE_PATH in the environment
                // still takes precedence over the co-located default.
                environment.set("SWBBUILDSERVICE_PATH", value: serviceURL.path, overwrite: false)
            }
        }
    }
}

// MARK: - Real Implementations

/// Real implementation of `BuildServiceProviding` using `SWBBuildService`.
public struct RealBuildServiceProvider: BuildServiceProviding {
    private let service: SWBBuildService

    public init(service: SWBBuildService) {
        self.service = service
    }

    public func createSession(
        name: String,
        cachePath: String?,
        inferiorProductsPath: String?,
        environment: [String: String]?
    ) async -> (Result<any BuildServiceSessionProviding, any Error>, [String]) {
        let (result, diagnostics) = await service.createSession(
            name: name,
            cachePath: cachePath,
            inferiorProductsPath: inferiorProductsPath,
            environment: environment
        )

        // Convert diagnostics to strings since SWBDiagnostic isn't public
        let diagnosticStrings = diagnostics.map { "\($0)" }

        switch result {
        case let .success(session):
            return (.success(RealBuildServiceSession(session: session)), diagnosticStrings)
        case let .failure(error):
            return (.failure(error), diagnosticStrings)
        }
    }

    public func close() async {
        await service.close()
    }
}

/// Real implementation of `BuildServiceSessionProviding` using `SWBBuildServiceSession`.
public struct RealBuildServiceSession: BuildServiceSessionProviding {
    public let session: SWBBuildServiceSession

    public init(session: SWBBuildServiceSession) {
        self.session = session
    }

    public func loadWorkspace(containerPath: String) async throws {
        try await session.loadWorkspace(containerPath: containerPath)
    }

    public func workspaceInfo() async throws -> SWBWorkspaceInfo {
        try await session.workspaceInfo()
    }

    public func close() async throws {
        try await session.close()
    }
}
