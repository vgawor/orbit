import Foundation

// MARK: - Deals, replies and notes (for bots like Account Manager)

extension HubSpotTaskProvider {
    // MARK: Whose deal is it

    /// The deals among `ids` that are yours (you're the deal owner in HubSpot).
    func ownedDeals(_ ids: [String]) async -> Set<String> {
        let unique = Array(Set(ids.map { $0.filter(\.isNumber) }.filter { !$0.isEmpty }))
        guard !unique.isEmpty, let owner = try? await resolveOwner(),
              let r = try? await request("POST", "/crm/v3/objects/deals/batch/read", body: [
                  "properties": ["hubspot_owner_id"], "inputs": unique.prefix(100).map { ["id": $0] }]) else { return [] }
        return Set((r["results"] as? [[String: Any]] ?? []).compactMap { d in
            Self.isOwned(d, by: owner) ? d["id"] as? String : nil
        })
    }

    nonisolated static func isOwned(_ object: [String: Any], by owner: String) -> Bool {
        let p = object["properties"] as? [String: Any] ?? [:]
        let id = p["hubspot_owner_id"].map { "\($0)" } ?? ""
        return !owner.isEmpty && id == owner
    }

    /// Stops changes to deals that belong to someone else.
    private func requireOwned(_ dealID: String) async throws {
        guard await ownedDeals([dealID]).contains(dealID.filter(\.isNumber)) else {
            throw HubSpotError.http(403, "deal \(dealID) belongs to someone else in HubSpot, so Orbit won't change it")
        }
    }

    /// Your open deals with no logged activity for `days` days, oldest first.
    func quietDeals(days: Int) async -> String {
        guard Self.isConfigured else { return "HubSpot isn't connected." }
        let since = Date.now.addingTimeInterval(-Double(max(days, 1)) * 86400)
        let ms = "\(Int(since.timeIntervalSince1970 * 1000))"
        let owner: String
        do { owner = try await resolveOwner() } catch { return "Couldn't find your HubSpot user: \(error.localizedDescription)" }
        let mine: [String: Any] = ["propertyName": "hubspot_owner_id", "operator": "EQ", "value": owner]
        let open: [String: Any] = ["propertyName": "hs_is_closed", "operator": "EQ", "value": "false"]
        do {
            let json = try await request("POST", "/crm/v3/objects/deals/search", body: [
                "filterGroups": [
                    ["filters": [mine, open, ["propertyName": "notes_last_updated", "operator": "LT", "value": ms]]],
                    ["filters": [mine, open, ["propertyName": "notes_last_updated", "operator": "NOT_HAS_PROPERTY"]]],
                ],
                "properties": Self.dealProperties,
                "sorts": [["propertyName": "notes_last_updated", "direction": "ASCENDING"]],
                "limit": 15,
            ])
            let deals = json["results"] as? [[String: Any]] ?? []
            guard !deals.isEmpty else { return "No open deals have been quiet for \(days) days." }
            return "Open deals with no activity for \(days)+ days:\n" + deals.map(Self.dealLine).joined(separator: "\n")
        } catch {
            return "Couldn't search deals: \(error.localizedDescription)"
        }
    }

