import Darwin
import Foundation
import SwiftUI
import SystemConfiguration

// MARK: - Logic

extension SecurityKit {
    enum InterfaceKind: String, Equatable, Sendable {
        case wifi = "Wi-Fi", ethernet = "Ethernet", tunnel = "VPN tunnel", bridge = "Bridge", other = "Other"
        var symbol: String {
            switch self {
            case .wifi: "wifi"
            case .ethernet: "cable.connector"
            case .tunnel: "lock.shield.fill"
            case .bridge: "point.3.connected.trianglepath.dotted"
            case .other: "network"
            }
        }
    }

    struct NetInterface: Identifiable, Equatable, Sendable {
        var id: String { name }
        let name: String
        let kind: InterfaceKind
        /// "Wi-Fi", "Thunderbolt Ethernet"… from System Configuration, when it knows the port.
        var displayName: String?
        var ipv4: [String]
        var ipv6: [String]
    }

    enum NetClassify {
        /// Interfaces that are never shown (loopback, Apple's peer-to-peer and helper links).
        static func isHidden(_ name: String) -> Bool {
            ["lo", "awdl", "llw", "anpi", "ap", "gif", "stf", "XHC", "vmenet"].contains { name.hasPrefix($0) }
        }

        static func isTunnel(_ name: String) -> Bool {
            ["utun", "ipsec", "ppp", "tun", "tap", "wg", "zt"].contains { name.hasPrefix($0) }
        }

        /// What kind of link this is, from its BSD name and (if known) its System Configuration type.
        static func kind(name: String, scType: String?) -> InterfaceKind {
            if isTunnel(name) { return .tunnel }
            if name.hasPrefix("bridge") { return .bridge }
            if let scType {
                if scType == (kSCNetworkInterfaceTypeIEEE80211 as String) { return .wifi }
                if scType == (kSCNetworkInterfaceTypeEthernet as String) { return .ethernet }
            }
            if name.hasPrefix("en") { return name == "en0" ? .wifi : .ethernet }
            return .other
        }

        /// IPv6 addresses worth showing: not link-local (fe80::).
        static func isUsefulIPv6(_ address: String) -> Bool {
            !address.lowercased().hasPrefix("fe80")
        }

        /// A VPN counts as on when a tunnel interface has an IPv4 address. (macOS keeps several
        /// utun interfaces up for iCloud and Continuity, but those only have link-local IPv6.)
        static func vpnOn(_ interfaces: [NetInterface]) -> Bool {
            interfaces.contains { $0.kind == .tunnel && !$0.ipv4.isEmpty }
        }

        /// Sorts and drops interfaces with nothing to show.
        static func tidy(_ list: [NetInterface]) -> [NetInterface] {
            let order: [InterfaceKind] = [.tunnel, .wifi, .ethernet, .bridge, .other]
            return list
                .filter { !isHidden($0.name) && (!$0.ipv4.isEmpty || ($0.kind != .tunnel && !$0.ipv6.isEmpty)) }
                .sorted { (order.firstIndex(of: $0.kind)!, $0.name) < (order.firstIndex(of: $1.kind)!, $1.name) }
        }

        /// Pulls the address out of ipify's `{"ip":"1.2.3.4"}`.
        /// The address to show at a glance: the first non-tunnel interface with IPv4 (Wi-Fi before Ethernet).
        static func primary(_ interfaces: [NetInterface]) -> NetInterface? {
            interfaces.first { $0.kind != .tunnel && !$0.ipv4.isEmpty }
        }

        static func parsePublicIP(_ data: Data) -> String? {
            struct Reply: Decodable { let ip: String }
            guard let ip = try? JSONDecoder().decode(Reply.self, from: data).ip, !ip.isEmpty, ip.count <= 45 else { return nil }
            return ip
        }
    }

    /// Reads every interface that's up, with its addresses (`getifaddrs`).
    static func readInterfaces() -> [NetInterface] {
        var types: [String: (String, String?)] = [:]
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for i in all {
                guard let bsd = SCNetworkInterfaceGetBSDName(i) as String?,
                      let type = SCNetworkInterfaceGetInterfaceType(i) as String? else { continue }
                types[bsd] = (type, SCNetworkInterfaceGetLocalizedDisplayName(i) as String?)
            }
        }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var byName: [String: NetInterface] = [:]
        var order: [String] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let addr = ifa.ifa_addr else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let name = String(cString: ifa.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if let pct = address.firstIndex(of: "%") { address = String(address[..<pct]) }
            if byName[name] == nil {
                let t = types[name]
                byName[name] = NetInterface(name: name, kind: NetClassify.kind(name: name, scType: t?.0),
                                            displayName: t?.1, ipv4: [], ipv6: [])
                order.append(name)
            }
            if family == AF_INET { byName[name]?.ipv4.append(address) }
            else if NetClassify.isUsefulIPv6(address) { byName[name]?.ipv6.append(address) }
        }
        return NetClassify.tidy(order.compactMap { byName[$0] })
    }
}

// MARK: - Module

/// Local addresses, whether a VPN is up, and (only when asked) the public IP.
@MainActor
@Observable
final class NetworkAddOn: AddOnModule {
    let id = "addon.network"
    let title = "Network"
    let symbol = "network.badge.shield.half.filled"
    let addOn = AddOnInfo(category: .security, tier: .free,
                          summary: "Your IP addresses and whether a VPN is on, at a glance.")

    private(set) var interfaces: [SecurityKit.NetInterface] = []
    private(set) var updated: Date?
    private(set) var publicIP: String?
    private(set) var publicIPError: String?
    private(set) var fetchingPublicIP = false
    private var timer: Timer?
    private let ctx: AddOnContext

