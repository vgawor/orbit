import EventKit
import SwiftUI

/// "Get started 3/6" on Home for new users: a few first things to try. Goes away once
/// everything is ticked off, or when you close it.
struct GetStartedCard: View {
    let vm: NotchViewModel
    let registry: ModuleRegistry
    @AppStorage(Onboarding.checklistHiddenKey) private var hidden = false
    @Environment(\.openSettings) private var openSettings

    private struct Item: Identifiable {
        let id: String
        let title: String
        let done: Bool
        let action: () -> Void
    }

    private var items: [Item] {
        _ = vm.selectedTab   // re-check when you move between tabs
        return [
            Item(id: "shortcut", title: "Open Orbit with ⌥ Space", done: Onboarding.hasVisited("shortcut")) {},
            Item(id: "calendar", title: "Connect your calendar",
                 done: EKEventStore.authorizationStatus(for: .event) == .fullAccess) {
                registry.module(MeetingsModule.self)?.requestAccess()
            },
            Item(id: "addon", title: "Add an add-on", done: registry.addOns.contains { registry.isEnabled($0.id) }) {
                SettingsView.show(.addOns)
                SettingsWindow.willOpen()
                openSettings()
            },
            Item(id: "launcher", title: "Open the Add-ons tab", done: Onboarding.hasVisited(AddOnsLauncher.tabID)) {
                vm.selectedTab = AddOnsLauncher.tabID
            },
            Item(id: "focus", title: "Start a focus session", done: Onboarding.hasVisited("focus")) {
                vm.selectedTab = "focus"
            },
            Item(id: "ask", title: "Ask Orbit something (⌥K)", done: Onboarding.hasVisited("ask")) {
                vm.selectedTab = "ask"
            },
        ]
    }

    var body: some View {
        let items = self.items
        let done = items.filter(\.done).count
        if !hidden && (done < items.count || ModuleRegistry.isPreview) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    OrbitView(size: 30, mood: .happy, motion: .idle)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Get started").font(.system(size: 14, weight: .semibold))
                        Text("\(done) of \(items.count) done").font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
                    }
                    Spacer()
                    ProgressRing(value: Double(done) / Double(items.count)).frame(width: 22, height: 22)
                    Button { hidden = true } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Tokens.secondary)
                            .frame(width: 22, height: 22).background(Circle().fill(Tokens.surface2))
                    }
                    .buttonStyle(.plain).help("Hide")
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(items) { item in
                        Button(action: item.action) {
                            HStack(spacing: 8) {
                                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.done ? Color.green : Tokens.secondary)
                                Text(item.title).font(.system(size: 12, weight: .medium))
                                    .strikethrough(item.done, color: .white.opacity(0.4))
                                    .foregroundStyle(item.done ? Tokens.secondary : .white)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.05)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(item.done)
                    }
                }
            }
            .padding(14)
            .glassCard(22)
        }
    }
}

private struct ProgressRing: View {
    let value: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 3)
            Circle().trim(from: 0, to: value).stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
