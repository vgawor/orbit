import AppKit
import SwiftUI

/// Small everyday converters: JSON, Base64, URL, JWT, UUID and timestamps.
@MainActor
@Observable
final class DevToolboxAddOn: AddOnModule {
    let id = "addon.devtools"
    let title = "Toolbox"
    let symbol = "wrench.and.screwdriver"
    let addOn = AddOnInfo(category: .developers, tier: .free,
                          summary: "Format JSON, decode Base64 and JWTs, make UUIDs and convert timestamps.")

    enum Tool: String, CaseIterable, Identifiable, Codable {
        case json, base64, url, jwt, uuid, time
        var id: String { rawValue }
        var title: String {
            switch self {
            case .json: "JSON"
            case .base64: "Base64"
            case .url: "URL"
            case .jwt: "JWT"
            case .uuid: "UUID"
            case .time: "Timestamp"
            }
        }
        /// The two ways the tool can go, when it has them.
        var modes: (String, String)? {
            switch self {
            case .json: ("Pretty", "Minify")
            case .base64, .url: ("Encode", "Decode")
            default: nil
            }
        }
        var placeholder: String {
            switch self {
            case .json: "{\"paste\": \"some JSON\"}"
            case .base64: "Text or Base64"
            case .url: "Text or a %-encoded string"
            case .jwt: "eyJhbGciOi…"
            case .uuid: ""
            case .time: "1730112000, 1730112000000 or 2026-10-28T10:00:00Z (empty = now)"
            }
        }
    }

    var tool: Tool = .json {
        didSet { UserDefaults.standard.set(tool.rawValue, forKey: "addon.devtools.tool") }
    }
    var secondMode = false
    var input = ""
    private(set) var uuids: [String] = []
    private let ctx: AddOnContext

    init(_ ctx: AddOnContext) {
        self.ctx = ctx
        if let raw = UserDefaults.standard.string(forKey: "addon.devtools.tool"), let t = Tool(rawValue: raw) { tool = t }
        generateUUIDs()
        if ModuleRegistry.isPreview {
            tool = .json
            input = #"{"name":"Orbit","version":"1.4.0","addOns":["ports","docker"],"pro":true,"limits":{"repos":10}}"#
        }
    }

    func generateUUIDs() { uuids = (0..<6).map { _ in DevTools.uuid() } }

    func useClipboard() {
        if let text = NSPasteboard.general.string(forType: .string) { input = text }
    }

    struct Output {
        var text = ""
        var rows: [(String, String)] = []
        var status: String?
        var ok = true
    }

    var output: Output {
        let text = input
        switch tool {
        case .json:
            switch DevTools.formatJSON(text, indent: secondMode ? nil : 2) {
            case .success(let s): return Output(text: s, status: "Valid JSON", ok: true)
            case .failure(let issue):
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Output() }
                let line = issue.line.map { "Line \($0): " } ?? ""
                return Output(status: line + issue.message, ok: false)
            }
        case .base64:
            if text.isEmpty { return Output() }
            if !secondMode { return Output(text: DevTools.base64Encode(text)) }
            if let s = DevTools.base64Decode(text) { return Output(text: s) }
            return Output(status: "Not Base64 text", ok: false)
        case .url:
            if text.isEmpty { return Output() }
            if !secondMode { return Output(text: DevTools.urlEncode(text)) }
            if let s = DevTools.urlDecode(text) { return Output(text: s) }
            return Output(status: "Not a valid %-encoded string", ok: false)
        case .jwt:
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Output() }
            guard let jwt = DevTools.decodeJWT(text) else { return Output(status: "Not a JWT", ok: false) }
            var status = "No expiry"
            var ok = true
            if let exp = jwt.expires {
                let when = exp.formatted(date: .abbreviated, time: .shortened)
                ok = !jwt.isExpired()
                status = ok ? "Expires \(when) (\(DevTools.relative(exp, now: .now)))" : "Expired \(when)"
            }
            return Output(text: "// Header\n\(jwt.header)\n\n// Payload\n\(jwt.payload)", status: status, ok: ok)
        case .uuid:
            return Output(rows: uuids.map { ("v4", $0) })
        case .time:
            guard let date = DevTools.parseTime(text) else { return Output(status: "Not a date or Unix time", ok: false) }
            return Output(rows: DevTools.timeRows(date))
        }
    }

    /// nil while there's nothing to judge, else whether the current output is good.
    var outcome: Bool? {
        let out = output
        if out.status == nil, out.text.isEmpty, out.rows.isEmpty { return nil }
        return out.ok
    }

    var homeCard: AnyView? { AnyView(ToolboxHomeCard(module: self) { [ctx, id] in ctx.openPanel(id) }) }

    var panel: AnyView { AnyView(ToolboxPanel(module: self)) }
}

/// Home: the two things you need most often, one click each: a fresh UUID and the Unix time now.
private struct ToolboxHomeCard: View {
    let module: DevToolboxAddOn
    let open: () -> Void
    @State private var copied: String?

