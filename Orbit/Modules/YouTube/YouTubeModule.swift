import AppKit
import SwiftUI
import WebKit

/// Plays a YouTube video in the notch. Drop or paste a link; detach the player into a floating
/// window and bring it back without restarting — it's the same web view the whole time.
@MainActor
@Observable
final class YouTubeModule: NotchModule {
    let id = "youtube"
    let title = "Video"
    let symbol = "play.rectangle"

    /// The page the player is embedded in pretends to live here, so YouTube gets a proper
    /// origin/Referer (without one the embed shows "Error 153 · Video player configuration error").
    static let embedOrigin = "https://www.youtube-nocookie.com"

    private(set) var current: YouTubeLink?
    private(set) var videoTitle: String?
    private(set) var isPlaying = false
    private(set) var isDetached = false
    /// Shown under the player, e.g. when the owner blocks embedding.
    private(set) var playerError: String?

    /// The one web view. Moved between the notch and the floating window; never recreated.
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let openPanel: @MainActor (String) -> Void
    @ObservationIgnored private var detachedWindow: YouTubeDetachedWindow?
    @ObservationIgnored private var titleTask: Task<Void, Never>?

    init(openPanel: @escaping @MainActor (String) -> Void) {
        self.openPanel = openPanel
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.preferences.isElementFullscreenEnabled = true
        config.websiteDataStore = .default()
        let bridge = YouTubeMessageBridge()
        config.userContentController.add(bridge, name: "orbit")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 360, height: 202), configuration: config)
        // Look like Safari so YouTube serves its normal HTML5 player.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        bridge.module = self
    }

    // MARK: Public API

    /// The video id in a YouTube link, or nil if it isn't one.
    static func videoID(from text: String) -> String? { YouTubeLink.parse(text)?.id }

    /// Loads a YouTube link and opens the Video panel. Returns false (and does nothing) if it isn't YouTube.
    @discardableResult
    func play(_ link: String) -> Bool {
        guard let parsed = YouTubeLink.parse(link) else { return false }
        load(parsed)
        if !isDetached { openPanel(id) }
        return true
    }

    /// Plays a YouTube link from the clipboard. Returns false when there isn't one.
    @discardableResult
    func pasteFromClipboard() -> Bool {
        let pb = NSPasteboard.general
        let candidates = [pb.string(forType: .string), pb.string(forType: .URL),
                          (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.absoluteString]
        for case let text? in candidates where play(text) { return true }
        return false
    }

    func togglePlayPause() {
        guard current != nil else { return }
        webView.evaluateJavaScript("togglePlay()", completionHandler: nil)
        isPlaying.toggle() // optimistic; the player's state message corrects it
    }

    /// Stops the video and empties the player.
    func closeVideo() {
        titleTask?.cancel()
        if isDetached { attach(reopenNotch: false) }
        webView.loadHTMLString("<html><body style='background:#000'></body></html>", baseURL: nil)
        current = nil
        videoTitle = nil
        isPlaying = false
        playerError = nil
    }

    /// Moves the player into a floating, resizable window that stays on top.
    func detach() {
        guard current != nil, !isDetached else { return }
        isDetached = true
        let window = YouTubeDetachedWindow(module: self)
        detachedWindow = window
        window.show()
    }

    /// Puts the player back in the notch (same web view, no reload).
    func attach(reopenNotch: Bool = true) {
        guard isDetached else { return }
        isDetached = false
        let window = detachedWindow
        detachedWindow = nil
        window?.closeQuietly()
        if reopenNotch { openPanel(id) }
    }

    func openInBrowser() {
        guard let current else { return }
        NSWorkspace.shared.open(current.watchURL)
    }

    // MARK: Loading

    private func load(_ link: YouTubeLink) {
        current = link
        videoTitle = nil
        playerError = nil
        isPlaying = false
        webView.loadHTMLString(Self.html(for: link), baseURL: URL(string: Self.embedOrigin))
        detachedWindow?.updateTitle()
        fetchTitle(link)
    }

    private func fetchTitle(_ link: YouTubeLink) {
        titleTask?.cancel()
        titleTask = Task { [weak self] in
            var comps = URLComponents(string: "https://www.youtube.com/oembed")!
            comps.queryItems = [.init(name: "url", value: "https://www.youtube.com/watch?v=\(link.id)"),
                                .init(name: "format", value: "json")]
            guard let url = comps.url,
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let info = try? JSONDecoder().decode(OEmbed.self, from: data),
                  !Task.isCancelled else { return }
            self?.setTitle(info.title, for: link)
        }
    }

    private func setTitle(_ title: String, for link: YouTubeLink) {
        guard current == link, !title.isEmpty else { return }
        videoTitle = title
        detachedWindow?.updateTitle()
    }

    private struct OEmbed: Decodable { let title: String }

    // MARK: Messages from the page

    fileprivate func receive(_ body: Any) {
        guard let msg = body as? [String: Any], let event = msg["event"] as? String else { return }
        switch event {
        case "state":
            // -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued
            let state = (msg["state"] as? NSNumber)?.intValue ?? -1
            isPlaying = state == 1 || state == 3
        case "ready":
            if videoTitle == nil, let t = msg["title"] as? String, let current, !t.isEmpty { setTitle(t, for: current) }
        case "error":
            let code = (msg["code"] as? NSNumber)?.intValue ?? 0
            isPlaying = false
            switch code {
            case 101, 150: playerError = "The owner doesn't allow this video outside YouTube."
            case 100: playerError = "This video is private or was removed."
            case 2: playerError = "That link doesn't point to a video."
            default: playerError = "YouTube couldn't play this here (error \(code))."
            }
        default: break
        }
    }

    /// A tiny page with the official IFrame player (youtube-nocookie host). Falls back to a plain
    /// embed iframe if the IFrame API script can't load.
    static func html(for link: YouTubeLink) -> String {
        let id = link.id, start = link.start, origin = embedOrigin
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}
        #player,iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style></head>
        <body><div id="player"></div>
        <script>
        var player = null, fallback = false;
        function post(m){ try { window.webkit.messageHandlers.orbit.postMessage(m); } catch(e) {} }
        function onYouTubeIframeAPIReady(){
          if (fallback) return;
          player = new YT.Player('player', {
            host: 'https://www.youtube-nocookie.com', videoId: '\(id)', width: '100%', height: '100%',
            playerVars: { autoplay: 1, playsinline: 1, start: \(start), rel: 0, modestbranding: 1,
                          enablejsapi: 1, origin: '\(origin)' },
            events: {
              onReady: function(e){ e.target.playVideo(); var d = e.target.getVideoData ? e.target.getVideoData() : null;
                                    post({event:'ready', title: d && d.title ? d.title : ''}); },
              onStateChange: function(e){ post({event:'state', state:e.data}); },
              onError: function(e){ post({event:'error', code:e.data}); }
            }
          });
        }
        function togglePlay(){
          if (player && player.getPlayerState) {
            var s = player.getPlayerState();
            if (s === 1 || s === 3) player.pauseVideo(); else player.playVideo();
          } else {
            var f = document.querySelector('iframe'); if (!f) return;
            window.__paused = !window.__paused;
            f.contentWindow.postMessage(JSON.stringify({event:'command', func: window.__paused ? 'pauseVideo' : 'playVideo', args:[]}), '*');
          }
        }
        setTimeout(function(){
          if (player) return;
          fallback = true;
          var f = document.createElement('iframe');
          f.src = 'https://www.youtube-nocookie.com/embed/\(id)?autoplay=1&playsinline=1&rel=0&enablejsapi=1&start=\(start)&origin=' + encodeURIComponent('\(origin)');
          f.allow = 'autoplay; encrypted-media; picture-in-picture; fullscreen';
          f.referrerPolicy = 'strict-origin-when-cross-origin';
          f.allowFullscreen = true;
          document.getElementById('player').replaceWith(f);
          post({event:'state', state:1});
        }, 5000);
        </script>
        <script src="https://www.youtube.com/iframe_api"></script>
        </body></html>
        """
    }

    // MARK: NotchModule

    var peekChip: PeekChip? {
        guard current != nil else { return nil }
        return PeekChip(symbol: "play.rectangle.fill", text: videoTitle ?? "YouTube",
                        tint: Color(red: 1, green: 0.2, blue: 0.2), priority: 2)
    }

    var panel: AnyView { AnyView(YouTubePanel(module: self)) }

    func stop() { closeVideo() }
}

/// Receives messages from the player page. Holds the module weakly (the content controller keeps this alive).
@MainActor
private final class YouTubeMessageBridge: NSObject, WKScriptMessageHandler {
    weak var module: YouTubeModule?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        module?.receive(message.body)
    }
}
