import Foundation
import Testing
@testable import Viktor

/// A predictable random source, so generated passwords can be checked.
private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Security add-ons: passwords")
struct PasswordGenTests {
    typealias Gen = SecurityKit.PasswordGen
    typealias Options = SecurityKit.PasswordOptions

    @Test func lengthAndCharacterGroups() {
        var rng = SeededRandom(state: 1)
        for length in [8, 20, 64] {
            let o = Options(length: length)
            for _ in 0..<50 {
                let p = Gen.generate(o, using: &rng)
                #expect(p.count == length)
                #expect(p.contains(where: Gen.lowercase.contains))
                #expect(p.contains(where: Gen.uppercase.contains))
                #expect(p.contains(where: Gen.digits.contains))
                #expect(p.contains(where: Gen.symbols.contains))
            }
        }
    }

    @Test func onlyLowercaseWhenEverythingIsOff() {
        var rng = SeededRandom(state: 7)
        let p = Gen.generate(Options(length: 30, numbers: false, symbols: false, uppercase: false), using: &rng)
        #expect(p.allSatisfy(Gen.lowercase.contains))
    }

    @Test func passphraseUsesListAndSeparator() {
        var rng = SeededRandom(state: 3)
        let o = Options(mode: .passphrase, words: 6, separator: ".")
        let words = Gen.generate(o, using: &rng).split(separator: ".").map(String.init)
        #expect(words.count == 6)
        #expect(words.allSatisfy(SecurityKit.wordList.contains))
    }

    @Test func wordListIsUniqueAndSimple() {
        let list = SecurityKit.wordList
        #expect(list.count >= 300)
        #expect(Set(list).count == list.count)
        #expect(list.allSatisfy { $0.allSatisfy { $0.isLowercase && $0.isLetter } })
    }

    @Test func entropyAndLabels() {
        // 26 + 26 + 10 + 24 = 86 symbols.
        #expect(abs(Gen.entropy(Options(length: 20)) - 20 * log2(86.0)) < 0.001)
        #expect(abs(Gen.entropy(Options(length: 10, numbers: false, symbols: false, uppercase: false)) - 47.004) < 0.01)
        #expect(abs(Gen.entropy(Options(mode: .passphrase, words: 5), wordCount: 1024) - 50) < 0.001)
        #expect(SecurityKit.Strength(bits: 30) == .weak)
        #expect(SecurityKit.Strength(bits: 50) == .ok)
        #expect(SecurityKit.Strength(bits: 80) == .strong)
        #expect(SecurityKit.Strength(bits: 128) == .veryStrong)
    }

    @Test func secureRandomStaysInRange() {
        var rng = SecurityKit.SecureRandom()
        for _ in 0..<1000 { #expect((0..<7).contains(Int.random(in: 0..<7, using: &rng))) }
    }
}

@Suite("Security add-ons: authenticator")
struct TOTPTests {
    typealias TOTP = SecurityKit.TOTP

    /// RFC 6238 appendix B: time, then the expected 8-digit codes for SHA1, SHA256, SHA512.
    static let vectors: [(Double, String, String, String)] = [
        (59, "94287082", "46119246", "90693936"),
        (1_111_111_109, "07081804", "68084774", "25091201"),
        (1_111_111_111, "14050471", "67062674", "99943326"),
        (1_234_567_890, "89005924", "91819424", "93441116"),
        (2_000_000_000, "69279037", "90698825", "38618901"),
        (20_000_000_000, "65353130", "77737706", "47863826"),
    ]
    static let sha1Key = Data("12345678901234567890".utf8)
    static let sha256Key = Data("12345678901234567890123456789012".utf8)
    static let sha512Key = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

    @Test func rfc6238Vectors() {
        for (t, sha1, sha256, sha512) in Self.vectors {
            let time = Date(timeIntervalSince1970: t)
            #expect(TOTP.code(secret: Self.sha1Key, time: time, digits: 8, algorithm: .sha1) == sha1)
            #expect(TOTP.code(secret: Self.sha256Key, time: time, digits: 8, algorithm: .sha256) == sha256)
            #expect(TOTP.code(secret: Self.sha512Key, time: time, digits: 8, algorithm: .sha512) == sha512)
        }
    }

    @Test func sixDigitsAndCountdown() {
        // The 6-digit code is the last six digits of the 8-digit one.
        #expect(TOTP.code(secret: Self.sha1Key, time: Date(timeIntervalSince1970: 59)) == "287082")
        #expect(TOTP.remaining(at: Date(timeIntervalSince1970: 59), period: 30) == 1)
        #expect(TOTP.remaining(at: Date(timeIntervalSince1970: 60), period: 30) == 30)
        #expect(TOTP.grouped("287082") == "287 082")
        #expect(TOTP.grouped("94287082") == "9428 7082")
    }

