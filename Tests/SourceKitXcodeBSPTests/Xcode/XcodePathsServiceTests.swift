import Foundation
import Testing
@testable import SourceKitXcodeBSP

@Suite("XcodePathsService DEVELOPER_DIR override")
struct XcodePathsServiceTests {

    @Test("Throws developerDirNotFound when the DEVELOPER_DIR override does not exist")
    func developerDirOverrideMissingThrows() async throws {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-paths-service-tests-\(UUID().uuidString)")
            .path
        let service = XcodePathsService(
            environment: FakeEnvironmentRepository(values: ["DEVELOPER_DIR": missingPath])
        )

        await #expect(throws: XcodePathError.self) {
            _ = try await service.resolve()
        }
    }

    @Test("Adopts the DEVELOPER_DIR override instead of falling back to xcode-select")
    func developerDirOverrideIsUsed() async throws {
        // A real, but non-Xcode, `.app/Contents/Developer` layout. `resolve()` must fail
        // further downstream (missing Info.plist) with a path derived from this directory —
        // proving the injected override was adopted rather than silently falling back to
        // the machine's real `xcode-select -p` output.
        let appName = "FakeXcode-\(UUID().uuidString).app"
        let xcodeAppDir = FileManager.default.temporaryDirectory.appendingPathComponent(appName)
        let developerDir = xcodeAppDir.appendingPathComponent("Contents/Developer")
        try FileManager.default.createDirectory(at: developerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: xcodeAppDir) }

        let service = XcodePathsService(
            environment: FakeEnvironmentRepository(values: ["DEVELOPER_DIR": developerDir.path])
        )

        do {
            _ = try await service.resolve()
            Issue.record("Expected resolve() to throw for a directory with no Info.plist")
        } catch let XcodePathError.infoPlistNotFound(path) {
            #expect(path.contains(appName))
        } catch {
            Issue.record("Expected XcodePathError.infoPlistNotFound, got \(error)")
        }
    }
}
