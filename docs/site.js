// Shared behaviour of the Winnie site. Every block looks for its own elements, so one file serves all pages.
const $ = id => document.getElementById(id);
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const sprite = name => `images/sprites/${name}.png`;
const calm = matchMedia('(prefers-reduced-motion: reduce)').matches;

// ---------- Theme: Auto follows the system; a manual choice is remembered.
const themeButton = $('theme');
if (themeButton) {
  const order = ['auto', 'light', 'dark'], labels = { auto: 'как в системе', light: 'светлая', dark: 'тёмная' };
  const icons = {
    auto: '<circle cx="12" cy="12" r="8.5"/><path d="M12 3.5v17a8.500 8.500 0 0 0 0-17z" fill="currentColor" stroke="none"/>',
    light: '<circle cx="12" cy="12" r="4"/><path d="M12 2.500v2.500M12 19v2.500M2.500 12H5M19 12h2.500M5.300 5.300l1.800 1.800M16.900 16.900l1.800 1.800M5.300 18.700l1.800-1.800M16.900 7.100l1.800-1.800"/>',
    dark: '<path d="M20 14.500A8.500 8.500 0 0 1 9.500 4 8.500 8.500 0 1 0 20 14.500z"/>',
  };
  const system = matchMedia('(prefers-color-scheme: dark)');
  let choice = 'auto';
  try { choice = localStorage.getItem('theme') || 'auto'; } catch {}
  if (!order.includes(choice)) choice = 'auto';
  const apply = () => {
    document.documentElement.dataset.theme = choice === 'auto' ? (system.matches ? 'dark' : 'light') : choice;
    themeButton.innerHTML = `<svg viewBox="0 0 24 24" aria-hidden="true">${icons[choice]}</svg>`;
    themeButton.title = `Тема: ${labels[choice]}`;
    themeButton.setAttribute('aria-label', themeButton.title);
  };
  apply();
  system.addEventListener('change', apply);
  themeButton.addEventListener('click', event => {
    choice = order[(order.indexOf(choice) + 1) % order.length];
    try { choice === 'auto' ? localStorage.removeItem('theme') : localStorage.setItem('theme', choice); } catch {}
    const root = document.documentElement;
    root.style.setProperty('--x', `${event.clientX}px`);
    root.style.setProperty('--y', `${event.clientY}px`);
    if (!document.startViewTransition || calm) return apply();
    // A second click while the circle is still opening skips the first transition; that is not an error.
    const transition = document.startViewTransition(apply);
    [transition.ready, transition.finished].forEach(promise => promise.catch(() => {}));
  });
}

// ---------- Menu drawer for widths where the full menu does not fit.
const drawer = $('drawer'), burger = $('burger');
if (drawer && burger) {
  const setOpen = open => {
    burger.setAttribute('aria-expanded', open);
    document.body.style.overflow = open ? 'hidden' : '';
    if (open) { drawer.hidden = false; requestAnimationFrame(() => requestAnimationFrame(() => drawer.classList.add('open'))); drawer.querySelector('button').focus(); }
    else { drawer.classList.remove('open'); setTimeout(() => { if (!drawer.classList.contains('open')) drawer.hidden = true; }, calm ? 0 : 450); burger.focus(); }
  };
  burger.addEventListener('click', () => setOpen(true));
  drawer.addEventListener('click', event => { if (event.target.closest('[data-close], a')) setOpen(false); });
  addEventListener('keydown', event => { if (event.key === 'Escape' && !drawer.hidden) setOpen(false); });
  matchMedia('(min-width: 1181px)').addEventListener('change', event => { if (event.matches && !drawer.hidden) setOpen(false); });
}

// ---------- Copy buttons: data-copy holds the id of the element whose text goes to the clipboard.
document.querySelectorAll('[data-copy]').forEach(button => button.addEventListener('click', async () => {
  const source = $(button.dataset.copy);
  try { await navigator.clipboard.writeText(source.textContent); }
  catch {
    const range = document.createRange(), selection = getSelection();
    range.selectNodeContents(source);
    selection.removeAllRanges(); selection.addRange(range);
    document.execCommand('copy');
    selection.removeAllRanges();
  }
  button.classList.add('done');
  setTimeout(() => button.classList.remove('done'), 1600);
}));

// ---------- Section rules draw themselves when a section comes into view.
const seen = new IntersectionObserver(entries => entries.forEach(entry => {
  if (entry.isIntersecting) { entry.target.classList.add('in'); seen.unobserve(entry.target); }
}), { threshold: .15 });
document.querySelectorAll('section').forEach(section => seen.observe(section));

