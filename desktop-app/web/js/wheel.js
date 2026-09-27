/* Scroll-wheel duration picker.
 *
 * A number input is a poor way to pick "how long": it needs a keyboard, it
 * has no sense of scale, and on a phone it covers half the screen. So the
 * focus view uses two snapping wheels (hours / minutes) that can be flicked,
 * wheeled, or clicked -- the same gesture as the iOS timer.
 *
 * No dependencies and no build step: the wheels are plain scroll containers
 * with CSS scroll-snap doing the settling. The JS only reads back which row
 * ended up in the middle band.
 *
 *   Wheel.pickDuration({
 *     title:   'Pick a length',
 *     minutes: 25, min: 1, max: 720,
 *     presets: [15, 25, 45],
 *     tabs:    [{ key:'focus', label:'Focus', minutes:25, min:1,  max:720 },
 *               { key:'break', label:'Break', minutes:5,  min:0,  max:120 }],
 *     onPick:  function (key, minutes) { ... }
 *   });
 *
 * onPick receives (key, minutes); key is null when there are no tabs.
 */
(function () {
  'use strict';

  /* Row height in px. It MUST match --wh-item in app.css: the index maths
     (scrollTop / ITEM) is only correct while the two agree. */
  var ITEM = 40;

  var mask = null, box = null;
  var cfg = null;          /* options of the currently open picker */
  var cur = null;          /* { key, minutes } of the selected tab */
  var onPick = null;

  function txt(k, fallback) {
    if (typeof window.t === 'function') {
      var v = window.t(k);
      if (v && v !== k) return v;
    }
    return fallback || k;
  }

  function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v); }

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  /* ---- shell ----------------------------------------------------------- */
  function ensure() {
    if (box) return;
    mask = document.createElement('div');
    mask.className = 'wheel-mask';
    mask.hidden = true;
    box = document.createElement('section');
    box.className = 'wheel-box';
    box.hidden = true;

    mask.addEventListener('click', close);
    box.addEventListener('click', function (e) {
      var b = e.target.closest ? e.target.closest('[data-wact]') : null;
      if (!b) return;
      var act = b.dataset.wact;
      if (act === 'close' || act === 'cancel') { close(); return; }
      if (act === 'ok') { commit(); return; }
      if (act === 'tab') { selectTab(b.dataset.key); return; }
      if (act === 'preset') { setMinutes(parseInt(b.dataset.min, 10)); return; }
      /* Rows are clicked to scroll them to the middle, like a real wheel. */
      var row = e.target.closest ? e.target.closest('.wh-item') : null;
      if (row && row.parentNode && row.parentNode.parentNode) {
        scrollToValue(row.parentNode.parentNode, parseInt(row.dataset.v, 10));
      }
    });

    document.body.appendChild(mask);
    document.body.appendChild(box);
  }

  /* ---- column building ------------------------------------------------- */
  function colValues(maxMinutes, step) {
    var hours = Math.min(12, Math.floor(maxMinutes / 60));
    var h = [];
    for (var i = 0; i <= hours; i++) h.push(i);
    var m = [];
    for (var j = 0; j < 60; j += (step || 1)) m.push(j);
    return { hours: h, mins: m };
  }

  function colHtml(vals, sel) {
    var out = '<div class="wh-items">';
    vals.forEach(function (v) {
      out += '<div class="wh-item' + (v === sel ? ' on' : '') + '" data-v="' + v + '">' + v + '</div>';
    });
    return out + '</div>';
  }

  /* Which row is in the middle band right now. */
  function readCol(colEl) {
    var idx = Math.round((colEl.scrollTop || 0) / ITEM);
    var items = colEl.querySelectorAll('.wh-item');
    if (!items.length) return 0;
    idx = clamp(idx, 0, items.length - 1);
    return parseInt(items[idx].dataset.v, 10);
  }

  function markCol(colEl) {
    var items = colEl.querySelectorAll('.wh-item');
    var idx = clamp(Math.round((colEl.scrollTop || 0) / ITEM), 0, items.length - 1);
    for (var i = 0; i < items.length; i++) {
      items[i].classList.toggle('on', i === idx);
    }
  }

  function syncFromWheels() {
    var hc = box.querySelector('[data-col="h"]');
    var mc = box.querySelector('[data-col="m"]');
    if (!hc || !mc) return;
    setMinutes(readCol(hc) * 60 + readCol(mc), true);
  }

  /* Our own scrollTo fires scroll events too, and reading those back would
     overwrite the value a preset just set. So only a gesture on the wheel
     itself (wheel / pointer / touch) marks the movement as the user's. */
  var userMoved = false;

  function bindCol(colEl) {
    var timer = null;
    function touched() { userMoved = true; }
    colEl.addEventListener('wheel', touched, { passive: true });
    colEl.addEventListener('pointerdown', touched);
    colEl.addEventListener('touchstart', touched, { passive: true });
    colEl.addEventListener('scroll', function () {
      markCol(colEl);
      if (timer) clearTimeout(timer);
      /* Debounced: scroll-snap is still settling, and the row that ends up
         under the band is the one that counts (scrollend is not universal). */
      timer = setTimeout(function () {
        if (!userMoved) return;
        userMoved = false;
        syncFromWheels();
      }, 110);
    });
  }

  /* Move a wheel so that v sits under the band. `instant` is used when
     opening: no animation, and the value is already known. */
  function scrollToValue(colEl, v, instant) {
    var top = indexOfValue(colEl, v) * ITEM;
    if (instant) colEl.scrollTop = top;
    else colEl.scrollTo({ top: top, behavior: 'smooth' });
  }

  /* ---- state ----------------------------------------------------------- */
  function tab() {
    if (!cfg.tabs) return { key: null, minutes: cfg.minutes, min: cfg.min, max: cfg.max, presets: cfg.presets };
    for (var i = 0; i < cfg.tabs.length; i++) {
      if (cfg.tabs[i].key === cur.key) return cfg.tabs[i];
    }
    return cfg.tabs[0];
  }

  function setMinutes(v, quiet) {
    var t = tab();
    v = clamp(parseInt(v, 10) || 0, t.min, t.max);
    cur.minutes = v;
    if (!quiet) {
      var hc = box.querySelector('[data-col="h"]');
      var mc = box.querySelector('[data-col="m"]');
      var vals = colValues(t.max, t.step);
      var h = Math.min(vals.hours[vals.hours.length - 1], Math.floor(v / 60));
      var m = v - h * 60;
      /* Snap the minute wheel to the nearest offered value (step may be 5). */
      var nearest = vals.mins[0];
      vals.mins.forEach(function (x) {
        if (Math.abs(x - m) < Math.abs(nearest - m)) nearest = x;
      });
      if (hc) scrollToValue(hc, h);
      if (mc) scrollToValue(mc, nearest);
    }
    var lab = box.querySelector('.wheel-val');
    if (lab) lab.textContent = label(v);
    var ps = box.querySelectorAll('.wheel-presets [data-min]');
    for (var i = 0; i < ps.length; i++) {
      ps[i].classList.toggle('on', parseInt(ps[i].dataset.min, 10) === v);
    }
  }

  function label(mins) {
    mins = parseInt(mins, 10) || 0;
    var h = Math.floor(mins / 60), m = mins % 60;
    if (!h) return m + ' ' + txt('pomo.mins', 'min');
    if (!m) return h + ' ' + txt('pomo.hours', 'h');
    return h + ' ' + txt('pomo.hours', 'h') + ' ' + m + ' ' + txt('pomo.mins', 'min');
  }

  function selectTab(k) {
    cur.key = k;
    var t = tab();
    cur.minutes = clamp(parseInt(t.minutes, 10) || t.min, t.min, t.max);
    render();
  }

  /* ---- render ---------------------------------------------------------- */
  function render() {
    var t = tab();
    var vals = colValues(t.max, t.step || 1);
    var h = Math.min(vals.hours[vals.hours.length - 1], Math.floor(cur.minutes / 60));
    var m = cur.minutes - h * 60;

    var out = '<header class="wheel-head">' +
      '<h2>' + esc(cfg.title || txt('pomo.pick', 'Pick a length')) + '</h2>' +
      '<button class="sheet-x" data-wact="close" aria-label="Close">&times;</button>' +
      '</header>';

    if (cfg.tabs) {
      out += '<div class="wheel-tabs">';
      cfg.tabs.forEach(function (x) {
        out += '<button class="wtab' + (x.key === cur.key ? ' on' : '') + '" data-wact="tab" data-key="' +
          esc(x.key) + '">' + esc(x.label) + '</button>';
      });
      out += '</div>';
    }

    out += '<div class="wheel-val">' + label(cur.minutes) + '</div>' +
      '<div class="wheel-cols">' +
      '<span class="wh-band"></span>' +
      '<div class="wh-col" data-col="h">' + colHtml(vals.hours, h) + '</div>' +
      '<span class="wh-unit">' + esc(txt('pomo.hours', 'h')) + '</span>' +
      '<div class="wh-col" data-col="m">' + colHtml(vals.mins, m) + '</div>' +
      '<span class="wh-unit">' + esc(txt('pomo.mins', 'm')) + '</span>' +
      '</div>';

    var presets = t.presets || cfg.presets || [];
    if (presets.length) {
      out += '<div class="wheel-presets">';
      presets.forEach(function (p) {
        if (p < t.min || p > t.max) return;
        out += '<button class="wpreset' + (p === cur.minutes ? ' on' : '') +
          '" data-wact="preset" data-min="' + p + '">' + label(p) + '</button>';
      });
      out += '</div>';
    }

    out += '<footer class="wheel-foot">' +
      '<button class="btn btn-ghost" data-wact="cancel">' + esc(txt('btn.cancel', 'Cancel')) + '</button>' +
      '<span class="spacer"></span>' +
      '<button class="btn btn-primary" data-wact="ok">' + esc(txt('btn.ok', 'OK')) + '</button>' +
      '</footer>';

    box.innerHTML = out;

    /* Park both wheels on the value instantly (no animation on open), and
       only now that the box is visible -- a hidden element has no layout, so
       writing scrollTop to it is silently ignored. */
    var hc = box.querySelector('[data-col="h"]');
    var mc = box.querySelector('[data-col="m"]');
    if (hc) { bindCol(hc); scrollToValue(hc, h, true); }
    if (mc) { bindCol(mc); scrollToValue(mc, m, true); }
  }

  function indexOfValue(colEl, v) {
    var items = colEl.querySelectorAll('.wh-item');
    for (var i = 0; i < items.length; i++) {
      if (parseInt(items[i].dataset.v, 10) === v) return i;
    }
    return 0;
  }

  /* ---- open / close ---------------------------------------------------- */
  function pickDuration(opts) {
    ensure();
    cfg = opts || {};
    onPick = cfg.onPick || null;
    if (cfg.tabs) {
      cur = { key: cfg.tabs[0].key, minutes: parseInt(cfg.tabs[0].minutes, 10) || cfg.tabs[0].min };
    } else {
      cur = { key: null, minutes: parseInt(cfg.minutes, 10) || cfg.min || 0 };
    }
    mask.hidden = false;
    box.hidden = false;
    userMoved = false;
    render();
  }

  function commit() {
    /* A spin the debounce has not caught yet must still count. */
    if (userMoved) { userMoved = false; syncFromWheels(); }
    var k = cur.key, v = cur.minutes, fn = onPick;
    /* The callback has to be captured first: close() clears it, and the
       callback itself re-opens things (toast + re-render) that must not run
       against a half-closed picker. */
    close();
    if (fn) fn(k, v);
  }

  function close() {
    if (mask) mask.hidden = true;
    if (box) box.hidden = true;
    onPick = null;
  }

  window.Wheel = {
    pickDuration: pickDuration,
    close: close,
    label: label,
    /* Test hook: the self test needs to move a wheel without a real flick. */
    _itemHeight: ITEM
  };
})();
