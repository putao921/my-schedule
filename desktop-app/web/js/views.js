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

  /* A tag's colour may be either a CSS custom-property name (the original
     scheme, e.g. '--accent') or a literal hex ('#3a7bd5'). Hex lets the user
     pick any colour they like. We also pick readable text (black/white) from
     luminance, because a light block with light text was the readability bug. */
  function isHex(c) { return typeof c === 'string' && c.charAt(0) === '#'; }
  function luminance(hex) {
    var h = hex.replace('#', '');
    if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
    var r = parseInt(h.substr(0, 2), 16) / 255,
        g = parseInt(h.substr(2, 2), 16) / 255,
        b = parseInt(h.substr(4, 2), 16) / 255;
    var f = function (v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
  }
  /* A hand-picked hex is chosen against the light theme's paper-like
     background. On the night theme the same fully saturated block glares, so
     we pull a tenth of the saturation out before painting it. Preset colours
     are CSS variables and already theme-aware -- this only touches hex picks. */
  function desaturate(hex, k) {
    var h = String(hex).replace('#', '');
    if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
    var r = parseInt(h.substr(0, 2), 16) / 255,
        g = parseInt(h.substr(2, 2), 16) / 255,
        b = parseInt(h.substr(4, 2), 16) / 255;
    var mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn;
    var l = (mx + mn) / 2, s = 0, hh = 0;
    if (d > 0) {
      s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
      if (mx === r) hh = (g - b) / d + (g < b ? 6 : 0);
      else if (mx === g) hh = (b - r) / d + 2;
      else hh = (r - g) / d + 4;
      hh /= 6;
    }
    s = Math.max(0, Math.min(1, s * (1 - k)));
    function h2rgb(p, q, t) {
      if (t < 0) t += 1;
      if (t > 1) t -= 1;
      if (t < 1 / 6) return p + (q - p) * 6 * t;
      if (t < 1 / 2) return q;
      if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
      return p;
    }
    var q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    var p = 2 * l - q;
    var to2 = function (v) {
      var x = Math.max(0, Math.min(255, Math.round(v * 255))).toString(16);
      return x.length < 2 ? '0' + x : x;
    };
    return '#' + to2(s === 0 ? l : h2rgb(p, q, hh + 1 / 3)) +
      to2(s === 0 ? l : h2rgb(p, q, hh)) +
      to2(s === 0 ? l : h2rgb(p, q, hh - 1 / 3));
  }

  function tagStyle(tag) {
    var c = tagColor(tag);
    if (isHex(c)) {
      var bg = (window.Store && Store.settings.theme === 'night')
        ? desaturate(c, 0.10) : c;
      return { bg: bg, fg: luminance(bg) > 0.55 ? '#111418' : '#ffffff' };
    }
    return { bg: 'var(' + c + ')', fg: 'var(--on-accent)' };
  }

  /* For the colour picker: a CSS var resolves to an rgb() at runtime, which the
     <input type=color> cannot show, so we turn it into hex. Falls back to a
     neutral grey when the var is unknown. */
  function resolveHex(c) {
    if (isHex(c)) return c;
    try {
      var raw = getComputedStyle(document.documentElement).getPropertyValue(c).trim();
      var m = raw.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/);
      if (m) {
        var h = function (n) { n = (+n).toString(16); return n.length < 2 ? '0' + n : n; };
        return '#' + h(m[1]) + h(m[2]) + h(m[3]);
      }
    } catch (e) { }
    return '#888888';
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
      '<span class="chip" data-tag="' + esc(e.tag) + '" style="background:' + tagStyle(e.tag).bg + ';color:' + tagStyle(e.tag).fg + '">' +
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
      dots += '<div class="day-dot" data-tag="' + esc(evs[i].tag) + '" style="background:' +
        tagStyle(evs[i].tag).bg + '"></div>';
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

  /* Side-by-side layout for overlapping events.
   *
   * Blocks are absolutely positioned, so two events at 09:00 used to sit
   * exactly on top of each other -- the second one was invisible. We bucket
   * events into clusters of transitive overlap, then hand each member a
   * column index plus the cluster's total column count; the renderer turns
   * that into left/width percentages. */
  function layoutWeek(evs) {
    var items = evs.map(function (e) {
      var st = e.start || 0;
      var en = e.end !== undefined && e.end !== null ? e.end : st + 60;
      if (en <= st) en = st + 30;
      return { e: e, st: st, en: en, col: 0, cols: 1 };
    }).sort(function (a, b) { return a.st - b.st || a.en - b.en; });

    var cluster = [], clusterEnd = -1;
    function flush() {
      var colEnd = [];          /* last occupied minute per column */
      cluster.forEach(function (it) {
        var placed = false;
        for (var c = 0; c < colEnd.length; c++) {
          if (colEnd[c] <= it.st) { colEnd[c] = it.en; it.col = c; placed = true; break; }
        }
        if (!placed) { it.col = colEnd.length; colEnd.push(it.en); }
      });
      var n = colEnd.length || 1;
      cluster.forEach(function (it) { it.cols = n; });
      cluster = []; clusterEnd = -1;
    }
    items.forEach(function (it) {
      if (cluster.length && it.st >= clusterEnd) flush();
      cluster.push(it);
      if (it.en > clusterEnd) clusterEnd = it.en;
    });
    if (cluster.length) flush();
    return items;
  }

  function renderWeek(el, cursor) {
    var start = Store.startOfWeek(cursor || new Date());
    var dn = dowNames();
    var todayS = Store.todayStr();

    /* Visible window: a sub-range of the 24h day. ws/we are hours [0..24]. */
    var ws = Math.max(0, Math.min(23, Store.settings.weekStart | 0));
    var we = Math.max(ws + 1, Math.min(24, Store.settings.weekEnd | 0));
    var lo = ws * 60, hi = we * 60;
    var rangeMins = hi - lo;

    var hours = '';
    for (var h = ws; h < we; h++) {
      hours += '<div class="week-hour">' + (h < 10 ? '0' : '') + h + '</div>';
    }

    var cols = '';
    for (var i = 0; i < 7; i++) {
      var d = new Date(start.getTime());
      d.setDate(d.getDate() + i);
      var s = Store.iso(d);
      var evs = Store.expandedEventsOn(s).filter(matchEvent);

      /* One slot per visible hour keeps the column height correct; blocks are
         absolutely positioned and referenced to the visible window. */
      var slots = '';
      for (var h2 = ws; h2 < we; h2++) slots += '<div class="week-slot"></div>';

      var blocks = '';
      var laid = layoutWeek(evs);
      /* The "now" marker: only drawn on today's column, and only when the
         current time falls inside the visible window. */
      var nowMark = '';
      if (s === todayS) {
        var nd = new Date();
        var nMins = nd.getHours() * 60 + nd.getMinutes();
        if (nMins >= lo && nMins <= hi) {
          nowMark = '<div class="week-now" style="top:' + ((nMins - lo) / rangeMins) * 100 +
            '%"><span>' + esc(t('week.now')) + ' ' + Store.hhmm(nMins) + '</span></div>';
        }
      }
      for (var j = 0; j < laid.length; j++) {
        var e = laid[j].e;
        var st = laid[j].st, en = laid[j].en;
        /* Clip to the visible window: an off-window event still shows a sliver
           so the user can drag it back, rather than vanishing silently. */
        if (en <= lo || st >= hi) continue;
        var sClip = Math.max(st, lo), eClip = Math.min(en, hi);
        var st0 = tagStyle(e.tag);
        var topPct = ((sClip - lo) / rangeMins) * 100;
        var hPct = ((eClip - sClip) / rangeMins) * 100;
        var wPct = 100 / laid[j].cols;
        var lPct = laid[j].col * wPct;
        blocks += '<div class="wk-ev" style="top:' + topPct + '%;height:' + hPct +
          '%;left:calc(2px + ' + lPct + '%);width:calc(' + wPct + '% - 3px);right:auto;' +
          'background:' + st0.bg + ';color:' + st0.fg + '" ' +
          'data-ev="' + e.id + '" title="' + esc(e.title) + '">' +
          esc(e.title) +
          '<div class="wk-h wk-h-top" data-handle="top"></div>' +
          '<div class="wk-h wk-h-bot" data-handle="bottom"></div>' +
          '</div>';
      }
      cols += '<div class="week-col' + (s === todayS ? ' today' : '') + '" data-date="' + s + '">' +
        slots + blocks + nowMark + '</div>';
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

    /* ---- font size --------------------------------------------------- */
    out += '<div class="sec-head"><h3>' + esc(t('set.font')) + '</h3></div>';
    out += '<div class="card">' +
      '<div class="field"><label>' + esc(t('set.fontScale')) + '</label>' +
      '<input type="range" id="setFont" min="0.8" max="1.4" step="0.05" value="' +
      esc(Store.settings.fontScale) + '">' +
      '<span class="ev-meta" id="setFontVal">' + Math.round(Store.settings.fontScale * 100) + '%</span>' +
      '</div></div>';

    /* ---- week time range -------------------------------------------- */
    out += '<div class="sec-head"><h3>' + esc(t('set.weekRange')) + '</h3>' +
      '<span class="sub">' + esc(t('set.weekRangeHint')) + '</span></div>';
    var hrs = function (sel) {
      var s = '';
      for (var hh = 0; hh <= 24; hh++) {
        s += '<option value="' + hh + '"' + (Store.settings[sel] === hh ? ' selected' : '') + '>' +
          (hh < 10 ? '0' : '') + hh + ':00</option>';
      }
      return s;
    };
    out += '<div class="card"><div class="row2">' +
      '<div class="field"><label>' + esc(t('set.weekStart')) + '</label>' +
      '<select id="setWeekStart">' + hrs('weekStart') + '</select></div>' +
      '<div class="field"><label>' + esc(t('set.weekEnd')) + '</label>' +
      '<select id="setWeekEnd">' + hrs('weekEnd') + '</select></div>' +
      '</div></div>';

    /* ---- tags ------------------------------------------------------- */
    out += '<div class="sec-head"><h3>' + esc(t('set.tags')) + '</h3>' +
      '<span class="sub">' + esc(t('set.tagsHint')) + '</span></div>';
    out += '<div class="card">' + tagList().map(function (tg, i) {
      return '<div class="tagrow">' +
        '<input type="color" class="swatch" data-tag-color="' + i + '" value="' + esc(resolveHex(tg.color)) + '" title="' + esc(t('set.color')) + '">' +
        '<span class="swatches">' + PALETTE.map(function (p) {
          return '<button class="mini-swatch" data-act="tag-preset" data-i="' + i +
            '" data-color="' + p[0] + '" style="background:var(' + p[0] + ')"></button>';
        }).join('') + '</span>' +
        '<input type="text" value="' + esc(tg.key) + '" data-tag-i="' + i + '">' +
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

    /* Font scale: live, no save button. */
    var fontEl = document.getElementById('setFont');
    if (fontEl) {
      fontEl.addEventListener('input', function () {
        var v = parseFloat(fontEl.value) || 1;
        Store.settings.fontScale = v;
        Store.persistSettings();
        var lab = document.getElementById('setFontVal');
        if (lab) lab.textContent = Math.round(v * 100) + '%';
        if (window.App) App.applyFont();
      });
    }

    /* Week visible range. */
    var wsEl = document.getElementById('setWeekStart'), weEl = document.getElementById('setWeekEnd');
    var onWeek = function () {
      var a = parseInt(wsEl.value, 10) || 0, b = parseInt(weEl.value, 10) || 24;
      if (b <= a) { b = Math.min(24, a + 1); if (weEl.value != b) weEl.value = b; }
      Store.settings.weekStart = a;
      Store.settings.weekEnd = b;
      Store.persistSettings();
      if (window.App) App.render();
    };
    if (wsEl) wsEl.addEventListener('change', onWeek);
    if (weEl) weEl.addEventListener('change', onWeek);

    Array.prototype.forEach.call(el.querySelectorAll('[data-tag-i]'), function (inp) {
      inp.addEventListener('change', function () { renameTag(parseInt(inp.dataset.tagI, 10), inp.value); });
    });
    Array.prototype.forEach.call(el.querySelectorAll('[data-tag-color]'), function (sel) {
      sel.addEventListener('input', function () {
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
    tagStyle: tagStyle,
    /* Shared by the Today and Stats views, which live in their own files but
       render the same rows. */
    eventCard: eventCard,
    taskCard: taskCard,
    emptyBox: emptyBox,
    lunarLabel: lunarLabel
  };
})();
