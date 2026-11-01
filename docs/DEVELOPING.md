# Developing Orbit

## Build and test

```bash
swift build --product Orbit      # the app
swift test                        # all tests
scripts/smoke-test.sh             # tests + every screen rendered + CLI checks
scripts/install.sh                # signed build into /Applications
```

`install.sh` signs with your Apple Development certificate if you have one (so macOS remembers
permissions across rebuilds), otherwise ad hoc.

## See every screen without permissions

```bash
ORBIT_PREVIEW=1 .build/debug/Orbit --snapshot /tmp/shots
```

This renders every screen and add-on to PNGs with sample data. Add `--orbit-film` to render
Orbit's animation as frame strips instead.

## Releases (maintainers)

```bash
scripts/release.sh 0.3.0                 # build the DMG and the update-feed entry only
scripts/release.sh 0.3.0 --publish       # ...and publish them
```

Releases are signed with your Apple Development certificate and aren't notarized, so people open
Orbit the first time via Privacy & Security → Open Anyway. If a Developer ID certificate is ever in
the Keychain, `release.sh` signs with it and notarizes automatically. Updates use Sparkle; the feed lives in the `orbit-releases` repository. The DMG opens as
a designed Finder window drawn by `scripts/make-dmg-background.swift`.

`scripts/publish-phone-app.sh` publishes the phone web app (`web/app`) to GitHub Pages.

## Layout

| Folder | What's in it |
|---|---|
| `Orbit/` | The app (SwiftUI). Each feature is a `NotchModule`, registered in `ModuleRegistry` |
| `Orbit/Bots/` | Bots: Claude Managed Agents or ChatGPT, approvals, memory |
| `OrbitKit/` | Shared code for the app and the `orbit` command-line tool |
| `OrbitCLI/` | The `orbit` tool |
| `server/` | Orbit Pro: Supabase migrations and edge functions |
| `web/app/` | The phone web app for approvals |
| `website/` | The website (static, no build step) |
| `sdk/` | Script add-on examples |