    @Test func base32() {
        // RFC 4648 test vectors.
        let pairs = [("f", "MY"), ("fo", "MZXQ"), ("foo", "MZXW6"), ("foob", "MZXW6YQ"), ("fooba", "MZXW6YTB"), ("foobar", "MZXW6YTBOI")]
        for (plain, encoded) in pairs {
            #expect(SecurityKit.Base32.encode(Data(plain.utf8)) == encoded)
            #expect(SecurityKit.Base32.decode(encoded) == Data(plain.utf8))
        }
        #expect(SecurityKit.Base32.decode("mzxw 6ytb-oi======") == Data("foobar".utf8))
        #expect(SecurityKit.Base32.decode("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ") == Self.sha1Key)
        #expect(SecurityKit.Base32.decode("not base32!") == nil)
        #expect(SecurityKit.Base32.decode("ABC1") == nil)
    }

    @Test func parsesOtpauthLinks() throws {
        let d = try SecurityKit.OTPAuth.parse(
            "otpauth://totp/ACME%20Co:john.doe@email.com?secret=HXDMVJECJJWSRB3HWIZR4IFUGFTMXBOZ&issuer=ACME%20Co&algorithm=SHA256&digits=8&period=60")
        #expect(d.issuer == "ACME Co")
        #expect(d.label == "john.doe@email.com")
        #expect(d.secret == "HXDMVJECJJWSRB3HWIZR4IFUGFTMXBOZ")
        #expect(d.digits == 8)
        #expect(d.period == 60)
        #expect(d.algorithm == .sha256)

        let simple = try SecurityKit.OTPAuth.parse("otpauth://totp/GitHub:viktor?secret=jbsw y3dp ehpk 3pxp")
        #expect(simple.issuer == "GitHub")
        #expect(simple.label == "viktor")
        #expect(simple.secret == "JBSWY3DPEHPK3PXP")
        #expect(simple.digits == 6 && simple.period == 30 && simple.algorithm == .sha1)
    }

    @Test func rejectsBadLinks() {
        #expect(throws: SecurityKit.OTPAuthError.notTOTP) { try SecurityKit.OTPAuth.parse("otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP") }
        #expect(throws: SecurityKit.OTPAuthError.notTOTP) { try SecurityKit.OTPAuth.parse("https://example.com") }
        #expect(throws: SecurityKit.OTPAuthError.missingSecret) { try SecurityKit.OTPAuth.parse("otpauth://totp/x") }
        #expect(throws: SecurityKit.OTPAuthError.badSecret) { try SecurityKit.OTPAuth.parse("otpauth://totp/x?secret=1111") }
        #expect(throws: SecurityKit.OTPAuthError.badDigits) {
            try SecurityKit.OTPAuth.parse("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&digits=7")
        }
    }

    @Test func plainSecretWithName() throws {
        let d = try SecurityKit.OTPAuth.draft(input: " jbsw-y3dp-ehpk-3pxp ", name: "Figma")
        #expect(d.issuer == "Figma")
        #expect(d.secret == "JBSWY3DPEHPK3PXP")
        #expect(throws: SecurityKit.OTPAuthError.badSecret) { try SecurityKit.OTPAuth.draft(input: "ABC", name: "x") }
    }
}

@Suite("Security add-ons: network")
struct NetworkClassifyTests {
    typealias C = SecurityKit.NetClassify
    typealias I = SecurityKit.NetInterface

    @Test func kinds() {
        #expect(C.kind(name: "utun4", scType: nil) == .tunnel)
        #expect(C.kind(name: "ipsec0", scType: nil) == .tunnel)
        #expect(C.kind(name: "ppp0", scType: nil) == .tunnel)
        #expect(C.kind(name: "en0", scType: "IEEE80211") == .wifi)
        #expect(C.kind(name: "en0", scType: "Ethernet") == .ethernet)
        #expect(C.kind(name: "en5", scType: nil) == .ethernet)
        #expect(C.kind(name: "bridge100", scType: nil) == .bridge)
        #expect(C.isHidden("awdl0") && C.isHidden("llw0") && C.isHidden("lo0") && C.isHidden("anpi1"))
        #expect(!C.isHidden("en0"))
    }

