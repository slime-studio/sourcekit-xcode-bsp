import Foundation

private let logger = StderrLogger(category: "derived-data")

/// Shape of `xcodebuild -list -json` output: `project` for a `.xcodeproj`, `workspace` for a
/// `.xcworkspace`.
private struct ListPayload: Decodable {
    struct Container: Decodable {
        var schemes: [String]?
        var targets: [String]?
    }

    var project: Container?
    var workspace: Container?
}

/// Resolves the DerivedData root Xcode itself would use for a container, using only documented
/// `xcodebuild` interfaces (`-list`, `-showBuildSettings`, `-json`; see `man xcodebuild`).
///
/// Deliberately does *not* reconstruct Xcode's `<Name>-<hash>` folder name. That hash is an
/// undocumented implementation detail, so reproducing it would silently break whenever Apple
/// changes it. Asking `xcodebuild` costs a subprocess but stays correct by construction.
///
/// `-showBuildSettings` reports a DerivedData-rooted `OBJROOT` only in the context of a scheme —
/// a bare or `-target` invocation reports the legacy, project-local build location instead. Not
/// every scheme works either: schemes backed by SPM package products (common in projects with a
/// local `Modules/` directory) exit 0 while emitting no build settings at all. Scheme *listing*
/// order is no guide, being alphabetical. So every scheme is ranked by how likely it is to
/// answer — being backed by a declared target is the strongest knowable signal — and then probed
/// in that order until one does.
public struct XcodeDerivedDataResolver: Sendable {
    /// Xcode's fixed intermediates subpath beneath a DerivedData root.
    private static let objrootSuffix = "/Build/Intermediates.noindex"

    private let processRunner: ProcessRunner
    private let timeout: Duration

    /// - Parameter timeout: Bounds the *entire* resolution rather than each subprocess, so a
    ///   merely-slow project (cold package-graph resolution, say) cannot multiply the budget by
    ///   the number of probes. This deadline, not an arbitrary attempt count, is what bounds how
    ///   many schemes get probed.
    public init(processRunner: ProcessRunner = ProcessRunner(), timeout: Duration = .seconds(60)) {
        self.processRunner = processRunner
        self.timeout = timeout
    }

    /// - Parameter workspacePath: Absolute path to a `.xcodeproj` or `.xcworkspace`.
    /// - Returns: The absolute DerivedData root (e.g.
    ///   `~/Library/Developer/Xcode/DerivedData/Foo-abc...xyz`), or `nil` if it couldn't be
    ///   resolved (no usable scheme, `xcodebuild` failed or timed out, or the container uses a
    ///   legacy/custom build location rather than DerivedData). Callers should fall back to their
    ///   own default build root when `nil`.
    public func resolve(workspacePath: String) async -> String? {
        await withDeadline { await self.resolveWithoutDeadline(workspacePath: workspacePath) }
    }

    // MARK: - Private

    private func resolveWithoutDeadline(workspacePath: String) async -> String? {
        let containerFlag = workspacePath.hasSuffix(".xcworkspace") ? "-workspace" : "-project"

        guard let listData = await run([containerFlag, workspacePath, "-list", "-json"]),
              let listing = Self.parseList(listData)
        else {
            logger.info("xcodebuild -list failed for \(workspacePath); cannot resolve Xcode DerivedData")
            return nil
        }

        let candidates = Self.candidateSchemes(
            schemes: listing.schemes,
            targets: listing.targets,
            containerPath: workspacePath
        )
        guard !candidates.isEmpty else {
            logger.info("No schemes found for \(workspacePath); cannot resolve Xcode DerivedData")
            return nil
        }

        var probed = 0
        for scheme in candidates {
            if Task.isCancelled { return nil }
            probed += 1
            guard let settingsData = await run(
                [containerFlag, workspacePath, "-scheme", scheme, "-showBuildSettings", "-json"]
            ) else { continue }

            guard let objroot = Self.objroot(fromSettingsJSON: settingsData) else { continue }

            if let root = Self.derivedDataRoot(fromObjroot: objroot) {
                return root
            }
            // First scheme to answer wins: we accept its build location rather than surveying
            // the rest. In practice a non-DerivedData OBJROOT means the container itself uses a
            // legacy or custom build location, which no other scheme would contradict — but a
            // scheme's build configuration *can* override SYMROOT/OBJROOT, so this is a
            // deliberate cost trade, not a guarantee. `buildRoot` in buildServer.json is the
            // escape hatch when a project needs a specific answer.
            logger.info("Scheme '\(scheme)' reports a non-DerivedData build location (OBJROOT: \(objroot))")
            return nil
        }

        logger.info(
            "None of \(probed) probed scheme(s) reported build settings "
                + "(tried: \(candidates.prefix(probed).joined(separator: ", ")))"
        )
        return nil
    }

