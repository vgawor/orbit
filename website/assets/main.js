// Page behaviour: the ticker, the hero notch film, the feature scenes, the feature tabs,
// and sections fading in. Scenes only play while they're on screen; with Reduce motion on,
// everything stays on its finished state (which is what the HTML shows).

const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const $ = (root, sel) => root.querySelector(sel);

// ---------- Ticker ----------
const words = ['Music', 'Meetings', 'Tasks', 'HubSpot', 'Focus', 'Timers', 'Notes', 'Shelf', 'AirDrop', 'Convert', 'Smart Ask', 'Agents'];
const dotColors = ['#FBAE72', '#F08DB3', '#A196FC', '#5C9EFF', '#6FE3B0', '#FFD34D'];
const track = document.getElementById('marquee');
if (track) {
  const one = words.map((w, i) => `<span>${w}<i style="background:${dotColors[i % dotColors.length]}"></i></span>`).join('');
  track.innerHTML = one + one;
}

// ---------- Scene runner ----------
// Plays `run` in a loop while `el` is visible. `run` gets helpers that stop as soon as it scrolls away.
function scene(el, run) {
  if (!el || reduce) return;
  let token = 0;
  let visible = false;
  const start = async () => {
    const mine = ++token;
    const alive = () => visible && mine === token;
    const wait = async (ms) => { await sleep(ms); if (!alive()) throw new Error('stopped'); };
    const type = async (node, text, speed = 45) => {
      node.textContent = '';
      for (const ch of text) { node.textContent += ch; await wait(speed); }
    };
    const point = async (cursor, target, box, press = true) => {
      const b = box.getBoundingClientRect(), t = target.getBoundingClientRect();
      cursor.style.left = `${t.left - b.left + t.width * 0.5}px`;
      cursor.style.top = `${t.top - b.top + t.height * 0.55}px`;
      await wait(950);
      if (press) {
        cursor.classList.add('press'); target.classList.add('press');
        await wait(160);
        cursor.classList.remove('press'); target.classList.remove('press');
      }
    };
    try { while (alive()) await run({ wait, type, point }); } catch { /* scrolled away */ }
  };
  new IntersectionObserver(([e]) => {
    const was = visible;
    visible = e.isIntersecting;
    if (visible && !was) start();
    if (!visible) token++;
  }, { threshold: 0.35 }).observe(el);
}

// ---------- Hero: hover → peek → open → nudge ----------
const film = document.getElementById('film');
const steps = [...document.querySelectorAll('.film-steps [data-step]')];
let pausedUntil = 0;
function setFilm(state) {
  if (!film) return;
  film.dataset.state = state;
  steps.forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.step === state)));
}
steps.forEach((b) => b.addEventListener('click', () => { pausedUntil = Date.now() + 9000; setFilm(b.dataset.step); }));
if (film && !reduce) {
  const cursor = $(film, '.cursor');
  const notch = $(film, '.notch');
  scene(film, async ({ wait, point }) => {
    if (Date.now() < pausedUntil) { await wait(500); return; }
    setFilm('closed');
    cursor.style.left = '72%'; cursor.style.top = '70%';
    await wait(900);
    await point(cursor, notch, film, false);       // hover the notch
    setFilm('peek');
    await wait(2300);
    cursor.classList.add('press'); await wait(160); cursor.classList.remove('press');
    setFilm('open');                                // click to open
    cursor.style.left = '86%'; cursor.style.top = '82%';
    await wait(4200);
    setFilm('closed');
    await wait(1400);
    setFilm('nudge');                               // a meeting is about to start
    await wait(3600);
  });
}

// ---------- Meetings: the alert drops, you click Join ----------
document.querySelectorAll('[data-demo="meeting"]').forEach((stage) => {
  const alert = $(stage, '.d-alert'), join = $(stage, '[data-join]'), cursor = $(stage, '.cursor');
  const title = $(stage, '[data-title]'), sub = $(stage, '[data-sub]');
  scene(stage, async ({ wait, point }) => {
    alert.classList.add('hidden');
    title.textContent = 'Weekly sync starts in 2 min'; sub.textContent = 'Zoom · 4 people'; join.textContent = 'Join';
    cursor.style.left = '30%'; cursor.style.top = '85%';
    await wait(900);
    alert.classList.remove('hidden');
    await wait(1400);
    await point(cursor, join, stage);
    title.textContent = 'Opening Zoom…'; sub.textContent = 'Weekly sync'; join.textContent = '✓';
    await wait(1800);
    alert.classList.add('hidden');
    await wait(900);
  });
});

