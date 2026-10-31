import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Files you drop on the notch. Drag them back out, AirDrop them or convert them.
/// The shelf only remembers where files are; it never moves or copies the originals.
@MainActor
@Observable
final class ShelfModule: NotchModule {
    let id = "shelf"
    let title = "Shelf"
    let symbol = "tray"

    struct Item: Codable, Identifiable, Equatable {
        var id = UUID()
        var path: String
        var added = Date.now
        var url: URL { URL(fileURLWithPath: path) }
        var name: String { url.lastPathComponent }
    }

    private(set) var items: [Item]
    private(set) var thumbnails: [UUID: NSImage] = [:]
    private(set) var converting: Set<UUID> = []
    private(set) var message: String?
    private var messageTask: Task<Void, Never>?

    init() {
        items = (Storage.load([Item].self, from: "shelf") ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        items.forEach(makeThumbnail)
    }

    // MARK: Items

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(where: { $0.path == url.path }) {
            let item = Item(path: url.path)
            items.insert(item, at: 0)
            makeThumbnail(item)
        }
        save()
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
        save()
    }

    func clear() {
        items.removeAll()
        thumbnails.removeAll()
        save()
    }

    private func save() { Storage.save(items, to: "shelf") }

    private func makeThumbnail(_ item: Item) {
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 120, height: 80),
                                                   scale: 2, representationTypes: .all)
        Task {
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                thumbnails[item.id] = rep.nsImage
            }
        }
    }

    // MARK: Actions

    /// Opens AirDrop for these files. Runs a moment later, so a drop that just finished
    /// (or the notch closing) doesn't cancel the AirDrop window.
    func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
                add(urls)
                show("AirDrop isn't available. Turn on Wi-Fi and Bluetooth, then try again.")
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            service.perform(withItems: urls)
        }
    }

    // MARK: Convert drop

    /// Files dropped on "Convert", waiting for you to pick a format in the Shelf.
    private(set) var pendingConvert: [URL] = []

    /// Formats every file in the pending drop can be converted to.
    var pendingFormats: [FileConverter.Format] {
        guard let first = pendingConvert.first else { return [] }
        return pendingConvert.dropFirst().reduce(FileConverter.formats(for: first)) { common, url in
            let f = FileConverter.formats(for: url)
            return common.filter(f.contains)
        }
    }

    /// Puts dropped files on the shelf and asks which format to convert them to.
    func askToConvert(_ urls: [URL]) {
        add(urls)
        pendingConvert = urls
        if pendingFormats.isEmpty {
            pendingConvert = []
            show("Orbit can convert images, videos and audio. This file is kept on the shelf.")
        }
    }

    func convertPending(to format: FileConverter.Format) {
        let urls = pendingConvert
        pendingConvert = []
        for url in urls {
            if let item = items.first(where: { $0.path == url.path }) { convert(item, to: format) }
        }
    }

    func cancelPendingConvert() { pendingConvert = [] }

    func reveal(_ item: Item) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
    func open(_ item: Item) { NSWorkspace.shared.open(item.url) }

    func convert(_ item: Item, to format: FileConverter.Format) {
        converting.insert(item.id)
        Task {
            do {
                let out = try await FileConverter.convert(item.url, to: format)
                add([out])
                show("Saved \(out.lastPathComponent)")
            } catch {
                show(error.localizedDescription)
            }
            converting.remove(item.id)
        }
    }

    private func show(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { message = nil }
        }
    }

    /// Reads file URLs from a drop and hands them to `then` (on the main thread, once all are read).
    static func readURLs(_ providers: [NSItemProvider], then: @escaping @MainActor ([URL]) -> Void) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        let collector = URLCollector(expected: fileProviders.count, then: then)
        for p in fileProviders {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                Task { @MainActor in collector.add(url) }
            }
        }
        return true
    }

    static func sizeString(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: Views

    var peekView: AnyView? {
        guard !items.isEmpty else { return nil }
        return AnyView(HStack(spacing: 5) {
            Image(systemName: "tray.full.fill").font(.system(size: 11))
            Text("\(items.count)")
        }.foregroundStyle(Tokens.secondary))
    }

    var panel: AnyView { AnyView(ShelfPanel(module: self)) }
}

// MARK: - Views

