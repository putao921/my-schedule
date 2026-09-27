/* App shell: routing, the editor sheet, toasts, import/export, SW registration. */
(function () {
  'use strict';

  var cursor = new Date();
  var current = Store.settings.view || 'month';
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
      'search.toggle': '#searchToggleTxt'
    };
    Object.keys(map).forEach(function (k) {
      var el = document.querySelector(map[k]);
      if (el) el.textContent = t(k);
    });
    var ph = $('searchInput');
    if (ph) ph.setAttribute('placeholder', t('search.toggle'));
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

  /* ------------------------------------------------------------- render -- */
  function render() {
    var el = $('view');
    var fn = Views[current] || Views.month;
    /* Views key off this for breakpoint-specific rules (e.g. the two-column
       task list on wide screens). */
    el.dataset.view = current;
    fn(el, cursor);
    Array.prototype.forEach.call(document.querySelectorAll('.nav-btn'), function (b) {
      b.classList.toggle('is-on', b.dataset.view === current);
    });
    refreshHero();
    if (window.Focus) Focus.paint();
    if (window.CloudSync && CloudSync.refreshBadge) CloudSync.refreshBadge();
  }

  function go(view) {
    current = view;
    Store.settings.view = view;
    Store.persistSettings();
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
    editing = { kind: kind, id: id || null };
    var rec = null;
    if (id) rec = kind === 'event' ? Store.findEvent(id) : Store.findTask(id);

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
        field(t('fld.ed.note'), '<textarea id="fNote">' + Views.esc(rec ? rec.note : '') + '</textarea>');
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
    $('sheetMask').hidden = false;
    $('sheet').hidden = false;
  }

  function field(label, inner) {
    return '<div class="field"><label>' + label + '</label>' + inner + '</div>';
  }

  function closeSheet() {
    $('sheetMask').hidden = true;
    $('sheet').hidden = true;
    editing = null;
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
        note: v('fNote')
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

  /* ------------------------------------------------------------ clicks -- */
  function onDocumentClick(ev) {
    var b = ev.target.closest ? ev.target.closest('[data-act]') : null;
    if (b) {
      var act = b.dataset.act, id = b.dataset.id;
      switch (act) {
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
        case 'toggle-theme':
          Store.settings.theme = Store.settings.theme === 'night' ? 'light' : 'night';
          Store.persistSettings(); applyTheme(); return;
        case 'toggle-lang':
          Store.settings.lang = window.lang() === 'zh' ? 'en' : 'zh';
          Store.persistSettings(); applyLang(); render(); return;
        case 'export': exportData(); return;
        case 'import': importData(); return;

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

    /* Tapping a month/day cell moves the cursor there. */
    var cell = ev.target.closest ? ev.target.closest('[data-date]') : null;
    if (cell && cell.dataset.date) {
      var d = Store.parseISO(cell.dataset.date);
      if (d) { cursor = d; if (current === 'month') render(); }
      return;
    }
    /* Tapping an event card opens its editor. */
    var card = ev.target.closest ? ev.target.closest('[data-ev]') : null;
    if (card && !b) { openSheet('event', card.dataset.ev); }
    var tcard = ev.target.closest ? ev.target.closest('[data-task]') : null;
    if (tcard && !b) { openSheet('task', tcard.dataset.task); }
  }

  /* --------------------------------------------------------------- boot -- */
  function boot() {
    applyTheme();
    applyLang();

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

    /* Deep link: #tasks / #week / ... opens that view directly. */
    var h = location.hash.replace('#', '');
    if (Views[h]) { current = h; Store.settings.view = h; }

    /* QA hook: ?auth=1 opens the sign-in sheet on load, so the panel can be
       screenshotted without a scripted click. */
    if (/[?&]auth=1/.test(location.search)) {
      go('me');
      setTimeout(function () {
        if (window.CloudSync) CloudSync.handle('sync-signin');
      }, 300);
    }

    Array.prototype.forEach.call(document.querySelectorAll('.nav-btn'), function (btn) {
      btn.addEventListener('click', function () { go(btn.dataset.view); });
    });

    $('fab').addEventListener('click', function () {
      openSheet(current === 'tasks' ? 'task' : 'event', null);
    });

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
    $('sheetClose').addEventListener('click', closeSheet);
    $('sheetCancel').addEventListener('click', closeSheet);
    $('sheetMask').addEventListener('click', closeSheet);
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

    if ('serviceWorker' in navigator) {
      navigator.serviceWorker.register('sw.js').catch(function () { });
    }

    if (window.CloudSync && CloudSync.init) CloudSync.init();

    /* ?selftest=1 loads the browser self test. Injected rather than linked so
       a normal visit never downloads it. */
    if (/[?&]selftest=1/.test(location.search)) {
      var st = document.createElement('script');
      st.src = 'js/selftest.js';
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
    toast: toast,
    refreshHero: refreshHero,
    applyLang: applyLang,
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