    @Test func vpnNeedsIPv4OnATunnel() {
        let systemUtun = I(name: "utun0", kind: .tunnel, ipv4: [], ipv6: [])
        let wifi = I(name: "en0", kind: .wifi, ipv4: ["192.168.1.20"], ipv6: [])
        #expect(!C.vpnOn([systemUtun, wifi]))
        #expect(C.vpnOn([systemUtun, wifi, I(name: "utun5", kind: .tunnel, ipv4: ["10.8.0.2"], ipv6: [])]))
    }

    @Test func tidyDropsEmptyAndHidden() {
        let list = C.tidy([
            I(name: "en0", kind: .wifi, ipv4: ["192.168.1.20"], ipv6: []),
            I(name: "utun0", kind: .tunnel, ipv4: [], ipv6: ["fd00::1"]),
            I(name: "awdl0", kind: .other, ipv4: [], ipv6: ["fd00::2"]),
            I(name: "utun3", kind: .tunnel, ipv4: ["10.0.0.2"], ipv6: []),
        ])
        #expect(list.map(\.name) == ["utun3", "en0"])
        #expect(!C.isUsefulIPv6("fe80::1"))
        #expect(C.isUsefulIPv6("2a02:aa1::1"))
    }

    @Test func publicIPReply() {
        #expect(C.parsePublicIP(Data(#"{"ip":"81.230.1.2"}"#.utf8)) == "81.230.1.2")
        #expect(C.parsePublicIP(Data("<html>".utf8)) == nil)
    }

    @Test func readsInterfacesWithoutCrashing() {
        let list = SecurityKit.readInterfaces()
        #expect(list.allSatisfy { !C.isHidden($0.name) })
    }
}

@Suite("Security add-ons: camera and mic log")
struct DeviceLogTests {
    typealias Log = SecurityKit.DeviceLog

    @Test func opensAndClosesSessions() {
        var log: [SecurityKit.DeviceSession] = []
        log = Log.apply(.init(camera: true, mic: false), to: log, at: 100)
        log = Log.apply(.init(camera: true, mic: true), to: log, at: 102)
        #expect(log.count == 2)
        log = Log.apply(.init(camera: false, mic: true), to: log, at: 160)
        #expect(log[0] == .init(kind: .camera, start: 100, end: 160))
        #expect(log[1].end == nil)
        log = Log.apply(.init(camera: true, mic: false), to: log, at: 200)
        #expect(log.count == 3)
        #expect(log[1].end == 200)
        #expect(log[2] == .init(kind: .camera, start: 200, end: nil))
    }

    @Test func keepsOnlyToday() {
        let cal = Calendar.current
        let now = Date.now
        let today = cal.startOfDay(for: now).timeIntervalSince1970
        let log: [SecurityKit.DeviceSession] = [
            .init(kind: .mic, start: today - 7200, end: today - 3600),     // yesterday
            .init(kind: .camera, start: today - 600, end: today + 60),     // over midnight
            .init(kind: .mic, start: today + 10, end: nil),
        ]
        #expect(Log.today(log, now: now).count == 2)
    }

    @Test func readingDoesNotCrash() {
        _ = SecurityKit.DeviceUse.read()
    }
}

@Suite("Security add-ons: checkup")
struct CheckupParseTests {
    typealias P = SecurityKit.CheckParse

    @Test func fileVaultFirewallSipGatekeeper() {
        #expect(P.fileVault("FileVault is On.\n").state == .good)
        #expect(P.fileVault("FileVault is Off.\n").state == .warn)
        #expect(P.fileVault("garbage").state == .unknown)
        #expect(P.firewall("Firewall is enabled. (State = 1)").state == .good)
        #expect(P.firewall("Firewall is disabled. (State = 0)").state == .warn)
        #expect(P.sip("System Integrity Protection status: enabled.").state == .good)
        #expect(P.sip("System Integrity Protection status: disabled.").state == .warn)
        #expect(P.sip("System Integrity Protection status: unknown (Custom Configuration).").state == .warn)
        #expect(P.gatekeeper("assessments enabled").state == .good)
        #expect(P.gatekeeper("assessments disabled").state == .warn)
    }

    @Test func updates() {
        #expect(P.updates(status: 0, output: "1\n").state == .good)
        #expect(P.updates(status: 0, output: "0\n").state == .warn)
        #expect(P.updates(status: 1, output: "The domain/default pair of (…, AutomaticCheckEnabled) does not exist").state == .good)
        #expect(P.updates(status: 1, output: "").state == .unknown)
    }

    @Test func screenLock() {
        let prefix = "2026-10-28 00:17:33.564 sysadminctl[44064:53218850] "
        #expect(P.screenLock(prefix + "screenLock delay is immediate") == .init(state: .good, value: "Immediately"))
        #expect(P.screenLock(prefix + "screenLock delay is 300 seconds") == .init(state: .warn, value: "After 5 min"))
        #expect(P.screenLock(prefix + "screenLock delay is 5 seconds").state == .good)
        #expect(P.screenLock(prefix + "screenLock is off").state == .warn)
        #expect(P.screenLock("something else").state == .unknown)
    }

