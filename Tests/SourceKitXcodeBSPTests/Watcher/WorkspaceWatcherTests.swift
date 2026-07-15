import Foundation
import os
import Testing
@testable import SourceKitXcodeBSP

@Suite("WorkspaceChangeFilter")
struct WorkspaceChangeFilterTests {

    @Test("Accepts the configured xcodeproj metadata path")
    func acceptsConfiguredXcodeproj() {
        let workspace = "/Projects/App/App.xcodeproj"
        let filter = WorkspaceChangeFilter(
            allowedPaths: WorkspaceChangeFilter.canonicalMetadataPaths(for: workspace)
        )

        #expect(filter.isRelevantChange(path: "/Projects/App/App.xcodeproj/project.pbxproj"))
    }

    @Test("Accepts the configured xcworkspace metadata path")
    func acceptsConfiguredXcworkspace() {
        let workspace = "/Projects/App/App.xcworkspace"
        let filter = WorkspaceChangeFilter(
            allowedPaths: [
                "/Projects/App/App.xcworkspace/contents.xcworkspacedata",
                "/Projects/App/Package.swift",
                "/Projects/App/Package.resolved",
            ]
        )

        #expect(
            filter.isRelevantChange(
                path: "/Projects/App/App.xcworkspace/contents.xcworkspacedata"
            )
        )
    }

    @Test("Accepts adjacent Package.swift / Package.resolved")
    func acceptsAdjacentPackageFiles() {
        let filter = WorkspaceChangeFilter(
            allowedPaths: [
                "/Projects/App/App.xcodeproj/project.pbxproj",
                "/Projects/App/Package.swift",
                "/Projects/App/Package.resolved",
            ]
        )

        #expect(filter.isRelevantChange(path: "/Projects/App/Package.swift"))
        #expect(filter.isRelevantChange(path: "/Projects/App/Package.resolved"))
    }

    @Test("Rejects basename matches outside the allowlist")
    func rejectsOtherProjects() {
        let filter = WorkspaceChangeFilter(
            allowedPaths: [
                "/Projects/App/App.xcodeproj/project.pbxproj",
            ]
        )

        #expect(!filter.isRelevantChange(path: "/Projects/Other/Other.xcodeproj/project.pbxproj"))
        #expect(!filter.isRelevantChange(path: "/Projects/App/Sources/main.swift"))
    }

    @Test("Ignores .git, .build, DerivedData, and package checkouts")
    func ignoresNoisePaths() {
        let filter = WorkspaceChangeFilter(
            allowedPaths: [
                "/Projects/App/App.xcodeproj/project.pbxproj",
                "/Projects/App/Package.swift",
            ]
        )

        let noise = [
            "/Projects/App/.git/HEAD",
            "/Projects/App/.git/objects/pack/pack-1.idx",
            "/Projects/App/.build/debug/App.swiftmodule",
            "/Projects/App/.build/checkouts/SomeDep/Package.swift",
            "/Projects/App/DerivedData/Build/Products/Debug/App",
            "/Projects/App/SourcePackages/checkouts/Foo/Package.swift",
            "/Projects/App/SourcePackages/checkouts/Foo/Foo.xcodeproj/project.pbxproj",
            "/Projects/App/.swiftpm/configuration/registries.json",
            "/Projects/App/App.xcodeproj/xcuserdata/user.xcuserdatad/xcschemes/xcschememanagement.plist",
        ]

        for path in noise {
            #expect(!filter.isRelevantChange(path: path), "expected ignored: \(path)")
            #expect(WorkspaceChangeFilter.isIgnored(path: path), "expected isIgnored: \(path)")
        }
    }

    @Test("Ignores allowed basename when nested under an ignored component")
    func ignoreWinsOverAllowlistBasename() {
        // Even if a checkout path were mistakenly allowlisted, ignore components win.
        let filter = WorkspaceChangeFilter(
            allowedPaths: [
                "/Projects/App/SourcePackages/checkouts/Dep/Package.swift",
            ]
        )
        #expect(
            !filter.isRelevantChange(
                path: "/Projects/App/SourcePackages/checkouts/Dep/Package.swift"
            )
        )
    }

    @Test("Standardizes paths before matching")
    func standardizesPaths() {
        let filter = WorkspaceChangeFilter(
            allowedPaths: ["/Projects/App/App.xcodeproj/project.pbxproj"]
        )
        #expect(
            filter.isRelevantChange(
                path: "/Projects/App/../App/App.xcodeproj/project.pbxproj"
            )
        )
    }

    @Test("canonicalMetadataPaths includes container metadata and adjacent packages")
    func canonicalPathsForXcodeproj() {
        let paths = WorkspaceChangeFilter.canonicalMetadataPaths(
            for: "/Projects/App/App.xcodeproj"
        )
        #expect(paths.contains("/Projects/App/App.xcodeproj/project.pbxproj"))
        #expect(paths.contains("/Projects/App/Package.swift"))
        #expect(paths.contains("/Projects/App/Package.resolved"))
    }

    @Test("canonicalMetadataPaths includes xcworkspace contents file")
    func canonicalPathsForXcworkspace() {
        let paths = WorkspaceChangeFilter.canonicalMetadataPaths(
            for: "/Projects/App/App.xcworkspace"
        )
        #expect(paths.contains("/Projects/App/App.xcworkspace/contents.xcworkspacedata"))
        #expect(paths.contains("/Projects/App/Package.swift"))
        #expect(paths.contains("/Projects/App/Package.resolved"))
    }
}

