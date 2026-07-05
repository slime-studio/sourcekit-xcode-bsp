import Foundation

/// Configuration loaded from buildServer.json.
public struct BuildServerConfig: Sendable, Codable {
    /// Path to `.xcworkspace` or `.xcodeproj` (absolute or relative to buildServer.json).
    public let workspace: String

    /// Optional path to build root (Xcode's DerivedData directory for this workspace).
    /// If not specified, uses `.build/derived-data` in the workspace directory.
    public let buildRoot: String?

    /// Target platform for builds (optional).
    /// Valid values: `iphonesimulator`, `iphoneos`, `macosx`, `watchsimulator`, `watchos`,
    /// `appletvsimulator`, `appletvos`, `xrsimulator`, `xros`.
    /// If not specified, SwiftBuild uses priority order (macOS > iPhone Simulator > etc.).
    public let platform: String?

    /// Whether to enable index data store. Defaults to true.
    public let indexingEnabled: Bool?

    /// Optional path to the `SWBBuildServiceBundle` executable (absolute, or relative to
    /// buildServer.json; `~` is expanded). If not specified, the co-located service built
    /// alongside `sourcekit-xcode-bsp` is used.
    public let serviceBundlePath: String?

    public init(
        workspace: String,
        buildRoot: String? = nil,
        platform: String? = nil,
        indexingEnabled: Bool? = nil,
        serviceBundlePath: String? = nil
    ) {
        self.workspace = workspace
        self.buildRoot = buildRoot
        self.platform = platform
        self.indexingEnabled = indexingEnabled
        self.serviceBundlePath = serviceBundlePath
    }
}

/// Loads BSP configuration from buildServer.json files.
public enum ConfigLoader {
    /// Configuration file name.
    private static let configFileName = "buildServer.json"

    /// Loads configuration from buildServer.json in the specified directory.
    ///
    /// - Parameter directory: Directory containing bsp.json.
    /// - Returns: Parsed configuration.
    /// - Throws: `ConfigError` if file not found or invalid.
    public static func load(from directory: String) throws -> BuildServerConfig {
        let configPath = (directory as NSString).appendingPathComponent(configFileName)
        let url = URL(fileURLWithPath: configPath)

        guard FileManager.default.fileExists(atPath: configPath) else {
            throw ConfigError.configNotFound(configPath)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConfigError.readFailed(configPath, underlying: error)
        }

        do {
            return try JSONDecoder().decode(BuildServerConfig.self, from: data)
        } catch {
            throw ConfigError.invalidFormat(configPath, underlying: error)
        }
    }

    /// Resolves the workspace path from configuration.
    ///
    /// - Parameters:
    ///   - config: The loaded configuration.
    ///   - directory: Directory to resolve relative paths against.
    /// - Returns: Absolute path to the workspace.
    /// - Throws: `ConfigError.workspaceNotFound` if resolved path doesn't exist.
    public static func resolveWorkspacePath(
        config: BuildServerConfig,
        relativeTo directory: String
    ) throws -> String {
        // Use absolute path directly, otherwise resolve relative to directory
        let resolvedPath: String
        if config.workspace.hasPrefix("/") {
            resolvedPath = config.workspace
        } else {
            resolvedPath = (directory as NSString).appendingPathComponent(config.workspace)
        }
        let standardizedPath = (resolvedPath as NSString).standardizingPath

        guard FileManager.default.fileExists(atPath: standardizedPath) else {
            throw ConfigError.workspaceNotFound(standardizedPath)
        }

        return standardizedPath
    }

    /// Resolves the build root path from configuration.
    ///
    /// - Parameters:
    ///   - config: The loaded configuration.
    ///   - directory: Directory to resolve relative paths against.
    /// - Returns: Absolute path to build root directory.
    public static func resolveBuildRoot(
        config: BuildServerConfig,
        relativeTo directory: String
    ) -> String {
        guard let configuredPath = config.buildRoot else {
            // Default to .build/derived-data in workspace directory
            return (directory as NSString).appendingPathComponent(".build/derived-data")
        }

        // Expand ~ and use absolute path directly, otherwise resolve relative to directory
        let expandedPath = (configuredPath as NSString).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return expandedPath
        } else {
            return ((directory as NSString).appendingPathComponent(expandedPath) as NSString).standardizingPath
        }
    }

    /// Renders a `buildServer.json` document (BSP discovery fields + sourcekit-xcode-bsp config).
    ///
    /// Optional values that are `nil` are omitted from the output. Slashes in paths are
    /// not escaped, and keys are sorted for deterministic output.
    ///
    /// - Parameters:
    ///   - argv: Command the LSP client runs to launch the server (the sourcekit-xcode-bsp binary path).
    ///   - workspace: Path to `.xcodeproj`/`.xcworkspace` (absolute or relative to the file).
    ///   - platform: Optional run-destination platform (e.g. `iphonesimulator`).
    ///   - buildRoot: Optional build root; when nil the server defaults to `.build/derived-data`.
    ///   - indexingEnabled: Optional index-store toggle; when nil the server defaults to enabled.
    public static func renderConfig(
        argv: [String],
        workspace: String,
        platform: String? = nil,
        buildRoot: String? = nil,
        indexingEnabled: Bool? = nil,
        name: String = "sourcekit-xcode-bsp",
        version: String = "0.1.0",
        bspVersion: String = "2.1.0",
        languages: [String] = ["swift"]
    ) throws -> String {
        struct Document: Encodable {
            let name: String
            let version: String
            let bspVersion: String
            let languages: [String]
            let argv: [String]
            let workspace: String
            let buildRoot: String?
            let platform: String?
            let indexingEnabled: Bool?
        }

        let doc = Document(
            name: name, version: version, bspVersion: bspVersion, languages: languages,
            argv: argv, workspace: workspace, buildRoot: buildRoot, platform: platform,
            indexingEnabled: indexingEnabled
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(doc)
        return String(decoding: data, as: UTF8.self)
    }

    /// Resolves the optional SWBBuildService executable path from configuration.
    ///
    /// - Parameters:
    ///   - config: The loaded configuration.
    ///   - directory: Directory to resolve relative paths against.
    /// - Returns: Absolute path if `serviceBundlePath` is configured, otherwise `nil`
    ///   (the provider falls back to the co-located service).
    public static func resolveServiceBundlePath(
        config: BuildServerConfig,
        relativeTo directory: String
    ) -> String? {
        guard let configuredPath = config.serviceBundlePath else { return nil }

        let expandedPath = (configuredPath as NSString).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return expandedPath
        } else {
            return ((directory as NSString).appendingPathComponent(expandedPath) as NSString).standardizingPath
        }
    }
}

/// Errors that can occur during configuration loading.
public enum ConfigError: Error, Sendable {
    case configNotFound(String)
    case readFailed(String, underlying: Error)
    case invalidFormat(String, underlying: Error)
    case workspaceNotFound(String)
}

extension ConfigError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .configNotFound(path):
            "Configuration file not found: \(path)"
        case let .readFailed(path, underlying):
            "Failed to read configuration file \(path): \(underlying.localizedDescription)"
        case let .invalidFormat(path, underlying):
            "Invalid configuration format in \(path): \(underlying.localizedDescription)"
        case let .workspaceNotFound(path):
            "Workspace not found: \(path)"
        }
    }
}