    /// Emails customers sent in the last `days` days that HubSpot logged, with the deals they belong to.
    func recentReplies(days: Int) async -> String {
        guard Self.isConfigured else { return "HubSpot isn't connected." }
        let since = Date.now.addingTimeInterval(-Double(max(days, 1)) * 86400)
        do {
            let json = try await request("POST", "/crm/v3/objects/emails/search", body: [
                "filterGroups": [["filters": [
                    ["propertyName": "hs_email_direction", "operator": "EQ", "value": "INCOMING_EMAIL"],
                    ["propertyName": "hs_timestamp", "operator": "GTE", "value": "\(Int(since.timeIntervalSince1970 * 1000))"],
                ]]],
                "properties": ["hs_email_subject", "hs_email_from_email", "hs_email_text", "hs_timestamp", "hubspot_owner_id"],
                "sorts": [["propertyName": "hs_timestamp", "direction": "DESCENDING"]],
                "limit": 50,
            ])
            let all = json["results"] as? [[String: Any]] ?? []
            guard !all.isEmpty else { return "No customer replies logged in HubSpot in the last \(days) days." }
            let owner = (try? await resolveOwner()) ?? ""
            let ids = all.compactMap { $0["id"] as? String }
            var dealFor: [String: [String]] = [:]
            if let r = try? await request("POST", "/crm/v4/associations/emails/deals/batch/read", body: ["inputs": ids.map { ["id": $0] }]) {
                for row in r["results"] as? [[String: Any]] ?? [] {
                    guard let from = (row["from"] as? [String: Any])?["id"].map({ "\($0)" }) else { continue }
                    dealFor[from] = (row["to"] as? [[String: Any]] ?? []).compactMap { $0["toObjectId"].map { "\($0)" } }
                }
            }
            // Only replies on your deals (or yours and not on any deal); colleagues' customers are left out.
            let mine = await ownedDeals(dealFor.values.flatMap { $0 })
            let emails = all.filter { e in
                let id = e["id"] as? String ?? ""
                let deals = dealFor[id] ?? []
                return deals.isEmpty ? Self.isOwned(e, by: owner) : deals.contains(where: mine.contains)
            }.prefix(15)
            guard !emails.isEmpty else { return "No customer replies on your deals in the last \(days) days." }
            return emails.map { e in
                let p = e["properties"] as? [String: Any] ?? [:]
                let id = e["id"] as? String ?? ""
                let deals = dealFor[id].map { " · deal id \($0.filter(mine.contains).joined(separator: ", "))" } ?? " · no deal"
                return "• \(Self.text(p["hs_timestamp"]).prefix(10)) from \(Self.text(p["hs_email_from_email"])): “\(Self.text(p["hs_email_subject"]))”\(deals)\n  \(Self.text(p["hs_email_text"]).prefix(400))"
            }.joined(separator: "\n")
        } catch {
            return "Couldn't read logged emails: \(error.localizedDescription)"
        }
    }

