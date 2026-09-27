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
    try { testLunar(); } catch (e) { ok('lunar.crash', false, e.message); }
    try { testToday(); } catch (e) { ok('today.crash', false, e.message); }
    try { testStats(); } catch (e) { ok('stats.crash', false, e.message); }
    testQueue()
      .catch(function (e) { ok('queue.crash', false, e.message); })
      .then(function () {
        try { testDrag(); } catch (e) { ok('drag.crash', false, e.message); }
        try { testLayout(); } catch (e) { ok('layout.crash', false, e.message); }
        if (window.App) App.render();
        report();
      });
  }

  if (document.readyState === 'complete') setTimeout(run, 200);
  else window.addEventListener('load', function () { setTimeout(run, 200); });
})();
