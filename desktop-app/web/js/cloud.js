/* Cloud sync: Auth (email) + Database (one JSON snapshot per user).
 *
 * Web apps support EMAIL login only -- phone/SMS and WeChat login are not
 * available on this platform, so they are deliberately absent here.
 *
 * Auth also only works on the app's registered HTTPS release domain. On
 * localhost or in a preview the SDK cannot complete a login, so every entry
 * point reports that clearly instead of failing silently.
 *
 * Sync model is last-writer-wins on a single JSON snapshot: simple, and it
 * matches how the desktop app exports/imports one file. Per-field merges come
 * later if a real conflict ever shows up.
 */
(function () {
  'use strict';

  var PUBLIC = {
    endpoint: 'https://my-schedule-88451.app.workbuddy.host',
    publishableKey: 'wbpk_0fr8fUkTu71oJ6tv8lH5Ra_PMMugIhkFlchqmyNRu7fUTzSP1F8fIpW'
  };

  var cloud = null;
  var pendingOtp = null;      /* { email, verificationId, isExistingUser } */
  var pendingReset = null;    /* returned challenge from resetPasswordForEmail */
  var authMode = 'password';  /* password | otp | signup | reset */
  var user = null;

  /* ------------------------------------------------------------- setup --- */
  function ready() {
    if (cloud) return true;
    if (typeof WorkBuddyCloud === 'undefined') return false;
    cloud = WorkBuddyCloud.createWorkBuddyCloud({
      endpoint: PUBLIC.endpoint,
      publishableKey: PUBLIC.publishableKey
    });
    cloud.auth.onAuthStateChange(function (event, session) {
      user = session && session.user ? session.user : null;
      if (event === 'SIGNED_OUT') user = null;
      paintState();
    });
    return true;
  }

  function onReleaseDomain() {
    /* Auth requires the registered HTTPS origin. */
    return location.protocol === 'https:' &&
      location.hostname.indexOf('app.workbuddy.host') !== -1;
  }

  function note(msg, bad) {
    if (window.App && App.toast) App.toast(msg);
    var el = document.getElementById('syncState');
    if (el) el.textContent = bad ? 'offline' : msg;
  }

  function paintState() {
    var mail = document.getElementById('acctMail');
    var st = document.getElementById('acctState');
    if (mail) mail.textContent = user ? (user.email || 'signed in') : 'not signed in';
    if (st) st.textContent = user ? 'cloud on' : 'local only';
  }

  /* --------------------------------------------------------- auth sheet --- */
  function sheetEl() {
    var el = document.getElementById('authSheet');
    if (el) return el;
    el = document.createElement('section');
    el.className = 'sheet';
    el.id = 'authSheet';
    el.setAttribute('aria-modal', 'true');
    el.innerHTML =
      '<header class="sheet-head"><h2 id="authTitle">Sign in</h2>' +
      '<button class="sheet-x" id="authClose" aria-label="Close">&times;</button></header>' +
      '<div class="sheet-body" id="authBody"></div>' +
      '<footer class="sheet-foot"><span class="spacer"></span>' +
      '<button class="btn btn-ghost" id="authCancel">Cancel</button>' +
      '<button class="btn btn-primary" id="authGo">Go</button></footer>';
    document.body.appendChild(el);
    el.hidden = true;
    document.getElementById('authClose').onclick = closeAuth;
    document.getElementById('authCancel').onclick = closeAuth;
    document.getElementById('authGo').onclick = submitAuth;
    return el;
  }

  function openAuth(mode) {
    if (!ready()) { note('cloud SDK not loaded', true); return; }
    authMode = mode || 'password';
    var el = sheetEl();
    renderAuth();
    el.hidden = false;
  }

  function closeAuth() {
    var el = document.getElementById('authSheet');
    if (el) el.hidden = true;
  }

  function renderAuth() {
    var body = document.getElementById('authBody');
    if (!body) return;

    /* Tabs: all four flows reachable, as the default email contract requires. */
    var tabs =
      '<div class="card-row" style="margin-bottom:12px;gap:6px;flex-wrap:wrap">' +
      tabBtn('password', 'Password') + tabBtn('otp', 'Email code') +
      tabBtn('signup', 'Sign up') + tabBtn('reset', 'Forgot') +
      '</div>';

    var form = '';
    form += '<div class="field"><label>Email</label><input id="aEmail" type="email" inputmode="email" autocomplete="email"></div>';

    if (authMode === 'password') {
      form += '<div class="field"><label>Password</label><input id="aPass" type="password" autocomplete="current-password"></div>';
    } else if (authMode === 'otp') {
      form += '<div class="field"><label>Code from email</label>' +
        '<div style="display:flex;gap:8px"><input id="aCode" type="text" inputmode="numeric" style="flex:1">' +
        '<button class="btn" type="button" id="aSend">Get code</button></div></div>';
    } else if (authMode === 'signup') {
      form += '<div class="field"><label>Password (for future logins)</label><input id="aPass" type="password" autocomplete="new-password"></div>' +
        '<div class="field"><label>Code from email</label>' +
        '<div style="display:flex;gap:8px"><input id="aCode" type="text" inputmode="numeric" style="flex:1">' +
        '<button class="btn" type="button" id="aSend">Get code</button></div></div>';
    } else {
      form += '<div class="field"><label>New password</label><input id="aPass" type="password" autocomplete="new-password"></div>' +
        '<div class="field"><label>Code from email</label>' +
        '<div style="display:flex;gap:8px"><input id="aCode" type="text" inputmode="numeric" style="flex:1">' +
        '<button class="btn" type="button" id="aSend">Send reset</button></div></div>';
    }

    var warn = onReleaseDomain() ? '' :
      '<div class="card" style="border-color:var(--holiday);font-size:12px">' +
      'Sign-in works only on the published HTTPS domain. Local preview is offline-only; ' +
      'data is still saved on this device.</div>';

    body.innerHTML = warn + tabs + form;

    var send = document.getElementById('aSend');
    if (send) send.onclick = sendCode;
  }

  function tabBtn(mode, label) {
    return '<button class="mini-btn" data-authmode="' + mode + '" style="' +
      (authMode === mode ? 'font-weight:700;border-color:var(--accent);color:var(--accent)' : '') +
      '">' + label + '</button>';
  }

  function val(id) {
    var e = document.getElementById(id);
    return e ? e.value.trim() : '';
  }

  /* ------------------------------------------------------------- flows --- */
  async function sendCode() {
    var email = val('aEmail');
    if (!email) { note('enter your email first', true); return; }
    try {
      if (authMode === 'reset') {
        var started = await cloud.auth.resetPasswordForEmail(email);
        if (started.error) { note(started.error.message, true); return; }
        pendingReset = started.data;
        note('reset code sent');
      } else {
        var sent = await cloud.auth.sendOtp({ email: email });
        if (sent.error) { note(sent.error.message, true); return; }
        pendingOtp = {
          email: email,
          verificationId: sent.data.verificationId,
          isExistingUser: !!sent.data.isExistingUser
        };
        note('code sent');
      }
    } catch (e) {
      note('could not send: ' + e.message, true);
    }
  }

  async function submitAuth() {
    var email = val('aEmail');
    if (!email) { note('enter your email first', true); return; }

    try {
      if (authMode === 'password') {
        var r = await cloud.auth.signInWithPassword({ email: email, password: val('aPass') });
        if (r.error) { note('wrong email or password', true); return; }
        user = r.data && r.data.user ? r.data.user : null;
        afterSignIn();
        return;
      }

      if (authMode === 'reset') {
        if (!pendingReset || pendingReset.email !== email) {
          note('send a reset code to this email first', true); return;
        }
        var done = await pendingReset.updateUser({ nonce: val('aCode'), password: val('aPass') });
        if (done.error) { note(done.error.message, true); return; }
        pendingReset = null;
        note('password updated');
        closeAuth();
        return;
      }

      /* OTP login / verified signup share one challenge. */
      if (!pendingOtp || pendingOtp.email !== email) {
        note('get a code for this email first', true); return;
      }
      var res = await cloud.auth.verifyOtp({
        email: pendingOtp.email,
        verificationId: pendingOtp.verificationId,
        isExistingUser: pendingOtp.isExistingUser,
        token: val('aCode'),
        password: pendingOtp.isExistingUser ? undefined : val('aPass')
      });
      if (res.error) { note(res.error.message, true); return; }
      pendingOtp = null;
      user = res.data && res.data.user ? res.data.user : null;
      afterSignIn();
    } catch (e) {
      note('sign-in failed: ' + e.message, true);
    }
  }

  function afterSignIn() {
    closeAuth();
    paintState();
    note('signed in');
    armAutoPush();
    /* First sync after login: take whatever the cloud has if we are empty. */
    pull(true);
  }

  /* -------------------------------------------------------------- sync --- */
  async function session() {
    if (!ready()) return null;
    var s = await cloud.auth.getSession();
    if (s.error || !s.data) return null;
    user = s.data.user || user;
    return s.data;
  }

  /* ------------------------------------------------------- auto uploads --
   * Once signed in, local edits upload on a debounce, so a phone and a PC
   * converge without the user pressing Upload. Downloads set `suppress` so a
   * pulled snapshot is not immediately echoed back to the cloud.
   */
  var autoArmed = false, suppress = false, debounce = null;

  function armAutoPush() {
    if (autoArmed || typeof Store === 'undefined') return;
    autoArmed = true;
    Store.onChange(function (reason) {
      if (suppress || reason === 'replace') return;
      clearTimeout(debounce);
      debounce = setTimeout(function () { push(true); }, 1500);
    });
  }

  async function push(silent) {
    var s = await session();
    if (!s) { if (!silent) openAuth('password'); return; }
    var payload = Store.raw();
    try {
      var mine = await cloud.database.from('sync_state')
        .select('id').limit(1);
      if (mine.error) { note(mine.error.message, true); return; }

      var row = mine.data && mine.data[0];
      var res;
      if (row) {
        res = await cloud.database.from('sync_state')
          .update({ payload: payload, updated_at: new Date().toISOString() })
          .eq('id', row.id).select();
      } else {
        res = await cloud.database.from('sync_state')
          .insert({ payload: payload }).select();
      }
      if (res.error) { note(res.error.message, true); return; }
      if (!res.data || !res.data.length) { note('nothing written - check sign-in', true); return; }
      note('uploaded ' + new Date().toLocaleTimeString());
    } catch (e) {
      note('upload failed: ' + e.message, true);
    }
  }

  async function pull(silent) {
    var s = await session();
    if (!s) { if (!silent) openAuth('password'); return; }
    try {
      var res = await cloud.database.from('sync_state')
        .select('payload,updated_at').limit(1);
      if (res.error) { note(res.error.message, true); return; }
      if (!res.data || !res.data.length) {
        if (!silent) note('no cloud copy yet');
        return;
      }
      var p = res.data[0].payload;
      if (!p || !Array.isArray(p.events) || !Array.isArray(p.tasks)) {
        note('cloud copy looks invalid', true); return;
      }
      suppress = true;
      try {
        Store.replaceAll(p);
      } finally {
        suppress = false;
      }
      if (window.App) App.render();
      note('downloaded');
    } catch (e) {
      note('download failed: ' + e.message, true);
    }
  }

  async function signOut() {
    if (!ready()) return;
    await cloud.auth.signOut();
    user = null;
    paintState();
    note('signed out');
  }

  /* ------------------------------------------------------------ wiring --- */
  function handle(act) {
    if (act === 'sync-signin') { openAuth('password'); return true; }
    if (act === 'sync-push') { push(); return true; }
    if (act === 'sync-pull') { pull(false); return true; }
    if (act === 'sync-out') { signOut(); return true; }
    return false;
  }

  /* Tab clicks inside the auth sheet. */
  document.addEventListener('click', function (ev) {
    var b = ev.target.closest ? ev.target.closest('[data-authmode]') : null;
    if (!b) return;
    authMode = b.dataset.authmode;
    renderAuth();
  });

  window.CloudSync = {
    init: function () {
      if (!ready()) {
        note('cloud SDK unavailable', true);
        return;
      }
      session().then(function (s) {
        paintState();
        if (s) { armAutoPush(); pull(true); }
      }).catch(function () { paintState(); });
    },
    handle: handle,
    push: push,
    pull: pull,
    refreshBadge: paintState
  };
})();
