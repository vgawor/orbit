<p align="center">
  <img src="docs/assets/readme/logo.png" width="128" alt="Orbit icon: a small coral planet with a face">
</p>

<h1 align="center">Orbit</h1>

<p align="center">
  Your whole day, tucked in the MacBook notch.<br>
  Music, meetings, tasks, focus, files, your AI agents and bots. Free and open source.
</p>

<p align="center">
  <a href="https://github.com/vgawor/orbit-releases/releases/latest"><strong>Download for Mac</strong></a> ·
  <a href="#what-it-does">Features</a> ·
  <a href="#agents-approve-from-the-notch">Agents</a> ·
  <a href="#bots-ai-teammates-that-ask-first">Bots</a> ·
  <a href="#private-by-default">Privacy</a> ·
  <a href="docs/ADDONS.md">Add-ons</a> ·
  <a href="#build-it-yourself">Build</a>
</p>

<p align="center">
  <a href="https://github.com/vgawor/orbit-releases/releases/latest"><img src="https://img.shields.io/github/v/release/vgawor/orbit-releases?label=release&color=ff7a59" alt="Latest release"></a>
  <a href="https://github.com/vgawor/orbit-releases/releases"><img src="https://img.shields.io/github/downloads/vgawor/orbit-releases/total?color=ff7a59" alt="Downloads"></a>
  <a href="#install"><img src="https://img.shields.io/badge/macOS-14%2B-black" alt="macOS 14 and newer"></a>
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="Apache 2.0 licence"></a>
  <a href="https://github.com/vgawor/orbit/stargazers"><img src="https://img.shields.io/github/stars/vgawor/orbit?style=flat&color=ffd33d" alt="GitHub stars"></a>
</p>

<p align="center">
  <img src="docs/assets/readme/orbit-hero.gif" width="800" alt="Orbit opening from the notch: a home dashboard with the next meeting, focus timer, music and a Claude Code approval">
</p>

Hover the notch to peek, click to open. Orbit shows what's next, plays your music, runs your
focus timer and holds your files, and it taps you on the shoulder when something needs you: a
meeting starting, an AI agent asking to run a command, a bot with a draft ready for your OK.

No notch? On an external display Orbit floats as a glass pill under the menu bar and works the
same way. Liquid Glass on macOS 26, frosted blur on macOS 14 and 15.

<p align="center">
  <img src="docs/assets/readme/home.png" width="49%" alt="Home: meetings left today, water, mood, screen time, currency, budget, watchlist and network cards">
  <img src="docs/assets/readme/addons.png" width="49%" alt="The add-on launcher with Productivity, Health, Finance, Security and Fun categories">
</p>

## Install

