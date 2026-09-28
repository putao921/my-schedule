/* Self test: drives the real UI in a real browser and prints PASS/FAIL lines.
 *
 * Loaded only for ?selftest=1 (app.js injects this tag), so it costs a byte of
 * nothing in normal use. It exists because these features cannot be verified
 * by reading the code: lunar labels, the drag gesture, and queue rotation are
 * all behaviour that only shows up when the DOM and the event loop are real.
 *
 * Output goes to a <pre> and to document.title so a headless --dump-dom run
 * can read it without a screenshot.
 */
(function () {
  'use strict';

  var R = [];
  function ok(name, cond, extra) {
    R.push((cond ? 'PASS ' : 'FAIL ') + name + (extra ? ' :: ' + extra : ''));
  }
  function click(sel) {
    var e = document.querySelector(sel);
    if (!e) return false;
    e.click();
    return true;
  }
  function view() { return document.getElementById('view'); }
  function count(sel) { return document.querySelectorAll(sel).length; }

  function pointer(type, x, y) {
    var target = document.elementFromPoint(x, y) || document;
    var ev = new PointerEvent(type, {
      bubbles: true, cancelable: true,
      clientX: x, clientY: y,
      pointerId: 7, pointerType: 'mouse', button: 0, buttons: 1
    });
    target.dispatchEvent(ev);
  }

  /* ---- 1. lunar calendar + festivals ---------------------------------- */
  function testLunar() {
    var i = Lunar.dayInfo('2026-09-25');
    ok('lunar.midAutumn', i.festival === '中秋节' && i.lunar.month === 8 && i.lunar.day === 15,
      i.full + '/' + i.festival);

    var e = view();
    Views.month(e, new Date(2026, 8, 1));
    var cell = e.querySelector('[data-date="2026-09-25"]');
    ok('month.cellFestival', !!cell && /中秋/.test(cell.textContent),
      cell ? cell.textContent.trim().slice(0, 24) : 'no cell');
    ok('month.cellHasLunar', !!cell && !!cell.querySelector('.day-lunar'));
    ok('month.holiClass', !!cell && cell.classList.contains('holi'));
    ok('month.holidayLine', /中秋节/.test(e.textContent),
      (e.querySelector('.hol-line') || {}).textContent || 'none');

    var nat = Lunar.dayInfo('2026-10-01');
    ok('lunar.nationalDay', nat.festival === '国庆节', String(nat.festival));
  }

  /* ---- 2. today view --------------------------------------------------- */
  function testToday() {
    /* Seed one overdue and one due-today task so both groups have content. */
    var t = Store.todayStr();
    var past = Store.iso(new Date(Date.now() - 3 * 86400000));
    var over = Store.newTask({ text: 'SELFTEST overdue', due: past });
    var due = Store.newTask({ text: 'SELFTEST due today', due: t });
    Store.newEvent({ date: t, start: 8 * 60, end: 9 * 60, title: 'SELFTEST event', tag: 'work' });
    Store.settings.focusLog[t] = 45;
    Store.persistSettings();

    ok('nav.todayExists', click('.nav-btn[data-view="today"]'));
    var e = view();
    ok('today.head', !!e.querySelector('.today-head'));
    ok('today.threeNums', count('.today-nums .tnum') === 3, String(count('.today-nums .tnum')));
    ok('today.lunarShown', /农历|八月|月/.test(e.querySelector('.today-head').textContent),
      e.querySelector('.today-head').textContent.trim().slice(0, 40));
    ok('today.overdueGroup', /SELFTEST overdue/.test(e.textContent));
    ok('today.dueGroup', /SELFTEST due today/.test(e.textContent));
    ok('today.eventRow', /SELFTEST event/.test(e.textContent));
    ok('today.lateBadge', !!e.querySelector('.late'), (e.querySelector('.late') || {}).textContent || '');

    /* Toggling the event must move the progress bar, not just the row. */
    var tick = e.querySelector('[data-act="toggle-ev"]');
    var bar = e.querySelector('.today-bar > i');
    var before = bar ? bar.style.width : '';
    if (tick) tick.click();
    var after = (view().querySelector('.today-bar > i') || {}).style.width || '';
    ok('today.progressMoves', before !== after, before + ' -> ' + after);

    Store.removeTask(over.id);
    Store.removeTask(due.id);
  }

  /* ---- 3. stats view --------------------------------------------------- */
  function testStats() {
    ok('nav.statsExists', click('.nav-btn[data-view="stats"]'));
    var e = view();
    ok('stats.tiles4', count('.tile') === 4, String(count('.tile')));
    ok('stats.twoCharts', count('.bars') === 2, String(count('.bars')));
    var cols = document.querySelectorAll('.bars');
    var c0 = cols[0] ? cols[0].querySelectorAll('.bar-col').length : 0;
    var c1 = cols[1] ? cols[1].querySelectorAll('.bar-col').length : 0;
    ok('stats.sevenCols', c0 === 7 && c1 === 7, c0 + '/' + c1);
    ok('stats.barHasHeight', !!e.querySelector('.bar-track') &&
      /height:\s*\d+%/.test(e.querySelector('.bar-track').getAttribute('style') || ''),
      (e.querySelector('.bar-track') || {}).getAttribute ? e.querySelector('.bar-track').getAttribute('style') : 'none');
    ok('stats.dist', count('.dist-row') >= 1, String(count('.dist-row')));
    /* Rendered height, not the style string: a % height inside an indefinite
       grid row parses to zero while the inline style still says "100%". */
    var tallest = 0;
    document.querySelectorAll('.bar-track').forEach(function (b) {
      var h = b.getBoundingClientRect().height;
      if (h > tallest) tallest = h;
    });
    ok('stats.barRendered', tallest > 10, 'tallest bar ' + Math.round(tallest) + 'px');
  }

  /* ---- 4. pomodoro queue ---------------------------------------------- */
  function testQueue() {
    var a = Store.newTask({ text: 'SELFTEST Q-A' });
    var b = Store.newTask({ text: 'SELFTEST Q-B' });
    ok('nav.focusExists', click('.nav-btn[data-view="focus"]'));

    function addToQueue(id) {
      var sel = document.getElementById('foQAdd');
      if (!sel) return false;
      sel.value = id;
      sel.dispatchEvent(new Event('change'));
      return true;
    }
    ok('queue.addA', addToQueue(a.id));
    ok('queue.addB', addToQueue(b.id));
    ok('queue.twoRows', count('.qlist .qrow') === 2, String(count('.qlist .qrow')));

    /* Rotation: force the countdown to expire and let the 1s loop complete it.
       Only a block that runs out on its own may consume a queue slot. */
    var p = Store.settings.pomo;
    p.queue = [a.id, b.id];
    p.taskId = null;
    p.mode = 'focus';
    p.running = true;
    p.endsAt = Date.now() - 500;
    p.left = 1;
    Store.persistSettings();

    return new Promise(function (resolve) {
      setTimeout(function () {
        var q = Store.settings.pomo;
        ok('queue.rotated', q.taskId === a.id, String(q.taskId === a.id));
        ok('queue.tail', q.queue.length === 2 && q.queue[0] === b.id && q.queue[1] === a.id,
          JSON.stringify(q.queue.map(function (id) {
            var t = Store.findTask(id);
            return t ? t.text : id;
          })));
        ok('queue.loggedFocus', (Store.focusOn(Store.todayStr()) || 0) >= 25,
          String(Store.focusOn(Store.todayStr())));
        /* Stop the timer again so later tests start from a clean state. */
        Focus.reset();
        Store.removeTask(a.id);
        Store.removeTask(b.id);
        resolve();
      }, 1400);
    });
  }

  /* ---- 5. cross-day drag ---------------------------------------------- */
  function testDrag() {
    ok('nav.weekExists', click('.nav-btn[data-view="week"]'));
    var blocks = document.querySelectorAll('.wk-ev');
    ok('week.hasBlocks', blocks.length > 0, String(blocks.length));
    if (!blocks.length) return;

    var el = blocks[0];
    var id = el.dataset.ev;
    var rec = Store.findEvent(id);
    var beforeDate = rec.date, beforeStart = rec.start;
    var beforeDur = (rec.end != null ? rec.end : rec.start + 60) - rec.start;

    var r = el.getBoundingClientRect();
    var sx = r.left + r.width / 2;
    var sy = Math.min(Math.max(r.top + 8, 40), window.innerHeight - 120);

    var cols = document.querySelectorAll('.week-col');
    var idx = 0;
    for (var i = 0; i < cols.length; i++) {
      if (cols[i].dataset.date === beforeDate) { idx = i; break; }
    }
    var tc = cols[(idx + 3) % cols.length];
    var tr = tc.getBoundingClientRect();
    var tx = tr.left + tr.width / 2;
    /* Keep the drop inside the viewport: elementFromPoint only sees what is
       on screen, and a week column is taller than the window. */
    var ty = Math.min(Math.max(tr.top + 150, 40), window.innerHeight - 100);

    pointer('pointerdown', sx, sy);
    pointer('pointermove', sx + 20, sy + 20);   /* past the 6px threshold */
    pointer('pointermove', tx, ty);
    var ghost = document.querySelector('.wk-ghost');
    ok('drag.ghostWithTag', !!ghost && !!ghost.querySelector('.ghost-tag'),
      ghost ? (ghost.querySelector('.ghost-tag') || {}).textContent : 'no ghost');
    pointer('pointerup', tx, ty);

    var after = Store.findEvent(id);
    ok('drag.crossDay', after.date !== beforeDate, beforeDate + ' -> ' + after.date);
    ok('drag.snapped15', after.start % 15 === 0, String(after.start));
    ok('drag.keptDuration', (after.end - after.start) === beforeDur,
      beforeDur + ' -> ' + (after.end - after.start));
    ok('drag.ghostRemoved', !document.querySelector('.wk-ghost'));
    /* Put it back so repeated runs are not cumulative. */
    Store.updateEvent(id, { date: beforeDate, start: beforeStart, end: beforeStart + 60 });
  }

  /* ---- 5c. the same gestures with a finger ------------------------------
   * Touch, not Pointer: iOS Safari still cancels the pointer mid-drag, so the
   * week view listens to Touch Events for fingers. A green drag suite that
   * only exercises Pointer Events says nothing about a phone. */
  function testTouchDrag() {
    if (typeof Touch === 'undefined' || typeof TouchEvent === 'undefined') {
      ok('touch.supported', false, 'no Touch/TouchEvent constructor');
      return;
    }
    /* Pick a block that is actually on screen: the drop target is resolved
       with elementFromPoint, which sees nothing outside the viewport -- a
       green "the finger moved" test that drops into the void is worthless. */
    var view = document.getElementById('view') || document.scrollingElement;
    var el = null;
    var all = document.querySelectorAll('.wk-ev');
    for (var k = 0; k < all.length; k++) {
      var rr0 = all[k].getBoundingClientRect();
      if (rr0.top > 40 && rr0.bottom < window.innerHeight - 30) { el = all[k]; break; }
    }
    if (!el && all.length) {
      el = all[0];
      if (el.scrollIntoView) el.scrollIntoView({ block: 'center' });
    }
    if (!el) { ok('touch.hasBlock', false, 'no block'); return; }
    var id = el.dataset.ev;
    var rec = Store.findEvent(id);
    if (!rec) { ok('touch.hasRecord', false, 'no record'); return; }

    var slotEl = document.querySelector('.week-slot');
    var slot = slotEl ? slotEl.getBoundingClientRect().height : 40;
    if (!(slot > 4)) slot = 40;

    function fire(type, x, y, target) {
      var t = new Touch({ identifier: 7, target: target, clientX: x, clientY: y });
      var list = (type === 'touchend') ? [] : [t];
      var ev = new TouchEvent(type, {
        bubbles: true, cancelable: true,
        touches: list, targetTouches: list, changedTouches: [t]
      });
      (target || document).dispatchEvent(ev);
      return ev;
    }

    var before = { date: rec.date, start: rec.start };
    var beforeDur = (rec.end != null ? rec.end : rec.start + 60) - rec.start;

    var r = el.getBoundingClientRect();
    var x = r.left + r.width / 2;
    var y = r.top + r.height / 2;
    /* Keep the finger inside the viewport for the whole gesture. */
    var dy = Math.min(slot * 2, Math.max(20, window.innerHeight - 60 - y));
    if (dy < 20) { y = Math.max(60, window.innerHeight - 60 - slot * 2); dy = slot * 2; }

    fire('touchstart', x, y, el);
    var moved = null;
    for (var i = 1; i <= 8; i++) {
      moved = fire('touchmove', x, y + dy * (i / 8), el);
    }
    /* The whole point of owning the gesture: the browser must be told not to
       scroll. iOS stops honouring preventDefault after the first move. */
    ok('touch.preventDefault', !!moved && moved.defaultPrevented);
    var g1 = document.querySelectorAll('.wk-ghost').length;
    ok('touch.ghost', g1 > 0, 'ghosts=' + g1);
    ok('touch.dropLine', !!document.querySelector('.week-dropline'), 'no drop line');
    fire('touchend', x, y + dy, el);

    var after = Store.findEvent(id);
    ok('touch.moved', after.start !== before.start || after.date !== before.date,
      before.start + ' -> ' + after.start);
    ok('touch.snapped15', after.start % 15 === 0, String(after.start));
    ok('touch.keptDuration', (after.end - after.start) === beforeDur,
      beforeDur + ' -> ' + (after.end - after.start));
    ok('touch.ghostRemoved', !document.querySelector('.wk-ghost'));

    /* Bottom grip: stretch the end. */
    var el2 = document.querySelector('.wk-ev[data-ev="' + id + '"]') || el;
    var grip = el2.querySelector('.wk-h-bot');
    ok('touch.hasGrip', !!grip);
    if (grip) {
      var b2 = Store.findEvent(id);
      var endBefore = b2.end != null ? b2.end : b2.start + 60;
      var rr = el2.getBoundingClientRect();
      var g = grip.getBoundingClientRect();
      var gx = g.left + g.width / 2, gy = g.top + g.height / 2;
      var gdy = Math.min(slot, Math.max(20, window.innerHeight - 40 - gy));
      if (gdy < 20) { gy = Math.max(60, window.innerHeight - 40 - slot); gdy = slot; }
      fire('touchstart', gx, gy, grip);
      for (var j = 1; j <= 8; j++) fire('touchmove', gx, gy + gdy * (j / 8), grip);
      fire('touchend', gx, gy + gdy, grip);
      var a2 = Store.findEvent(id);
      var endAfter = a2.end != null ? a2.end : a2.start + 60;
      ok('touch.resized', endAfter !== endBefore, endBefore + ' -> ' + endAfter);
      ok('touch.resizeKeepsStart', a2.start === b2.start, b2.start + ' -> ' + a2.start);
    }

    Store.updateEvent(id, { date: before.date, start: before.start, end: before.start + 60 });
  }

  /* ---- 5d. undo / redo --------------------------------------------------
   * The week view is drag-first, so a mis-drop has to be reversible. Covered
   * through the Store the same way a drag writes it (updateEvent). */
  function testUndo() {
    if (!window.Undo) { ok('undo.exists', false, 'no Undo module'); return; }
    ok('undo.buttons', !!document.querySelector('[data-act="undo"]') &&
      !!document.querySelector('[data-act="redo"]'), 'missing in week header');

    var e = Store.newEvent({ date: '2026-11-02', start: 9 * 60, end: 10 * 60, title: '可撤销', tag: 'work' });
    var id = e.id;
    /* A drag: same write path (updateEvent with date + start + end). */
    Store.updateEvent(id, { date: '2026-11-04', start: 14 * 60, end: 15 * 60 });
    var moved = Store.findEvent(id);
    ok('undo.setup', moved.date === '2026-11-04' && moved.start === 840, moved.date + ' ' + moved.start);

    click('[data-act="undo"]');
    var back = Store.findEvent(id);
    ok('undo.restored', back && back.date === '2026-11-02' && back.start === 540,
      back ? back.date + ' ' + back.start : 'gone');
    ok('undo.toast', !!document.querySelector('.toast'), 'no feedback');

    click('[data-act="redo"]');
    var again = Store.findEvent(id);
    ok('undo.redone', again && again.date === '2026-11-04' && again.start === 840,
      again ? again.date + ' ' + again.start : 'gone');

    /* A delete is undoable too -- the other way to lose an entry. */
    Store.removeEvent(id);
    ok('undo.deleted', !Store.findEvent(id));
    click('[data-act="undo"]');
    ok('undo.undeleted', !!Store.findEvent(id), 'delete was not undoable');

    /* Buttons must show what is actually possible. */
    var u = document.querySelector('[data-act="undo"]');
    ok('undo.buttonState', u && u.disabled === !Undo.canUndo(),
      u ? 'disabled=' + u.disabled + ' canUndo=' + Undo.canUndo() : 'no button');

    /* Settings are NOT part of the history: undoing a mis-drag must not also
       rewind the font size chosen a minute ago. */
    var fs = Store.settings.fontScale;
    Store.settings.fontScale = 1.3; Store.persistSettings();
    click('[data-act="undo"]');
    ok('undo.keepsSettings', Store.settings.fontScale === 1.3,
      String(Store.settings.fontScale));
    Store.settings.fontScale = fs; Store.persistSettings();

    var del = Store.findEvent(id);
    if (del) Store.removeEvent(id);
  }

  /* ---- 5b. count-up + wheel duration picker --------------------------- */
  function testRepeat() {
    /* weekly: every week from Mon 2026-09-28 */
    var base = '2026-09-28';
    var ev = Store.newEvent({ date: base, start: 10 * 60, end: 11 * 60, title: '周会', tag: 'work', repeat: 'weekly', repeatEvery: 1 });
    var id = ev.id;
    var next = Store.expandedEventsOn('2026-10-05');
    ok('repeat.weeklyNext', next.some(function (e) { return e.id === id + '@2026-10-05'; }), 'n=' + next.length);
    var tue = Store.expandedEventsOn('2026-09-29');
    ok('repeat.weeklySkip', !tue.some(function (e) { return e.id === id + '@2026-09-29'; }));
    /* until boundary is inclusive */
    Store.updateEvent(id, { repeatUntil: '2026-10-12' });
    ok('repeat.untilStop', !Store.expandedEventsOn('2026-10-19').some(function (e) { return e.id === id + '@2026-10-19'; }));
    ok('repeat.untilIncl', Store.expandedEventsOn('2026-10-12').some(function (e) { return e.id === id + '@2026-10-12'; }));
    Store.updateEvent(id, { repeatUntil: '' });
    /* daily every 2 */
    var d = Store.newEvent({ date: '2026-01-01', start: 9 * 60, end: 10 * 60, title: '双日', repeat: 'daily', repeatEvery: 2 });
    ok('repeat.dailyEvery2', Store.expandedEventsOn('2026-01-03').some(function (e) { return e.id === d.id + '@2026-01-03'; }));
    ok('repeat.dailySkip', !Store.expandedEventsOn('2026-01-02').some(function (e) { return e.id === d.id + '@2026-01-02'; }));
    /* monthly last day: 01-31 -> 02-28 (2026 is not a leap year) */
    var m = Store.newEvent({ date: '2026-01-31', start: 9 * 60, end: 10 * 60, title: '月末', repeat: 'monthly', repeatEvery: 1, repeatMonthMode: 'last' });
    ok('repeat.monthLast', Store.expandedEventsOn('2026-02-28').some(function (e) { return e.id === m.id + '@2026-02-28'; }));
    /* yearly */
    var y = Store.newEvent({ date: '2026-03-01', start: 9 * 60, end: 10 * 60, title: '年庆', repeat: 'yearly', repeatEvery: 1 });
    ok('repeat.yearlyNext', Store.expandedEventsOn('2027-03-01').some(function (e) { return e.id === y.id + '@2027-03-01'; }));

    /* Dragging ONE occurrence of a series must become a per-date exception:
       this is what a finger-drag of a repeating class writes through. */
    var s = Store.newEvent({ date: base, start: 8 * 60, end: 9 * 60, title: '系列课', tag: 'work', repeat: 'weekly', repeatEvery: 1 });
    var instId = s.id + '@2026-10-05';
    Store.updateEvent(instId, { start: 10 * 60, end: 11 * 60 });
    var ex1 = Store.expandedEventsOn('2026-10-05').filter(function (e) { return e.id === instId; })[0] || {};
    ok('repeat.exResized', ex1.start === 600 && ex1.end === 660, JSON.stringify(ex1.start) + '/' + JSON.stringify(ex1.end));
    var sameWeek = Store.expandedEventsOn('2026-10-12').filter(function (e) { return e.id === s.id + '@2026-10-12'; })[0] || {};
    ok('repeat.exIsolated', sameWeek.start === 480, String(sameWeek.start));
    Store.updateEvent(instId, { date: '2026-10-07', start: 14 * 60, end: 15 * 60 });
    var wed = Store.expandedEventsOn('2026-10-07').filter(function (e) { return e.id === instId; })[0] || {};
    ok('repeat.exMoved', wed.date === '2026-10-07' && wed.start === 840, JSON.stringify(wed));
    ok('repeat.exVacated', !Store.expandedEventsOn('2026-10-05').some(function (e) { return e.id === instId; }));
    var kept = Store.expandedEventsOn('2026-10-12').filter(function (e) { return e.id === s.id + '@2026-10-12'; })[0] || {};
    ok('repeat.exSeriesKept', kept.start === 480, String(kept.start));
    Store.removeEvent(s.id);
    /* Editing an occurrence is a per-date exception now; the base record is
       only touched when the base id itself is used. */
    Store.updateEvent(id + '@2026-10-05', { title: '周会改' });
    var exOcc = Store.expandedEventsOn('2026-10-05').filter(function (e) { return e.id === id + '@2026-10-05'; })[0] || {};
    ok('repeat.editInstance', exOcc.title === '周会改' && Store.findEvent(id).title === '周会',
      JSON.stringify(exOcc.title) + '/' + String(Store.findEvent(id).title));
    Store.updateEvent(id, { title: '系列改名' });
    ok('repeat.editBase', Store.findEvent(id).title === '系列改名', String(Store.findEvent(id).title));
    /* cleanup so repeated runs stay clean */
    Store.removeEvent(id); Store.removeEvent(d.id); Store.removeEvent(m.id); Store.removeEvent(y.id);
  }

  /* Calendar navigation (month / week) — free scrolling, not just the current
     period. Verifies the prev/next/today controls move the cursor and re-render. */
  /* Week view: visible range, overlapping blocks, now marker, resize grips,
     text scaling and hex-colour readability. */
  function testWeek() {
    click('.nav-btn[data-view="week"]');
    var today = Store.todayStr();

    /* ---- visible hours ------------------------------------------- */
    var ws0 = Store.settings.weekStart, we0 = Store.settings.weekEnd;
    Store.settings.weekStart = 9; Store.settings.weekEnd = 17;
    App.render();
    ok('week.rangeHours', count('.week-hours .week-hour') === 8,
      String(count('.week-hours .week-hour')));
    ok('week.rangeSlots', count('.week-col .week-slot') === 8 * 7,
      String(count('.week-col .week-slot')));
    Store.settings.weekStart = ws0; Store.settings.weekEnd = we0;
    App.render();
    ok('week.fullHours', count('.week-hours .week-hour') === 24,
      String(count('.week-hours .week-hour')));

    /* ---- "now" marker -------------------------------------------- */
    /* Drawn at most once, and only on today's column. */
    var nowN = count('.week-now');
    ok('week.nowAtMostOne', nowN <= 1, String(nowN));
    ok('week.nowOnToday', nowN === 0 || count('.week-now') === count('.week-col.today .week-now'),
      'now=' + nowN + ' todayCol=' + count('.week-col.today'));

    /* ---- overlapping events -------------------------------------- */
    var a = Store.newEvent({ date: today, start: 600, end: 660, title: 'ov-a', tag: 'work' });
    var b = Store.newEvent({ date: today, start: 620, end: 700, title: 'ov-b', tag: 'life' });
    App.render();
    var blocks = [];
    Array.prototype.forEach.call(document.querySelectorAll('.wk-ev'), function (n) {
      var ti = n.getAttribute('title') || '';
      if (ti === 'ov-a' || ti === 'ov-b') blocks.push(n);
    });
    ok('week.overlapBoth', blocks.length === 2, String(blocks.length));
    if (blocks.length === 2) {
      var col = blocks[0].parentNode;
      var cw = col.getBoundingClientRect().width;
      var ra = blocks[0].getBoundingClientRect(), rb = blocks[1].getBoundingClientRect();
      ok('week.overlapNarrower', ra.width < cw * 0.8 && rb.width < cw * 0.8,
        Math.round(ra.width) + '/' + Math.round(rb.width) + ' of ' + Math.round(cw));
      ok('week.overlapSideBySide', Math.abs(ra.left - rb.left) > 4,
        Math.round(ra.left) + ' vs ' + Math.round(rb.left));
      ok('week.overlapSameTop', Math.abs(ra.top - rb.top) < cw,
        Math.round(ra.top) + ' vs ' + Math.round(rb.top));
    }

    /* ---- resize grips -------------------------------------------- */
    ok('week.gripTop', count('.wk-ev .wk-h[data-handle="top"]') >= 2,
      String(count('.wk-ev .wk-h[data-handle="top"]')));
    ok('week.gripBottom', count('.wk-ev .wk-h[data-handle="bottom"]') >= 2,
      String(count('.wk-ev .wk-h[data-handle="bottom"]')));

    Store.removeEvent(a.id); Store.removeEvent(b.id);

    /* ---- text scaling -------------------------------------------- */
    var fs0 = Store.settings.fontScale;
    Store.settings.fontScale = 1.3;
    App.applyFont();
    var got = getComputedStyle(document.documentElement).getPropertyValue('--fs').trim();
    ok('week.fontScale', Math.abs(parseFloat(got) - 1.3) < 0.01, got);
    Store.settings.fontScale = fs0;
    App.applyFont();

    /* ---- gesture affordances -------------------------------------- */
    var ev0 = document.querySelector('.wk-ev');
    ok('week.touchActionNone', ev0 && getComputedStyle(ev0).touchAction === 'none',
      ev0 ? getComputedStyle(ev0).touchAction : 'no block');
    var grip = document.querySelector('.wk-h');
    ok('week.gripHasSize', grip && grip.getBoundingClientRect().height >= 12,
      grip ? String(Math.round(grip.getBoundingClientRect().height)) : 'no grip');

    /* ---- night theme desaturates hex picks ------------------------ */
    if (window.Views && Views.tagStyle && Store.settings.tags.length) {
      var tn = Store.settings.tags[0], ocN = tn.color, th0 = Store.settings.theme;
      tn.color = '#ff0000';
      Store.settings.theme = 'light';
      var dayC = Views.tagStyle(tn.key).bg;
      Store.settings.theme = 'night';
      var nightC = Views.tagStyle(tn.key).bg;
      Store.settings.theme = th0; tn.color = ocN;
      ok('week.nightDesaturates', dayC !== nightC && /^#[0-9a-f]{6}$/i.test(nightC),
        dayC + ' -> ' + nightC);
      /* Preset colours stay variable-driven and therefore theme-aware. */
      var tp = Store.settings.tags[0];
      var opC = tp.color; tp.color = '--accent';
      ok('week.presetStaysVar', Views.tagStyle(tp.key).bg.indexOf('var(') === 0,
        Views.tagStyle(tp.key).bg);
      tp.color = opC;
    }

    /* ---- hex colours stay readable -------------------------------- */
    if (window.Views && Views.tagStyle && Store.settings.tags.length) {
      var tg = Store.settings.tags[0], oldC = tg.color;
      tg.color = '#fafafa';
      ok('week.lightNeedsDarkText', Views.tagStyle(tg.key).fg === '#111418',
        Views.tagStyle(tg.key).fg);
      tg.color = '#101010';
      ok('week.darkNeedsLightText', Views.tagStyle(tg.key).fg === '#ffffff',
        Views.tagStyle(tg.key).fg);
      tg.color = oldC;
    } else {
      ok('week.tagStyleExported', false, 'Views.tagStyle missing');
    }
    App.render();
  }

  function testNav() {
    function title() {
      var h = view().querySelector('.cal-title h3');
      return h ? h.textContent : '';
    }
    ok('nav.goMonth', click('.nav-btn[data-view="month"]'));
    ok('nav.monthButtons',
      count('.cal-btn[data-act="cal-prev"]') === 1 &&
      count('.cal-btn[data-act="cal-next"]') === 1 &&
      count('[data-act="cal-today"]') === 1);
    var t0 = title();
    ok('nav.monthTitle', !!t0, t0);
    click('[data-act="cal-next"]');
    var t1 = title();
    ok('nav.monthNext', t1 && t1 !== t0, t0 + ' -> ' + t1);
    click('[data-act="cal-prev"]');
    ok('nav.monthBack', title() === t0, title() + ' (want ' + t0 + ')');
    click('[data-act="cal-today"]');
    ok('nav.monthToday', title() === t0, title() + ' (want ' + t0 + ')');

    ok('nav.goWeek', click('.nav-btn[data-view="week"]'));
    ok('nav.weekButtons',
      count('.cal-btn[data-act="cal-prev"]') === 1 &&
      count('.cal-btn[data-act="cal-next"]') === 1);
    var w0 = title();
    ok('nav.weekTitle', !!w0, w0);
    click('[data-act="cal-next"]');
    var w1 = title();
    ok('nav.weekNext', w1 && w1 !== w0, w0 + ' -> ' + w1);
    click('[data-act="cal-prev"]');
    ok('nav.weekBack', title() === w0, title() + ' (want ' + w0 + ')');
  }

  function testTimer() {
    ok('nav.focusAgain', click('.nav-btn[data-view="focus"]'));
    ok('timer.currentIsFocus', window.App && App.currentView() === 'focus',
      String(window.App ? App.currentView() : 'no App'));
    ok('timer.viewIsFocus', view().dataset.view === 'focus', view().dataset.view);
    Focus.reset();

    ok('timer.segTwo', count('.seg-btn') === 2, String(count('.seg-btn')));
    var dur = document.getElementById('foDur');
    ok('timer.durShown', !!dur, dur ? dur.textContent : 'none');

    /* Count up: the number must climb from zero, and pausing must bank the
       seconds so a reload or a resume keeps counting from where it stopped. */
    click('.seg-btn[data-dir="up"]');
    ok('timer.dirUp', Store.settings.pomo.dir === 'up', String(Store.settings.pomo.dir));
    ok('timer.upHidesLength', !document.getElementById('foDur'));

    var p = Store.settings.pomo;
    p.running = true;
    p.upStart = Date.now() - 125000;
    p.upBase = 0;
    Store.persistSettings();
    Focus.paint();
    var shown = (document.getElementById('foTime') || {}).textContent;
    ok('timer.countsUp', shown === '02:05', String(shown));
    ok('timer.upState', /正计时|count/i.test((document.getElementById('foState') || {}).textContent || ''),
      (document.getElementById('foState') || {}).textContent);

    Focus.pause();
    var banked = Store.settings.pomo.upBase;
    ok('timer.upBanked', banked >= 124 && banked <= 127, String(banked));
    ok('timer.upStopped', !Store.settings.pomo.running && !Store.settings.pomo.upStart);

    /* Past 99 minutes the two-digit padding must not wrap it back to 05:00. */
    p.running = true;
    p.upStart = Date.now() - 6300000;
    p.upBase = 0;
    Focus.paint();
    var long = (document.getElementById('foTime') || {}).textContent;
    ok('timer.over99', long === '105:00', String(long));

    /* Ending a count-up logs the minutes actually sat. */
    var before = Store.focusOn(Store.todayStr()) || 0;
    Focus.end();
    ok('timer.upLogged', (Store.focusOn(Store.todayStr()) || 0) - before >= 100,
      before + ' -> ' + (Store.focusOn(Store.todayStr()) || 0));

    click('.seg-btn[data-dir="down"]');
    ok('timer.dirDown', Store.settings.pomo.dir === 'down', String(Store.settings.pomo.dir));
    ok('timer.durBack', !!document.getElementById('foDur'));

    /* ---- the wheel picker ---- */
    ok('timer.pickerOpens', click('[data-act="fo-dur"]'));
    var box = document.querySelector('.wheel-box');
    ok('timer.wheelOpen', !!box && !box.hidden);
    ok('timer.twoWheels', count('.wh-col') === 2, String(count('.wh-col')));
    ok('timer.twoTabs', count('.wtab') === 2, String(count('.wtab')));
    ok('timer.bandAligned', (function () {
      var c = document.querySelector('.wh-col[data-col="m"]');
      var b = document.querySelector('.wh-band');
      if (!c || !b) return false;
      var cr = c.getBoundingClientRect(), br = b.getBoundingClientRect();
      return Math.abs((cr.top + cr.height / 2) - (br.top + br.height / 2)) <= 2;
    })(), 'wheel centre vs band centre');

    var pre45 = document.querySelector('.wpreset[data-min="45"]');
    ok('timer.presetExists', !!pre45);
    if (pre45) pre45.click();
    ok('timer.presetMarked', !!pre45 && pre45.classList.contains('on'));
    click('.wheel-foot [data-wact="ok"]');
    ok('timer.durApplied', Store.settings.pomodoroMin === 45, String(Store.settings.pomodoroMin));
    ok('timer.wheelClosed', !!document.querySelector('.wheel-box') &&
      document.querySelector('.wheel-box').hidden);
    var d2 = (document.getElementById('foDur') || {}).textContent;
    ok('timer.durLabel', d2 === '45:00', String(d2));

    /* Scrolling the minute wheel must actually change the value: the index
       maths (scrollTop / 40) is the part that can silently drift. */
    click('[data-act="fo-dur"]');
    /* A real spin always starts with a finger/wheel on the column, and the
       picker only trusts the wheel position when it saw that gesture. */
    var mc = document.querySelector('.wh-col[data-col="m"]');
    var hc = document.querySelector('.wh-col[data-col="h"]');
    if (mc) {
      mc.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
      mc.scrollTop = 30 * 40;
      mc.dispatchEvent(new Event('scroll'));
    }
    if (hc) { hc.scrollTop = 0; hc.dispatchEvent(new Event('scroll')); }

    return new Promise(function (resolve) {
      setTimeout(function () {
        var marked = document.querySelector('.wh-item.on');
        ok('timer.scrollMarked', !!marked && marked.dataset.v !== undefined,
          marked ? marked.dataset.v : 'none');
        click('.wheel-foot [data-wact="ok"]');
        ok('timer.scrollValue', Store.settings.pomodoroMin === 30,
          String(Store.settings.pomodoroMin));

        /* The break tab writes the other field. */
        click('[data-act="fo-dur"]');
        var tb = document.querySelector('.wtab[data-key="break"]');
        if (tb) tb.click();
        var pre10 = document.querySelector('.wpreset[data-min="10"]');
        ok('timer.breakPreset', !!pre10);
        if (pre10) pre10.click();
        click('.wheel-foot [data-wact="ok"]');
        ok('timer.breakApplied', Store.settings.breakMin === 10, String(Store.settings.breakMin));

        /* Leave the settings as they were found. */
        Store.settings.pomodoroMin = 25;
        Store.settings.breakMin = 5;
        Store.persistSettings();
        Focus.reset();
        resolve();
      }, 240);
    });
  }

  /* ---- 6. layout sanity ------------------------------------------------ */
  function testLayout() {
    ok('layout.noHOverflow', document.documentElement.scrollWidth <= window.innerWidth + 1,
      document.documentElement.scrollWidth + ' vs ' + window.innerWidth);
    ok('layout.navEight', count('.nav-btn') === 8, String(count('.nav-btn')));
    var nav = document.querySelector('.nav').getBoundingClientRect();
    ok('layout.navVisible', nav.width > 0 && nav.height > 0,
      Math.round(nav.width) + 'x' + Math.round(nav.height));
  }

  function report() {
    var fails = R.filter(function (x) { return x.indexOf('FAIL') === 0; }).length;
    var text = 'SELFTEST ' + (R.length - fails) + '/' + R.length + ' passed\n' + R.join('\n');
    var pre = document.createElement('pre');
    pre.id = 'selftestReport';
    pre.textContent = text;
    document.body.appendChild(pre);
    document.title = 'SELFTEST ' + (R.length - fails) + '/' + R.length;
  }

  function run() {
    /* An exception inside a click listener never reaches the caller, so a
       view that throws looks exactly like a view that is missing. Surface it. */
    window.addEventListener('error', function (e) {
      R.push('FAIL js.error :: ' + (e.message || '?') + ' @' + (e.lineno || '?'));
    });
    try { testLunar(); } catch (e) { ok('lunar.crash', false, e.message); }
    try { testToday(); } catch (e) { ok('today.crash', false, e.message); }
    try { testRepeat(); } catch (e) { ok('repeat.crash', false, e.message); }
    try { testWeek(); } catch (e) { ok('week.crash', false, e.message); }
    try { testNav(); } catch (e) { ok('nav.crash', false, e.message); }
    try { testStats(); } catch (e) { ok('stats.crash', false, e.message); }
    testQueue()
      .catch(function (e) { ok('queue.crash', false, e.message); })
      .then(function () {
        try { testDrag(); } catch (e) { ok('drag.crash', false, e.message); }
        try { testTouchDrag(); } catch (e) { ok('touch.crash', false, e.message); }
        try { testUndo(); } catch (e) { ok('undo.crash', false, e.message); }
      })
      .then(function () {
        return new Promise(function (resolve) {
          try { resolve(testTimer()); } catch (e) { ok('timer.crash', false, e.message); resolve(); }
        });
      })
      .then(function () {
        try { testLayout(); } catch (e) { ok('layout.crash', false, e.message); }
        if (window.App) App.render();
        report();
      });
  }

  if (document.readyState === 'complete') setTimeout(run, 200);
  else window.addEventListener('load', function () { setTimeout(run, 200); });
})();
