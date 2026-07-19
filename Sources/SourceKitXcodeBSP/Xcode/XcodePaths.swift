import Foundation

/// Resolved paths to Xcode components.
public struct XcodePaths: Sendable {
    /// Path to the Developer directory (e.g., /Applications/Xcode.app/Contents/Developer).
    public let developerDir: String

    /// Path to Xcode.app.
    public let xcodeApp: URL

    /// Path to the SWBBuildService executable, if found.
    public let swbBuildService: String?

    /// Xcode version information.
    public let version: XcodeVersion

    public var serviceBundleURL: URL? {
        guard let swbBuildService else { return nil }
        return URL(fileURLWithPath: swbBuildService)
            .deletingLastPathComponent() // Contents/MacOS
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // SWBBuildService.bundle
    }

    /// Initializes from a known developer directory path.
    ///
    /// - Parameter developerDir: The Xcode developer directory path.
    /// - Throws: `XcodePathError` if paths cannot be resolved.
    public init(developerDir: String) throws {
        self.developerDir = developerDir

        // Developer dir is: Xcode.app/Contents/Developer
        // Navigate up to Xcode.app
        xcodeApp = URL(fileURLWithPath: developerDir)
            .deletingLastPathComponent() // → Contents
            .deletingLastPathComponent() // → Xcode.app

        version = try Self.readVersion(from: xcodeApp)
        swbBuildService = Self.findSWBBuildService(in: xcodeApp)
    }

    // MARK: - Private

    private static func readVersion(from xcodeApp: URL) throws -> XcodeVersion {
        let infoPlist = xcodeApp.appendingPathComponent("Contents/Info.plist")

        guard FileManager.default.fileExists(atPath: infoPlist.path) else {
            throw XcodePathError.infoPlistNotFound(infoPlist.path)
        }

        let data = try Data(contentsOf: infoPlist)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data,
            format: nil
        ) as? [String: Any] else {
            throw XcodePathError.infoPlistInvalid
        }

        guard let shortVersion = plist["CFBundleShortVersionString"] as? String else {
            throw XcodePathError.versionNotFound
        }

        return XcodeVersion(versionString: shortVersion)
    }

    private static func findSWBBuildService(in xcodeApp: URL) -> String? {
        let fm = FileManager.default

        // Primary: SwiftBuild.framework (Xcode 16+)
        let swbPath = xcodeApp
            .appendingPathComponent("Contents/SharedFrameworks")
            .appendingPathComponent("SwiftBuild.framework/Versions/A")
            .appendingPathComponent("PlugIns/SWBBuildService.bundle")
            .appendingPathComponent("Contents/MacOS/SWBBuildService")

        if fm.isExecutableFile(atPath: swbPath.path) {
            return swbPath.path
        }

        // Fallback: XCBuild.framework (older Xcode)
        let xcbPath = xcodeApp
            .appendingPathComponent("Contents/SharedFrameworks")
            .appendingPathComponent("XCBuild.framework/Versions/A")
            .appendingPathComponent("PlugIns/XCBBuildService.bundle")
            .appendingPathComponent("Contents/MacOS/XCBBuildService")

        if fm.isExecutableFile(atPath: xcbPath.path) {
            return xcbPath.path
        }

        return nil
    }
}

/// Resolves Xcode paths by querying the process environment and filesystem.
///
/// Resolution order:
/// 1. `DEVELOPER_DIR` environment variable
/// 2. `xcode-select -p` output
public struct XcodePathsService: Sendable {
    private let environment: any EnvironmentRepository
    private let processRunner: ProcessRunner

    public init(
        environment: any EnvironmentRepository = ProcessEnvironmentRepository(),
        processRunner: ProcessRunner = ProcessRunner()
    ) {
        self.environment = environment
        self.processRunner = processRunner
    }

    public func resolve() async throws -> XcodePaths {
        let developerDir = try await getDeveloperDir()
        return try XcodePaths(developerDir: developerDir)
    }

    // MARK: - Private

    private func getDeveloperDir() async throws -> String {
        if let envPath = environment.get("DEVELOPER_DIR") {
            guard FileManager.default.fileExists(atPath: envPath) else {
                throw XcodePathError.developerDirNotFound(envPath)
            }
            return envPath
        }
        return try await runXcodeSelect()
    }

    private func runXcodeSelect() async throws -> String {
        let output: ProcessRunner.Output
        do {
            output = try await processRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcode-select"),
                arguments: ["-p"]
            )
        } catch {
            throw XcodePathError.xcodeSelectFailed(underlying: error)
        }

        guard let path = String(data: output.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty
        else {
            throw XcodePathError.xcodeSelectFailed(underlying: nil)
        }
        return path
    }
}

/// Xcode version information.
public struct XcodeVersion: Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    /// Whether this Xcode version is supported (≥26.0).
    public var isSupported: Bool {
        major >= 26
    }

    public var description: String {
        if patch > 0 {
            "\(major).\(minor).\(patch)"
        } else {
            "\(major).\(minor)"
        }
    }

    public init(major: Int, minor: Int, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init(versionString: String) {
        let parts = versionString.split(separator: ".").compactMap { Int($0) }
        major = parts.count > 0 ? parts[0] : 0
        minor = parts.count > 1 ? parts[1] : 0
        patch = parts.count > 2 ? parts[2] : 0
    }
}

/// Errors that can occur during Xcode path resolution.
public enum XcodePathError: Error, Sendable {
    case developerDirNotFound(String)
    case xcodeSelectFailed(underlying: Error?)
    case infoPlistNotFound(String)
    case infoPlistInvalid
    case versionNotFound
    case unsupportedVersion(XcodeVersion)
    case swbBuildServiceNotFound
}

extension XcodePathError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .developerDirNotFound(path):
            "DEVELOPER_DIR does not exist: \(path)"
        case .xcodeSelectFailed:
            "Failed to run xcode-select. Ensure Xcode is installed."
        case let .infoPlistNotFound(path):
            "Xcode Info.plist not found at: \(path)"
        case .infoPlistInvalid:
            "Failed to parse Xcode Info.plist"
        case .versionNotFound:
            "Could not determine Xcode version"
        case let .unsupportedVersion(version):
            "Xcode \(version) is not supported. Requires Xcode 26 or later."
        case .swbBuildServiceNotFound:
            "SWBBuildService not found in Xcode.app. This may indicate a corrupted Xcode installation."
        }
    }
}
