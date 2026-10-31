import AppKit
import SwiftUI
import WebKit

/// Hosts the module's single WKWebView. Whichever host is on screen takes the web view
/// (removing it from its previous superview first), so playback never restarts.
struct YouTubeWebHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        adopt(into: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        adopt(into: container)
    }

    private func adopt(into container: NSView) {
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}

/// The Video tab: player on the left, title and controls on the right.
struct YouTubePanel: View {
    let module: YouTubeModule
    @State private var link = ""
    @State private var linkError: String?

    private let videoWidth: CGFloat = 360
    private var videoHeight: CGFloat { videoWidth * 9 / 16 }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            player
                .frame(width: videoWidth, height: videoHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Tokens.stroke))
            side
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var player: some View {
        if module.current == nil {
            placeholder(symbol: "play.rectangle", text: "Drag a YouTube link onto the notch, or paste one here.")
        } else if module.isDetached {
            ZStack {
                placeholder(symbol: "macwindow.on.rectangle", text: "Playing in its own window.")
                VStack { Spacer(); PillButton(title: "Back to notch") { module.attach() }.padding(.bottom, 14) }
            }
        } else {
            YouTubeWebHost(webView: module.webView)
        }
    }

    private func placeholder(symbol: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(Tokens.faint)
            Text(text)
                .font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.surface)
    }

    private var side: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardLabel("YouTube")
            if module.current != nil {
                Text(module.videoTitle ?? "Loading…")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let error = module.playerError {
                    HStack(spacing: 6) {
                        Text(error).font(.system(size: 11)).foregroundStyle(Tokens.error).lineLimit(2)
                        Button("Open on YouTube") { module.openInBrowser() }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                    }
                }
                HStack(spacing: 4) {
                    IconButton(symbol: module.isPlaying ? "pause.fill" : "play.fill", size: 14) { module.togglePlayPause() }
                        .help(module.isPlaying ? "Pause" : "Play")
                    IconButton(symbol: module.isDetached ? "arrow.down.right.and.arrow.up.left" : "macwindow.on.rectangle") {
                        module.isDetached ? module.attach() : module.detach()
                    }
                    .help(module.isDetached ? "Back to notch" : "Detach")
                    IconButton(symbol: "safari") { module.openInBrowser() }
                        .help("Open on YouTube")
                    IconButton(symbol: "xmark") { module.closeVideo() }
                        .help("Close video")
                }
                .foregroundStyle(.white)
            } else {
                Text("Keep a tutorial or talk beside your work.")
                    .font(.system(size: 12)).foregroundStyle(Tokens.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                TextField("Paste a YouTube link", text: $link)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.surface2))
                    .onSubmit(submit)
                PillButton(title: "Play", action: submit)
            }
            if let linkError {
                Text(linkError).font(.system(size: 11)).foregroundStyle(Tokens.error)
            } else if module.current == nil {
                Button("Play link from clipboard") {
                    if !module.pasteFromClipboard() { linkError = "No YouTube link on the clipboard." }
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Tokens.secondary)
            }
        }
    }

    private func submit() {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if module.play(text) {
            link = ""
            linkError = nil
        } else {
            linkError = "That doesn't look like a YouTube link."
        }
    }
}

/// The floating, resizable, always-on-top player window. Keeps a 16:9 video area.
@MainActor
final class YouTubeDetachedWindow: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private weak var module: YouTubeModule?
    private var closingQuietly = false

    init(module: YouTubeModule) {
        self.module = module
        let size = NSSize(width: 480, height: 270)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = module.videoTitle ?? "YouTube"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = .black
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentAspectRatio = NSSize(width: 16, height: 9)
        panel.contentMinSize = NSSize(width: 288, height: 162)
        panel.delegate = self

        let host = NSHostingView(rootView: YouTubeWebHost(webView: module.webView).ignoresSafeArea())
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        let back = NSHostingView(rootView: BackToNotchButton { [weak self] in self?.module?.attach() })
        back.frame = NSRect(x: 0, y: 0, width: 120, height: 22)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = back
        accessory.layoutAttribute = .trailing
        panel.addTitlebarAccessoryViewController(accessory)
    }

    func show() {
        if !panel.setFrameUsingName("ViktorYouTubePlayer"), let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.maxX - panel.frame.width - 24, y: v.maxY - panel.frame.height - 24))
        }
        panel.setFrameAutosaveName("ViktorYouTubePlayer")
        panel.orderFrontRegardless()
    }

    func updateTitle() { panel.title = module?.videoTitle ?? "YouTube" }

    /// Closes the window without telling the module (it already knows).
    func closeQuietly() {
        closingQuietly = true
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        // The red close button sends the player back to the notch (it keeps playing).
        if !closingQuietly { module?.attach(reopenNotch: false) }
    }
}

private struct BackToNotchButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("Back to notch", systemImage: "arrow.up.to.line")
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.borderless)
        .padding(.trailing, 8)
    }
}
