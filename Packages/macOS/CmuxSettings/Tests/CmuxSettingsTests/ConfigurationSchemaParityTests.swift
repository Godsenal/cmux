import CmuxSettings
import Foundation
import Testing

@Suite("cmux.json schema parity")
struct ConfigurationSchemaParityTests {
    @Test("schema validates every public keyboard shortcut action")
    func schemaValidatesEveryShortcutAction() throws {
        let schemaURL = repositoryRootURL()
            .appendingPathComponent("web/data/cmux.schema.json")
        let data = try Data(contentsOf: schemaURL)
        let root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let properties = try #require(root["properties"] as? [String: Any])
        let shortcuts = try #require(properties["shortcuts"] as? [String: Any])
        let shortcutProperties = try #require(shortcuts["properties"] as? [String: Any])
        let bindings = try #require(shortcutProperties["bindings"] as? [String: Any])
        let propertyNames = try #require(bindings["propertyNames"] as? [String: Any])
        let schemaActionIDs = Set(try #require(propertyNames["enum"] as? [String]))
        let runtimeActionIDs = Set(ShortcutAction.allCases.map(\.rawValue))

        #expect(schemaActionIDs == runtimeActionIDs)
    }

    private func repositoryRootURL() -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            directory.deleteLastPathComponent()
        }
        return directory
    }
}
