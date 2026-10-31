# Make an Orbit add-on

There are two ways to build for Orbit.

| | Script add-ons | Swift add-ons |
|---|---|---|
| Language | Anything: shell, Python, Node, Go… | Swift + SwiftUI |
| What you get | A Home widget, a tab, a peek chip and nudges | Full control of the notch panel, timers, system APIs |
| How it ships | Drop a folder in, share it on GitHub, list it in the gallery | A pull request to the open-source app |
| Good for | Status from an API, a command's output, a quick metric | Rich, interactive tools |

## Script add-ons (any language)

A script add-on is a folder in `~/Library/Application Support/Orbit/Widgets/` with two files (the folder and `widget.json` keep their original names):

```
Widgets/
  battery/
    widget.json
    run.sh        ← must be executable (chmod +x run.sh)
```

### widget.json

```json
{
  "id": "battery",
  "name": "Battery",
  "description": "Battery level and time left, in the peek.",
  "author": "Your name",
  "category": "productivity",
  "run": "run.sh",
  "args": [],
  "interval": 120,
  "symbol": "battery.75percent"
}
```

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Letters, numbers, `-`, `_`, `.` |
| `name` | yes | Shown in the gallery and the tab |
| `run` | yes | The script inside the folder |
| `description` | | One sentence for the gallery |
| `author` | | Shown as "by …" |
| `category` | | productivity, health, finance, security, fun, developers or ai |
| `args` | | Arguments passed to the script |
| `interval` | | Seconds between runs, at least 10, default 300 |
| `symbol` | | An SF Symbol name for the tab |

### What the script prints

The script prints one JSON object to standard output. Every field is optional:

```json
{
  "title": "Battery",
  "value": "84%",
  "subtitle": "discharging · 3:12 left",
  "symbol": "battery.75percent",
  "tint": "#34C759",
  "progress": 0.84,
  "items": [ { "title": "Something", "value": "12", "url": "https://…" } ],
  "url": "https://…",
  "chip": "84%",
  "attention": "Battery at 9%"
}
```

| Field | Shows up as |
|---|---|
| `title`, `value`, `subtitle` | The card: a big value with a line under it |
| `progress` (0–1) | A bar on the card |
| `items` | A list in the tab; each item can open a link |
| `url` | Clicking the card opens it |
| `chip` | A short line in the peek |
| `attention` | Orbit comes out of the notch to tell you; clear it by leaving it empty |
| `tint`, `symbol` | Colour and icon |

If the script prints other lines first (logging), Orbit uses the last line that is valid JSON.

### Rules Orbit enforces

- **Approval first.** A script add-on only runs after the person presses **Trust & run**, and again after
  the script changes (Orbit remembers a SHA-256 of it).
- **No shell.** The script runs directly, inside its own folder.
- **Time limit.** Each run has 20 seconds.
- **Your own keys.** If you need one, read it from an environment variable or a file in the
  add-on's folder. Never ship someone else's key.

### Try the examples

```bash
cp -R sdk/examples/battery ~/Library/Application\ Support/Viktor/Widgets/
```

Restart Orbit, open **Settings → Add-ons**, add **Battery**, open its tab and press **Trust & run**.

Examples in `sdk/examples/`:
- `battery`: shell, using `pmset`;
- `hacker-news`: Python with a public API and a list of links;
- `git-status`: shell, takes the repo path as an argument.

## Swift add-ons

Swift add-ons live in the app's source, `Viktor/Modules/AddOns/<Category>/`.

1. Make a class that conforms to `AddOnModule`:

```swift
@MainActor @Observable
final class HelloAddOn: AddOnModule {
    let id = "addon.hello"
    let title = "Hello"
    let symbol = "hand.wave.fill"
    let addOn = AddOnInfo(category: .fun, tier: .free, summary: "Says hello.", author: "Your name")

    var panel: AnyView { AnyView(VStack { AddOnHeader(symbol: symbol, title: title); Text("Hello!") }) }
    var homeCard: AnyView? { AnyView(Text("Hello").padding().glassCard(20)) }
    func start() {}   // timers and listeners go here
    func stop() {}
}
```

2. Return it from the category's `make(_:)`, for example `FunAddOns.make`.
3. Use the design pieces: `glassCard`, `glassSurface`, `PillButton` (the one main action),
   `GlassPillButton`, `AddOnHeader`, `NotchScroll`, `Tokens`.
4. Save data with `Storage.save(_:to:)`, secrets with `Secrets.set(_:for:)`, and nudge with
   `ctx.alerts.post(NotchAlert(...))`.
5. Add tests for your logic in `Tests/ViktorTests/`, then render your panel to a PNG:
   `VIKTOR_PREVIEW=1 .build/debug/Viktor --snapshot /tmp/shots` writes `addon-<id>.png`.
6. Open a pull request. See CONTRIBUTING.md and the checklist below.

## Review checklist (for both kinds)

- Does one thing well, in plain words.
- Works offline or fails politely.
- Asks before changing anything outside Orbit.
- No tracking, no ads, no selling data.
- Pro add-ons from the community: open an issue first about the revenue share.
