import Foundation
import Testing
@testable import XcodeBSP

@Suite("ConfigLoader.renderConfig")
struct RenderConfigTests {

    private func parse(_ json: String) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(obj as? [String: Any])
    }

    @Test("Includes BSP discovery fields and the workspace")
    func includesCoreFields() throws {
        let json = try ConfigLoader.renderConfig(argv: ["/bin/xcode-bsp"], workspace: "App.xcodeproj")
        let dict = try parse(json)

        #expect(dict["name"] as? String == "xcode-bsp")
        #expect(dict["bspVersion"] as? String == "2.1.0")
        #expect(dict["languages"] as? [String] == ["swift"])
        #expect(dict["argv"] as? [String] == ["/bin/xcode-bsp"])
        #expect(dict["workspace"] as? String == "App.xcodeproj")
    }

    @Test("Omits optional fields when nil")
    func omitsNilOptionals() throws {
        let json = try ConfigLoader.renderConfig(argv: ["x"], workspace: "A.xcodeproj")
        let dict = try parse(json)

        #expect(dict["platform"] == nil)
        #expect(dict["buildRoot"] == nil)
        #expect(dict["indexingEnabled"] == nil)
    }

    @Test("Emits optional fields with camelCase keys when provided")
    func includesProvidedOptionals() throws {
        let json = try ConfigLoader.renderConfig(
            argv: ["x"],
            workspace: "A.xcodeproj",
            platform: "iphonesimulator",
            buildRoot: ".build/derived-data",
            indexingEnabled: false
        )
        let dict = try parse(json)

        #expect(dict["platform"] as? String == "iphonesimulator")
        #expect(dict["buildRoot"] as? String == ".build/derived-data")
        #expect(dict["indexingEnabled"] as? Bool == false)
    }

    @Test("Does not escape slashes in paths")
    func doesNotEscapeSlashes() throws {
        let json = try ConfigLoader.renderConfig(
            argv: ["/usr/local/bin/xcode-bsp"],
            workspace: "A.xcodeproj"
        )
        #expect(json.contains("/usr/local/bin/xcode-bsp"))
        #expect(!json.contains("\\/"))
    }

    @Test("Round-trips back into a decodable BuildServerConfig")
    func roundTrips() throws {
        let json = try ConfigLoader.renderConfig(
            argv: ["x"],
            workspace: "A.xcodeproj",
            platform: "macosx",
            buildRoot: "build",
            indexingEnabled: true
        )
        let config = try JSONDecoder().decode(BuildServerConfig.self, from: Data(json.utf8))

        #expect(config.workspace == "A.xcodeproj")
        #expect(config.platform == "macosx")
        #expect(config.buildRoot == "build")
        #expect(config.indexingEnabled == true)
    }
}