// ---------- Tasks: type it, it appears, tick one off ----------
document.querySelectorAll('[data-demo="tasks"]').forEach((stage) => {
  const typed = $(stage, '[data-typed]'), row = $(stage, '[data-new]'), tick = $(stage, '[data-tick]');
  scene(stage, async ({ wait, type }) => {
    row.classList.add('collapsed'); tick.classList.remove('done'); typed.textContent = '';
    await wait(700);
    await type(typed, 'Call Anna tomorrow 10', 55);
    await wait(500);
    typed.textContent = '';
    row.classList.remove('collapsed');
    await wait(1300);
    tick.classList.add('done');
    await wait(2600);
  });
});

// ---------- Ask: a sentence in, a confirmed change out ----------
document.querySelectorAll('[data-demo="ask"]').forEach((stage) => {
  const typed = $(stage, '[data-typed]'), reply = $(stage, '[data-reply]'), card = $(stage, '.d-card');
  const ok = $(stage, '[data-ok]'), done = $(stage, '[data-done]'), orbit = $(stage, '[data-orbit]');
  scene(stage, async ({ wait, type }) => {
    reply.classList.add('is-hidden'); done.classList.add('is-hidden'); typed.textContent = '';
    orbit.setAttribute('motion', 'thinking');
    await wait(600);
    await type(typed, 'Move the offer to Monday 9', 50);
    await wait(400);
    card.classList.add('is-thinking'); reply.classList.remove('is-hidden');
    await wait(1700);
    card.classList.remove('is-thinking'); orbit.setAttribute('motion', 'idle');
    await wait(1300);
    ok.classList.add('press'); await wait(160); ok.classList.remove('press');
    done.classList.remove('is-hidden'); orbit.setAttribute('mood', 'happy');
    await wait(2600);
    orbit.setAttribute('mood', 'normal');
  });
});

// ---------- Shelf: a file is dragged up, dropped, converted ----------
document.querySelectorAll('[data-demo="shelf"]').forEach((stage) => {
  const file = $(stage, '[data-file]'), drop = $(stage, '.d-drop'), shelf = $(stage, '.d-shelf');
  const zone = $(stage, '[data-zone]'), name = $(stage, '[data-name]'), convert = $(stage, '[data-convert]');
  scene(stage, async ({ wait }) => {
    drop.classList.add('hidden'); shelf.classList.add('hidden'); zone.classList.remove('target');
    file.style.opacity = '1'; file.style.left = '40%'; file.style.bottom = '16px'; file.style.transform = 'rotate(-8deg)';
    name.textContent = 'beach.heic'; convert.textContent = 'Convert to JPEG';
    await wait(800);
    file.style.left = '22%'; file.style.bottom = '150px'; file.style.transform = 'rotate(4deg) scale(.9)';
    await wait(400);
    drop.classList.remove('hidden');
    await wait(700);
    zone.classList.add('target');
    await wait(700);
    file.style.opacity = '0';
    drop.classList.add('hidden');
    await wait(350);
    shelf.classList.remove('hidden');
    await wait(1300);
    convert.classList.add('press'); await wait(160); convert.classList.remove('press');
    name.textContent = 'beach.jpg'; convert.textContent = 'Converted ✓';
    await wait(2400);
  });
});

// ---------- Focus: the clock runs, music pauses on the break ----------
document.querySelectorAll('[data-demo="focus"]').forEach((stage) => {
  const clock = $(stage, '[data-clock]'), progress = $(stage, '[data-progress]'), tea = $(stage, '[data-tea]');
  const music = $(stage, '[data-music]'), row = $(stage, '.music');
  const fmt = (s) => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
  scene(stage, async ({ wait }) => {
    let left = 12, teaLeft = 190;
    row.classList.remove('paused'); music.textContent = 'Playing'; clock.parentElement.querySelector('small').textContent = 'Focus · round 2 of 4';
    while (left > 0) {
      clock.textContent = fmt(left); tea.textContent = fmt(teaLeft);
      progress.style.width = `${100 - (left / 12) * 70}%`;
      await wait(450);
      left -= 1; teaLeft -= 1;
    }
    clock.textContent = '0:00';
    clock.parentElement.querySelector('small').textContent = 'Break · 5 min';
    row.classList.add('paused'); music.textContent = 'Paused for your break';
    await wait(2600);
  });
});

