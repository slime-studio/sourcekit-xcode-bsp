import Darwin
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

// MARK: - Real Implementations

/// Real implementation of `BuildServiceProviding` using `SWBBuildService`.
public struct RealBuildServiceProvider: BuildServiceProviding {
    private let service: SWBBuildService

    /// Creates a provider with an existing service.
    public init(service: SWBBuildService) {
        self.service = service
    }

    /// Creates a provider with a default out-of-process connection.
    ///
    /// SwiftBuild only accepts a path to a flat (non-`.bundle`) service executable via the
    /// `SWBBUILDSERVICE_PATH` environment variable, so that is how the resolved path is
    /// handed to the framework. We prefer the service built from the same swift-build
    /// checkout over the (older) one the framework's Xcode.app PlugIns lookup would find.
    ///
    /// - Parameter serviceBundlePath: Explicit service executable path from
    ///   `buildServer.json` (`serviceBundlePath`). When `nil`, falls back to the
    ///   `SWBBuildServiceBundle` co-located next to this executable (guaranteed by the
    ///   Package.swift dependency).
    public static func makeDefault(
        serviceBundlePath: String? = nil,
        synchronousBuildDescriptionSerialization: Bool = false
    ) async throws -> RealBuildServiceProvider {
        if synchronousBuildDescriptionSerialization {
            setenv("UseSynchronousBuildDescriptionSerialization", "YES", 1)
        }
        if let serviceBundlePath {
            // An explicit path from the config is authoritative.
            setenv("SWBBUILDSERVICE_PATH", serviceBundlePath, 1)
        } else if let execURL = Bundle.main.executableURL {
            let serviceURL = execURL.deletingLastPathComponent()
                .appendingPathComponent("SWBBuildServiceBundle")
            if FileManager.default.isExecutableFile(atPath: serviceURL.path) {
                // Use 0 (don't overwrite) so an explicit SWBBUILDSERVICE_PATH already in
                // the environment still takes precedence over the co-located default.
                setenv("SWBBUILDSERVICE_PATH", serviceURL.path, 0)
            }
        }
        let service = try await SWBBuildService(connectionMode: .outOfProcess, serviceBundleURL: nil)
        return RealBuildServiceProvider(service: service)
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