1. [Download the latest Orbit DMG](https://github.com/vgawor/orbit-releases/releases/latest) and
   drag Orbit to Applications.
2. Open it. macOS warns you once because Orbit isn't notarized by Apple: click **Done**.
3. Go to **System Settings → Privacy & Security** and click **Open Anyway**.

You only do this once. Orbit updates itself after that. Company-managed Macs may need IT to
allow it, or you can [build it yourself](#build-it-yourself).

## What it does

### Your day

- **Home.** A dashboard of cards: the next meeting with a Join button, free time, focus, music,
  tasks and any add-on you pick.
- **Meetings.** Your calendar with one-click Join for Zoom, Teams, Google Meet and Webex, and an alert in the
  notch two minutes before.
- **Music.** Spotify and Apple Music controls, with device switching for Spotify.
- **Tasks.** Local tasks, or HubSpot tasks with your own token. Type "Send offer to Northwind
  tomorrow 14:00" and Orbit fills in the form.
- **Timers and Focus.** Run several timers at once, or a 4 × 25 minute focus block with breaks.
- **Notes, Shelf and Capture.** Quick notes, a shelf to drop files on (AirDrop, convert), and
  screenshots or recordings of an area, window or screen.
- **Smart Ask.** Ask a question from anywhere and get the answer in the notch.
- **Mirror, Prompter, Draw, Mic safety and Presenting mode** for calls and talks.

<p align="center">
  <img src="docs/assets/readme/alert.png" width="700" alt="A meeting alert in the notch: Design review starts in 2 min, with Later and Join buttons">
</p>

### Agents: approve from the notch

Start Claude Code on a task and approve each step from the notch: every file edit and every
command waits for your **Allow**. If you don't answer, it isn't allowed. Claude Code sessions in
your own terminal ask in the notch too, so you never switch tabs to say yes.

<p align="center">
  <img src="docs/assets/readme/agents-approve.gif" width="800" alt="Claude Code asks in the notch to edit README.md, write CHANGELOG.md and run npm start; each is allowed with one click">
</p>

<p align="center">
  <img src="docs/assets/readme/agents.png" width="700" alt="The Agents tab: a finished agent run that fixed failing tests, with each edit and command marked Allowed">
</p>

### Bots: AI teammates that ask first

Bots run on a schedule and report back in the notch: **Chief of Staff** writes your morning
brief, **Account Manager** follows up on your HubSpot deals, **Inbox** sorts what came in, and
you can make your own. They hand work to each other, and anything that changes something waits
for your OK. After you've approved the same kind of action a few times, Orbit offers to trust it,
with Undo for 10 minutes. Bots only touch HubSpot deals you own.

<p align="center">
  <img src="docs/assets/readme/bots.png" width="700" alt="Account Manager needs your OK: a drafted pricing email with Open draft, Edit and Skip, and a HubSpot task it created with Undo">
</p>

### Add-ons

35 add-ons in seven categories (Productivity, Health, Finance, Security, Fun, Developers and AI),
from world clock and clipboard history to GitHub Actions, Docker, ports and uptime checks. They're
off until you turn them on. See the [full list](docs/ADDONS.md), or
[write your own](docs/SDK.md) as a small script in any language.

### Orbit itself

Orbit is a little planet with moods. It works, thinks, listens, celebrates and sleeps along with
you, in seven colours.

<p align="center">
  <img src="docs/assets/readme/moods.png" width="800" alt="Orbit's moods and colours: normal, happy, thinking, working, celebrate, sleep and more, in coral, mint, sunny, bluey, ink and white">
</p>

## Private by default

- **Everything stays on your Mac** except what you connect yourself: Smart Ask and bots talk to
  Claude or ChatGPT with your key, Tasks talks to HubSpot with your token, and Agents reads your
  GitHub reviews.
- **No account, no telemetry.** Orbit Pro is optional (see below).
- **Permissions only when needed:** Calendar for meetings, Screen Recording for capture, Camera
  for the mirror, Microphone for mic safety, each asked the first time you use the feature.

## Free and Pro

Orbit is free and open source, and bots work with your own API key at no cost.
**Orbit Pro** ($12/month) is an optional account: bots run on Orbit's AI keys so you don't need
an API account, you approve them from your phone, and you get the Pro add-ons. Pro requests go
through Orbit's server to the AI provider and aren't stored there.

## Build it yourself

You need Xcode 26 (or its command line tools) on macOS 14 or later.

```bash
swift build --product Viktor    # the app
swift test                      # all tests
scripts/install.sh              # build Orbit.app and put it in /Applications
```

More in [docs/DEVELOPING.md](docs/DEVELOPING.md): screen snapshots, signing and releases.
The app is called Orbit; the source still uses its first working name, Viktor, for folders,
types and the `viktor` command-line tool.

## Contributing

Bug reports, fixes and add-ons are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first.
Security problems: see [SECURITY.md](SECURITY.md). If Orbit is useful to you, a ⭐ helps other
people find it.

## Licence

Apache License 2.0 ([LICENSE](LICENSE)), except the Pro add-ons, which are under the Functional
Source License ([LICENSE-PRO.md](LICENSE-PRO.md)) and become Apache-2.0 after two years. The Orbit
name and icon are trademarks ([TRADEMARKS.md](TRADEMARKS.md)).
