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

  /* ------------------------------------------------------------ helpers -- */
  function eventCard(e) {
    return '<div class="card card-row" data-ev="' + e.id + '">' +
      '<button class="tick' + (e.done ? ' on' : '') + '" data-act="toggle-ev" data-id="' + e.id + '">&#10003;</button>' +
      '<span class="grow">' +
      '<div class="ev-title' + (e.done ? ' done' : '') + '">' + esc(e.title || '(untitled)') + '</div>' +
      '<div class="ev-meta">' + Store.hhmm(e.start) + '-' + Store.hhmm(e.end) + '</div>' +
      '</span>' +
      '<span class="chip" data-tag="' + esc(e.tag) + '">' + esc(e.tag) + '</span>' +
      '<div class="row-actions">' +
      '<button class="mini-btn" data-act="edit-ev" data-id="' + e.id + '">Edit</button>' +
      '</div>' +
      '</div>';
  }

  function taskCard(t) {
    return '<div class="card card-row" data-task="' + t.id + '">' +
      '<button class="tick' + (t.done ? ' on' : '') + '" data-act="toggle-task" data-id="' + t.id + '">&#10003;</button>' +
      '<span class="grow">' +
      '<div class="ev-title' + (t.done ? ' done' : '') + '">' + esc(t.text || '(untitled)') + '</div>' +
      '<div class="ev-meta">' + (t.due ? esc(t.due) + ' ' + esc(t.dueTime || '') : '') +
      ' · ' + esc(t.project || 'Inbox') + ' · ' + esc(t.priority || 'medium') + '</div>' +
      '</span>' +
      '<div class="row-actions">' +
      '<button class="mini-btn" data-act="edit-task" data-id="' + t.id + '">Edit</button>' +
      '</div>' +
      '</div>';
  }

  function emptyBox(text) {
    return '<div class="empty">' + esc(text) + '</div>';
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

    el.innerHTML =
      '<div class="sec-head"><h3>' + esc(title) + '</h3>' +
      '<span class="sub">' + esc(t('view.month')) + '</span></div>' +
      head + grid +
      '<div class="sec-head"><h3>' + esc(t('fld.day.title')) + '</h3>' +
      '<span class="sub">' + Store.iso(cur) + '</span></div>' +
      dayList(Store.iso(cur));
  }

  function cell(date, todayS, out) {
    var s = Store.iso(date);
    var evs = Store.eventsOn(s);
    var cls = 'day' + (out ? ' out' : '') + (s === todayS ? ' today' : '');
    var weekend = (date.getDay() === 0 || date.getDay() === 6);
    if (weekend && !out) cls += ' weekend';

    var dots = '';
    for (var i = 0; i < Math.min(evs.length, 3); i++) {
      dots += '<div class="day-dot" data-tag="' + esc(evs[i].tag) + '"></div>';
    }
    return '<div class="' + cls + '" data-date="' + s + '">' +
      '<div class="day-num">' + date.getDate() + '</div>' + dots + '</div>';
  }

  function dayList(dateStr) {
    var evs = Store.eventsOn(dateStr);
    if (!evs.length) return emptyBox(t('fld.day.empty'));
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
      var evs = Store.eventsOn(s);
      var blocks = '';
      for (var j = 0; j < evs.length; j++) {
        var e = evs[j];
        var topPx = ((e.start || 0) / 60) * 40;
        blocks += '<div class="card" style="position:absolute;left:2px;right:2px;top:' + topPx +
          'px;padding:2px 4px;font-size:10px;overflow:hidden" data-ev="' + e.id + '">' +
          esc(e.title) + '</div>';
      }
      cols += '<div class="week-col' + (s === todayS ? ' today' : '') + '" data-date="' + s + '">' +
        blocks + '</div>';
    }

    var head = '<div class="month-head">';
    for (var k = 0; k < 7; k++) {
      var hd = new Date(start.getTime());
      hd.setDate(hd.getDate() + k);
      head += '<div class="month-dow">' + dn[k] + '<br><span class="ev-meta">' + hd.getDate() + '</span></div>';
    }
    head += '</div>';

    el.innerHTML =
      '<div class="sec-head"><h3>' + esc(t('view.week')) + '</h3>' +
      '<span class="sub">' + Store.iso(start) + ' ~ </span></div>' +
      head +
      '<div class="week-wrap"><div class="week-hours">' + hours + '</div>' +
      '<div class="week-cols">' + cols + '</div></div>';
  }

  /* --------------------------------------------------------------- list -- */
  function renderList(el, cursor) {
    var groups = {};
    Store.events.forEach(function (e) {
      var k = e.date || Store.todayStr();
      (groups[k] = groups[k] || []).push(e);
    });
    var keys = Object.keys(groups).sort();
    if (!keys.length) { el.innerHTML = emptyBox(t('fld.day.empty')); return; }

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
    var open = Store.tasks.filter(function (t) { return !t.done; });
    var done = Store.tasks.filter(function (t) { return t.done; });
    var out = '<div class="sec-head"><h3>' + esc(t('view.tasks')) + '</h3>' +
      '<span class="sub">' + open.length + '</span></div>';

    if (!open.length && !done.length) {
      el.innerHTML = out + emptyBox(t('fld.day.empty'));
      return;
    }
    open.forEach(function (t) { out += taskCard(t); });
    if (done.length) {
      out += '<div class="sec-head"><h3>Done</h3><span class="sub">' + done.length + '</span></div>';
      done.forEach(function (t) { out += taskCard(t); });
    }
    el.innerHTML = out;
  }

  /* ----------------------------------------------------------------- me -- */
  function renderMe(el) {
    var st = Store.stats();
    var out = '<div class="sec-head"><h3>' + esc(t('nav.profile')) + '</h3></div>';

    out += '<div class="card acct">' +
      '<img class="acct-av" id="acctAvatar" alt="" src="icons/icon-192.png">' +
      '<span class="grow"><div id="acctMail">' + esc(t('pomo.noTask')) + '</div>' +
      '<div class="acct-mail" id="acctState">offline</div></span>' +
      '</div>';

    out += '<div class="card">' +
      '<div class="card-row"><span class="grow">' + esc(t('fld.st.theme')) + '</span>' +
      '<button class="mini-btn" data-act="toggle-theme">Toggle</button></div>' +
      '<div class="card-row" style="margin-top:8px"><span class="grow">' + esc(t('fld.st.lang')) + '</span>' +
      '<button class="mini-btn" data-act="toggle-lang">ZH / EN</button></div>' +
      '</div>';

    out += '<div class="card">' +
      '<div class="ev-meta">' +
      esc(fmt(t('fld.st.totals'), Store.events.length, st.done,
        Store.tasks.filter(function (x) { return !x.done; }).length)) +
      '</div></div>';

    /* Sync controls: cloud.js fills in the real handlers. */
    out += '<div class="card">' +
      '<div class="card-row"><span class="grow"><b>Sync</b></span>' +
      '<span class="ev-meta" id="syncState">-</span></div>' +
      '<div class="card-row" style="margin-top:8px;flex-wrap:wrap;gap:8px">' +
      '<button class="btn" data-act="sync-signin">Sign in</button>' +
      '<button class="btn" data-act="sync-push">Upload</button>' +
      '<button class="btn" data-act="sync-pull">Download</button>' +
      '<button class="btn btn-ghost" data-act="sync-out">Sign out</button>' +
      '</div></div>';

    out += '<div class="card">' +
      '<div class="card-row" style="flex-wrap:wrap;gap:8px">' +
      '<button class="btn" data-act="export">Export</button>' +
      '<button class="btn" data-act="import">Import</button>' +
      '</div></div>';

    el.innerHTML = out;
  }

  window.Views = {
    month: renderMonth,
    week: renderWeek,
    list: renderList,
    tasks: renderTasks,
    me: renderMe,
    esc: esc
  };
})();
