import AppKit
import CryptoKit
import Foundation
import SwiftUI

// MARK: - Logic

extension SecurityKit {
    /// RFC 4648 Base32 (the alphabet authenticator secrets use).
    enum Base32 {
        static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

        /// Uppercase, without spaces, dashes or padding. Nil if anything else is left.
        static func normalize(_ text: String) -> String? {
            let cleaned = text.uppercased().filter { !" -\t\n=".contains($0) }
            guard !cleaned.isEmpty, cleaned.allSatisfy(alphabet.contains) else { return nil }
            return cleaned
        }

        static func decode(_ text: String) -> Data? {
            guard let cleaned = normalize(text) else { return nil }
            var lookup: [Character: UInt32] = [:]
            for (i, c) in alphabet.enumerated() { lookup[c] = UInt32(i) }
            var bytes: [UInt8] = []
            var buffer: UInt32 = 0
            var bits = 0
            for c in cleaned {
                buffer = (buffer << 5) | lookup[c]!
                bits += 5
                if bits >= 8 {
                    bits -= 8
                    bytes.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
                }
                buffer &= (1 << UInt32(bits)) - 1
            }
            return bytes.isEmpty ? nil : Data(bytes)
        }

        static func encode(_ data: Data) -> String {
            var out = ""
            var buffer: UInt32 = 0
            var bits = 0
            for byte in data {
                buffer = (buffer << 8) | UInt32(byte)
                bits += 8
                while bits >= 5 {
                    bits -= 5
                    out.append(alphabet[Int((buffer >> UInt32(bits)) & 31)])
                }
                buffer &= (1 << UInt32(bits)) - 1
            }
            if bits > 0 { out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)]) }
            return out
        }
    }

    enum OTPAlgorithm: String, Codable, CaseIterable { case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512" }

    /// Time-based one-time codes (RFC 6238).
    enum TOTP {
        static func code(secret: Data, time: Date, digits: Int = 6, period: Int = 30, algorithm: OTPAlgorithm = .sha1) -> String {
            let counter = UInt64(max(0, time.timeIntervalSince1970) / Double(max(period, 1)))
            return hotp(secret: secret, counter: counter, digits: digits, algorithm: algorithm)
        }

        /// RFC 4226: HMAC of the counter, dynamic truncation, last `digits` digits.
        static func hotp(secret: Data, counter: UInt64, digits: Int, algorithm: OTPAlgorithm) -> String {
            let message = withUnsafeBytes(of: counter.bigEndian) { Data($0) }
            let key = SymmetricKey(data: secret)
            let mac: [UInt8] = switch algorithm {
            case .sha1: Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
            case .sha256: Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
            case .sha512: Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
            }
            let offset = Int(mac[mac.count - 1] & 0x0F)
            let value = (UInt32(mac[offset] & 0x7F) << 24) | (UInt32(mac[offset + 1]) << 16)
                | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
            var mod: UInt32 = 1
            for _ in 0..<digits { mod *= 10 }
            let s = String(value % mod)
            return String(repeating: "0", count: max(0, digits - s.count)) + s
        }

        /// Seconds until the code changes.
        static func remaining(at time: Date, period: Int) -> Int {
            let p = max(period, 1)
            return p - Int(time.timeIntervalSince1970) % p
        }

        /// "123 456" / "1234 5678", easier to read.
        static func grouped(_ code: String) -> String {
            guard code.count >= 6 else { return code }
            let mid = code.index(code.startIndex, offsetBy: code.count / 2)
            return code[..<mid] + " " + code[mid...]
        }
    }

    /// What an `otpauth://totp/...` link (or a pasted secret) describes.
    struct OTPDraft: Equatable {
        var label: String
        var issuer: String
        var secret: String          // normalised Base32
        var digits = 6
        var period = 30
        var algorithm = OTPAlgorithm.sha1
    }

    enum OTPAuthError: Error, Equatable, LocalizedError {
        case notTOTP, missingSecret, badSecret, badDigits, badPeriod
        var errorDescription: String? {
            switch self {
            case .notTOTP: "That isn't an otpauth://totp link."
            case .missingSecret: "The link has no secret."
            case .badSecret: "The secret isn't valid Base32 (letters A–Z and digits 2–7)."
            case .badDigits: "Codes must be 6 or 8 digits."
            case .badPeriod: "The code period must be between 10 and 120 seconds."
            }
        }
    }

    enum OTPAuth {
        /// Parses `otpauth://totp/Issuer:account?secret=…&issuer=…&digits=6&period=30&algorithm=SHA1`.
        static func parse(_ text: String) throws(OTPAuthError) -> OTPDraft {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let comps = URLComponents(string: trimmed), comps.scheme?.lowercased() == "otpauth",
                  comps.host?.lowercased() == "totp" else { throw .notTOTP }
            let items = comps.queryItems ?? []
            func q(_ name: String) -> String? { items.first { $0.name.lowercased() == name }?.value }
            guard let raw = q("secret"), !raw.isEmpty else { throw .missingSecret }
            guard let secret = Base32.normalize(raw), Base32.decode(secret) != nil else { throw .badSecret }

            var path = comps.path
            if path.hasPrefix("/") { path.removeFirst() }
            var label = path
            var issuer = q("issuer") ?? ""
            if let colon = path.firstIndex(of: ":") {
                let prefix = path[..<colon].trimmingCharacters(in: .whitespaces)
                label = path[path.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if issuer.isEmpty { issuer = prefix }
            }
            var draft = OTPDraft(label: label, issuer: issuer, secret: secret)
            if let d = q("digits") {
                guard let n = Int(d), n == 6 || n == 8 else { throw .badDigits }
                draft.digits = n
            }
            if let p = q("period") {
                guard let n = Int(p), (10...120).contains(n) else { throw .badPeriod }
                draft.period = n
            }
            if let a = q("algorithm"), let alg = OTPAlgorithm(rawValue: a.uppercased()) { draft.algorithm = alg }
            return draft
        }

        /// A pasted link, or a Base32 secret plus a name typed by hand.
        static func draft(input: String, name: String) throws(OTPAuthError) -> OTPDraft {
            let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.lowercased().hasPrefix("otpauth:") {
                var d = try parse(text)
                let n = name.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { d.issuer = n }
                return d
            }
            guard let secret = Base32.normalize(text), let bytes = Base32.decode(secret), bytes.count >= 10 else {
                throw .badSecret
            }
            let n = name.trimmingCharacters(in: .whitespaces)
            return OTPDraft(label: "", issuer: n.isEmpty ? "Account" : n, secret: secret)
        }
    }
}

// MARK: - Module

/// Two-factor codes. Secrets live only in the Keychain; the list (names, digits…) in Storage.
@MainActor
@Observable
final class AuthenticatorAddOn: AddOnModule {
    let id = "addon.authenticator"
    let title = "Authenticator"
    let symbol = "lock.rotation"
    let addOn = AddOnInfo(category: .security, tier: .pro,
                          summary: "Two-factor codes in the notch. Secrets stay in your Keychain.")

    struct Account: Codable, Identifiable, Equatable {
        var id = UUID()
        var label: String
        var issuer: String
        var digits: Int
        var period: Int
        var algorithm: SecurityKit.OTPAlgorithm

        var title: String { issuer.isEmpty ? (label.isEmpty ? "Account" : label) : issuer }
        var subtitle: String? { issuer.isEmpty || label.isEmpty ? nil : label }
        var keychainAccount: String { "addon.totp.\(id.uuidString)" }
    }

    private static let file = "addon-authenticator"
    private(set) var accounts: [Account]
    /// Decoded secrets, kept in memory only. Filled from the Keychain on first use.
    @ObservationIgnored private var secrets: [UUID: Data] = [:]
    var adding = false
    var addError: String?
    /// The account whose code was just copied (for a short "Copied").
    var copiedID: UUID?

    init() {
        if ModuleRegistry.isPreview {
            accounts = Self.samples.map(\.0)
            for (a, s) in Self.samples { secrets[a.id] = SecurityKit.Base32.decode(s) }
        } else {
            accounts = Storage.load([Account].self, from: Self.file) ?? []
        }
    }

    func code(for account: Account, at time: Date) -> String? {
        guard let secret = secret(for: account) else { return nil }
        return SecurityKit.TOTP.code(secret: secret, time: time, digits: account.digits,
                                     period: account.period, algorithm: account.algorithm)
    }

    private func secret(for account: Account) -> Data? {
        if let s = secrets[account.id] { return s }
        guard let stored = Secrets.get(account.keychainAccount), let data = SecurityKit.Base32.decode(stored) else { return nil }
        secrets[account.id] = data
        return data
    }

    @discardableResult
    func add(input: String, name: String) -> Bool {
        do {
            let d = try SecurityKit.OTPAuth.draft(input: input, name: name)
            let account = Account(label: d.label, issuer: d.issuer, digits: d.digits, period: d.period, algorithm: d.algorithm)
            guard Secrets.set(d.secret, for: account.keychainAccount) else {
                addError = "Couldn't save the secret in the Keychain."
                return false
            }
            secrets[account.id] = SecurityKit.Base32.decode(d.secret)
            accounts.append(account)
            save()
            addError = nil
            adding = false
            return true
        } catch {
            addError = error.localizedDescription
            return false
        }
    }

    func delete(_ account: Account) {
        Secrets.set(nil, for: account.keychainAccount)
        secrets[account.id] = nil
        accounts.removeAll { $0.id == account.id }
        save()
    }

    func copy(_ account: Account) {
        guard let code = code(for: account, at: .now) else { return }
        SecurityKit.copy(code, concealed: true)
        copiedID = account.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if self?.copiedID == account.id { self?.copiedID = nil }
        }
    }

    private func save() {
        guard !ModuleRegistry.isPreview else { return }
        Storage.save(accounts, to: Self.file)
    }

    func stop() { secrets.removeAll() }

    var panel: AnyView { AnyView(SecAuthenticatorPanel(module: self)) }

    /// Layout snapshots only: made-up accounts (the GitHub one is the RFC test secret).
    private static let samples: [(Account, String)] = [
        (Account(label: "sam@example.com", issuer: "GitHub", digits: 6, period: 30, algorithm: .sha1), "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"),
        (Account(label: "sam", issuer: "Figma", digits: 6, period: 30, algorithm: .sha1), "JBSWY3DPEHPK3PXP"),
        (Account(label: "", issuer: "AWS root", digits: 8, period: 30, algorithm: .sha256), "KRSXG5CTMVRXEZLUKN2XAZLSKNSWG4TFOQ"),
    ]
}