// ---------- Hero bear: notices the pointer, as the real one does.
const pet = $('pet');
if (pet) {
  new Image().src = sprite('hover');
  pet.addEventListener('mouseenter', () => pet.src = sprite('hover'));
  pet.addEventListener('mouseleave', () => pet.src = sprite('idle'));
}

// ---------- Hero chat: turns its own tabs, Chat, Events, Notes.
const panel = $('panel');
if (panel && !calm) {
  const slots = [...panel.children];
  let shown = 0;
  setInterval(() => {
    if (document.hidden) return;
    slots[shown].classList.remove('on');
    shown = (shown + 1) % slots.length;
    slots[shown].classList.add('on');
  }, 2800);
}

// ---------- 01: scenarios. The reply is typed, then the result arrives in the shape that case has in the app.
const list = $('list');
if (list) {
  const cases = [
    { c: '--violet', icon: '🎙️', title: 'Слушать по шорткату', note: 'Диктовка из любого приложения, ответ вслух.',
      keys: ['⇧', '⌘', 'E'], pose: 'listening', ask: 'сколько граммов в стакане муки?', text: 'Около 130 граммов.' },
    { c: '--acc', icon: '⏰', title: 'Напомнить', note: 'Время берётся из фразы.',
      ask: 'напомни через 40 минут достать пирог', card: ['Достать пирог', 'сегодня, 14:40'] },
    { c: '--blue', icon: '⚡', title: 'Быстрая команда', note: 'Кнопка в пустом чате со своей инструкцией.',
      chip: 'Проверь почту', ask: 'Собери сводку непрочитанной почты: что ждёт ответа, что можно пропустить',
      items: ['Лёва ждёт ответ по поездке', 'Счёт за хостинг до пятницы', 'Остальное – рассылки'] },
    { c: '--yellow', icon: '📝', title: 'Записать', note: 'Заметки – Markdown-файлы на диске.',
      ask: 'запиши в Идеи: прогулка по экрану', text: 'Добавил в заметку «Идеи».' },
    { c: '--blue', icon: '🌍', title: 'Перевести', note: 'Ответ выделяется и копируется.',
      ask: 'переведи вежливо: давайте перенесём созвон на четверг', text: 'Could we please move the call to Thursday?' },
    { c: '--blue', icon: '🔎', title: 'Найти', note: 'Поиск в вебе со ссылками на источники.',
      ask: 'до скольки сегодня работает мэрия?', text: 'До 18:00, приём документов до 17:30.', source: '1. Сайт мэрии' },
    { c: '--green', icon: '📬', title: 'Разобрать почту', note: 'Gmail, доступ только на чтение.',
      ask: 'что важного в почте?', items: ['Лёва ждёт ответ по поездке', 'Счёт за хостинг до пятницы', 'Остальное – рассылки'] },
  ];
  const stage = $('stage'), hint = $('hint'), say = $('say'), out = $('out'), bear = $('stage-pet');
  let run = 0;
  ['listening', 'thinking', 'talking'].forEach(name => { new Image().src = sprite(name); });
  cases.forEach((item, index) => {
    const button = document.createElement('button');
    button.type = 'button'; button.role = 'tab';
    button.style.setProperty('--c', `var(${item.c})`);
    button.innerHTML = `<span class="ico" aria-hidden="true">${item.icon}</span><b>${item.title}</b><small>${item.note}</small>`;
    button.addEventListener('click', () => play(index));
    list.append(button);
  });
  async function play(index) {
    const id = ++run, item = cases[index], alive = () => id === run;
    [...list.children].forEach((button, i) => button.setAttribute('aria-selected', i === index));
    stage.style.setProperty('--c', `var(${item.c})`);
    hint.innerHTML = say.textContent = out.innerHTML = '';
    say.classList.remove('done');
    bear.src = sprite(item.pose || 'idle');
    if (item.keys) hint.innerHTML = item.keys.map(key => `<kbd>${key}</kbd>`).join('') + ' слушаю';
    if (item.chip) { hint.innerHTML = `<span class="chip">${item.chip}</span>`; await sleep(calm ? 0 : 700); }
    for (const char of item.ask) { if (!alive()) return; say.textContent += char; if (!calm) await sleep(item.chip ? 12 : 30); }
    say.classList.add('done');
    bear.src = sprite('thinking'); await sleep(900); if (!alive()) return;
    bear.src = sprite('talking');
    if (item.text) for (const word of item.text.split(' ')) { if (!alive()) return; out.append(`${word} `); if (!calm) await sleep(90); }
    if (item.source) out.insertAdjacentHTML('beforeend', `<span class="src">${item.source}</span>`);
    if (item.card) out.innerHTML = `<div class="card"><img src="images/favicon.png" alt="" width="40"><div>${item.card[0]}<small>Winnie · ${item.card[1]}</small></div></div>`;
    if (item.items) { out.innerHTML = '<ul></ul>'; for (const line of item.items) { if (!alive()) return; out.firstChild.insertAdjacentHTML('beforeend', `<li>${line}</li>`); await sleep(calm ? 0 : 350); } }
    await sleep(3000);
    if (alive() && !calm) play((index + 1) % cases.length);
  }
  new IntersectionObserver((entries, observer) => { if (entries[0].isIntersecting) { observer.disconnect(); play(0); } }, { threshold: .3 }).observe(stage);
}