    /// Schemes and targets as reported by `xcodebuild -list -json`.
    ///
    /// For a `.xcodeproj` the payload is under `project` and includes `targets`. For a
    /// `.xcworkspace` it is under `workspace` and carries only `schemes`, since targets belong to
    /// the contained projects — so `targets` is empty there and the target-backed ranking tier is
    /// simply unpopulated.
    struct Listing: Equatable {
        var schemes: [String]
        var targets: [String]
    }

    /// Pure so it can be tested against captured `xcodebuild -list -json` output.
    static func parseList(_ data: Data) -> Listing? {
        guard let payload = try? JSONDecoder().decode(ListPayload.self, from: data),
              let container = payload.project ?? payload.workspace
        else { return nil }

        return Listing(schemes: container.schemes ?? [], targets: container.targets ?? [])
    }

    /// Orders every scheme by how likely it is to report build settings. Nothing is dropped.
    ///
    /// Being backed by a declared target is a strong signal — on a project with local SPM
    /// modules, the package-product schemes are exactly the ones absent from `targets`, and
    /// exactly the ones `-showBuildSettings` reports nothing for. But it is only *sufficient*,
    /// not *necessary*: a scheme is a user-named document, so one named differently from the
    /// target it builds (`ZzCustomNamed` building `NetNewsWire`, say) is absent from `targets`
    /// and still reports a perfectly good `OBJROOT`. Treating target-backing as a membership
    /// filter would therefore make such schemes unreachable, so it ranks them instead.
    ///
    /// Tiers: exact container-name match, then target-backed, then container-name prefix, then
    /// everything else; listing order breaks ties. This also makes the `.xcworkspace` case
    /// degrade smoothly rather than branch — workspaces report no targets, so that tier is
    /// simply empty.
    ///
    /// Pure so it can be tested without launching `xcodebuild`.
    static func candidateSchemes(
        schemes: [String],
        targets: [String],
        containerPath: String
    ) -> [String] {
        let targetSet = Set(targets)
        let containerName = ((containerPath as NSString).lastPathComponent as NSString)
            .deletingPathExtension

        return schemes.enumerated().sorted { lhs, rhs in
            let lhsRank = rank(scheme: lhs.element, containerName: containerName, targets: targetSet)
            let rhsRank = rank(scheme: rhs.element, containerName: containerName, targets: targetSet)
            // Preserve listing order within a rank so selection stays deterministic.
            return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
        }.map(\.element)
    }

    private static func rank(scheme: String, containerName: String, targets: Set<String>) -> Int {
        if scheme == containerName { return 0 }
        if targets.contains(scheme) { return 1 }
        if scheme.hasPrefix(containerName) { return 2 }
        return 3
    }

    /// Extracts `OBJROOT` from `xcodebuild -showBuildSettings -json` output.
    ///
    /// Returns `nil` when the payload carries no build settings at all, which is how a
    /// package-product scheme manifests (it exits 0 with an empty array).
    ///
    /// Pure so it can be tested against captured output.
    static func objroot(fromSettingsJSON data: Data) -> String? {
        // Values are decoded leniently: only OBJROOT is needed, and a strict [String: String]
        // decode would fail outright if any unrelated setting were ever non-string.
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        for entry in entries {
            if let settings = entry["buildSettings"] as? [String: Any],
               let objroot = settings["OBJROOT"] as? String,
               !objroot.isEmpty {
                return objroot
            }
        }
        return nil
    }

    /// Strips Xcode's fixed `Build/Intermediates.noindex` suffix off `OBJROOT` to recover the
    /// DerivedData root.
    ///
    /// A differently-suffixed `OBJROOT` means the container isn't using Xcode's unified
    /// DerivedData build location (e.g. a legacy or custom build location), so this returns `nil`
    /// rather than a path that wouldn't actually be shared with Xcode.
    ///
    /// Pure so it can be tested directly.
    static func derivedDataRoot(fromObjroot objroot: String) -> String? {
        guard objroot.hasSuffix(objrootSuffix) else { return nil }
        return String(objroot.dropLast(objrootSuffix.count))
    }

    /// Races `work` against `timeout`, yielding `nil` if the deadline wins.
    private func withDeadline(_ work: @escaping @Sendable () async -> String?) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await work() }
            group.addTask {
                // Must distinguish "slept the full timeout" from "cancelled because work won".
                // Swallowing the cancellation and falling through would report a timeout on
                // every successful resolution.
                do {
                    try await Task.sleep(for: self.timeout)
                } catch {
                    return nil
                }
                logger.info("Timed out resolving Xcode DerivedData root after \(self.timeout)")
                return nil
            }
            defer { group.cancelAll() }
            // Whichever task finishes first wins: the resolution result, or nil from the deadline.
            return await group.next().flatMap { $0 }
        }
    }

    /// Runs `xcodebuild`, swallowing any failure into `nil` so callers can try the next candidate
    /// or fall back to a default.
    private func run(_ arguments: [String]) async -> Data? {
        try? await processRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: arguments
        ).stdout
    }
}
