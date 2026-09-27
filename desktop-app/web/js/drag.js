/* Drag-to-reschedule in the week (and month) view.
 *
 * Pointer events rather than HTML5 drag-and-drop: HTML5 DnD does not fire for
 * touch at all, and this app is phone-first.
 *
 * Mouse: drag starts after a few pixels of movement.
 * Touch: drag starts after a short hold, so a plain swipe still scrolls the
 * page. While dragging, touchmove is preventDefault-ed (non-passive) or the
 * browser would scroll the view out from under the finger.
 */
(function () {
  'use strict';

  var HOLD_MS = 260;      /* touch: how long before a press becomes a drag */
  var MOVE_PX = 6;        /* mouse: how far before a press becomes a drag */

  var src = null;         /* { id, el, kind } */
  var ghost = null;
  var holdTimer = null;
  var startX = 0, startY = 0;
  var dragging = false;
  var armed = false;      /* press seen, waiting to decide drag vs scroll */
  var pointerId = null;

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
      highlight(ev.clientX, ev.clientY);
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
    cancel();
    if (wasDragging) drop(x, y);
  }

  function cancel() {
    clearTimeout(holdTimer);
    armed = false;
    if (dragging && src) src.el.classList.remove('is-drag');
    dragging = false;
    if (ghost && ghost.parentNode) ghost.parentNode.removeChild(ghost);
    ghost = null;
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
    document.body.appendChild(ghost);
    moveGhost(x, y);
    highlight(x, y);
  }

  function moveGhost(x, y) {
    if (!ghost) return;
    ghost.style.left = x + 'px';
    ghost.style.top = y + 'px';
  }

  function targetAt(x, y) {
    var el = document.elementFromPoint(x, y);
    if (!el || !el.closest) return null;
    return el.closest('[data-date]');
  }

  function highlight(x, y) {
    Array.prototype.forEach.call(document.querySelectorAll('.drop-on'), function (n) {
      n.classList.remove('drop-on');
    });
    var t = targetAt(x, y);
    if (t) t.classList.add('drop-on');
  }

  function drop(x, y) {
    if (!src) return;
    var rec = Store.findEvent(src.id);
    var target = targetAt(x, y);
    if (!rec || !target) return;

    var date = target.dataset.date;
    if (!date) return;

    var dur = (rec.end || rec.start + 60) - (rec.start || 0);
    if (dur <= 0) dur = 60;

    var patch = { date: date };
    /* Week columns give a time as well; month cells only move the day. */
    if (target.classList.contains('week-col')) {
      var r = target.getBoundingClientRect();
      var mins = Math.round(((y - r.top) / slotH()) * 60 / 15) * 15;
      mins = Math.max(0, Math.min(1440 - dur, mins));
      patch.start = mins;
      patch.end = mins + dur;
    }

    if (patch.date === rec.date && (patch.start === undefined || patch.start === rec.start)) return;

    Store.updateEvent(src.id, patch);
    if (window.App) {
      App.render();
      App.toast((window.t ? window.t('undo.dragEvent') : 'moved: ') + (rec.title || ''));
    }
  }

  /* A dragging finger must not scroll the page. */
  function onTouchMove(ev) {
    if (dragging && ev.cancelable) ev.preventDefault();
  }

  document.addEventListener('pointerdown', onDown);
  document.addEventListener('pointermove', onMove);
  document.addEventListener('pointerup', onUp);
  document.addEventListener('pointercancel', cancel);
  document.addEventListener('touchmove', onTouchMove, { passive: false });
})();
