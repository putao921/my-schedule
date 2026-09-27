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
      s.pomo = {
        mode: 'focus', dir: 'down', running: false,
        endsAt: null, left: null, upBase: 0, upStart: null,
        taskId: null, queue: []
      };
    }
    var p = s.pomo;
    if (p.mode !== 'break') p.mode = 'focus';
    if (p.dir !== 'up') p.dir = 'down';
    /* Queue holds task ids, in order. */
    if (!Array.isArray(p.queue)) p.queue = [];
    if (typeof p.upBase !== 'number' || !isFinite(p.upBase) || p.upBase < 0) p.upBase = 0;
    return p;
  }

  function minutes() {
    var s = S();
    var f = parseInt(s.pomodoroMin, 10);
    var b = parseInt(s.breakMin, 10);
    return { focus: f > 0 ? f : 25, break: b >= 0 ? b : 5 };
  }

  /* Count-up applies to the focus block only. A break that never ends is not
     a break, so the rest block always counts down. */
  function isUp(p) { return (p || pomo()).dir === 'up' && (p || pomo()).mode !== 'break'; }

  /* Seconds counted up so far: banked seconds + the current run. */
  function elapsed(p) {
    p = p || pomo();
    var base = parseInt(p.upBase, 10) || 0;
    if (p.running && p.upStart) return base + Math.floor((Date.now() - p.upStart) / 1000);
    return base;
  }

  /* Seconds left right now: derived from the wall-clock deadline when running
     so a background tab or a reload cannot drift. */
  function remaining(p) {
    p = p || pomo();
    if (isUp(p)) return 0;
    if (p.running && p.endsAt) {
      var left = Math.round((p.endsAt - Date.now()) / 1000);
      return left > 0 ? left : 0;
    }
    if (typeof p.left === 'number') return Math.max(0, p.left);
    return minutes()[p.mode] * 60;
  }

  /* What the big number shows: down = time left, up = time spent. */
  function displaySecs(p) { return isUp(p) ? elapsed(p) : remaining(p); }

  function total(p) {
    p = p || pomo();
    return minutes()[p.mode] * 60;
  }

  /* Is there a timer on screen at all? Used by the mini widget. */
  function isLive(p) {
    p = p || pomo();
    if (p.running) return true;
    return isUp(p) ? (!!p.upStart || (parseInt(p.upBase, 10) || 0) > 0) : (p.left !== null);
  }

  function save() { Store.persistSettings(); }

  /* ---- actions -------------------------------------------------------- */
  function start() {
    var p = pomo();
    if (p.running) return;
    /* Nothing picked by hand but a queue is waiting: take its head, so
       "queue two tasks, press start" works without a second tap. */
    if (!p.taskId && queue().length) advanceQueue();
    begin(p);
    save();
    paint();
  }

  /* Put the clock in motion for the current direction. Count-up has no
     deadline, so it remembers when it started instead. */
  function begin(p) {
    if (isUp(p)) {
      p.upStart = Date.now();
      p.endsAt = null;
      p.left = null;
    } else {
      var secs = remaining(p);
      p.left = secs;
      p.endsAt = Date.now() + secs * 1000;
    }
    p.running = true;
  }

  function pause() {
    var p = pomo();
    if (!p.running) return;
    if (isUp(p)) {
      p.upBase = elapsed(p);
      p.upStart = null;
    } else {
      p.left = remaining(p);
      p.endsAt = null;
    }
    p.running = false;
    save();
    paint();
  }

  function reset() {
    var p = pomo();
    p.running = false;
    p.endsAt = null;
    p.left = null;
    p.upBase = 0;
    p.upStart = null;
    p.mode = 'focus';
    save();
    paint();
  }

  /* Stop early but keep the minutes actually sat: "结束并统计". */
  function endAndLog() {
    var p = pomo();
    if (p.mode === 'focus') {
      var secs = isUp(p) ? elapsed(p) : (minutes().focus * 60 - remaining(p));
      if (secs > 0) addFocus(Math.max(1, Math.round(secs / 60)));
    }
    reset();
    if (window.App) App.toast(txt('pomo.logged', 'logged'));
    if (window.App) App.refreshHero();
  }

  /* Switch counting direction. The running block cannot be converted in
     place -- "12:30 left" and "12:30 spent" are different sessions -- so the
     timer goes back to ready and the user starts again. */
  function setDir(dir) {
    var p = pomo();
    dir = dir === 'up' ? 'up' : 'down';
    if (p.dir === dir) return;
    p.dir = dir;
    reset();
    if (window.App) App.toast(txt('pomo.dirChanged', 'switched to {0}')
      .replace('{0}', dir === 'up' ? txt('pomo.countUp', 'count up') : txt('pomo.countDown', 'countdown')));
  }

  function addFocus(mins) {
    /* Delegated to the store so today's hero figure and the stats week are
       written by the same code path -- two writers is how they drift. */
    if (window.Store && Store.addFocus) Store.addFocus(mins);
  }

  /* ---- task queue ----------------------------------------------------- */
  /* Rotating queue, same rule as the desktop app: only a focus block that
     runs to completion consumes a slot. Pausing or stopping early leaves the
     queue alone, because the user may well want to carry on with the same
     task. The head becomes the current task and moves to the tail, so a
     three-task queue cycles instead of running once and stopping. */
  function queue() { return pomo().queue; }

  function queueAlive() {
    return queue().filter(function (id) { return !!Store.findTask(id); });
  }

  function advanceQueue() {
    var p = pomo();
    var ids = queueAlive();
    if (!ids.length) { p.queue = []; save(); return null; }
    var head = ids[0];
    var t = Store.findTask(head);
    if (t) p.taskId = head;
    p.queue = ids.slice(1).concat([head]);
    save();
    return t;
  }

  function enqueue(taskId) {
    if (!taskId) return;
    var p = pomo();
    /* No duplicates: the same task twice would just waste a slot later. */
    if (p.queue.indexOf(taskId) !== -1) return;
    p.queue.push(taskId);
    save();
  }

  function dequeueAt(i) {
    var p = pomo();
    if (i < 0 || i >= p.queue.length) return;
    p.queue.splice(i, 1);
    save();
  }

  function clearQueue() {
    pomo().queue = [];
    save();
  }

  function complete() {
    var p = pomo();
    if (p.mode === 'focus') {
      addFocus(minutes().focus);
      /* Only a block that ran out on its own earns the next task. */
      advanceQueue();
      p.mode = 'break';
    } else {
      p.mode = 'focus';
    }
    p.left = minutes()[p.mode] * 60;
    /* A fresh count-up block starts at zero, not from the last session. */
    if (isUp(p)) p.upBase = 0;
    begin(p);
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
  /* mm:ss, but minutes may pass 99 when counting up: padding to two digits
     would silently turn 105 minutes into 05. */
  function fmtTime(sec) {
    sec = Math.max(0, Math.floor(sec));
    var m = Math.floor(sec / 60), s = sec % 60;
    var mm = m < 100 ? ('0' + m).slice(-2) : String(m);
    return mm + ':' + ('0' + s).slice(-2);
  }

  function ring(frac, up) {
    /* r=70 in a 160 viewBox; dasharray = circumference. */
    var r = 70, c = 2 * Math.PI * r;
    var shown = Math.max(0, Math.min(1, frac)) * c;
    return '<svg viewBox="0 0 160 160" aria-hidden="true">' +
      '<circle cx="80" cy="80" r="' + r + '" fill="none" stroke="var(--line-soft)" stroke-width="10"/>' +
      '<circle cx="80" cy="80" r="' + r + '" fill="none" stroke="' +
      (pomo().mode === 'break' ? 'var(--accent-cool)' : 'var(--accent-warm)') +
      '" stroke-width="10" stroke-linecap="round" stroke-dasharray="' + shown + ' ' + c +
      '" transform="rotate(-90 80 80)"' + (up ? ' class="ring-up"' : '') + '/></svg>';
  }

  /* How far round the ring: counting down it drains, counting up it fills and
     then starts a new lap against the target length -- a ring stuck at full
     would look frozen during a long count-up session. */
  function progress(p) {
    var t = total(p);
    if (!t) return 0;
    if (isUp(p)) return (elapsed(p) % t) / t;
    return 1 - remaining(p) / t;
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

  /* Start / Pause / Resume. "Resume" only makes sense once there is something
     on the clock -- for count-up that means banked seconds, not p.left. */
  function mainLabel(p) {
    if (p.running) return txt('pomo.pause', 'Pause');
    var idle = isUp(p)
      ? (!(parseInt(p.upBase, 10) || 0) && !p.upStart)
      : (p.left === null);
    return idle ? txt('pomo.start', 'Start') : txt('pomo.resume', 'Resume');
  }

  /* Countdown / count-up switch. */
  function segHtml(p) {
    var up = p.dir === 'up';
    return '<div class="seg" role="group" aria-label="' + esc2(txt('pomo.direction', 'Direction')) + '">' +
      '<button class="seg-btn' + (up ? '' : ' on') + '" data-act="fo-dir" data-dir="down">' +
      txt('pomo.countDown', 'Countdown') + '</button>' +
      '<button class="seg-btn' + (up ? ' on' : '') + '" data-act="fo-dir" data-dir="up">' +
      txt('pomo.countUp', 'Count up') + '</button>' +
      '</div>';
  }

  /* The length button, and what it means: in countdown mode it is the block
     length, in count-up mode there is nothing to count down to. */
  function durHtml(p) {
    if (isUp(p)) {
      return '<div class="focus-dur">' +
        '<span class="dur-note">' + txt('pomo.unlimited', 'no limit - tap end to log') + '</span>' +
        '</div>';
    }
    return '<div class="focus-dur">' +
      '<button class="dur-btn" data-act="fo-dur">' +
      '<span class="dur-val" id="foDur">' + fmtTime(total(p)) + '</span>' +
      '<span class="dur-caret">&#9662;</span>' +
      '<span class="dur-cap">' + txt('pomo.dur', 'Length') + '</span>' +
      '</button>' +
      '<span class="ev-meta">' + txt('pomo.pickHint', 'tap the wheels to choose') + '</span>' +
      '</div>';
  }

  /* Wheel picker for both block lengths. Changing it while a block is running
     would silently redefine "how long is left", so in that case it takes
     effect from the next block and says so. */
  function openPicker() {
    if (!window.Wheel) return;
    var m = minutes();
    Wheel.pickDuration({
      title: txt('pomo.pick', 'Pick a length'),
      tabs: [
        {
          key: 'focus', label: txt('pomo.focusLen', 'Focus'),
          minutes: m.focus, min: 1, max: 720, step: 1,
          presets: [5, 15, 25, 45, 60, 90]
        },
        {
          key: 'break', label: txt('pomo.breakLen', 'Break'),
          minutes: m.break, min: 0, max: 120, step: 1,
          presets: [1, 3, 5, 10, 15, 30]
        }
      ],
      onPick: function (k, mins) {
        var s = S();
        var p = pomo();
        var field = k === 'break' ? 'breakMin' : 'pomodoroMin';
        s[field] = mins;
        var live = p.running && ((k === 'break') === (p.mode === 'break'));
        if (live) {
          save();
          if (window.App) {
            App.toast(txt('pomo.durNext', 'from the next block: {0}').replace('{0}', Wheel.label(mins)));
            App.render();
          }
          return;
        }
        /* Not running (or the other block): apply straight away. */
        if (k !== 'break' && p.mode === 'focus') { p.left = null; p.upBase = 0; p.upStart = null; }
        if (k === 'break' && p.mode === 'break') p.left = mins * 60;
        save();
        if (window.App) {
          App.toast(txt('pomo.durSet', 'length {0}').replace('{0}', Wheel.label(mins)));
          App.render();
        }
      }
    });
  }

  function stateText(p) {
    var up = isUp(p);
    var idle = !p.running && p.endsAt === null && p.left === null && !p.upStart && !(parseInt(p.upBase, 10) || 0);
    if (idle) return up ? txt('pomo.upReady', 'count-up ready') : txt('pomo.ready', 'ready');
    if (!p.running) return up ? txt('pomo.upPaused', 'count-up paused') : txt('pomo.paused', 'paused');
    if (p.mode === 'break') return txt('pomo.break', 'Break');
    return up ? txt('pomo.upRunning', 'counting up') : txt('pomo.focusing', 'Focusing');
  }

  function taskText(p) {
    if (!p.taskId) return txt('pomo.noTask', 'no task');
    var t = Store.findTask(p.taskId);
    return t ? t.text : txt('pomo.noTask', 'no task');
  }

  /* Queue block: what is being worked on now, what comes next, and how to
     change both. Rendered only when there is something to show plus a way to
     add -- an always-visible empty list is just noise. */
  function queueHtml(p) {
    var ids = queueAlive();
    var out = '<div class="card queue">' +
      '<div class="card-row"><span class="grow"><b>' + txt('pomo.queue', 'Queue') + '</b></span>' +
      '<span class="ev-meta">' + ids.length + '</span></div>';

    if (!ids.length) {
      out += '<div class="ev-meta q-empty">' + txt('pomo.queueEmpty', 'no queued tasks') + '</div>';
    } else {
      out += '<ol class="qlist">';
      ids.forEach(function (id, i) {
        var t = Store.findTask(id);
        if (!t) return;
        out += '<li class="qrow">' +
          '<span class="qnum">' + (i + 1) + '</span>' +
          '<span class="grow qname">' + esc2(t.text) + '</span>' +
          '<button class="mini-btn" data-act="fo-q-now" data-i="' + i + '">' +
          txt('pomo.queueNow', 'Now') + '</button>' +
          '<button class="mini-btn" data-act="fo-q-del" data-i="' + i + '">&times;</button>' +
          '</li>';
      });
      out += '</ol>';
    }

    var options = '';
    Store.tasks.forEach(function (t) {
      if (t.done) return;
      if (ids.indexOf(t.id) !== -1) return;
      options += '<option value="' + t.id + '">' + esc2(t.text) + '</option>';
    });
    if (options) {
      out += '<div class="qadd">' +
        '<select id="foQAdd">' + options + '</select>' +
        '<button class="mini-btn" data-act="fo-q-add">' +
        txt('pomo.queueAdd', 'Add') + '</button>' +
        '</div>';
    }
    if (ids.length) {
      out += '<div class="card-row" style="margin-top:8px">' +
        '<button class="mini-btn" data-act="fo-q-clear">' +
        txt('pomo.queueClear', 'Clear queue') + '</button></div>';
    }
    return out + '</div>';
  }

  function renderFocus(el) {
    var p = pomo();
    var secs = displaySecs(p);
    var running = p.running;
    var up = isUp(p);

    el.innerHTML =
      '<div class="sec-head"><h3>' + txt('nav.focus', 'Focus') + '</h3>' +
      '<span class="sub">' + fmt(S().focusTodayMin) + '</span></div>' +
      '<div class="focus-wrap">' +
      segHtml(p) +
      '<div class="focus-ring">' + ring(progress(p), up) +
      '<div style="text-align:center">' +
      '<div class="focus-time" id="foTime">' + fmtTime(secs) + '</div>' +
      '<div class="focus-state" id="foState">' + stateText(p) + '</div>' +
      '</div></div>' +
      '<div class="focus-task" id="foTask">' + esc2(taskText(p)) + '</div>' +
      durHtml(p) +
      '<div class="field" style="width:100%;max-width:340px">' +
      '<label>' + txt('fld.fo.task', 'Task') + '</label>' +
      '<select id="foTaskSel">' + taskOptions() + '</select></div>' +
      '<div class="focus-ctl">' +
      '<button class="btn btn-primary" data-act="fo-toggle" id="foMain">' + mainLabel(p) + '</button>' +
      '<button class="btn" data-act="fo-end">' + txt('pomo.endStat', 'End & log') + '</button>' +
      '<button class="btn btn-ghost" data-act="fo-reset">' + txt('focus.reset', 'Reset') + '</button>' +
      '</div>' +
      '<div class="ev-meta">' + txt('pomo.hint', '') + '</div>' +
      queueHtml(p) +
      '</div>';

    /* The task select and the queue's add-select are both live controls. */
    var sel = document.getElementById('foTaskSel');
    if (sel) {
      sel.addEventListener('change', function () {
        pomo().taskId = sel.value || null;
        save();
      });
    }
    var qadd = document.getElementById('foQAdd');
    if (qadd) {
      qadd.addEventListener('change', function () {
        if (!qadd.value) return;
        enqueue(qadd.value);
        if (window.App) App.render();
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
    var secs = displaySecs(p);
    var t = document.getElementById('foTime');
    if (t) t.textContent = fmtTime(secs);
    var s = document.getElementById('foState');
    if (s) s.textContent = stateText(p);
    var k = document.getElementById('foTask');
    if (k) k.textContent = taskText(p);
    var b = document.getElementById('foMain');
    if (b) b.textContent = mainLabel(p);
    var d = document.getElementById('foDur');
    if (d) d.textContent = fmtTime(total(p));
    var ringEl = document.querySelector('.focus-ring');
    if (ringEl) {
      /* Cheap: rebuild only the arc. */
      var svg = ringEl.querySelector('svg');
      if (svg) {
        var tmp = document.createElement('div');
        tmp.innerHTML = ring(progress(p), isUp(p));
        ringEl.replaceChild(tmp.firstChild, svg);
      }
    }
    paintMini();
  }

  /* ---- mini widget ---------------------------------------------------- */
  function paintMini() {
    var p = pomo();
    var onFocusView = window.App && App.currentView && App.currentView() === 'focus';

    if (!isLive(p) || onFocusView) { hideMini(); return; }

    var el = miniEl || (miniEl = document.createElement('div'));
    el.className = 'mini';
    el.innerHTML =
      '<span class="mini-time">' + fmtTime(displaySecs(p)) + '</span>' +
      (isUp(p) ? '<span class="mini-up">&#8593;</span>' : '') +
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
      /* Only a countdown can run out; a count-up runs until it is stopped. */
      if (!isUp(p) && remaining(p) <= 0) { complete(); return; }
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
    setDir: setDir,
    openPicker: openPicker,
    /* Test hook: the self test needs the live seconds without waiting. */
    seconds: displaySecs,
    /* Handles the data-act buttons used by both the view and the mini bar. */
    handle: function (act, el) {
      if (act === 'fo-toggle') { pomo().running ? pause() : start(); return true; }
      if (act === 'fo-end') { endAndLog(); if (window.App) App.render(); return true; }
      if (act === 'fo-reset') { reset(); if (window.App) App.render(); return true; }
      if (act === 'fo-dir' && el) {
        setDir(el.dataset.dir);
        if (window.App) App.render();
        return true;
      }
      if (act === 'fo-dur') { openPicker(); return true; }
      /* Queue buttons carry their row index in data-i. */
      if (act === 'fo-q-add') {
        var sel = document.getElementById('foQAdd');
        if (sel && sel.value) enqueue(sel.value);
        if (window.App) App.render();
        return true;
      }
      if (act === 'fo-q-del' && el) { dequeueAt(parseInt(el.dataset.i, 10)); if (window.App) App.render(); return true; }
      if (act === 'fo-q-clear') { clearQueue(); if (window.App) App.render(); return true; }
      if (act === 'fo-q-now' && el) {
        var i = parseInt(el.dataset.i, 10);
        var id = queueAlive()[i];
        if (id) {
          var p = pomo();
          p.taskId = id;
          p.queue = queueAlive().filter(function (x) { return x !== id; });
          save();
          if (window.App) App.render();
        }
        return true;
      }
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
