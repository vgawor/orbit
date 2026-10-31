import AppKit
import Foundation
import Security
import SwiftUI

// MARK: - Logic

extension SecurityKit {
    /// Random numbers straight from the system's secure source (`SecRandomCopyBytes`).
    /// Used with `Int.random(in:using:)`, which picks without modulo bias.
    struct SecureRandom: RandomNumberGenerator {
        mutating func next() -> UInt64 {
            var value: UInt64 = 0
            let status = withUnsafeMutableBytes(of: &value) { SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }
            if status != errSecSuccess {
                var fallback = SystemRandomNumberGenerator()
                return fallback.next()
            }
            return value
        }
    }

    enum Strength: String, Equatable {
        case weak = "Weak", ok = "OK", strong = "Strong", veryStrong = "Very strong"

        init(bits: Double) {
            switch bits {
            case ..<40: self = .weak
            case ..<64: self = .ok
            case ..<100: self = .strong
            default: self = .veryStrong
            }
        }

        var color: Color {
            switch self {
            case .weak: Tokens.error
            case .ok: Tokens.attention
            case .strong: Tokens.live
            case .veryStrong: Tokens.live
            }
        }

        /// 0…1 for the meter.
        var fill: Double {
            switch self {
            case .weak: 0.25
            case .ok: 0.5
            case .strong: 0.75
            case .veryStrong: 1
            }
        }
    }

    struct PasswordOptions: Equatable {
        enum Mode: String, CaseIterable { case characters = "Characters", passphrase = "Passphrase" }
        var mode: Mode = .characters
        var length = 20
        var numbers = true
        var symbols = true
        var uppercase = true
        var words = 5
        var separator = "-"

        static let lengthRange = 8...64
        static let wordRange = 4...7
        static let separators = ["-", ".", "_", " "]
    }

    enum PasswordGen {
        static let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
        static let uppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        static let digits = Array("0123456789")
        static let symbols = Array("!@#$%^&*()-_=+[]{};:,.?/")

        /// The character groups in use. Lowercase letters are always in.
        static func groups(_ o: PasswordOptions) -> [[Character]] {
            var g = [lowercase]
            if o.uppercase { g.append(uppercase) }
            if o.numbers { g.append(digits) }
            if o.symbols { g.append(symbols) }
            return g
        }

        /// Bits of entropy: length × log2(pool) for characters, words × log2(list) for passphrases.
        static func entropy(_ o: PasswordOptions, wordCount: Int = SecurityKit.wordList.count) -> Double {
            switch o.mode {
            case .characters:
                let pool = groups(o).reduce(0) { $0 + $1.count }
                return Double(o.length) * log2(Double(pool))
            case .passphrase:
                return Double(o.words) * log2(Double(wordCount))
            }
        }

        /// A new password. Every chosen group shows up at least once (redraws otherwise, so all
        /// passwords that qualify stay equally likely).
        static func generate<R: RandomNumberGenerator>(_ o: PasswordOptions, using rng: inout R) -> String {
            switch o.mode {
            case .passphrase:
                let list = SecurityKit.wordList
                return (0..<o.words).map { _ in list[Int.random(in: 0..<list.count, using: &rng)] }
                    .joined(separator: o.separator)
            case .characters:
                let groups = groups(o)
                let pool = groups.flatMap { $0 }
                let length = min(max(o.length, PasswordOptions.lengthRange.lowerBound), PasswordOptions.lengthRange.upperBound)
                for _ in 0..<1000 {
                    let chars = (0..<length).map { _ in pool[Int.random(in: 0..<pool.count, using: &rng)] }
                    if groups.allSatisfy({ g in chars.contains(where: g.contains) }) { return String(chars) }
                }
                return String((0..<length).map { _ in pool[Int.random(in: 0..<pool.count, using: &rng)] })
            }
        }

        static func generate(_ o: PasswordOptions) -> String {
            var rng = SecureRandom()
            return generate(o, using: &rng)
        }
    }
}