@Suite("WatcherContext debounce")
struct WatcherContextDebounceTests {

    @Test("Coalesces rapid relevant events into a single onChange")
    func coalescesBursts() async throws {
        let filter = WorkspaceChangeFilter(
            allowedPaths: ["/Projects/App/App.xcodeproj/project.pbxproj"]
        )
        let count = OSAllocatedUnfairLock(initialState: 0)
        let context = WatcherContext(
            filter: filter,
            debounceInterval: 0.05,
            onChange: {
                count.withLock { $0 += 1 }
            }
        )

        context.handle(paths: ["/Projects/App/App.xcodeproj/project.pbxproj"])
        context.handle(paths: ["/Projects/App/App.xcodeproj/project.pbxproj"])
        context.handle(paths: ["/Projects/App/.git/HEAD"])
        context.handle(paths: ["/Projects/App/App.xcodeproj/project.pbxproj"])

        try await Task.sleep(for: .milliseconds(120))
        #expect(count.withLock { $0 } == 1)
        context.cancelPending()
    }

    @Test("Does not fire onChange for ignored-only bursts")
    func ignoresNoiseOnly() async throws {
        let filter = WorkspaceChangeFilter(
            allowedPaths: ["/Projects/App/App.xcodeproj/project.pbxproj"]
        )
        let count = OSAllocatedUnfairLock(initialState: 0)
        let context = WatcherContext(
            filter: filter,
            debounceInterval: 0.05,
            onChange: {
                count.withLock { $0 += 1 }
            }
        )

        context.handle(paths: [
            "/Projects/App/.git/HEAD",
            "/Projects/App/.build/debug/output",
            "/Projects/App/SourcePackages/checkouts/Dep/Package.swift",
        ])

        try await Task.sleep(for: .milliseconds(120))
        #expect(count.withLock { $0 } == 0)
        context.cancelPending()
    }
}

@Suite("WorkspaceReloadCoordinator")
struct WorkspaceReloadCoordinatorTests {

    @Test("Serializes reloads and runs a trailing pass for mid-flight requests")
    func serializesAndCoalesces() async {
        let state = OSAllocatedUnfairLock(initialState: (started: 0, maxConcurrent: 0, inFlight: 0, finished: 0))

        let coordinator = WorkspaceReloadCoordinator {
            state.withLock { s in
                s.started += 1
                s.inFlight += 1
                s.maxConcurrent = max(s.maxConcurrent, s.inFlight)
            }
            try? await Task.sleep(for: .milliseconds(40))
            state.withLock { s in
                s.inFlight -= 1
                s.finished += 1
            }
        }

        async let first: Void = coordinator.requestReload()
        // Let the first reload start before stacking follow-ups.
        try? await Task.sleep(for: .milliseconds(5))
        async let second: Void = coordinator.requestReload()
        async let third: Void = coordinator.requestReload()
        _ = await (first, second, third)

        let snapshot = state.withLock { $0 }
        #expect(snapshot.maxConcurrent == 1)
        #expect(snapshot.started == 2)
        #expect(snapshot.finished == 2)
    }
}
