/* Drag-to-reschedule across days (week view) and across weeks (month view).
 *
 * Mouse/pen: Pointer Events, drag starts after a few pixels of movement.
 * Touch: plain Touch Events, NOT Pointer Events. Pointer Events exist on iOS
 * 13+ but Safari still cancels the pointer (pointercancel) as soon as it
 * decides the gesture might be a scroll/selection, and by then touchmove is
 * no longer cancelable -- the drag died mid-finger. Touch Events plus an
 * immediate preventDefault on the first owned move is the only thing that
 * behaves the same on iOS Safari, Android Chrome and a desktop browser with
 * touch emulation.
 *
 * Two things make this feel finished rather than merely functional:
 *   - the ghost carries the drop target and time, so a cross-day move is
 *     confirmed before the finger lifts;
 *   - the view auto-scrolls near its edges, because a day can be far off
 *     screen in a 24-hour column and a drag cannot reach what is not visible.
 */
(function () {
  'use strict';

  var HOLD_MS = 260;      /* touch: how long before a press becomes a drag */
  var MOVE_PX = 6;        /* mouse: how far before a press becomes a drag */
  var TOUCH_PX = 9;       /* touch: a finger is sloppier than a cursor */

  /* Blocks set touch-action:none, so the browser never steals the gesture for
     scrolling -- but that also means a move must ALWAYS start the drag. The
     old code cancelled a touch move before the hold completed, which is why
     dragging felt dead on a phone. */
  var EDGE_PX = 52;       /* distance from a view edge that starts scrolling */
  var CLICK_GUARD_MS = 320;

  var src = null;         /* { id, el } */
  var ghost = null;
  var ghostTag = null;
  var holdTimer = null;
  var startX = 0, startY = 0;
  var lastX = 0, lastY = 0;
  var dragging = false;
  var armed = false;      /* press seen, waiting to decide drag vs scroll */
  var pointerId = null;
  var viaTouch = false;   /* current gesture comes from a finger */
  var suppressClick = false;

  var mode = 'move';      /* 'move' (whole block) or 'resize' (top/bottom edge) */
  var edge = null;        /* 'top' | 'bottom' while resizing */
  var rbadge = null;      /* live "09:00 - 10:30" readout while resizing */
  var dropLine = null;    /* horizontal line showing the snapped drop time */
  var pending = null;     /* { start, end } staged by a resize */

  /* Visible window, in minutes. The week grid can show a sub-range of the day,
     so every y -> time conversion must be relative to that window, not to
     midnight -- otherwise dragging inside a 09:00-18:00 grid lands 9h off. */
  function windowMins() {
    var s = (window.Store && Store.settings) || {};
    var ws = Math.max(0, Math.min(23, s.weekStart | 0));
    var we = s.weekEnd | 0;
    if (!we || we <= ws) we = 24;
    we = Math.min(24, we);
    return { lo: ws * 60, hi: we * 60 };
  }

  /* Snap to 15 minutes: finer than that is unreadable on a phone and the
     stored event would look different from what the grid shows. */
  function snap(m) { return Math.round(m / 15) * 15; }

  function slotH() {
    var el = document.querySelector('.week-slot');
    if (el) {
      var h = el.getBoundingClientRect().height;
      if (h > 4) return h;
    }
    var raw = getComputedStyle(document.documentElement).getPropertyValue('--slot-h');
    var n = parseInt(raw, 10);
    return n > 0 ? n : 40;
  }

  /* Shared by mouse/pen (Pointer Events) and finger (Touch Events): every
     gesture is reduced to press / move / release so the two transports cannot
     drift apart. */
  function press(x, y, target, touch) {
    if (target && target.closest && target.closest('[data-act]')) return;
    var el = target && target.closest ? target.closest('[data-ev]') : null;
    if (!el) return;

    /* Grabbing the top/bottom grip resizes instead of moving. */
    var hand = target.closest('[data-handle]');
    mode = hand ? 'resize' : 'move';
    edge = hand ? hand.dataset.handle : null;

    src = { id: el.dataset.ev, el: el };
    startX = x; startY = y; lastX = x; lastY = y;
    armed = true; dragging = false;
    viaTouch = !!touch;

    /* A finger that presses and waits also gets a drag -- otherwise people
       conclude "you have to be quick" and give up. */
    if (touch) {
      clearTimeout(holdTimer);
      holdTimer = setTimeout(function () { if (armed) begin(lastX, lastY); }, HOLD_MS);
    }
  }

  function travel(x, y) {
    if (!armed && !dragging) return false;
    lastX = x; lastY = y;

    if (dragging) {
      if (mode === 'resize') { resizeAt(y); moveRBadge(x, y); return true; }
      moveGhost(x, y);
      var info = targetInfo(x, y);
      highlight(info);
      paintTag(info);
      showDropLine(info);
      autoScroll(y);
      return true;
    }
    /* Not yet dragging: any move past the threshold starts it. The block
       declares touch-action:none, so there is no competing scroll gesture
       that we would have to disambiguate from. */
    var dx = Math.abs(x - startX), dy = Math.abs(y - startY);
    var need = viaTouch ? TOUCH_PX : MOVE_PX;
    if (dx > need || dy > need) begin(x, y);
    return dragging;
  }

  function release(x, y) {
    clearTimeout(holdTimer);
    if (!armed && !dragging) return;
    var wasDragging = dragging;
    var info = wasDragging ? targetInfo(x, y) : null;
    var commitResize = wasDragging && mode === 'resize' && pending;
    cancel();
    if (commitResize) { applyResize(); return; }
    if (wasDragging) {
      /* The browser still fires a click after this release. Without the
         guard, dropping a card back where it was also opens its editor --
         which looks like the app mis-read a drag as a tap. */
      suppressClick = true;
      setTimeout(function () { suppressClick = false; }, CLICK_GUARD_MS);
      drop(info);
    }
  }

  function cancel() {
    clearTimeout(holdTimer);
    armed = false;
    if (dragging && src) src.el.classList.remove('is-drag', 'is-resize');
    dragging = false;
    if (ghost && ghost.parentNode) ghost.parentNode.removeChild(ghost);
    ghost = null; ghostTag = null;
    if (rbadge && rbadge.parentNode) rbadge.parentNode.removeChild(rbadge);
    rbadge = null;
    clearDropLine();
    mode = 'move'; edge = null;
    Array.prototype.forEach.call(document.querySelectorAll('.drop-on'), function (n) {
      n.classList.remove('drop-on');
    });
  }

  /* ---- resize ------------------------------------------------------- */

  function showRBadge() {
    rbadge = document.createElement('div');
    rbadge.className = 'resize-badge';
    document.body.appendChild(rbadge);
  }
  function moveRBadge(x, y) {
    if (!rbadge) return;
    rbadge.style.left = x + 'px';
    rbadge.style.top = y + 'px';
  }

  /* Drag the edge, keep the other edge pinned, never shorter than 15 min. */
  function resizeAt(y) {
    if (!src) return;
    var col = src.el.parentNode;
    if (!col || !col.classList || !col.classList.contains('week-col')) return;
    var r = col.getBoundingClientRect();
    if (r.height <= 0) return;
    var w = windowMins();
    var rec = Store.findEvent(src.id);
    if (!rec) return;

    var mins = snap(w.lo + ((y - r.top) / r.height) * (w.hi - w.lo));
    mins = Math.max(w.lo, Math.min(w.hi, mins));

    var st = rec.start || 0;
    var en = rec.end != null ? rec.end : st + 60;
    if (en <= st) en = st + 30;

    if (edge === 'top') {
      if (mins > en - 15) mins = en - 15;
      st = Math.max(w.lo, mins);
    } else {
      if (mins < st + 15) mins = st + 15;
      en = Math.min(w.hi, mins);
    }
    pending = { start: st, end: en };

    /* Live preview: move the real block so the user sees the new span, plus
       an exact readout, because a 10px slip is 15 minutes. */
    var pct = function (m) { return ((m - w.lo) / (w.hi - w.lo)) * 100; };
    src.el.style.top = pct(Math.max(st, w.lo)) + '%';
    src.el.style.height = (pct(Math.min(en, w.hi)) - pct(Math.max(st, w.lo))) + '%';
    if (rbadge) rbadge.textContent = Store.hhmm(st) + ' – ' + Store.hhmm(en);
  }

  function applyResize() {
    if (!src || !pending) return;
    var rec = Store.findEvent(src.id);
    if (!rec) return;
    if (pending.start === rec.start && pending.end === rec.end) { pending = null; return; }
    var label = Store.hhmm(pending.start) + ' – ' + Store.hhmm(pending.end);
    Store.updateEvent(src.id, { start: pending.start, end: pending.end });
    pending = null;
    if (window.App) {
      App.render();
      App.toast((window.t ? window.t('undo.resizeEvent') : 'resized: ') +
        (rec.title || '') + ' → ' + label);
    }
  }

  /* ---- drop alignment line ------------------------------------------ */

  function clearDropLine() {
    if (dropLine && dropLine.parentNode) dropLine.parentNode.removeChild(dropLine);
    dropLine = null;
  }

  /* While dragging, draw a line at the exact snapped start time. Without it
     the ghost only says "14:00" in text and you cannot tell which row it
     will actually land on. */
  function showDropLine(info) {
    clearDropLine();
    if (!info || info.mins === null || !info.el.classList.contains('week-col')) return;
    var w = windowMins();
    var line = document.createElement('div');
    line.className = 'week-dropline';
    line.style.top = (((info.mins - w.lo) / (w.hi - w.lo)) * 100) + '%';
    var lab = document.createElement('span');
    lab.className = 'dropline-time';
    lab.textContent = Store.hhmm(info.mins);
    line.appendChild(lab);
    info.el.appendChild(line);
    dropLine = line;
  }

  function begin(x, y) {
    if (!src) return;
    dragging = true; armed = false;
    src.el.classList.add('is-drag');
    if (mode === 'resize') {
      src.el.classList.add('is-resize');
      showRBadge();
      moveRBadge(x, y);
      resizeAt(y);
      return;
    }
    ghost = document.createElement('div');
    ghost.className = 'card wk-ghost';
    ghost.style.width = Math.max(90, src.el.offsetWidth) + 'px';
    ghost.textContent = src.el.textContent;
    ghostTag = document.createElement('span');
    ghostTag.className = 'ghost-tag';
    ghost.appendChild(ghostTag);
    document.body.appendChild(ghost);
    moveGhost(x, y);
    var info = targetInfo(x, y);
    highlight(info);
    paintTag(info);
  }

  function moveGhost(x, y) {
    if (!ghost) return;
    ghost.style.left = x + 'px';
    ghost.style.top = y + 'px';
  }

  /* Where would this drop land? Week columns carry a time as well as a date;
     month cells only carry a day. */
  function targetInfo(x, y) {
    var el = document.elementFromPoint(x, y);
    if (!el || !el.closest) return null;
    var t = el.closest('[data-date]');
    if (!t || !t.dataset.date) return null;

    var mins = null;
    if (t.classList.contains('week-col')) {
      var r = t.getBoundingClientRect();
      if (r.height > 0) {
        /* Relative to the visible window, not to midnight: with a 09:00-18:00
           grid, the column top IS 09:00. */
        var w = windowMins();
        mins = snap(w.lo + ((y - r.top) / r.height) * (w.hi - w.lo));
        mins = Math.max(w.lo, Math.min(w.hi - 15, mins));
      }
    }
    return { el: t, date: t.dataset.date, mins: mins };
  }

  function highlight(info) {
    Array.prototype.forEach.call(document.querySelectorAll('.drop-on'), function (n) {
      n.classList.remove('drop-on');
    });
    if (info) info.el.classList.add('drop-on');
  }

  function paintTag(info) {
    if (!ghostTag) return;
    if (!info) { ghostTag.textContent = ''; return; }
    var d = Store.parseISO(info.date);
    var dow = window.lang && window.lang() === 'zh'
      ? ['日', '一', '二', '三', '四', '五', '六'][d.getDay()]
      : ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][d.getDay()];
    ghostTag.textContent = dow + ' ' + info.date.slice(5) +
      (info.mins !== null ? ' ' + Store.hhmm(info.mins) : '');
  }

  /* Dragging to a time that is off-screen: scroll the view, not the page. */
  function autoScroll(y) {
    var view = document.getElementById('view');
    if (!view) return;
    var r = view.getBoundingClientRect();
    var dy = 0;
    if (y < r.top + EDGE_PX) dy = -Math.ceil((r.top + EDGE_PX - y) / 5);
    else if (y > r.bottom - EDGE_PX) dy = Math.ceil((y - (r.bottom - EDGE_PX)) / 5);
    if (!dy) return;
    var before = view.scrollTop;
    view.scrollTop += dy;
    /* Only week columns scroll; if nothing moved there is nothing to chase. */
    if (view.scrollTop === before) window.scrollBy(0, dy);
  }

  function drop(info) {
    if (!src || !info) return;
    var rec = Store.findEvent(src.id);
    if (!rec) return;

    var dur = (rec.end != null ? rec.end : (rec.start || 0) + 60) - (rec.start || 0);
    if (!dur || dur <= 0) dur = 60;

    var patch = { date: info.date };
    if (info.mins !== null) {
      var start = Math.max(0, Math.min(1440 - dur, info.mins));
      patch.start = start;
      patch.end = start + dur;
    }

    if (patch.date === rec.date &&
      (patch.start === undefined || patch.start === rec.start)) return;

    Store.updateEvent(src.id, patch);
    if (window.App) {
      App.render();
      var label = info.date + (info.mins !== null ? ' ' + Store.hhmm(patch.start) : '');
      App.toast((window.t ? window.t('undo.dragEvent') : 'moved: ') +
        (rec.title || '') + ' → ' + label);
    }
  }

  function onClickCapture(ev) {
    if (!suppressClick) return;
    /* One click only: a fixed dead zone would also swallow the next real tap
       (dropping a card, then hitting the nav, felt like a frozen UI). */
    suppressClick = false;
    /* And only the gesture's own click is eaten -- the one that lands on a
       card. Anything else right after a drop is a genuine user action. */
    var t = ev.target.closest ? ev.target.closest('[data-ev]') : null;
    if (!t) return;
    ev.stopPropagation();
    ev.preventDefault();
  }

  /* ---- transport: mouse / pen ---------------------------------------- */
  function onPointerDown(ev) {
    /* A finger is handled by the Touch Events below. Taking it here as well
       would double-arm the gesture, and Safari's pointercancel would then
       tear down a drag that Touch Events had already started. */
    if (ev.pointerType === 'touch') return;
    if (ev.button != null && ev.button !== 0) return;
    press(ev.clientX, ev.clientY, ev.target, false);
    if (!src) return;
    pointerId = ev.pointerId;
    /* Capture keeps the stream even when the cursor leaves the card. */
    if (src.el.setPointerCapture) {
      try { src.el.setPointerCapture(ev.pointerId); } catch (e) { }
    }
  }
  function onPointerMove(ev) {
    if (ev.pointerType === 'touch') return;
    if (pointerId != null && ev.pointerId !== pointerId) return;
    travel(ev.clientX, ev.clientY);
  }
  function onPointerUp(ev) {
    if (ev.pointerType === 'touch') return;
    if (pointerId != null && ev.pointerId !== pointerId) return;
    release(ev.clientX, ev.clientY);
    pointerId = null;
  }

  /* ---- transport: finger --------------------------------------------- */
  function firstTouch(ev) {
    if (ev.touches && ev.touches.length) return ev.touches[0];
    if (ev.changedTouches && ev.changedTouches.length) return ev.changedTouches[0];
    return null;
  }

  function onTouchStart(ev) {
    /* Two fingers belong to pinch-zoom, never to a drag. */
    if (ev.touches.length > 1) { cancel(); return; }
    var t = ev.touches[0];
    if (!t) return;
    press(t.clientX, t.clientY, ev.target, true);
  }

  function onTouchMove(ev) {
    var t = firstTouch(ev);
    if (!t) return;
    if (!armed && !dragging) return;      /* not our gesture: let it scroll */
    /* We own this gesture. preventDefault has to happen on the FIRST move --
       once iOS has begun scrolling it stops honouring it, and the drag is
       silently cancelled under the finger. The card already declares
       touch-action:none, so nothing here fights a legitimate page scroll. */
    if (ev.cancelable) ev.preventDefault();
    travel(t.clientX, t.clientY);
  }

  function onTouchEnd(ev) {
    var t = firstTouch(ev);
    release(t ? t.clientX : lastX, t ? t.clientY : lastY);
  }

  /* Android Chrome pops the context menu on a long press -- exactly the
     gesture that arms a touch drag. Swallow it while one is in flight. */
  function onContextMenu(ev) {
    if (!armed && !dragging) return;
    if (ev.target && ev.target.closest && ev.target.closest('[data-ev]')) ev.preventDefault();
  }

  document.addEventListener('pointerdown', onPointerDown);
  document.addEventListener('pointermove', onPointerMove);
  document.addEventListener('pointerup', onPointerUp);
  document.addEventListener('pointercancel', function (ev) {
    /* Safari fires this for touches it reclassifies as a scroll. Ignore it
       for fingers: Touch Events are the source of truth there. */
    if (ev.pointerType === 'touch') return;
    cancel();
  });

  document.addEventListener('touchstart', onTouchStart, { passive: true });
  document.addEventListener('touchmove', onTouchMove, { passive: false });
  document.addEventListener('touchend', onTouchEnd);
  document.addEventListener('touchcancel', cancel);
  document.addEventListener('contextmenu', onContextMenu);

  /* Capture phase: the guard has to run before any view-level handler. */
  document.addEventListener('click', onClickCapture, true);
})();
