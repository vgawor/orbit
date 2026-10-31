// The add-on catalogue for the website (same as docs/ADDONS.md and the app's Settings → Add-ons).
// `built` are in the app today; `ideas` are on the roadmap.

window.ORBIT_ADDONS = [
  {
    id: 'productivity', title: 'Productivity', color: '#5C9EFF',
    icon: '<path d="M9 11l3 3 8-8"/><path d="M20 12v6a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h9"/>',
    blurb: 'Get more done without leaving what you\'re doing.',
    built: [
      ['Clipboard history', 'Free', 'The last 30 things you copied. Pin the ones you reuse. Skips passwords.'],
      ['Snippets', 'Free', 'Saved text you paste often: addresses, replies, signatures.'],
      ['World clock', 'Free', 'Your teammates\' time zones, with day, night and working hours.'],
      ['Day timeline', 'Pro', 'Today\'s calendar as a timeline with a "now" line and free gaps.'],
      ['Countdowns', 'Free', 'Days to launches, trips and deadlines.'],
    ],
    ideas: ['Quick capture to Reminders', 'Read later', 'Meeting notes', 'Mail unread', 'Focus mode switcher', 'Window layouts', 'Calculator & units', 'Daily journal', 'Weekly review', 'File search', 'Recent files', 'Text grab (OCR)', 'Mini kanban', 'Goals', 'Email templates'],
  },
  {
    id: 'health', title: 'Health', color: '#FF6B78',
    icon: '<path d="M20.8 5.6a5 5 0 0 0-7.1 0L12 7.3l-1.7-1.7a5 5 0 1 0-7.1 7.1L12 21.5l8.8-8.8a5 5 0 0 0 0-7.1z"/>',
    blurb: 'Small nudges to drink, breathe, rest your eyes and move.',
    built: [
      ['Water', 'Free', 'A daily goal, one-click glasses and gentle reminders.'],
      ['Eye & posture breaks', 'Free', '20-20-20 eye breaks and posture tips, skipped when you\'re away.'],
      ['Breathing', 'Free', 'Box and 4-7-8 breathing with an animated guide.'],
      ['Screen time', 'Pro', 'Time per app today. Idle time isn\'t counted.'],
      ['Mood check-in', 'Free', 'Mood and energy once a day, with a 14-day trend.'],
    ],
    ideas: ['Stretch routines', 'Stand reminders', 'Meditation timer', 'Calm sounds', 'Wind-down', 'Caffeine log', 'Medication reminders', 'Meal reminders', 'Noise level', 'Interval workout', 'Daylight', 'Wellbeing summary', 'Blink reminder', 'Steps from iPhone', 'Habits'],
  },
  {
    id: 'finance', title: 'Finance', color: '#34C759',
    icon: '<path d="M3 17l6-6 4 4 8-8"/><path d="M14 7h7v7"/>',
    blurb: 'Money at a glance: rates, budgets and subscriptions.',
    built: [
      ['Currency converter', 'Free', 'ECB rates. Works offline with the last rates.'],
      ['Market watchlist', 'Pro', 'Crypto and currency pairs with 24-hour change.'],
      ['Budget', 'Free', 'A monthly budget, quick-add expenses and category bars.'],
      ['Subscriptions', 'Free', 'What you pay for, your totals and renewal reminders.'],
      ['VAT & tax calculator', 'Free', 'Add or remove VAT, and see what to set aside for tax.'],
    ],
    ideas: ['Bills due', 'Split the bill', 'Hourly rate', 'Invoice due dates', 'Receipt inbox', 'Savings goals', 'Price alerts', 'Market hours', 'Net worth snapshot', 'Stripe revenue', 'HubSpot pipeline', 'Loan calculator', 'Salary after tax', 'Expense export', 'Exchange-rate history'],
  },
  {
    id: 'security', title: 'Security', color: '#FFB020',
    icon: '<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/><path d="M9 12l2 2 4-4"/>',
    blurb: 'Know what your Mac is doing, and keep it locked down.',
    built: [
      ['Password generator', 'Free', 'Strong passwords and passphrases. The clipboard clears after 60 seconds.'],
      ['Authenticator', 'Pro', '2FA codes, with the secrets kept in your Keychain.'],
      ['Network & VPN', 'Free', 'Your IP addresses, whether a VPN is on, and your public IP on request.'],
      ['Camera & mic indicator', 'Free', 'Know when anything uses your camera or mic, with a log.'],
      ['Security checkup', 'Pro', 'FileVault, firewall, SIP, Gatekeeper and updates at a glance.'],
    ],
    ideas: ['Breach check', 'Lock now', 'USB alerts', 'Wi-Fi trust', 'Secure notes', 'Certificate expiry', 'Open ports', 'Login items audit', 'App permissions', 'File hash', 'Shred from shelf', 'Link checker', 'Panic button', 'DNS status', 'SSH key check'],
  },
  {
    id: 'fun', title: 'Fun', color: '#F08DB3',
    icon: '<rect x="2" y="7" width="20" height="11" rx="5"/><path d="M7 11v3M5.5 12.5h3"/><circle cx="16" cy="11.5" r="1"/><circle cx="18" cy="13.5" r="1"/>',
    blurb: 'A little play in the notch.',
    built: [
      ['Decision maker', 'Free', 'Coin, dice and "pick one", with little animations.'],
      ['Star Catcher', 'Free', 'Catch stars, dodge meteors and beat your high score.'],
      ['On this day', 'Free', 'What happened on today\'s date, from Wikipedia.'],
      ['Weather', 'Free', 'An animated sky, now and for the next few hours.'],
      ['Fun fact', 'Free', 'A light-hearted fact a day.'],
    ],
    ideas: ['Daily word puzzle', 'Trivia', 'Soundboard', 'Space station', 'Moon phase', 'Pixel pet', 'Countdown to Friday', 'Confetti', 'Emoji kitchen', 'Team kudos', 'Music quiz', 'Doodle pad', 'Stickers', 'Typing race', 'Seasonal themes'],
  },
  {
    id: 'developers', title: 'Developers', color: '#D97757',
    icon: '<path d="M8 7l-5 5 5 5M16 7l5 5-5 5"/>',
    blurb: 'Builds, ports, containers and the tools you reach for every day.',
    built: [
      ['GitHub Actions', 'Pro', 'Your latest workflow runs, with an alert when one fails.'],
      ['Ports & processes', 'Free', 'What\'s listening on which port. Open it or stop it.'],
      ['Docker', 'Free', 'Your containers, with start, stop and restart.'],
      ['Dev toolbox', 'Free', 'JSON, Base64, URL, JWT, UUID and timestamps.'],
      ['Uptime monitor', 'Pro', 'Checks your sites and alerts you when one goes down.'],
    ],
    ideas: ['npm scripts', 'Git repo status', 'Xcode builds', 'Vercel deploys', 'Sentry issues', 'Localhost launcher', 'Colour picker', 'Regex tester', 'Cron explainer', 'HTTP request', 'Log tail', 'Homebrew updates', 'Env switcher', 'PR review queue', 'Linear / Jira issues'],
  },
  {
    id: 'ai', title: 'AI', color: '#A196FC',
    icon: '<path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z"/><path d="M19 15l.8 2.2L22 18l-2.2.8L19 21l-.8-2.2L16 18l2.2-.8z"/>',
    blurb: 'Claude in the notch: summarise, translate, rewrite and more.',
    built: [
      ['Prompt library', 'Free', 'Saved prompts with {{clipboard}}. Copy them or run them.'],
      ['Summarize', 'Pro', 'Clipboard or pasted text, turned into bullets.'],
      ['Translate', 'Pro', '14 languages, keeping your formatting.'],
      ['Rewrite', 'Pro', 'Clearer, shorter, friendlier, more formal, or just fixed.'],
      ['Action items', 'Pro', 'Notes or a transcript, turned into tasks with owners and dates.'],
    ],
    ideas: ['Email draft', 'Voice to task', 'Explain screenshot', 'Code explainer', 'Commit message', 'Research a company', 'Meeting recap', 'Smart replies', 'Agent templates', 'Claude usage', 'Local model', 'Alt text', 'Flashcards', 'Context packs', 'Daily plan'],
  },
];
