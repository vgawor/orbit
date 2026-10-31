import Foundation
import Testing
@testable import ViktorKit

struct SupportFolderTests {
    @Test func oldViktorFolderMovesToOrbit() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("support-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let old = base.appendingPathComponent("Viktor")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: old.appendingPathComponent("notes.json"))

        let dir = APIConfig.supportFolder(in: base)
        #expect(dir.lastPathComponent == "Orbit")
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("notes.json").path))
        #expect(!fm.fileExists(atPath: old.path))
    }
}
