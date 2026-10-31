import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Viktor

@Suite("Notch state and Dot nudges") @MainActor
struct NotchStateTests {
    let meeting = Attention(id: "meeting", symbol: "video", tint: .blue, label: "3m", priority: 5)

    @Test func dotNudgesUntilYouLook() {
        let vm = NotchViewModel()
        vm.updateNudge(meeting)
        #expect(vm.nudge?.id == "meeting")
        vm.state = .peek                       // looking counts as seen
        #expect(vm.nudge == nil)
        vm.state = .closed
        vm.updateNudge(meeting)
        #expect(vm.nudge == nil)               // not again for 15 minutes
    }

    @Test func noNudgeWhilePresentingOrOpen() {
        let vm = NotchViewModel()
        vm.presenting = true
        vm.updateNudge(meeting)
        #expect(vm.nudge == nil)
        vm.presenting = false
        vm.state = .open
        vm.updateNudge(meeting)
        #expect(vm.nudge == nil)
    }

    @Test func sizesGrowFromClosedToOpen() {
        let vm = NotchViewModel()
        let closed = vm.size(for: .closed), peek = vm.size(for: .peek), open = vm.size(for: .open)
        #expect(closed == vm.notchSize)
        #expect(peek.width > closed.width && peek.height > closed.height)
        #expect(open.width > peek.width && open.height > peek.height)
    }

    @Test func keyboardToggle() {
        let vm = NotchViewModel()
        vm.toggleFromKeyboard()
        #expect(vm.state == .open)
        vm.toggleFromKeyboard()
        #expect(vm.state == .closed)
    }
}

@Suite("File converter") @MainActor
struct ConverterTests {
    private func pngFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("viktor-conv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.setColor(.systemPink, atX: 3, y: 3)
        let url = dir.appendingPathComponent("photo.png")
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    @Test func offersOtherFormats() throws {
        let png = try pngFile()
        #expect(FileConverter.formats(for: png) == [.jpeg, .heic, .tiff, .pdf])
        #expect(FileConverter.formats(for: URL(fileURLWithPath: "/tmp/a.txt")).isEmpty)
        #expect(FileConverter.formats(for: URL(fileURLWithPath: "/tmp/a.mov")) == [.mp4, .m4a])
    }

    @Test func neverOverwrites() throws {
        let png = try pngFile()
        let first = FileConverter.outputURL(for: png, ext: "png")
        #expect(first.lastPathComponent == "photo 2.png")
        #expect(FileConverter.outputURL(for: png, ext: "jpeg").lastPathComponent == "photo.jpeg")
    }

    @Test(arguments: [FileConverter.Format.jpeg, .heic, .tiff, .pdf])
    func convertsImages(_ format: FileConverter.Format) async throws {
        let png = try pngFile()
        let out = try await FileConverter.convert(png, to: format)
        let size = try #require(try out.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size > 0)
        #expect(FileConverter.type(of: out)?.conforms(to: format.utType) == true)
    }

    @Test func unreadableFileFails() async throws {
        let dir = try pngFile().deletingLastPathComponent()
        let bad = dir.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: bad)
        await #expect(throws: (any Error).self) { _ = try await FileConverter.convert(bad, to: .jpeg) }
    }
}
