import SwiftUI

/// Settings → Accounts → Orbit: sign in, Orbit Pro, AI use this month, and approvals on the phone.
struct OrbitAccountSection: View {
    var cloud = OrbitCloud.shared
    var phone: PhoneSync?
    @State private var email = OrbitCloud.shared.email ?? ""
    @State private var code = ""

    var body: some View {
        Section("Orbit account") {
            if cloud.isSignedIn {
                signedIn
            } else if let sentTo = cloud.codeSentTo {
                Text("We sent a sign-in email to \(sentTo). Open it on this Mac and click Log In; Orbit opens and signs you in.")
                    .font(.callout)
                Text("If the email has a 6-digit code instead, enter it here:").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Code", text: $code, prompt: Text("123456"))
                        .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 120)
                        .onSubmit(verify)
                    Button("Sign in", action: verify).disabled(code.filter(\.isNumber).count < 6 || cloud.busy)
                    Button("Use another email") { cloud.cancelCode(); code = "" }.buttonStyle(.link)
                    if cloud.busy { ProgressView().controlSize(.small) }
                }
            } else {
                HStack {
                    TextField("Email", text: $email, prompt: Text("you@company.com"))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .textContentType(.emailAddress)
                        .onSubmit(send)
                    Button("Send sign-in email", action: send).disabled(!email.contains("@") || cloud.busy)
                    if cloud.busy { ProgressView().controlSize(.small) }
                }
                Text("Sign in to get Orbit Pro (bots without your own API keys) and approvals on your phone. No password: Orbit emails you a sign-in link.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = cloud.message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
        .task { if cloud.isSignedIn { await cloud.refreshStatus() } }
    }

    @ViewBuilder private var signedIn: some View {
        LabeledContent("Signed in as") {
            HStack {
                Text(cloud.email ?? "you").foregroundStyle(.secondary)
                Button("Sign out") { cloud.signOut() }
            }
        }
        if let s = cloud.status {
            LabeledContent("Plan") {
                HStack {
                    Text(s.pro ? "Orbit Pro" : "Free").fontWeight(s.pro ? .semibold : .regular)
                    if s.status == "past_due" { Text("· payment failed").foregroundStyle(.orange) }
                    if s.pro {
                        Button("Manage…") { Task { await cloud.manage() } }
                    } else {
                        Button("Upgrade to Orbit Pro · $12/month") { Task { await cloud.upgrade() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            if s.pro {
                LabeledContent("AI included this month") {
                    HStack {
                        ProgressView(value: Double(min(s.spent_cents, s.limit_cents)), total: Double(max(s.limit_cents, 1)))
                            .frame(width: 120)
                        Text("\(BotRunner.dollars(s.spent_cents)) of \(BotRunner.dollars(s.limit_cents))").foregroundStyle(.secondary)
                    }
                }
                Toggle("Bots use Orbit Pro instead of my own API keys", isOn: Binding(
                    get: { cloud.preferPro }, set: { cloud.preferPro = $0 }))
                Text("Bots switch over on their next sync; old cloud schedules on your own key are archived so nothing runs twice.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Orbit Pro: bots run on Orbit's keys (Claude and ChatGPT), about $8 of AI use a month included, approvals on your phone. Paddle handles payment, VAT and receipts. Cancel any time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            HStack { ProgressView().controlSize(.small); Text("Checking your plan…").foregroundStyle(.secondary) }
        }
        if let phone {
            Toggle("Show approvals on my phone", isOn: Binding(get: { phone.enabled }, set: { phone.enabled = $0 }))
            HStack(alignment: .firstTextBaseline) {
                Text("On your iPhone, open \(OrbitCloud.phoneAppURL.absoluteString) in Safari, sign in with the same email, then Share → Add to Home Screen and allow notifications.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button("Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(OrbitCloud.phoneAppURL.absoluteString, forType: .string)
                }
                .buttonStyle(.link)
            }
            if let e = phone.lastError { Text(e).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func send() { Task { await cloud.sendCode(to: email) } }
    private func verify() { Task { await cloud.verify(code: code); code = "" } }
}
