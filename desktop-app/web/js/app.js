/* App shell: routing, the editor sheet, toasts, import/export, SW registration. */
(function () {
  'use strict';

  var cursor = new Date();
  /* A settings file written by an older release can still name the AI page;
     a reload should open a schedule view, never the chat. */
  var current = Store.settings.view === 'ai' ? 'month' : (Store.settings.view || 'month');
  var $ = function (id) { return document.getElementById(id); };

  /* ------------------------------------------------------------- chrome -- */
  function applyTheme() {
    document.documentElement.setAttribute('data-theme', Store.settings.theme);
    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta) {
      meta.setAttribute('content',
        Store.settings.theme === 'night' ? '#1B1318' : '#EFD7D4');
    }
  }

  /* Text size: one custom property scales every size the stylesheet declares
     with calc(Npx * var(--fs)). Kept on <html> so overlays (sheet, toast,
     wheel) scale too. */
  function applyFont() {
    var s = parseFloat(Store.settings.fontScale);
    if (!s || s < 0.5 || s > 2) s = 1;
    document.documentElement.style.setProperty('--fs', String(s));
  }

  function applyLang() {
    document.documentElement.lang = Store.settings.lang;
    var map = {
      'nav.today': '.nav-btn[data-view="today"] .nav-txt',
      'nav.month': '.nav-btn[data-view="month"] .nav-txt',
      'nav.week': '.nav-btn[data-view="week"] .nav-txt',
      'nav.list': '.nav-btn[data-view="list"] .nav-txt',
      'nav.tasks': '.nav-btn[data-view="tasks"] .nav-txt',
      'nav.focus': '.nav-btn[data-view="focus"] .nav-txt',
      'nav.stats': '.nav-btn[data-view="stats"] .nav-txt',
      'nav.profile': '.nav-btn[data-view="me"] .nav-txt',
      'nav.sched': '.nav-btn[data-group="sched"] .nav-txt',
      'nav.focusGroup': '.nav-btn[data-group="focus"] .nav-txt',
      'nav.ai': '.nav-btn[data-view="ai"] .nav-txt',
      'search.toggle': '#searchToggleTxt'
    };
    Object.keys(map).forEach(function (k) {
      var el = document.querySelector(map[k]);
      if (el) el.textContent = t(k);
    });
    var ph = $('searchInput');
    if (ph) ph.setAttribute('placeholder', t('search.toggle'));
    /* Sub-bar chips are built from the same keys: rebuild them on a language
       switch so they read in the new language. */
    renderSub();
  }

  function refreshHero() {
    var now = new Date();
    var zh = window.lang() === 'zh';
    var dow = zh ? ['日', '一', '二', '三', '四', '五', '六'][now.getDay()]
      : ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][now.getDay()];
    $('heroDow').textContent = dow;
    $('heroDay').textContent = Store.iso(now);
    $('heroClock').textContent =
      ('0' + now.getHours()).slice(-2) + ':' + ('0' + now.getMinutes()).slice(-2);

    var st = Store.stats();
    var pct = st.total ? Math.round(st.done / st.total * 100) : 0;
    $('heroDoneLabel').textContent = fmt(t('hero.done'), st.done, st.total) + ' (' + pct + '%)';
    $('heroDoneBar').style.width = pct + '%';

    var fm = parseInt(Store.settings.focusTodayMin, 10) || 0;
    $('heroFocusLabel').textContent = fmt(t('hero.focus'), Math.floor(fm / 60), fm % 60);
  }

  /* ------------------------------------------------- merged nav groups --- */
  /* On phones 月/周/列表 collapse into 日程 and 专注/统计 into 专注 so the bottom
     bar holds five entries instead of eight. Opening a group lists its entries
     in the sub-bar at the top of the screen. Desktop shows all eight as usual. */
  var GROUPS = {
    sched: ['month', 'week', 'list'],
    focus: ['focus', 'stats']
  };
  var openGroup = null;

  function groupOf(view) {
    var keys = Object.keys(GROUPS);
    for (var i = 0; i < keys.length; i++) {
      if (GROUPS[keys[i]].indexOf(view) >= 0) return keys[i];
    }
    return null;
  }

  function renderSub() {
    var bar = $('subbar');
    if (!bar) return;
    if (!openGroup) { bar.hidden = true; bar.innerHTML = ''; return; }
    bar.hidden = false;
    bar.innerHTML = GROUPS[openGroup].map(function (v) {
      return '<button class="sub-chip' + (v === current ? ' is-on' : '') +
        '" data-view="' + v + '">' +
        '<span class="nav-ico" data-ico="' + v + '"></span>' +
        '<span class="nav-txt">' + t('nav.' + v) + '</span></button>';
    }).join('');
    Array.prototype.forEach.call(bar.querySelectorAll('.sub-chip'), function (c) {
      c.addEventListener('click', function () { go(c.dataset.view); });
    });
  }

  /* ------------------------------------------------------------- render -- */
  function render() {
    var el = $('view');
    var fn = Views[current] || Views.month;
    /* Views key off this for breakpoint-specific rules (e.g. the two-column
       task list on wide screens). */
    el.dataset.view = current;
    fn(el, cursor);
    Array.prototype.forEach.call(document.querySelectorAll('.nav-btn'), function (b) {
      /* Group buttons stand for several views: light up whenever the current
         view belongs to them. */
      var on = b.dataset.group
        ? groupOf(current) === b.dataset.group
        : b.dataset.view === current;
      b.classList.toggle('is-on', on);
    });
    renderSub();
    refreshHero();
    /* The + button means "new event here"; it has nothing to add on the AI
       page, where the footer button is the action. */
    var fc = $('fabCol');
    if (fc) fc.hidden = (current === 'ai');
    if (window.Focus) Focus.paint();
    if (window.CloudSync && CloudSync.refreshBadge) CloudSync.refreshBadge();
    syncUndoButtons();
  }

  /* The AI page is a view, with two deliberate exceptions: it is never
     persisted (a reload lands on the last schedule view, not on the chat),
     and it is pushed onto the browser history once, so Back -- the hardware
     key or the Android gesture -- returns to where the user came from. */
  var prevView = 'month';

  function openAI() {
    if (current !== 'ai') prevView = current;
    current = 'ai';
    openGroup = null;
    if (!history.state || !history.state.ai) {
      try { history.pushState({ ai: 1 }, ''); } catch (e) { }
    }
    render();
  }

  function closeAI() {
    if (current !== 'ai') return;
    current = prevView || 'month';
    /* Drop the entry we pushed. The popstate handler ignores this because
       current is no longer 'ai', so the view does not switch twice. */
    if (history.state && history.state.ai) {
      try { history.back(); } catch (e) { }
    }
    render();
  }

  function go(view) {
    if (view === 'ai') { openAI(); return; }
    current = view;
    /* 今日 / 任务 / 我的 are not merged: entering one closes the sub-bar. */
    if (!groupOf(view)) openGroup = null;
    /* Entering the month/week view lands on the period containing today;
       the calendar navigation then moves the cursor from there. */
    if (view === 'month' || view === 'week') cursor = new Date();
    Store.settings.view = view;
    Store.persistSettings();
    render();
  }

  /* Move the calendar cursor by one period in the current view: a week for the
     week view, a month for the month view. dir is -1 (prev) or +1 (next). */
  function moveCursor(dir) {
    if (current === 'week') {
      var ws = Store.startOfWeek(cursor || new Date());
      ws.setDate(ws.getDate() + dir * 7);
      cursor = ws;
    } else {
      var c = cursor || new Date();
      cursor = new Date(c.getFullYear(), c.getMonth() + dir, 1);
    }
    render();
  }

  /* -------------------------------------------------------------- toast -- */
  var toastTimer = null;
  function toast(msg) {
    var el = $('toast');
    el.textContent = msg;
    el.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.hidden = true; }, 2600);
  }

  /* -------------------------------------------------------------- sheet -- */
  var editing = null;   /* { kind:'event'|'task', id } */

  function openSheet(kind, id) {
    var baseId = (id && id.indexOf('@') > 0) ? id.split('@')[0] : id;
    editing = { kind: kind, id: baseId };
    var rec = null;
    if (baseId) rec = kind === 'event' ? Store.findEvent(baseId) : Store.findTask(baseId);

    $('sheetTitle').textContent = rec
      ? (kind === 'event' ? t('fld.ed.title') : t('fld.tk.title'))
      : (kind === 'event' ? t('fld.ed.new') : t('fld.tk.new'));
    $('sheetDelete').hidden = !rec;

    var body = '';
    if (kind === 'event') {
      body =
        field(t('fld.ed.titleF'), '<input id="fTitle" type="text" value="' + Views.esc(rec ? rec.title : '') + '">') +
        field(t('fld.ed.date'), '<input id="fDate" type="date" value="' + (rec ? rec.date : Store.iso(cursor)) + '">') +
        '<div class="field"><label>' + t('fld.ed.start') + ' / ' + t('fld.ed.end') + '</label>' +
        '<div style="display:flex;gap:8px">' +
        '<input id="fStart" type="time" value="' + Store.hhmm(rec ? rec.start : 9 * 60) + '">' +
        '<input id="fEnd" type="time" value="' + Store.hhmm(rec ? rec.end : 10 * 60) + '"></div></div>' +
        field(t('fld.ed.tag'), '<select id="fTag">' +
          (Views.tagNames ? Views.tagNames() : ['work', 'focus', 'life']).map(function (g) {
            return '<option value="' + Views.esc(g) + '"' + (rec && rec.tag === g ? ' selected' : '') + '>' +
              Views.esc(g) + '</option>';
          }).join('') + '</select>') +
        field(t('fld.ed.note'), '<textarea id="fNote">' + Views.esc(rec ? rec.note : '') + '</textarea>') +
        buildRepeat(rec);
    } else {
      body =
        field(t('fld.tk.text'), '<input id="fText" type="text" value="' + Views.esc(rec ? rec.text : '') + '">') +
        field(t('fld.tk.due'), '<input id="fDue" type="date" value="' + (rec && rec.due ? rec.due : '') + '">') +
        field(t('fld.tk.project'), '<input id="fProject" type="text" value="' + Views.esc(rec ? rec.project : 'Inbox') + '">') +
        field(t('fld.tk.priority'), '<select id="fPriority">' +
          ['low', 'medium', 'high'].map(function (p) {
            return '<option value="' + p + '"' + (rec && rec.priority === p ? ' selected' : '') + '>' + p + '</option>';
          }).join('') + '</select>');
    }
    $('sheetBody').innerHTML = body;
    var fr = $('fRepeat');
    if (fr) {
      var syncRepeat = function () {
        var ex = $('repeatExtra');
        if (ex) ex.style.display = (fr.value === 'none') ? 'none' : 'block';
        var mm = $('fRepeatMonthMode');
        if (mm && mm.parentNode) mm.parentNode.style.display =
          (fr.value === 'monthly' || fr.value === 'yearly') ? '' : 'none';
      };
      fr.addEventListener('change', syncRepeat);
      syncRepeat();
    }
    $('sheetMask').hidden = false;
    $('sheet').hidden = false;
    /* An entry is pushed so the phone's BACK key closes the sheet instead of
       leaving the app -- the complaint "the editor pops up and there is no
       way out" was exactly that. */
    if (!sheetInHistory) {
      history.pushState({ sheet: 1 }, '');
      sheetInHistory = true;
    }
  }

  function field(label, inner) {
    return '<div class="field"><label>' + label + '</label>' + inner + '</div>';
  }

  /* Repeat picker for the event editor. The base event keeps one set of fields;
     the view expands it into per-day instances. */
  function buildRepeat(rec) {
    var reps = ['none', 'daily', 'weekly', 'monthly', 'yearly'];
    var sel = '<select id="fRepeat">' + reps.map(function (r) {
      return '<option value="' + r + '"' + (rec && rec.repeat === r ? ' selected' : '') + '>' + t('opt.rep.' + r) + '</option>';
    }).join('') + '</select>';
    var extra =
      field(t('fld.ed.every'), '<input id="fRepeatEvery" type="number" min="1" step="1" value="' + (rec && rec.repeatEvery ? rec.repeatEvery : 1) + '">') +
      field(t('fld.ed.until'), '<input id="fRepeatUntil" type="date" value="' + (rec && rec.repeatUntil ? rec.repeatUntil : '') + '">') +
      field(t('fld.ed.monthLast'), '<select id="fRepeatMonthMode">' +
        '<option value="day"' + (rec && rec.repeatMonthMode !== 'last' ? ' selected' : '') + '>' + t('opt.rep.day') + '</option>' +
        '<option value="last"' + (rec && rec.repeatMonthMode === 'last' ? ' selected' : '') + '>' + t('opt.rep.last') + '</option>' +
        '</select>');
    return '<div class="field"><label>' + t('fld.ed.repeat') + '</label>' + sel +
      '<div id="repeatExtra" style="margin-top:6px">' + extra + '</div></div>';
  }

  var sheetInHistory = false;   /* we pushed an extra history entry for the sheet */

  function closeSheet(fromPop) {
    $('sheetMask').hidden = true;
    $('sheet').hidden = true;
    editing = null;
    /* Pop our own entry back off -- unless the pop itself is what closed us. */
    if (sheetInHistory) {
      sheetInHistory = false;
      if (!fromPop) history.back();
    }
  }

  function saveSheet() {
    if (!editing) return;
    var v = function (id) { var e = $(id); return e ? e.value : ''; };
    if (editing.kind === 'event') {
      var patch = {
        title: v('fTitle'),
        date: v('fDate'),
        start: Store.fromHHMM(v('fStart')),
        end: Store.fromHHMM(v('fEnd')),
        tag: v('fTag'),
        note: v('fNote'),
        repeat: v('fRepeat') || 'none',
        repeatEvery: Math.max(1, parseInt(v('fRepeatEvery'), 10) || 1),
        repeatUntil: v('fRepeatUntil') || '',
        repeatMonthMode: v('fRepeatMonthMode') || 'day'
      };
      if (editing.id) Store.updateEvent(editing.id, patch);
      else Store.newEvent(patch);
    } else {
      var p2 = {
        text: v('fText'),
        due: v('fDue') || null,
        project: v('fProject'),
        priority: v('fPriority')
      };
      if (editing.id) Store.updateTask(editing.id, p2);
      else Store.newTask(p2);
    }
    closeSheet();
    render();
    toast(t('toast.saved'));
  }

  /* --------------------------------------------------------------- search -- */
  function openSearch() {
    $('searchBar').hidden = false;
    var i = $('searchInput');
    i.focus();
  }
  function closeSearch() {
    $('searchBar').hidden = true;
    $('searchInput').value = '';
    Views.setQuery('');
    render();
  }

  /* --------------------------------------------------------------- avatar -- */
  /* Downscale to 128px before storing: localStorage is small and a phone photo
     would blow the quota (and slow down sync) for no visual gain. */
  function pickAvatar() {
    var inp = document.createElement('input');
    inp.type = 'file';
    inp.accept = 'image/*';
    inp.onchange = function () {
      var f = inp.files && inp.files[0];
      if (!f) return;
      var r = new FileReader();
      r.onload = function () {
        var img = new Image();
        img.onload = function () {
          var size = 128;
          var c = document.createElement('canvas');
          c.width = size; c.height = size;
          var ctx = c.getContext('2d');
          var s = Math.max(size / img.width, size / img.height);
          var dw = img.width * s, dh = img.height * s;
          ctx.drawImage(img, (size - dw) / 2, (size - dh) / 2, dw, dh);
          try {
            Store.settings.avatar = c.toDataURL('image/png');
            Store.persistSettings();
            render();
          } catch (e) { toast(t('toast.avTooLarge')); }
        };
        img.src = r.result;
      };
      r.readAsDataURL(f);
    };
    inp.click();
  }

  /* ------------------------------------------------------- import/export -- */
  function exportData() {
    var blob = new Blob([JSON.stringify(Store.raw(), null, 2)], { type: 'application/json' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'myschedule-' + Store.todayStr() + '.json';
    a.click();
    setTimeout(function () { URL.revokeObjectURL(a.href); }, 2000);
  }

  function importData() {
    var inp = document.createElement('input');
    inp.type = 'file';
    inp.accept = 'application/json,.json';
    inp.onchange = function () {
      var f = inp.files && inp.files[0];
      if (!f) return;
      var r = new FileReader();
      r.onload = function () {
        try {
          var obj = JSON.parse(r.result);
          if (!Array.isArray(obj.events) || !Array.isArray(obj.tasks)) throw new Error('bad shape');
          Store.replaceAll(obj);
          render();
          toast(t('toast.imported'));
        } catch (e) {
          toast(t('toast.importFail') + ': ' + e.message);
        }
      };
      r.readAsText(f);
    };
    inp.click();
  }

  /* ---- undo / redo --------------------------------------------------- */
  /* Cheaper to ask forgiveness than permission: the drag is not confirmed
     first, it is simply reversible. */
  function doUndo() {
    if (!window.Undo || !Undo.canUndo()) { toast(t('undo.none')); return; }
    Undo.undo();
    render();
    toast(t('undo.done'));
  }
  function doRedo() {
    if (!window.Undo || !Undo.canRedo()) { toast(t('redo.none')); return; }
    Undo.redo();
    render();
    toast(t('redo.done'));
  }
  /* The buttons are re-rendered with the view, so their enabled state has to
     be re-applied after every render -- and after every undo/redo. */
  function syncUndoButtons() {
    var u = document.querySelector('[data-act="undo"]');
    var r = document.querySelector('[data-act="redo"]');
    if (u) u.disabled = !(window.Undo && Undo.canUndo());
    if (r) r.disabled = !(window.Undo && Undo.canRedo());
  }

  /* ------------------------------------------------------------ clicks -- */
  function onDocumentClick(ev) {
    var b = ev.target.closest ? ev.target.closest('[data-act]') : null;
    if (b) {
      var act = b.dataset.act, id = b.dataset.id;
      switch (act) {
        /* ---- undo / redo (week view header + Ctrl+Z) ---- */
        case 'undo': doUndo(); return;
        case 'redo': doRedo(); return;

        case 'toggle-ev': {
          var e = Store.findEvent(id);
          if (e) Store.updateEvent(id, { done: !e.done });
          render(); return;
        }
        case 'toggle-task': {
          var tk = Store.findTask(id);
          if (tk) Store.updateTask(id, { done: !tk.done });
          render(); return;
        }
        case 'edit-ev': openSheet('event', id); return;
        case 'edit-task': openSheet('task', id); return;
        case 'cal-pick': openCalPicker(); return;
        case 'toggle-theme':
          Store.settings.theme = Store.settings.theme === 'night' ? 'light' : 'night';
          Store.persistSettings(); applyTheme(); return;
        case 'toggle-lang':
          Store.settings.lang = window.lang() === 'zh' ? 'en' : 'zh';
          Store.persistSettings(); applyLang(); render(); return;
        case 'export': exportData(); return;
        case 'import': importData(); return;
        case 'ai-open': if (window.AIUI) AIUI.open(b.dataset.tab || 'import'); return;

        /* ---- tag customisation ---- */
        case 'tag-add':
          Store.settings.tags.push({ key: 'new', color: '--accent' });
          Store.persistSettings(); render(); return;
        case 'tag-del': {
          var ti = parseInt(b.dataset.i, 10);
          var gone = Store.settings.tags[ti];
          Store.settings.tags.splice(ti, 1);
          /* Events keep their tag string; it simply falls back to the default
             colour until the user reassigns it. */
          Store.persistSettings(); render();
          if (gone) toast(gone.key);
          return;
        }
        case 'tag-preset': {
          var pj = parseInt(b.dataset.i, 10);
          if (Store.settings.tags[pj] && b.dataset.color) {
            Store.settings.tags[pj].color = b.dataset.color;
            Store.persistSettings(); render();
          }
          return;
        }
        case 'tag-color': {
          var ci = parseInt(b.dataset.i, 10);
          var cur = Store.settings.tags[ci];
          if (!cur) return;
          var order = ['--accent', '--accent-warm', '--accent-cool', '--holiday', '--ink-soft'];
          cur.color = order[(order.indexOf(cur.color) + 1) % order.length];
          Store.persistSettings(); render(); return;
        }

        /* ---- view shortcuts from other pages ---- */
        case 'go-stats': go('stats'); return;
        case 'go-focus': go('focus'); return;
        case 'go-today': go('today'); return;

        /* ---- calendar navigation (month / week views) ---- */
        case 'cal-prev': moveCursor(-1); return;
        case 'cal-next': moveCursor(1); return;
        case 'cal-today': cursor = new Date(); render(); return;

        /* ---- custom festivals ---- */
        case 'hol-add': {
          var d = $('holDate') && $('holDate').value;
          var n = $('holName') && $('holName').value.trim();
          if (!d || !n) { toast(t('hol.needBoth')); return; }
          Store.settings.holidays[d] = n;
          Store.persistSettings(); render(); return;
        }
        case 'hol-del': {
          delete Store.settings.holidays[b.dataset.date];
          Store.persistSettings(); render(); return;
        }

        /* ---- avatar ---- */
        case 'av-pick': pickAvatar(); return;
        case 'av-reset':
          Store.settings.avatar = null;
          Store.persistSettings(); render(); return;
      }
      /* Focus timer owns its own buttons (view + mini bar); the element is
         passed along because queue buttons carry a row index in data-i. */
      if (window.Focus && Focus.handle && Focus.handle(act, b)) return;
      /* Cloud actions are owned by cloud.js. */
      if (window.CloudSync && CloudSync.handle) { CloudSync.handle(act); return; }
    }

    /* Tapping a month/day cell moves the cursor there (month: that day's month;
       week: that day's week). Both views re-render so the navigation takes effect. */
    var cell = ev.target.closest ? ev.target.closest('[data-date]') : null;
    if (cell && cell.dataset.date) {
      var d = Store.parseISO(cell.dataset.date);
      if (d) { cursor = d; if (current === 'month' || current === 'week') render(); }
      return;
    }
    /* Tapping a calendar block (week / month chip) opens its editor. Plain
       list rows deliberately do NOT: a stray tap on the row text popping a
       modal felt like a trap -- the row's own 编辑 button is the entry there. */
    var card = ev.target.closest ? ev.target.closest('[data-ev]') : null;
    if (card && !b && !card.classList.contains('card-row')) { openSheet('event', card.dataset.ev); }
    var tcard = ev.target.closest ? ev.target.closest('[data-task]') : null;
    if (tcard && !b && !tcard.classList.contains('card-row')) { openSheet('task', tcard.dataset.task); }
  }

  /* ------------------------------------------------- year/month picker -- */
  /* The ‹ › buttons move one period at a time; jumping to "next March" that
     way is 8 taps. The calendar title opens this little panel instead. */
  var pickY = 0, pickM = 0;

  function openCalPicker() {
    pickY = cursor.getFullYear();
    pickM = cursor.getMonth();
    paintCalPicker();
    $('pickMask').hidden = false;
    $('calPick').hidden = false;
  }

  function closeCalPicker() {
    $('pickMask').hidden = true;
    $('calPick').hidden = true;
  }

  function paintCalPicker() {
    var months = t('cal.months').split(',');
    var grid = months.map(function (lbl, i) {
      return '<button class="pm' + (i === pickM ? ' on' : '') + '" data-pm="' + i + '">' +
        Views.esc(lbl) + '</button>';
    }).join('');
    $('calPick').innerHTML =
      '<div class="cp-head">' +
        '<button class="cal-btn" data-py="-1" aria-label="-1 year">‹</button>' +
        '<strong>' + pickY + '</strong>' +
        '<button class="cal-btn" data-py="1" aria-label="+1 year">›</button>' +
        '<button class="cp-x" data-cpx="1" aria-label="Close">×</button>' +
      '</div>' +
      '<div class="cp-grid">' + grid + '</div>';
  }

  function calPickClick(ev) {
    var b = ev.target.closest ? ev.target.closest('button') : null;
    if (!b) return;
    if (b.dataset.cpx) { closeCalPicker(); return; }
    if (b.dataset.py) {
      pickY += parseInt(b.dataset.py, 10);
      if (pickY < 1970) pickY = 1970;
      if (pickY > 2100) pickY = 2100;
      paintCalPicker();
      return;
    }
    if (b.dataset.pm != null && b.dataset.pm !== '') {
      /* Month view lands on that month; week view on the week containing
         its 1st -- both read the same cursor. */
      cursor = new Date(pickY, parseInt(b.dataset.pm, 10), 1);
      closeCalPicker();
      render();
    }
  }

  /* The phone's BACK key: popstate fires, whatever overlay is up closes. */
  window.addEventListener('popstate', function () {
    if (window.AIUI && AIUI.isOpen()) { AIUI.close(true); return; }
    if (!$('sheet').hidden) closeSheet(true);
    if (!$('calPick').hidden) closeCalPicker();
  });

  /* --------------------------------------------------------------- boot -- */
  /* Ctrl/Cmd+Z / Ctrl+Shift+Z: the keyboard route to the same history the
     week-view buttons expose. Skipped while typing, or every text field
     would lose its own undo. */
  function onKeyDown(ev) {
    /* Esc backs out of whatever overlay is on top: picker first, then the
       editor sheet. Desktop had no keyboard way out at all. */
    if (ev.key === 'Escape') {
      if (window.AIUI && AIUI.isOpen()) { AIUI.close(); return; }
      if (!$('calPick').hidden) { closeCalPicker(); return; }
      if (!$('sheet').hidden) { closeSheet(); return; }
      return;
    }
    if (!(ev.ctrlKey || ev.metaKey)) return;
    var k = (ev.key || '').toLowerCase();
    if (k !== 'z' && k !== 'y') return;
    var n = ev.target || {};
    var tag = (n.tagName || '').toLowerCase();
    if (tag === 'input' || tag === 'textarea' || n.isContentEditable) return;
    ev.preventDefault();
    if (k === 'y' || ev.shiftKey) doRedo(); else doUndo();
  }

  function boot() {
    applyTheme();
    applyFont();
    applyLang();
    document.addEventListener('keydown', onKeyDown);
    /* Back (hardware key, gesture or browser button) leaves the AI page and
       returns to the view the user came from. No other view owns a history
       entry, so everything else falls through to the page itself. */
    window.addEventListener('popstate', function () {
      if (current === 'ai') { current = prevView || 'month'; render(); }
    });
    /* A drag writes through the Store, so the buttons must follow the history,
       not only the render cycle. */
    if (window.Undo) Undo.onChange(syncUndoButtons);

    /* Focus registers Views.focus, so it must run before the deep-link lookup
       below -- otherwise #focus silently falls back to the month view. */
    if (window.Focus && Focus.init) Focus.init();

    /* Today and Stats are their own files (they are big enough to deserve
       one) and register themselves here, before the deep-link lookup below --
       otherwise #today / #stats silently fall back to the month view, exactly
       the bug #focus had. */
    if (window.Views) {
      if (window.TodayView) Views.today = TodayView.render;
      if (window.StatsView) Views.stats = StatsView.render;
    }

    /* Deep link: #tasks / #week / #ai ... opens that view directly. The AI
       view is deliberately not written into settings (see openAI). */
    var h = location.hash.replace('#', '');
    if (h === 'ai') openAI();
    else if (Views[h]) { current = h; Store.settings.view = h; }

    /* QA hook: ?auth=1 opens the sign-in sheet on load, so the panel can be
       screenshotted without a scripted click. */
    if (/[?&]auth=1/.test(location.search)) {
      go('me');
      setTimeout(function () {
        if (window.CloudSync) CloudSync.handle('sync-signin');
      }, 300);
    }
    /* QA hook: ?picker=1 opens the duration wheel over the focus view. */
    if (/[?&]picker=1/.test(location.search)) {
      go('focus');
      setTimeout(function () {
        if (window.Focus) Focus.openPicker();
      }, 300);
    }

    Array.prototype.forEach.call(document.querySelectorAll('.nav-btn'), function (btn) {
      btn.addEventListener('click', function () {
        if (!btn.dataset.group) { go(btn.dataset.view); return; }
        var g = btn.dataset.group;
        /* Tapping the open group closes it; tapping another opens that one. */
        if (openGroup === g) { openGroup = null; renderSub(); render(); return; }
        openGroup = g;
        if (groupOf(current) !== g) { go(GROUPS[g][0]); return; }
        renderSub(); render();
      });
    });

    $('fab').addEventListener('click', function () {
      openSheet(current === 'tasks' ? 'task' : 'event', null);
    });

    if (window.AIUI) {
      AIUI.bind();
      /* #navAi is a .nav-btn with data-view="ai", so the shared nav handler
         above already routes to it; nothing to bind here. */
      /* QA hook: ?ai=import|plan|edit|key opens the panel on that tab. */
      var aiTab = (location.search.match(/[?&]ai=(import|plan|edit|key)/) || [])[1];
      if (aiTab) setTimeout(function () { AIUI.open(aiTab); }, 200);
    }

    /* Search: typing filters the current view. */
    $('searchToggle').addEventListener('click', function () {
      if ($('searchBar').hidden) openSearch(); else closeSearch();
    });
    $('searchClear').addEventListener('click', closeSearch);
    (function () {
      var t = null;
      $('searchInput').addEventListener('input', function () {
        clearTimeout(t);
        t = setTimeout(function () {
          Views.setQuery($('searchInput').value);
          render();
        }, 180);
      });
    })();
    /* Wrapped: the click event must not leak into closeSheet's fromPop flag,
       or the pushed history entry would never be popped back off. */
    $('sheetClose').addEventListener('click', function () { closeSheet(); });
    $('sheetCancel').addEventListener('click', function () { closeSheet(); });
    $('sheetMask').addEventListener('click', function () { closeSheet(); });
    $('pickMask').addEventListener('click', closeCalPicker);
    $('calPick').addEventListener('click', calPickClick);
    $('sheetSave').addEventListener('click', saveSheet);
    $('sheetDelete').addEventListener('click', function () {
      if (!editing || !editing.id) return;
      if (editing.kind === 'event') Store.removeEvent(editing.id);
      else Store.removeTask(editing.id);
      closeSheet(); render(); toast(t('toast.deleted'));
    });

    document.addEventListener('click', onDocumentClick);

    /* Seed a few records on first run so the UI is never a blank wall. */
    if (!Store.events.length && !Store.tasks.length) seed();
    render();

    /* Clock ticks so the hero never shows a stale time. */
    setInterval(refreshHero, 20000);

    /* The week grid's "now" marker has to creep forward. Skip the redraw while
       a block is being dragged, or the element under the finger is replaced
       mid-gesture and the drag dies. */
    setInterval(function () {
      if (current !== 'week') return;
      if (document.querySelector('.wk-ev.is-drag, .wk-ev.is-resize')) return;
      render();
    }, 60000);

    if ('serviceWorker' in navigator) {
      navigator.serviceWorker.register('sw.js').catch(function () { });
      /* When an updated worker takes over (skipWaiting + clients.claim fires
         this on first load after a release), reload once so the new shell is
         actually rendered -- otherwise users must refresh twice to see a
         release. The guard prevents a reload loop. */
      if (!sessionStorage.getItem('swReloaded')) {
        navigator.serviceWorker.addEventListener('controllerchange', function () {
          if (sessionStorage.getItem('swReloaded')) return;
          sessionStorage.setItem('swReloaded', '1');
          location.reload();
        });
      }
    }

    if (window.CloudSync && CloudSync.init) CloudSync.init();

    /* ?selftest=1 loads the browser self test. Injected rather than linked so
       a normal visit never downloads it. */
    if (/[?&]selftest=1/.test(location.search)) {
      var st = document.createElement('script');
      st.src = 'js/selftest.js?v=30';
      document.body.appendChild(st);
    }

    /* ?debug: report real layout metrics through the title so headless runs
       can assert the responsive rules without opening devtools (and without
       reading a screenshot, which cannot be verified programmatically). */
    if (location.search.indexOf('debug') !== -1) {
      setTimeout(function () { reportLayout(); }, 400);
      window.addEventListener('resize', function () { reportLayout(); });
    }
  }

  function rect(sel) {
    var el = document.querySelector(sel);
    if (!el) return null;
    var r = el.getBoundingClientRect();
    return { x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) };
  }

  function reportLayout() {
    var v = $('view');
    var nav = rect('.nav'), hero = rect('.hero'), view = rect('#view');
    var col = rect('.week-col');
    var cards = document.querySelectorAll('.view > .card');
    var x1 = cards[0] ? Math.round(cards[0].getBoundingClientRect().left) : -1;
    var x2 = cards[1] ? Math.round(cards[1].getBoundingClientRect().left) : -1;
    var out = [
      'vw=' + window.innerWidth,
      'vh=' + window.innerHeight,
      'docW=' + document.documentElement.scrollWidth,
      'nav=' + (nav ? (nav.x + ',' + nav.y + ' ' + nav.w + 'x' + nav.h) : 'none'),
      'hero=' + (hero ? (hero.x + ',' + hero.y + ' ' + hero.w + 'x' + hero.h) : 'none'),
      'view=' + (view ? (view.x + ',' + view.y + ' ' + view.w + 'x' + view.h) : 'none'),
      'weekcol=' + (col ? col.h : 'none'),
      'cardX=' + x1 + '/' + x2
    ].join(' ');
    document.title = out;
    var p = document.createElement('pre');
    p.id = 'layoutReport';
    p.textContent = out;
    p.style.display = 'none';
    document.body.appendChild(p);
  }

  function seed() {
    var today = Store.todayStr();
    Store.newEvent({ date: today, start: 9 * 60, end: 10 * 60, title: 'Team Meeting', tag: 'work' });
    Store.newEvent({ date: today, start: 14 * 60, end: 15 * 60 + 30, title: 'Deep work', tag: 'focus', done: true });
    Store.newTask({ text: '整理本周会议纪要', project: 'Work', priority: 'high' });
    Store.newTask({ text: '提交读书报告终稿', due: today, project: 'Study', priority: 'high' });
  }

  /* Public hooks used by cloud.js after a pull. */
  window.App = {
    render: render,
    go: go,
    closeAI: closeAI,
    toast: toast,
    refreshHero: refreshHero,
    applyLang: applyLang,
    applyFont: applyFont,
    currentView: function () { return current; },
    openSearch: openSearch,
    get cursor() { return cursor; }
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
