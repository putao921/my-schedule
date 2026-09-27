/* Service worker: cache-first for the app shell, network-first for nothing.
 *
 * The app is offline-first by design (localStorage is the source of truth the
 * UI reads), so the SW only needs to guarantee the shell itself loads without
 * a network. Caching data would risk serving a stale shell against fresh
 * local data -- a mismatch that is worse than a plain offline miss.
 *
 * Bump CACHE on every shell change; the old cache is deleted on activate.
 */
var CACHE = 'myschedule-v2';

var SHELL = [
  './',
  './index.html',
  './manifest.webmanifest',
  './css/tokens.css',
  './css/app.css',
  './js/i18n.js',
  './js/store.js',
  './js/views.js',
  './js/cloud.js',
  './js/app.js',
  './icons/icon-192.png',
  './icons/icon-512.png'
];

self.addEventListener('install', function (e) {
  e.waitUntil(
    caches.open(CACHE).then(function (c) {
      /* Individually, so one 404 cannot fail the whole install. */
      return Promise.all(SHELL.map(function (u) {
        return c.add(u).catch(function () { });
      }));
    }).then(function () { return self.skipWaiting(); })
  );
});

self.addEventListener('activate', function (e) {
  e.waitUntil(
    caches.keys().then(function (keys) {
      return Promise.all(keys.map(function (k) {
        return k === CACHE ? null : caches.delete(k);
      }));
    }).then(function () { return self.clients.claim(); })
  );
});

self.addEventListener('fetch', function (e) {
  var req = e.request;
  if (req.method !== 'GET') return;

  /* Cloud data-plane calls must never be cached -- they carry credentials
     and must reflect the server's current state. */
  if (req.url.indexOf('/.cloud/') !== -1) return;

  e.respondWith(
    caches.match(req).then(function (hit) {
      if (hit) {
        /* Revalidate in the background so the next launch is current. */
        fetch(req).then(function (res) {
          if (res && res.ok) {
            caches.open(CACHE).then(function (c) { c.put(req, res.clone()); });
          }
        }).catch(function () { });
        return hit;
      }
      return fetch(req).then(function (res) {
        if (res && res.ok) {
          var copy = res.clone();
          caches.open(CACHE).then(function (c) { c.put(req, copy); });
        }
        return res;
      }).catch(function () {
        /* Offline navigation with no cached shell: fall back to the entry. */
        if (req.mode === 'navigate') return caches.match('./index.html');
        return null;
      });
    })
  );
});
