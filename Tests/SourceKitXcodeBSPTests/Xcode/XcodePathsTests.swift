import Foundation
import Testing
@testable import SourceKitXcodeBSP

@Suite("XcodePaths Tests")
struct XcodePathsTests {

    // MARK: - XcodeVersion

    @Test("XcodeVersion parses major.minor")
    func versionParsesMajorMinor() {
        let version = XcodeVersion(versionString: "16.0")

        #expect(version.major == 16)
        #expect(version.minor == 0)
        #expect(version.patch == 0)
    }

    @Test("XcodeVersion parses major.minor.patch")
    func versionParsesMajorMinorPatch() {
        let version = XcodeVersion(versionString: "16.2.1")

        #expect(version.major == 16)
        #expect(version.minor == 2)
        #expect(version.patch == 1)
    }

    @Test("XcodeVersion handles single number")
    func versionHandlesSingleNumber() {
        let version = XcodeVersion(versionString: "16")

        #expect(version.major == 16)
        #expect(version.minor == 0)
        #expect(version.patch == 0)
    }

    @Test("XcodeVersion handles empty string")
    func versionHandlesEmptyString() {
        let version = XcodeVersion(versionString: "")

        #expect(version.major == 0)
        #expect(version.minor == 0)
        #expect(version.patch == 0)
    }

    @Test("XcodeVersion isSupported for Xcode 26+")
    func versionIsSupportedXcode26() {
        let v26 = XcodeVersion(major: 26, minor: 0)
        let v26_2 = XcodeVersion(major: 26, minor: 2)
        let v27 = XcodeVersion(major: 27, minor: 0)

        #expect(v26.isSupported)
        #expect(v26_2.isSupported)
        #expect(v27.isSupported)
    }

    @Test("XcodeVersion isSupported false for Xcode 25")
    func versionNotSupportedXcode25() {
        let v25 = XcodeVersion(major: 25, minor: 4)
        let v16 = XcodeVersion(major: 16, minor: 0)

        #expect(!v25.isSupported)
        #expect(!v16.isSupported)
    }

    @Test("XcodeVersion description formats correctly")
    func versionDescription() {
        let v16_0 = XcodeVersion(major: 16, minor: 0)
        let v16_2_1 = XcodeVersion(major: 16, minor: 2, patch: 1)

        #expect(v16_0.description == "16.0")
        #expect(v16_2_1.description == "16.2.1")
    }

    // MARK: - Error Messages

    @Test("XcodePathError provides helpful messages")
    func errorMessages() {
        let errors: [XcodePathError] = [
            .developerDirNotFound("/invalid/path"),
            .xcodeSelectFailed(underlying: nil),
            .infoPlistNotFound("/path/to/Info.plist"),
            .infoPlistInvalid,
            .versionNotFound,
            .unsupportedVersion(XcodeVersion(major: 15, minor: 0)),
            .swbBuildServiceNotFound
        ]

        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }

    @Test("Unsupported version error includes version number")
    func unsupportedVersionErrorIncludesVersion() {
        let error = XcodePathError.unsupportedVersion(XcodeVersion(major: 25, minor: 4))

        #expect(error.errorDescription?.contains("25.4") == true)
        #expect(error.errorDescription?.contains("26") == true)
    }
}
