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
    pomo: { mode: 'focus', running: false, endsAt: null, left: null, taskId: null, queue: [] },
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
    var e = findEvent(evId);
    if (!e) return null;
    for (var k in patch) {
      if (Object.prototype.hasOwnProperty.call(patch, k)) e[k] = patch[k];
    }
    persist(); emit('event.update');
    return e;
  }

  function removeEvent(evId) {
    data.events = data.events.filter(function (e) { return e.id !== evId; });
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
    persist(); emit('replace');
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
    raw: function () { return data; },
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
    addFocus: addFocus,
    focusOn: focusOn,
    stats: stats
  };
})();
