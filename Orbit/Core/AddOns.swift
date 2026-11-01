import SwiftUI

/// Add-ons: optional features grouped by category, each Free or Pro.
/// They're off until you add them in Settings → Add-ons (so the tab bar doesn't fill up).
///
/// To build one: make a type that conforms to `AddOnModule` (a `NotchModule` with `addOn` info)
/// in `Orbit/Modules/AddOns/<Category>/`, and return it from that category's `make(_:)`.

enum AddOnCategory: String, CaseIterable, Identifiable, Codable {
    case productivity, health, finance, security, fun, developers, ai

    var id: String { rawValue }
    var title: String {
        switch self {
        case .productivity: "Productivity"
        case .health: "Health"
        case .finance: "Finance"
        case .security: "Security"
        case .fun: "Fun"
        case .developers: "Developers"
        case .ai: "AI"
        }
    }
    var symbol: String {
        switch self {
        case .productivity: "checklist"
        case .health: "heart.fill"
        case .finance: "chart.line.uptrend.xyaxis"
        case .security: "lock.shield.fill"
        case .fun: "gamecontroller.fill"
        case .developers: "chevron.left.forwardslash.chevron.right"
        case .ai: "sparkles"
        }
    }
    var tint: Color {
        switch self {
        case .productivity: Color(red: 0.36, green: 0.62, blue: 1)
        case .health: Color(red: 1, green: 0.42, blue: 0.47)
        case .finance: Color(red: 0.2, green: 0.78, blue: 0.35)
        case .security: Color(red: 1, green: 0.69, blue: 0.13)
        case .fun: Color(red: 0.94, green: 0.55, blue: 0.7)
        case .developers: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .ai: Color(red: 0.63, green: 0.59, blue: 0.99)
        }
    }
    var blurb: String {
        switch self {
        case .productivity: "Get more done without leaving what you're doing."
        case .health: "Small nudges to drink, breathe, rest your eyes and move."
        case .finance: "Money at a glance: rates, budgets and subscriptions."
        case .security: "Know what your Mac is doing and keep it locked down."
        case .fun: "A little play in the notch."
        case .developers: "Builds, ports, containers and tools for your day as a developer."
        case .ai: "Claude in the notch: summarise, translate, rewrite and more."
        }
    }
}

enum AddOnTier: String, Codable { case free, pro }

struct AddOnInfo {
    let category: AddOnCategory
    let tier: AddOnTier
    /// One sentence for the gallery.
    let summary: String
    /// "Orbit" for built-in add-ons; a person or company for community ones.
    var author: String = "Orbit"
}

/// A `NotchModule` that's an add-on.
@MainActor
protocol AddOnModule: NotchModule {
    var addOn: AddOnInfo { get }
}

/// What add-ons get from the app.
struct AddOnContext {
    let alerts: AlertCenter
    /// Opens the notch on a tab (pass a module id).
    let openPanel: @MainActor (String) -> Void
    let closePanel: @MainActor () -> Void
    /// Adds a task on this Mac (title, optional due date).
    var addTask: @MainActor (String, Date?) -> Void = { _, _ in }
    /// Adds a note with this text.
    var addNote: @MainActor (String) -> Void = { _ in }
}

/// Every built-in add-on, category by category.
@MainActor
enum AddOnCatalog {
    static func make(_ ctx: AddOnContext) -> [any NotchModule] {
        ProductivityAddOns.make(ctx) + HealthAddOns.make(ctx) + FinanceAddOns.make(ctx) + SecurityAddOns.make(ctx)
            + FunAddOns.make(ctx) + DeveloperAddOns.make(ctx) + AIAddOns.make(ctx)
            + ScriptWidgets.load()   // community widgets in ~/Library/Application Support/Orbit/Widgets
    }
}

/// Free or Pro. Pro add-ons follow your Orbit Pro plan (Settings → Accounts → Orbit account)
/// once `OrbitProRequired` is on in Info.plist; test builds leave it off, so everything is unlocked.
/// Settings → Add-ons → "Preview as Free" shows what Free users see.
@MainActor
@Observable
final class Entitlements {
    static let shared = Entitlements()

    var previewAsFree = UserDefaults.standard.bool(forKey: "pro.previewAsFree") {
        didSet { UserDefaults.standard.set(previewAsFree, forKey: "pro.previewAsFree") }
    }

    /// On at launch: Pro add-ons need Orbit Pro. Off in test builds.
    static var proRequired: Bool { Bundle.main.object(forInfoDictionaryKey: "OrbitProRequired") as? Bool ?? false }

    /// The last plan Orbit saw, kept for 14 days so Pro keeps working offline.
    static let lastProKey = "pro.lastConfirmed"
    nonisolated static let offlineGrace: TimeInterval = 14 * 86400

    var isPro: Bool {
        if previewAsFree { return false }
        if !Self.proRequired { return true }
        if let status = OrbitCloud.shared.status { return status.pro }
        return Self.recentlyPro(lastConfirmed: UserDefaults.standard.object(forKey: Self.lastProKey) as? Date, now: .now)
    }

    nonisolated static func recentlyPro(lastConfirmed: Date?, now: Date) -> Bool {
        guard let lastConfirmed else { return false }
        return now.timeIntervalSince(lastConfirmed) < offlineGrace
    }

    func allows(_ tier: AddOnTier) -> Bool { tier == .free || isPro }
}

// MARK: - Small shared pieces for add-on panels

/// The header every add-on panel starts with: icon, title and a short line.
struct AddOnHeader: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 32, height: 32).glassSurface(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: .semibold))
                if let subtitle { Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Tokens.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
    }
}
