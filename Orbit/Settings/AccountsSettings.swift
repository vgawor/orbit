import AppKit
import SwiftUI

/// Settings → Accounts: connect HubSpot so your tasks show in the Tasks tab.
struct AccountsSettings: View {
    let tasks: TasksModule?
    var phone: PhoneSync? = nil

    @State private var token = ""
    @State private var email = UserDefaults.standard.string(forKey: HubSpotTaskProvider.emailKey) ?? ""
    @State private var hasToken = Secrets.get(HubSpotTaskProvider.tokenAccount) != nil
    @State private var status: String?
    @State private var statusIsError = false
    @State private var testing = false

    @State private var claudeKey = ""
    @State private var hasClaudeKey = Secrets.get(ClaudeAPI.keyAccount) != nil
    @State private var claudeStatus: String?
    @State private var claudeOK = false
    @State private var claudeTesting = false

    var body: some View {
        Form {
            OrbitAccountSection(phone: phone)

            Section("Claude") {
                if hasClaudeKey {
                    LabeledContent("API key") {
                        HStack {
                            Text("Saved in Keychain").foregroundStyle(.secondary)
                            Button("Remove") {
                                Secrets.set(nil, for: ClaudeAPI.keyAccount)
                                hasClaudeKey = false
                                claudeStatus = nil
                            }
                        }
                    }
                } else {
                    SecureField("Anthropic API key (sk-ant-…)", text: $claudeKey)
                }
                HStack {
                    if claudeTesting { ProgressView().controlSize(.small) }
                    if let claudeStatus {
                        Text(claudeStatus).font(.caption).foregroundStyle(claudeOK ? .green : .red)
                    }
                    Spacer()
                    Button(hasClaudeKey ? "Test" : "Save and test", action: testClaude)
                        .disabled((!hasClaudeKey && claudeKey.isEmpty) || claudeTesting)
                }
                Text("Powers Smart Ask, the morning brief and meeting prep, using \(ClaudeAPI.model). Create a key at console.anthropic.com → API keys. Usage is billed to that account; what you ask, plus the meetings, tasks and HubSpot details needed for the answer, is sent to Anthropic.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ChatGPTAccountSection()

            Section("HubSpot") {
                TextField("Your HubSpot login email", text: $email)
                    .textContentType(.emailAddress)
                    .onSubmit(saveEmail)
                if hasToken {
                    LabeledContent("Private app token") {
                        HStack {
                            Text("Saved in Keychain").foregroundStyle(.secondary)
                            Button("Remove") {
                                Secrets.set(nil, for: HubSpotTaskProvider.tokenAccount)
                                hasToken = false
                                status = nil
                                Task { await tasks?.reload() }
                            }
                        }
                    }
                } else {
                    SecureField("Private app token (pat-…)", text: $token)
                }
                HStack {
                    if testing { ProgressView().controlSize(.small) }
                    if let status {
                        Text(status).font(.caption).foregroundStyle(statusIsError ? .red : .green)
                    }
                    Spacer()
                    Button(hasToken ? "Test connection" : "Save and connect", action: connect)
                        .disabled(email.isEmpty || (!hasToken && token.isEmpty) || testing)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("How to get a token").font(.headline)
                    Text("In HubSpot: Settings → Integrations → Private Apps → Create a private app. On the Scopes tab, tick:")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("""
                    crm.objects.contacts.read    (read tasks)
                    crm.objects.contacts.write   (tick off and create tasks)
                    crm.objects.owners.read      (find which tasks are yours)
                    crm.objects.projects.read    (show project names)
                    crm.objects.tasks.read / .write   (if your account lists them)
                    crm.objects.deals.read / .write   (Account Manager: deals)
                    sales-email-read             (Account Manager: customer replies)
                    """)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Create the app, then copy its access token (pat-…) here.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("If a permission is missing, the test above names it.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Orbit shows open tasks assigned to you, ticks them off and creates new ones. It never deletes HubSpot tasks.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            SpotifyAccountSection()
        }
        .formStyle(.grouped)
    }

    private func testClaude() {
        if !hasClaudeKey {
            Secrets.set(claudeKey.trimmingCharacters(in: .whitespacesAndNewlines), for: ClaudeAPI.keyAccount)
            claudeKey = ""
            hasClaudeKey = Secrets.get(ClaudeAPI.keyAccount) != nil
        }
        claudeTesting = true
        claudeStatus = nil
        Task {
            do {
                let r = try await ClaudeAPI.send(system: "Reply with exactly: OK",
                                                 messages: [["role": "user", "content": "Test"]], maxTokens: 64)
                claudeOK = true
                claudeStatus = "Connected · \((r["model"] as? String) ?? ClaudeAPI.model)"
            } catch {
                claudeOK = false
                claudeStatus = error.localizedDescription
            }
            claudeTesting = false
        }
    }

    private func saveEmail() {
        UserDefaults.standard.set(email.trimmingCharacters(in: .whitespaces), forKey: HubSpotTaskProvider.emailKey)
    }

    private func connect() {
        saveEmail()
        if !hasToken {
            Secrets.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: HubSpotTaskProvider.tokenAccount)
            token = ""
            hasToken = Secrets.get(HubSpotTaskProvider.tokenAccount) != nil
        }
        testing = true
        status = nil
        Task {
            do {
                let open = try await HubSpotTaskProvider().test()
                status = "Connected · \(open) open task\(open == 1 ? "" : "s") assigned to you"
                statusIsError = false
                await tasks?.reload()
            } catch {
                status = error.localizedDescription
                statusIsError = true
            }
            testing = false
        }
    }
}


/// Settings → Accounts → Spotify: the Client ID of your own Spotify app, and Connect / Disconnect.
private struct SpotifyAccountSection: View {
    @State private var spotify = SpotifyConnect.shared

    var body: some View {
        @Bindable var spotify = spotify
        Section("Spotify") {
            TextField("Client ID", text: $spotify.clientID, prompt: Text("From developer.spotify.com"))
                .textContentType(.none)
            HStack {
                if spotify.connected {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Disconnect") { spotify.disconnect() }
                } else {
                    Text("Not connected").foregroundStyle(.secondary)
                    Spacer()
                    Button("Connect Spotify") { spotify.connect() }.disabled(!spotify.hasClientID)
                }
            }
            if let problem = spotify.problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup("How to get a Client ID (5 minutes)") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Go to developer.spotify.com/dashboard and log in with your Spotify account.")
                    Text("2. Click Create app. Name it Orbit, tick Web API.")
                    Text("3. Add this Redirect URI: \(SpotifyConnect.redirectURI)")
                        .textSelection(.enabled)
                    Text("4. Save, then copy the Client ID into the field above and click Connect Spotify.")
                    Text("Choosing where Spotify plays needs Spotify Premium. Orbit only asks to see and change what's playing.")
                        .foregroundStyle(.secondary).padding(.top, 2)
                }
                .font(.caption)
            }
        }
        .onAppear { spotify.refreshState() }
    }
}

/// Settings → Accounts → ChatGPT: an OpenAI API key for bots that run with ChatGPT.
struct ChatGPTAccountSection: View {
    @State private var key = ""
    @State private var hasKey = Secrets.get(OpenAIAPI.keyAccount) != nil
    @State private var status: String?
    @State private var ok = false
    @State private var testing = false

    var body: some View {
        Section("ChatGPT") {
            if hasKey {
                LabeledContent("API key") {
                    HStack {
                        Text("Saved in Keychain").foregroundStyle(.secondary)
                        Button("Remove") {
                            Secrets.set(nil, for: OpenAIAPI.keyAccount)
                            hasKey = false
                            status = nil
                        }
                    }
                }
            } else {
                SecureField("OpenAI API key (sk-…)", text: $key)
            }
            HStack {
                if testing { ProgressView().controlSize(.small) }
                if let status { Text(status).font(.caption).foregroundStyle(ok ? .green : .red) }
                Spacer()
                Button(hasKey ? "Test" : "Save and test", action: test)
                    .disabled((!hasKey && key.isEmpty) || testing)
            }
            Text("Optional. Lets bots run with ChatGPT instead of Claude (Settings → Bots → Runs with). They run on this Mac while it's awake. Create a key at platform.openai.com → API keys; a ChatGPT subscription doesn't include API use. Usage is billed to that account, and what a bot reads is sent to OpenAI.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func test() {
        if !hasKey {
            Secrets.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: OpenAIAPI.keyAccount)
            key = ""
            hasKey = Secrets.get(OpenAIAPI.keyAccount) != nil
        }
        testing = true
        status = nil
        Task {
            do {
                let turn = try await OpenAIAPI.start(model: BotProvider.chatgpt.defaultModel, instructions: "Reply with exactly: OK",
                                                     message: "Test", tools: [])
                ok = true
                status = "Connected · \(turn.model.isEmpty ? BotProvider.chatgpt.defaultModel : turn.model)"
            } catch {
                ok = false
                status = error.localizedDescription
            }
            testing = false
        }
    }
}
