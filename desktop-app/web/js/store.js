/* Data layer.
 *
 * The record shape is deliberately IDENTICAL to the WPF app's schedule.json
 * (events[] / tasks[]), so an exported file from the desktop app loads here
 * unchanged, and vice versa. Changing a field name means changing both ends.
 *
 * Storage strategy is offline-first: localStorage is the truth the UI reads
 * immediately, and the cloud (js/cloud.js) mirrors it when a user is signed
 * in. That ordering is what makes the app usable the moment it opens, with or
 * without a network.
 */
(function () {
  'use strict';

  var KEY_DATA = 'myschedule.data.v1';
  var KEY_SET = 'myschedule.settings.v1';

  /* ---- settings -------------------------------------------------------- */
  /* Tag colours are CSS custom properties from tokens.css, so a custom tag is
     just a name plus a variable -- no hex values live in the data. */
  var DEFAULT_TAGS = [
    { key: 'work', color: '--accent' },
    { key: 'focus', color: '--accent-warm' },
    { key: 'life', color: '--accent-cool' }
  ];

  var DEFAULT_SETTINGS = {
    theme: 'light',
    lang: 'zh',
    view: 'month',
    pomodoroMin: 25,
    breakMin: 5,
    focusTodayMin: 0,
    focusDate: null,
    /* focusLog keeps one entry per day (yyyy-MM-dd -> minutes). The hero only
       needs today, but the stats chart needs a week, and a week cannot be
       reconstructed from a single "today" counter once the day rolls over. */
    focusLog: {},
    /* pomo.dir: 'down' counts down to zero, 'up' counts up with no end.
       Only the focus block honours 'up' -- a break that never ends is not a
       break -- so a count-up session still gets a normal timed break.
       upBase/upStart are the count-up bookkeeping: seconds banked from
       earlier runs, and the wall clock the current run started at. */
    pomo: {
      mode: 'focus', dir: 'down', running: false,
      endsAt: null, left: null, upBase: 0, upStart: null,
      taskId: null, queue: []
    },
    /* Week view can show a sub-range of the 24h day (desktop app let you pick
       the visible window). 0 = 00:00, 24 = 24:00. */
    weekStart: 0,
    weekEnd: 24,
    /* Global UI font scale; 1 = default. Applied as --fs on :root. */
    fontScale: 1,
    tags: DEFAULT_TAGS,
    /* User-entered festivals, keyed 'yyyy-MM-DD'. They override anything the
       built-in calendar knows: it is the user's calendar, not ours. */
    holidays: {},
    avatar: null
  };

  var settings = load(KEY_SET, DEFAULT_SETTINGS);

  /* Old installs (and a hand-edited file) may miss newer keys; fill them in
     without throwing away what is already there. */
  Object.keys(DEFAULT_SETTINGS).forEach(function (k) {
    if (settings[k] === undefined) settings[k] = DEFAULT_SETTINGS[k];
  });
  if (!Array.isArray(settings.tags) || !settings.tags.length) settings.tags = DEFAULT_TAGS;
  if (!settings.focusLog || typeof settings.focusLog !== 'object') settings.focusLog = {};
  if (!settings.holidays || typeof settings.holidays !== 'object') settings.holidays = {};
  if (!settings.pomo || typeof settings.pomo !== 'object') settings.pomo = DEFAULT_SETTINGS.pomo;
  if (!Array.isArray(settings.pomo.queue)) settings.pomo.queue = [];

  /* ---- records --------------------------------------------------------- */
  var data = load(KEY_DATA, null) || { events: [], tasks: [] };
  if (!Array.isArray(data.events)) data.events = [];
  if (!Array.isArray(data.tasks)) data.tasks = [];

  function load(key, fallback) {
    try {
      var raw = localStorage.getItem(key);
      if (!raw) return fallback;
      return JSON.parse(raw);
    } catch (e) {
      return fallback;
    }
  }

  function persist() {
    try {
      localStorage.setItem(KEY_DATA, JSON.stringify(data));
    } catch (e) {
      /* Quota or private-mode failure: the UI must still work this session. */
    }
  }

  function persistSettings() {
    try {
      localStorage.setItem(KEY_SET, JSON.stringify(settings));
    } catch (e) { }
  }

  function id() {
    return Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
  }

  /* ---- change notification --------------------------------------------- */
  var listeners = [];
  function onChange(fn) { listeners.push(fn); }
  function emit(reason) {
    for (var i = 0; i < listeners.length; i++) {
      try { listeners[i](reason); } catch (e) { }
    }
  }

  /* ---- events ----------------------------------------------------------- */
  function newEvent(o) {
    o = o || {};
    var e = {
      id: id(),
      date: o.date || todayStr(),
      start: num(o.start, 9 * 60),
      end: num(o.end, 10 * 60),
      title: o.title || '',
      tag: o.tag || 'work',
      note: o.note || '',
      done: !!o.done,
      repeat: o.repeat || 'none',
      repeatEvery: num(o.repeatEvery, 1),
      repeatUntil: o.repeatUntil || '',
      repeatMonthMode: o.repeatMonthMode || 'day',
      reminderMin: num(o.reminderMin, 0),
      reminderKey: o.reminderKey || ''
    };
    data.events.push(e);
    persist(); emit('event.add');
    return e;
  }

  function updateEvent(evId, patch) {
    var at = (evId || '').indexOf('@');
    var realId = at > 0 ? evId.split('@')[0] : evId;
    var e = findEvent(realId);
    if (!e) return null;
    /* An instance id (base@date) on a repeating series means "this occurrence
       only": the patch becomes a per-date exception instead of rewriting the
       whole series. Dragging one week's class must not move every week. */
    if (at > 0 && e.repeat && e.repeat !== 'none') {
      var instDate = evId.slice(at + 1);
      if (!e.exceptions) e.exceptions = {};
      var ex = e.exceptions[instDate] || { date: instDate };
      for (var k in patch) {
        if (Object.prototype.hasOwnProperty.call(patch, k)) ex[k] = patch[k];
      }
      e.exceptions[instDate] = ex;
      persist(); emit('event.update');
      return e;
    }
    for (var k2 in patch) {
      if (Object.prototype.hasOwnProperty.call(patch, k2)) e[k2] = patch[k2];
    }
    persist(); emit('event.update');
    return e;
  }

  function removeEvent(evId) {
    var realId = (evId && evId.indexOf('@') > 0) ? evId.split('@')[0] : evId;
    data.events = data.events.filter(function (e) { return e.id !== realId; });
    persist(); emit('event.remove');
  }

  function findEvent(evId) {
    for (var i = 0; i < data.events.length; i++) {
      if (data.events[i].id === evId) return data.events[i];
    }
    return null;
  }

  /* ---- tasks ------------------------------------------------------------ */
  function newTask(o) {
    o = o || {};
    var t = {
      id: id(),
      text: o.text || '',
      done: !!o.done,
      due: o.due || null,
      dueTime: o.dueTime || '09:00',
      tag: o.tag || 'task',
      priority: o.priority || 'medium',
      project: o.project || 'Inbox',
      subtasks: o.subtasks || [],
      estimatedMin: num(o.estimatedMin, 30),
      actualMin: num(o.actualMin, 0),
      reminderMin: num(o.reminderMin, 10)
    };
    data.tasks.push(t);
    persist(); emit('task.add');
    return t;
  }

  function updateTask(tId, patch) {
    var t = findTask(tId);
    if (!t) return null;
    for (var k in patch) {
      if (Object.prototype.hasOwnProperty.call(patch, k)) t[k] = patch[k];
    }
    persist(); emit('task.update');
    return t;
  }

  function removeTask(tId) {
    data.tasks = data.tasks.filter(function (t) { return t.id !== tId; });
    persist(); emit('task.remove');
  }

  function findTask(tId) {
    for (var i = 0; i < data.tasks.length; i++) {
      if (data.tasks[i].id === tId) return data.tasks[i];
    }
    return null;
  }

  /* ---- wholesale replace (import / cloud pull) -------------------------- */
  function replaceAll(next) {
    if (!next) return;
    data.events = Array.isArray(next.events) ? next.events : [];
    data.tasks = Array.isArray(next.tasks) ? next.tasks : [];
    /* Settings ride along too, so tags/colours/week-range/font travel with the
       data when a user signs in on a second device. Only keys we already know
       are copied in; a stray key from a future build is ignored on purpose. */
    if (next.settings && typeof next.settings === 'object') {
      Object.keys(DEFAULT_SETTINGS).forEach(function (k) {
        if (next.settings[k] !== undefined) settings[k] = next.settings[k];
      });
    }
    persist(); persistSettings(); emit('replace');
  }

  /* ---- helpers ---------------------------------------------------------- */
  function num(v, d) {
    var n = parseInt(v, 10);
    return isNaN(n) ? d : n;
  }

  function todayStr() {
    var d = new Date();
    return iso(d);
  }

  function iso(d) {
    var m = d.getMonth() + 1, day = d.getDate();
    return d.getFullYear() + '-' + (m < 10 ? '0' : '') + m + '-' + (day < 10 ? '0' : '') + day;
  }

  function parseISO(s) {
    if (!s) return null;
    var p = String(s).split('-');
    if (p.length !== 3) return null;
    return new Date(parseInt(p[0], 10), parseInt(p[1], 10) - 1, parseInt(p[2], 10));
  }

  function hhmm(mins) {
    var m = parseInt(mins, 10) || 0;
    var h = Math.floor(m / 60) % 24, mm = m % 60;
    return (h < 10 ? '0' : '') + h + ':' + (mm < 10 ? '0' : '') + mm;
  }

  function fromHHMM(s) {
    if (!s) return 0;
    var p = String(s).split(':');
    return (parseInt(p[0], 10) || 0) * 60 + (parseInt(p[1], 10) || 0);
  }

  /* Monday = 0, matching the desktop app's Start-Of-Week. */
  function startOfWeek(d) {
    var dow = (d.getDay() + 6) % 7;
    var r = new Date(d.getFullYear(), d.getMonth(), d.getDate());
    r.setDate(r.getDate() - dow);
    return r;
  }

  function eventsOn(dateStr) {
    return data.events.filter(function (e) { return e.date === dateStr; })
      .sort(function (a, b) { return (a.start || 0) - (b.start || 0); });
  }

  /* ---- repeating events: expand a base event into visible instances ------ */
  /* A base event with repeat != 'none' yields one instance per matching day.
     Instances are virtual clones (id = baseId + '@' + date) so the UI can open
     the editor for any occurrence; editing / deleting acts on the base event,
     i.e. the whole series. The base day itself is reached through the same rule
     (delta 0), so we never return both the base record and its clone. */
  function diffDays(a, b) {
    return Math.round((a.getTime() - b.getTime()) / 86400000);
  }

  function daysInMonth(d) {
    return new Date(d.getFullYear(), d.getMonth() + 1, 0).getDate();
  }

  function isLastDay(d) {
    return d.getDate() === daysInMonth(d);
  }

  /* Does `target` fall on the repeating series defined by base event `e`? */
  function repeatsOn(e, base, target) {
    var every = Math.max(1, parseInt(e.repeatEvery, 10) || 1);
    if (diffDays(target, base) < 0) return false;
    if (e.repeatUntil) {
      var until = parseISO(e.repeatUntil);
      if (until && target > until) return false;
    }
    var mode = e.repeatMonthMode || 'day';
    if (e.repeat === 'daily') {
      return diffDays(target, base) % every === 0;
    }
    if (e.repeat === 'weekly') {
      if (target.getDay() !== base.getDay()) return false;
      return Math.floor(diffDays(target, base) / 7) % every === 0;
    }
    if (e.repeat === 'monthly') {
      var months = (target.getFullYear() - base.getFullYear()) * 12 + (target.getMonth() - base.getMonth());
      if (months < 0 || months % every !== 0) return false;
      if (mode === 'last') return isLastDay(target);
      /* day mode: same date, but a base day > days-in-month (e.g. 31st) lands
         on the last day so the series never vanishes in short months. */
      if (base.getDate() > daysInMonth(target)) return isLastDay(target);
      return target.getDate() === base.getDate();
    }
    if (e.repeat === 'yearly') {
      var years = target.getFullYear() - base.getFullYear();
      if (years < 0 || years % every !== 0) return false;
      if (target.getMonth() !== base.getMonth()) return false;
      if (mode === 'last') return isLastDay(target);
      if (base.getDate() > daysInMonth(target)) return isLastDay(target);
      return target.getDate() === base.getDate();
    }
    return false;
  }

  function cloneInstance(e, dateStr) {
    var inst = {};
    for (var k in e) {
      if (Object.prototype.hasOwnProperty.call(e, k)) inst[k] = e[k];
    }
    inst.date = dateStr;
    inst.id = e.id + '@' + dateStr;
    inst._repeat = true;
    return inst;
  }

  /* One occurrence that was dragged or edited on its own: the series clone
     with the exception's fields painted over it. Exceptions are keyed by the
     ORIGINAL date, and so is the instance id (base@key) -- that id must stay
     stable even when the occurrence moves to another day, or editing it a
     second time would fork a second exception. */
  function instanceWith(e, ex, dateStr, key) {
    var inst = cloneInstance(e, dateStr);
    for (var k in ex) {
      if (Object.prototype.hasOwnProperty.call(ex, k) && k !== 'cancel') inst[k] = ex[k];
    }
    inst.date = dateStr;
    inst.id = e.id + '@' + (key || dateStr);
    inst._repeat = true;
    inst._exception = true;
    return inst;
  }

  /* What shows on a given day: real single-day events plus every repeating
     instance that lands on that day. Exceptions (dragged occurrences) both
     override their original slot and appear on the day they were moved to. */
  function expandedEventsOn(dateStr) {
    var target = parseISO(dateStr);
    if (!target) return eventsOn(dateStr);
    var out = [];
    for (var i = 0; i < data.events.length; i++) {
      var e = data.events[i];
      if (!e || !e.date) continue;
      if (e.repeat && e.repeat !== 'none') {
        var base = parseISO(e.date);
        var ex = e.exceptions ? e.exceptions[dateStr] : null;
        if (ex) {
          /* This occurrence was moved/edited on its own; the series rule no
             longer speaks for it. An occurrence dragged elsewhere renders on
             its new day (second pass below), not here. */
          if (!ex.cancel && (ex.date || dateStr) === dateStr) {
            out.push(instanceWith(e, ex, dateStr));
          }
        } else if (base && repeatsOn(e, base, target)) {
          out.push(cloneInstance(e, dateStr));
        }
      } else if (e.date === dateStr) {
        out.push(e);
      }
    }
    /* Second pass: occurrences dragged INTO this day. Their exception is
       stored under the original date, so the first pass never saw them. */
    for (var j = 0; j < data.events.length; j++) {
      var ev = data.events[j];
      if (!ev || !ev.exceptions) continue;
      for (var d in ev.exceptions) {
        if (!Object.prototype.hasOwnProperty.call(ev.exceptions, d)) continue;
        var ex2 = ev.exceptions[d];
        if (ex2.cancel || d === dateStr || ex2.date !== dateStr) continue;
        out.push(instanceWith(ev, ex2, dateStr, d));
      }
    }
    out.sort(function (a, b) { return (a.start || 0) - (b.start || 0); });
    return out;
  }

  /* ---- focus bookkeeping ---------------------------------------------- */
  /* One entry point, so the hero's "today" figure and the stats week can never
     drift apart: both read the same log. */
  function addFocus(mins, dateStr) {
    mins = parseInt(mins, 10) || 0;
    if (mins <= 0) return;
    var day = dateStr || todayStr();
    if (settings.focusDate !== day) { settings.focusDate = day; settings.focusTodayMin = 0; }
    settings.focusTodayMin = (parseInt(settings.focusTodayMin, 10) || 0) + mins;
    settings.focusLog[day] = (parseInt(settings.focusLog[day], 10) || 0) + mins;
    persistSettings();
  }

  function focusOn(dateStr) {
    return parseInt(settings.focusLog[dateStr], 10) || 0;
  }

  function stats() {
    var done = data.events.filter(function (e) { return e.done; }).length;
    return { done: done, total: data.events.length };
  }

  window.Store = {
    settings: settings,
    get events() { return data.events; },
    get tasks() { return data.tasks; },
    /* Events + tasks are the user's data; settings (tags, week range, font…)
       are bundled so a cloud pull restores the whole picture, not just the
       records. exportData() serialises the same shape. */
    raw: function () { return { events: data.events, tasks: data.tasks, settings: settings }; },
    onChange: onChange,
    emit: emit,
    persist: persist,
    persistSettings: persistSettings,
    newEvent: newEvent,
    updateEvent: updateEvent,
    removeEvent: removeEvent,
    findEvent: findEvent,
    newTask: newTask,
    updateTask: updateTask,
    removeTask: removeTask,
    findTask: findTask,
    replaceAll: replaceAll,
    todayStr: todayStr,
    iso: iso,
    parseISO: parseISO,
    hhmm: hhmm,
    fromHHMM: fromHHMM,
    startOfWeek: startOfWeek,
    eventsOn: eventsOn,
    expandedEventsOn: expandedEventsOn,
    addFocus: addFocus,
    focusOn: focusOn,
    stats: stats
  };
})();