    @Test func runsCommandsWithArguments() async {
        let out = await SecurityKit.run("/bin/echo", ["hello", "world; rm -rf /"])
        #expect(out?.status == 0)
        #expect(out?.output == "hello world; rm -rf /\n")
        let slow = await SecurityKit.run("/bin/sleep", ["5"], timeout: 0.3)
        #expect(slow == nil)
        #expect(await SecurityKit.run("/no/such/tool", []) == nil)
    }

    @Test func everyCheckHasAFix() {
        for check in SecurityKit.CheckID.allCases {
            #expect(!check.fix.isEmpty)
            if let url = check.settingsURL { #expect(url.hasPrefix("x-apple.systempreferences:")) }
        }
    }
}

@Suite("Security add-ons: catalog") @MainActor
struct SecurityCatalogTests {
    @Test func fiveAddOnsWithTiers() {
        let ctx = AddOnContext(alerts: AlertCenter(), openPanel: { _ in }, closePanel: {})
        let mods = SecurityAddOns.make(ctx).compactMap { $0 as? any AddOnModule }
        #expect(mods.map(\.id) == ["addon.passwords", "addon.authenticator", "addon.network", "addon.privacy", "addon.checkup"])
        #expect(mods.allSatisfy { $0.addOn.category == .security })
        #expect(mods.filter { $0.addOn.tier == .pro }.map(\.id) == ["addon.authenticator", "addon.checkup"])
    }
}

@Suite("Security add-ons: Orbit and Home cards") @MainActor
struct SecurityOrbitTests {
    @Test func inspectorVerdict() {
        typealias Score = SecurityKit.CheckScore
        #expect(Score.verdict([], running: true) == .checking)
        #expect(Score.verdict([.good, .warn], running: true) == .checking)
        #expect(Score.verdict([.good, .warn, .unknown], running: false) == .warn)
        #expect(Score.verdict([.good, .good], running: false) == .good)
        #expect(Score.verdict([.good, .unknown], running: false) == .unknown)
        #expect(Score.verdict([], running: false) == .unknown)
    }

    @Test func primaryInterfaceSkipsTunnels() {
        typealias I = SecurityKit.NetInterface
        let list = [I(name: "utun4", kind: .tunnel, ipv4: ["10.0.0.2"], ipv6: []),
                    I(name: "en0", kind: .wifi, displayName: "Wi-Fi", ipv4: ["192.168.1.20"], ipv6: []),
                    I(name: "en5", kind: .ethernet, ipv4: ["192.168.1.30"], ipv6: [])]
        #expect(SecurityKit.NetClassify.primary(list)?.name == "en0")
        #expect(SecurityKit.NetClassify.primary([list[0]]) == nil)
        #expect(SecurityKit.NetClassify.primary([]) == nil)
    }

    @Test func cameraAndMicHeadline() {
        typealias R = SecurityKit.DeviceUse.Reading
        #expect(PrivacyAddOn.headline(R(camera: true, mic: true)) == "Camera and mic on")
        #expect(PrivacyAddOn.headline(R(camera: true, mic: false)) == "Camera on")
        #expect(PrivacyAddOn.headline(R(camera: false, mic: true)) == "Mic in use")
        #expect(PrivacyAddOn.headline(R(camera: false, mic: false)) == "Camera and mic off")
    }

    @Test func keyOrbitLooksAtTheEndOfTheRing() {
        let full = SecKeyOrbit.gaze(1), quarter = SecKeyOrbit.gaze(0.25), half = SecKeyOrbit.gaze(0.5)
        #expect(abs(full.dx) < 1e-9 && abs(full.dy + 1) < 1e-9)       // top
        #expect(abs(quarter.dx - 1) < 1e-9 && abs(quarter.dy) < 1e-9) // right
        #expect(abs(half.dx) < 1e-9 && abs(half.dy - 1) < 1e-9)       // bottom
    }

    @Test func noAuthenticatorCodesOnHome() {
        let ctx = AddOnContext(alerts: AlertCenter(), openPanel: { _ in }, closePanel: {})
        let mods = SecurityAddOns.make(ctx)
        // Every security add-on has a Home card except the authenticator: codes don't belong on Home.
        #expect(mods.filter { $0.homeCard != nil }.map(\.id) == ["addon.passwords", "addon.network", "addon.privacy", "addon.checkup"])
    }
}
