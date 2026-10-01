/* AI integration layer.
 *
 * Three features ride on this file:
 *   1. import  -- a screenshot or pasted blob of text becomes draft events
 *   2. plan    -- a goal is broken into weekly tasks and fitted into real gaps
 *   3. edit    -- an instruction in plain language becomes operations on
 *                  existing events
 *
 * Two rules shape everything here:
 *
 * The model never touches the Store directly. It emits JSON, this file
 * validates it, the user is shown a diff and picks what to keep. A model that
 * says "2月30日" or invents an id is a normal Tuesday; nothing it produces is
 * trusted until it has passed through normalize*().
 *
 * Credentials never touch the Store either. Store.raw() ships settings to the
 * cloud, so the API key lives under its own localStorage key -- otherwise the
 * next sync would copy the key to the server and to every other device.
 *
 * Only the OpenAI-compatible /chat/completions shape is spoken, because that
 * one dialect covers OpenAI, DeepSeek, Moonshot, GLM, DashScope, SiliconFlow,
 * OpenRouter and Ollama. One adapter instead of eight.
 */
(function () {
  'use strict';

  var CFG_KEY = 'myschedule.ai.v1';
  var DEFAULTS = {
    baseUrl: 'https://api.openai.com/v1',
    apiKey: '',
    model: 'gpt-4o-mini',
    vision: true,
    timeoutMs: 180000,
    /* How the assistant introduces itself in the chat tab. Purely cosmetic,
       and it lives with the key so it never reaches cloud sync either. */
    assistantName: '小安',
    /* Whether the chat tab may read the user's own data. On by default --
       an assistant that cannot see the calendar is not much of an assistant --
       but it is the user's call, since the digest travels to whichever
       endpoint they configured. Treated as "on unless explicitly false" so
       configs saved before this key existed keep working. */
    shareData: true
  };

  /* Vendors differ only in three strings, and typing a base URL by hand on a
     phone is where most setups die. `vision` is whether the DEFAULT model
     listed can read images. */
  var PRESETS = [
    { name: 'OpenAI', baseUrl: 'https://api.openai.com/v1', model: 'gpt-4o-mini', vision: true },
    { name: 'DeepSeek', baseUrl: 'https://api.deepseek.com/v1', model: 'deepseek-chat', vision: false },
    { name: 'Kimi (Moonshot)', baseUrl: 'https://api.moonshot.cn/v1', model: 'moonshot-v1-32k', vision: false },
    { name: '智谱 GLM', baseUrl: 'https://open.bigmodel.cn/api/paas/v4', model: 'glm-4-flash', vision: true },
    { name: '通义千问', baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1', model: 'qwen-plus', vision: false },
    { name: 'SiliconFlow', baseUrl: 'https://api.siliconflow.cn/v1', model: 'Qwen/Qwen2.5-7B-Instruct', vision: false },
    { name: 'OpenRouter', baseUrl: 'https://openrouter.ai/api/v1', model: 'openai/gpt-4o-mini', vision: true },
    { name: 'Ollama (本地)', baseUrl: 'http://localhost:11434/v1', model: 'qwen2.5:7b', vision: false },
    /* Free, no-credit-card tiers that are OpenAI-compatible. Gemini's
       /v1beta/openai/ path is Google's OpenAI-shaped endpoint; Groq serves
       open-weight models (Llama / DeepSeek) on free LPU inference. */
    { name: 'Google Gemini', baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai/', model: 'gemini-2.5-flash', vision: true },
    { name: 'Groq', baseUrl: 'https://api.groq.com/openai/v1', model: 'llama-3.3-70b-versatile', vision: false }
  ];

  var cfg = loadCfg();
  /* Test seam: selftest installs a responder so the whole pipeline can be
     exercised without a network call or a key. */
  var responder = null;

  function loadCfg() {
    try {
      var raw = localStorage.getItem(CFG_KEY);
      if (!raw) return copy(DEFAULTS);
      var o = JSON.parse(raw);
      var out = copy(DEFAULTS);
      for (var k in DEFAULTS) {
        if (Object.prototype.hasOwnProperty.call(DEFAULTS, k) && o[k] != null) out[k] = o[k];
      }
      return out;
    } catch (e) { return copy(DEFAULTS); }
  }
  function copy(o) {
    var r = {};
    for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) r[k] = o[k];
    return r;
  }
  function saveCfg() {
    try { localStorage.setItem(CFG_KEY, JSON.stringify(cfg)); } catch (e) { }
  }

  /* ------------------------------------------------------------ transport */
  function endpoint() {
    var b = String(cfg.baseUrl || '').replace(/\/+$/, '');
    if (!b) return '';
    return /\/chat\/completions$/.test(b) ? b : b + '/chat/completions';
  }

  function chat(messages, opts) {
    opts = opts || {};
    if (responder) return Promise.resolve(responder(messages, opts));
    var url = endpoint();
    if (!url) return Promise.reject(err('config', 'no base url'));
    if (!cfg.apiKey && !/localhost|127\.0\.0\.1/.test(url)) {
      return Promise.reject(err('auth', 'no api key'));
    }
    var body = {
      model: cfg.model,
      messages: messages,
      temperature: opts.temperature == null ? 0.2 : opts.temperature
    };
    var ctl = typeof AbortController === 'function' ? new AbortController() : null;
    var timer = setTimeout(function () { if (ctl) ctl.abort(); }, cfg.timeoutMs || 90000);
    var init = {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    };
    if (cfg.apiKey) init.headers.Authorization = 'Bearer ' + cfg.apiKey;
    if (ctl) init.signal = ctl.signal;

    return fetch(url, init).then(function (r) {
      clearTimeout(timer);
      return r.text().then(function (txt) { return { status: r.status, text: txt }; });
    }).then(function (res) {
      lastRawText = res.text || '';
      var txt = res.text || '';
      var data = null;
      try { data = JSON.parse(txt); } catch (e) { data = null; }
      if (res.status === 401 || res.status === 403) throw err('auth', 'HTTP ' + res.status);
      if (res.status >= 400) {
        var msg = (data && (data.error && (data.error.message || data.error.code))) || txt.slice(0, 160);
        throw err(res.status === 404 ? 'model' : 'http', 'HTTP ' + res.status + ' ' + msg);
      }
      /* Non-standard error bodies (e.g. SiliconFlow returns
         {"code":500,"msg":"404 NOT_FOUND","success":false} on a 200) must be
         surfaced as a real API error, not mistaken for empty content. */
      if (data && data.success === false) {
        var detail = data.msg || 'unknown error';
        throw err('api', detail + (data.code != null ? ' [code ' + data.code + ']' : '') +
          (lang() !== 'en' ? '：模型名或请求路径不正确（请核对厂商预设与模型名是否匹配你的 API Key）'
                           : ': wrong model name or endpoint path (check the preset and model match your key)'));
      }
      if (data && data.error && (data.error.message || data.error.code || data.error.type)) {
        throw err('api', data.error.message || String(data.error.code || data.error.type));
      }
      var content = null;
      if (data && data.choices && data.choices[0]) {
        var ch = data.choices[0];
        content = ch.message && ch.message.content != null ? ch.message.content
                : (ch.text != null ? ch.text : null);
      }
      if (content == null && data && data.content != null) content = data.content;
      if (content == null) throw err('shape', 'no content in response', res.text);
      return String(content);
    }).catch(function (e) {
      clearTimeout(timer);
      if (e && e.aiKind) throw e;
      /* fetch rejects on DNS, TLS, CORS and abort alike -- the message never
         says which, so translate by elimination. */
      var name = e && e.name;
      if (name === 'AbortError') throw err('timeout', 'request timed out');
      throw err('network', (e && e.message) || 'network error');
    });
  }

  function err(kind, msg, raw) {
    var e = new Error(msg || kind);
    e.aiKind = kind;
    if (raw != null) e.raw = String(raw);
    return e;
  }

  var lastRawText = '';

  /* Models still wrap JSON in prose, fences or stray braces even when told
     not to. Be forgiving: strip a fenced block, then take the first fully
     balanced {…} or […] (string-aware), and salvage common slips like
     trailing commas or single-quoted keys. */
  function parseJSON(text) {
    if (!text) return null;
    var s = String(text).trim();
    var fence = s.match(/```(?:json)?\s*([\s\S]*?)```/i);
    if (fence) s = fence[1].trim();
    return tryParse(s) || extractBalanced(s, '{', '}') || extractBalanced(s, '[', ']');
  }

  function tryParse(t) {
    try { return JSON.parse(t); } catch (e) { return null; }
  }

  /* Walk from the first open bracket, respecting strings and escapes, and
     return the value once brackets balance — so trailing prose, a second
     stray object, or a truncated tail never poison the parse. */
  function extractBalanced(s, open, close) {
    var first = s.indexOf(open);
    if (first < 0) return null;
    var depth = 0, inStr = false, esc = false;
    for (var i = first; i < s.length; i++) {
      var c = s.charAt(i);
      if (inStr) {
        if (esc) esc = false;
        else if (c === '\\') esc = true;
        else if (c === '"') inStr = false;
        continue;
      }
      if (c === '"') { inStr = true; continue; }
      if (c === open) depth++;
      else if (c === close) {
        if (--depth === 0) {
          var slice = s.slice(first, i + 1);
          return tryParse(slice) || tryParse(fixJSON(slice)) || null;
        }
      }
    }
    /* Unterminated tail (truncated reply): drop the dangling partial value
       and retry once before giving up. */
    var cut = s.slice(first).replace(/,?\s*[^,{}\[\]]*$/, '');
    return tryParse(cut) || tryParse(fixJSON(cut)) || null;
  }

  /* Last-resort cleanup for models that emit almost-JSON: drop trailing
     commas before } or ], and quote single-quoted *keys* (not string values). */
  function fixJSON(t) {
    return t
      .replace(/,(\s*[}\]])/g, '$1')
      .replace(/'([^']+)'\s*:/g, '"$1":');
  }

  function askJSON(messages, opts) {
    return chat(messages, opts).then(function (txt) {
      var o = parseJSON(txt);
      if (!o) throw err('shape', 'model did not return JSON', txt);
      return o;
    });
  }

  /* ------------------------------------------------------------- helpers */
  function toMin(v, fallback) {
    if (typeof v === 'number' && isFinite(v)) return Math.round(v);
    if (typeof v === 'string' && v.indexOf(':') > 0 && window.Store && Store.fromHHMM) {
      var m = Store.fromHHMM(v);
      if (m != null && isFinite(m)) return m;
    }
    if (typeof v === 'string' && /^\d+$/.test(v.trim())) return parseInt(v.trim(), 10);
    return fallback == null ? null : fallback;
  }
  function hhmm(m) {
    if (window.Store && Store.hhmm) return Store.hhmm(m);
    var h = Math.floor(m / 60), mm = m % 60;
    return (h < 10 ? '0' : '') + h + ':' + (mm < 10 ? '0' : '') + mm;
  }
  function addDays(isoStr, n) {
    var d = window.Store && Store.parseISO ? Store.parseISO(isoStr) : null;
    if (!d) return isoStr;
    d.setDate(d.getDate() + n);
    return Store.iso(d);
  }
  function mondayOf(isoStr) {
    var d = window.Store && Store.startOfWeek ? Store.startOfWeek(Store.parseISO(isoStr)) : null;
    return d ? Store.iso(d) : isoStr;
  }
  function tags() {
    return (window.Views && Views.tagNames) ? Views.tagNames() : [];
  }
  function knownTag(t) {
    var list = tags();
    if (!t) return list[0] || 'work';
    for (var i = 0; i < list.length; i++) if (list[i] === t) return t;
    return null;
  }

  /* ------------------------------------------------- draft normalisation */
  /* Round-trip, not just "parses": new Date('2026-02-30') quietly rolls over
     to March, so a format check alone would let February 30th through. */
  function validISO(s) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(String(s || ''))) return false;
    var d = Store.parseISO(s);
    return !!d && Store.iso(d) === s;
  }

  var REPEATS = ['none', 'daily', 'weekly', 'monthly', 'yearly'];
  var OPS = ['move', 'update', 'delete', 'done'];

  /* Raw model output -> events the app can store, plus the rejects with a
     human reason. Anything questionable is downgraded, not dropped: a missing
     end time becomes +60min with a note, an unknown tag becomes the first
     real tag. */
  function normalizeEvents(list) {
    var ok = [], bad = [];
    if (!list || !list.length) return { ok: ok, bad: bad };
    for (var i = 0; i < list.length; i++) {
      var raw = list[i];
      if (!raw || typeof raw !== 'object') { bad.push({ item: raw, why: 'notObject' }); continue; }
      var title = String(raw.title || raw.name || '').trim();
      if (!title) { bad.push({ item: raw, why: 'noTitle' }); continue; }

      var date = String(raw.date || '').trim();
      if (!/^\d{4}-\d{1,2}-\d{1,2}$/.test(date)) { bad.push({ item: raw, why: 'badDate', title: title }); continue; }
      var parts = date.split('-');
      var iso = parts[0] + '-' + ('0' + parts[1]).slice(-2) + '-' + ('0' + parts[2]).slice(-2);
      if (!validISO(iso)) { bad.push({ item: raw, why: 'badDate', title: title }); continue; }

      var start = toMin(raw.start != null ? raw.start : raw.begin, null);
      var end = toMin(raw.end != null ? raw.end : raw.finish, null);
      var note = String(raw.note || raw.notes || '').trim();
      if (start == null && end == null) { start = 9 * 60; end = 10 * 60; note = (note ? note + ' ' : '') + '(时间未标注)'; }
      else if (start == null) { start = Math.max(0, end - 60); }
      else if (end == null) { end = start + 60; }
      if (start < 0) start = 0;
      if (end > 1440) end = 1440;
      if (end <= start) end = Math.min(1440, start + 60);
      if (end <= start) { bad.push({ item: raw, why: 'badTime', title: title }); continue; }

      var rep = 'none';
      if (raw.repeat && REPEATS.indexOf(String(raw.repeat)) >= 0) rep = String(raw.repeat);
      var every = parseInt(raw.repeatEvery, 10);
      if (!isFinite(every) || every < 1) every = 1;
      var until = /^\d{4}-\d{2}-\d{2}$/.test(String(raw.repeatUntil || '')) ? String(raw.repeatUntil) : '';

      var tag = knownTag(raw.tag);
      if (!tag) tag = tags()[0] || 'work';

      ok.push({
        title: title.slice(0, 80),
        date: iso,
        start: start,
        end: end,
        tag: tag,
        note: note.slice(0, 300),
        repeat: rep,
        repeatEvery: rep === 'none' ? 1 : every,
        repeatUntil: rep === 'none' ? '' : until
      });
    }
    return { ok: ok, bad: bad };
  }

  /* Same day, overlapping minutes: worth flagging, not worth blocking -- the
     user may be importing a duplicate on purpose, or replacing one. */
  function conflictOf(e) {
    var list = Store.expandedEventsOn(e.date) || [];
    for (var i = 0; i < list.length; i++) {
      var o = list[i];
      var os = o.start || 0, oe = o.end || (os + 60);
      if (e.start < oe && os < e.end) {
        return (o.title || '?') + ' ' + hhmm(os) + '-' + hhmm(oe);
      }
    }
    return '';
  }

  /* ------------------------------------------------------- free slots ---- */
  /* The complement of the day's busy intervals, clipped to waking hours.
     This is what keeps a generated plan from landing on top of a lecture. */
  function freeSlots(dateStr, opts) {
    opts = opts || {};
    var dayStart = opts.dayStart == null ? 8 * 60 : opts.dayStart;
    var dayEnd = opts.dayEnd == null ? 22 * 60 : opts.dayEnd;
    var minChunk = opts.minChunk == null ? 30 : opts.minChunk;
    var busy = [];
    var list = Store.expandedEventsOn(dateStr) || [];
    for (var i = 0; i < list.length; i++) {
      var s = list[i].start || 0;
      var e = list[i].end || (s + 60);
      if (e <= dayStart || s >= dayEnd) continue;
      busy.push([Math.max(s, dayStart), Math.min(e, dayEnd)]);
    }
    busy.sort(function (a, b) { return a[0] - b[0]; });
    var out = [], cur = dayStart;
    for (var j = 0; j < busy.length; j++) {
      if (busy[j][0] - cur >= minChunk) out.push({ date: dateStr, start: cur, end: busy[j][0] });
      cur = Math.max(cur, busy[j][1]);
    }
    if (dayEnd - cur >= minChunk) out.push({ date: dateStr, start: cur, end: dayEnd });
    return out;
  }

  function preferKey(slot, prefer) {
    if (prefer === 'am') return slot.start < 12 * 60 ? 0 : (slot.start < 18 * 60 ? 1 : 2);
    if (prefer === 'pm') return (slot.start >= 12 * 60 && slot.start < 18 * 60) ? 0 : (slot.start < 12 * 60 ? 1 : 2);
    if (prefer === 'night') return slot.start >= 18 * 60 ? 0 : (slot.start >= 12 * 60 ? 1 : 2);
    return 0;
  }

  /* One week's gaps, ordered the way the user likes to work: preferred time
     of day first, then earliest day. Weeks are generated lazily so an
     over-ambitious plan can spill into the next one instead of vanishing. */
  function weekSlots(mondayStr, opts) {
    var slots = [];
    for (var d = 0; d < 7; d++) {
      var day = addDays(mondayStr, d);
      var free = freeSlots(day, opts);
      for (var i = 0; i < free.length; i++) slots.push(free[i]);
    }
    var prefer = opts.prefer || 'any';
    slots.sort(function (a, b) {
      var ka = preferKey(a, prefer), kb = preferKey(b, prefer);
      if (ka !== kb) return ka - kb;
      if (a.date !== b.date) return a.date < b.date ? -1 : 1;
      return a.start - b.start;
    });
    return slots;
  }

  /* Fit weekly tasks into real gaps. The model decides WHAT to study and how
     long; the app decides WHEN, because only the app knows which Tuesday is
     actually free. */
  function assign(tasks, opts) {
    opts = opts || {};
    var startMonday = mondayOf(opts.startDate || Store.todayStr());
    var maxPerDay = opts.maxPerDayMin || 180;
    var weeks = opts.weeks || 8;
    var out = [], unplaced = [];
    var used = {};          /* date -> minutes already taken by this plan */
    var pool = [], poolWeek = 0;

    var queue = (tasks || []).slice().sort(function (a, b) {
      var wa = parseInt(a.week, 10) || 1, wb = parseInt(b.week, 10) || 1;
      return wa - wb;
    });

    for (var t = 0; t < queue.length; t++) {
      var task = queue[t];
      var need = parseInt(task.minutes, 10) || 60;
      var weekNo = Math.max(1, parseInt(task.week, 10) || 1);
      /* Keep the plan honest: week 3's work should not be done in week 1. */
      while (poolWeek + 1 < weekNo && poolWeek < weeks + 2) { pool = []; poolWeek++; }
      var guard = 0;
      var placed = [];
      while (need > 0 && guard++ < 400) {
        if (!pool.length) {
          if (poolWeek >= weeks + 2) break;
          pool = weekSlots(addDays(startMonday, poolWeek * 7), opts);
          poolWeek++;
          if (!pool.length) continue;
        }
        var slot = pool.shift();
        if (!slot) continue;
        var dayUsed = used[slot.date] || 0;
        var room = Math.min(slot.end - slot.start, maxPerDay - dayUsed);
        if (room < 15) continue;
        var take = Math.min(need, room);
        placed.push({ date: slot.date, start: slot.start, end: slot.start + take });
        used[slot.date] = dayUsed + take;
        need -= take;
        if (slot.start + take < slot.end) {
          pool.unshift({ date: slot.date, start: slot.start + take, end: slot.end });
        }
      }
      if (!placed.length) { unplaced.push(task); continue; }
      for (var p = 0; p < placed.length; p++) {
        var seg = placed[p];
        out.push({
          title: String(task.title || '').slice(0, 80),
          date: seg.date,
          start: seg.start,
          end: seg.end,
          tag: knownTag(task.tag) || tags()[0] || 'work',
          note: (task.note ? String(task.note) + ' ' : '') + (task.stage ? '[' + task.stage + ']' : ''),
          repeat: 'none',
          repeatEvery: 1,
          repeatUntil: ''
        });
      }
      if (need > 0) unplaced.push({ title: task.title, minutes: need, week: weekNo });
    }
    return { events: out, unplaced: unplaced };
  }

  /* ------------------------------------------------------------ ops ------ */
  /* An "edit my schedule" instruction is answered as operations, never as a
     rewritten calendar: ids come from the app, so the model cannot invent
     one, and every op is a diff the user can read before it lands. */
  function normalizeOps(list, ctxIds) {
    var ok = [], bad = [];
    if (!list || !list.length) return { ok: ok, bad: bad };
    for (var i = 0; i < list.length; i++) {
      var raw = list[i];
      if (!raw || typeof raw !== 'object') { bad.push({ item: raw, why: 'notObject' }); continue; }
      var op = String(raw.op || raw.action || '').toLowerCase();
      if (OPS.indexOf(op) < 0) { bad.push({ item: raw, why: 'badOp' }); continue; }
      var id = String(raw.id || '');
      if (!id || (ctxIds && ctxIds.indexOf(id) < 0)) { bad.push({ item: raw, why: 'unknownId', title: id }); continue; }
      var rec = Store.findEvent(id);
      if (!rec) { bad.push({ item: raw, why: 'unknownId', title: id }); continue; }

      if (op === 'delete' || op === 'done') {
        ok.push({ op: op, id: id, before: snap(rec), after: null });
        continue;
      }
      var date = String(raw.date || rec.date || '').trim();
      if (!validISO(date)) { bad.push({ item: raw, why: 'badDate', title: rec.title }); continue; }
      var start = toMin(raw.start, rec.start);
      var end = toMin(raw.end, rec.end != null ? rec.end : (rec.start + 60));
      if (start == null || end == null) { bad.push({ item: raw, why: 'badTime', title: rec.title }); continue; }
      if (end <= start) end = start + 60;
      if (end > 1440) { bad.push({ item: raw, why: 'badTime', title: rec.title }); continue; }

      if (op === 'move') {
        ok.push({
          op: 'move', id: id,
          before: snap(rec),
          after: { date: date, start: start, end: end, title: rec.title }
        });
      } else {
        var patch = {};
        var allowed = ['title', 'tag', 'note', 'done', 'reminderMin', 'repeat', 'repeatEvery', 'repeatUntil'];
        var src = raw.patch && typeof raw.patch === 'object' ? raw.patch : raw;
        for (var k = 0; k < allowed.length; k++) {
          var key = allowed[k];
          if (src[key] == null) continue;
          patch[key] = src[key];
        }
        /* Date/time also arrive on update ops (they are part of the patch);
           validated above, so fold them in. */
        if (raw.date || raw.start || raw.end) {
          patch.date = date; patch.start = start; patch.end = end;
        }
        if (patch.tag && !knownTag(patch.tag)) patch.tag = tags()[0] || 'work';
        if (!Object.keys(patch).length) { bad.push({ item: raw, why: 'emptyPatch', title: rec.title }); continue; }
        ok.push({ op: 'update', id: id, before: snap(rec), after: patch });
      }
    }
    return { ok: ok, bad: bad };
  }

  function snap(rec) {
    return {
      title: rec.title, date: rec.date, start: rec.start,
      end: rec.end != null ? rec.end : (rec.start + 60), tag: rec.tag, done: !!rec.done
    };
  }

  /* --------------------------------------------------------- applying --- */
  /* One snapshot for the whole batch: importing twelve courses should cost
     one undo, not twelve. */
  function transact(fn, reason) {
    if (window.Undo && Undo.transact) return Undo.transact(fn, reason || 'ai.batch');
    fn();
    return 1;
  }

  function applyEvents(list) {
    var n = 0;
    transact(function () {
      for (var i = 0; i < list.length; i++) {
        var e = list[i];
        Store.newEvent({
          title: e.title, date: e.date, start: e.start, end: e.end,
          tag: e.tag, note: e.note, repeat: e.repeat,
          repeatEvery: e.repeatEvery, repeatUntil: e.repeatUntil
        });
        n++;
      }
    }, 'ai.import');
    return n;
  }

  function applyOps(list) {
    var n = 0;
    transact(function () {
      for (var i = 0; i < list.length; i++) {
        var o = list[i];
        if (o.op === 'delete') { Store.removeEvent(o.id); n++; }
        else if (o.op === 'done') { Store.updateEvent(o.id, { done: true }); n++; }
        else if (o.op === 'move') { Store.updateEvent(o.id, { date: o.after.date, start: o.after.start, end: o.after.end }); n++; }
        else { Store.updateEvent(o.id, o.after); n++; }
      }
    }, 'ai.edit');
    return n;
  }

  /* ------------------------------------------------------------ prompts - */
  function lang() { return (window.lang && window.lang()) || 'zh'; }

  function sys(text) { return { role: 'system', content: text }; }

  function importPrompt(text, year) {
    var zh = lang() !== 'en';
    var rules = zh
      ? '你是日程提取器。从用户给的文本或课表图片里提取所有日程，只输出 JSON：\n' +
        '{"events":[{"title":"","date":"YYYY-MM-DD","start":"HH:MM","end":"HH:MM","tag":"","note":"","repeat":"none|daily|weekly|monthly|yearly","repeatEvery":1,"repeatUntil":""}],"notes":""}\n' +
        '规则：年份缺失用 ' + year + '；只有星期几（如"每周三"）时，取该文本所指的最近那个周三，repeat 设为 weekly；' +
        '时间缺失就填 09:00-10:00 并在 note 写"时间未标注"；tag 只能从 ' + tags().join('/') + ' 里选，不确定就留空；' +
        '不要编造信息，不确定的写进 note；只输出纯 JSON（不要使用 Markdown 代码块包裹，直接以 { 或 [ 开头），不要输出 JSON 以外的任何解释文字。'
      : 'You extract calendar entries. Return JSON only:\n' +
        '{"events":[{"title":"","date":"YYYY-MM-DD","start":"HH:MM","end":"HH:MM","tag":"","note":"","repeat":"none|daily|weekly|monthly|yearly","repeatEvery":1,"repeatUntil":""}],"notes":""}\n' +
        'Missing year: use ' + year + '. A bare weekday ("every Wednesday") means the nearest such day and repeat:"weekly". ' +
        'Missing time: 09:00-10:00 with note "time unknown". tag must be one of ' + tags().join('/') + ' or empty. Never invent facts. Output raw JSON only, no code fences, no prose.';
    return [sys(rules), { role: 'user', content: String(text || '').slice(0, 12000) }];
  }

  function importImagePrompt(text, images, year) {
    var msgs = importPrompt(text || (lang() !== 'en' ? '请识别图片中的课表/通知，提取所有日程。' : 'Read the timetable in this image and extract every entry.'), year);
    var last = msgs[msgs.length - 1];
    var content = [{ type: 'text', text: last.content }];
    for (var i = 0; i < images.length; i++) {
      content.push({ type: 'image_url', image_url: { url: images[i] } });
    }
    msgs[msgs.length - 1] = { role: 'user', content: content };
    return msgs;
  }

  function planPrompt(goal, opts) {
    var zh = lang() !== 'en';
    var rules = zh
      ? '你做备考/项目拆解。把目标拆成阶段和周任务，只输出 JSON：\n' +
        '{"stages":[{"name":"","week":1}],"tasks":[{"title":"","week":1,"minutes":120,"stage":"","tag":"","note":""}],"notes":""}\n' +
        '约束：从现在到 ' + opts.due + ' 共 ' + opts.weeks + ' 周；每周投入不超过 ' + opts.hours + ' 小时；' +
        '每个任务的 minutes 在 45-240 之间；按周递增推进，同一周的任务总分钟不超过 ' + (opts.hours * 60) + '；' +
        'title 要具体可执行（写清章节/任务），不要写"复习"这种空话；只输出纯 JSON（不要使用 Markdown 代码块包裹），不要输出 JSON 以外的任何解释文字。'
      : 'Break the goal into stages and weekly tasks. Return JSON only:\n' +
        '{"stages":[{"name":"","week":1}],"tasks":[{"title":"","week":1,"minutes":120,"stage":"","tag":"","note":""}],"notes":""}\n' +
        'From now until ' + opts.due + ' there are ' + opts.weeks + ' weeks; at most ' + opts.hours + ' hours per week; ' +
        'each task 45-240 minutes; titles must be concrete. Output raw JSON only, no code fences, no prose.';
    var user = zh
      ? '目标：' + goal + '\n截止：' + opts.due
      : 'Goal: ' + goal + '\nDue: ' + opts.due;
    return [sys(rules), { role: 'user', content: user }];
  }

  function editPrompt(cmd, ctx) {
    var zh = lang() !== 'en';
    var rules = zh
      ? '你把一个自然语言指令翻译成对既有日程的操作，只输出 JSON：\n' +
        '{"ops":[{"op":"move|update|delete|done","id":"","date":"YYYY-MM-DD","start":"HH:MM","end":"HH:MM","patch":{}}],"notes":""}\n' +
        '规则：只能使用下面列表里出现过的 id，绝不能自己编；move/update 需要 date、start、end（"往后挪一小时"= start 和 end 各 +60 分钟）；' +
        'update 的 patch 只能是 title/tag/note/done/reminderMin；无法判断的条目直接省略，不要猜测；只输出纯 JSON（不要使用 Markdown 代码块包裹），不要输出 JSON 以外的任何解释文字。'
      : 'Translate the instruction into operations on the listed events. Return JSON only:\n' +
        '{"ops":[{"op":"move|update|delete|done","id":"","date":"YYYY-MM-DD","start":"HH:MM","end":"HH:MM","patch":{}}],"notes":""}\n' +
        'Only use ids from the list; never invent one. move/update need date, start and end. Skip anything ambiguous. Output raw JSON only, no code fences, no prose.';
    var body = JSON.stringify(ctx || []);
    return [sys(rules), { role: 'user', content: (zh ? '当前日程：\n' : 'Current events:\n') + body + '\n\n' +
      (zh ? '指令：' : 'Instruction: ') + cmd }];
  }

  /* -------------------------------------------------- chat data digest -- */
  /* A read-only digest of the user's own data, rebuilt on every send so the
     assistant talks about the real week instead of inventing one. Compact and
     capped on purpose: it rides along with every chat turn, so a semester of
     classes must not turn into a semester of tokens. Repeating series are
     written as rules ("每周一 08:00 法理学"), never as one line per
     occurrence -- that single choice is what keeps the digest flat. */
  var WD_ZH = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
  var WD_EN = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  var RP_ZH = { daily: '每天', weekly: '每周', monthly: '每月', yearly: '每年' };
  var PRI_ZH = { high: '高', medium: '中', low: '低' };

  function wdOf(dateStr, zh) {
    var d = new Date(dateStr + 'T00:00:00');
    if (isNaN(d.getTime())) return '';
    return (zh ? WD_ZH : WD_EN)[d.getDay()];
  }

  function snapEvent(e, zh) {
    var s = hhmm(e.start || 0);
    var en = e.end != null ? e.end : (e.start || 0) + 60;
    var txt = s + '-' + hhmm(en) + ' ' + (e.title || (zh ? '(无标题)' : '(untitled)'));
    if (e.tag) txt += ' [' + e.tag + ']';
    if (e.done) txt += zh ? ' 已完成' : ' done';
    return txt;
  }

  function snapshot(opts) {
    if (!window.Store) return '';
    var o = opts || {};
    var zh = lang() !== 'en';
    var days = o.days || 7;
    var cap = o.maxChars || 3500;
    var today = Store.todayStr();
    var out = [];

    out.push((zh ? '今天 ' : 'Today ') + today + '（' + wdOf(today, zh) + '）');

    /* Today: what the user asks about most, with done state included. */
    var tdy = Store.expandedEventsOn(today) || [];
    if (!tdy.length) out.push(zh ? '今日日程：空' : "Today's schedule: empty");
    else {
      out.push((zh ? '今日日程（' : "Today's events (") + tdy.length + (zh ? ' 项）' : ')'));
      var prevEnd = -1;
      for (var i = 0; i < tdy.length && i < 30; i++) {
        var st = tdy[i].start || 0;
        var fin = tdy[i].end != null ? tdy[i].end : st + 60;
        /* Overlaps are the one judgement a model reliably misses when it is
           skimming a list, so mark them in the data itself. */
        var clash = prevEnd > st;
        out.push('- ' + snapEvent(tdy[i], zh) +
          (clash ? (zh ? ' ⚠与上一条时间重叠' : ' [overlaps previous]') : ''));
        if (fin > prevEnd) prevEnd = fin;
      }
    }

    var all = Store.events || [];

    /* Repeating series as rules, so a whole semester costs one line. */
    var series = [];
    for (var k = 0; k < all.length; k++) {
      var e = all[k];
      if (!e || !e.repeat || e.repeat === 'none') continue;
      var lbl = RP_ZH[e.repeat] || e.repeat;
      if (e.repeat === 'weekly') lbl = (zh ? '每周' : 'every ') + wdOf(e.date, zh);
      if (!zh) lbl = e.repeat === 'weekly' ? lbl : (e.repeat || '');
      var every = parseInt(e.repeatEvery, 10) || 1;
      if (every > 1) lbl += zh ? '（每 ' + every + ' 轮）' : ' (every ' + every + ')';
      series.push('- ' + lbl + ' ' + snapEvent(e, zh) +
        (e.repeatUntil ? (zh ? '，至 ' : ', until ') + e.repeatUntil : ''));
    }
    if (series.length) {
      out.push((zh ? '重复安排（' : 'Recurring (') + series.length + (zh ? ' 条规则）' : ' rules)'));
      out.push.apply(out, series.slice(0, 25));
    }

    /* One-off events in the window ahead, grouped by day. */
    var from = addDays(today, 1);
    var to = addDays(today, days);
    var byDay = {};
    var cnt = 0;
    for (var m = 0; m < all.length; m++) {
      var x = all[m];
      if (!x || (x.repeat && x.repeat !== 'none') || !x.date) continue;
      if (x.date < from || x.date > to) continue;
      (byDay[x.date] = byDay[x.date] || []).push(x);
      cnt++;
    }
    if (cnt) {
      out.push((zh ? '未来 ' + days + ' 天的一次性安排（' : 'One-off events in the next ' + days + ' days (') +
        cnt + (zh ? ' 项）' : ')'));
      var keys = Object.keys(byDay).sort();
      for (var d2 = 0; d2 < keys.length && d2 < 14; d2++) {
        out.push('- ' + keys[d2] + '(' + wdOf(keys[d2], zh) + ')：' +
          byDay[keys[d2]].slice(0, 8).map(function (z) { return snapEvent(z, zh); }).join('；'));
      }
    }

    /* Open tasks, most pressing first. */
    var tasks = (Store.tasks || []).slice();
    var open = tasks.filter(function (tk) { return !tk.done; });
    if (tasks.length) {
      var rank = { high: 0, medium: 1, low: 2 };
      open.sort(function (a, b) {
        var pa = rank[a.priority] != null ? rank[a.priority] : 1;
        var pb = rank[b.priority] != null ? rank[b.priority] : 1;
        if (pa !== pb) return pa - pb;
        return String(a.due || '9999') < String(b.due || '9999') ? -1 : 1;
      });
      out.push((zh ? '待办任务（未完成 ' : 'Tasks (') + open.length + '/' + tasks.length + (zh ? '）' : ' open)'));
      for (var q = 0; q < open.length && q < 30; q++) {
        var tk = open[q];
        var line = '- [' + (PRI_ZH[tk.priority] || tk.priority || '-') + '] ' + (tk.text || '');
        if (tk.due) line += (zh ? ' · 截止 ' : ' · due ') + tk.due;
        if (tk.project) line += ' · ' + tk.project;
        if (tk.subtasks && tk.subtasks.length) {
          var dn = tk.subtasks.filter(function (s) { return s && s.done; }).length;
          line += ' · ' + dn + '/' + tk.subtasks.length;
        }
        out.push(line);
      }
    }

    /* Focus: same log the hero and the stats week read. */
    var fToday = Store.focusOn(today) || 0;
    var fWeek = 0;
    for (var w = 0; w < 7; w++) fWeek += Store.focusOn(addDays(today, -w)) || 0;
    out.push(zh
      ? '专注：今天 ' + fToday + ' 分钟，近 7 天 ' + fWeek + ' 分钟（日均 ' + Math.round(fWeek / 7) + '）'
      : 'Focus: ' + fToday + ' min today, ' + fWeek + ' min in the last 7 days (avg ' + Math.round(fWeek / 7) + ')');

    var text = out.join('\n');
    if (text.length > cap) text = text.slice(0, cap) + (zh ? '\n（…已截断）' : '\n(...truncated)');
    return text;
  }

  /* The chat tab's persona. With a digest (ctx) it can answer questions about
     the real calendar; without one it must keep its hands off the subject.
     Writing stays in the edit tab either way -- a chat reply that silently
     moved a class would be exactly the failure this file was built to prevent. */
  function chatSystem(name, today, ctx) {
    var zh = lang() !== 'en';
    var head = zh
      ? '你是 MySchedule 日程应用里的助手，名字叫「' + name + '」。今天是 ' + today + '。\n' +
        '用简洁自然的中文回答，能一步说清就不要铺开；不知道就直说不知道。\n'
      : 'You are the assistant inside MySchedule, named "' + name + '". Today is ' + today + '.\n' +
        'Answer concisely and naturally; say so when you do not know.\n';
    var body = ctx
      ? (zh
        ? '下面是用户在此应用里的真实数据（只读，随每次提问一起给你）。回答时可以直接引用它，' +
          '比如"你今天下午三点有课""这周有 4 个待办没截止"。\n' +
          '规则：只依据下面的数据说话，没有的就说没有，绝不虚构日程或任务；' +
          '时间冲突、空档、负荷是否过重这类判断请主动提醒；' +
          '用户问"我今天/这周有什么安排"时，直接列出来，不要反问。\n'
        : "Below is the user's real data in this app (read-only, sent with every question). " +
          'Quote it freely, e.g. "you have class at 3pm today".\n' +
          'Rules: speak only from this data; never invent events or tasks; ' +
          'flag conflicts, gaps and overload on your own initiative.\n')
      : (zh
        ? '你没有读取用户日程的权限，不要猜测或虚构他的安排。\n'
        : "You cannot see the user's data; never guess or invent their schedule.\n");
    var tail = zh
      ? '注意：你只能对话，不能直接修改日程；用户要改日程请让他用「改程」页。\n' +
        '不要输出 JSON 或代码。'
      : 'You cannot edit the calendar -- point the user at the Edit tab for that.\n' +
        'Never output JSON or code.';
    return head + body + tail + (ctx ? '\n\n' + ctx : '');
  }

  /* The context handed to the model: just enough to act on, small enough to
     be cheap. Titles are kept because "把法理学的课挪后" needs the name. */
  function contextEvents(rangeDays) {
    var out = [];
    var from = Store.todayStr();
    var n = rangeDays || 7;
    for (var i = 0; i < n; i++) {
      var day = addDays(from, i);
      var list = Store.expandedEventsOn(day) || [];
      for (var j = 0; j < list.length; j++) {
        var e = list[j];
        out.push({
          id: String(e.id).split('@')[0],
          title: e.title,
          date: day,
          start: hhmm(e.start || 0),
          end: hhmm(e.end != null ? e.end : (e.start + 60)),
          tag: e.tag,
          repeat: e.repeat || 'none',
          done: !!e.done
        });
      }
    }
    return out;
  }

  function contextIds(ctx) {
    var ids = [];
    for (var i = 0; i < ctx.length; i++) {
      if (ids.indexOf(ctx[i].id) < 0) ids.push(ctx[i].id);
    }
    return ids;
  }

  /* ------------------------------------------------------------- export - */
  window.AI = {
    PRESETS: PRESETS,
    cfg: function () { return cfg; },
    setCfg: function (patch) {
      for (var k in patch) {
        if (Object.prototype.hasOwnProperty.call(patch, k)) cfg[k] = patch[k];
      }
      saveCfg();
      return cfg;
    },
    ready: function () { return !!cfg.model && (!!cfg.apiKey || /localhost|127\.0\.0\.1/.test(cfg.baseUrl || '')); },
    chat: chat,
    askJSON: askJSON,
    parseJSON: parseJSON,
    normalizeEvents: normalizeEvents,
    normalizeOps: normalizeOps,
    conflictOf: conflictOf,
    freeSlots: freeSlots,
    weekSlots: weekSlots,
    assign: assign,
    applyEvents: applyEvents,
    applyOps: applyOps,
    apply: transact,
    contextEvents: contextEvents,
    contextIds: contextIds,
    importPrompt: importPrompt,
    importImagePrompt: importImagePrompt,
    planPrompt: planPrompt,
    editPrompt: editPrompt,
    chatSystem: chatSystem,
    snapshot: snapshot,
    shareData: function () { return cfg.shareData !== false; },
    hhmm: hhmm,
    addDays: addDays,
    mondayOf: mondayOf,
    errText: errText,
    lastRaw: function () { return lastRawText; },
    /* Test seam, not for production use. */
    _stub: function (fn) { responder = fn; },
    _cfgKey: CFG_KEY
  };

  function errText(e) {
    var kind = (e && e.aiKind) || 'network';
    var zh = lang() !== 'en';
    var m = (e && e.message) || '';
    /* A 400 from a text-only model when we sent an image_url: the endpoint
       accepts text content only. Translate the cryptic body into a fix. */
    if (kind === 'http' && /content\.type|image_url|取值范围|only.*text|does not support .*image/i.test(m)) {
      return zh
        ? '你的模型不支持图片识别：该接口只接受文本、不接收图片（HTTP 400）。请换用支持读图的模型——智谱 GLM-4V、Gemini 2.5 Flash、GPT-4o、OpenRouter 视觉模型，或在 SiliconFlow 选视觉模型（如 deepseek-ai/deepseek-vl2）。'
        : 'Your model cannot read images: this endpoint accepts text only, not images (HTTP 400). Use a vision model — Zhipu GLM-4V, Gemini 2.5 Flash, GPT-4o, an OpenRouter vision model, or a SiliconFlow VL model (e.g. deepseek-ai/deepseek-vl2).';
    }
    var map = {
      auth: zh ? '密钥无效或没有权限（401/403）' : 'Key rejected (401/403)',
      model: zh ? '模型名不存在，或该接口没有这个模型' : 'Model not found',
      timeout: zh ? '请求超时：可在 AI 设置里调高「超时（秒）」，或换更快的模型（如 Groq）' : 'Request timed out: raise the timeout in AI settings, or use a faster model (e.g. Groq)',
      network: zh ? '连不上接口：检查网络、地址，或该服务是否允许浏览器直连（CORS）' : 'Cannot reach the endpoint (network or CORS)',
      shape: zh ? '模型没有返回可用的 JSON' : 'Model did not return usable JSON',
      api: zh ? '接口返回了错误（不是 JSON 解析问题）' : 'The API returned an error (not a parse issue)',
      config: zh ? '还没填接口地址' : 'No endpoint configured'
    };
    var base = map[kind] || map.network;
    if (kind === 'shape' && e && e.raw != null) {
      var empty = !String(e.raw).trim();
      if (empty) {
        base += zh ? '（接口返回了空内容——多为限流/余额不足/该模型未授权，或响应格式不兼容）'
                   : ' (empty response — usually rate-limit, no quota, or incompatible format)';
      } else {
        var r = String(e.raw).trim().slice(0, 280);
        base += (zh ? '（接口原始返回：' : ' (raw response: ') + r + (zh ? '）' : ')');
      }
    }
    var extra = (e && e.message && (kind === 'http' || kind === 'api')) ? e.message : '';
    return extra ? base + ' — ' + extra : base;
  }
})();
