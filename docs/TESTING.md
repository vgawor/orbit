# Testing Orbit

## Automatic (run any time)

```bash
scripts/smoke-test.sh
```

It runs three things:

1. **Unit tests** (`swift test`, 52 tests). They cover meeting links (Zoom, Teams, Meet, Webex), task dates and quick add, task groups and tick-for-the-day, HubSpot task reading, timers and focus sessions (single, automatic and manual cycles), Smart Ask date parsing, Spotify, YouTube and SSH parsing, the local API and Claude Code hooks, the hook installer, Dot nudges and the file converter.
2. **Screens.** Every notch screen is rendered to a PNG and checked. Text fields and menus show as yellow boxes in these pictures. That's a limit of the renderer, not a bug.
3. **CLI and the running app.** It checks `status`, `send`, `ls`, `rm`, `run`, `ask` and the Claude hooks against the installed app. It also checks that a wrong token is refused.

None of this touches your real tasks, HubSpot, Keychain or `~/.claude/settings.json`.

## By hand (needs permissions, hardware or your accounts)

Tick these off once. Repeat a row only when that feature changes.

| ✓ | Feature | How to test | Expected |
|---|---|---|---|
| ☐ | Notch hover and click | Hover the notch, then click it | The peek opens, then the panel opens. Clicking outside closes it. |
| ☐ | Peek and open linger | Change both in Settings → General | The panel stays open as long as set. |
| ☐ | Dot nudge | Have an overdue task or a meeting within 5 min | Dot comes out of the closed notch. It stops after you peek. |
| ☐ | Music | Play Spotify, then use play/pause, skip, shuffle, volume and seek | The notch follows along and the controls work. |
| ☐ | Meeting join (Zoom) | Calendar event with a Zoom link, 3 min ahead | An alert appears. Join opens the Zoom app. |
| ☐ | Meeting join (Teams) | Same with a Teams link | Join opens Teams. |
| ☐ | Meeting prep | Click Prep on the next meeting (needs the Claude key) | A short brief with HubSpot info on the attendees. |
| ☐ | Morning brief | Home → Today card with the Claude key added | A few lines about your day. |
| ☐ | Smart Ask | Click Dot and ask "add a task to call Anna tomorrow 10" | It asks for confirmation, then the task appears. |
| ☐ | HubSpot tasks | Tick a HubSpot task | It's marked done in HubSpot and stays ticked in Orbit until tomorrow. |
| ☐ | HubSpot create | Tasks → + → HubSpot form, with a project and a contact | The task exists in HubSpot with the right project and contact. |
| ☐ | Timers | Start 5 min, 15 min and a custom timer together | All three count down. Each one alerts when it's done. |
| ☐ | Focus playlist | Set a Spotify playlist, start focus, wait for a break | It plays during focus and pauses on breaks. |
| ☐ | Shelf | Drag a file onto the notch, then drag it back out | The file is kept and can be dragged into Finder or Mail. |
| ☐ | AirDrop and convert | Shelf → AirDrop, then Convert to JPEG | The AirDrop sheet opens and a JPEG appears next to the file. |
| ☐ | YouTube | Drag a YouTube link onto the notch | The video plays in the notch. |
| ☐ | Scrolling capture | Capture → scrolling screenshot (needs Screen Recording) | One long image. |
| ☐ | Draw | ⌃⌥D, draw, Esc | You can draw on the screen and Esc clears it. |
| ☐ | Mic safety | Join a call with the mic on | The mic indicator shows in the notch. |
| ☐ | Mirror | Open Mirror | Camera preview (asks for camera access the first time). |
| ☐ | Prompter | Paste text and start | The text scrolls under the notch at a readable width. |
| ☐ | Presenting mode | Click the eye icon, then share your screen | Notch content and pop-ups stay hidden. |
| ☐ | Hotkeys | ⌥Space, ⌥K, ⌥P, ⌥M | Open/close, Ask, Presenting and Mic all respond. |
| ☐ | Launch at login | Turn it on in Settings, then restart the Mac | Orbit starts by itself. |
| ☐ | Agent task | Agents → New agent task, pick a project folder, "add a README line saying hello" | A coloured Orbit starts working; the chat shows what Claude does. |
| ☐ | Agent approval | Same task, when Claude wants to edit a file | "Allow? Editing README.md" pops up in the notch and in the chat. Allow continues, Deny stops that step. |
| ☐ | Agent follow-up | After it's done, type "now undo that" in the chat | The same session continues. |
| ☐ | Agent stop | Start a long task, click Stop | It stops; anything waiting for your OK is denied. |
| ☐ | Orbit chat in Agents | Agents → Orbit, ask "what's my day?" | Same conversation as the Ask tab. |
| ☐ | Terminal approval | Turn the Claude Code hooks off and on in Settings → Developer, start `claude` in a terminal, ask it to edit a file | "Allow?" pops up in the notch. Allow or Deny answers it; "In terminal" (or 2 min without an answer) shows the normal question in the terminal. |
| ☐ | Floating pill | On an external display (no notch), hover the top centre | A glass pill floats just below the menu bar and opens into the panel. |
| ☐ | GitHub reviews | Add a GitHub token and have a PR waiting for your review | The PR shows under Agents. |
| ☐ | Bots: Chief of Staff | Settings → Bots, turn it on, Run now | A briefing shows in the notch within a minute or two. |
| ☐ | Bots: approvals | Account Manager, Run now | "Needs your OK" cards in the notch; Send, Edit and Skip all work; the report shows green and amber steps. |
| ☐ | Bots: memory and trust | Settings → Bots → Memory; turn on "Create tasks" under Does on its own | Notes can be edited; a trusted change shows in the notch with Undo. |
| ☐ | Bots: gallery and Inbox | Add a bot → Inbox, Run now | macOS asks to control Mail; proposals arrive as approvals. |
| ☐ | Bots: ChatGPT | Add an OpenAI key, set a bot to ChatGPT, Run now | Same as with Claude; the cost is shown as an estimate. |
| ☐ | Bots: hand-off | Inbox and Account Manager on, an email about a deal | "Hand to Account Manager" asks first; the Team view shows the hand-off. |
| ☐ | Orbit account | Settings → Accounts → Send sign-in email, click Log In on the Mac | Orbit opens signed in and shows your plan. |
| ☐ | Orbit Pro (sandbox) | Upgrade with Paddle's test card | Plan shows Orbit Pro within a minute; bots move to Orbit's keys. |
| ☐ | Phone approvals | Phone web app on the Home Screen, notifications on | A bot request arrives as a notification; answering it on the phone carries it out on the Mac. |
| ☐ | About you | Settings → General → About you | Bots and Smart Ask use your name and company, not anyone else's. |
| ☐ | Overdue snooze | Snooze an overdue task | It leaves "overdue" in the peek and moves to Snoozed at the bottom of Tasks. |
| ☐ | Status menu | Click the status next to Orbit | Lists what needs you and what's running; picking one opens it. |
| ☐ | Meetings in the peek | Hover a meeting → eye; a multi-day event | Hidden meetings and long events don't count down in the peek; the list shows "in 2 h" or "now · 35 min left". |
| ☐ | Tab order | Right-click a tab → Move left / Move right | The tab moves and stays there after a restart. |
| ☐ | Home dashboard | Edit Home: drag, resize, remove, Add widget, Reset layout | Nothing overlaps after you let go; gaps close; the layout is kept after a restart. |
| ☐ | Pro add-ons (launch build) | Set OrbitProRequired to true, Free account | Pro add-ons show Upgrade to Pro; with Orbit Pro they unlock. |

