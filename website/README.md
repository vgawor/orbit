# Orbit website

The homepage for Orbit: the "playful" layout from the website design canvas, with animated
product scenes (inspired by how x.ai/bot shows its product working), built in the
Liquid Glass system from the app (black like the notch, glass panels and cards, SF Pro, the
app's signal colours, one white pill per section for the main action).

Plain HTML, CSS and a little JavaScript. No build step and no dependencies.

| File | What it is |
|---|---|
| `index.html` | The page |
| `assets/styles.css` | Design tokens (top of the file) and all styles |
| `assets/orbit.js` | `<orbit-character>`: the animated Orbit, same drawing, colours, moods and motions as the app |
| `assets/main.js` | The animated scenes (hero notch film, meetings, tasks, Smart Ask, shelf, focus, presenting, agents), the feature chips, the ticker |
| `assets/favicon.svg` | Orbit icon |

## Preview

```bash
cd website && python3 -m http.server 4321
```

Then open http://localhost:4321.

## Animated scenes

Each feature shows a short scene of the app at work. A scene plays only while it's on screen
and loops. With Reduce motion on, scenes don't play and each shows its finished state (the HTML
is written in that state). To add one: give the stage `data-demo="name"` in `index.html` and add
a `scene(stage, async ({ wait, type, point }) => { … })` in `main.js`.

## Orbit in the scenes

```html
<orbit-character size="96" color="Original" mood="happy" motion="celebrate"></orbit-character>
```

- `color`: White, Original, Ink, Bluey, Coral, Mint, Sunny
- `mood`: normal, wide, squint, grumpy, happy, closed, wink
- `motion`: idle, working, thinking, listening, nudge, celebrate, alert, sleep, glow, still
- `tint`: glow colour for nudge, glow and alert

Animations stop for visitors who turned on Reduce motion.

## Before publishing

Replace the placeholders:

- `[DOWNLOAD URL]`: the notarized DMG (final section)
- `[PRICE]`: the Pro price
- `[SUPPORT EMAIL]`: the support address
- `#privacy`, `#terms`: link to real pages

The page shows the command as `orbit`; the tool is still called `viktor` until the app is renamed.

## Publishing

Upload the folder to any static host (Netlify, Vercel, Cloudflare Pages or GitHub Pages).
