import Testing
@testable import SourceKitXcodeBSP

@Suite("BuildServiceProviderFactory.environmentAssignments")
struct BuildServiceProviderFactoryTests {

    @Test("Sets UseSynchronousBuildDescriptionSerialization to YES, overwriting")
    func setsSyncSerializationFlagWhenTrue() {
        let assignments = BuildServiceProviderFactory.environmentAssignments(
            serviceBundlePath: nil,
            synchronousBuildDescriptionSerialization: true,
            xcodeBundledServiceBundlePath: nil,
            coLocatedServiceBundlePath: nil
        )

        #expect(assignments.contains(
            .init(key: "UseSynchronousBuildDescriptionSerialization", value: "YES", overwrite: true)
        ))
    }

    @Test("Sets UseSynchronousBuildDescriptionSerialization to NO, overwriting")
    func setsSyncSerializationFlagWhenFalse() {
        let assignments = BuildServiceProviderFactory.environmentAssignments(
            serviceBundlePath: nil,
            synchronousBuildDescriptionSerialization: false,
            xcodeBundledServiceBundlePath: nil,
            coLocatedServiceBundlePath: nil
        )

        #expect(assignments.contains(
            .init(key: "UseSynchronousBuildDescriptionSerialization", value: "NO", overwrite: true)
        ))
    }

    @Test("An explicit serviceBundlePath overwrites any inherited value, and wins over every fallback")
    func explicitServiceBundlePathOverwrites() {
        let assignments = BuildServiceProviderFactory.environmentAssignments(
            serviceBundlePath: "/explicit/SWBBuildService",
            synchronousBuildDescriptionSerialization: true,
            xcodeBundledServiceBundlePath: "/xcode/SWBBuildService",
            coLocatedServiceBundlePath: "/colocated/SWBBuildService"
        )

        #expect(assignments.contains(
            .init(key: "SWBBUILDSERVICE_PATH", value: "/explicit/SWBBuildService", overwrite: true)
        ))
        // The explicit path wins outright; no fallback must also be emitted.
        #expect(assignments.filter { $0.key == "SWBBUILDSERVICE_PATH" }.count == 1)
    }

    @Test("The Xcode-bundled path takes priority over the co-located path, without overwriting")
    func xcodeBundledPathTakesPriorityOverCoLocated() {
        let assignments = BuildServiceProviderFactory.environmentAssignments(
            serviceBundlePath: nil,
            synchronousBuildDescriptionSerialization: true,
            xcodeBundledServiceBundlePath: "/xcode/SWBBuildService",
            coLocatedServiceBundlePath: "/colocated/SWBBuildService"
        )

        #expect(assignments.contains(
            .init(key: "SWBBUILDSERVICE_PATH", value: "/xcode/SWBBuildService", overwrite: false)
        ))
        #expect(assignments.filter { $0.key == "SWBBUILDSERVICE_PATH" }.count == 1)
    }

    @Test("The co-located fallback path does not overwrite an inherited value")
    func coLocatedPathDoesNotOverwrite() {
        let assignments = BuildServiceProviderFactory.environmentAssignments(
            serviceBundlePath: nil,
            synchronousBuildDescriptionSerialization: true,
            xcodeBundledServiceBundlePath: nil,
            coLocatedServiceBundlePath: "/colocated/SWBBuildService"
        )

        #expect(assignments.contains(
            .init(key: "SWBBUILDSERVICE_PATH", value: "/colocated/SWBBuildService", overwrite: false)
        ))
    }

    @Test("Falls back to the co-located path when no Xcode-bundled path is available")
    func fallsBackToCoLocatedWhenXcodeBundledUnavailable() {
        let assignments = BuildServiceProviderFactory.environmentAssignments(
            serviceBundlePath: nil,
            synchronousBuildDescriptionSerialization: true,
            xcodeBundledServiceBundlePath: nil,
            coLocatedServiceBundlePath: "/colocated/SWBBuildService"
        )

        #expect(assignments.contains(
            .init(key: "SWBBUILDSERVICE_PATH", value: "/colocated/SWBBuildService", overwrite: false)
        ))
    }

    @Test("Omits SWBBUILDSERVICE_PATH when no path is available from any source")
    func omitsServiceBundlePathWhenUnavailable() {
        let assignments = BuildServiceProviderFactory.environmentAssignments(
            serviceBundlePath: nil,
            synchronousBuildDescriptionSerialization: true,
            xcodeBundledServiceBundlePath: nil,
            coLocatedServiceBundlePath: nil
        )

        #expect(!assignments.contains { $0.key == "SWBBUILDSERVICE_PATH" })
    }
}

@Suite("BuildServiceProviderFactory.preferredXcodeBundledServiceBundlePath")
struct PreferredXcodeBundledPathTests {

    @Test("Prefers Xcode's bundled service at the minimum supported version")
    func prefersAtMinimumVersion() {
        let path = BuildServiceProviderFactory.preferredXcodeBundledServiceBundlePath(
            xcodeVersion: XcodeVersion(major: 27, minor: 0),
            xcodeServiceBundlePath: "/xcode/SWBBuildService"
        )

        #expect(path == "/xcode/SWBBuildService")
    }

    @Test("Prefers Xcode's bundled service above the minimum supported version")
    func prefersAboveMinimumVersion() {
        let path = BuildServiceProviderFactory.preferredXcodeBundledServiceBundlePath(
            xcodeVersion: XcodeVersion(major: 28, minor: 1),
            xcodeServiceBundlePath: "/xcode/SWBBuildService"
        )

        #expect(path == "/xcode/SWBBuildService")
    }

    @Test("Does not prefer Xcode's bundled service below the minimum supported version")
    func doesNotPreferBelowMinimumVersion() {
        let path = BuildServiceProviderFactory.preferredXcodeBundledServiceBundlePath(
            xcodeVersion: XcodeVersion(major: 26, minor: 0),
            xcodeServiceBundlePath: "/xcode/SWBBuildService"
        )

        #expect(path == nil)
    }

    @Test("Returns nil when Xcode's service bundle couldn't be located, even on a new enough Xcode")
    func returnsNilWhenServicePathUnavailable() {
        let path = BuildServiceProviderFactory.preferredXcodeBundledServiceBundlePath(
            xcodeVersion: XcodeVersion(major: 27, minor: 0),
            xcodeServiceBundlePath: nil
        )

        #expect(path == nil)
    }
}