struct ShelfPanel: View {
    let module: ShelfModule
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !module.pendingConvert.isEmpty { convertBar }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(module.items) { ShelfTile(item: $0, module: module) }
                    dropTile
                }
            }
            HStack {
                Text(module.message ?? "Drag files out to use them. Right-click for more.")
                    .font(.system(size: 11)).foregroundStyle(module.message == nil ? Tokens.faint : .white)
                    .lineLimit(1)
                Spacer()
                if module.items.count > 1 {
                    Button("AirDrop all") { module.airDrop(module.items.map(\.url)) }
                    Button("Clear") { module.clear() }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Tokens.secondary)
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { ShelfModule.readURLs($0) { module.add($0) } }
    }

    /// Shown after files are dropped on "Convert": pick a format.
    private var convertBar: some View {
        let count = module.pendingConvert.count
        return HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12, weight: .semibold))
            Text(count == 1 ? "Convert \(module.pendingConvert[0].lastPathComponent) to" : "Convert \(count) files to")
                .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            ForEach(module.pendingFormats, id: \.self) { f in
                Chip(title: f.label) { module.convertPending(to: f) }
            }
            Spacer(minLength: 0)
            Button("Not now") { module.cancelPendingConvert() }
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Tokens.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var dropTile: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundStyle(targeted ? .white : Tokens.faint)
            .overlay {
                Text(module.items.isEmpty ? "Drop files on the notch\nto keep them here" : "Drop more")
                    .font(.system(size: 12)).multilineTextAlignment(.center).foregroundStyle(Tokens.faint)
            }
            .frame(width: module.items.isEmpty ? 640 : 140)
    }
}

struct ShelfTile: View {
    let item: ShelfModule.Item
    let module: ShelfModule
    @State private var hovering = false

    var body: some View {
        let formats = FileConverter.formats(for: item.url)
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                if hovering {
                    Button { module.remove(item) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                            .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain).padding(4)
                }
            }
            Text(item.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Text(ShelfModule.sizeString(item.url)).font(.system(size: 11)).foregroundStyle(Tokens.faint)
            Spacer(minLength: 0)
            if module.converting.contains(item.id) {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Converting…") }
                    .font(.system(size: 11)).foregroundStyle(Tokens.secondary)
            } else {
                HStack(spacing: 4) {
                    ForEach(formats.prefix(3), id: \.self) { f in
                        Chip(title: f.label) { module.convert(item, to: f) }
                    }
                    if formats.count > 3 {
                        Menu {
                            ForEach(formats.dropFirst(3), id: \.self) { f in
                                Button("Convert to \(f.label)") { module.convert(item, to: f) }
                            }
                        } label: { Text("…") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                    Spacer(minLength: 0)
                    IconButton(symbol: "paperplane", size: 11) { module.airDrop([item.url]) }
                        .help("AirDrop")
                }
            }
        }
        .padding(10)
        .frame(width: 168)
        .frame(maxHeight: .infinity)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Tokens.stroke))
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { module.open(item) }
        .contextMenu {
            Button("Open") { module.open(item) }
            Button("Show in Finder") { module.reveal(item) }
            Button("AirDrop") { module.airDrop([item.url]) }
            if !formats.isEmpty {
                Menu("Convert to") {
                    ForEach(formats, id: \.self) { f in Button(f.label) { module.convert(item, to: f) } }
                }
            }
            Divider()
            Button("Remove from Shelf") { module.remove(item) }
        }
    }

    private var thumbnail: some View {
        Group {
            if let img = module.thumbnails[item.id] {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().aspectRatio(contentMode: .fit).padding(12)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 74)
        .background(Tokens.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct Chip: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(hovering ? Color.white : Tokens.surface2))
                .foregroundStyle(hovering ? Color.black : Tokens.secondary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Gathers URLs from several drop providers, then calls back once.
@MainActor
private final class URLCollector {
    private var urls: [URL] = []
    private var remaining: Int
    private let then: @MainActor ([URL]) -> Void

    init(expected: Int, then: @escaping @MainActor ([URL]) -> Void) {
        remaining = expected
        self.then = then
    }

    func add(_ url: URL?) {
        if let url { urls.append(url) }
        remaining -= 1
        if remaining == 0, !urls.isEmpty { then(urls) }
    }
}
