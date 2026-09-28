/* Undo / redo for data mutations.
 *
 * The week view is drag-first: a block can be moved or stretched with one
 * finger, which also makes it easy to move one by accident. Rather than
 * asking "are you sure?" before every drop, every mutation is recorded and
 * the last N states can be walked back and forward.
 *
 * Snapshots, not inverse operations: the whole dataset is small (it lives in
 * localStorage anyway) and a snapshot cannot drift out of sync with whatever
 * code path changed the data -- dragging, the editor, a delete or an import
 * all end up in the same history. Only events and tasks are snapshotted;
 * settings (theme, font, week range) are deliberately left alone, so undoing
 * a mis-drag does not also rewind the font size chosen a minute ago.
 *
 * In-memory only: a reload starts with a clean history, which is what people
 * expect from a page they just opened.
 */
(function () {
  'use strict';

  var LIMIT = 40;
  var past = [];        /* { data, reason } -- states before a change */
  var future = [];      /* { data, reason } -- states that were undone */
  var base = null;      /* current committed state */
  var suspended = false;
  var listeners = [];

  function snapshot() {
    var r = (window.Store && Store.raw) ? Store.raw() : {};
    return JSON.stringify({ events: r.events || [], tasks: r.tasks || [] });
  }

  function commit(data) {
    suspended = true;
    try {
      Store.replaceAll(JSON.parse(data));
    } finally { suspended = false; }
    notify();
  }

  function notify() {
    for (var i = 0; i < listeners.length; i++) {
      try { listeners[i](); } catch (e) { }
    }
  }

  /* Called on every Store change. `base` is the state the user was looking at
     before this change, so that is what gets pushed. */
  function record(reason) {
    if (suspended) return;
    var now = snapshot();
    if (base === null) { base = now; return; }   /* first sight: just anchor */
    if (now === base) return;                    /* nothing actually changed */
    if (past.length >= LIMIT) past.shift();
    past.push({ data: base, reason: reason });
    future.length = 0;
    base = now;
    notify();
  }

  function canUndo() { return past.length > 0; }
  function canRedo() { return future.length > 0; }

  function undo() {
    if (!past.length) return null;
    var entry = past.pop();
    future.push({ data: base, reason: entry.reason });
    base = entry.data;
    commit(base);
    return entry.reason;
  }

  function redo() {
    if (!future.length) return null;
    var entry = future.pop();
    past.push({ data: base, reason: entry.reason });
    base = entry.data;
    commit(base);
    return entry.reason;
  }

  /* A cloud pull or an import replaces everything; keeping the old snapshots
     around would let a user "undo" a sync half-way back into last week. */
  function reset() {
    past.length = 0;
    future.length = 0;
    base = snapshot();
    notify();
  }

  function onChange(fn) { listeners.push(fn); }

  /* Only data changes belong here: settings churn (theme, font, range) would
     bury a mis-drag under twenty undo steps. */
  if (window.Store && Store.onChange) {
    /* `suspended` matters here: undo/redo replay through Store.replaceAll,
       which emits 'replace'. Treating that as an external reset would wipe
       the very stack the undo step just came from. */
    Store.onChange(function (reason) {
      if (suspended) return;
      if (reason === 'replace') { reset(); return; }
      if (/^(event|task)\./.test(reason)) record(reason);
    });
    /* Anchor immediately, so the very first edit is undoable too. */
    base = snapshot();
  }

  window.Undo = {
    undo: undo,
    redo: redo,
    canUndo: canUndo,
    canRedo: canRedo,
    reset: reset,
    onChange: onChange,
    depth: function () { return { past: past.length, future: future.length }; }
  };
})();
