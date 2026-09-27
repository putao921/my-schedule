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

  /* ---- 5b. count-up + wheel duration picker --------------------------- */
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
    try { testStats(); } catch (e) { ok('stats.crash', false, e.message); }
    testQueue()
      .catch(function (e) { ok('queue.crash', false, e.message); })
      .then(function () {
        try { testDrag(); } catch (e) { ok('drag.crash', false, e.message); }
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
