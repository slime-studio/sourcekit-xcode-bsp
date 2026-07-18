import Foundation

/// Filters filesystem events down to the workspace's canonical project metadata.
///
/// BSP must not trust a broad recursive watch (or client notifications) blindly:
/// ignore build/VCS noise, then accept only exact metadata paths for this workspace.
public struct WorkspaceChangeFilter: Sendable {
    /// Absolute, standardized paths that may trigger a reload.
    public let allowedPaths: Set<String>

    /// Path components that always disqualify an event, even if a basename matches.
    public static let ignoredPathComponents: Set<String> = [
        ".git",
        ".build",
        ".swiftpm",
        "DerivedData",
        // Covers SourcePackages/checkouts without matching clone dirs like ~/checkouts/App.
        "SourcePackages",
        "xcuserdata",
        "Index.noindex",
        "ModuleCache.noindex",
        "CompilationCache.noindex",
    ]

    public init(allowedPaths: Set<String>) {
        self.allowedPaths = Set(allowedPaths.map { Self.standardizedPath($0) })
    }

    /// Builds the canonical allowlist for a configured `.xcodeproj` / `.xcworkspace`.
    ///
    /// - Parameter workspacePath: Absolute path to the workspace container from config.
    public init(workspacePath: String) {
        self.init(allowedPaths: Self.canonicalMetadataPaths(for: workspacePath))
    }

    /// Canonical metadata paths for `workspacePath`.
    ///
    /// Includes the container's own project file, embedded SwiftPM `Package.resolved`
    /// (inside the project/workspace bundle), and adjacent SwiftPM lock/manifest
    /// files. Sibling `.xcodeproj` / `.xcworkspace` metadata at the same parent level
    /// is included so multi-project roots still reload without matching nested
    /// package checkouts.
    ///
    /// - Note: Sibling discovery is a one-shot snapshot of the parent directory at
    ///   call time (watcher init). Projects created later as siblings are not added
    ///   to the allowlist until the server restarts and rebuilds the filter.
    public static func canonicalMetadataPaths(for workspacePath: String) -> Set<String> {
        let workspaceURL = URL(fileURLWithPath: workspacePath).standardizedFileURL
        let parent = workspaceURL.deletingLastPathComponent()
        var paths = Set<String>()

        switch workspaceURL.pathExtension {
        case "xcodeproj":
            paths.formUnion(Self.xcodeprojMetadataPaths(for: workspaceURL))
        case "xcworkspace":
            paths.formUnion(Self.xcworkspaceMetadataPaths(for: workspaceURL))
        default:
            break
        }

        paths.insert(parent.appendingPathComponent("Package.swift").path)
        paths.insert(parent.appendingPathComponent("Package.resolved").path)

        if let siblings = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for sibling in siblings {
                switch sibling.pathExtension {
                case "xcodeproj":
                    paths.formUnion(Self.xcodeprojMetadataPaths(for: sibling))
                case "xcworkspace":
                    paths.formUnion(Self.xcworkspaceMetadataPaths(for: sibling))
                default:
                    continue
                }
            }
        }

        return paths
    }

    /// Metadata paths for an `.xcodeproj`, including the embedded SPM lock file.
    private static func xcodeprojMetadataPaths(for projectURL: URL) -> Set<String> {
        [
            projectURL.appendingPathComponent("project.pbxproj").path,
            // Xcode writes package resolution state inside the project container.
            projectURL
                .appendingPathComponent("project.xcworkspace")
                .appendingPathComponent("xcshareddata")
                .appendingPathComponent("swiftpm")
                .appendingPathComponent("Package.resolved").path,
        ]
    }

    /// Metadata paths for an `.xcworkspace`, including shared SPM lock file.
    private static func xcworkspaceMetadataPaths(for workspaceURL: URL) -> Set<String> {
        [
            workspaceURL.appendingPathComponent("contents.xcworkspacedata").path,
            workspaceURL
                .appendingPathComponent("xcshareddata")
                .appendingPathComponent("swiftpm")
                .appendingPathComponent("Package.resolved").path,
        ]
    }

    /// Returns whether `path` should trigger a workspace reload.
    public func isRelevantChange(path: String) -> Bool {
        let standardized = Self.standardizedPath(path)
        guard !Self.isIgnored(path: standardized) else { return false }
        return allowedPaths.contains(standardized)
    }

    /// Returns true when any path component is on the ignore list.
    public static func isIgnored(path: String) -> Bool {
        let components = URL(fileURLWithPath: path).pathComponents
        return components.contains { ignoredPathComponents.contains($0) }
    }

    public static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
