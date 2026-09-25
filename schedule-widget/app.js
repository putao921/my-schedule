/* ==========================================================================
   My Schedule — 核心脚本
   内容已标注：除日期/节假日外，全部为演示用模拟数据。
   ========================================================================== */
(() => {
  'use strict';

  /* ======================================================================
     1. 像素图标集（内联 SVG，避免外部资源依赖）
     ====================================================================== */
  const ICON = {
    today:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/><rect x="7" y="13" width="5" height="5" rx="1" fill="currentColor" stroke="none"/></svg>',
    week:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/><rect x="6" y="13" width="3" height="5" rx="1" fill="currentColor" stroke="none"/><rect x="10.5" y="13" width="3" height="5" rx="1" fill="currentColor" stroke="none"/><rect x="15" y="13" width="3" height="5" rx="1" fill="currentColor" stroke="none"/></svg>',
    month:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/><path d="M7 14h.01M12 14h.01M17 14h.01M7 18h.01M12 18h.01M17 18h.01"/></svg>',
    list:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M8 6h13M8 12h13M8 18h13"/><path d="M3.5 6h.01M3.5 12h.01M3.5 18h.01"/></svg>',
    tasks:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="3" width="16" height="18" rx="2"/><path d="M8 9l2 2 4-4M8 16h6"/></svg>',
    settings:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M19 5l-2 2M7 17l-2 2"/></svg>',
    profile: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="8" r="4"/><path d="M4 21c0-4 3.6-6 8-6s8 2 8 6"/></svg>',
    plus:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg>',
    pin:     '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 3l6 6-3 1-4 4 1 5-3-3-6 6"/><path d="M9 9l-5 5 6 1"/></svg>',
    moon:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M20 14.5A8.5 8.5 0 019.5 4a8.5 8.5 0 1010.5 10.5z"/><path d="M4 4l1.5 1.5M17 2v2M21 19h2" opacity=".6"/></svg>',
    sun:     '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5L19 19M19 5l-1.5 1.5M6.5 17.5L5 19"/></svg>',
    more:    '<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="5" cy="12" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="19" cy="12" r="2"/></svg>',
    collapse:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M6 15l6-6 6 6"/></svg>',
    chevL:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M15 6l-6 6 6 6"/></svg>',
    chevR:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M9 6l6 6-6 6"/></svg>',
    search:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="M20 20l-4-4"/></svg>',
    check:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 12.5l5 5L20 7"/></svg>',
    min:     '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"><path d="M5 12h14"/></svg>',
    max:     '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><rect x="4" y="4" width="16" height="16" rx="1.5"/></svg>',
    close:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"><path d="M6 6l12 12M18 6L6 18"/></svg>',
    doc:     '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3h8l5 5v13H6z"/><path d="M14 3v5h5"/></svg>',
    trash:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 7h16M9 7V5h6v2M6 7l1 14h10l1-14"/></svg>',
    // 角落缎带（节假日标记）
    ribbon:  '<svg viewBox="0 0 16 16"><path d="M16 0v16L7 9H0V0z" fill="currentColor" opacity=".95"/><path d="M13.5 3.5l-1.6 1.9 1.4 1.4-1.9 2.2" fill="none" stroke="#fff" stroke-width="1.1" stroke-linecap="round" stroke-linejoin="round"/></svg>'
  };

  /* ======================================================================
     2. 工具
     ====================================================================== */
  const $  = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

  const pad2 = n => String(n).padStart(2, '0');
  const ymd  = d => `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
  const parseYmd = s => { const [y, m, d] = s.split('-').map(Number); return new Date(y, m - 1, d); };
  const addDays = (d, n) => { const x = new Date(d); x.setDate(x.getDate() + n); return x; };
  const addMonths = (d, n) => new Date(d.getFullYear(), d.getMonth() + n, 1);
  const startOfWeek = d => addDays(d, -((d.getDay() + 6) % 7));   // 周一为一周之始
  const sameDay = (a, b) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
  const minToHHMM = m => `${pad2(Math.floor(m / 60) % 24)}:${pad2(m % 60)}`;
  const hm = m => { const h = Math.floor(m / 60), mm = m % 60; return mm === 0 ? `${pad2(h)}:00` : `${pad2(h)}:${pad2(mm)}`; };

  const DOW_EN = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const DOW_ZH = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  const MON_EN = ['January','February','March','April','May','June','July','August','September','October','November','December'];

  /* ======================================================================
     3. 应用状态
     ====================================================================== */
  const STORE_KEY = 'myschedule.v1';

  /** 节假日（演示数据，可替换为真实数据源） */
  const HOLIDAYS = {
    '2026-09-25': '中秋节',
    '2026-10-01': '国庆节',
    '2026-10-02': '国庆假期',
    '2026-10-03': '国庆假期'
  };

  let state = {
    view: 'month',                 // month | week | list
    anchor: new Date(),            // 当前视图基准日期
    selected: null,                // 月视图选中的日期 (Date)
    theme: 'light',                // light | night
    query: '',
    filterTag: 'all',
    filterScope: 'all'
  };

  /* --- 3a. 演示数据（模拟，非真实日程） --- */
  function seedData() {
    const y = 2026, m = 8; // 2026-09
    const E = (d, sh, sm, eh, em, title, tag, done = false) => ({
      id: uid(), date: `${y}-${pad2(m + 1)}-${pad2(d)}`,
      start: sh * 60 + sm, end: eh * 60 + em,
      title, tag, done, note: ''
    });
    return {
      events: [
        E(2,  2, 0,  3, 0,  'Morning run',    'focus'),
        E(3,  2, 0,  3, 0,  'Deep work',      'focus'),
        E(4,  2, 0,  3, 0,  'Morning run',    'focus'),
        E(2,  7, 30, 9, 0,  'Team Meeting',   'work'),
        E(3,  7, 30, 9, 0,  'Team Meeting',   'work'),
        E(5,  7, 30, 9, 0,  'Team Meeting',   'work'),
        E(2,  10, 0, 11, 0, 'Design Review',  'work'),
        E(3,  10, 0, 11, 0, 'Design Review',  'work'),
        E(4,  10, 0, 11, 0, 'Design Review',  'work'),
        E(2,  12, 0, 13, 0, 'Lunch',          'life'),
        E(3,  12, 0, 13, 0, 'Lunch',          'life'),
        E(4,  12, 0, 13, 0, 'Lunch',          'life'),
        E(5,  12, 0, 13, 0, 'Lunch',          'life'),
        E(4,  15, 0, 16, 30,'Project Sync',   'work'),
        E(5,  15, 0, 16, 30,'Project Sync',   'work'),
        E(4,  18, 0, 19, 30,'Yoga Class',     'life'),
        E(23, 9, 0, 10, 0,  'Ideation',       'work',  true),
        E(23, 14, 0, 15, 0, 'Thesis draft',   'focus', true),
        E(23, 16, 30, 17, 30,'Reading group', 'work'),
        E(24, 11, 0, 12, 0, 'Advisor call',   'work'),
        E(26, 9, 0, 12, 0,  'Weekend lab',    'focus'),
        E(28, 13, 0, 15, 0, 'Paper revision', 'focus')
      ],
      tasks: [
        { id: uid(), text: 'Task and task-sheet description tasks', done: false, due: null,    tag: 'task' },
        { id: uid(), text: 'Task production staff for compiling',    done: false, due: null,    tag: 'task' },
        { id: uid(), text: '整理本周会议纪要',                        done: true,  due: '2026-09-23', tag: 'task' },
        { id: uid(), text: '提交读书报告终稿',                        done: false, due: '2026-09-26', tag: 'task' }
      ]
    };
  }

  let db = load();

  function uid() { return 'id-' + Math.random().toString(36).slice(2, 10); }

  function load() {
    try {
      const raw = localStorage.getItem(STORE_KEY);
      if (raw) {
        const d = JSON.parse(raw);
        if (d && Array.isArray(d.events) && Array.isArray(d.tasks)) return d;
      }
    } catch (e) { /* 存储不可用时退回内存模式 */ }
    const fresh = seedData();
    save(fresh);
    return fresh;
  }

  function save(data = db) {
    try { localStorage.setItem(STORE_KEY, JSON.stringify(data)); }
    catch (e) { /* 忽略：隐私模式或配额不足 */ }
  }

  /* ======================================================================
     4. 查询助手
     ====================================================================== */
  const eventsOn = d => {
    const key = ymd(d);
    return db.events
      .filter(e => e.date === key)
      .sort((a, b) => a.start - b.start);
  };

  const holidayOf = d => HOLIDAYS[ymd(d)] || null;
  const isWeekend = d => d.getDay() === 0 || d.getDay() === 6;

  function monthGrid(anchor) {
    const first = new Date(anchor.getFullYear(), anchor.getMonth(), 1);
    const gridStart = startOfWeek(first);
    return Array.from({ length: 42 }, (_, i) => addDays(gridStart, i));
  }

  function weekDays(anchor) {
    const s = startOfWeek(anchor);
    return Array.from({ length: 7 }, (_, i) => addDays(s, i));
  }

  /* ======================================================================
     5. 渲染
     ====================================================================== */
  const el = {
    app:        $('#app'),
    navItems:   $$('.nav__item[data-view]'),
    tabItems:  $$('.tabbar__btn[data-view]'),
    title:      $('#win-title'),
    heroDate:   $('#hero-date'),
    heroStats:  $('#hero-stats'),
    ringTime:   $('#ring-time'),
    ringDial:   $('#ring-dial'),
    calLabel:   $('#cal-label'),
    calPeriod:  $('#cal-period'),
    calNote:    $('#cal-note'),
    body:       $('#body'),
    viewRoot:   $('#view-root'),
    statusCount:$('#status-count'),
    ringLabel:  $('#ring-label')
  };

  const WEEK_LABEL = { month: 'Month view', week: 'Week view', list: 'List view' };

  function render() {
    document.documentElement.dataset.theme = state.theme;

    // 标题栏
    const viewName = WEEK_LABEL[state.view];
    el.title.textContent = `Main window — ${viewName}`;

    // 导航选中态
    el.navItems.forEach(b => {
      const on = b.dataset.view === state.view;
      b.setAttribute('aria-current', on ? 'page' : 'false');
    });
    el.tabItems.forEach(b => b.setAttribute('aria-selected', String(b.dataset.view === state.view)));

    // 顶栏视图切换
    $$('.seg__btn').forEach(b => b.setAttribute('aria-selected', String(b.dataset.view === state.view)));

    // Hero
    const now = state.anchor;
    el.heroDate.textContent =
      `${DOW_EN[(now.getDay() + 6) % 7]}, ${MON_EN[now.getMonth()].slice(0, 3)} ${pad2(now.getDate())} ${now.getFullYear()} ${pad2(new Date().getHours())}:${pad2(new Date().getMinutes())}`;

    const week = weekDays(now);
    const doneCount = db.events.filter(e => e.done).length;
    const pct = db.events.length ? Math.round((doneCount / db.events.length) * 100) : 0;
    el.heroStats.innerHTML =
      `Week done <b>${doneCount}/${db.events.length}</b> (${pct}%) · Focus <b>7.6h</b>`;

    // 状态栏
    const taskOpen = db.tasks.filter(t => !t.done).length;
    el.statusCount.innerHTML =
      `<b>${db.events.length}</b> events · <b>${db.tasks.length}</b> tasks`;

    // 主体：只替换视图容器，保留 hero 与日历导航条
    el.viewRoot.innerHTML = '';
    let node;
    if (state.view === 'month')      node = renderMonth();
    else if (state.view === 'week')  node = renderWeek();
    else                             node = renderList();
    el.viewRoot.appendChild(node);

    renderCalbar();
  }

  /* ---------- 5a. 日历导航条 ---------- */
  function renderCalbar() {
    const a = state.anchor;
    if (state.view === 'month') {
      el.calLabel.textContent = 'This month';
      el.calPeriod.textContent = `${MON_EN[a.getMonth()]} ${a.getFullYear()}`;
      const n = monthGrid(a).filter(d => d.getMonth() === a.getMonth() && holidayOf(d)).length;
      el.calNote.textContent = n ? `${n} holidays this month` : '';
    } else if (state.view === 'week') {
      const ws = weekDays(a);
      el.calLabel.textContent = 'This week';
      el.calPeriod.textContent =
        `${MON_EN[ws[0].getMonth()].slice(0,3)} ${ws[0].getDate()} – ${MON_EN[ws[6].getMonth()].slice(0,3)} ${ws[6].getDate()}`;
      const names = ws.filter(holidayOf).map(d => `${d.getMonth() + 1}/${d.getDate()} ${holidayOf(d)}`);
      el.calNote.textContent = names.join(' · ');
    } else {
      el.calLabel.textContent = 'All';
      el.calPeriod.textContent = `${MON_EN[a.getMonth()]} ${a.getFullYear()}`;
      el.calNote.textContent = '';
    }
  }

  /* ---------- 5b. 月视图 ---------- */
  function renderMonth() {
    const wrap = document.createElement('div');
    wrap.className = 'month surface';

    // 星期表头
    const head = document.createElement('div');
    head.className = 'month__head';
    DOW_EN.forEach((d, i) => {
      const c = document.createElement('div');
      c.className = 'month__dow' + (i >= 5 ? ' month__dow--weekend' : '');
      c.textContent = d;
      head.appendChild(c);
    });
    wrap.appendChild(head);

    // 日期网格
    const grid = document.createElement('div');
    grid.className = 'month__grid';
    const today = new Date();
    const month = state.anchor.getMonth();

    monthGrid(state.anchor).forEach(d => {
      const inMonth = d.getMonth() === month;
      const evts = eventsOn(d);
      const holi = holidayOf(d);

      const cell = document.createElement('button');
      cell.type = 'button';
      cell.className = 'day';
      cell.dataset.date = ymd(d);
      if (isWeekend(d))           cell.classList.add('day--weekend');
      if (!inMonth)               cell.classList.add('day--outside');
      if (sameDay(d, today))      cell.classList.add('day--today');
      if (state.selected && sameDay(d, state.selected)) cell.classList.add('day--selected');
      if (holi)                   cell.classList.add('day--holiday');
      cell.setAttribute('aria-label',
        `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日${DOW_ZH[(d.getDay() + 6) % 7]}，${evts.length} 项日程${holi ? '，' + holi : ''}`);

      // 日期数字
      const num = document.createElement('span');
      num.className = 'day__num';
      num.textContent = d.getDate();
      cell.appendChild(num);

      // 日程摘要（对应参考图的划线文字与浅色条）
      const marks = document.createElement('div');
      marks.className = 'day__marks';
      evts.slice(0, 3).forEach(e => {
        const chip = document.createElement('span');
        if (e.done) {
          chip.className = 'chip chip--done';
          chip.textContent = e.title;
          chip.style.textDecoration = 'line-through';
        } else if (e.tag === 'focus' || e.tag === 'life') {
          chip.className = 'chip chip--soft';
          chip.setAttribute('aria-hidden', 'true');
        } else {
          chip.className = 'chip';
          chip.textContent = e.title;
        }
        marks.appendChild(chip);
      });
      if (evts.length > 3) {
        const more = document.createElement('span');
        more.className = 'chip chip--more';
        more.textContent = `+${evts.length - 3}`;
        marks.appendChild(more);
      }
      cell.appendChild(marks);

      // 节日角标
      if (holi) {
        const corner = document.createElement('span');
        corner.className = 'corner px';
        corner.style.color = 'var(--accent-holiday)';
        corner.innerHTML = ICON.ribbon;
        corner.title = holi;
        cell.appendChild(corner);
      }

      grid.appendChild(cell);
    });
    wrap.appendChild(grid);

    // 页脚统计
    const foot = document.createElement('div');
    foot.className = 'month__foot';
    const monthEvents = db.events.filter(e => e.date.startsWith(
      `${state.anchor.getFullYear()}-${pad2(state.anchor.getMonth() + 1)}`));
    foot.innerHTML = `<b>${monthEvents.length}</b> events · <b>${db.tasks.length}</b> tasks`;
    wrap.appendChild(foot);

    return wrap;
  }

  /* ---------- 5c. 周视图 ---------- */
  const DAY_START = 0;    // 00:00
  const DAY_END   = 24;   // 24:00

  function renderWeek() {
    const wrap = document.createElement('div');
    wrap.className = 'week surface';

    const today = new Date();
    const days = weekDays(state.anchor);

    // 表头
    const head = document.createElement('div');
    head.className = 'week__head';
    head.appendChild(document.createElement('div')); // 时间列占位
    days.forEach(d => {
      const c = document.createElement('div');
      c.className = 'week__headcell';
      if (isWeekend(d))      c.classList.add('week__headcell--weekend');
      if (sameDay(d, today)) c.classList.add('week__headcell--today');
      const dow = document.createElement('div');
      dow.className = 'week__dow';
      dow.textContent = DOW_EN[(d.getDay() + 6) % 7];
      const dt = document.createElement('div');
      dt.className = 'week__date';
      dt.textContent = `${d.getMonth() + 1}/${d.getDate()}`;
      c.append(dow, dt);
      const holi = holidayOf(d);
      if (holi) {
        const r = document.createElement('div');
        r.className = 'ribbon';
        r.textContent = holi.length > 4 ? 'off' : holi;
        c.appendChild(r);
      }
      head.appendChild(c);
    });
    wrap.appendChild(head);

    // 时间网格
    const scroll = document.createElement('div');
    scroll.className = 'week__body';
    const canvas = document.createElement('div');
    canvas.className = 'week__canvas';

    // 小时刻度
    const gutter = document.createElement('div');
    gutter.className = 'week__gutter';
    for (let h = DAY_START; h <= DAY_END; h++) {
      const t = document.createElement('div');
      t.className = 'week__hour';
      t.textContent = `${pad2(h)}:00`;
      gutter.appendChild(t);
    }
    canvas.appendChild(gutter);

    // 每日列
    const hours = DAY_END - DAY_START;
    days.forEach(d => {
      const col = document.createElement('div');
      col.className = 'week__col';
      if (isWeekend(d))      col.classList.add('week__col--weekend');
      if (sameDay(d, today)) col.classList.add('week__col--today');

      for (let h = 0; h < hours; h++) {
        const slot = document.createElement('div');
        slot.className = 'week__slot';
        col.appendChild(slot);
      }

      // 事件卡：按分钟定位，重叠时并排
      const dayEvents = eventsOn(d);
      const laid = layoutOverlaps(dayEvents);
      const total = hours * 60;
      laid.forEach(({ evt, lane, lanes }) => {
        const card = document.createElement('button');
        card.type = 'button';
        card.className = 'evt';
        if (evt.tag === 'focus' || evt.tag === 'life') card.classList.add('evt--focus');
        if (evt.tag === 'work')                        card.classList.add('evt--event');
        const dur = evt.end - evt.start;
        if (dur <= 45) card.classList.add('evt--short');

        const top    = ((evt.start - DAY_START * 60) / total) * 100;
        const height = (dur / total) * 100;
        const width  = 100 / lanes;

        card.style.top    = top + '%';
        card.style.height = `max(${height}%, 20px)`;
        card.style.left   = `calc(${lane * width}% + 2px)`;
        card.style.right  = `calc(${100 - (lane + 1) * width}% + 2px)`;

        card.innerHTML = `<span class="evt__time">${minToHHMM(evt.start)}–${minToHHMM(evt.end)}</span>${escapeHtml(evt.title)}`;
        card.dataset.id = evt.id;
        card.title = `${evt.title}\n${minToHHMM(evt.start)} – ${minToHHMM(evt.end)}`;
        col.appendChild(card);
      });

      canvas.appendChild(col);
    });

    scroll.appendChild(canvas);

    // 当前时刻指示线（仅当本周包含今天时显示）
    const todayIdx = days.findIndex(d => sameDay(d, today));
    if (todayIdx >= 0) {
      const now = new Date();
      const mins = now.getHours() * 60 + now.getMinutes();
      const line = document.createElement('div');
      line.className = 'nowline';
      line.dataset.time = minToHHMM(mins);
      line.style.top = `${(mins / (hours * 60)) * 100}%`;
      // 指示点落在「今天」那一列的左边缘
      line.style.setProperty('--now-col', String(todayIdx));
      canvas.appendChild(line);
      // 自动滚动到当前时段，便于一眼看到「现在」
      requestAnimationFrame(() => {
        const slot = canvas.querySelector('.week__slot');
        const h = (slot && slot.offsetHeight) || 32;
        scroll.scrollTop = Math.max(0, (mins / 60) * h - scroll.clientHeight / 3);
      });
    }
    wrap.appendChild(scroll);

    // 页脚
    const foot = document.createElement('div');
    foot.className = 'month__foot';
    const weekEventCount = days.reduce((s, d) => s + eventsOn(d).length, 0);
    foot.innerHTML = `<b>${weekEventCount}</b> events · <b>${db.tasks.length}</b> tasks`;
    wrap.appendChild(foot);

    return wrap;
  }

  /** 简单的重叠分道算法 */
  function layoutOverlaps(list) {
    if (!list.length) return [];
    const sorted = [...list].sort((a, b) => a.start - b.start || a.end - b.end);
    const clusters = [];
    let cur = [], curEnd = -1;
    sorted.forEach(e => {
      if (cur.length && e.start >= curEnd) { clusters.push(cur); cur = []; curEnd = -1; }
      cur.push(e);
      curEnd = Math.max(curEnd, e.end);
    });
    if (cur.length) clusters.push(cur);

    const out = [];
    clusters.forEach(cluster => {
      const laneEnds = [];
      const placed = cluster.map(e => {
        let lane = laneEnds.findIndex(end => end <= e.start);
        if (lane === -1) { lane = laneEnds.length; laneEnds.push(e.end); }
        else laneEnds[lane] = e.end;
        return { evt: e, lane };
      });
      placed.forEach(p => out.push({ ...p, lanes: laneEnds.length }));
    });
    return out;
  }

  /* ---------- 5d. 列表视图 ---------- */
  function renderList() {
    const wrap = document.createElement('div');
    wrap.className = 'list surface';

    /* ---- 左：事件列表 ---- */
    const main = document.createElement('div');
    main.className = 'list__main';

    // 过滤栏
    const filters = document.createElement('div');
    filters.className = 'list__filters';
    filters.innerHTML = `
      <label class="search">
        ${ICON.search}
        <input id="q" type="search" placeholder="Search events / tags" value="${escapeAttr(state.query)}" aria-label="搜索日程" />
      </label>
      <select class="select" id="f-scope" aria-label="范围">
        <option value="all">All tasks</option>
        <option value="week">This week</option>
        <option value="month">This month</option>
      </select>
      <select class="select" id="f-order" aria-label="排序">
        <option value="date">Manual</option>
        <option value="title">By title</option>
        <option value="tag">By tag</option>
      </select>
      <select class="select" id="f-tag" aria-label="标签">
        <option value="all">All tags</option>
        <option value="work">Work</option>
        <option value="focus">Focus</option>
        <option value="life">Life</option>
      </select>`;
    main.appendChild(filters);

    // 事件行
    const scroll = document.createElement('div');
    scroll.className = 'list__scroll';

    let list = db.events.slice();
    const q = state.query.trim().toLowerCase();
    if (q) list = list.filter(e => e.title.toLowerCase().includes(q) || e.tag.toLowerCase().includes(q));
    if (state.filterTag !== 'all') list = list.filter(e => e.tag === state.filterTag);
    if (state.filterScope === 'week') {
      const wk = new Set(weekDays(state.anchor).map(ymd));
      list = list.filter(e => wk.has(e.date));
    } else if (state.filterScope === 'month') {
      const pre = `${state.anchor.getFullYear()}-${pad2(state.anchor.getMonth() + 1)}`;
      list = list.filter(e => e.date.startsWith(pre));
    }
    list.sort((a, b) => a.date.localeCompare(b.date) || a.start - b.start);

    if (!list.length) {
      scroll.appendChild(emptyState(
        'No events found',
        q ? `没有匹配「${state.query}」的日程，试试其他关键词。` : '当前筛选条件下暂无日程。'));
    } else {
      const groups = new Map();
      list.forEach(e => {
        if (!groups.has(e.date)) groups.set(e.date, []);
        groups.get(e.date).push(e);
      });
      groups.forEach((items, date) => {
        const d = parseYmd(date);
        const g = document.createElement('div');
        g.className = 'list__daygroup';
        g.innerHTML = `${DOW_ZH[(d.getDay() + 6) % 7]} · ${d.getMonth() + 1}月${d.getDate()}日 <span>${items.length} 项</span>`;
        scroll.appendChild(g);

        items.forEach(e => {
          const row = document.createElement('button');
          row.type = 'button';
          row.className = 'row';
          row.dataset.id = e.id;
          const tagCls = e.tag === 'work' ? 'tag--event' : e.tag === 'focus' ? 'tag--focus' : 'tag--task';
          const tagLabel = e.tag === 'work' ? 'Work' : e.tag === 'focus' ? 'Focus' : 'Life';
          row.innerHTML = `
            <span class="row__time">${minToHHMM(e.start)}–${minToHHMM(e.end)}</span>
            <span class="row__title ${e.done ? 'row__title--done' : ''}">${escapeHtml(e.title)}</span>
            <span class="row__tags">
              <span class="tag ${tagCls}">${tagLabel}</span>
              <span class="tag tag--task">${e.date}</span>
            </span>`;
          scroll.appendChild(row);
        });
      });
    }
    main.appendChild(scroll);
    wrap.appendChild(main);

    /* ---- 右：任务栏 ---- */
    const aside = document.createElement('div');
    aside.className = 'list__aside';
    const open = db.tasks.filter(t => !t.done).length;
    aside.innerHTML = `
      <div class="list__asidehead"><span>Tasks</span><span>${open} open</span></div>`;
    const ascroll = document.createElement('div');
    ascroll.className = 'list__asidescroll';
    if (!db.tasks.length) {
      ascroll.appendChild(emptyState('No tasks', '还没有任务，点击 + Event 添加。'));
    } else {
      db.tasks.forEach(t => {
        const row = document.createElement('div');
        row.className = 'task';
        row.dataset.done = String(t.done);
        row.dataset.id = t.id;
        const dueToday = t.due === ymd(new Date());
        row.innerHTML = `
          <button class="task__box" type="button" aria-label="切换完成状态" aria-pressed="${t.done}">${ICON.check}</button>
          <div class="task__text">${escapeHtml(t.text)}</div>
          <div class="task__due ${dueToday ? 'task__due--today' : ''}">${t.due ? (dueToday ? 'Today' : t.due.slice(5)) : 'No due'}</div>`;
        ascroll.appendChild(row);
      });
    }
    aside.appendChild(ascroll);
    wrap.appendChild(aside);

    return wrap;
  }

  /* ---------- 5e. 空状态 ---------- */
  function emptyState(title, hint) {
    const d = document.createElement('div');
    d.className = 'empty';
    d.innerHTML = `
      <div class="empty__art">${ICON.doc}</div>
      <div class="empty__title">${escapeHtml(title)}</div>
      <div class="empty__hint">${escapeHtml(hint)}</div>`;
    return d;
  }

  const escapeHtml = s => String(s).replace(/[&<>"']/g, c =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const escapeAttr = escapeHtml;

  /* ======================================================================
     6. 交互绑定
     ====================================================================== */
  function bind() {
    /* --- 视图切换（顶栏分段 + 侧栏 + 底部标签栏） --- */
    document.addEventListener('click', ev => {
      const vBtn = ev.target.closest('[data-view]');
      if (vBtn) { state.view = vBtn.dataset.view; render(); return; }

      // 月视图：选中日期（不改变当前显示月份，切换月份用 ‹ › 或「This month」）
      const day = ev.target.closest('.day');
      if (day) {
        const picked = parseYmd(day.dataset.date);
        const monthChanged = picked.getMonth() !== state.anchor.getMonth()
          || picked.getFullYear() !== state.anchor.getFullYear();
        state.selected = picked;
        // 点相邻月份的灰格才翻月，点当月格子只做选中
        if (monthChanged) state.anchor = new Date(picked);
        render();
        return;
      }

      // 列表：点击事件行 → 打开编辑
      const row = ev.target.closest('.row');
      if (row) { openEditor(db.events.find(e => e.id === row.dataset.id)); return; }

      // 周视图：点击事件卡
      const card = ev.target.closest('.evt');
      if (card) { openEditor(db.events.find(e => e.id === card.dataset.id)); return; }

      // 任务勾选
      const box = ev.target.closest('.task__box');
      if (box) {
        const wrap = box.closest('.task');
        const t = db.tasks.find(x => x.id === wrap.dataset.id);
        if (t) { t.done = !t.done; save(); render(); }
        return;
      }
    });

    /* --- 上一/下一 / 回到今天 --- */
    $('#nav-prev').addEventListener('click', () => {
      if (state.view === 'week') state.anchor = addDays(state.anchor, -7);
      else if (state.view === 'month') state.anchor = addMonths(state.anchor, -1);
      else state.anchor = addMonths(state.anchor, -1);
      render();
    });
    $('#nav-next').addEventListener('click', () => {
      if (state.view === 'week') state.anchor = addDays(state.anchor, 7);
      else state.anchor = addMonths(state.anchor, 1);
      render();
    });
    $('#cal-label').addEventListener('click', () => {
      state.anchor = new Date();
      state.selected = new Date();
      render();
    });

    /* --- 主题切换 --- */
    const themeBtn = $('#btn-theme');
    themeBtn.addEventListener('click', () => {
      state.theme = state.theme === 'night' ? 'light' : 'night';
      themeBtn.innerHTML = (state.theme === 'night' ? ICON.sun : ICON.moon) +
        `<span>${state.theme === 'night' ? 'Day' : 'Night'}</span>`;
      render();
    });

    /* --- 新增日程 --- */
    $('#btn-add').addEventListener('click', () => openEditor(null));

    /* --- 列表筛选 --- */
    document.addEventListener('input', ev => {
      if (ev.target.id === 'q') { state.query = ev.target.value; softRerenderList(ev.target); }
    });
    document.addEventListener('change', ev => {
      const id = ev.target.id;
      if (id === 'f-tag')   { state.filterTag = ev.target.value; render(); }
      if (id === 'f-scope') { state.filterScope = ev.target.value; render(); }
      if (id === 'f-order') { render(); }
      if (id === 'f-date')  { /* 编辑器中处理 */ }
    });

    /* --- 键盘快捷键 --- */
    document.addEventListener('keydown', ev => {
      const t = ev.target;
      // 仅在非输入控件、且目标为元素时响应（合成事件或 document 目标会缺少 matches）
      if (t && typeof t.matches === 'function' && t.matches('input, textarea, select, [contenteditable]')) return;
      if (t && t.isContentEditable) return;

      const k = ev.key.toLowerCase();
      if (k === 'm') { state.view = 'month'; render(); }
      else if (k === 'w') { state.view = 'week';  render(); }
      else if (k === 'l') { state.view = 'list';  render(); }
      else if (k === 'n') { ev.preventDefault(); openEditor(null); }
      else if (k === 't') { state.anchor = new Date(); state.selected = new Date(); render(); }
      else if (ev.key === 'ArrowLeft')  $('#nav-prev').click();
      else if (ev.key === 'ArrowRight') $('#nav-next').click();
      else if (ev.key === 'Escape' && !$('#modal').hidden) closeModal();
    });

    /* --- 模态框关闭 --- */
    $('#modal-close').addEventListener('click', closeModal);
    $('#modal-cancel').addEventListener('click', closeModal);
    $('#modal').addEventListener('click', ev => { if (ev.target.id === 'modal') closeModal(); });
    $('#event-form').addEventListener('submit', ev => { ev.preventDefault(); saveFromForm(); });
    $('#btn-delete').addEventListener('click', deleteCurrent);

    /* --- 标签选择 --- */
    $('#tag-chips').addEventListener('click', ev => {
      const b = ev.target.closest('.chipbtn');
      if (!b) return;
      $$('#tag-chips .chipbtn').forEach(x => x.setAttribute('aria-pressed', 'false'));
      b.setAttribute('aria-pressed', 'true');
    });
  }

  /** 搜索时只重绘列表主体，避免输入框失焦 */
  function softRerenderList(input) {
    const pos = input.selectionStart;
    render();
    const next = $('#q');
    if (next) { next.focus(); next.setSelectionRange(pos, pos); }
  }

  /* ======================================================================
     7. 事件编辑器
     ====================================================================== */
  let editingId = null;

  function openEditor(evt) {
    editingId = evt ? evt.id : null;
    $('#modal-title').textContent = evt ? '编辑日程' : '新建日程';
    $('#btn-delete').hidden = !evt;
    $('#f-title').value = evt ? evt.title : '';
    $('#f-date').value  = evt ? evt.date : ymd(state.selected || state.anchor);
    $('#f-start').value = evt ? minToHHMM(evt.start) : '09:00';
    $('#f-end').value   = evt ? minToHHMM(evt.end)   : '10:00';
    $('#f-note').value  = evt ? (evt.note || '') : '';
    const tag = evt ? evt.tag : 'work';
    $$('#tag-chips .chipbtn').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.tag === tag)));
    $('#f-done').checked = evt ? !!evt.done : false;

    $('#modal').hidden = false;
    requestAnimationFrame(() => $('#f-title').focus());
  }

  function closeModal() {
    $('#modal').hidden = true;
    editingId = null;
  }

  function saveFromForm() {
    const title = $('#f-title').value.trim();
    if (!title) { toast('请填写日程标题'); $('#f-title').focus(); return; }

    const date  = $('#f-date').value || ymd(new Date());
    const start = toMin($('#f-start').value);
    const end   = Math.max(toMin($('#f-end').value), start + 15);
    const tagEl = $('#tag-chips .chipbtn[aria-pressed="true"]');
    const tag   = tagEl ? tagEl.dataset.tag : 'work';

    if (editingId) {
      const e = db.events.find(x => x.id === editingId);
      Object.assign(e, { title, date, start, end, tag, note: $('#f-note').value, done: $('#f-done').checked });
      toast('日程已更新');
    } else {
      db.events.push({ id: uid(), title, date, start, end, tag, note: $('#f-note').value, done: $('#f-done').checked });
      toast('日程已添加');
    }
    save();
    render();
    closeModal();
  }

  function deleteCurrent() {
    if (!editingId) return;
    db.events = db.events.filter(e => e.id !== editingId);
    save();
    render();
    closeModal();
    toast('日程已删除');
  }

  const toMin = v => {
    const [h, m] = String(v).split(':').map(Number);
    return (h || 0) * 60 + (m || 0);
  };

  /* ======================================================================
     8. 提示条
     ====================================================================== */
  let toastTimer = null;
  function toast(msg) {
    const t = $('#toast');
    t.textContent = msg;
    t.classList.add('toast--on');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => t.classList.remove('toast--on'), 1800);
  }

  /* ======================================================================
     9. 启动
     ====================================================================== */
  function boot() {
    // 支持 ?view=week&theme=night&date=2026-09-23 便于预览与调试
    const qs = new URLSearchParams(location.search);
    if (['month', 'week', 'list'].includes(qs.get('view'))) state.view = qs.get('view');
    if (['light', 'night'].includes(qs.get('theme')))       state.theme = qs.get('theme');

    document.documentElement.dataset.theme = state.theme;
    if (state.theme === 'night') {
      const tb = $('#btn-theme');
      tb.innerHTML = ICON.sun + '<span>Day</span>';
    }

    // 初始定位：URL 指定日期 > 示例数据首条 > 今天
    const wantDate = qs.get('date');
    if (wantDate) {
      state.anchor = parseYmd(wantDate);
    } else {
      const first = db.events[0];
      state.anchor = first ? parseYmd(first.date) : new Date();
    }
    state.selected = new Date(state.anchor);

    bind();
    render();

    // 每分钟刷新「当前时刻」相关显示
    setInterval(() => { if (state.view !== 'month') render(); }, 60000);
  }

  document.readyState === 'loading'
    ? document.addEventListener('DOMContentLoaded', boot)
    : boot();
})();
