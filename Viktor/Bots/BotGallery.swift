import Foundation

/// Ready-made bots to add from Settings → Bots → Gallery. Each becomes your own bot that you can
/// change. Added bots start switched off.
enum BotGallery {
    struct Template: Identifiable {
        let id: String
        let name: String
        let color: String
        let summary: String
        /// Plain words for the gallery card: what it looks at and what it can change.
        let uses: String
        let job: String
        let kickoff: String
        let schedule: BotSchedule
        let tools: [String]
        let level: BotLevel
        var budgetCents = 100

        /// A new bot from this template, with its own id.
        func makeBot(id: String = BotGallery.newID()) -> Bot {
            Bot(id: id, name: name, color: color, summary: summary, job: job, kickoff: kickoff, schedule: schedule,
                model: BotProvider.claude.defaultModel, level: level, enabled: false, prepMeetings: false,
                budgetCents: budgetCents, tools: tools + OrbitTools.memoryNames)
        }
    }

    static let templates: [Template] = [inbox, talentScout, accountHealth, weeklyReview]

    static let inbox = Template(
        id: "inbox", name: "Inbox", color: "mint",
        summary: "Flags what needs you today and turns requests into tasks",
        uses: "Reads Apple Mail on this Mac · creates tasks and email drafts after you approve",
        job: """
        You are Inbox, one of {{fullName}}'s bots. {{intro}}

        Each run:
        - Call find_emails for the last day (unread first). Open the ones that look like they need {{name}} with read_email.
        - Ignore newsletters, receipts, notifications and anything that's only for information.
        - For a clear request or promise ("can you send…", "please confirm…", a deadline): create_task (target mac, or hubspot when it's about a customer) with a short title and the due date if one is given.
        - Only draft_email when a short reply is obviously right; otherwise leave it to {{name}}.
        - When an email is about a customer deal and Account Manager is on your team (list_teammates), hand_off the email to it with the sender, subject and what they asked, instead of handling it yourself.

        Finish with at most 3 bullet lines ("• "): the emails that need {{name}} today, most important first, each with sender and why.
        """,
        kickoff: "Go through my inbox.",
        schedule: BotSchedule(days: .weekdays, hour: 8, minute: 30),
        tools: ["get_overview", "find_emails", "read_email", "lookup_contacts", "create_task", "draft_email", "list_teammates", "hand_off"],
        level: .draft)

    static let talentScout = Template(
        id: "talent-scout", name: "Talent Scout", color: "coral",
        summary: "Finds people worth talking to for a role you describe",
        uses: "Searches the web · saves notes in Orbit after you approve",
        job: """
        You are Talent Scout, one of {{fullName}}'s bots. {{intro}}

        The role you're looking for (edit this): senior iOS developer, remote or near you.

        Each run:
        - Use web research to find up to 5 people who publicly fit the role (portfolios, talks, open-source work, company pages). Only use public, professional information.
        - Skip anyone you've already suggested (check recall_memory) and remember who you suggested.
        - add_note once with the list: name, where they work, why they fit, and a link.

        Finish with a short report: the 5 names, one line each.
        """,
        kickoff: "Find this week's candidates.",
        schedule: BotSchedule(days: .weekly, hour: 7, minute: 30, weekday: 2),
        tools: ["search_notes", Bot.webTool, "add_note"],
        level: .draft,
        budgetCents: 200)

    static let accountHealth = Template(
        id: "account-health", name: "Account Health", color: "original",
        summary: "A Friday look at which customers need attention",
        uses: "Reads HubSpot deals and contacts · changes nothing",
        job: """
        You are Account Health, one of {{fullName}}'s bots. {{intro}} Deals and customers are in HubSpot.

        Each run:
        - Call find_quiet_deals (14 days) and get_deal for the biggest ones (at most 5).
        - Judge which customers are at risk: no contact for a long time, a passed close date, unanswered questions, or a contact who went quiet.

        Write at most 6 bullet lines ("• "), most urgent first: customer, why it's at risk, and one concrete next step.
        """,
        kickoff: "How are my accounts doing?",
        schedule: BotSchedule(days: .weekly, hour: 15, minute: 0, weekday: 6),
        tools: ["get_overview", "lookup_contacts", "find_quiet_deals", "get_deal"],
        level: .read)

    static let weeklyReview = Template(
        id: "weekly-review", name: "Weekly Review", color: "ink",
        summary: "Friday afternoon: what's open and what's coming",
        uses: "Reads your day, tasks and notes · changes nothing",
        job: """
        You are Weekly Review, one of {{fullName}}'s bots. {{intro}}

        Each run:
        - Call get_overview and search_notes (recent notes).
        - Write a calm end-of-week review: what's still open and overdue, the first meetings next week and what to prepare, and anything in recent notes that looks unfinished.

        At most 6 bullet lines ("• "), then one short line to end the week.
        """,
        kickoff: "Write my weekly review.",
        schedule: BotSchedule(days: .weekly, hour: 16, minute: 0, weekday: 6),
        tools: ["get_overview", "search_notes"],
        level: .read,
        budgetCents: 50)

    /// A blank bot for "Start from scratch".
    static func blank() -> Bot {
        Bot(id: newID(), name: "New bot", color: "dot", summary: "", job: """
            You are one of {{fullName}}'s bots. {{intro}}

            Each run:
            - (What should it look at, and what should it do?)

            Finish with a short report: at most 5 bullet lines ("• ").
            """,
            kickoff: "Do your job for today.", schedule: BotSchedule(days: .weekdays, hour: 9, minute: 0),
            model: BotProvider.claude.defaultModel, level: .read, enabled: false, prepMeetings: false,
            budgetCents: 100, tools: ["get_overview"] + OrbitTools.memoryNames)
    }

    static func newID() -> String { "bot-" + UUID().uuidString.prefix(8).lowercased() }

    /// The tools you can pick for a bot, grouped like the editor shows them.
    static let toolGroups: [(title: String, tools: [(name: String, label: String)])] = [
        ("Your day", [("get_overview", "Meetings, tasks, focus and music"), ("get_meeting", "Meeting details and attendees"),
                      ("search_notes", "Your notes in Orbit")]),
        ("HubSpot", [("lookup_contacts", "Look people up"), ("find_quiet_deals", "Find quiet deals"),
                     ("find_recent_replies", "Customer replies"), ("get_deal", "Deal details")]),
        ("Mail", [("find_emails", "Find emails in Apple Mail"), ("read_email", "Read an email")]),
        ("Web", [(Bot.webTool, "Search and read web pages")]),
        ("Teamwork", [("list_teammates", "See your other bots"), ("hand_off", "Hand work to another bot (asks you first)")]),
        ("Changes (ask you first)", [("create_task", "Create tasks"), ("update_task", "Update tasks"), ("add_note", "Save notes in Orbit"),
                                     ("hubspot_log_note", "Log notes in HubSpot"), ("hubspot_update_deal", "Update deals"),
                                     ("draft_email", "Open email drafts")]),
    ]
}