    var vpnOn: Bool { SecurityKit.NetClassify.vpnOn(interfaces) }

    init(_ ctx: AddOnContext) {
        self.ctx = ctx
        if ModuleRegistry.isPreview { refresh() }
    }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        interfaces = SecurityKit.readInterfaces()
        updated = .now
    }

    /// Asks api.ipify.org for the address the internet sees. Only when the button is pressed.
    func fetchPublicIP() {
        guard !fetchingPublicIP, let url = URL(string: "https://api.ipify.org?format=json") else { return }
        fetchingPublicIP = true
        publicIPError = nil
        Task {
            defer { fetchingPublicIP = false }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                if let ip = SecurityKit.NetClassify.parsePublicIP(data) { publicIP = ip }
                else { publicIPError = "Unexpected reply" }
            } catch {
                publicIPError = "Couldn't reach ipify"
            }
        }
    }

    var peekChip: PeekChip? {
        vpnOn ? PeekChip(symbol: "lock.shield.fill", text: "VPN on", tint: Tokens.live, priority: 1) : nil
    }

    var homeCard: AnyView? { AnyView(SecNetworkHomeCard(module: self) { [ctx, id] in ctx.openPanel(id) }) }

    var panel: AnyView { AnyView(SecNetworkPanel(module: self)) }
}

/// Home: VPN on or off, and this Mac's main local address.
struct SecNetworkHomeCard: View {
    let module: NetworkAddOn
    let open: () -> Void

    var body: some View {
        let main = SecurityKit.NetClassify.primary(module.interfaces)
        DevSecHomeCard(label: "Network",
                       title: module.vpnOn ? "VPN on" : "VPN off",
                       detail: main.map { "\($0.displayName ?? $0.kind.rawValue) · \($0.ipv4.first ?? "")" } ?? "Not connected",
                       titleTint: module.vpnOn ? Tokens.live : .white,
                       open: open) {
            SecShieldOrbit(size: 50, on: module.vpnOn)
        }
    }
}

// MARK: - View

struct SecNetworkPanel: View {
    let module: NetworkAddOn

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AddOnHeader(symbol: "network.badge.shield.half.filled", title: "Network",
                            subtitle: module.updated.map { "Updated \($0.formatted(date: .omitted, time: .shortened)) · refreshes every 30 s" },
                            tint: SecurityAddOns.tint)
                GlassPillButton(title: "Refresh", symbol: "arrow.clockwise") { module.refresh() }
            }
            HStack(spacing: 12) {
                vpnCard
                publicCard
            }
            .frame(height: 112)
            VStack(alignment: .leading, spacing: 8) {
                CardLabel("This Mac's addresses")
                if module.interfaces.isEmpty {
                    Text("Not connected to a network.").font(.system(size: 12.5)).foregroundStyle(Tokens.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    NotchScroll {
                        VStack(spacing: 2) {
                            ForEach(module.interfaces) { SecInterfaceRow(item: $0) }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glassCard(22)
        }
        .onAppear { module.refresh() }
    }

    private var vpnCard: some View {
        let on = module.vpnOn
        let tunnel = module.interfaces.first { $0.kind == .tunnel && !$0.ipv4.isEmpty }
        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                CardLabel("VPN")
                HStack(spacing: 8) {
                    SecStatusDot(color: on ? Tokens.live : Tokens.faint, size: 9)
                    Text(on ? "VPN on" : "VPN off").font(.system(size: 20, weight: .semibold))
                }
                Text(on ? "Traffic can go through \(tunnel?.name ?? "a tunnel") · \(tunnel?.ipv4.first ?? "")"
                        : "No tunnel with an IPv4 address is up.")
                    .font(.system(size: 11.5)).foregroundStyle(Tokens.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }
            // Orbit puts its shield up while a VPN is on.
            SecShieldOrbit(size: 62, on: on)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(22)
    }

    private var publicCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardLabel("Public IP")
            if let ip = module.publicIP {
                Text(ip).font(.system(size: 20, weight: .semibold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.6)
                    .textSelection(.enabled)
            } else {
                Text(module.fetchingPublicIP ? "Checking…" : "Hidden").font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(module.fetchingPublicIP ? Tokens.secondary : .white)
            }
            HStack(spacing: 8) {
                Text(module.publicIPError ?? "Asks api.ipify.org, only when you press.")
                    .font(.system(size: 11.5)).foregroundStyle(module.publicIPError == nil ? Tokens.secondary : Tokens.attention)
                    .lineLimit(2)
                Spacer(minLength: 6)
                GlassPillButton(title: module.publicIP == nil ? "Show" : "Check again", symbol: "globe") { module.fetchPublicIP() }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(22)
    }
}

struct SecInterfaceRow: View {
    let item: SecurityKit.NetInterface

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind.symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(item.kind == .tunnel ? Tokens.live : .white)
                .frame(width: 28, height: 28).glassSurface(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName ?? item.kind.rawValue).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(item.kind == .tunnel ? "\(item.name) · tunnel" : item.name)
                    .font(.system(size: 11)).foregroundStyle(Tokens.secondary)
            }
            .frame(width: 170, alignment: .leading)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                ForEach(item.ipv4, id: \.self) {
                    Text($0).font(.system(size: 13, weight: .medium, design: .monospaced)).textSelection(.enabled)
                }
                if let v6 = item.ipv6.first {
                    Text(v6).font(.system(size: 11, design: .monospaced)).foregroundStyle(Tokens.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
