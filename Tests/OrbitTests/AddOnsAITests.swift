import Foundation
import Testing
@testable import Orbit

@Suite("AI add-ons")
@MainActor struct AddOnsAITests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    // MARK: Placeholders

    @Test func fillsPlaceholders() {
        let out = AILogic.fillPlaceholders("Today is {{date}}.\n\n{{ Clipboard }} / {{clipboard}}",
                                           clipboard: "hello", date: day(2026, 10, 28), calendar: utc)
        #expect(out == "Today is 2026-10-28.\n\nhello / hello")
    }

    @Test func clipboardWithTemplateCharactersIsInsertedLiterally() {
        let out = AILogic.fillPlaceholders("x {{clipboard}} y", clipboard: "$1 \\n costs $5", date: .now)
        #expect(out == "x $1 \\n costs $5 y")
    }

    @Test func leavesUnknownPlaceholdersAndFindsUsedOnes() {
        let text = "{{name}} and {{clipboard}} on {{DATE}}"
        #expect(AILogic.fillPlaceholders(text, clipboard: "c", date: day(2026, 1, 2), calendar: utc) == "{{name}} and c on 2026-01-02")
        #expect(AILogic.placeholders(in: text) == ["name", "clipboard", "date"])
    }

    @Test func startersUsePlaceholders() {
        #expect(PromptLibraryAddOn.starters.count == 5)
        #expect(PromptLibraryAddOn.starters.allSatisfy { AILogic.placeholders(in: $0.text).contains("clipboard") })
    }

    // MARK: Prompt building

    @Test func summarizeMessageFollowsLength() {
        #expect(AILogic.summarizeMessage("abc", length: .bullets).contains("3 bullet points"))
        #expect(AILogic.summarizeMessage("abc", length: .short).contains("one short paragraph"))
        #expect(AILogic.summarizeMessage("abc", length: .detailed).contains("<text>\nabc\n</text>"))
        #expect(AILogic.summarizeSystem.contains("exactly as written"))
    }

    @Test func rewriteMessagePerTone() {
        for tone in AILogic.Tone.allCases {
            let message = AILogic.rewriteMessage("hi", tone: tone)
            #expect(message.hasPrefix(tone.instruction))
            #expect(message.hasSuffix("<text>\nhi\n</text>"))
        }
        #expect(Set(AILogic.Tone.allCases.map(\.instruction)).count == AILogic.Tone.allCases.count)
    }

    @Test func translateMessageNamesLanguage() {
        #expect(AILogic.languages.count == 14)
        #expect(AILogic.translateMessage("Hej", to: "German").hasPrefix("Translate into German."))
    }

    // MARK: Translation parsing

    @Test func parsesTranslationWithSource() {
        let parsed = AILogic.parseTranslation("SOURCE: Swedish\n---\nHi Anna!\n\n- one\n- two")
        #expect(parsed.source == "Swedish")
        #expect(parsed.text == "Hi Anna!\n\n- one\n- two")
    }

    @Test func parsesTranslationWithoutSeparatorOrSource() {
        let a = AILogic.parseTranslation("Source: French\n\nBonjour")
        #expect(a.source == "French")
        #expect(a.text == "Bonjour")
        let b = AILogic.parseTranslation("Just the text")
        #expect(b.source == nil)
        #expect(b.text == "Just the text")
    }

    @Test func mapsDetectedLanguage() {
        #expect(AILogic.knownLanguage("swedish") == "Swedish")
        #expect(AILogic.knownLanguage("Norwegian (Bokmål)") == "Norwegian")
        #expect(AILogic.knownLanguage("Klingon") == nil)
        #expect(AILogic.knownLanguage(nil) == nil)
    }

    // MARK: Action items

    @Test func parsesPlainJSON() throws {
        let raw = #"[{"title": "Send offer", "owner": "Sam", "due": "2026-11-03"}, {"title": "Book room", "owner": null, "due": null}]"#
        let items = try #require(AILogic.parseActionItems(raw))
        #expect(items.count == 2)
        #expect(items[0] == .init(title: "Send offer", owner: "Sam", due: "2026-11-03"))
        #expect(items[1].owner == nil && items[1].due == nil)
    }

    @Test func parsesFencedJSONAndSurroundingText() throws {
        let fenced = "```json\n[{\"title\": \"Call Anna\", \"owner\": \"\", \"due\": \"2026-11-03T10:00:00\"}]\n```"
        let a = try #require(AILogic.parseActionItems(fenced))
        #expect(a == [.init(title: "Call Anna", owner: nil, due: "2026-11-03")])

        let chatty = "Here you go:\n[{\"title\": \"Ship it\"}]\nLet me know!"
        #expect(AILogic.parseActionItems(chatty)?.map(\.title) == ["Ship it"])

        let wrapped = #"{"items": [{"task": "Wrapped", "assignee": "Bo", "due": "soon"}]}"#
        #expect(AILogic.parseActionItems(wrapped) == [.init(title: "Wrapped", owner: "Bo", due: nil)])
    }

    @Test func emptyAndBadJSON() {
        #expect(AILogic.parseActionItems("[]") == [])
        #expect(AILogic.parseActionItems("I couldn't find any.") == nil)
        #expect(AILogic.parseActionItems("[{\"title\": \"broken\"") == nil)
        #expect(AILogic.parseActionItems(#"[{"owner": "no title"}, {"title": "  "}, {"title": "ok"}]"#)?.map(\.title) == ["ok"])
    }

    @Test func parsesDays() throws {
        let d = try #require(AILogic.parseDay("2026-11-03", calendar: utc))
        #expect(utc.dateComponents([.year, .month, .day, .hour], from: d) == DateComponents(year: 2026, month: 11, day: 3, hour: 0))
        #expect(AILogic.parseDay("2026-02-30", calendar: utc) == nil)
        #expect(AILogic.parseDay("2026-13-01", calendar: utc) == nil)
        #expect(AILogic.parseDay("next friday", calendar: utc) == nil)
        #expect(AILogic.parseDay("03/11/2026", calendar: utc) == nil)
    }

    @Test func listsItemsAsText() {
        let list = AILogic.actionItemsList([
            .init(title: "Send offer", owner: "Sam", due: "2026-11-03"),
            .init(title: "Book room"),
        ])
        #expect(list == "- Send offer (Sam, due 2026-11-03)\n- Book room")
    }

    @Test func actionItemsPromptHasTodayAndAsksForJSON() {
        let system = AILogic.actionItemsSystem(today: day(2026, 10, 28), calendar: utc)
        #expect(system.contains("Today is 2026-10-28"))
        #expect(system.contains("JSON only"))
    }

    @Test func stripsCodeFences() {
        #expect(AILogic.stripCodeFences("```\nabc\n```") == "abc")
        #expect(AILogic.stripCodeFences("```json\n[1]\n```  ") == "[1]")
        #expect(AILogic.stripCodeFences("plain") == "plain")
    }

    // MARK: Home cards

    @Test func previewLineSkipsMarkersAndBlankLines() {
        #expect(AILogic.previewLine("\n\n- **Revenue** up 12%\n- Two new deals") == "Revenue up 12%")
        #expect(AILogic.previewLine("1. First step\n2. Second") == "First step")
        #expect(AILogic.previewLine("## Summary\nText") == "Summary")
        #expect(AILogic.previewLine("  \n---\n• Bullet") == "Bullet")
        #expect(AILogic.previewLine("   \n- \n") == nil)
        let long = String(repeating: "word ", count: 40)
        let cut = AILogic.previewLine(long, limit: 20)
        #expect((cut?.count ?? 99) <= 20)
        #expect(cut?.hasSuffix("…") == true)
    }

    @Test func homeLineFollowsThePhase() {
        #expect(AIRequest.Phase.idle.homeLine(idle: "Copy text") == "Copy text")
        #expect(AIRequest.Phase.working.homeLine(idle: "x") == "Working on it…")
        #expect(AIRequest.Phase.done("- Hi Anna!\n- More").homeLine(idle: "x") == "Hi Anna!")
        #expect(AIRequest.Phase.done("  ").homeLine(idle: "x") == "x")
        #expect(AIRequest.Phase.failed("boom").homeLine(idle: "x").contains("try again"))
    }

    @Test func clipboardTitle() {
        #expect(aiClipboardTitle("English") == "Clipboard → English")
    }

    @Test func everyAIAddOnHasAHomeCard() {
        let ctx = AddOnContext(alerts: AlertCenter(), openPanel: { _ in }, closePanel: {})
        let modules = AIAddOns.make(ctx).compactMap { $0 as? any AddOnModule }
        #expect(modules.allSatisfy { $0.homeCard != nil })
    }

    @Test func addingToTasksCheersOncePerClick() {
        var added: [String] = []
        var ctx = AddOnContext(alerts: AlertCenter(), openPanel: { _ in }, closePanel: {})
        ctx.addTask = { title, _ in added.append(title) }
        let module = ActionItemsAddOn(ctx)
        module.show([.init(title: "Send offer", owner: "Sam", due: nil), .init(title: "Book room"), .init(title: "Call Anna")])
        #expect(module.celebrations == 0)

        module.addToTasks(module.items[0])
        #expect(module.celebrations == 1)
        module.addToTasks(module.items[0])          // already added: no task, no cheer
        #expect(module.celebrations == 1)

        module.addChecked()                         // two new ones in one click: one cheer
        #expect(module.celebrations == 2)
        #expect(added == ["Send offer (Sam)", "Book room", "Call Anna"])
        module.addChecked()                         // nothing new
        #expect(module.celebrations == 2)
        #expect(module.homeLine == "3 found, all in Tasks")
    }

    // MARK: Modules

    @Test func makesFiveAddOns() {
        let ctx = AddOnContext(alerts: AlertCenter(), openPanel: { _ in }, closePanel: {})
        let modules = AIAddOns.make(ctx).compactMap { $0 as? any AddOnModule }
        #expect(modules.map(\.id) == ["addon.prompts", "addon.summarize", "addon.translate", "addon.rewrite", "addon.actionitems"])
        #expect(modules.allSatisfy { $0.addOn.category == .ai })
        #expect(modules.map(\.addOn.tier) == [.free, .pro, .pro, .pro, .pro])
    }
}