    var body: some View {
        DevSecHomeCard(label: "Dev toolbox",
                       title: copied.map { "Copied \($0)" } ?? "Quick copy",
                       detail: copied == nil ? "Fresh UUID or Unix time" : "It's on the clipboard",
                       titleTint: copied == nil ? .white : Tokens.live,
                       open: open) {
            DevToolboxOrbit(size: 46, thinking: false, ok: copied == nil ? nil : true)
        } trailing: {
            HStack(spacing: 6) {
                GlassPillButton(title: "UUID", symbol: "number") { copy(DevTools.uuid(), as: "UUID") }
                GlassPillButton(title: "Now", symbol: "clock") { copy(String(Int(Date.now.timeIntervalSince1970)), as: "Unix time") }
            }
        }
    }

    private func copy(_ value: String, as name: String) {
        DevActions.copy(value)
        copied = name
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if copied == name { copied = nil }
        }
    }
}

// MARK: - Panel

private struct ToolboxPanel: View {
    @Bindable var module: DevToolboxAddOn
    @State private var thinking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                AddOnHeader(symbol: "wrench.and.screwdriver.fill", title: "Dev toolbox", subtitle: subtitle,
                            tint: AddOnCategory.developers.tint)
                // Orbit mulls over each change, then is pleased with a good result or grumpy at a bad one.
                DevToolboxOrbit(size: 36, thinking: thinking, ok: module.outcome)
            }
            .task(id: module.input) {
                guard !module.input.isEmpty else { thinking = false; return }
                thinking = true
                try? await Task.sleep(for: .milliseconds(650))
                if !Task.isCancelled { thinking = false }
            }
            GlassGroup(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(DevToolboxAddOn.Tool.allCases) { t in
                        Button { module.tool = t; module.secondMode = false } label: {
                            Text(t.title).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(module.tool == t ? .white : Tokens.secondary)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .glassSurface(Capsule(), selected: module.tool == t, interactive: true)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if module.tool == .uuid {
                uuidCard
            } else {
                HStack(spacing: 10) {
                    inputCard
                    outputCard
                }
            }
        }
    }

    var subtitle: String {
        switch module.tool {
        case .json: "Pretty-print, minify and check JSON"
        case .base64: "Encode and decode Base64"
        case .url: "Percent-encode and decode text"
        case .jwt: "Read a token's header and claims — the signature isn't checked"
        case .uuid: "Random version 4 UUIDs"
        case .time: "Unix time ⇄ ISO 8601 and your local time"
        }
    }

    var inputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                CardLabel("Input")
                Spacer()
                if let modes = module.tool.modes {
                    modeButton(modes.0, selected: !module.secondMode) { module.secondMode = false }
                    modeButton(modes.1, selected: module.secondMode) { module.secondMode = true }
                }
                if module.tool == .time {
                    modeButton("Now", selected: false) { module.input = String(Int(Date.now.timeIntervalSince1970)) }
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $module.input)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                if module.input.isEmpty {
                    Text(module.tool.placeholder).font(.system(size: 12, design: .monospaced)).foregroundStyle(Tokens.faint)
                        .padding(.leading, 5).allowsHitTesting(false)
                }
            }
            .padding(8)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 6) {
                GlassPillButton(title: "Use clipboard", symbol: "doc.on.clipboard") { module.useClipboard() }
                Spacer()
                if !module.input.isEmpty {
                    GlassPillButton(title: "Clear", symbol: "xmark") { module.input = "" }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(20)
    }

    var outputCard: some View {
        let out = module.output
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardLabel("Output")
                Spacer()
                if !out.text.isEmpty {
                    GlassPillButton(title: "Copy", symbol: "doc.on.doc") { DevActions.copy(out.text) }
                }
            }
            if let status = out.status {
                HStack(spacing: 5) {
                    Image(systemName: out.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    Text(status).lineLimit(2)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(out.ok ? Tokens.live : Tokens.error)
            }
            if !out.rows.isEmpty {
                VStack(spacing: 5) { ForEach(out.rows.indices, id: \.self) { i in copyRow(out.rows[i].0, out.rows[i].1) } }
                Spacer(minLength: 0)
            } else if out.text.isEmpty {
                Text(out.ok ? "The result shows here." : "")
                    .font(.system(size: 12)).foregroundStyle(Tokens.faint)
                Spacer(minLength: 0)
            } else {
                NotchScroll {
                    Text(out.text).font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(20)
    }

    var uuidCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardLabel("Fresh UUIDs")
                Spacer()
                PillButton(title: "Generate") { module.generateUUIDs() }
            }
            ForEach(module.uuids, id: \.self) { copyRow("v4", $0) }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(20)
    }

    func copyRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(Tokens.secondary).frame(width: 96, alignment: .leading)
            Text(value).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 4)
            Button { DevActions.copy(value) } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 10.5)).foregroundStyle(Tokens.secondary)
            }
            .buttonStyle(.plain).help("Copy")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    func modeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? .white : Tokens.secondary)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .glassSurface(Capsule(), selected: selected, interactive: true)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
