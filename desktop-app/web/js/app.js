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
      'nav.month': '.nav-btn[data-view="month"] .nav-txt',
      'nav.week': '.nav-btn[data-view="week"] .nav-txt',
      'nav.list': '.nav-btn[data-view="list"] .nav-txt',
      'nav.tasks': '.nav-btn[data-view="tasks"] .nav-txt',
      'nav.profile': '.nav-btn[data-view="me"] .nav-txt'
    };
    Object.keys(map).forEach(function (k) {
      var el = document.querySelector(map[k]);
      if (el) el.textContent = t(k);
    });
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
    fn(el, cursor);
    Array.prototype.forEach.call(document.querySelectorAll('.nav-btn'), function (b) {
      b.classList.toggle('is-on', b.dataset.view === current);
    });
    refreshHero();
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
      ? (kind === 'event' ? t('fld.ed.title') : 'Edit task')
      : (kind === 'event' ? t('fld.ed.new') : 'New task');
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
          ['work', 'focus', 'life'].map(function (g) {
            return '<option value="' + g + '"' + (rec && rec.tag === g ? ' selected' : '') + '>' + g + '</option>';
          }).join('') + '</select>') +
        field('Note', '<textarea id="fNote">' + Views.esc(rec ? rec.note : '') + '</textarea>');
    } else {
      body =
        field('Task', '<input id="fText" type="text" value="' + Views.esc(rec ? rec.text : '') + '">') +
        field('Due', '<input id="fDue" type="date" value="' + (rec && rec.due ? rec.due : '') + '">') +
        field('Project', '<input id="fProject" type="text" value="' + Views.esc(rec ? rec.project : 'Inbox') + '">') +
        field('Priority', '<select id="fPriority">' +
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
    toast('saved');
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
          toast('imported');
        } catch (e) {
          toast('import failed: ' + e.message);
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
      }
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
    $('sheetClose').addEventListener('click', closeSheet);
    $('sheetCancel').addEventListener('click', closeSheet);
    $('sheetMask').addEventListener('click', closeSheet);
    $('sheetSave').addEventListener('click', saveSheet);
    $('sheetDelete').addEventListener('click', function () {
      if (!editing || !editing.id) return;
      if (editing.kind === 'event') Store.removeEvent(editing.id);
      else Store.removeTask(editing.id);
      closeSheet(); render(); toast('deleted');
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

    /* ?debug: report the real layout metrics through the title, so headless
       runs can be checked without opening devtools. */
    if (location.search.indexOf('debug') !== -1) {
      var v = $('view');
      document.title = 'vw=' + window.innerWidth +
        ' docW=' + document.documentElement.scrollWidth +
        ' viewW=' + v.scrollWidth +
        ' gridW=' + (document.querySelector('.month-grid') || {}).scrollWidth;
    }
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
    get cursor() { return cursor; }
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