// MARK: - Views

struct SecAuthenticatorPanel: View {
    @Bindable var module: AuthenticatorAddOn
    @State private var input = ""
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AddOnHeader(symbol: "lock.rotation", title: "Authenticator",
                            subtitle: module.accounts.isEmpty ? "Two-factor codes, secrets kept in your Keychain"
                                : "\(module.accounts.count) account\(module.accounts.count == 1 ? "" : "s") · click a code to copy it",
                            tint: SecurityAddOns.tint)
                if let first = module.accounts.first {
                    // Orbit keeps an eye on the clock: its eyes follow the countdown ring round.
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let left = SecurityKit.TOTP.remaining(at: ctx.date, period: first.period)
                        SecKeyOrbit(size: 46, progress: Double(left) / Double(max(first.period, 1)), urgent: left <= 5)
                    }
                    .frame(width: 46, height: 46)
                    .help("New codes in a moment")
                }
                if !module.adding {
                    GlassPillButton(title: "Add account", symbol: "plus") { module.adding = true; module.addError = nil }
                }
            }
            if module.adding { addForm }
            if module.accounts.isEmpty && !module.adding {
                empty
            } else if !module.accounts.isEmpty {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    NotchScroll {
                        VStack(spacing: 8) {
                            ForEach(module.accounts) { account in
                                SecTOTPRow(module: module, account: account, now: ctx.date)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            SecKeyOrbit(size: 64, progress: nil)
            Text("No accounts yet").font(.system(size: 14, weight: .semibold))
            Text("When a site shows a QR code for two-factor sign-in, choose “Can't scan?” and paste the link or secret here.")
                .font(.system(size: 12)).foregroundStyle(Tokens.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            PillButton(title: "Add account") { module.adding = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(22)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardLabel("New account")
            field("otpauth://totp/… link or Base32 secret", text: $input)
            field("Name, e.g. GitHub (optional for links)", text: $name)
            HStack(spacing: 8) {
                if let err = module.addError {
                    Label(err, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5))
                        .foregroundStyle(Tokens.attention).lineLimit(2)
                } else {
                    Text("The secret goes straight into your Keychain and is never shown again.")
                        .font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
                }
                Spacer(minLength: 8)
                GlassPillButton(title: "Cancel") { module.adding = false; module.addError = nil; input = ""; name = "" }
                PillButton(title: "Add") {
                    if module.add(input: input, name: name) { input = ""; name = "" }
                }
            }
        }
        .padding(14)
        .glassCard(22)
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, design: .monospaced))
            .padding(.horizontal, 12).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Tokens.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Tokens.stroke))
    }
}

