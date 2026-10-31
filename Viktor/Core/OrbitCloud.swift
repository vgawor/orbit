import AppKit
import Foundation

/// Your Orbit account (Supabase): sign in with a code sent by email, see your plan and AI use,
/// upgrade to Orbit Pro (Paddle) or manage the subscription. With Pro, bots run on Orbit's keys
/// through Orbit's server, so you don't need your own Anthropic or OpenAI key.
@MainActor
@Observable
final class OrbitCloud {
    static let shared = OrbitCloud()

    // Public values: the project address and its publishable key are meant to ship in apps.
    static let url = URL(string: "https://agxhwmdzbdatvsjuvsma.supabase.co")!
    static let publishableKey = "sb_publishable_g7gLn8wqHiC2bCUuVddAiQ_JNUDwx5i"
    /// The phone web app (approvals on the phone).
    static var phoneAppURL: URL {
        URL(string: Bundle.main.object(forInfoDictionaryKey: "OrbitPhoneURL") as? String ?? "")
            ?? URL(string: "https://vgawor.github.io/orbit-releases/app/")!
    }

    static let keychainAccount = "orbit-cloud"
    private static let emailKey = "orbitCloud.email"
    private static let useProKey = "orbitCloud.usePro"

    struct Status: Equatable, Decodable {
        var pro: Bool
        var plan: String
        var status: String?
        var renews: String?
        var spent_cents: Int
        var limit_cents: Int
    }

    private(set) var email: String? = UserDefaults.standard.string(forKey: emailKey)
    private(set) var status: Status?
    private(set) var busy = false
    /// The last problem, in words.
    var message: String?
    /// An email was sent; waiting for its code.
    private(set) var codeSentTo: String?

    /// Bots use Orbit Pro when you have it, unless you turn this off to use your own keys.
    var preferPro: Bool = UserDefaults.standard.object(forKey: "orbitCloud.usePro") as? Bool ?? true {
        didSet { UserDefaults.standard.set(preferPro, forKey: Self.useProKey) }
    }

    private var accessToken: String?
    private var accessExpires = Date.distantPast

    var isSignedIn: Bool { Secrets.get(Self.keychainAccount)?.isEmpty == false }
    /// True when bots should go through Orbit's server.
    var usesPro: Bool { isSignedIn && preferPro && (status?.pro ?? false) }

    // MARK: Signing in

    func sendCode(to address: String) async {
        let email = address.trimmingCharacters(in: .whitespaces).lowercased()
        guard email.contains("@") else { message = "Enter your email address."; return }
        busy = true
        defer { busy = false }
        do {
            // The email's "Log In" link opens orbit://auth-callback, which signs Orbit in.
            _ = try await auth("otp?redirect_to=\(Self.callback.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")",
                               ["email": email, "create_user": true])
            codeSentTo = email
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    func verify(code: String) async {
        guard let email = codeSentTo else { return }
        busy = true
        defer { busy = false }
        do {
            let json = try await auth("verify", ["type": "email", "email": email,
                                                  "token": code.filter(\.isNumber)])
            try store(json)
            self.email = email
            UserDefaults.standard.set(email, forKey: Self.emailKey)
            codeSentTo = nil
            message = nil
            await refreshStatus()
        } catch {
            message = error.localizedDescription
        }
    }

    func cancelCode() { codeSentTo = nil; message = nil }

    static let callback = "orbit://auth-callback"

    /// The sign-in link from the email: orbit://auth-callback#access_token=…&refresh_token=…
    func handle(_ url: URL) async {
        switch Self.signIn(from: url) {
        case .none:
            return
        case .failure(let why):
            message = why
        case .success(let link):
            accessToken = link.access
            accessExpires = .now.addingTimeInterval(Double(link.expiresIn))
            Secrets.set(link.refresh, for: Self.keychainAccount)
            codeSentTo = nil
            message = nil
            if let data = try? await Self.request("GET", path: "auth/v1/user", token: link.access),
               let user = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let address = user["email"] as? String {
                email = address
                UserDefaults.standard.set(address, forKey: Self.emailKey)
            }
            await refreshStatus()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    struct LinkSignIn: Equatable {
        let access: String
        let refresh: String
        let expiresIn: Int
    }

    enum LinkResult: Equatable {
        case success(LinkSignIn)
        case failure(String)
    }

    /// Reads the tokens (or the error) Supabase puts after the # in the sign-in link. nil when
    /// the link isn't a sign-in link.
    nonisolated static func signIn(from url: URL) -> LinkResult? {
        guard url.scheme == "orbit", url.host == "auth-callback" else { return nil }
        var items: [String: String] = [:]
        for part in [url.fragment, url.query].compactMap({ $0 }) {
            for pair in part.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding?.replacingOccurrences(of: "+", with: " ") ?? String($0) }
                if kv.count == 2 { items[kv[0]] = kv[1] }
            }
        }
        if let error = items["error_description"] ?? items["error"] {
            return .failure(error.lowercased().contains("expired")
                ? "That sign-in link has expired. Send a new one from Settings → Accounts."
                : "Orbit couldn't sign you in: \(error)")
        }
        guard let access = items["access_token"], let refresh = items["refresh_token"] else {
            return .failure("That sign-in link is incomplete. Send a new one from Settings → Accounts.")
        }
        return .success(LinkSignIn(access: access, refresh: refresh, expiresIn: Int(items["expires_in"] ?? "") ?? 3600))
    }

    func signOut() {
        let token = accessToken
        Secrets.set(nil, for: Self.keychainAccount)
        accessToken = nil
        status = nil
        email = nil
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
        if let token { Task { _ = try? await Self.request("POST", path: "auth/v1/logout", token: token, body: [:]) } }
    }

    /// A fresh sign-in token, renewed when it's about to run out.
    func token() async throws -> String {
        if let accessToken, accessExpires > .now.addingTimeInterval(60) { return accessToken }
        guard let refresh = Secrets.get(Self.keychainAccount), !refresh.isEmpty else { throw CloudError.signedOut }
        do {
            let json = try await auth("token?grant_type=refresh_token", ["refresh_token": refresh])
            try store(json)
            return accessToken!
        } catch let e as CloudError where e == .http(400, nil) || e == .http(401, nil) {
            signOut()
            throw CloudError.signedOut
        }
    }

    private func store(_ json: [String: Any]) throws {
        guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
            throw CloudError.message("Orbit couldn't sign you in. Try again.")
        }
        accessToken = access
        accessExpires = .now.addingTimeInterval(Double(json["expires_in"] as? Int ?? 3600))
        Secrets.set(refresh, for: Self.keychainAccount)
    }

