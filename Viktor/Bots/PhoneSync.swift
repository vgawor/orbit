import Foundation

/// Approvals on your phone. While you're signed in to Orbit, approvals waiting on this Mac are
/// copied to Orbit's server (which pushes them to your phone), and answers given on the phone
/// come back here and run exactly like pressing Send or Skip in the notch.
@MainActor
@Observable
final class PhoneSync {
    private let runner: BotRunner
    private let cloud: OrbitCloud
    private var timer: Timer?
    private(set) var lastError: String?

    /// Approvals already copied to the server.
    private var sent: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "phone.sent") ?? [])
    private static let enabledKey = "phone.enabled"

    var enabled: Bool = UserDefaults.standard.object(forKey: "phone.enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey); if enabled { syncSoon() } }
    }

    init(runner: BotRunner, cloud: OrbitCloud = .shared) {
        self.runner = runner
        self.cloud = cloud
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func syncSoon() { Task { await sync() } }

    private var syncing = false

    func sync() async {
        guard enabled, cloud.isSignedIn, !syncing else { return }
        guard !runner.approvals.isEmpty || !sent.isEmpty else { return }
        syncing = true
        defer { syncing = false }
        do {
            // 1. Answers from the phone.
            if !sent.isEmpty {
                let data = try await cloud.rest("GET", "approvals", query: ["select": "id,decision", "status": "eq.decided"])
                for answer in Self.parseDecisions(data) {
                    guard let approval = runner.approvals.first(where: { $0.id == answer.id }) else { continue }
                    let edits = answer.approve ? Self.edits(answer.fields, for: approval) : nil
                    await runner.decide(approval.id, approve: answer.approve, edited: edits?.isEmpty == false ? edits : nil)
                }
            }
            // 2. Send new ones, and mark the ones that are done (answered here or on the phone).
            let waiting = runner.approvals
            let fresh = waiting.filter { !sent.contains($0.id) }
            let gone = sent.subtracting(waiting.map(\.id))
            guard !fresh.isEmpty || !gone.isEmpty else { return }
            _ = try await cloud.function("phone", body: [
                "pending": fresh.map(payload),
                "gone": Array(gone),
            ])
            sent.formUnion(fresh.map(\.id))
            sent.subtract(gone)
            UserDefaults.standard.set(Array(sent), forKey: "phone.sent")
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// An approval as the phone shows it.
    private func payload(_ a: BotApproval) -> [String: Any] {
        let bot = runner.store.bot(a.botID)
        let shown = ApprovalPresentation(tool: a.tool, input: a.input)
        return [
            "id": a.id, "bot_name": bot?.name ?? "A bot", "bot_color": bot?.color ?? "dot",
            "title": shown.title, "action": shown.action, "reason": a.reason ?? "",
            "fields": shown.fields.map { ["key": $0.key, "label": $0.label, "value": $0.value, "multiline": $0.multiline, "list": $0.isList] },
        ]
    }

    struct Answer: Equatable {
        let id: String
        let approve: Bool
        let fields: [String: String]
    }

    /// `[{"id": "…", "decision": {"approve": true, "fields": {"body": "…"}}}]`
    nonisolated static func parseDecisions(_ data: Data) -> [Answer] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let d = row["decision"] as? [String: Any] else { return nil }
            return Answer(id: id, approve: d["approve"] as? Bool ?? false, fields: d["fields"] as? [String: String] ?? [:])
        }
    }

    /// The phone's edited text, turned into tool input the same way the notch's Edit does.
    static func edits(_ fields: [String: String], for approval: BotApproval) -> [String: Any] {
        var shown = ApprovalPresentation(tool: approval.tool, input: approval.input)
        for i in shown.fields.indices { if let v = fields[shown.fields[i].key] { shown.fields[i].value = v } }
        return shown.edits(from: approval.input)
    }
}
