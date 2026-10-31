# Orbit

Your whole day, tucked in the MacBook notch: music, meetings, tasks, focus, files, your AI
agents and bots. Hover to peek, click to open, and Orbit nudges you when something needs you.

macOS 14 or later, with or without a notch. Liquid Glass on macOS 26.

**Download:** the latest signed build is on the [releases page](https://github.com/vgawor/orbit-releases/releases).
It updates itself.

## What's inside

- **Core:** Home dashboard, Music, Meetings with Join, Tasks (with HubSpot), Timers and Focus,
  Notes, Shelf (AirDrop, Convert), Capture, Draw, Mirror, Prompter, Mic safety, Presenting mode
  and Smart Ask.
- **Agents:** start Claude Code on a task and approve each step from the notch. Terminal sessions
  ask in the notch too.
- **Bots:** AI teammates on a schedule (Chief of Staff, Account Manager, Inbox, your own) that
  report back in the notch. Anything that changes something waits for your OK.
- **Add-ons:** 35 in seven categories. See [docs/ADDONS.md](docs/ADDONS.md).
- **Script add-ons:** write one as a small script in any language. See [docs/SDK.md](docs/SDK.md).

## Free and Pro

Orbit is free and open source. **Orbit Pro** ($12/month) is an optional account: bots run on
Orbit's AI keys instead of your own, you approve them from your phone, and you get the Pro
add-ons. Building from source gives you everything except the Orbit Pro service.

## Build

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
Security problems: see [SECURITY.md](SECURITY.md).

## Licence

Apache License 2.0 ([LICENSE](LICENSE)), except the Pro add-ons, which are under the Functional
Source License ([LICENSE-PRO.md](LICENSE-PRO.md)) and become Apache-2.0 after two years. The Orbit
name and icon are trademarks ([TRADEMARKS.md](TRADEMARKS.md)).
