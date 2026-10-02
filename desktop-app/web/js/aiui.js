/* AI panel UI.
 *
 * The chat tab is the front door: a normal conversation, no forms. The other
 * tabs are the three pipelines -- collect input -> ask the model -> show a
 * diff -> write only what the user ticks. The diff step is the point of those
 * features; an import that silently wrote twelve guessed events would be worse
 * than typing them by hand.
 *
 * Chat deliberately cannot write to the calendar yet. Keeping writing behind
 * a reviewed diff means one bad model reply can never scramble a schedule.
 *
 * The settings tab exists because there is no key to ship with a static page:
 * the user supplies their own, and it is kept out of Store.settings (which is
 * what cloud sync uploads).
 */
(function () {
  'use strict';

  var state = {
    tab: 'chat',
    busy: false,
    preview: null,      /* { kind:'events'|'ops', items:[ {on, ...} ] } */
    images: [],         /* data URLs, already downscaled */
    msgs: []            /* chat: [ {role:'user'|'assistant', text:'', bad:bool} ] */
  };

  /* The page node. It is authored in index.html outside #view and moved into
     #view while the AI view is active, so re-rendering the view does not
     rebuild the body (and does not lose a half-typed message). */
  var PAGE = null;

  /* How much of the conversation is replayed to the model. Older turns are
     dropped from the request but stay on screen -- cheap, and long enough
     that "把它挪到周五" still has its antecedent. */
  var CHAT_MEMORY = 16;

  function $(id) { return document.getElementById(id); }
  function t(k) { return window.t ? window.t(k) : k; }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function hhmm(m) { return window.AI ? AI.hhmm(m) : ''; }

  /* ------------------------------------------------------------- shell -- */
  /* v31: the AI page is a view. Mounting means moving the node into #view;
     leaving it means handing the view back to the router. */
  function mount(el) {
    if (!PAGE) PAGE = $('aiView');
    if (!PAGE) return;
    el.innerHTML = '';
    el.appendChild(PAGE);
    PAGE.hidden = false;
    seedBrief();
    render();
  }

  /* Opened with an empty conversation, the assistant greets with the day.
     It costs nothing (no request), so it may appear every single time. */
  function seedBrief() {
    if (!state.msgs.length && !state.preview && AI.shareData()) {
      var b = dailyBrief();
      if (b) state.msgs.push({ role: 'assistant', text: b, brief: true });
    }
  }

  function open(tab) {
    if (!window.AI) return;
    state.tab = tab || (AI.ready() ? 'chat' : 'key');
    state.preview = null;
    if (window.App && App.go) App.go('ai');
    else render();
  }

  function close() {
    state.preview = null;
    if (window.App && App.closeAI) { App.closeAI(); return; }
    render();
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
    if (state.tab === 'chat') return t('ai.send');
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
      { k: 'chat', label: t('ai.tab.chat') },
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
    if (state.tab === 'chat') body.innerHTML = viewChat();
    else if (state.tab === 'import') body.innerHTML = viewImport();
    else if (state.tab === 'plan') body.innerHTML = viewPlan();
    else if (state.tab === 'edit') body.innerHTML = viewEdit();
    else body.innerHTML = viewKey();
    if (state.preview) {
      body.insertAdjacentHTML('beforeend', viewPreview());
    }
    $('aiTitle').textContent = state.tab === 'chat' ? assistantName() : t('ai.title');
    busy(false);
    bindTab();
    if (state.tab === 'chat') scrollChat();
  }

  /* -------------------------------------------------------------- chat -- */
  function assistantName() {
    var n = (AI.cfg().assistantName || '').trim();
    return n || '小安';
  }

  function viewChat() {
    var log = state.msgs.map(function (m) {
      var who = m.role === 'user' ? 'me' : 'ai';
      var ask = m.brief
        ? '<div class="ai-brief-ask"><button class="mini-btn" id="aiBriefAsk">' +
          esc(t('ai.briefAsk')) + '</button></div>'
        : '';
      return '<div class="ai-msg ' + who + '">' +
        '<div class="ai-who">' + esc(m.role === 'user' ? t('ai.me') : assistantName()) + '</div>' +
        '<div class="ai-bubble' + (m.bad ? ' bad' : '') + '">' + esc(m.text) + '</div>' + ask + '</div>';
    }).join('');
    var empty = state.msgs.length ? ''
      : '<div class="ai-note">' + esc(t('ai.chatHello')).replace('{name}', esc(assistantName())) + '</div>';
    var hint = AI.shareData() ? t('ai.chatHint') : t('ai.chatHintOff');
    return '<div class="ai-chat-head">' +
      '<span class="ev-meta grow">' + esc(hint) + '</span>' +
      '<button class="mini-btn" id="aiChatClear">' + esc(t('ai.clear')) + '</button></div>' +
      '<div class="ai-chat" id="aiChatLog">' + empty + log + '</div>' +
      '<textarea id="aiChatIn" class="ai-chat-in" rows="2" placeholder="' +
      esc(t('ai.sendPh')) + '"></textarea>';
  }

  function scrollChat() {
    var log = $('aiChatLog');
    if (log) log.scrollTop = log.scrollHeight;
  }

  function bindChat() {
    var ta = $('aiChatIn');
    if (ta) ta.addEventListener('keydown', function (ev) {
      if (ev.key === 'Enter' && !ev.shiftKey) { ev.preventDefault(); sendChat(); }
    });
    var clr = $('aiChatClear');
    if (clr) clr.addEventListener('click', function () {
      state.msgs = [];
      state.preview = null;
      status('');
      seedBrief();
      render();
    });
    var ask = $('aiBriefAsk');
    if (ask) ask.addEventListener('click', function () {
      var ta = $('aiChatIn');
      if (ta) ta.value = t('ai.briefAskQ');
      sendChat();
    });
  }

  /* ------------------------------------------------------------ brief --- */
  /* A local, zero-token morning brief: everything it says already lives in
     Store, so it appears instantly and works offline. The model is optional
     and opt-in ("让小安说说") -- a daily auto-summary that billed a request
     every time the view opened would be a tax, not a feature. */
  function dailyBrief() {
    if (!window.Store || !window.AI) return '';
    var zh = !(window.lang && window.lang() === 'en');
    var today = Store.todayStr();
    var list = Store.expandedEventsOn(today) || [];
    var L = [];

    L.push((zh ? '今天是 ' : 'Today is ') + today + '（' + AI.wdOf(today, zh) + '）。');
    if (!list.length) L.push(zh ? '今天还没有安排。' : 'Nothing on the calendar today.');
    else {
      L.push((zh ? '共 ' : '') + list.length + (zh ? ' 项安排：' : ' events: '));
      list.slice(0, 8).forEach(function (e) {
        L.push('· ' + hhmm(e.start || 0) + ' ' + (e.title || t('gen.untitled')) +
          (e.done ? (zh ? '（已完成）' : ' (done)') : ''));
      });
      if (list.length > 8) L.push(zh ? '…还有 ' + (list.length - 8) + ' 项' : '…' + (list.length - 8) + ' more');
    }

    /* Overlaps, counted the same way the digest marks them. */
    var clashes = 0, prevEnd = -1;
    list.forEach(function (e) {
      var st = e.start || 0;
      if (prevEnd > st) clashes++;
      var fin = e.end != null ? e.end : st + 60;
      if (fin > prevEnd) prevEnd = fin;
    });
    if (clashes) L.push(zh ? '⚠ 有 ' + clashes + ' 处时间重叠。' : '⚠ ' + clashes + ' overlapping slot(s).');

    /* Tasks due today or earlier -- the things that will actually bite. */
    var tasks = Store.tasks || [];
    var overdue = tasks.filter(function (x) { return !x.done && x.due && x.due < today; });
    var dueToday = tasks.filter(function (x) { return !x.done && x.due === today; });
    var openN = tasks.filter(function (x) { return !x.done; }).length;
    if (overdue.length) L.push((zh ? '⚠ ' : '⚠ ') + overdue.length +
      (zh ? ' 个待办已过期：' : ' overdue: ') +
      overdue.slice(0, 3).map(function (x) { return x.text; }).join('、'));
    if (dueToday.length) L.push(dueToday.length + (zh ? ' 个待办今天到期。' : ' due today.'));
    if (openN && !overdue.length && !dueToday.length) {
      L.push(openN + (zh ? ' 个待办待处理。' : ' open task(s).'));
    }

    var y = Store.focusOn(AI.addDays(today, -1)) || 0;
    if (y) L.push((zh ? '昨天专注 ' : 'Focus yesterday: ') + y + (zh ? ' 分钟。' : ' min.'));

    L.push(zh ? '想让我帮你排一排，就直接说。' : 'Tell me if you want me to rearrange anything.');
    return L.join('\n');
  }

  /* ------------------------------------------------------- ops in chat -- */
  /* A model reply may carry a proposed edit: prose plus a JSON ops block. It
     is only ever a proposal -- the ops go through the same reviewed diff as
     the Edit tab, and nothing is written until the user ticks and applies. */
  function sendChat() {
    if (state.busy) return;
    var ta = $('aiChatIn');
    var text = (ta && ta.value || '').trim();
    if (!text) { status(t('ai.needInput'), true); return; }
    if (!AI.ready()) { state.tab = 'key'; render(); status(t('ai.needKey'), true); return; }

    state.msgs.push({ role: 'user', text: text });
    if (ta) ta.value = '';
    render();
    busy(true, t('ai.thinking'));

    /* The digest is rebuilt per send, never appended to state.msgs: it must
       reflect edits made since the last turn, but it must not accumulate in
       the history we replay (that would multiply its cost every turn). It is
       also cropped to the question -- "今天下午有空吗" should not pay for a
       fortnight of one-off events. */
    var today = window.Store ? Store.todayStr() : new Date().toISOString().slice(0, 10);
    var share = AI.shareData();
    var ctx = share ? AI.snapshot({ query: text }) : '';
    var msgs = [{ role: 'system', content: AI.chatSystem(assistantName(), today, ctx, share) }];
    var tail = state.msgs.slice(-CHAT_MEMORY);
    for (var i = 0; i < tail.length; i++) {
      msgs.push({ role: tail[i].role === 'user' ? 'user' : 'assistant', content: tail[i].text });
    }

    AI.chat(msgs, { temperature: 0.5 }).then(function (reply) {
      var raw = String(reply == null ? '' : reply);
      var txt = raw.trim();
      var pulled = share ? AI.opsFromReply(raw, AI.contextIds(AI.contextEvents(30))) : null;
      if (pulled) {
        state.preview = {
          kind: 'ops',
          items: pulled.items.map(function (o) { o.on = true; return o; }),
          bad: pulled.bad,
          notes: ''
        };
        /* The bubble keeps the prose; the JSON block is machinery. */
        txt = pulled.reply || txt;
      }
      state.msgs.push({ role: 'assistant', text: txt || t('ai.emptyReply') });
      render();
      status(state.preview ? t('ai.checkList') : '');
    }).catch(function (e) {
      state.msgs.push({ role: 'assistant', text: AI.errText(e), bad: true });
      render();
      status(AI.errText(e), true);
    });
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
      '<div class="ai-note" style="margin-top:8px">' + esc(t('ai.visionHint')) + '</div>' +
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
      '<div class="field"><label>' + esc(t('ai.name')) + '</label>' +
      '<input id="aiName" value="' + esc(assistantName()) + '" placeholder="' + esc(t('ai.namePh')) + '"></div>' +
      '<div class="field"><label>' + esc(t('ai.timeout')) + '</label>' +
      '<input id="aiTimeout" type="number" min="10" step="10" value="' + Math.round((c.timeoutMs || 180000) / 1000) + '" placeholder="180"> 秒</div>' +
      '<label class="ai-check"><input type="checkbox" id="aiVision"' + (c.vision ? ' checked' : '') + '> ' +
      esc(t('ai.vision')) + '</label>' +
      '<label class="ai-check"><input type="checkbox" id="aiShare"' + (c.shareData !== false ? ' checked' : '') + '> ' +
      esc(t('ai.share')) + '</label>' +
      '<div class="ai-note">' + esc(t('ai.shareHint')) + '</div>' +
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
    if (state.tab === 'chat') {
      bindChat();
    } else if (state.tab === 'import') {
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
    if (state.tab === 'chat') sendChat();
    else if (state.tab === 'import') runImport();
    else if (state.tab === 'plan') runPlan();
    else runEdit();
  }

  function saveKey() {
    AI.setCfg({
      baseUrl: ($('aiBase').value || '').trim(),
      model: ($('aiModel').value || '').trim(),
      apiKey: ($('aiKey').value || '').trim(),
      vision: !!$('aiVision').checked,
      shareData: !$('aiShare') || $('aiShare').checked,
      assistantName: ($('aiName') && $('aiName').value || '').trim() || assistantName(),
      timeoutMs: (function () { var v = parseInt($('aiTimeout').value, 10); return (v >= 10 ? v : 180) * 1000; })()
    });
    status(t('ai.saved'));
    if (window.App && App.render) App.render();
  }

  function testConn() {
    saveKey();
    if (!AI.ready()) { status(t('ai.needKey'), true); return; }
    busy(true, t('ai.testing'));
    AI.chat([{ role: 'user', content: 'ping' }], { temperature: 0 })
      .then(function (txt) { busy(false); status(t('ai.ok') + (txt ? ' · ' + String(txt).slice(0, 120) : '')); })
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
    /* In chat the user asked here, so the answer belongs here: drop the diff,
       confirm inline, and stay in the conversation. */
    if (state.tab === 'chat') {
      state.preview = null;
      state.msgs.push({ role: 'assistant', text: t('ai.appliedN').replace('{n}', String(n)) });
      render();
    } else {
      close();
    }
    if (window.App && App.toast) App.toast(t('ai.written') + ' ' + n + ' — ' + t('ai.canUndo'));
  }

  /* -------------------------------------------------------------- wiring */
  function bind() {
    if (!PAGE) PAGE = $('aiView');
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

  /* The router (app.js) renders Views.ai into #view like any other view. */
  if (window.Views) Views.ai = mount;

  window.AIUI = {
    open: open,
    close: close,
    isOpen: function () {
      var v = document.getElementById('view');
      return !!v && v.dataset.view === 'ai';
    },
    bind: bind,
    /* QA hook: ?ai=1 opens the panel straight away. */
    state: state
  };
})();
