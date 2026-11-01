import SwiftUI

struct SettingsView: View {
    let registry: ModuleRegistry
    let delegate: AppDelegate
    @State private var loginOn = LoginItem.isEnabled
    @State private var loginMessage: String?
    @AppStorage(SettingsView.tabKey) private var tab: Tab = .general

    enum Tab: String { case general, addOns, bots, appearance, accounts, developer }
    static let tabKey = "settingsTab"

    /// Picks the tab Settings opens on (call before opening it).
    static func show(_ tab: Tab) { UserDefaults.standard.set(tab.rawValue, forKey: tabKey) }

    var body: some View {
        TabView(selection: $tab) {
            Form {
                AboutYouSection()
                Section("Startup") {
                    Toggle("Start Orbit when I log in", isOn: Binding(
                        get: { loginOn },
                        set: { on in loginMessage = LoginItem.set(on); loginOn = LoginItem.isEnabled }))
                        .disabled(!LoginItem.isInstalled)
                    if !LoginItem.isInstalled {
                        Text("Install Orbit in Applications first: run scripts/install.sh.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let loginMessage { Text(loginMessage).font(.caption).foregroundStyle(.secondary) }
                }
                Section("Notch") {
                    Toggle("Show the pill on displays without a notch", isOn: Binding(
                        get: { delegate.vm.showPillWithoutNotch },
                        set: { delegate.vm.showPillWithoutNotch = $0 }))
                    Picker("Peek stays after the pointer leaves", selection: Binding(
                        get: { delegate.vm.peekLinger },
                        set: { delegate.vm.peekLinger = $0 })) {
                        Text("Close right away").tag(0.0)
                        Text("2 seconds").tag(2.0)
                        Text("4 seconds").tag(4.0)
                        Text("8 seconds").tag(8.0)
                        Text("15 seconds").tag(15.0)
                    }
                    Picker("Open notch stays after the pointer leaves", selection: Binding(
                        get: { delegate.vm.openLinger },
                        set: { delegate.vm.openLinger = $0 })) {
                        Text("Close right away").tag(0.3)
                        Text("2 seconds").tag(2.0)
                        Text("4 seconds").tag(4.0)
                        Text("8 seconds").tag(8.0)
                        Text("15 seconds").tag(15.0)
                        Text("Until I click outside").tag(-1.0)
                    }
                    Toggle("Orbit nudges me when something needs me", isOn: Binding(
                        get: { delegate.vm.companionFlight },
                        set: { delegate.vm.companionFlight = $0 }))
                    Text("Hover the top center of the screen to peek. Click to open.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Shortcuts") {
                    LabeledContent("Open or close Orbit", value: "⌥ Space")
                    LabeledContent("Close", value: "Esc")
                }
                Section("Welcome") {
                    Button("Show the welcome tour again") {
                        UserDefaults.standard.removeObject(forKey: Onboarding.checklistHiddenKey)
                        OnboardingWindow.shared.show(vm: delegate.vm, registry: registry)
                    }
                }
                Section("Updates") {
                    LabeledContent("Version", value: Updater.version)
                    if Updater.shared.isAvailable {
                        Toggle("Check for updates automatically", isOn: Binding(
                            get: { Updater.shared.automaticallyChecks },
                            set: { Updater.shared.automaticallyChecks = $0 }))
                        Button("Check for updates now") { Updater.shared.checkForUpdates() }
                    } else {
                        Text("Updates work in the installed app.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }
            .tag(Tab.general)

            AddOnsSettings(registry: registry)
                .tabItem { Label("Add-ons", systemImage: "puzzlepiece.extension") }
                .tag(Tab.addOns)

            BotsSettings(module: registry.module(BotsModule.self))
                .tabItem { Label("Bots", systemImage: "person.2.wave.2") }
                .tag(Tab.bots)

            AppearanceSettings(registry: registry)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
                .tag(Tab.appearance)

            AccountsSettings(tasks: registry.module(TasksModule.self), phone: registry.module(BotsModule.self)?.phone)
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                .tag(Tab.accounts)

            DeveloperSettings(api: delegate.api, agents: registry.module(AgentsModule.self))
                .tabItem { Label("Developer", systemImage: "terminal") }
                .tag(Tab.developer)
        }
        .frame(width: 760, height: 600)
        .onAppear { DispatchQueue.main.async { SettingsWindow.bringForward() } }
    }
}

/// Settings → General → About you: who your bots and Smart Ask work for.
struct AboutYouSection: View {
    @AppStorage("look.name") private var firstName = ""
    @AppStorage(UserProfile.fullNameKey) private var fullName = ""
    @AppStorage(UserProfile.companyKey) private var company = ""
    @AppStorage(UserProfile.aboutKey) private var about = ""

    var body: some View {
        Section("About you") {
            TextField("What Orbit calls you", text: $firstName, prompt: Text(UserProfile.firstName))
            TextField("Full name", text: $fullName, prompt: Text(NSFullUserName()))
            TextField("Company", text: $company, prompt: Text("Optional"))
            TextField("What you do", text: $about, prompt: Text("Optional, e.g. “Sells design services to retailers”"), axis: .vertical)
            Text("Bots and Smart Ask use this to know who they work for: “\(UserProfile.intro(fullName: fullName.isEmpty ? NSFullUserName() : fullName, company: company, about: about))”")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
