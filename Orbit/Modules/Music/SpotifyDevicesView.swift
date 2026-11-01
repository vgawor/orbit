import AppKit
import SwiftUI

/// The speaker button next to the volume: shows where Spotify is playing ("Kök" in green when it's
/// another device, since the volume slider then controls that speaker) and opens the device list.
struct SpotifyDeviceButton: View {
    var spotify = SpotifyConnect.shared
    /// Changes with the song, so the playing device is checked again.
    var trackKey: String = ""
    let open: () -> Void

    var body: some View {
        let active = spotify.devices.first(where: \.isActive)
        let elsewhere = active.map { $0.type.lowercased() != "computer" } ?? false
        Button(action: open) {
            HStack(spacing: 5) {
                Image(systemName: active?.symbol ?? "hifispeaker.2.fill").font(.system(size: 11, weight: .semibold))
                if let active, elsewhere {
                    Text(active.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                }
            }
            .foregroundStyle(elsewhere ? Color.green : .white.opacity(0.8))
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().fill(elsewhere ? Color.green.opacity(0.16) : Tokens.surface2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(active.map { elsewhere ? "Playing on \($0.name). The volume controls \($0.name). Click to choose where Spotify plays." : "Playing on this Mac. Click to choose where Spotify plays." }
              ?? "Choose where Spotify plays")
        .task(id: trackKey) { if spotify.connected { await spotify.loadDevices() } }
        .onChange(of: spotify.nearby.speakers) { _, _ in spotify.mergeDevices() }
    }
}

/// Spotify Connect device list, inside the Music card.
struct SpotifyDevicesView: View {
    var spotify = SpotifyConnect.shared
    let close: () -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: close) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24).background(Circle().fill(Tokens.surface2))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Play on").font(.system(size: 15, weight: .semibold))
                    Text("Spotify Connect").font(.system(size: 11)).foregroundStyle(Tokens.secondary)
                }
                Spacer()
                if spotify.connected {
                    Button { Task { await spotify.loadDevices() } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                            .frame(width: 26, height: 26).background(Circle().fill(Tokens.surface2))
                            .rotationEffect(.degrees(spotify.loading ? 360 : 0))
                            .animation(spotify.loading ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: spotify.loading)
                    }
                    .buttonStyle(.plain).help("Refresh devices")
                }
            }
            if !spotify.connected {
                notConnected
            } else {
                if let problem = spotify.problem {
                    HStack(spacing: 8) {
                        OrbitView(size: 22, mood: .wide, motion: .still)
                        Text(problem).font(.system(size: 12)).foregroundStyle(Tokens.attention)
                    }
                }
                NotchScroll {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(spotify.devices.filter { !$0.onNetwork }) { device in row(device) }
                        let nearby = spotify.devices.filter(\.onNetwork)
                        if !nearby.isEmpty || spotify.nearby.searching {
                            HStack(spacing: 6) {
                                Text("ON YOUR NETWORK").font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                                    .foregroundStyle(Tokens.secondary)
                                if spotify.nearby.searching { ProgressView().controlSize(.mini) }
                            }
                            .padding(.top, 6).padding(.leading, 4)
                            ForEach(nearby) { device in row(device) }
                        }
                        missingRow.padding(.top, 4)
                    }
                    .padding(.bottom, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await spotify.loadDevices() }
        .onChange(of: spotify.nearby.speakers) { _, _ in spotify.mergeDevices() }
        .onDisappear { spotify.nearby.stop() }
    }

    /// Like Spotify's "Don't see your device?": what to do when a speaker is missing.
    private var missingRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.circle").font(.system(size: 14)).foregroundStyle(Tokens.secondary)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Don't see your device?").font(.system(size: 12.5, weight: .semibold))
                Text("Make sure it's on the same Wi-Fi. A speaker you've never used with Spotify needs to be picked once in the Spotify app.")
                    .font(.system(size: 11)).foregroundStyle(Tokens.secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            GlassPillButton(title: "Open Spotify", symbol: "arrow.up.forward") {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
                    NSWorkspace.shared.openApplication(at: url, configuration: .init())
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private func row(_ d: SpotifyConnect.Device) -> some View {
        Button { Task { await spotify.transfer(to: d) } } label: {
            HStack(spacing: 10) {
                Image(systemName: d.symbol).font(.system(size: 14))
                    .foregroundStyle(d.isActive ? Color.green : .white.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(d.isActive ? Color.green.opacity(0.18) : Tokens.surface2))
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.name).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(d.isActive ? Color.green : .white).lineLimit(1)
                    Text(subtitle(d))
                        .font(.system(size: 11)).foregroundStyle(Tokens.secondary)
                }
                Spacer()
                if spotify.switchingTo == d.id {
                    ProgressView().controlSize(.small)
                } else if d.isActive {
                    Image(systemName: "waveform").foregroundStyle(.green).symbolEffect(.variableColor.iterative)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(d.isActive ? 0.09 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(d.isActive || d.isRestricted || spotify.switchingTo != nil)
        .opacity(d.isRestricted ? 0.5 : 1)
    }

    private func subtitle(_ d: SpotifyConnect.Device) -> String {
        if d.isActive { return "Playing here" }
        if d.onNetwork { return d.linked ? "\(d.type) · on your Wi-Fi" : "\(d.type) · pick it once in Spotify" }
        return d.type
    }

    private var notConnected: some View {
        HStack(spacing: 14) {
            OrbitView(size: 54, mood: .wide, motion: .listening)
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect Spotify to choose where it plays").font(.system(size: 14, weight: .semibold))
                Text(spotify.hasClientID
                     ? "Sign in once and pick your phone, speakers or TV from here. Needs Spotify Premium."
                     : "Add your Spotify app's Client ID in Settings → Accounts, then sign in.")
                    .font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if spotify.hasClientID {
                        GlassPillButton(title: "Connect Spotify", symbol: "link") { spotify.connect() }
                    } else {
                        GlassPillButton(title: "Open Settings", symbol: "gearshape") {
                            SettingsView.show(.accounts)
                            SettingsWindow.willOpen()
                            openSettings()
                        }
                    }
                }
                if let problem = spotify.problem {
                    Text(problem).font(.system(size: 11)).foregroundStyle(Tokens.attention)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}
