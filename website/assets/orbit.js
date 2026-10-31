// <orbit-character size="96" color="White" mood="normal" motion="idle" tint="#FFB020">
// Orbit, the companion from the app: a ringed planet with two tilted eyes, drawn as SVG and
// animated with SVG animations (same drawing, colours, moods and motions as Viktor/Views/Orbit.swift).

const THEMES = {
  White:    { body: '#FFFFFF', ring: '#B9B6D3', eyes: '#16131F' },
  Original: { body: '#FBAE72', ring: '#A196FC', eyes: '#3B0844' },
  Ink:      { body: '#26252C', ring: '#77748A', eyes: '#FFFFFF' },
  Bluey:    { body: '#5C9EFF', ring: '#CFE1FF', eyes: '#0A1A33' },
  Coral:    { body: '#FF7A6B', ring: '#FFD3CB', eyes: '#2A0A06' },
  Mint:     { body: '#6FE3B0', ring: '#2E8F68', eyes: '#06281B' },
  Sunny:    { body: '#FFD34D', ring: '#FF9F43', eyes: '#2B1E00' },
};

const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

function pose(motionIn, moodIn, tintIn, theme) {
  const motion = reduceMotion.matches ? 'still' : motionIn;
  const tint = tintIn || (motion === 'alert' ? '#FF453A' : '#FFB020');
  let mood = moodIn;
  if (mood === 'normal') {
    if (motion === 'thinking') mood = 'squint';
    if (motion === 'listening' || motion === 'nudge') mood = 'wide';
    if (motion === 'alert') mood = 'grumpy';
  }
  if (motion === 'celebrate') mood = 'happy';
  if (motion === 'sleep') mood = 'closed';

  let erx = 4.6, ery = 6.4;
  if (mood === 'wide') { erx = 5.6; ery = 7.8; }
  if (mood === 'squint') { erx = 5; ery = 2; }
  if (mood === 'grumpy') { erx = 4.8; ery = 3.6; }
  const lineEyes = mood === 'happy' || mood === 'closed';
  const blink = motion === 'still' || lineEyes ? `${ery};${ery};${ery};${ery}` : `${ery};${ery};0.5;${ery}`;

  let bob = '0 0;0 0', bobKeys = '0;1', bobDur = '3s';
  if (motion === 'idle' || motion === 'glow') { bob = '0 0;0 -1.6;0 0'; bobKeys = '0;0.5;1'; bobDur = '3.2s'; }
  if (motion === 'sleep') { bob = '0 0;0 -1;0 0'; bobKeys = '0;0.5;1'; bobDur = '4.5s'; }
  if (motion === 'nudge') { bob = '0 0;0 -12;0 0;0 -5;0 0;0 0'; bobKeys = '0;0.18;0.34;0.44;0.54;1'; bobDur = '1.4s'; }
  if (motion === 'celebrate') { bob = '0 0;0 -10;0 0;0 0'; bobKeys = '0;0.2;0.4;1'; bobDur = '2.2s'; }
  if (motion === 'alert') { bob = '0 0;-3 0;3 0;-3 0;3 0;0 0;0 0'; bobKeys = '0;0.06;0.12;0.18;0.24;0.3;1'; bobDur = '1.8s'; }

  let swing = '0 50 52;0 50 52', swingDur = '2.4s';
  if (motion === 'working') swing = '-12 50 52;12 50 52;-12 50 52';
  if (motion === 'nudge') { swing = '-9 50 52;9 50 52;-9 50 52'; swingDur = '0.8s'; }
  if (motion === 'celebrate') { swing = '-15 50 52;15 50 52;-15 50 52'; swingDur = '1.1s'; }
  if (motion === 'thinking') { swing = '-4 50 52;4 50 52;-4 50 52'; swingDur = '4.8s'; }

  let look = '0 0;0 0';
  if (motion === 'working') look = '-3 1;3 -1;-3 1';
  if (motion === 'thinking') look = '1.2 -2.4;1.2 -2.4';

  return {
    ...theme, tint, erx, ery, blink, bob, bobKeys, bobDur, swing, swingDur, look,
    ringCycle: motion === 'celebrate' ? '#FF8A80;#FFD180;#FFFF8D;#B9F6CA;#80D8FF;#B388FF;#FF8A80' : `${theme.ring};${theme.ring}`,
    ringW: motion === 'listening' ? '8.5;12;8.5' : '8.5;8.5',
    ringOp: motion === 'sleep' ? '0.45;0.85;0.45' : '1;1',
    flash: motion === 'alert' ? '0;0.85;0;0.85;0;0' : '0;0;0;0;0;0',
    glow: ['nudge', 'glow', 'alert'].includes(motion) ? `drop-shadow(0 0 4px ${tint})` : 'none',
    moonR: motion === 'thinking' ? 5.5 : 0,
    leftOp: lineEyes ? 0 : 1,
    rightOp: lineEyes || mood === 'wink' ? 0 : 1,
    browOp: mood === 'grumpy' ? 1 : 0,
    happyOp: mood === 'happy' ? 1 : 0,
    closedOp: mood === 'closed' ? 1 : 0,
    closedRightOp: mood === 'closed' || mood === 'wink' ? 1 : 0,
  };
}

