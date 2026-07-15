import Foundation
import Testing
@testable import SourceKitXcodeBSP

@Suite("ConfigLoader.renderConfig")
struct RenderConfigTests {

    private func parse(_ json: String) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(obj as? [String: Any])
    }

    @Test("Includes BSP discovery fields and the workspace")
    func includesCoreFields() throws {
        let json = try ConfigLoader.renderConfig(argv: ["/bin/sourcekit-xcode-bsp"], workspace: "App.xcodeproj")
        let dict = try parse(json)

        #expect(dict["name"] as? String == "sourcekit-xcode-bsp")
        #expect(dict["bspVersion"] as? String == "2.1.0")
        #expect(dict["languages"] as? [String] == ["swift"])
        #expect(dict["argv"] as? [String] == ["/bin/sourcekit-xcode-bsp"])
        #expect(dict["workspace"] as? String == "App.xcodeproj")
    }

    @Test("Omits optional fields when nil")
    func omitsNilOptionals() throws {
        let json = try ConfigLoader.renderConfig(argv: ["x"], workspace: "A.xcodeproj")
        let dict = try parse(json)

        #expect(dict["platform"] == nil)
        #expect(dict["buildRoot"] == nil)
    }

    @Test("Emits optional fields with camelCase keys when provided")
    func includesProvidedOptionals() throws {
        let json = try ConfigLoader.renderConfig(
            argv: ["x"],
            workspace: "A.xcodeproj",
            platform: "iphonesimulator",
            buildRoot: ".build/derived-data"
        )
        let dict = try parse(json)

        #expect(dict["platform"] as? String == "iphonesimulator")
        #expect(dict["buildRoot"] as? String == ".build/derived-data")
    }

    @Test("Does not escape slashes in paths")
    func doesNotEscapeSlashes() throws {
        let json = try ConfigLoader.renderConfig(
            argv: ["/usr/local/bin/sourcekit-xcode-bsp"],
            workspace: "A.xcodeproj"
        )
        #expect(json.contains("/usr/local/bin/sourcekit-xcode-bsp"))
        #expect(!json.contains("\\/"))
    }

    @Test("Round-trips back into a decodable BuildServerConfig")
    func roundTrips() throws {
        let json = try ConfigLoader.renderConfig(
            argv: ["x"],
            workspace: "A.xcodeproj",
            platform: "macosx",
            buildRoot: "build"
        )
        let config = try JSONDecoder().decode(BuildServerConfig.self, from: Data(json.utf8))

        #expect(config.workspace == "A.xcodeproj")
        #expect(config.platform == "macosx")
        #expect(config.buildRoot == "build")
    }

    @Test("Does not emit indexingEnabled")
    func doesNotEmitIndexingEnabled() throws {
        let json = try ConfigLoader.renderConfig(
            argv: ["x"],
            workspace: "A.xcodeproj",
            platform: "iphonesimulator",
            buildRoot: ".build/derived-data"
        )
        let dict = try parse(json)
        #expect(dict["indexingEnabled"] == nil)
    }

    @Test("Decodes configs that still contain legacy indexingEnabled")
    func decodesLegacyIndexingEnabled() throws {
        // Pre-removal configs may still set this key; unknown keys must not fail decode.
        let json = """
        {
          "workspace": "A.xcodeproj",
          "indexingEnabled": false
        }
        """
        let config = try JSONDecoder().decode(BuildServerConfig.self, from: Data(json.utf8))
        #expect(config.workspace == "A.xcodeproj")
    }
}
