import Foundation
import Testing
@testable import Orbit

struct ScriptWidgetsTests {
    @Test func manifestNeedsIdNameAndScriptInsideTheFolder() {
        let ok = ScriptWidgets.parseManifest(Data(#"{"id":"bat tery!","name":"Battery","run":"run.sh","interval":60}"#.utf8))
        #expect(ok?.id == "battery")
        #expect(ok?.interval == 60)
        #expect(ScriptWidgets.parseManifest(Data(#"{"id":"x","name":"X","run":"../evil.sh"}"#.utf8)) == nil)
        #expect(ScriptWidgets.parseManifest(Data(#"{"id":"","name":"X","run":"a"}"#.utf8)) == nil)
        #expect(ScriptWidgets.parseManifest(Data("not json".utf8)) == nil)
    }

    @Test func outputUsesTheLastJSONLine() {
        let text = """
        fetching…
        {"title":"Battery","value":"84%","progress":0.84,"items":[{"title":"a","value":"1"}]}
        """
        let o = ScriptWidgets.parseOutput(text)
        #expect(o?.value == "84%")
        #expect(o?.progress == 0.84)
        #expect(o?.items?.first?.title == "a")
        #expect(ScriptWidgets.parseOutput("nothing here") == nil)
    }

    @Test func categoriesAndColours() {
        #expect(ScriptWidgets.category("Developers") == .developers)
        #expect(ScriptWidgets.category("nope") == .productivity)
        #expect(ScriptWidgets.color("#FF0000") != nil)
        #expect(ScriptWidgets.color("red") == nil)
    }

    @Test func exampleWidgetsAreValid() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let examples = root.appendingPathComponent("sdk/examples")
        let dirs = try FileManager.default.contentsOfDirectory(at: examples, includingPropertiesForKeys: nil)
        #expect(dirs.count >= 3)
        for dir in dirs {
            let m = ScriptWidgets.parseManifest(try Data(contentsOf: dir.appendingPathComponent("widget.json")))
            #expect(m != nil, "\(dir.lastPathComponent) manifest")
            if let m { #expect(FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent(m.run).path)) }
        }
    }
}

struct StorageTests {
    struct Stamp: Codable, Equatable { var at: Date }
    @Test func datesSurviveSaveAndLoad() {
        let name = "test-storage-\(UUID().uuidString)"
        let value = Stamp(at: Date(timeIntervalSince1970: 1_800_000_000))
        Storage.save(value, to: name)
        #expect(Storage.load(Stamp.self, from: name) == value)
        try? FileManager.default.removeItem(at: Storage.folder.appendingPathComponent("\(name).json"))
    }
}