function ring(p, front) {
  const anim = `
    <animate attributeName="stroke" values="${p.ringCycle}" dur="2.4s" repeatCount="indefinite"/>
    <animate attributeName="stroke-width" values="${p.ringW}" dur="0.9s" repeatCount="indefinite"/>
    <animate attributeName="opacity" values="${p.ringOp}" dur="4.5s" repeatCount="indefinite"/>`;
  const shape = front
    ? `<path d="M3 52 A47 15 0 0 0 97 52" fill="none" stroke="${p.ring}" stroke-width="8.5">${anim}</path>`
    : `<ellipse cx="50" cy="52" rx="47" ry="15" fill="none" stroke="${p.ring}" stroke-width="8.5">${anim}</ellipse>
       <circle r="${p.moonR}" fill="${p.body}" stroke="${p.ring}" stroke-width="1.6">
         <animateMotion path="M97 52 A47 15 0 1 1 3 52 A47 15 0 1 1 97 52" dur="2.6s" repeatCount="indefinite"/></circle>`;
  return `<g style="filter:${p.glow}"><g transform="rotate(24 50 52)"><g>
    <animateTransform attributeName="transform" type="rotate" values="${p.swing}" dur="${p.swingDur}" repeatCount="indefinite"/>
    ${shape}</g></g></g>`;
}

function svg(size, p, label) {
  const eye = (cx, cy, op) => `<ellipse cx="${cx}" cy="${cy}" rx="${p.erx}" ry="${p.ery}" fill="${p.eyes}" opacity="${op}" transform="rotate(24 ${cx} ${cy})">
      <animate attributeName="ry" values="${p.blink}" keyTimes="0;0.92;0.96;1" dur="4.2s" repeatCount="indefinite"/></ellipse>`;
  return `<svg width="${size}" height="${size}" viewBox="-2 -2 104 104" role="img" aria-label="${label}" style="overflow:visible">
  <g><animateTransform attributeName="transform" type="translate" values="${p.bob}" keyTimes="${p.bobKeys}" dur="${p.bobDur}" repeatCount="indefinite"/>
    ${ring(p, false)}
    <circle cx="50" cy="52" r="30" fill="${p.body}"/>
    <circle cx="50" cy="52" r="30" fill="${p.tint}" opacity="0">
      <animate attributeName="opacity" values="${p.flash}" keyTimes="0;0.1;0.2;0.3;0.4;1" dur="1.8s" repeatCount="indefinite"/></circle>
    <g><animateTransform attributeName="transform" type="translate" values="${p.look}" dur="2.4s" repeatCount="indefinite"/>
      ${eye(54, 41, p.leftOp)}${eye(68, 49, p.rightOp)}
      <g opacity="${p.browOp}" stroke="${p.eyes}" stroke-width="3.2" stroke-linecap="round"><path d="M48 33 L59 37"/><path d="M64 41 L73 41"/></g>
      <g opacity="${p.happyOp}" fill="none" stroke="${p.eyes}" stroke-width="3.6" stroke-linecap="round"><path d="M49 43 Q54 34 59 42"/><path d="M63 51 Q68 42 73 50"/></g>
      <g fill="none" stroke="${p.eyes}" stroke-width="3.6" stroke-linecap="round"><path d="M49 40 Q54 46 59 42" opacity="${p.closedOp}"/><path d="M63 48 Q68 54 73 50" opacity="${p.closedRightOp}"/></g>
    </g>
    ${ring(p, true)}
  </g></svg>`;
}

class OrbitCharacter extends HTMLElement {
  static observedAttributes = ['size', 'color', 'mood', 'motion', 'tint', 'label'];
  connectedCallback() { this.render(); }
  attributeChangedCallback() { if (this.isConnected) this.render(); }
  render() {
    const size = Number(this.getAttribute('size') || 96);
    const theme = THEMES[this.getAttribute('color')] || THEMES.White;
    const p = pose(this.getAttribute('motion') || 'idle', this.getAttribute('mood') || 'normal', this.getAttribute('tint'), theme);
    this.style.display = 'inline-block';
    this.style.lineHeight = '0';
    this.style.width = this.style.height = `${size}px`;
    this.innerHTML = svg(size, p, this.getAttribute('label') || 'Orbit');
  }
}

customElements.define('orbit-character', OrbitCharacter);
reduceMotion.addEventListener?.('change', () => document.querySelectorAll('orbit-character').forEach((o) => o.render()));