// ---------- Presenting: ⌥P hides what's private ----------
document.querySelectorAll('[data-demo="present"]').forEach((stage) => {
  const left = $(stage, '[data-left]'), right = $(stage, '[data-right]'), keys = stage.querySelectorAll('kbd');
  scene(stage, async ({ wait }) => {
    left.textContent = 'Send the offer · overdue'; right.textContent = '12m';
    await wait(1800);
    keys.forEach((k) => k.classList.add('down'));
    await wait(220);
    keys.forEach((k) => k.classList.remove('down'));
    left.style.opacity = '0'; right.style.opacity = '0';
    await wait(300);
    left.textContent = 'Presenting'; right.textContent = '';
    left.style.opacity = '1';
    await wait(2600);
    keys.forEach((k) => k.classList.add('down'));
    await wait(220);
    keys.forEach((k) => k.classList.remove('down'));
    left.style.opacity = '0';
    await wait(300);
    left.style.opacity = '1'; right.style.opacity = '1';
  });
});

// ---------- Agent: steps stream in, you allow the test run ----------
document.querySelectorAll('[data-demo="agent"]').forEach((win) => {
  const stepsBox = $(win, '[data-steps]'), allow = $(win, '[data-allow]'), allowBtn = $(win, '[data-allow-btn]');
  const result = $(win, '[data-result]'), state = $(win, '[data-state]'), orbit = $(win, '[data-orbit]'), cursor = $(win, '.cursor');
  const lines = ['Reading checkout.test.ts', 'Reading src/lib/price.ts', 'Editing price.ts'];
  scene(win, async ({ wait, point }) => {
    stepsBox.innerHTML = ''; allow.classList.add('is-hidden'); result.classList.add('is-hidden');
    state.textContent = 'Working'; state.style.color = 'var(--live)';
    orbit.setAttribute('motion', 'working'); orbit.setAttribute('mood', 'normal');
    cursor.style.left = '20%'; cursor.style.top = '92%';
    await wait(700);
    for (const l of lines) {
      stepsBox.insertAdjacentHTML('beforeend', `<div class="aw-step"><i>›</i>${l}</div>`);
      await wait(900);
    }
    allow.classList.remove('is-hidden');
    state.textContent = 'Waiting for your OK'; state.style.color = 'var(--attention)';
    orbit.setAttribute('motion', 'nudge'); orbit.setAttribute('mood', 'wide');
    await wait(1100);
    await point(cursor, allowBtn, win);
    allow.classList.add('is-hidden');
    state.textContent = 'Working'; state.style.color = 'var(--live)';
    orbit.setAttribute('motion', 'working'); orbit.setAttribute('mood', 'normal');
    stepsBox.insertAdjacentHTML('beforeend', '<div class="aw-step"><i>›</i>Running npm test</div>');
    await wait(1400);
    result.classList.remove('is-hidden');
    state.textContent = 'Done'; state.style.color = 'var(--text-2)';
    orbit.setAttribute('motion', 'idle'); orbit.setAttribute('mood', 'happy');
    await wait(3200);
  });
});

