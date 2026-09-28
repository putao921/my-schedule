/* AI panel UI.
 *
 * Three tabs, one pipeline: collect input -> ask the model -> show a diff ->
 * write only what the user ticks. The diff step is the point of the whole
 * feature; an import that silently wrote twelve guessed events would be worse
 * than typing them by hand.
 *
 * The settings tab exists because there is no key to ship with a static page:
 * the user supplies their own, and it is kept out of Store.settings (which is
 * what cloud sync uploads).
 */
(function () {
  'use strict';

  var state = {
    tab: 'import',
    busy: false,
    preview: null,      /* { kind:'events'|'ops', items:[ {on, ...} ] } */
    images: [],         /* data URLs, already downscaled */
    inHistory: false
  };

  function $(id) { return document.getElementById(id); }
  function t(k) { return window.t ? window.t(k) : k; }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function hhmm(m) { return window.AI ? AI.hhmm(m) : ''; }

  /* ------------------------------------------------------------- shell -- */
  function open(tab) {
    if (!window.AI) return;
    state.tab = tab || (AI.ready() ? 'import' : 'key');
    state.preview = null;
    if (!state.inHistory) {
      try { history.pushState({ ai: 1 }, ''); } catch (e) { }
      state.inHistory = true;
    }
    $('aiMask').hidden = false;
    $('aiSheet').hidden = false;
    render();
  }

  function close(fromPop) {
    if ($('aiSheet').hidden) return;
    $('aiSheet').hidden = true;
    $('aiMask').hidden = true;
    state.preview = null;
    if (state.inHistory && !fromPop) {
      state.inHistory = false;
      try { history.back(); } catch (e) { }
    }
    state.inHistory = false;
  }

  function status(msg, bad) {
    var el = $('aiStatus');
    if (!el) return;
    el.textContent = msg || '';
    el.className = 'ai-status' + (bad ? ' bad' : '');
  }

  function busy(on, msg) {
    state.busy = !!on;
    var go = $('aiGo');
    if (go) { go.disabled = !!on; go.textContent = on ? (msg || t('ai.working')) : goLabel(); }
    var mask = $('aiBody');
    if (mask) mask.setAttribute('aria-busy', on ? 'true' : 'false');
  }

  function goLabel() {
    if (state.preview) {
      var n = countOn();
      return n ? t('ai.writeN') + ' (' + n + ')' : t('ai.writeNone');
    }
    if (state.tab === 'key') return t('ai.save');
    if (state.tab === 'plan') return t('ai.genPlan');
    if (state.tab === 'edit') return t('ai.genEdit');
    return t('ai.extract');
  }

  function countOn() {
    var n = 0;
    var items = (state.preview && state.preview.items) || [];
    for (var i = 0; i < items.length; i++) if (items[i].on) n++;
    return n;
  }

  /* -------------------------------------------------------------- tabs -- */
  function render() {
    var tabs = [
      { k: 'import', label: t('ai.tab.import') },
      { k: 'plan', label: t('ai.tab.plan') },
      { k: 'edit', label: t('ai.tab.edit') },
      { k: 'key', label: t('ai.tab.key') }
    ];
    $('aiTabs').innerHTML = tabs.map(function (x) {
      return '<button class="ai-tab' + (state.tab === x.k ? ' on' : '') +
        '" data-aitab="' + x.k + '">' + esc(x.label) + '</button>';
    }).join('');
    var body = $('aiBody');
    if (state.tab === 'import') body.innerHTML = viewImport();
    else if (state.tab === 'plan') body.innerHTML = viewPlan();
    else if (state.tab === 'edit') body.innerHTML = viewEdit();
    else body.innerHTML = viewKey();
    if (state.preview) {
      body.insertAdjacentHTML('beforeend', viewPreview());
    }
    $('aiTitle').textContent = t('ai.title');
    busy(false);
    bindTab();
  }

  function viewImport() {
    var imgs = state.images.map(function (src, i) {
      return '<div class="ai-thumb"><img alt="" src="' + esc(src) + '">' +
        '<button class="ai-thumb-x" data-aimg="' + i + '" aria-label="remove">×</button></div>';
    }).join('');
    return '<div class="field"><label>' + esc(t('ai.paste')) + '</label>' +
      '<textarea id="aiText" rows="6" placeholder="' + esc(t('ai.pastePh')) + '"></textarea></div>' +
      '<div class="ai-imgs" id="aiImgs">' + imgs + '</div>' +
      '<div class="card-row" style="flex-wrap:wrap;gap:8px;margin-top:8px">' +
      '<button class="btn" id="aiPickImg">' + esc(t('ai.pickImg')) + '</button>' +
      '<span class="ev-meta">' + esc(t('ai.pasteImgHint')) + '</span></div>' +
      '<input type="file" id="aiFile" accept="image/*" multiple hidden>';
  }

  function viewPlan() {
    var due = defaultDue();
    return '<div class="field"><label>' + esc(t('ai.goal')) + '</label>' +
      '<textarea id="aiGoal" rows="3" placeholder="' + esc(t('ai.goalPh')) + '"></textarea></div>' +
      '<div class="row2">' +
      '<div class="field"><label>' + esc(t('ai.due')) + '</label>' +
      '<input type="date" id="aiDue" value="' + esc(due) + '"></div>' +
      '<div class="field"><label>' + esc(t('ai.hours')) + '</label>' +
      '<input type="number" id="aiHours" min="1" max="60" value="10"></div>' +
      '</div>' +
      '<div class="row2">' +
      '<div class="field"><label>' + esc(t('ai.maxDay')) + '</label>' +
      '<input type="number" id="aiMaxDay" min="30" max="600" step="15" value="180"></div>' +
      '<div class="field"><label>' + esc(t('ai.prefer')) + '</label>' +
      '<select id="aiPrefer">' +
      '<option value="any">' + esc(t('ai.preferAny')) + '</option>' +
      '<option value="am">' + esc(t('ai.preferAm')) + '</option>' +
      '<option value="pm">' + esc(t('ai.preferPm')) + '</option>' +
      '<option value="night">' + esc(t('ai.preferNight')) + '</option>' +
      '</select></div>' +
      '</div>' +
      '<div class="ev-meta">' + esc(t('ai.planHint')) + '</div>';
  }

  function viewEdit() {
    return '<div class="field"><label>' + esc(t('ai.cmd')) + '</label>' +
      '<textarea id="aiCmd" rows="3" placeholder="' + esc(t('ai.cmdPh')) + '"></textarea></div>' +
      '<div class="field"><label>' + esc(t('ai.range')) + '</label>' +
      '<select id="aiRange">' +
      '<option value="7">' + esc(t('ai.range7')) + '</option>' +
      '<option value="14">' + esc(t('ai.range14')) + '</option>' +
      '<option value="30">' + esc(t('ai.range30')) + '</option>' +
      '</select></div>' +
      '<div class="ev-meta">' + esc(t('ai.editHint')) + '</div>';
  }

  function viewKey() {
    var c = AI.cfg();
    var opts = AI.PRESETS.map(function (p, i) {
      return '<option value="' + i + '">' + esc(p.name) + ' — ' + esc(p.model) + '</option>';
    }).join('');
    return '<div class="ai-note">' + esc(t('ai.keyNote')) + '</div>' +
      '<div class="field"><label>' + esc(t('ai.vendor')) + '</label>' +
      '<select id="aiPreset"><option value="">' + esc(t('ai.vendorPick')) + '</option>' + opts + '</select></div>' +
      '<div class="field"><label>' + esc(t('ai.base')) + '</label>' +
      '<input id="aiBase" value="' + esc(c.baseUrl) + '" placeholder="https://api.openai.com/v1"></div>' +
      '<div class="field"><label>' + esc(t('ai.model')) + '</label>' +
      '<input id="aiModel" value="' + esc(c.model) + '"></div>' +
      '<div class="field"><label>' + esc(t('ai.key')) + '</label>' +
      '<input id="aiKey" type="password" value="' + esc(c.apiKey) + '" placeholder="sk-..."></div>' +
      '<label class="ai-check"><input type="checkbox" id="aiVision"' + (c.vision ? ' checked' : '') + '> ' +
      esc(t('ai.vision')) + '</label>' +
      '<div class="card-row" style="margin-top:8px"><button class="btn" id="aiTest">' +
      esc(t('ai.test')) + '</button></div>';
  }

  function defaultDue() {
    var d = new Date();
    d.setDate(d.getDate() + 56);
    return window.Store ? Store.iso(d) : '';
  }

  /* ----------------------------------------------------------- preview -- */
  function viewPreview() {
    var p = state.preview;
    var rows = p.items.map(function (it, i) {
      var warn = '';
      if (it.kind === 'ops') {
        var b = it.before, a = it.after;
        var head = '<b>' + esc(b.title) + '</b>';
        var from = b.date + ' ' + hhmm(b.start) + '-' + hhmm(b.end);
        var to;
        if (it.op === 'delete') to = t('ai.opDelete');
        else if (it.op === 'done') to = t('ai.opDone');
        else to = (a.date || b.date) + ' ' + hhmm(a.start != null ? a.start : b.start) + '-' +
          hhmm(a.end != null ? a.end : b.end);
        return '<label class="ai-item"><input type="checkbox" data-aip="' + i + '"' +
          (it.on ? ' checked' : '') + '><span class="grow">' +
          '<div class="ai-t">' + head + '<span class="ai-op">' + esc(opName(it.op)) + '</span></div>' +
          '<div class="ai-m"><s>' + esc(from) + '</s> → ' + esc(to) + '</div>' +
          '</span></label>';
      }
      if (it.conflict) {
        warn = '<div class="ai-warn">' + esc(t('ai.overlap')) + ' ' + esc(it.conflict) + '</div>';
      }
      return '<label class="ai-item"><input type="checkbox" data-aip="' + i + '"' +
        (it.on ? ' checked' : '') + '><span class="grow">' +
        '<div class="ai-t"><b>' + esc(it.title) + '</b>' +
        (it.repeat && it.repeat !== 'none' ? '<span class="ai-op">' + esc(repeatName(it.repeat)) + '</span>' : '') +
        '</div>' +
        '<div class="ai-m">' + esc(it.date) + ' ' + hhmm(it.start) + '-' + hhmm(it.end) +
        (it.tag ? ' · ' + esc(it.tag) : '') + '</div>' +
        (it.note ? '<div class="ai-m">' + esc(it.note) + '</div>' : '') +
        warn + '</span></label>';
    }).join('');

    var bad = '';
    if (p.bad && p.bad.length) {
      bad = '<div class="ai-bad">' + esc(t('ai.dropped')) + ' ' + p.bad.length + ' — ' +
        esc(p.bad.slice(0, 4).map(function (x) { return x.title || x.why; }).join('、')) + '</div>';
    }
    var note = p.notes ? '<div class="ai-note">' + esc(p.notes) + '</div>' : '';
    return '<div class="ai-prev">' +
      '<div class="ai-prev-head"><span class="grow"><b>' + esc(t('ai.preview')) + '</b> ' +
      p.items.length + '</span>' +
      '<button class="mini-btn" id="aiAll">' + esc(t('ai.all')) + '</button>' +
      '<button class="mini-btn" id="aiNone">' + esc(t('ai.none')) + '</button></div>' +
      note + bad + rows + '</div>';
  }

  function opName(op) {
    var map = { move: t('ai.opMove'), update: t('ai.opUpdate'), delete: t('ai.opDelete'), done: t('ai.opDone') };
    return map[op] || op;
  }
  function repeatName(r) {
    var map = { daily: t('opt.rep.daily'), weekly: t('opt.rep.weekly'), monthly: t('opt.rep.monthly'), yearly: t('opt.rep.yearly') };
    return map[r] || r;
  }

  /* ------------------------------------------------------------- input -- */
  function bindTab() {
    var body = $('aiBody');
    if (state.tab === 'import') {
      var file = $('aiFile');
      if (file) file.addEventListener('change', function () { addFiles(file.files); });
      var pick = $('aiPickImg');
      if (pick) pick.addEventListener('click', function () { file.click(); });
      var ta = $('aiText');
      if (ta) ta.addEventListener('paste', function (ev) {
        var items = ev.clipboardData && ev.clipboardData.items;
        if (!items) return;
        var found = false;
        for (var i = 0; i < items.length; i++) {
          if (items[i].type && items[i].type.indexOf('image') === 0) {
            var f = items[i].getAsFile();
            if (f) { addFiles([f]); found = true; }
          }
        }
        /* Text pastes fall through to the textarea; only images are ours. */
        if (found) ev.preventDefault();
      });
    } else if (state.tab === 'key') {
      var pre = $('aiPreset');
      if (pre) pre.addEventListener('change', function () {
        var p = AI.PRESETS[parseInt(pre.value, 10)];
        if (!p) return;
        $('aiBase').value = p.baseUrl;
        $('aiModel').value = p.model;
        $('aiVision').checked = !!p.vision;
      });
      var testBtn = $('aiTest');
      if (testBtn) testBtn.addEventListener('click', testConn);
    }
    var all = $('aiAll'), none = $('aiNone');
    if (all) all.addEventListener('click', function () { setAll(true); });
    if (none) none.addEventListener('click', function () { setAll(false); });
    Array.prototype.forEach.call(body.querySelectorAll('[data-aip]'), function (cb) {
      cb.addEventListener('change', function () {
        var i = parseInt(cb.dataset.aip, 10);
        if (state.preview && state.preview.items[i]) state.preview.items[i].on = cb.checked;
        busy(false);
      });
    });
    Array.prototype.forEach.call(body.querySelectorAll('[data-aimg]'), function (btn) {
      btn.addEventListener('click', function () {
        state.images.splice(parseInt(btn.dataset.aimg, 10), 1);
        render();
      });
    });
  }

  function setAll(on) {
    if (!state.preview) return;
    for (var i = 0; i < state.preview.items.length; i++) state.preview.items[i].on = on;
    Array.prototype.forEach.call($('aiBody').querySelectorAll('[data-aip]'), function (cb) { cb.checked = on; });
    busy(false);
  }

  /* Screenshots are far larger than a model needs and every pixel costs
     tokens; 1280px and JPEG 0.8 is still perfectly readable for a timetable. */
  function addFiles(files) {
    var list = Array.prototype.slice.call(files || []);
    if (!list.length) return;
    var pending = list.length;
    list.forEach(function (f) {
      if (!/^image\//.test(f.type)) { if (--pending === 0) render(); return; }
      shrink(f).then(function (url) {
        state.images.push(url);
        if (--pending === 0) render();
      }).catch(function () { if (--pending === 0) render(); });
    });
  }

  function shrink(file) {
    return new Promise(function (res, rej) {
      var fr = new FileReader();
      fr.onload = function () {
        var img = new Image();
        img.onload = function () {
          var max = 1280;
          var scale = Math.min(1, max / Math.max(img.width, img.height));
          var w = Math.round(img.width * scale), h = Math.round(img.height * scale);
          try {
            var cv = document.createElement('canvas');
            cv.width = w; cv.height = h;
            cv.getContext('2d').drawImage(img, 0, 0, w, h);
            res(cv.toDataURL('image/jpeg', 0.8));
          } catch (e) { res(String(fr.result)); }
        };
        img.onerror = function () { rej(new Error('decode')); };
        img.src = String(fr.result);
      };
      fr.onerror = function () { rej(new Error('read')); };
      fr.readAsDataURL(file);
    });
  }

  /* -------------------------------------------------------------- runs -- */
  function go() {
    if (state.busy) return;
    if (state.preview) { write(); return; }
    if (state.tab === 'key') { saveKey(); return; }
    if (!AI.ready()) { state.tab = 'key'; render(); status(t('ai.needKey'), true); return; }
    if (state.tab === 'import') runImport();
    else if (state.tab === 'plan') runPlan();
    else runEdit();
  }

  function saveKey() {
    AI.setCfg({
      baseUrl: ($('aiBase').value || '').trim(),
      model: ($('aiModel').value || '').trim(),
      apiKey: ($('aiKey').value || '').trim(),
      vision: !!$('aiVision').checked
    });
    status(t('ai.saved'));
    if (window.App && App.render) App.render();
  }

  function testConn() {
    saveKey();
    if (!AI.ready()) { status(t('ai.needKey'), true); return; }
    busy(true, t('ai.testing'));
    AI.chat([{ role: 'user', content: 'ping' }], { temperature: 0 })
      .then(function () { busy(false); status(t('ai.ok')); })
      .catch(function (e) { busy(false); status(AI.errText(e), true); });
  }

  function runImport() {
    var text = ($('aiText') && $('aiText').value || '').trim();
    if (!text && !state.images.length) { status(t('ai.needInput'), true); return; }
    if (state.images.length && !AI.cfg().vision) { status(t('ai.noVision'), true); return; }
    busy(true, t('ai.reading'));
    var year = new Date().getFullYear();
    var msgs = state.images.length
      ? AI.importImagePrompt(text, state.images, year)
      : AI.importPrompt(text, year);
    AI.askJSON(msgs).then(function (obj) {
      var norm = AI.normalizeEvents(obj.events || obj.items || []);
      var items = norm.ok.map(function (e) {
        e.on = true;
        e.conflict = AI.conflictOf(e);
        return e;
      });
      if (!items.length && norm.bad.length) {
        status(t('ai.allBad') + ' ' + norm.bad[0].why, true);
        busy(false);
        return;
      }
      state.preview = { kind: 'events', items: items, bad: norm.bad, notes: obj.notes || '' };
      render();
      status(t('ai.checkList'));
    }).catch(function (e) { busy(false); status(AI.errText(e), true); });
  }

  function runPlan() {
    var goal = ($('aiGoal') && $('aiGoal').value || '').trim();
    if (!goal) { status(t('ai.needGoal'), true); return; }
    var due = ($('aiDue') && $('aiDue').value) || defaultDue();
    var hours = parseInt(($('aiHours') && $('aiHours').value), 10) || 10;
    var maxDay = parseInt(($('aiMaxDay') && $('aiMaxDay').value), 10) || 180;
    var prefer = ($('aiPrefer') && $('aiPrefer').value) || 'any';
    var weeks = Math.max(1, Math.round((Store.parseISO(due) - Store.parseISO(Store.todayStr())) / 604800000));

    busy(true, t('ai.planning'));
    AI.askJSON(AI.planPrompt(goal, { due: due, weeks: weeks, hours: hours })).then(function (obj) {
      var tasks = obj.tasks || [];
      if (!tasks.length) { busy(false); status(t('ai.allBad'), true); return; }
      var fit = AI.assign(tasks, {
        startDate: Store.todayStr(),
        weeks: weeks,
        maxPerDayMin: maxDay,
        prefer: prefer
      });
      var items = fit.events.map(function (e) {
        e.on = true;
        e.conflict = AI.conflictOf(e);
        return e;
      });
      state.preview = {
        kind: 'events', items: items,
        bad: fit.unplaced.map(function (u) { return { why: 'noSlot', title: u.title }; }),
        notes: obj.notes || ''
      };
      render();
      status(t('ai.checkList'));
    }).catch(function (e) { busy(false); status(AI.errText(e), true); });
  }

  function runEdit() {
    var cmd = ($('aiCmd') && $('aiCmd').value || '').trim();
    if (!cmd) { status(t('ai.needCmd'), true); return; }
    var days = parseInt(($('aiRange') && $('aiRange').value), 10) || 7;
    var ctx = AI.contextEvents(days);
    if (!ctx.length) { status(t('ai.noEvents'), true); return; }
    busy(true, t('ai.thinking'));
    AI.askJSON(AI.editPrompt(cmd, ctx)).then(function (obj) {
      var norm = AI.normalizeOps(obj.ops || [], AI.contextIds(ctx));
      if (!norm.ok.length) {
        busy(false);
        status(t('ai.noOps') + (norm.bad.length ? ' (' + norm.bad[0].why + ')' : ''), true);
        return;
      }
      var items = norm.ok.map(function (o) { o.on = true; return o; });
      state.preview = { kind: 'ops', items: items, bad: norm.bad, notes: obj.notes || '' };
      render();
      status(t('ai.checkList'));
    }).catch(function (e) { busy(false); status(AI.errText(e), true); });
  }

  function write() {
    var items = (state.preview && state.preview.items) || [];
    var picked = items.filter(function (x) { return x.on; });
    if (!picked.length) { status(t('ai.writeNone'), true); return; }
    var n = state.preview.kind === 'ops' ? AI.applyOps(picked) : AI.applyEvents(picked);
    if (window.App && App.render) App.render();
    status('');
    close();
    if (window.App && App.toast) App.toast(t('ai.written') + ' ' + n + ' — ' + t('ai.canUndo'));
  }

  /* -------------------------------------------------------------- wiring */
  function bind() {
    var mask = $('aiMask');
    mask.addEventListener('click', function () { close(); });
    $('aiClose').addEventListener('click', function () { close(); });
    $('aiCancel').addEventListener('click', function () { close(); });
    $('aiGo').addEventListener('click', go);
    $('aiTabs').addEventListener('click', function (ev) {
      var b = ev.target.closest ? ev.target.closest('[data-aitab]') : null;
      if (!b) return;
      state.tab = b.dataset.aitab;
      state.preview = null;
      status('');
      render();
    });
  }

  window.AIUI = {
    open: open,
    close: close,
    isOpen: function () { return !$('aiSheet').hidden; },
    bind: bind,
    /* QA hook: ?ai=1 opens the panel straight away. */
    state: state
  };
})();
