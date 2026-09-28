/* Statistics: the "how am I actually doing" page.
 *
 * Charts are plain divs sized in percent -- no charting library. Two reasons:
 * the app must load offline from a service-worker cache with zero network
 * dependencies, and a library would add ~100KB to render seven bars.
 *
 * Everything here is derived, never stored: the week series is computed from
 * events[] and settings.focusLog on each render, so there is no aggregate that
 * can drift out of sync with the records it summarises.
 */
(function () {
  'use strict';

  var DAY = 86400000;

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function iso(d) { return Store.iso(d); }
  function pad2(n) { return (n < 10 ? '0' : '') + n; }

  /* The seven days ending today, oldest first -- reading order matches how
     people read a trend. */
  function last7() {
    var out = [];
    var base = new Date();
    for (var i = 6; i >= 0; i--) {
      var d = new Date(base.getFullYear(), base.getMonth(), base.getDate() - i);
      out.push(d);
    }
    return out;
  }

  function dowShort(d) {
    var zh = window.lang() === 'zh';
    return zh ? ['日', '一', '二', '三', '四', '五', '六'][d.getDay()]
      : ['S', 'M', 'T', 'W', 'T', 'F', 'S'][d.getDay()];
  }

  function hhmm(mins) {
    mins = parseInt(mins, 10) || 0;
    return Math.floor(mins / 60) + 'h' + pad2(mins % 60) + 'm';
  }

  /* ---- series --------------------------------------------------------- */
  function focusSeries(days) {
    return days.map(function (d) {
      return { date: iso(d), label: dowShort(d), value: Store.focusOn(iso(d)) };
    });
  }

  function eventSeries(days) {
    return days.map(function (d) {
      var s = iso(d);
      var all = Store.events.filter(function (e) { return e.date === s; });
      var done = all.filter(function (e) { return e.done; }).length;
      return { date: s, label: dowShort(d), done: done, total: all.length };
    });
  }

  function tagSeries() {
    var map = {};
    Store.events.forEach(function (e) {
      var k = e.tag || 'work';
      map[k] = (map[k] || 0) + 1;
    });
    return Object.keys(map).map(function (k) {
      return { key: k, count: map[k], color: (Views.tagStyle ? Views.tagStyle(k).bg : Views.tagColor(k)) };
    }).sort(function (a, b) { return b.count - a.count; });
  }

  /* Consecutive days with a recorded focus session. Today is not allowed to
     break the streak: at 9am a user has not failed to focus, they simply have
     not started yet. */
  function streak() {
    var n = 0;
    for (var i = 0; i < 400; i++) {
      var d = new Date();
      d = new Date(d.getFullYear(), d.getMonth(), d.getDate() - i);
      var v = Store.focusOn(iso(d));
      if (v > 0) { n++; continue; }
      if (i === 0) continue;   /* today may still be empty */
      break;
    }
    return n;
  }

  function maxOf(series, key) {
    var m = 0;
    series.forEach(function (x) { if ((x[key] || 0) > m) m = x[key] || 0; });
    return m;
  }

  /* ---- charts --------------------------------------------------------- */
  /* One bar per day. Two modes:
       single  -- bar height is value / busiest day (focus minutes)
       two-tone -- track height is the day's scheduled total / busiest day, and
                   an inner bar shows what share of that day got done, so a 1/1
                   day and a 3/8 day look different instead of both "small". */
  function barChart(series, opts) {
    var two = opts.fill === true;
    var tmax = two ? (maxOf(series, 'total') || 1) : 1;
    var max = two ? tmax : (maxOf(series, opts.key) || 1);

    var out = '<div class="bars">';
    series.forEach(function (x) {
      var v = x[opts.key] || 0;
      var h, inner = '', label = '';

      if (two) {
        var tot = x.total || 0;
        h = tot ? Math.max(4, Math.round(tot / tmax * 100)) : 0;
        inner = '<i class="bar-fill" style="height:' +
          (tot ? Math.round(x.done / tot * 100) : 0) + '%"></i>';
        label = tot ? (x.done + '/' + tot) : '';
      } else {
        h = v ? Math.max(4, Math.round(v / max * 100)) : 0;
        label = v ? String(v) : '';
      }

      out += '<div class="bar-col">' +
        '<span class="bar-val">' + esc(label) + '</span>' +
        '<div class="bar-area"><div class="bar-track" style="height:' + h + '%">' + inner + '</div></div>' +
        '<span class="bar-lab">' + esc(x.label) + '</span>' +
        '</div>';
    });
    return out + '</div>';
  }

  function distList(items) {
    var max = 0;
    items.forEach(function (x) { if (x.count > max) max = x.count; });
    if (!max) return '';
    return '<div class="dist">' + items.map(function (x) {
      var w = Math.round(x.count / max * 100);
      return '<div class="dist-row">' +
        '<span class="dist-key">' + esc(x.key) + '</span>' +
        '<span class="dist-track"><i style="width:' + w + '%;background:var(' + x.color + ')"></i></span>' +
        '<span class="dist-val">' + x.count + '</span>' +
        '</div>';
    }).join('') + '</div>';
  }

  /* ---- view ----------------------------------------------------------- */
  function renderStats(el) {
    var days = last7();
    var fs = focusSeries(days);
    var es = eventSeries(days);
    var tags = tagSeries();

    var focusWeek = fs.reduce(function (a, x) { return a + x.value; }, 0);
    var evWeek = es.reduce(function (a, x) { return a + x.total; }, 0);
    var evDone = es.reduce(function (a, x) { return a + x.done; }, 0);

    var allTasks = Store.tasks.length;
    var openTasks = Store.tasks.filter(function (x) { return !x.done; }).length;

    var out = '<div class="sec-head"><h3>' + esc(t('nav.stats')) + '</h3></div>';

    /* Overview tiles. */
    out += '<div class="tiles">' +
      tile(hhmm(focusWeek), t('st.focusWeek')) +
      tile(evDone + '/' + evWeek, t('st.evWeek')) +
      tile(streak(), t('st.streak')) +
      tile((allTasks - openTasks) + '/' + allTasks, t('st.taskDone')) +
      '</div>';

    /* Focus minutes: the one number people most want to see trend. */
    out += '<div class="sec-head"><h3>' + esc(t('st.focus7')) + '</h3>' +
      '<span class="sub">' + esc(t('st.minutes')) + '</span></div>';
    out += '<div class="card">' + barChart(fs, { key: 'value', fill: false }) + '</div>';

    /* Events: done against scheduled. */
    out += '<div class="sec-head"><h3>' + esc(t('st.ev7')) + '</h3>' +
      '<span class="sub">' + evDone + ' / ' + evWeek + '</span></div>';
    out += '<div class="card">' + barChart(es, { key: 'done', fill: true }) + '</div>';

    /* Tag mix. */
    out += '<div class="sec-head"><h3>' + esc(t('st.byTag')) + '</h3></div>';
    out += '<div class="card">' +
      (tags.length ? distList(tags) : Views.emptyBox(t('st.noData'))) + '</div>';

    el.innerHTML = out;
  }

  function tile(value, label) {
    return '<div class="tile"><b>' + esc(value) + '</b><span>' + esc(label) + '</span></div>';
  }

  window.StatsView = { render: renderStats };
})();
