/* Drag-to-reschedule across days (week view) and across weeks (month view).
 *
 * Pointer events rather than HTML5 drag-and-drop: HTML5 DnD does not fire for
 * touch at all, and this app is phone-first.
 *
 * Mouse: drag starts after a few pixels of movement.
 * Touch: drag starts after a short hold, so a plain swipe still scrolls the
 * page. While dragging, touchmove is preventDefault-ed (non-passive) or the
 * browser would scroll the view out from under the finger.
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
  var EDGE_PX = 52;       /* distance from a view edge that starts scrolling */
  var CLICK_GUARD_MS = 320;

  var src = null;         /* { id, el } */
  var ghost = null;
  var ghostTag = null;
  var holdTimer = null;
  var startX = 0, startY = 0;
  var dragging = false;
  var armed = false;      /* press seen, waiting to decide drag vs scroll */
  var pointerId = null;
  var suppressClick = false;

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

  function onDown(ev) {
    if (ev.button != null && ev.button !== 0) return;
    var el = ev.target.closest ? ev.target.closest('[data-ev]') : null;
    if (!el) return;
    /* Buttons inside the card keep their own behaviour. */
    if (ev.target.closest('[data-act]')) return;

    src = { id: el.dataset.ev, el: el };
    startX = ev.clientX; startY = ev.clientY;
    armed = true; dragging = false;
    pointerId = ev.pointerId;

    if (ev.pointerType === 'touch') {
      clearTimeout(holdTimer);
      holdTimer = setTimeout(function () {
        if (armed) begin(ev.clientX, ev.clientY);
      }, HOLD_MS);
    }
  }

  function onMove(ev) {
    if (!armed && !dragging) return;
    if (pointerId != null && ev.pointerId !== pointerId) return;

    if (dragging) {
      moveGhost(ev.clientX, ev.clientY);
      var info = targetInfo(ev.clientX, ev.clientY);
      highlight(info);
      paintTag(info);
      autoScroll(ev.clientY);
      return;
    }
    /* Not yet dragging: a mouse move past the threshold starts it, a touch
       move before the hold completes means the user is scrolling. */
    var dx = Math.abs(ev.clientX - startX), dy = Math.abs(ev.clientY - startY);
    if (dx > MOVE_PX || dy > MOVE_PX) {
      if (ev.pointerType === 'mouse') begin(ev.clientX, ev.clientY);
      else cancel();
    }
  }

  function onUp(ev) {
    clearTimeout(holdTimer);
    if (!armed && !dragging) return;
    var wasDragging = dragging;
    var x = ev.clientX, y = ev.clientY;
    var info = wasDragging ? targetInfo(x, y) : null;
    cancel();
    if (wasDragging) {
      /* The browser still fires a click after this pointerup. Without the
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
    if (dragging && src) src.el.classList.remove('is-drag');
    dragging = false;
    if (ghost && ghost.parentNode) ghost.parentNode.removeChild(ghost);
    ghost = null; ghostTag = null;
    Array.prototype.forEach.call(document.querySelectorAll('.drop-on'), function (n) {
      n.classList.remove('drop-on');
    });
  }

  function begin(x, y) {
    if (!src) return;
    dragging = true; armed = false;
    src.el.classList.add('is-drag');
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
        mins = Math.round(((y - r.top) / slotH()) * 60 / 15) * 15;
        mins = Math.max(0, Math.min(1440 - 15, mins));
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

  /* A dragging finger must not scroll the page. */
  function onTouchMove(ev) {
    if (dragging && ev.cancelable) ev.preventDefault();
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

  document.addEventListener('pointerdown', onDown);
  document.addEventListener('pointermove', onMove);
  document.addEventListener('pointerup', onUp);
  document.addEventListener('pointercancel', cancel);
  document.addEventListener('touchmove', onTouchMove, { passive: false });
  /* Capture phase: the guard has to run before any view-level handler. */
  document.addEventListener('click', onClickCapture, true);
})();