// MARK: - Module

/// Makes strong passwords and passphrases. Nothing is ever saved.
@MainActor
@Observable
final class PasswordsAddOn: AddOnModule {
    let id = "addon.passwords"
    let title = "Passwords"
    let symbol = "key.fill"
    let addOn = AddOnInfo(category: .security, tier: .free,
                          summary: "Strong passwords and easy passphrases, copied and wiped from the clipboard after a minute.")

    var options = SecurityKit.PasswordOptions() { didSet { if options != oldValue { regenerate() } } }
    private(set) var password = ""
    /// When the copied password will be wiped from the clipboard.
    private(set) var clearsAt: Date?
    private var clearTask: Task<Void, Never>?
    /// Whether the panel shows the password in full. Session only; Orbit wears its mask while it does.
    var revealed = true
    private let ctx: AddOnContext

    init(_ ctx: AddOnContext) {
        self.ctx = ctx
        password = SecurityKit.PasswordGen.generate(options)
    }

    var entropy: Double { SecurityKit.PasswordGen.entropy(options) }
    var strength: SecurityKit.Strength { .init(bits: entropy) }

    func regenerate() { password = SecurityKit.PasswordGen.generate(options) }

    /// Copies, then clears the clipboard after 60 s if it still holds this password.
    func copy() {
        let copied = password
        let count = SecurityKit.copy(copied, concealed: true)
        clearsAt = Date.now.addingTimeInterval(60)
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            let pb = NSPasteboard.general
            if pb.changeCount == count, pb.string(forType: .string) == copied { pb.clearContents() }
            self?.clearsAt = nil
        }
    }

    func stop() {
        // Don't leave a password behind when the add-on is removed.
        clearTask?.cancel()
        if clearsAt != nil, NSPasteboard.general.string(forType: .string) == password { NSPasteboard.general.clearContents() }
        clearsAt = nil
    }

    /// Makes a fresh password and copies it in one go, without ever showing it (used by the Home card).
    func copyNew() {
        regenerate()
        copy()
    }

    /// How Orbit feels about the current settings.
    var orbitMood: OrbitView.Mood {
        switch strength {
        case .weak: .grumpy
        case .ok: .normal
        case .strong, .veryStrong: .happy
        }
    }

    var homeCard: AnyView? { AnyView(SecPasswordsHomeCard(module: self) { [ctx, id] in ctx.openPanel(id) }) }

    var panel: AnyView { AnyView(SecPasswordsPanel(module: self)) }
}

// MARK: - View