// ---------- Everything: chips switch the description ----------
const features = [
  ['Music', '#FBAE72', 'What\'s playing in Spotify or Music, with a spinning vinyl or the cover art. Play, pause, skip, shuffle and scrub from the notch, and see the waveform while you peek.'],
  ['Meetings', '#4C9BFF', 'Your next meeting from the calendars on your Mac, with a countdown in the peek and a big Join button. Zoom, Teams, Meet and Webex.'],
  ['Tasks', '#34C759', 'Your own tasks and your HubSpot tasks in one list, with Overdue, Today and Upcoming, priorities, links and notes.'],
  ['Focus', '#FFD34D', 'Several timers at once, single focus blocks or rounds with breaks. Pick a playlist that plays while you focus.'],
  ['Notes', '#A196FC', 'A scratchpad that\'s always one hover away, plus a short list of saved notes.'],
  ['Shelf', '#6FE3B0', 'Drop files on the notch to keep them, AirDrop them, or convert images, video and audio.'],
  ['Smart Ask', '#F08DB3', 'Ask in plain words. A morning brief, meeting prep with HubSpot context, and changes only after you say OK.'],
  ['Agents', '#D97757', 'Start Claude Code on a task, approve its steps from the notch, and see your terminal sessions and GitHub reviews.'],
  ['Capture', '#5C9EFF', 'Scrolling screenshots, screen recordings, and drawing right on your screen during a call.'],
  ['Mirror & Mic', '#34C759', 'Check your camera before a call, see when your mic is live, and mute it from anywhere with ⌥M.'],
  ['Prompter', '#FFB020', 'Your script scrolls right under the camera, at a speed you set, so you keep eye contact.'],
  ['YouTube & Photos', '#A196FC', 'Drop a YouTube link to watch it in the notch, and keep a photo slideshow on Home.'],
];
const tabs = document.getElementById('feature-tabs');
if (tabs) {
  tabs.innerHTML = features.map(([name, color], i) =>
    `<button class="chip glass" role="tab" id="ft-${i}" aria-controls="feature-panel" data-i="${i}">
       <i class="swatch" style="background:${color}"></i>${name}</button>`).join('');
  const buttons = [...tabs.querySelectorAll('button')];
  const panel = document.getElementById('feature-panel');
  const show = (i, focus) => {
    const [name, color, text] = features[i];
    buttons.forEach((b, j) => { b.setAttribute('aria-selected', String(i === j)); b.setAttribute('aria-checked', String(i === j)); b.tabIndex = i === j ? 0 : -1; });
    panel.setAttribute('aria-labelledby', `ft-${i}`);
    const box = panel.querySelector('div');
    box.style.animation = 'none'; void box.offsetWidth; box.style.animation = '';
    document.getElementById('feature-title').textContent = name;
    document.getElementById('feature-text').textContent = text;
    const ico = document.getElementById('feature-ico');
    ico.style.background = `${color}2e`; ico.innerHTML = `<i class="swatch" style="width:18px;height:18px;background:${color}"></i>`;
    if (focus) buttons[i].focus();
  };
  buttons.forEach((b, i) => {
    b.addEventListener('click', () => show(i));
    b.addEventListener('keydown', (e) => {
      const d = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
      if (d) { e.preventDefault(); show((i + d + buttons.length) % buttons.length, true); }
    });
  });
  show(0);
}

// ---------- Add-on categories (homepage) ----------
const catGrid = document.getElementById('cat-grid');
if (catGrid && window.ORBIT_ADDONS) {
  catGrid.innerHTML = window.ORBIT_ADDONS.map((c) => `
    <a class="cat-card glass reveal in" href="addons.html#${c.id}">
      <span class="cat-ico" style="background:${c.color}26;color:${c.color}"><svg viewBox="0 0 24 24" aria-hidden="true">${c.icon}</svg></span>
      <h3>${c.title}</h3>
      <p>${c.blurb}</p>
      <div class="names">${c.built.slice(0, 3).map(([n]) => `<span>${n}</span>`).join('')}</div>
      <span class="count">${c.built.length} add-ons now · ${c.ideas.length} on the roadmap</span>
    </a>`).join('');
}

// ---------- The hero's focus tile counts down ----------
const live = document.querySelector('[data-live-timer]');
if (live && !reduce) {
  let s = 17 * 60 + 42;
  setInterval(() => { s = s > 0 ? s - 1 : 25 * 60; live.textContent = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`; }, 1000);
}

// ---------- Fade sections in ----------
const io = 'IntersectionObserver' in window
  ? new IntersectionObserver((entries) => entries.forEach((e) => {
      if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
    }), { rootMargin: '0px 0px -8% 0px' })
  : null;
document.querySelectorAll('.reveal').forEach((el) => (io ? io.observe(el) : el.classList.add('in')));

const year = document.getElementById('year');
if (year) year.textContent = new Date().getFullYear();
