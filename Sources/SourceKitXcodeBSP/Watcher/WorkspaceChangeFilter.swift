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
    /// Includes the container's own project file and adjacent SwiftPM lock/manifest
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
            paths.insert(workspaceURL.appendingPathComponent("project.pbxproj").path)
        case "xcworkspace":
            paths.insert(workspaceURL.appendingPathComponent("contents.xcworkspacedata").path)
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
                    paths.insert(sibling.appendingPathComponent("project.pbxproj").path)
                case "xcworkspace":
                    paths.insert(sibling.appendingPathComponent("contents.xcworkspacedata").path)
                default:
                    continue
                }
            }
        }

        return paths
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