struct SecPasswordsPanel: View {
    @Bindable var module: PasswordsAddOn
    private typealias Options = SecurityKit.PasswordOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AddOnHeader(symbol: "key.fill", title: "Passwords",
                        subtitle: "Made on this Mac and never saved", tint: SecurityAddOns.tint)
            passwordCard
            HStack(alignment: .top, spacing: 12) {
                settingsCard
            }
            Spacer(minLength: 0)
        }
    }

    private var passwordCard: some View {
        HStack(alignment: .center, spacing: 16) {
            // Orbit covers its eyes while the password is on screen, and looks again once it's hidden.
            SecBlindfoldOrbit(size: 66, blindfolded: module.revealed, mood: module.orbitMood)
                .help(module.revealed ? "Orbit isn't looking" : "Hidden")
            passwordDetails
        }
        .padding(16)
        .glassCard(22)
    }

    private var passwordDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if module.revealed {
                        Text(module.password)
                            .font(.system(size: module.password.count > 40 ? 15 : 20, weight: .medium, design: .monospaced))
                            .textSelection(.enabled)
                    } else {
                        Text(String(repeating: "•", count: min(module.password.count, 24)))
                            .font(.system(size: 20, weight: .medium, design: .monospaced))
                            .foregroundStyle(Tokens.secondary)
                    }
                }
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                DevIconButton(symbol: module.revealed ? "eye.slash" : "eye",
                              help: module.revealed ? "Hide the password" : "Show the password") {
                    module.revealed.toggle()
                }
            }
            HStack(spacing: 10) {
                meter
                Text(module.strength.rawValue).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(module.strength.color)
                Text("\(Int(module.entropy.rounded())) bits").font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Tokens.secondary)
                Spacer(minLength: 8)
                if module.clearsAt != nil {
                    Label("Copied · clears in 60 s", systemImage: "checkmark")
                        .font(.system(size: 11)).foregroundStyle(Tokens.secondary)
                }
                GlassPillButton(title: "New", symbol: "arrow.clockwise") { module.regenerate() }
                PillButton(title: "Copy") { module.copy() }
            }
        }
    }

    private var meter: some View {
        HStack(spacing: 3) {
            ForEach(0..<4) { i in
                Capsule()
                    .fill(Double(i) < module.strength.fill * 4 ? module.strength.color : Tokens.surface2)
                    .frame(width: 22, height: 5)
            }
        }
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                ForEach(Options.Mode.allCases, id: \.self) { mode in
                    SecChip(title: mode.rawValue, symbol: mode == .characters ? "textformat.abc" : "text.word.spacing",
                            selected: module.options.mode == mode) { module.options.mode = mode }
                }
                Spacer()
            }
            if module.options.mode == .characters {
                row("Length", value: "\(module.options.length)") {
                    SecSlider(value: $module.options.length, range: Options.lengthRange, tint: SecurityAddOns.tint)
                }
                HStack(spacing: 6) {
                    CardLabel("Include").frame(width: 70, alignment: .leading)
                    SecChip(title: "a–z", selected: true) {}.disabled(true)
                    SecChip(title: "A–Z", selected: module.options.uppercase) { module.options.uppercase.toggle() }
                    SecChip(title: "0–9", selected: module.options.numbers) { module.options.numbers.toggle() }
                    SecChip(title: "!#%", selected: module.options.symbols) { module.options.symbols.toggle() }
                    Spacer()
                }
            } else {
                row("Words", value: "\(module.options.words)") {
                    SecSlider(value: $module.options.words, range: Options.wordRange, tint: SecurityAddOns.tint)
                }
                HStack(spacing: 6) {
                    CardLabel("Between").frame(width: 70, alignment: .leading)
                    ForEach(Options.separators, id: \.self) { sep in
                        SecChip(title: sep == " " ? "Space" : sep, selected: module.options.separator == sep) {
                            module.options.separator = sep
                        }
                    }
                    Spacer()
                }
            }
            Text(module.options.mode == .characters
                 ? "Long beats clever: 16 characters or more is strong for almost anything."
                 : "Easy to type and remember. Picked from \(SecurityKit.wordList.count) common words.")
                .font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(22)
    }

    private func row<C: View>(_ label: String, value: String, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 10) {
            CardLabel(label).frame(width: 70, alignment: .leading)
            control()
            Text(value).font(.system(size: 13, weight: .semibold).monospacedDigit()).frame(width: 28, alignment: .trailing)
        }
    }
}

/// Home: a fresh strong password straight to the clipboard, never shown on screen.
struct SecPasswordsHomeCard: View {
    let module: PasswordsAddOn
    let open: () -> Void

    var body: some View {
        let o = module.options
        let size = o.mode == .characters ? "\(o.length) characters" : "\(o.words) words"
        let copied = module.clearsAt != nil
        DevSecHomeCard(label: "Passwords",
                       title: copied ? "Copied · clears in a minute" : "\(module.strength.rawValue) password",
                       detail: "\(size) · never shown here",
                       titleTint: copied ? Tokens.live : .white,
                       open: open) {
            SecBlindfoldOrbit(size: 50, blindfolded: false, mood: copied ? .wink : module.orbitMood)
        } trailing: {
            PillButton(title: "Copy new") { module.copyNew() }
                .help("Makes a new password and copies it. It's wiped from the clipboard after a minute.")
        }
    }
}
