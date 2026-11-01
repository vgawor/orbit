import AppKit
import SwiftUI

/// A photo slideshow from a folder you pick (Dots: "photo collections and slideshows").
@MainActor
@Observable
final class PhotosModule: NotchModule {
    let id = "photos"
    let title = "Photos"
    let symbol = "photo.on.rectangle"

    private(set) var folder: URL? = UserDefaults.standard.string(forKey: "photos.folder").map { URL(fileURLWithPath: $0) }
    private(set) var files: [URL] = []
    private(set) var index = 0
    private(set) var image: NSImage?
    var interval: Double = UserDefaults.standard.object(forKey: "photos.interval") as? Double ?? 10 {
        didSet { UserDefaults.standard.set(interval, forKey: "photos.interval"); restartTimer() }
    }
    var paused = false
    private var timer: Timer?

    func start() {
        loadFolder()
        restartTimer()
    }

    func stop() { timer?.invalidate() }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use folder"
        panel.message = "Choose a folder of photos for the slideshow"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        UserDefaults.standard.set(url.path, forKey: "photos.folder")
        loadFolder()
    }

    private func loadFolder() {
        guard let folder else { return }
        let exts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "webp"]
        Task {
            let found = await Task.detached {
                (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
                    .filter { exts.contains($0.pathExtension.lowercased()) }.shuffled() ?? []
            }.value
            files = found
            index = 0
            show()
        }
    }

    func next() { guard !files.isEmpty else { return }; index = (index + 1) % files.count; show() }
    func previous() { guard !files.isEmpty else { return }; index = (index - 1 + files.count) % files.count; show() }

    private func show() {
        guard files.indices.contains(index) else { image = nil; return }
        let url = files[index]
        Task {
            // Downscale off the main thread so big photos don't stutter the notch.
            let data = await Task.detached { () -> Data? in
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceThumbnailMaxPixelSize: 1200,
                          kCGImageSourceCreateThumbnailWithTransform: true,
                      ] as CFDictionary) else { return nil }
                return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [:])
            }.value
            withAnimation(.easeInOut(duration: 0.6)) { image = data.flatMap(NSImage.init(data:)) }
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(interval, 3), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.paused == false { self?.next() } }
        }
    }

    // MARK: Views

    var homeCard: AnyView? { AnyView(PhotoCard(module: self, compact: true)) }
    var panel: AnyView { AnyView(PhotoCard(module: self, compact: false)) }
}

struct PhotoCard: View {
    let module: PhotosModule
    let compact: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            if let image = module.image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .id(module.index)
                    .transition(.opacity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 22)).foregroundStyle(Tokens.faint)
                    Text(module.folder == nil ? "Choose a folder of photos" : "No photos in that folder")
                        .font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                    PillButton(title: "Choose folder…", fill: Tokens.surface2) { module.chooseFolder() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Tokens.surface)
            }
            if !compact && module.image != nil {
                HStack(spacing: 6) {
                    IconButton(symbol: "chevron.left") { module.previous() }
                    IconButton(symbol: module.paused ? "play.fill" : "pause.fill") { module.paused.toggle() }
                    IconButton(symbol: "chevron.right") { module.next() }
                    Spacer()
                    Menu {
                        ForEach([5.0, 10, 30, 60], id: \.self) { s in Button("Every \(Int(s)) s") { module.interval = s } }
                        Divider()
                        Button("Choose folder…") { module.chooseFolder() }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 13))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                .padding(8)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Tokens.stroke))
    }
}
