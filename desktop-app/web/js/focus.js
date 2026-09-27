/* Focus timer (pomodoro) + the mini floating countdown.
 *
 * This is the web counterpart of the desktop app's pomodoro: same cycle
 * (focus -> break -> focus), same bookkeeping (completed focus minutes land
 * in today's focus total), and the same "mini" widget idea. The one thing
 * that cannot carry over is a window floating above other apps -- a browser
 * tab cannot do that -- so the mini widget floats above the *page* instead.
 *
 * State lives in Store.settings.pomo so a reload (or another device, once
 * synced) resumes the same countdown rather than losing it.
 */
(function () {
  'use strict';

  var tick = null;
  var miniEl = null;

  function S() { return Store.settings; }

  function txt(key, fallback) {
    if (typeof window.t === 'function') {
      var v = window.t(key);
      if (v && v !== key) return v;
    }
    return fallback || key;
  }

  /* ---- state ---------------------------------------------------------- */
  function pomo() {
    var s = S();
    if (!s.pomo || typeof s.pomo !== 'object') {
      s.pomo = { mode: 'focus', running: false, endsAt: null, left: null, taskId: null };
    }
    var p = s.pomo;
    if (p.mode !== 'break') p.mode = 'focus';
    return p;
  }

  function minutes() {
    var s = S();
    var f = parseInt(s.pomodoroMin, 10);
    var b = parseInt(s.breakMin, 10);
    return { focus: f > 0 ? f : 25, break: b >= 0 ? b : 5 };
  }

  /* Seconds left right now: derived from the wall-clock deadline when running
     so a background tab or a reload cannot drift. */
  function remaining(p) {
    p = p || pomo();
    if (p.running && p.endsAt) {
      var left = Math.round((p.endsAt - Date.now()) / 1000);
      return left > 0 ? left : 0;
    }
    if (typeof p.left === 'number') return Math.max(0, p.left);
    return minutes()[p.mode] * 60;
  }

  function total(p) {
    p = p || pomo();
    return minutes()[p.mode] * 60;
  }

  function save() { Store.persistSettings(); }

  /* ---- actions -------------------------------------------------------- */
  function start() {
    var p = pomo();
    if (p.running) return;
    var secs = remaining(p);
    p.left = secs;
    p.endsAt = Date.now() + secs * 1000;
    p.running = true;
    save();
    paint();
  }

  function pause() {
    var p = pomo();
    if (!p.running) return;
    p.left = remaining(p);
    p.running = false;
    p.endsAt = null;
    save();
    paint();
  }

  function reset() {
    var p = pomo();
    p.running = false;
    p.endsAt = null;
    p.left = null;
    p.mode = 'focus';
    save();
    paint();
  }

  /* Stop early but keep the minutes actually sat: "结束并统计". */
  function endAndLog() {
    var p = pomo();
    if (p.mode === 'focus') {
      var done = minutes().focus * 60 - remaining(p);
      if (done > 0) addFocus(Math.max(1, Math.round(done / 60)));
    }
    reset();
    if (window.App) App.toast(txt('pomo.logged', 'logged'));
    if (window.App) App.refreshHero();
  }

  function addFocus(mins) {
    var s = S();
    var today = Store.todayStr();
    /* The daily total belongs to today only; a new day starts from zero. */
    if (s.focusDate !== today) { s.focusDate = today; s.focusTodayMin = 0; }
    s.focusTodayMin = (parseInt(s.focusTodayMin, 10) || 0) + mins;
    save();
  }

  function complete() {
    var p = pomo();
    if (p.mode === 'focus') {
      addFocus(minutes().focus);
      p.mode = 'break';
    } else {
      p.mode = 'focus';
    }
    p.left = minutes()[p.mode] * 60;
    p.endsAt = Date.now() + p.left * 1000;
    p.running = true;   /* the cycle carries on, like the desktop app */
    save();
    notify();
    paint();
    if (window.App) { App.refreshHero(); App.toast(txt(p.mode === 'break' ? 'pomo.break' : 'pomo.focusing')); }
  }

  function notify() {
    var title = txt('sched', 'My Schedule');
    var body = pomo().mode === 'break'
      ? txt('pomo.break', 'Break')
      : txt('pomo.focusing', 'Focus');
    try {
      if (window.Notification && Notification.permission === 'granted') {
        new Notification(title, { body: body });
      }
    } catch (e) { }
    try { if (navigator.vibrate) navigator.vibrate([120, 80, 120]); } catch (e) { }
  }

  /* ---- rendering ------------------------------------------------------ */
  function fmtTime(sec) {
    var m = Math.floor(sec / 60), s = sec % 60;
    return ('0' + m).slice(-2) + ':' + ('0' + s).slice(-2);
  }

  function ring(frac) {
    /* r=70 in a 160 viewBox; dasharray = circumference. */
    var r = 70, c = 2 * Math.PI * r;
    var shown = Math.max(0, Math.min(1, frac)) * c;
    return '<svg viewBox="0 0 160 160" aria-hidden="true">' +
      '<circle cx="80" cy="80" r="' + r + '" fill="none" stroke="var(--line-soft)" stroke-width="10"/>' +
      '<circle cx="80" cy="80" r="' + r + '" fill="none" stroke="' +
      (pomo().mode === 'break' ? 'var(--accent-cool)' : 'var(--accent-warm)') +
      '" stroke-width="10" stroke-linecap="round" stroke-dasharray="' + shown + ' ' + c +
      '" transform="rotate(-90 80 80)"/></svg>';
  }

  function taskOptions() {
    var p = pomo();
    var out = '<option value="">' + txt('pomo.noTask', 'no task') + '</option>';
    Store.tasks.forEach(function (t) {
      if (t.done) return;
      out += '<option value="' + t.id + '"' + (p.taskId === t.id ? ' selected' : '') + '>' +
        (window.Views ? Views.esc(t.text) : String(t.text).replace(/</g, '&lt;')) + '</option>';
    });
    return out;
  }

  function stateText(p) {
    if (!p.running && p.endsAt === null && p.left === null) return txt('pomo.ready', 'ready');
    if (!p.running) return txt('pomo.paused', 'paused');
    return p.mode === 'break' ? txt('pomo.break', 'Break') : txt('pomo.focusing', 'Focusing');
  }

  function taskText(p) {
    if (!p.taskId) return txt('pomo.noTask', 'no task');
    var t = Store.findTask(p.taskId);
    return t ? t.text : txt('pomo.noTask', 'no task');
  }

  function renderFocus(el) {
    var p = pomo();
    var secs = remaining(p);
    var frac = 1 - secs / total(p);
    var running = p.running;

    el.innerHTML =
      '<div class="sec-head"><h3>' + txt('nav.focus', 'Focus') + '</h3>' +
      '<span class="sub">' + fmt(S().focusTodayMin) + '</span></div>' +
      '<div class="focus-wrap">' +
      '<div class="focus-ring">' + ring(frac) +
      '<div style="text-align:center">' +
      '<div class="focus-time" id="foTime">' + fmtTime(secs) + '</div>' +
      '<div class="focus-state" id="foState">' + stateText(p) + '</div>' +
      '</div></div>' +
      '<div class="focus-task" id="foTask">' + esc2(taskText(p)) + '</div>' +
      '<div class="field" style="width:100%;max-width:340px">' +
      '<label>' + txt('fld.fo.task', 'Task') + '</label>' +
      '<select id="foTaskSel">' + taskOptions() + '</select></div>' +
      '<div class="focus-ctl">' +
      '<button class="btn btn-primary" data-act="fo-toggle" id="foMain">' +
      (running ? txt('pomo.pause', 'Pause') : (p.left === null ? txt('pomo.start', 'Start') : txt('pomo.resume', 'Resume'))) +
      '</button>' +
      '<button class="btn" data-act="fo-end">' + txt('pomo.endStat', 'End & log') + '</button>' +
      '<button class="btn btn-ghost" data-act="fo-reset">' + txt('focus.reset', 'Reset') + '</button>' +
      '</div>' +
      '<div class="ev-meta">' + txt('pomo.hint', '') + '</div>' +
      '</div>';

    var sel = document.getElementById('foTaskSel');
    if (sel) {
      sel.addEventListener('change', function () {
        pomo().taskId = sel.value || null;
        save();
      });
    }
  }

  function fmt(mins) {
    mins = parseInt(mins, 10) || 0;
    return txt('hero.focus', 'Focus today {0}h{1:00}m').replace('{0}', Math.floor(mins / 60)).replace('{1:00}', mins % 60);
  }

  function esc2(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  /* Update only the live parts, so the task select keeps its state. */
  function paint() {
    var p = pomo();
    var secs = remaining(p);
    var t = document.getElementById('foTime');
    if (t) t.textContent = fmtTime(secs);
    var s = document.getElementById('foState');
    if (s) s.textContent = stateText(p);
    var k = document.getElementById('foTask');
    if (k) k.textContent = taskText(p);
    var b = document.getElementById('foMain');
    if (b) {
      b.textContent = p.running ? txt('pomo.pause', 'Pause')
        : (p.left === null ? txt('pomo.start', 'Start') : txt('pomo.resume', 'Resume'));
    }
    var ringEl = document.querySelector('.focus-ring');
    if (ringEl) {
      /* Cheap: rebuild only the arc. */
      var svg = ringEl.querySelector('svg');
      if (svg) {
        var tmp = document.createElement('div');
        tmp.innerHTML = ring(1 - secs / total(p));
        ringEl.replaceChild(tmp.firstChild, svg);
      }
    }
    paintMini();
  }

  /* ---- mini widget ---------------------------------------------------- */
  function paintMini() {
    var p = pomo();
    var live = p.running || (p.left !== null && p.endsAt !== null) || (p.left !== null);
    var onFocusView = window.App && App.currentView && App.currentView() === 'focus';

    if (!live || onFocusView) { hideMini(); return; }

    var el = miniEl || (miniEl = document.createElement('div'));
    el.className = 'mini';
    el.innerHTML =
      '<span class="mini-time">' + fmtTime(remaining(p)) + '</span>' +
      '<span class="mini-task">' + esc2(taskText(p)) + '</span>' +
      '<span class="mini-btns">' +
      '<button class="mini-btn" data-act="fo-toggle">' +
      (p.running ? txt('pomo.pause', 'Pause') : txt('pomo.resume', 'Resume')) + '</button>' +
      '<button class="mini-btn" data-act="fo-end">' + txt('pomo.endStat', 'End & log') + '</button>' +
      '</span>';
    if (!el.parentNode) document.body.appendChild(el);
  }

  function hideMini() {
    if (miniEl && miniEl.parentNode) miniEl.parentNode.removeChild(miniEl);
  }

  /* ---- ticking -------------------------------------------------------- */
  function loop() {
    var p = pomo();
    if (p.running) {
      if (remaining(p) <= 0) { complete(); return; }
      paint();
    }
  }

  /* ---- public --------------------------------------------------------- */
  window.Focus = {
    view: renderFocus,
    paint: paint,
    start: start,
    pause: pause,
    reset: reset,
    end: endAndLog,
    /* Handles the data-act buttons used by both the view and the mini bar. */
    handle: function (act) {
      if (act === 'fo-toggle') { pomo().running ? pause() : start(); return true; }
      if (act === 'fo-end') { endAndLog(); if (window.App) App.render(); return true; }
      if (act === 'fo-reset') { reset(); if (window.App) App.render(); return true; }
      return false;
    },
    init: function () {
      if (window.Views) Views.focus = renderFocus;
      if (!tick) tick = setInterval(loop, 1000);
      /* Ask once, quietly; a denied prompt is harmless. */
      try {
        if (window.Notification && Notification.permission === 'default') {
          Notification.requestPermission(function () { });
        }
      } catch (e) { }
    }
  };
})();