    // MARK: Plan and billing

    func refreshStatus() async {
        guard isSignedIn else { status = nil; return }
        do {
            let data = try await function("billing", body: ["action": "status"])
            status = try JSONDecoder().decode(Status.self, from: data)
            // Remembered so Pro add-ons keep working offline for a while.
            if status?.pro == true { UserDefaults.standard.set(Date.now, forKey: Entitlements.lastProKey) }
            else { UserDefaults.standard.removeObject(forKey: Entitlements.lastProKey) }
        } catch CloudError.signedOut {
            status = nil
        } catch {
            message = error.localizedDescription
        }
    }

    /// Opens Paddle's checkout for Orbit Pro in the browser.
    func upgrade() async { await openBillingPage("checkout") }
    /// Opens Paddle's page to change card or cancel.
    func manage() async { await openBillingPage("portal") }

    private func openBillingPage(_ action: String) async {
        busy = true
        defer { busy = false }
        do {
            let data = try await function("billing", body: ["action": action])
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let s = json?["url"] as? String, let url = URL(string: s) else { throw CloudError.message("No link came back.") }
            NSWorkspace.shared.open(url)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: Requests

    /// Calls one of Orbit's server functions as the signed-in user.
    func function(_ name: String, method: String = "POST", path: String = "", body: [String: Any]? = nil,
                  query: [String: String] = [:]) async throws -> Data {
        let token = try await token()
        return try await Self.request(method, path: "functions/v1/\(name)\(path)", token: token, body: body, query: query)
    }

    /// Reads or writes your own rows (row rules on the server keep everyone to their own).
    func rest(_ method: String, _ table: String, query: [String: String], body: Any? = nil) async throws -> Data {
        let token = try await token()
        return try await Self.request(method, path: "rest/v1/\(table)", token: token, body: body, query: query,
                                      extraHeaders: ["Prefer": "return=minimal"])
    }

    private func auth(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        let data = try await Self.request("POST", path: "auth/v1/\(path)", token: nil, body: body)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func request(_ method: String, path: String, token: String?, body: Any? = nil, query: [String: String] = [:],
                        extraHeaders: [String: String] = [:]) async throws -> Data {
        var comps = URLComponents(url: url.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if path.contains("?") {
            // Paths like "token?grant_type=…" keep their own query.
            comps = URLComponents(string: url.absoluteString + "/" + path)!
        }
        if !query.isEmpty { comps.queryItems = (comps.queryItems ?? []) + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!, timeoutInterval: 60)
        req.httpMethod = method
        req.setValue(publishableKey, forHTTPHeaderField: "apikey")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: req) }
        catch { throw CloudError.message("Couldn't reach Orbit's server. Check your internet connection.") }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw CloudError.http(code, Self.errorText(data)) }
        return data
    }

    /// The message in Supabase's or Orbit's error answers.
    static func errorText(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let e = json["error"] as? [String: Any], let m = e["message"] as? String { return m }
        return (json["msg"] ?? json["message"] ?? json["error_description"] ?? json["error"]) as? String
    }

    enum CloudError: LocalizedError, Equatable {
        case signedOut
        case http(Int, String?)
        case message(String)

        var errorDescription: String? {
            switch self {
            case .signedOut: "You're signed out of Orbit. Sign in again in Settings → Accounts."
            case .http(let code, let text):
                switch code {
                case 429 where (text ?? "").lowercased().contains("email rate limit"):
                    "Orbit's sign-in emails are used up for this hour (the free email sender allows only a few per hour). Try again in an hour, or use an email you already received."
                case 429: "Too many tries. Wait a minute and try again."
                case 401: "You're signed out of Orbit. Sign in again in Settings → Accounts."
                default: text ?? "Orbit's server answered \(code)."
                }
            case .message(let m): m
            }
        }

        /// Matches on the code only.
        static func == (a: CloudError, b: CloudError) -> Bool {
            switch (a, b) {
            case (.signedOut, .signedOut): true
            case (.http(let x, _), .http(let y, _)): x == y
            case (.message(let x), .message(let y)): x == y
            default: false
            }
        }
    }
}