    /// One deal: its numbers, the people on it, recent notes and emails.
    func dealDetails(_ id: String) async -> String {
        guard Self.isConfigured else { return "HubSpot isn't connected." }
        let safe = id.filter(\.isNumber)
        guard !safe.isEmpty, let deal = try? await request("GET", "/crm/v3/objects/deals/\(safe)?properties=\(Self.dealProperties.joined(separator: ","))", body: nil) else {
            return "No deal with id \(id) (or the token can't read deals)."
        }
        if let owner = try? await resolveOwner(), !Self.isOwned(deal, by: owner) {
            return "Deal \(safe) belongs to someone else in HubSpot, not the user. Leave it alone: no follow-ups, tasks or notes for it."
        }
        var lines = [Self.dealLine(deal)]
        func linked(_ type: String) async -> [String] {
            guard let r = try? await request("GET", "/crm/v4/objects/deals/\(safe)/associations/\(type)?limit=20", body: nil) else { return [] }
            return (r["results"] as? [[String: Any]] ?? []).compactMap { $0["toObjectId"].map { "\($0)" } }
        }
        let contactIDs = await linked("contacts")
        if !contactIDs.isEmpty, let r = try? await request("POST", "/crm/v3/objects/contacts/batch/read", body: [
            "properties": ["firstname", "lastname", "email", "jobtitle"], "inputs": contactIDs.map { ["id": $0] }]) {
            for c in r["results"] as? [[String: Any]] ?? [] {
                let p = c["properties"] as? [String: Any] ?? [:]
                lines.append("  Contact: \(Self.text(p["firstname"])) \(Self.text(p["lastname"])) <\(Self.text(p["email"]))> \(Self.text(p["jobtitle"]))")
            }
        }
        let noteIDs = await linked("notes")
        if !noteIDs.isEmpty, let r = try? await request("POST", "/crm/v3/objects/notes/batch/read", body: [
            "properties": ["hs_note_body", "hs_timestamp"], "inputs": noteIDs.suffix(20).map { ["id": $0] }]) {
            let notes = (r["results"] as? [[String: Any]] ?? []).map { $0["properties"] as? [String: Any] ?? [:] }
                .sorted { Self.text($0["hs_timestamp"]) > Self.text($1["hs_timestamp"]) }.prefix(4)
            for n in notes { lines.append("  Note \(Self.text(n["hs_timestamp"]).prefix(10)): \(Self.text(n["hs_note_body"]).prefix(400))") }
        }
        let emailIDs = await linked("emails")
        if !emailIDs.isEmpty, let r = try? await request("POST", "/crm/v3/objects/emails/batch/read", body: [
            "properties": ["hs_email_subject", "hs_email_direction", "hs_email_text", "hs_timestamp"], "inputs": emailIDs.suffix(20).map { ["id": $0] }]) {
            let emails = (r["results"] as? [[String: Any]] ?? []).map { $0["properties"] as? [String: Any] ?? [:] }
                .sorted { Self.text($0["hs_timestamp"]) > Self.text($1["hs_timestamp"]) }.prefix(4)
            for e in emails {
                let dir = Self.text(e["hs_email_direction"]) == "INCOMING_EMAIL" ? "from them" : "from you"
                lines.append("  Email \(Self.text(e["hs_timestamp"]).prefix(10)) \(dir): “\(Self.text(e["hs_email_subject"]))” \(Self.text(e["hs_email_text"]).prefix(300))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Adds a note to a deal. Returns the new note's id.
    func logNote(dealID: String, body: String) async throws -> String {
        try await requireOwned(dealID)
        let safe = dealID.filter(\.isNumber)
        let json = try await request("POST", "/crm/v3/objects/notes", body: [
            "properties": ["hs_note_body": body, "hs_timestamp": "\(Int(Date.now.timeIntervalSince1970 * 1000))"],
            // 214 = note to deal (HubSpot-defined association).
            "associations": [["to": ["id": safe], "types": [["associationCategory": "HUBSPOT_DEFINED", "associationTypeId": 214]]]],
        ])
        return json["id"] as? String ?? ""
    }

    /// Changes a deal's stage, close date or amount. Returns what was there before (for the history).
    func updateDeal(_ dealID: String, properties: [String: String], checkOwner: Bool = true) async throws -> [String: String] {
        if checkOwner { try await requireOwned(dealID) }
        let safe = dealID.filter(\.isNumber)
        let before = try await request("GET", "/crm/v3/objects/deals/\(safe)?properties=\(properties.keys.joined(separator: ","))", body: nil)
        let old = (before["properties"] as? [String: Any] ?? [:]).reduce(into: [String: String]()) { out, kv in
            if properties[kv.key] != nil { out[kv.key] = Self.text(kv.value) }
        }
        _ = try await request("PATCH", "/crm/v3/objects/deals/\(safe)", body: ["properties": properties])
        return old
    }

    /// Deletes a task or note (used by Undo). HubSpot keeps it in its recycle bin for 90 days.
    func deleteObject(_ type: String, _ id: String) async throws {
        let safe = id.filter(\.isNumber)
        guard !safe.isEmpty, ["tasks", "notes"].contains(type) else { return }
        _ = try await request("DELETE", "/crm/v3/objects/\(type)/\(safe)", body: nil)
    }

    static let dealProperties = ["dealname", "amount", "dealstage", "closedate", "notes_last_updated", "hs_is_closed", "hubspot_owner_id"]

    static func dealLine(_ deal: [String: Any]) -> String {
        let p = deal["properties"] as? [String: Any] ?? [:]
        let id = deal["id"] as? String ?? ""
        let last = text(p["notes_last_updated"]).prefix(10)
        return "• id \(id) · \(text(p["dealname"])) · amount \(text(p["amount"]).isEmpty ? "–" : text(p["amount"])) · stage \(text(p["dealstage"])) · close \(text(p["closedate"]).prefix(10)) · last activity \(last.isEmpty ? "never" : String(last))"
    }

    static func text(_ any: Any?) -> String {
        (any as? String).map { $0.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }
}
