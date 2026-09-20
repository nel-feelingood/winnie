// Shared behaviour of the Winnie site. Every block checks for its own elements, so one file serves all pages.

// Copy buttons: data-copy holds the id of the element whose text goes to the clipboard.
document.querySelectorAll('[data-copy]').forEach(button => button.addEventListener('click', async () => {
  const source = document.getElementById(button.dataset.copy);
  try { await navigator.clipboard.writeText(source.textContent); }
  catch {
    const range = document.createRange(), selection = getSelection();
    range.selectNodeContents(source);
    selection.removeAllRanges(); selection.addRange(range);
    document.execCommand('copy');
    selection.removeAllRanges();
  }
  const target = button.querySelector('.label') || button, label = target.textContent;
  target.textContent = 'Скопировано ✓';
  setTimeout(() => target.textContent = label, 1800);
}));

// The bear on the desktop tells what he can do, wearing the sprite that goes with each line.
const pet = document.getElementById('pet'), bubble = document.getElementById('bubble');
if (pet && bubble) {
  const story = [
    ['talking',   'Привет! Я Винни. Живу поверх всех окон.'],
    ['thinking',  'Спроси что угодно — поищу в интернете.'],
    ['talking',   'Напомню о важном. Скажи: «через час позвонить».'],
    ['talking',   'Веду заметки. Могу дописывать их сам.'],
    ['thinking',  'Пришли скриншот — объясню, что на нём.'],
    ['talking',   'Расскажу, что важного в почте.'],
    ['listening', 'Понимаю голос и отвечаю вслух.'],
    ['talking',   'В Telegram я тоже есть.'],
    ['smoke-2',   'В 16:20 у меня перекур.'],
    ['sleep',     'А если минуту не трогать — сплю и вижу сны.'],
  ];
  ['hover', ...story.map(([state]) => state)].forEach(state => { new Image().src = `images/sprites/${state}.png`; });
  let step = -1, timer;
  const say = (state, text) => {
    pet.src = `images/sprites/${state}.png`;
    bubble.classList.remove('pop'); void bubble.offsetWidth; bubble.classList.add('pop');
    bubble.textContent = text;
  };
  const next = () => { step = (step + 1) % story.length; say(...story[step]); };
  const play = () => { clearInterval(timer); timer = setInterval(next, 3600); };
  pet.addEventListener('mouseenter', () => { clearInterval(timer); say('hover', 'Нажми — расскажу, что ещё умею'); });
  pet.addEventListener('mouseleave', () => { next(); play(); });
  pet.addEventListener('click', () => { next(); if (!pet.matches(':hover')) play(); });
  setTimeout(() => { next(); play(); }, 1200);
}

// Dreams over the sleeping bear: mostly his favourites, as in the app, only more often than once in 10 s.
const dreams = document.getElementById('dreams');
if (dreams) {
  const favourites = ['🍯', '🐝', '🥄', '🍰', '🎈', '💃', '💋', '👠', '🌿', '🍃', '🍀', '🏎️', '🚗', '🚙', '🏁', '💼', '💻', '📈', '☕️'];
  const dream = () => {
    const emoji = document.createElement('span');
    emoji.textContent = favourites[Math.floor(Math.random() * favourites.length)];
    emoji.style.left = `${38 + Math.random() * 30}%`;
    dreams.append(emoji);
    emoji.addEventListener('animationend', () => emoji.remove());
  };
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) { dreams.classList.add('still'); dream(); }
  else { dream(); setInterval(() => { if (!document.hidden) dream(); }, 2200); }
}

// "Write to the author": a static site has no server, so the form composes a letter in the visitor's mail app.
const form = document.getElementById('contact-form');
if (form) form.addEventListener('submit', event => {
  event.preventDefault();
  const data = new FormData(form), name = (data.get('name') || '').trim();
  const body = `${data.get('message').trim()}${name ? `\n\n— ${name}` : ''}`;
  location.href = `mailto:${form.dataset.mail}?subject=${encodeURIComponent(`Winnie: ${data.get('topic')}`)}&body=${encodeURIComponent(body)}`;
});

// Tabs on the installation page. A link to a heading inside a hidden panel opens that panel first.
const tabs = [...document.querySelectorAll('[role="tab"]')];
if (tabs.length) {
  const select = (tab, focus) => {
    tabs.forEach(t => {
      const on = t === tab;
      t.setAttribute('aria-selected', on); t.tabIndex = on ? 0 : -1;
      document.getElementById(t.getAttribute('aria-controls')).hidden = !on;
    });
    if (focus) tab.focus();
  };
  const reveal = () => {
    const target = location.hash && document.getElementById(location.hash.slice(1));
    const panel = target && target.closest('.tab-panel');
    if (panel && panel.hidden) { select(document.getElementById(panel.getAttribute('aria-labelledby'))); target.scrollIntoView(); }
  };
  tabs.forEach((tab, i) => {
    tab.addEventListener('click', () => select(tab));
    tab.addEventListener('keydown', e => {
      if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') select(tabs[(i + (e.key === 'ArrowRight' ? 1 : tabs.length - 1)) % tabs.length], true);
    });
  });
  document.querySelectorAll('[data-tab]').forEach(link => link.addEventListener('click', () => select(document.getElementById(`tab-${link.dataset.tab}`))));
  addEventListener('hashchange', reveal);
  reveal();
}
