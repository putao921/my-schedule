/* View rendering.
 *
 * Every view is a pure function of Store state: render(container) rebuilds its
 * subtree from scratch. With a few hundred records that is cheaper than
 * diffing, and it removes a whole class of stale-DOM bugs.
 */
(function () {
  'use strict';

  /* ---- i18n helpers (used by views and app alike) ---------------------- */
  window.lang = function () {
    return (window.Store && Store.settings.lang) || window.I18N_DEFAULT || 'zh';
  };

  window.t = function (key) {
    var bundle = (window.I18N || {})[window.lang()] || {};
    var en = (window.I18N || {}).en || {};
    /* Missing key in the active language falls back to English, then to the
       key itself -- a raw key on screen is ugly but never a crash. */
    if (Object.prototype.hasOwnProperty.call(bundle, key)) return bundle[key];
    if (Object.prototype.hasOwnProperty.call(en, key)) return en[key];
    return key;
  };

  /* .NET-style {0}/{1:00} placeholders. */
  window.fmt = function (str) {
    var args = Array.prototype.slice.call(arguments, 1);
    return String(str).replace(/\{(\d+)(?::(\d+))?\}/g, function (m, idx, pad) {
      var v = args[parseInt(idx, 10)];
      if (v === undefined || v === null) return '';
      if (pad) {
        var n = String(v);
        while (n.length < parseInt(pad, 10)) n = '0' + n;
        return n;
      }
      return String(v);
    });
  };

  var DOW_ZH = ['一', '二', '三', '四', '五', '六', '日'];
  var DOW_EN = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  var MON_ZH = ['1月', '2月', '3月', '4月', '5月', '6月', '7月', '8月', '9月', '10月', '11月', '12月'];
  var MON_EN = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  function dowNames() { return window.lang() === 'zh' ? DOW_ZH : DOW_EN; }
  function monNames() { return window.lang() === 'zh' ? MON_ZH : MON_EN; }

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  /* ---- tags ----------------------------------------------------------- */
  /* Tag colours live in settings so users can rename/recolor them; every chip
     and dot therefore reads the palette variable at render time. */
  var PALETTE = [
    ['--accent', 'accent'],
    ['--accent-warm', 'warm'],
    ['--accent-cool', 'cool'],
    ['--holiday', 'holiday'],
    ['--ink-soft', 'muted']
  ];

  function tagList() {
    var t = (window.Store && Store.settings.tags) || [];
    return Array.isArray(t) && t.length ? t
      : [{ key: 'work', color: '--accent' }];
  }

  function tagColor(tag) {
    var list = tagList();
    for (var i = 0; i < list.length; i++) {
      if (list[i].key === tag) return list[i].color || '--accent';
    }
    return '--accent';
  }

  function tagNames() {
    return tagList().map(function (x) { return x.key; });
  }

  /* ---- search --------------------------------------------------------- */
  /* One query filters every list-shaped view; month/week keep their shape and
     simply drop non-matching records. */
  var query = '';
  function setQuery(q) { query = String(q || '').trim().toLowerCase(); }
  function getQuery() { return query; }

  function matches(hay) {
    if (!query) return true;
    return String(hay || '').toLowerCase().indexOf(query) !== -1;
  }
  function matchEvent(e) {
    return matches((e.title || '') + ' ' + (e.note || '') + ' ' + (e.tag || ''));
  }
  function matchTask(t) {
    return matches((t.text || '') + ' ' + (t.project || '') + ' ' + (t.priority || ''));
  }

  /* ------------------------------------------------------------ helpers -- */
  function eventCard(e) {
    return '<div class="card card-row" data-ev="' + e.id + '">' +
      '<button class="tick' + (e.done ? ' on' : '') + '" data-act="toggle-ev" data-id="' + e.id + '">&#10003;</button>' +
      '<span class="grow">' +
      '<div class="ev-title' + (e.done ? ' done' : '') + '">' + esc(e.title || t('gen.untitled')) + '</div>' +
      '<div class="ev-meta">' + Store.hhmm(e.start) + '-' + Store.hhmm(e.end) + '</div>' +
      '</span>' +
      '<span class="chip" data-tag="' + esc(e.tag) + '" style="background:var(' + tagColor(e.tag) + ')">' +
      esc(e.tag) + '</span>' +
      '<div class="row-actions">' +
      '<button class="mini-btn" data-act="edit-ev" data-id="' + e.id + '">' + esc(t('btn.edit')) + '</button>' +
      '</div>' +
      '</div>';
  }

  /* NOTE: the parameter is named t to match the desktop app's record naming,
     which shadows the global t() translator -- so every translated string in
     here goes through window.t explicitly. Getting this wrong throws inside
     every task list, which is how the self test caught it. */
  function taskCard(t) {
    return '<div class="card card-row" data-task="' + t.id + '">' +
      '<button class="tick' + (t.done ? ' on' : '') + '" data-act="toggle-task" data-id="' + t.id + '">&#10003;</button>' +
      '<span class="grow">' +
      '<div class="ev-title' + (t.done ? ' done' : '') + '">' + esc(t.text || window.t('gen.untitled')) + '</div>' +
      '<div class="ev-meta">' + (t.due ? esc(t.due) + ' ' + esc(t.dueTime || '') : '') +
      ' · ' + esc(t.project || 'Inbox') + ' · ' + esc(t.priority || 'medium') + '</div>' +
      '</span>' +
      '<div class="row-actions">' +
      '<button class="mini-btn" data-act="edit-task" data-id="' + t.id + '">' + esc(window.t('btn.edit')) + '</button>' +
      '</div>' +
      '</div>';
  }

  function emptyBox(text) {
    return '<div class="empty">' + esc(text) + '</div>';
  }

  /* A reusable header with prev / next / today controls so the month and week
     views can be scrolled to any period, not just the one containing today.
     `cursor` (owned by app.js) is the anchor; the buttons dispatch data-act
     events that app.js turns into cursor moves. */
  function calNav(title, sub) {
    return '<div class="sec-head cal-nav">' +
      '<button class="cal-btn" data-act="cal-prev" aria-label="' + esc(t('cal.prev')) +
        '" title="' + esc(t('cal.prev')) + '">‹</button>' +
      '<div class="cal-title"><h3>' + esc(title) + '</h3>' +
        (sub ? '<span class="sub">' + esc(sub) + '</span>' : '') + '</div>' +
      '<button class="cal-btn" data-act="cal-next" aria-label="' + esc(t('cal.next')) +
        '" title="' + esc(t('cal.next')) + '">›</button>' +
      '<button class="cal-today" data-act="cal-today">' + esc(t('nav.today')) + '</button>' +
      '</div>';
  }

  /* -------------------------------------------------------------- month -- */
  function renderMonth(el, cursor) {
    var cur = cursor || new Date();
    var y = cur.getFullYear(), m = cur.getMonth();
    var first = new Date(y, m, 1);
    var lead = (first.getDay() + 6) % 7;           // Monday-first
    var days = new Date(y, m + 1, 0).getDate();
    var todayS = Store.todayStr();

    var head = '<div class="month-head">';
    var dn = dowNames();
    for (var i = 0; i < 7; i++) head += '<div class="month-dow">' + dn[i] + '</div>';
    head += '</div>';

    var grid = '<div class="month-grid">';
    /* Leading cells from the previous month. */
    var prevDays = new Date(y, m, 0).getDate();
    for (var p = lead - 1; p >= 0; p--) {
      grid += cell(new Date(y, m - 1, prevDays - p), todayS, true);
    }
    for (var d = 1; d <= days; d++) grid += cell(new Date(y, m, d), todayS, false);
    /* Trailing cells so the grid always ends on a full row. */
    var used = lead + days;
    var tail = (7 - (used % 7)) % 7;
    for (var q = 1; q <= tail; q++) grid += cell(new Date(y, m + 1, q), todayS, true);
    grid += '</div>';

    var title = (window.lang() === 'zh')
      ? (y + '年' + MON_ZH[m])
      : (MON_EN[m] + ' ' + y);

    /* Two panes: the calendar and the agenda for the selected day. On wide
       screens the stylesheet lays them side by side; on phones they stack. */
    el.innerHTML =
      '<div class="month-split">' +
      '<div class="month-pane">' +
      calNav(title, t('view.month')) +
      head + grid + holidayLine(y, m) +
      '</div>' +
      '<div class="day-pane">' +
      '<div class="sec-head"><h3>' + esc(t('fld.day.title')) + '</h3>' +
      '<span class="sub">' + Store.iso(cur) +
      (lunarLabel(Store.iso(cur)) ? ' · ' + esc(lunarLabel(Store.iso(cur))) : '') +
      '</span></div>' +
      dayList(Store.iso(cur)) +
      '</div></div>';
  }

  /* A month cell shows three things: the day number, the lunar label (or the
     festival name when the day has one -- the festival is what people actually
     scan for), and up to three event dots. */
  function cell(date, todayS, out) {
    var s = Store.iso(date);
    var evs = Store.expandedEventsOn(s);
    var cls = 'day' + (out ? ' out' : '') + (s === todayS ? ' today' : '');
    var weekend = (date.getDay() === 0 || date.getDay() === 6);
    if (weekend && !out) cls += ' weekend';

    /* Out-of-month filler cells carry no lunar label: they exist only to keep
       the grid rectangular, and filling them would imply they are real days. */
    var info = (window.Lunar && !out) ? Lunar.dayInfo(s) : null;
    if (info && info.festival) cls += ' holi';

    var dots = '';
    for (var i = 0; i < Math.min(evs.length, 3); i++) {
      dots += '<div class="day-dot" data-tag="' + esc(evs[i].tag) + '" style="background:var(' +
        tagColor(evs[i].tag) + ')"></div>';
    }

    var lunar = '';
    if (info) {
      lunar = '<span class="day-lunar' + (info.festival ? ' fest' : '') + '">' +
        esc(info.festival || info.text) + '</span>';
    }

    return '<div class="' + cls + '" data-date="' + s + '">' +
      '<div class="day-top"><span class="day-num">' + date.getDate() + '</span>' + lunar + '</div>' +
      dots + '</div>';
  }

  /* "本月 N 个节假日" -- the count the desktop app shows under the calendar. */
  function holidayLine(y, m) {
    if (!window.Lunar) return '';
    var list = Lunar.festivalsIn(y, m);
    if (!list.length) return '';
    return '<div class="ev-meta hol-line">' +
      esc(fmt(t(list.length === 1 ? 'cal.holiday1' : 'cal.holidayN'), list.length)) +
      ' · ' + list.map(function (x) { return x.day + ' ' + x.name; }).join('、') +
      '</div>';
  }

  /* "八月十五 · 中秋节" -- one line, dropped entirely when there is nothing
     to say (before lunar.js loads, or outside its 1900-2100 range). */
  function lunarLabel(dateStr) {
    if (!window.Lunar) return '';
    var i = Lunar.dayInfo(dateStr);
    if (!i || !i.lunar) return '';
    return i.festival ? (i.full + ' · ' + i.festival) : i.full;
  }

  function dayList(dateStr) {
    var evs = Store.expandedEventsOn(dateStr).filter(matchEvent);
    if (!evs.length) return emptyBox(query ? t('search.none') : t('fld.day.empty'));
    var out = '';
    for (var i = 0; i < evs.length; i++) out += eventCard(evs[i]);
    return out;
  }

  /* --------------------------------------------------------------- week -- */
  function renderWeek(el, cursor) {
    var start = Store.startOfWeek(cursor || new Date());
    var dn = dowNames();
    var todayS = Store.todayStr();

    var hours = '';
    for (var h = 0; h < 24; h++) {
      hours += '<div class="week-hour">' + (h < 10 ? '0' : '') + h + '</div>';
    }

    var cols = '';
    for (var i = 0; i < 7; i++) {
      var d = new Date(start.getTime());
      d.setDate(d.getDate() + i);
      var s = Store.iso(d);
      var evs = Store.expandedEventsOn(s).filter(matchEvent);

      /* 24 slot cells give the column its height (blocks are absolutely
         positioned, so without them the column collapses to zero) and act as
         the drop grid for drag-to-reschedule. */
      var slots = '';
      for (var h2 = 0; h2 < 24; h2++) slots += '<div class="week-slot"></div>';

      var blocks = '';
      for (var j = 0; j < evs.length; j++) {
        var e = evs[j];
        /* Percentages, not pixels: the slot height changes per breakpoint, so
           a fixed 40px/hour would drift out of alignment on tablets. */
        var st = e.start || 0;
        var en = e.end !== undefined && e.end !== null ? e.end : st + 60;
        if (en <= st) en = st + 30;
        var topPct = (st / 1440) * 100;
        var hPct = ((en - st) / 1440) * 100;
        blocks += '<div class="wk-ev" style="top:' + topPct + '%;height:' + hPct +
          '%;background:var(' + tagColor(e.tag) + ');color:var(--on-accent)" ' +
          'data-ev="' + e.id + '" title="' + esc(e.title) + '">' +
          esc(e.title) + '</div>';
      }
      cols += '<div class="week-col' + (s === todayS ? ' today' : '') + '" data-date="' + s + '">' +
        slots + blocks + '</div>';
    }

    var head = '<div class="month-head">';
    for (var k = 0; k < 7; k++) {
      var hd = new Date(start.getTime());
      hd.setDate(hd.getDate() + k);
      var hs = Store.iso(hd);
      var hi = window.Lunar ? Lunar.dayInfo(hs) : null;
      head += '<div class="month-dow">' + dn[k] + '<br><span class="ev-meta">' + hd.getDate() +
        '</span>' + (hi ? '<span class="wk-lunar' + (hi.festival ? ' fest' : '') + '">' +
          esc(hi.festival || hi.text) + '</span>' : '') + '</div>';
    }
    head += '</div>';

    var wkEnd = new Date(start.getTime());
    wkEnd.setDate(wkEnd.getDate() + 6);
    var mn = monNames();
    var wkTitle = (window.lang() === 'zh')
      ? (mn[start.getMonth()] + start.getDate() + '日 – ' + mn[wkEnd.getMonth()] + wkEnd.getDate() + '日')
      : (mn[start.getMonth()] + ' ' + start.getDate() + ' – ' + mn[wkEnd.getMonth()] + ' ' + wkEnd.getDate());
    if (start.getFullYear() !== wkEnd.getFullYear()) {
      wkTitle = (window.lang() === 'zh')
        ? (start.getFullYear() + '年' + wkTitle)
        : (start.getFullYear() + ' · ' + wkTitle);
    }

    el.innerHTML =
      calNav(wkTitle, '') +
      head +
      '<div class="week-wrap"><div class="week-hours">' + hours + '</div>' +
      '<div class="week-cols">' + cols + '</div></div>';
  }

  /* --------------------------------------------------------------- list -- */
  function renderList(el, cursor) {
    var groups = {};
    Store.events.filter(matchEvent).forEach(function (e) {
      var k = e.date || Store.todayStr();
      (groups[k] = groups[k] || []).push(e);
    });
    var keys = Object.keys(groups).sort();
    if (!keys.length) { el.innerHTML = emptyBox(query ? t('search.none') : t('fld.day.empty')); return; }

    var out = '<div class="sec-head"><h3>' + esc(t('view.list')) + '</h3></div>';
    keys.forEach(function (k) {
      out += '<div class="sec-head"><h3>' + esc(k) + '</h3></div>';
      groups[k].sort(function (a, b) { return (a.start || 0) - (b.start || 0); })
        .forEach(function (e) { out += eventCard(e); });
    });
    el.innerHTML = out;
  }

  /* -------------------------------------------------------------- tasks -- */
  function renderTasks(el) {
    var open = Store.tasks.filter(function (t) { return !t.done; }).filter(matchTask);
    var done = Store.tasks.filter(function (t) { return t.done; }).filter(matchTask);
    var out = '<div class="sec-head"><h3>' + esc(t('view.tasks')) + '</h3>' +
      '<span class="sub">' + open.length + '</span></div>';

    if (!open.length && !done.length) {
      el.innerHTML = out + emptyBox(query ? t('search.none') : t('fld.day.empty'));
      return;
    }
    open.forEach(function (t) { out += taskCard(t); });
    if (done.length) {
      out += '<div class="sec-head"><h3>' + esc(t('task.doneHead')) + '</h3><span class="sub">' + done.length + '</span></div>';
      done.forEach(function (t) { out += taskCard(t); });
    }
    el.innerHTML = out;
  }

  /* ----------------------------------------------------------------- me -- */
  function renderMe(el) {
    var st = Store.stats();
    var out = '<div class="sec-head"><h3>' + esc(t('nav.profile')) + '</h3></div>';

    out += '<div class="card acct">' +
      '<img class="acct-av" id="acctAvatar" alt="" src="' +
      esc(Store.settings.avatar || 'icons/icon-192.png') + '">' +
      '<span class="grow"><div id="acctMail">' + esc(t('sync.notSignedIn')) + '</div>' +
      '<div class="acct-mail" id="acctState">' + esc(t('sync.localOnly')) + '</div></span>' +
      '</div>';

    out += '<div class="card">' +
      '<div class="ev-meta">' +
      esc(fmt(t('fld.st.totals'), Store.events.length, st.done,
        Store.tasks.filter(function (x) { return !x.done; }).length)) +
      '</div></div>';

    /* Sync controls: cloud.js fills in the real handlers. */
    out += '<div class="card">' +
      '<div class="card-row"><span class="grow"><b>' + esc(t('sync.title')) + '</b></span>' +
      '<span class="ev-meta" id="syncState">-</span></div>' +
      '<div class="card-row" style="margin-top:8px;flex-wrap:wrap;gap:8px">' +
      '<button class="btn btn-primary" data-act="sync-signin">' + esc(t('sync.signin')) + '</button>' +
      '<button class="btn" data-act="sync-push">' + esc(t('sync.upload')) + '</button>' +
      '<button class="btn" data-act="sync-pull">' + esc(t('sync.download')) + '</button>' +
      '<button class="btn btn-ghost" data-act="sync-out">' + esc(t('sync.signout')) + '</button>' +
      '</div></div>';

    out += '<div class="card">' +
      '<div class="card-row" style="flex-wrap:wrap;gap:8px">' +
      '<button class="btn" data-act="export">' + esc(t('sync.export')) + '</button>' +
      '<button class="btn" data-act="import">' + esc(t('sync.import')) + '</button>' +
      '</div></div>';

    out += '<div class="card">' +
      '<div class="card-row" style="flex-wrap:wrap;gap:8px">' +
      '<button class="btn" data-act="go-today">' + esc(t('nav.today')) + '</button>' +
      '<button class="btn" data-act="go-stats">' + esc(t('nav.stats')) + '</button>' +
      '</div></div>';

    /* ---- appearance ------------------------------------------------- */
    out += '<div class="sec-head"><h3>' + esc(t('set.appearance')) + '</h3></div>';
    out += '<div class="card">' +
      '<div class="card-row"><span class="grow">' + esc(t('fld.st.theme')) + '</span>' +
      '<button class="mini-btn" data-act="toggle-theme">' + esc(t('sync.toggle')) + '</button></div>' +
      '<div class="card-row" style="margin-top:8px"><span class="grow">' + esc(t('fld.st.lang')) + '</span>' +
      '<button class="mini-btn" data-act="toggle-lang">ZH / EN</button></div>' +
      '<div class="av-pick">' +
      '<img id="acctAvatarBig" alt="" src="' + esc(Store.settings.avatar || 'icons/icon-192.png') + '">' +
      '<span class="grow">' +
      '<div class="ev-meta">' + esc(t('av.change')) + '</div>' +
      '<div class="card-row" style="margin-top:6px;flex-wrap:wrap;gap:8px">' +
      '<button class="mini-btn" data-act="av-pick">' + esc(t('av.choose')) + '</button>' +
      '<button class="mini-btn" data-act="av-reset">' + esc(t('av.reset')) + '</button>' +
      '</div></span></div>' +
      '</div>';

    /* ---- focus timer ------------------------------------------------ */
    out += '<div class="sec-head"><h3>' + esc(t('nav.focus')) + '</h3></div>';
    out += '<div class="card">' +
      '<div class="row2">' +
      '<div class="field"><label>' + esc(t('set.pomoMin')) + '</label>' +
      '<input type="number" min="1" max="180" id="setPomo" value="' +
      esc(Store.settings.pomodoroMin) + '"></div>' +
      '<div class="field"><label>' + esc(t('set.breakMin')) + '</label>' +
      '<input type="number" min="0" max="60" id="setBreak" value="' +
      esc(Store.settings.breakMin) + '"></div>' +
      '</div></div>';

    /* ---- tags ------------------------------------------------------- */
    out += '<div class="sec-head"><h3>' + esc(t('set.tags')) + '</h3>' +
      '<span class="sub">' + esc(t('set.tagsHint')) + '</span></div>';
    out += '<div class="card">' + tagList().map(function (tg, i) {
      return '<div class="tagrow">' +
        '<button class="swatch" data-act="tag-color" data-i="' + i + '" ' +
        'style="background:var(' + esc(tg.color) + ')" aria-label="colour"></button>' +
        '<input type="text" value="' + esc(tg.key) + '" data-tag-i="' + i + '">' +
        '<select data-tag-color="' + i + '">' + PALETTE.map(function (p) {
          return '<option value="' + p[0] + '"' + (tg.color === p[0] ? ' selected' : '') + '>' +
            esc(p[1]) + '</option>';
        }).join('') + '</select>' +
        '<button class="mini-btn" data-act="tag-del" data-i="' + i + '">&times;</button>' +
        '</div>';
    }).join('') +
      '<div class="card-row" style="margin-top:10px">' +
      '<button class="mini-btn" data-act="tag-add">+ ' + esc(t('set.tagAdd')) + '</button>' +
      '</div></div>';

    /* ---- custom festivals -------------------------------------------- */
    /* The built-in calendar covers the usual ones; this is the escape hatch
       for company anniversaries, birthdays, or a local holiday the table
       does not know. A user entry overrides the built-in name. */
    out += '<div class="sec-head"><h3>' + esc(t('set.holidays')) + '</h3>' +
      '<span class="sub">' + esc(t('set.holidaysHint')) + '</span></div>';
    out += '<div class="card">' +
      '<div class="row2">' +
      '<div class="field"><label>' + esc(t('hol.date')) + '</label>' +
      '<input type="date" id="holDate"></div>' +
      '<div class="field"><label>' + esc(t('hol.name')) + '</label>' +
      '<input type="text" id="holName"></div>' +
      '</div>' +
      '<button class="mini-btn" data-act="hol-add">+ ' + esc(t('hol.add')) + '</button>' +
      holidayList() +
      '</div>';

    el.innerHTML = out;

    /* Settings inputs are live: no save button to forget. */
    bindSetting('setPomo', 'pomodoroMin', true);
    bindSetting('setBreak', 'breakMin', true);
    Array.prototype.forEach.call(el.querySelectorAll('[data-tag-i]'), function (inp) {
      inp.addEventListener('change', function () { renameTag(parseInt(inp.dataset.tagI, 10), inp.value); });
    });
    Array.prototype.forEach.call(el.querySelectorAll('[data-tag-color]'), function (sel) {
      sel.addEventListener('change', function () {
        var i = parseInt(sel.dataset.tagColor, 10);
        Store.settings.tags[i].color = sel.value;
        Store.persistSettings();
        if (window.App) App.render();
      });
    });
  }

  /* Sorted by date: an unsorted list makes "did I already add that" a
     scanning exercise. */
  function holidayList() {
    var h = (window.Store && Store.settings.holidays) || {};
    var keys = Object.keys(h).sort();
    if (!keys.length) return '<div class="ev-meta" style="margin-top:8px">' +
      esc(t('hol.none')) + '</div>';
    return '<div class="hol-list">' + keys.map(function (k) {
      return '<div class="hol-row">' +
        '<span class="ev-meta">' + esc(k) + '</span>' +
        '<span class="grow">' + esc(h[k]) + '</span>' +
        '<button class="mini-btn" data-act="hol-del" data-date="' + esc(k) + '">&times;</button>' +
        '</div>';
    }).join('') + '</div>';
  }

  function bindSetting(id, key, numeric) {
    var el = document.getElementById(id);
    if (!el) return;
    el.addEventListener('change', function () {
      Store.settings[key] = numeric ? (parseInt(el.value, 10) || 0) : el.value;
      Store.persistSettings();
      if (window.App) { App.refreshHero(); App.toast(t('set.saved')); }
    });
  }

  /* Renaming a tag must carry its events along, or they would point at a tag
     that no longer exists and lose their colour. */
  function renameTag(i, next) {
    var list = Store.settings.tags;
    var old = list[i] && list[i].key;
    next = String(next || '').trim();
    if (!next || !old || next === old) return;
    list[i].key = next;
    Store.events.forEach(function (e) {
      if (e.tag === old) Store.updateEvent(e.id, { tag: next });
    });
    Store.persistSettings();
    if (window.App) App.render();
  }

  window.Views = {
    month: renderMonth,
    week: renderWeek,
    list: renderList,
    tasks: renderTasks,
    me: renderMe,
    esc: esc,
    setQuery: setQuery,
    getQuery: getQuery,
    tagNames: tagNames,
    tagColor: tagColor,
    /* Shared by the Today and Stats views, which live in their own files but
       render the same rows. */
    eventCard: eventCard,
    taskCard: taskCard,
    emptyBox: emptyBox,
    lunarLabel: lunarLabel
  };
})();
