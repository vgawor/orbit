# Contributing to Orbit

Thanks for helping. Bug reports, fixes, new add-ons and better wording are all welcome.

## Before you start

- **Bugs:** open an issue with your macOS version, Mac model (notch or not) and the steps to make
  it happen.
- **Bigger changes and new features:** open an issue first, so we can agree on the idea before
  you spend time on it.
- **Add-ons:** script add-ons can live in your own repository; see [docs/SDK.md](docs/SDK.md).
  Swift add-ons go in `Viktor/Modules/AddOns/<Category>/`.

## Making a change

1. Fork the repository and make a branch.
2. Build and test: `swift build --product Viktor` and `swift test`.
   `scripts/smoke-test.sh` also renders every screen, which catches layout problems.
3. Keep the style of the code around you. Comments and interface text are short, plain English.
4. Open a pull request saying what changed and why. Add a screenshot for anything visible.

## Ground rules

- **Privacy first.** No tracking, analytics or ads. Nothing leaves the Mac unless the user turned
  on the feature that needs it.
- **Ask before changing things.** Anything that sends, deletes or changes the user's data needs
  their OK first.
- **No secrets in the code.** Keys and tokens belong in the Keychain.

## Contributor licence agreement

Before your first pull request is merged, you'll be asked to agree to a short contributor
licence agreement. You keep the copyright to your work; the agreement lets Orbit include it in
both the open-source app and Orbit Pro.

## Code of conduct

Be kind and constructive. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
