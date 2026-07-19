import Testing
@testable import SourceKitXcodeBSP

@Suite("BuildServiceProviderFactory.environmentAssignments")
struct BuildServiceProviderFactoryTests {

    @Test("Sets UseSynchronousBuildDescriptionSerialization to YES, overwriting")
    func setsSyncSerializationFlagWhenTrue() {
        let assignments = BuildServiceProviderFactory.environmentAssignments(
            serviceBundlePath: nil,
            synchronousBuildDescriptionSerialization: true,
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
            coLocatedServiceBundlePath: nil
        )

        #expect(assignments.contains(
            .init(key: "UseSynchronousBuildDescriptionSerialization", value: "NO", overwrite: true)
        ))
    }

    @Test("An explicit serviceBundlePath overwrites any inherited value")
    func explicitServiceBundlePathOverwrites() {
        let assignments = BuildServiceProviderFactory.environmentAssignments(
            serviceBundlePath: "/explicit/SWBBuildService",
            synchronousBuildDescriptionSerialization: true,
            coLocatedServiceBundlePath: "/colocated/SWBBuildService"
        )

        #expect(assignments.contains(
            .init(key: "SWBBUILDSERVICE_PATH", value: "/explicit/SWBBuildService", overwrite: true)
        ))
        // The explicit path wins outright; the co-located fallback must not also be emitted.
        #expect(assignments.filter { $0.key == "SWBBUILDSERVICE_PATH" }.count == 1)
    }

    @Test("The co-located fallback path does not overwrite an inherited value")
    func coLocatedPathDoesNotOverwrite() {
        let assignments = BuildServiceProviderFactory.environmentAssignments(
            serviceBundlePath: nil,
            synchronousBuildDescriptionSerialization: true,
            coLocatedServiceBundlePath: "/colocated/SWBBuildService"
        )

        #expect(assignments.contains(
            .init(key: "SWBBUILDSERVICE_PATH", value: "/colocated/SWBBuildService", overwrite: false)
        ))
    }

    @Test("Omits SWBBUILDSERVICE_PATH when neither an explicit nor co-located path is available")
    func omitsServiceBundlePathWhenUnavailable() {
        let assignments = BuildServiceProviderFactory.environmentAssignments(
            serviceBundlePath: nil,
            synchronousBuildDescriptionSerialization: true,
            coLocatedServiceBundlePath: nil
        )

        #expect(!assignments.contains { $0.key == "SWBBUILDSERVICE_PATH" })
    }
}
