import Foundation
import Testing
@testable import Orbit

@MainActor
struct OrbitProTests {
    @Test func phoneAnswersBecomeTheSameEditsAsTheNotch() throws {
        let data = Data(#"[{"id":"sevt_1","decision":{"approve":true,"fields":{"to":"dana@acme.se, anna@acme.se","body":"Hi Dana, thanks!"}}},{"id":"sevt_2","decision":{"approve":false,"fields":{}}},{"id":"broken"}]"#.utf8)
        let answers = PhoneSync.parseDecisions(data)
        #expect(answers.count == 2)
        #expect(answers[0] == .init(id: "sevt_1", approve: true, fields: ["to": "dana@acme.se, anna@acme.se", "body": "Hi Dana, thanks!"]))
        #expect(answers[1].approve == false)

        let input: [String: Any] = ["to": ["dana@acme.se"], "subject": "Re: Pricing", "body": "Hi Dana"]
        let json = String(data: try JSONSerialization.data(withJSONObject: input), encoding: .utf8)!
        let approval = BotApproval(id: "sevt_1", runID: "r", botID: "account-manager", tool: "draft_email", inputJSON: json, reason: nil, created: .now)
        let edits = PhoneSync.edits(answers[0].fields, for: approval)
        #expect(edits["to"] as? [String] == ["dana@acme.se", "anna@acme.se"])
        #expect(edits["body"] as? String == "Hi Dana, thanks!")
        #expect(edits["subject"] == nil, "unchanged fields aren't sent")
        #expect(PhoneSync.edits([:], for: approval).isEmpty)
        #expect(PhoneSync.parseDecisions(Data("nope".utf8)).isEmpty)
    }

    @Test func serverErrorsReadWell() {
        #expect(OrbitCloud.errorText(Data(#"{"error":{"type":"orbit_error","message":"Orbit Pro isn't active on this account."}}"#.utf8)) == "Orbit Pro isn't active on this account.")
        #expect(OrbitCloud.errorText(Data(#"{"msg":"Token has expired or is invalid"}"#.utf8)) == "Token has expired or is invalid")
        #expect(OrbitCloud.errorText(Data("<html>".utf8)) == nil)
        #expect(OrbitCloud.CloudError.http(429, nil).localizedDescription.contains("Wait a minute"))
        #expect(OrbitCloud.CloudError.http(429, "email rate limit exceeded").localizedDescription.contains("this hour"))
        #expect(OrbitCloud.CloudError.http(402, "You've used this month's AI").localizedDescription == "You've used this month's AI")
        #expect(OrbitCloud.CloudError.signedOut.localizedDescription.contains("Sign in again"))
        #expect(OrbitCloud.CloudError.http(400, "a") == .http(400, nil), "matched on the code")
    }

    @Test func runsKeepTheModeTheyStartedIn() async throws {
        #expect(CloudMode(rawValue: "pro") == .pro)
        #expect(CloudMode.override == nil)
        await CloudMode.$override.withValue(.pro) {
            #expect(CloudMode.active == .pro)
        }
        var run = BotRun(id: "sesn_1", botID: "b", kind: .scheduled, title: "", started: .now)
        run.cloudMode = "pro"
        let back = try JSONDecoder().decode(BotRun.self, from: JSONEncoder().encode(run))
        #expect(back.cloudMode == "pro")
        var bot = Bot.chiefOfStaff
        bot.cloudMode = "pro"
        #expect(try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(bot)).cloudMode == "pro")
    }

    @Test func signedOutMeansOwnKeys() {
        // Without an Orbit sign-in, bots never go through Orbit's server.
        if !OrbitCloud.shared.isSignedIn {
            #expect(!OrbitCloud.shared.usesPro)
            #expect(CloudMode.current == .own)
        }
        #expect(OrbitCloud.url.host == "agxhwmdzbdatvsjuvsma.supabase.co")
        #expect(OrbitCloud.publishableKey.hasPrefix("sb_publishable_"), "only the publishable key ships in the app")
    }

    @Test func signInLinksAreRead() {
        let good = URL(string: "orbit://auth-callback#access_token=eyJabc&expires_in=3600&expires_at=1&refresh_token=r1x&token_type=bearer&type=magiclink")!
        #expect(OrbitCloud.signIn(from: good) == .success(.init(access: "eyJabc", refresh: "r1x", expiresIn: 3600)))

        let expired = URL(string: "orbit://auth-callback#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired")!
        if case .failure(let why) = OrbitCloud.signIn(from: expired) { #expect(why.contains("expired")) } else { Issue.record("expired links are explained") }

        if case .failure = OrbitCloud.signIn(from: URL(string: "orbit://auth-callback#access_token=only")!) {} else { Issue.record("needs both tokens") }
        #expect(OrbitCloud.signIn(from: URL(string: "orbit://something-else#access_token=a&refresh_token=b")!) == nil)
        #expect(OrbitCloud.signIn(from: URL(string: "https://auth-callback#access_token=a&refresh_token=b")!) == nil)
        #expect(OrbitCloud.callback == "orbit://auth-callback")
    }
}
