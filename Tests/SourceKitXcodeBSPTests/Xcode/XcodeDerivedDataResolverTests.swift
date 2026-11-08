import Foundation
import Testing
@testable import SourceKitXcodeBSP

@Suite("XcodeDerivedDataResolver.parseList")
struct ParseListTests {

    @Test("Parses schemes and targets from .xcodeproj listing output")
    func parsesProjectListing() throws {
        let json = Data("""
        { "project": { "name": "App", "configurations": ["Debug"],
          "schemes": ["Account", "App"], "targets": ["App", "AppTests"] } }
        """.utf8)

        let listing = try #require(XcodeDerivedDataResolver.parseList(json))

        #expect(listing.schemes == ["Account", "App"])
        #expect(listing.targets == ["App", "AppTests"])
    }

    @Test("Parses .xcworkspace listing, which carries schemes but no targets")
    func parsesWorkspaceListing() throws {
        // Real shape: workspace targets live in the contained projects, so the key is absent.
        let json = Data("""
        { "workspace": { "name": "Demo", "schemes": ["Dependency", "test"] } }
        """.utf8)

        let listing = try #require(XcodeDerivedDataResolver.parseList(json))

        #expect(listing.schemes == ["Dependency", "test"])
        #expect(listing.targets.isEmpty)
    }

    @Test("Returns nil for output that is not a recognizable listing")
    func returnsNilForUnrecognizedOutput() {
        #expect(XcodeDerivedDataResolver.parseList(Data("not json".utf8)) == nil)
        #expect(XcodeDerivedDataResolver.parseList(Data("{}".utf8)) == nil)
    }
}

@Suite("XcodeDerivedDataResolver.candidateSchemes")
struct CandidateSchemesTests {
    // Abridged from real `xcodebuild -list -json` output for NetNewsWire: the SPM-module schemes
    // sort alphabetically first but are absent from `targets`, and are exactly the schemes that
    // report no build settings.
    private let schemes = [
        "Account", "AccountTests", "Articles", "NetNewsWire",
        "NetNewsWire iOS Widget Extension", "NetNewsWire-iOS", "RSCore", "Secrets",
    ]
    private let targets = [
        "NetNewsWire", "NetNewsWire iOS Widget Extension", "NetNewsWire-iOS", "NetNewsWireTests",
    ]

    @Test("Ranks target-backed schemes ahead of non-target-backed ones, dropping nothing")
    func ranksTargetBackedFirstWithoutDropping() throws {
        let candidates = XcodeDerivedDataResolver.candidateSchemes(
            schemes: schemes, targets: targets, containerPath: "/src/NetNewsWire.xcodeproj"
        )

        // Every scheme stays reachable; target-backing only decides order.
        #expect(candidates.count == schemes.count)
        #expect(Set(candidates) == Set(schemes))

        let backed = ["NetNewsWire", "NetNewsWire iOS Widget Extension", "NetNewsWire-iOS"]
        let worstBackedRank = try #require(
            backed.compactMap { candidates.firstIndex(of: $0) }.max()
        )
        let bestUnbackedRank = try #require(
            ["Account", "RSCore", "Secrets"].compactMap { candidates.firstIndex(of: $0) }.min()
        )
        #expect(worstBackedRank < bestUnbackedRank)
    }

    @Test("Keeps a scheme named unlike any target reachable, just ranked last")
    func keepsCustomNamedSchemeReachable() {
        // Verified against real xcodebuild: a shared scheme named `ZzCustomNamed` that builds the
        // `NetNewsWire` target is absent from `targets` yet still reports a valid DerivedData
        // OBJROOT. Target-backing is sufficient, not necessary, so it must not be an exclusion.
        let candidates = XcodeDerivedDataResolver.candidateSchemes(
            schemes: schemes + ["ZzCustomNamed"],
            targets: targets,
            containerPath: "/src/NetNewsWire.xcodeproj"
        )

        #expect(candidates.contains("ZzCustomNamed"))
        #expect(candidates.last == "ZzCustomNamed")
    }

    @Test("Probes the container-named scheme first, so the usual case resolves in one subprocess")
    func prefersContainerNameMatchFirst() {
        let candidates = XcodeDerivedDataResolver.candidateSchemes(
            schemes: schemes, targets: targets, containerPath: "/src/NetNewsWire.xcodeproj"
        )

        // Probe 1 hits in the common case, so resolution costs a single extra subprocess.
        #expect(candidates.first == "NetNewsWire")
        // Exact match, then the other target-backed schemes, then the rest.
        #expect(
            candidates.prefix(3)
                == ["NetNewsWire", "NetNewsWire iOS Widget Extension", "NetNewsWire-iOS"]
        )
    }

    @Test("Degrades smoothly for an .xcworkspace, where no targets are reported")
    func ordersWorkspaceSchemesWithoutTargets() {
        let candidates = XcodeDerivedDataResolver.candidateSchemes(
            schemes: ["Dependency", "Dependency2", "Demo"],
            targets: [],
            containerPath: "/src/Demo.xcworkspace"
        )

        // Container-name match is promoted; the rest keep listing order.
        #expect(candidates == ["Demo", "Dependency", "Dependency2"])
    }

    @Test("Still probes schemes when none is target-backed")
    func probesEvenWhenNoneTargetBacked() {
        let candidates = XcodeDerivedDataResolver.candidateSchemes(
            schemes: ["OnlyPackageScheme"],
            targets: ["SomeUnrelatedTarget"],
            containerPath: "/src/App.xcodeproj"
        )

        #expect(candidates == ["OnlyPackageScheme"])
    }

    @Test("Prefers a target-backed scheme over a mere container-name prefix match")
    func targetBackedBeatsPrefixMatch() {
        let candidates = XcodeDerivedDataResolver.candidateSchemes(
            schemes: ["App-CustomConfig", "SomeTarget"],
            targets: ["SomeTarget"],
            containerPath: "/src/App.xcodeproj"
        )

        #expect(candidates == ["SomeTarget", "App-CustomConfig"])
    }

    @Test("Returns empty when there are no schemes at all")
    func returnsEmptyWithoutSchemes() {
        #expect(
            XcodeDerivedDataResolver.candidateSchemes(
                schemes: [], targets: ["App"], containerPath: "/src/App.xcodeproj"
            ).isEmpty
        )
    }
}