// ---------- 02: the three tabs of the app.
const tabs = $('tabs');
if (tabs) tabs.addEventListener('click', event => {
  const tab = event.target.closest('[data-tab]'); if (!tab) return;
  tabs.querySelectorAll('[data-tab]').forEach(button => button.setAttribute('aria-selected', button === tab));
  document.querySelectorAll('[data-body]').forEach(body => body.hidden = body.dataset.body !== tab.dataset.tab);
  document.querySelectorAll('[data-shot]').forEach(shot => shot.hidden = shot.dataset.shot !== tab.dataset.tab);
});

// ---------- 03: the resizable window reports its size at the app's scale (the box is drawn at half size).
const box = $('resize');
if (box && 'ResizeObserver' in window) new ResizeObserver(() => {
  $('resize-size').textContent = `${Math.round(box.offsetWidth * 2)} × ${Math.round(box.offsetHeight * 2)}`;
}).observe(box);

// ---------- 04: frames. They change by themselves like a cartoon; picking one from the strip pauses.
const strip = $('strip');
if (strip) {
  const frames = [
    ['idle', 'Покой', 'Стоит в углу экрана поверх всех окон.'], ['hover', 'Заметил', 'Курсор над ним. Появляется кнопка нового диалога.'],
    ['thinking', 'Думает', 'Запрос ушёл, ответа ещё нет.'], ['talking', 'Говорит', 'Ответ приходит в чат.'],
    ['listening', 'Слушает', 'Идёт диктовка.'], ['drag', 'Тащат', 'Его перетаскивают. Место запоминается.'],
    ['error', 'Ошибка', 'Нет сети или не подошёл ключ.'], ['sleep', 'Спит', 'Минута без действий.'],
    ['smoke-0', 'Перекур', 'Анимация из пяти кадров.'],
  ];
  let current = 0, playing = false, timer, inner;
  frames.forEach(([name, title], index) => {
    const button = document.createElement('button');
    button.type = 'button'; button.role = 'tab';
    button.innerHTML = `<img src="${sprite(name)}" alt="" loading="lazy"><span>${title}</span>`;
    button.addEventListener('click', () => { setPlaying(false); show(index); });
    strip.append(button);
  });
  function show(index) {
    current = index; clearInterval(inner);
    const [name, title, text] = frames[index];
    $('frame').src = sprite(name); $('frame-t').textContent = title; $('frame-d').textContent = text;
    $('frame-n').textContent = `${String(index + 1).padStart(2, '0')} / ${String(frames.length).padStart(2, '0')}`;
    [...strip.children].forEach((button, i) => button.setAttribute('aria-selected', i === index));
    if (name === 'smoke-0' && !calm) { let n = 0; inner = setInterval(() => $('frame').src = sprite(`smoke-${n = (n + 1) % 5}`), 420); }
  }
  function setPlaying(on) {
    playing = on; clearTimeout(timer);
    $('frame-play').textContent = on ? 'Пауза' : 'Играть';
    const tick = () => { timer = setTimeout(() => { show((current + 1) % frames.length); tick(); }, frames[current][0] === 'smoke-0' ? 2300 : 1200); };
    if (on) tick();
  }
  $('frame-play').addEventListener('click', () => setPlaying(!playing));
  show(0);
  new IntersectionObserver((entries, observer) => { if (entries[0].isIntersecting) { observer.disconnect(); if (!calm) setPlaying(true); else setPlaying(false); } }, { threshold: .3 }).observe(strip);
}

// ---------- Contact form: a static site has no server, so it composes a letter in the visitor's mail app.
const form = $('contact-form');
if (form) form.addEventListener('submit', event => {
  event.preventDefault();
  const data = new FormData(form), name = (data.get('name') || '').trim();
  const body = `${data.get('message').trim()}${name ? `\n\n${name}` : ''}`;
  location.href = `mailto:${form.dataset.mail}?subject=${encodeURIComponent(`Winnie: ${data.get('topic')}`)}&body=${encodeURIComponent(body)}`;
});
