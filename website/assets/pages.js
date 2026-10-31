// The add-ons page: filter by category, list the add-ons, then the roadmap ideas.

const cats = window.ORBIT_ADDONS || [];
const filter = document.getElementById('addon-filter');
const grid = document.getElementById('addon-grid');
const ideas = document.getElementById('addon-ideas');

function render(id) {
  const shown = id === 'all' ? cats : cats.filter((c) => c.id === id);
  grid.innerHTML = shown.flatMap((c) => c.built.map(([name, tier, text]) => `
    <article class="addon-card glass">
      <div class="top">
        <span class="cat-ico" style="background:${c.color}26;color:${c.color}"><svg viewBox="0 0 24 24" aria-hidden="true">${c.icon}</svg></span>
        <span class="grow"><b>${name}</b><small>${c.title}</small></span>
        <span class="tier-badge ${tier === 'Free' ? 'free' : ''}">${tier}</span>
      </div>
      <p>${text}</p>
    </article>`)).join('');
  ideas.innerHTML = `<h3>Coming next</h3>` + shown.map((c) => `
    <div><small style="color:${c.color};font-weight:600">${c.title}</small>
      <div class="idea-row">${c.ideas.map((n) => `<span>${n}</span>`).join('')}</div></div>`).join('');
  [...filter.querySelectorAll('button')].forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.id === id)));
}

if (filter && grid) {
  filter.innerHTML = [`<button class="chip glass" data-id="all">All</button>`]
    .concat(cats.map((c) => `<button class="chip glass" data-id="${c.id}"><i class="swatch" style="background:${c.color}"></i>${c.title}</button>`)).join('');
  filter.addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (!b) return;
    history.replaceState(null, '', b.dataset.id === 'all' ? location.pathname : `#${b.dataset.id}`);
    render(b.dataset.id);
  });
  const start = location.hash.slice(1);
  render(cats.some((c) => c.id === start) ? start : 'all');
}