struct SecTOTPRow: View {
    let module: AuthenticatorAddOn
    let account: AuthenticatorAddOn.Account
    let now: Date
    @State private var hovering = false
    @State private var confirming = false

    var body: some View {
        let remaining = SecurityKit.TOTP.remaining(at: now, period: account.period)
        let urgent = remaining <= 5
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let sub = account.subtitle {
                    Text(sub).font(.system(size: 11.5)).foregroundStyle(Tokens.secondary).lineLimit(1)
                }
            }
            .frame(width: 190, alignment: .leading)
            Spacer(minLength: 8)
            if confirming {
                Text("Delete this account?").font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                GlassPillButton(title: "Cancel") { confirming = false }
                PillButton(title: "Delete", fill: Tokens.error) { module.delete(account) }
            } else {
                if module.copiedID == account.id {
                    Label("Copied", systemImage: "checkmark").font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Tokens.live)
                }
                Text(module.code(for: account, at: now).map(SecurityKit.TOTP.grouped) ?? "Locked")
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundStyle(urgent ? Tokens.attention : .white)
                ring(remaining: remaining, urgent: urgent)
                Button { confirming = true } label: {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Tokens.faint)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .help("Delete")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glassCard(18)
        .contentShape(Rectangle())
        .onTapGesture { if !confirming { module.copy(account) } }
        .onHover { hovering = $0 }
        .help("Click to copy")
    }

    private func ring(remaining: Int, urgent: Bool) -> some View {
        ZStack {
            Circle().stroke(Tokens.surface2, lineWidth: 3)
            Circle().trim(from: 0, to: CGFloat(remaining) / CGFloat(max(account.period, 1)))
                .stroke(urgent ? Tokens.attention : SecurityAddOns.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(remaining)").font(.system(size: 9.5, weight: .semibold).monospacedDigit()).foregroundStyle(Tokens.secondary)
        }
        .frame(width: 26, height: 26)
    }
}