@Suite("XcodeDerivedDataResolver.objroot")
struct ObjrootTests {

    @Test("Extracts OBJROOT from -showBuildSettings -json output")
    func extractsObjroot() {
        let json = Data("""
        [ { "action": "build", "target": "App",
            "buildSettings": { "ARCHS": "arm64",
              "OBJROOT": "/dd/App-abc/Build/Intermediates.noindex" } } ]
        """.utf8)

        #expect(
            XcodeDerivedDataResolver.objroot(fromSettingsJSON: json)
                == "/dd/App-abc/Build/Intermediates.noindex"
        )
    }

    @Test("Returns nil for the empty array a package-product scheme produces")
    func returnsNilForEmptyArray() {
        #expect(XcodeDerivedDataResolver.objroot(fromSettingsJSON: Data("[]".utf8)) == nil)
    }

    @Test("Tolerates non-string values in unrelated build settings")
    func toleratesNonStringValues() {
        // A strict [String: String] decode would fail the whole payload here.
        let json = Data("""
        [ { "buildSettings": { "SOME_LIST": ["a","b"], "SOME_FLAG": true,
              "OBJROOT": "/dd/App-abc/Build/Intermediates.noindex" } } ]
        """.utf8)

        #expect(
            XcodeDerivedDataResolver.objroot(fromSettingsJSON: json)
                == "/dd/App-abc/Build/Intermediates.noindex"
        )
    }

    @Test("Returns nil when OBJROOT is absent or empty")
    func returnsNilWhenObjrootMissing() {
        #expect(
            XcodeDerivedDataResolver.objroot(
                fromSettingsJSON: Data(#"[{"buildSettings":{"ARCHS":"arm64"}}]"#.utf8)
            ) == nil
        )
        #expect(
            XcodeDerivedDataResolver.objroot(
                fromSettingsJSON: Data(#"[{"buildSettings":{"OBJROOT":""}}]"#.utf8)
            ) == nil
        )
    }

    @Test("Returns nil for unparseable output")
    func returnsNilForGarbage() {
        #expect(XcodeDerivedDataResolver.objroot(fromSettingsJSON: Data("nope".utf8)) == nil)
    }
}

@Suite("XcodeDerivedDataResolver.derivedDataRoot")
struct DerivedDataRootTests {

    @Test("Strips the Build/Intermediates.noindex suffix")
    func stripsSuffix() {
        #expect(
            XcodeDerivedDataResolver.derivedDataRoot(
                fromObjroot: "/Users/me/Library/Developer/Xcode/DerivedData/App-abc123"
                    + "/Build/Intermediates.noindex"
            ) == "/Users/me/Library/Developer/Xcode/DerivedData/App-abc123"
        )
    }

    @Test("Returns nil for a legacy/custom build location")
    func returnsNilForLegacyLocation() {
        // A bare or -target invocation reports this project-local form.
        #expect(XcodeDerivedDataResolver.derivedDataRoot(fromObjroot: "/src/App/build") == nil)
    }
}
