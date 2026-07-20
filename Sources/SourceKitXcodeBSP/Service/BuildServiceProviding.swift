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

    /// A single environment variable `make()` sets before launching the build service.
    struct EnvironmentAssignment: Equatable, Sendable {
        let key: String
        let value: String
        let overwrite: Bool
    }

    /// Computes which environment variables `configureEnvironment()` should set, and to what.
    ///
    /// SwiftBuild only accepts a path to a flat (non-`.bundle`) service executable via the
    /// `SWBBUILDSERVICE_PATH` environment variable, so that is how the resolved path is
    /// handed to the framework. We prefer the service built from the same swift-build
    /// checkout over the (older) one the framework's Xcode.app PlugIns lookup would find.
    ///
    /// Pure and independent of `EnvironmentRepository`/`SWBBuildService`, so it can be
    /// tested directly without a fake environment or launching a real out-of-process service.
    ///
    /// - Parameters:
    ///   - serviceBundlePath: Explicit service executable path from `buildServer.json`
    ///     (`serviceBundlePath`). Authoritative when present.
    ///   - coLocatedServiceBundlePath: Path to the `SWBBuildServiceBundle` co-located next
    ///     to this executable, if one exists there. Used as a fallback default.
    static func environmentAssignments(
        serviceBundlePath: String?,
        synchronousBuildDescriptionSerialization: Bool,
        coLocatedServiceBundlePath: String?
    ) -> [EnvironmentAssignment] {
        var assignments = [
            EnvironmentAssignment(
                key: "UseSynchronousBuildDescriptionSerialization",
                // Always set explicitly so our config wins over any inherited environment value.
                value: synchronousBuildDescriptionSerialization ? "YES" : "NO",
                overwrite: true
            )
        ]
        if let serviceBundlePath {
            // An explicit path from the config is authoritative — overwrite any inherited value.
            assignments.append(
                EnvironmentAssignment(key: "SWBBUILDSERVICE_PATH", value: serviceBundlePath, overwrite: true)
            )
        } else if let coLocatedServiceBundlePath {
            // overwrite: false so an explicit SWBBUILDSERVICE_PATH already in the
            // environment still takes precedence over the co-located default.
            assignments.append(
                EnvironmentAssignment(
                    key: "SWBBUILDSERVICE_PATH", value: coLocatedServiceBundlePath, overwrite: false
                )
            )
        }
        return assignments
    }

    private func configureEnvironment() {
        let coLocatedServiceBundlePath: String? = {
            guard let execURL = Bundle.main.executableURL else { return nil }
            let serviceURL = execURL.deletingLastPathComponent()
                .appendingPathComponent("SWBBuildServiceBundle")
            return FileManager.default.isExecutableFile(atPath: serviceURL.path) ? serviceURL.path : nil
        }()

        for assignment in Self.environmentAssignments(
            serviceBundlePath: serviceBundlePath,
            synchronousBuildDescriptionSerialization: synchronousBuildDescriptionSerialization,
            coLocatedServiceBundlePath: coLocatedServiceBundlePath
        ) {
            environment.set(assignment.key, value: assignment.value, overwrite: assignment.overwrite)
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
