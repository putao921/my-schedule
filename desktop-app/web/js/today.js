/* "Today" -- a single page that answers "what do I actually have to do now".
 *
 * The month view answers "when is everything"; the task view answers "what is
 * outstanding". Neither answers the question people open a planner for, which
 * is what this view exists to answer: today's timed events, the things due
 * today, and -- the part the other views quietly drop on the floor -- the
 * things that were due earlier and are now simply late.
 *
 * Overdue is deliberately its own group at the top. A due date that has passed
 * is not the same kind of item as one that is due later today, and burying it
 * in a chronological list is how things get missed.
 */
(function () {
  'use strict';

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function todayISO() { return Store.todayStr(); }

  function isOverdue(task) {
    return !task.done && task.due && task.due < todayISO();
  }
  function isDueToday(task) {
    return task.due === todayISO();
  }

  function fmtMin(mins) {
    mins = parseInt(mins, 10) || 0;
    return Math.floor(mins / 60) + 'h' + ('0' + (mins % 60)).slice(-2) + 'm';
  }

  function renderToday(el) {
    var today = todayISO();
    var d = new Date();
    var zh = window.lang() === 'zh';

    var evs = Store.expandedEventsOn(today);
    var tasks = Store.tasks.slice();
    var overdue = tasks.filter(isOverdue);
    var dueToday = tasks.filter(isDueToday);

    var done = evs.filter(function (e) { return e.done; }).length;
    var total = evs.length;
    var pct = total ? Math.round(done / total * 100) : 0;
    var focus = parseInt(Store.settings.focusTodayMin, 10) || 0;

    /* ---- header ------------------------------------------------------ */
    var lunar = window.Views && Views.lunarLabel ? Views.lunarLabel(today) : '';
    var fest = window.Lunar ? (Lunar.dayInfo(today).festival || '') : '';

    var out = '<div class="today-head card' + (fest ? ' fest' : '') + '">' +
      '<div class="today-date">' +
      '<span class="today-dow">' + esc(zh ? '星期' + ['日', '一', '二', '三', '四', '五', '六'][d.getDay()] : ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][d.getDay()]) + '</span>' +
      '<span class="today-day">' + esc(today) + '</span>' +
      (lunar ? '<span class="today-lunar">' + esc(lunar) + '</span>' : '') +
      '</div>' +
      '<div class="today-nums">' +
      '<div class="tnum"><b>' + done + '/' + total + '</b><span>' + esc(t('today.evDone')) + '</span></div>' +
      '<div class="tnum"><b>' + fmtMin(focus) + '</b><span>' + esc(t('today.focus')) + '</span></div>' +
      '<div class="tnum"><b>' + (overdue.length + dueToday.length) + '</b><span>' + esc(t('today.due')) + '</span></div>' +
      '</div>' +
      '<div class="today-bar"><i style="width:' + pct + '%"></i></div>' +
      '</div>';

    /* ---- overdue ------------------------------------------------------ */
    if (overdue.length) {
      out += '<div class="sec-head"><h3>' + esc(t('today.overdue')) + '</h3>' +
        '<span class="sub">' + overdue.length + '</span></div>';
      overdue.forEach(function (tk) { out += overdueCard(tk, today); });
    }

    /* ---- today's timed events ----------------------------------------- */
    out += '<div class="sec-head"><h3>' + esc(t('today.events')) + '</h3>' +
      '<span class="sub">' + total + '</span></div>';
    if (!evs.length) out += Views.emptyBox(t('today.evEmpty'));
    else evs.forEach(function (e) { out += Views.eventCard(e); });

    /* ---- tasks due today ---------------------------------------------- */
    out += '<div class="sec-head"><h3>' + esc(t('today.dueToday')) + '</h3>' +
      '<span class="sub">' + dueToday.length + '</span></div>';
    if (!dueToday.length) out += Views.emptyBox(t('today.dueEmpty'));
    else dueToday.forEach(function (tk) { out += Views.taskCard(tk); });

    /* ---- way out ------------------------------------------------------- */
    out += '<div class="card">' +
      '<div class="card-row" style="flex-wrap:wrap;gap:8px">' +
      '<button class="btn" data-act="go-stats">' + esc(t('today.stats')) + '</button>' +
      '<button class="btn" data-act="go-focus">' + esc(t('nav.focus')) + '</button>' +
      '</div></div>';

    el.innerHTML = out;
  }

  /* Same shape as a task row, plus how late it is: without that number an
     overdue task looks exactly like one that is merely old. */
  function overdueCard(tk, today) {
    var days = Math.round((Store.parseISO(today) - Store.parseISO(tk.due)) / 86400000);
    var late = days > 0 ? fmt(t('today.lateDays'), days) : '';
    var tpl = Views.taskCard(tk);
    return tpl.replace('<div class="ev-meta">', '<div class="ev-meta"><span class="late">' +
      esc(late) + '</span> ');
  }

  window.TodayView = { render: renderToday };
})();
