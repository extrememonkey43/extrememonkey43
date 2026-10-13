import Foundation

/// JavaScript injected at document start into play.geforcenow.com.
///
/// What it does, in order:
/// 1. Identity: GeForce NOW only streams on iPad from a Home Screen web app, so Sedef reports
///    `navigator.standalone` (or, experimentally, looks like Mac Safari). Only on geforcenow.com;
///    sign-in pages keep the plain iPad Safari.
/// 2. Session request: GeForce NOW asks its servers for a stream with a POST to
///    `https://<zone>.nvidiagrid.net/v2/session`. The body carries
///    `sessionRequestData.clientRequestMonitorSettings[0].framesPerSecond`. We rewrite that
///    (and optionally the resolution), and on that request present the device headers
///    (`nv-device-os`, `nv-device-type`, `nv-browser-type`, …) as a Windows PC with Chrome,
///    because the server caps iPad/Safari clients at 60 FPS. Desktop tools use the same trick.
/// 3. Fullscreen shim (Mac identity): the app is already full screen, but desktop GFN calls
///    `requestFullscreen()`, which WKWebView on iPad doesn't expose.
/// 4. Text entry: tells the app when a text field is focused, so it can offer its own text
///    prompt when the iPad keyboard doesn't come up, and fills the field with the result.
/// 5. Stats: reads WebRTC stats once a second and posts them to the native HUD.
enum GFNScript {
    /// Builds the user script. `config` is serialized to JSON and handed to the IIFE.
    static func source(config: [String: Any]) -> String {
        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            json = text
        } else {
            json = "{}"
        }
        return core + "(" + json + ");"
    }

    // The body is a function expression; `source(config:)` appends the call.
    // Kept free of `\#(` and `"""#` so it can live in a raw string literal.
    static let core = #"""
(function (CFG) {
  'use strict';
  if (window.__sedefInstalled) return;
  try { Object.defineProperty(window, '__sedefInstalled', { value: true }); } catch (e) {}

  CFG = CFG || {};
  // The identity is only for GeForce NOW itself; sign-in pages keep the plain iPad Safari.
  var onGeForceNow = /(^|\.)geforcenow\.com$/i.test(location.hostname);
  var desktop = onGeForceNow && CFG.identity === 'macSafari';

  function post(type, payload) {
    try {
      window.webkit.messageHandlers.sedef.postMessage({ type: type, payload: payload === undefined ? null : payload });
    } catch (e) {}
  }

  function override(target, prop, value) {
    try {
      Object.defineProperty(target, prop, { configurable: true, enumerable: true, get: function () { return value; } });
    } catch (e) {}
  }

  /* ---------- 1. Identity ---------- */
  // GeForce NOW fingerprints the engine and treats a Chrome/Windows disguise on WebKit as forged
  // (it then refuses to stream), so only the checks of its own iPad and Mac Safari paths change.
  var navProto = window.Navigator && window.Navigator.prototype;
  if (navProto && onGeForceNow) {
    if (desktop) {
      // Mac Safari: GeForce NOW tells iPad from Mac by touch points.
      override(navProto, 'maxTouchPoints', 0);
      override(navProto, 'platform', 'MacIntel');
      if (!window.safari) {
        try {
          Object.defineProperty(window, 'safari', {
            configurable: true,
            value: { pushNotification: { permission: function () { return { permission: 'default' }; }, requestPermission: function () {} } }
          });
        } catch (e) {}
      }
    } else {
      // iPad: GeForce NOW only streams from a Home Screen web app, which it detects through
      // navigator.standalone. Sedef is full screen anyway.
      override(navProto, 'standalone', true);
    }
  }

  /* ---------- 2. Session request ---------- */
  function parseUrl(url) {
    try { return new URL(String(url), location.href); } catch (e) { return null; }
  }
  function isGridApi(url) {
    var u = parseUrl(url);
    return !!u && /(^|\.)nvidiagrid\.net$/i.test(u.hostname) && /^\/v2\//i.test(u.pathname);
  }
  function isSessionUrl(url) {
    var u = parseUrl(url);
    return !!u && /(^|\.)nvidiagrid\.net$/i.test(u.hostname) && /^\/v2\/session/i.test(u.pathname);
  }

  function rewriteBody(text) {
    var wantFps = CFG.fps > 0;
    var wantSize = CFG.width > 0 && CFG.height > 0;
    if (typeof text !== 'string' || (!wantFps && !wantSize)) return null;
    var trimmed = text.trim();
    if (trimmed.charAt(0) !== '{') return null;
    var body;
    try { body = JSON.parse(trimmed); } catch (e) { return null; }
    var srd = body && body.sessionRequestData;
    if (!srd || typeof srd !== 'object' || !('clientRequestMonitorSettings' in srd)) return null;

    var list = Array.isArray(srd.clientRequestMonitorSettings) ? srd.clientRequestMonitorSettings : [];
    var first = list[0] && typeof list[0] === 'object' ? list[0] : null;
    var monitor = Object.assign({
      widthInPixels: 1920,
      heightInPixels: 1080,
      framesPerSecond: 60,
      displayData: null,
      dpi: 0,
      hdr10PlusGamingData: null,
      monitorId: 0,
      positionX: 0,
      positionY: 0,
      sdrHdrMode: 0
    }, first || {});
    if (wantFps) monitor.framesPerSecond = CFG.fps;
    if (wantSize) {
      monitor.widthInPixels = CFG.width;
      monitor.heightInPixels = CFG.height;
    }
    srd.clientRequestMonitorSettings = [monitor];

    post('session', {
      width: monitor.widthInPixels,
      height: monitor.heightInPixels,
      fps: monitor.framesPerSecond,
      before: first ? { width: first.widthInPixels, height: first.heightInPixels, fps: first.framesPerSecond } : null
    });
    return JSON.stringify(body);
  }

  // Device headers GFN's servers use to pick what a client may stream. On iPad they say
  // IPADOS / TABLET / SAFARI / APPLE, which caps the stream at 60 FPS. CFG.serverProfile:
  //   'ipad'          leave them alone
  //   'windowsOS'     nv-device-os: WINDOWS
  //   'windowsChrome' a Windows PC running Chrome on the session request (default)
  // Values: null removes the header. Only the session request gets headers added when missing:
  // adding custom headers elsewhere could trigger a CORS preflight the server rejects.
  var CHROME_VERSION = '140.0.0.0';
  function headerOverrides(isSession) {
    var profile = CFG.serverProfile || 'ipad';
    if (profile === 'ipad') return {};
    var overrides = { 'nv-device-os': 'WINDOWS' };
    if (profile === 'windowsChrome' && isSession) {
      overrides['nv-device-type'] = 'DESKTOP';
      overrides['nv-browser-type'] = 'CHROME';
      overrides['nv-browser-version'] = CHROME_VERSION;
      overrides['nv-device-make'] = null;
      overrides['nv-device-model'] = null;
    }
    return overrides;
  }
  // Headers that are only rewritten when GFN sends them (never added).
  var REPLACE_ONLY = { 'nv-browser-version': true };

  function rewriteHeaders(source, isSession) {
    var headers = new Headers(source == null ? undefined : source);
    var overrides = headerOverrides(isSession);
    Object.keys(overrides).forEach(function (name) {
      var value = overrides[name];
      if (value === null) headers.delete(name);
      else if (headers.has(name) || (isSession && !REPLACE_ONLY[name])) headers.set(name, value);
    });
    return headers;
  }

  function bodyToText(body) {
    if (body == null) return Promise.resolve(null);
    if (typeof body === 'string') return Promise.resolve(body);
    try {
      if (body instanceof ArrayBuffer || ArrayBuffer.isView(body)) return Promise.resolve(new TextDecoder().decode(body));
      if (typeof Blob !== 'undefined' && body instanceof Blob) return body.text();
    } catch (e) {}
    return Promise.resolve(null);
  }

  var nativeFetch = window.fetch;
  if (typeof nativeFetch === 'function') {
    var patchedFetch = async function (input, init, url) {
      var isRequest = typeof Request !== 'undefined' && input instanceof Request;
      var options = Object.assign({}, init || {});
      var headerSource = init && init.headers !== undefined ? init.headers : (isRequest ? input.headers : undefined);
      var session = isSessionUrl(url);
      options.headers = rewriteHeaders(headerSource, session);

      if (session) {
        var text = null;
        if (init && init.body != null) {
          text = await bodyToText(init.body);
        } else if (isRequest && !/^(GET|HEAD)$/i.test(input.method)) {
          text = await input.clone().text();
        }
        var patched = rewriteBody(text);
        if (patched !== null) options.body = patched;
      }
      return isRequest ? nativeFetch.call(window, new Request(input, options)) : nativeFetch.call(window, input, options);
    };

    window.fetch = function fetch(input, init) {
      var url = '';
      try { url = input && typeof input === 'object' && 'url' in input ? input.url : String(input); } catch (e) {}
      if (!isGridApi(url)) return nativeFetch.apply(this, arguments);
      var args = arguments, self = this;
      return patchedFetch(input, init, url).catch(function (error) {
        post('log', 'fetch rewrite failed: ' + error);
        return nativeFetch.apply(self, args);
      });
    };
  }

  var xhrProto = window.XMLHttpRequest && window.XMLHttpRequest.prototype;
  if (xhrProto) {
    var flags = new WeakMap();
    var xhrOpen = xhrProto.open;
    var xhrSend = xhrProto.send;
    var xhrSetHeader = xhrProto.setRequestHeader;

    xhrProto.open = function (method, url) {
      try {
        var session = isSessionUrl(url);
        flags.set(this, { api: isGridApi(url), session: session, overrides: headerOverrides(session), sent: {} });
      } catch (e) {}
      return xhrOpen.apply(this, arguments);
    };
    xhrProto.setRequestHeader = function (name, value) {
      var f = flags.get(this);
      var key = String(name).toLowerCase();
      if (f && f.api && Object.prototype.hasOwnProperty.call(f.overrides, key)) {
        f.sent[key] = true;
        if (f.overrides[key] === null) return;
        value = f.overrides[key];
      }
      return xhrSetHeader.call(this, name, value);
    };
    xhrProto.send = function (body) {
      var f = flags.get(this);
      if (f && f.api) {
        if (f.session) {
          for (var key in f.overrides) {
            if (f.overrides[key] !== null && !f.sent[key] && !REPLACE_ONLY[key]) {
              try { xhrSetHeader.call(this, key, f.overrides[key]); } catch (e) {}
            }
          }
        }
        if (f.session && typeof body === 'string') {
          var patched = rewriteBody(body);
          if (patched !== null) body = patched;
        }
      }
      return xhrSend.call(this, body);
    };
  }

  /* ---------- 3. Fullscreen shim (desktop identities only) ---------- */
  var elementProto = window.Element && window.Element.prototype;
  var documentProto = window.Document && window.Document.prototype;
  if (desktop && elementProto && documentProto && typeof elementProto.requestFullscreen !== 'function') {
    var fullscreenElement = null;
    var setFullscreen = function (element) {
      fullscreenElement = element;
      try { document.dispatchEvent(new Event('fullscreenchange')); } catch (e) {}
    };
    elementProto.requestFullscreen = function () { setFullscreen(this); return Promise.resolve(); };
    documentProto.exitFullscreen = function () { setFullscreen(null); return Promise.resolve(); };
    override(documentProto, 'fullscreenEnabled', true);
    try {
      Object.defineProperty(documentProto, 'fullscreenElement', { configurable: true, get: function () { return fullscreenElement; } });
      Object.defineProperty(documentProto, 'fullscreen', { configurable: true, get: function () { return fullscreenElement !== null; } });
    } catch (e) {}
  }

  /* ---------- 4. No callouts / selection on the stream ---------- */
  var addStyle = function () {
    try {
      var style = document.createElement('style');
      style.textContent = 'video, canvas { -webkit-touch-callout: none !important; -webkit-user-select: none !important; user-select: none !important; }';
      (document.head || document.documentElement).appendChild(style);
    } catch (e) {}
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', addStyle, { once: true });
  else addStyle();

  /* ---------- 5. Text entry bridge ---------- */
  // If the iPad keyboard doesn't come up for a web text field, the app offers its own text
  // prompt and puts the result into the field through window.__sedefInsertText.
  var lastEditable = null;
  function isEditable(el) {
    if (!el || el.disabled || el.readOnly) return false;
    if (el.isContentEditable) return true;
    if (el.tagName === 'TEXTAREA') return true;
    return el.tagName === 'INPUT' && /^(text|email|password|search|tel|url|number)?$/i.test(el.getAttribute('type') || '');
  }
  function isVisible(el) {
    try {
      var r = el.getBoundingClientRect();
      return r.width >= 20 && r.height >= 10 && r.bottom > 0 && r.right > 0;
    } catch (e) { return false; }
  }
  document.addEventListener('focusin', function (e) {
    var el = e.target;
    if (!isEditable(el) || !isVisible(el)) return;
    lastEditable = el;
    var type = el.isContentEditable ? 'text' : (el.tagName === 'TEXTAREA' ? 'textarea' : String(el.type || 'text').toLowerCase());
    post('editFocus', {
      type: type,
      value: type === 'password' || el.isContentEditable ? '' : String(el.value || ''),
      label: el.getAttribute('placeholder') || el.getAttribute('aria-label') || ''
    });
  }, true);
  document.addEventListener('focusout', function (e) {
    if (e.target === lastEditable) post('editBlur', null);
  }, true);
  try {
    Object.defineProperty(window, '__sedefInsertText', {
      value: function (text) {
        var el = lastEditable;
        if (!el || !el.isConnected) return false;
        try { el.focus({ preventScroll: true }); } catch (e) {}
        if (el.isContentEditable) return document.execCommand('insertText', false, text);
        // Use the native setter so frameworks (Angular, React) notice the change.
        var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, text);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
      }
    });
  } catch (e) {}

  /* ---------- 6. Passkey autofill off ---------- */
  // Passkeys can't work in an app's web view without Apple entitlements. Sign-in pages that ask
  // for passkey autofill (autocomplete="webauthn") get a request that stays pending, which is
  // what happens when the user doesn't pick a passkey, and that rejects when the page aborts it.
  try {
    if (window.PublicKeyCredential && typeof window.PublicKeyCredential.isConditionalMediationAvailable === 'function') {
      window.PublicKeyCredential.isConditionalMediationAvailable = function () { return Promise.resolve(false); };
    }
    var credentials = navigator.credentials;
    if (credentials && typeof credentials.get === 'function') {
      var credentialsGet = credentials.get;
      credentials.get = function (options) {
        if (options && options.mediation === 'conditional') {
          var signal = options.signal;
          return new Promise(function (resolve, reject) {
            var abort = function () {
              reject(signal && signal.reason !== undefined ? signal.reason : new DOMException('The operation was aborted.', 'AbortError'));
            };
            if (!signal) return;
            if (signal.aborted) abort();
            else signal.addEventListener('abort', abort, { once: true });
          });
        }
        return credentialsGet.apply(this, arguments);
      };
    }
  } catch (e) {}

  /* ---------- 7. Stream stats for the HUD ---------- */
  var peers = [];
  var PC = window.RTCPeerConnection;
  if (PC && PC.prototype) {
    ['setRemoteDescription', 'setLocalDescription'].forEach(function (name) {
      var original = PC.prototype[name];
      if (typeof original !== 'function') return;
      PC.prototype[name] = function () {
        if (peers.indexOf(this) === -1) peers.push(this);
        return original.apply(this, arguments);
      };
    });
  }

  var previous = new WeakMap();
  var tracked = { video: null, presented: null, lastCount: null, lastTime: 0 };

  function pickVideo() {
    var best = null, bestArea = 0;
    var videos = document.getElementsByTagName('video');
    for (var i = 0; i < videos.length; i++) {
      var v = videos[i];
      var area = (v.videoWidth || 0) * (v.videoHeight || 0);
      if (!v.paused && area > bestArea) { best = v; bestArea = area; }
    }
    return best;
  }

  function track(video) {
    if (video === tracked.video) return;
    tracked = { video: video, presented: null, lastCount: null, lastTime: 0 };
    if (!video || typeof video.requestVideoFrameCallback !== 'function') return;
    var onFrame = function (now, meta) {
      if (tracked.video !== video) return;
      tracked.presented = meta.presentedFrames;
      video.requestVideoFrameCallback(onFrame);
    };
    video.requestVideoFrameCallback(onFrame);
  }

  // Frames that actually reached the screen per second. Counted from presentedFrames, so it stays
  // correct even if the page's own callbacks are throttled to 60 Hz.
  function presentedFps(video, now) {
    if (!video) return null;
    var count = null;
    if (typeof video.requestVideoFrameCallback === 'function') {
      count = tracked.presented;
    } else if (typeof video.getVideoPlaybackQuality === 'function') {
      var q = video.getVideoPlaybackQuality();
      count = q.totalVideoFrames - q.droppedVideoFrames;
    }
    if (count === null) return null;
    var fps = null;
    if (tracked.lastCount !== null && now > tracked.lastTime) {
      fps = (count - tracked.lastCount) / ((now - tracked.lastTime) / 1000);
    }
    tracked.lastCount = count;
    tracked.lastTime = now;
    return fps;
  }

  async function collect() {
    if (document.hidden) return;
    var video = pickVideo();
    track(video);
    var now = performance.now();
    peers = peers.filter(function (pc) { return pc.connectionState !== 'closed' && pc.signalingState !== 'closed'; });

    var stats = null;
    for (var i = 0; i < peers.length && !stats; i++) {
      var pc = peers[i], report;
      try { report = await pc.getStats(); } catch (e) { continue; }
      var inbound = null, codecs = {}, pairs = {}, selectedPairId = null;
      report.forEach(function (s) {
        if (s.type === 'inbound-rtp' && (s.kind === 'video' || s.mediaType === 'video')) {
          if (!inbound || (s.bytesReceived || 0) > (inbound.bytesReceived || 0)) inbound = s;
        } else if (s.type === 'codec') {
          codecs[s.id] = s;
        } else if (s.type === 'candidate-pair') {
          pairs[s.id] = s;
        } else if (s.type === 'transport' && s.selectedCandidatePairId) {
          selectedPairId = s.selectedCandidatePairId;
        }
      });
      if (!inbound) continue;

      var pair = selectedPairId ? pairs[selectedPairId] : null;
      if (!pair) {
        Object.keys(pairs).forEach(function (id) {
          if (pairs[id].nominated && pairs[id].state === 'succeeded') pair = pairs[id];
        });
      }
      var prev = previous.get(pc);
      var dt = prev ? (now - prev.time) / 1000 : 0;
      previous.set(pc, {
        time: now,
        bytes: inbound.bytesReceived || 0,
        decoded: inbound.framesDecoded || 0,
        dropped: inbound.framesDropped || 0
      });
      var codec = codecs[inbound.codecId];
      stats = {
        fps: typeof inbound.framesPerSecond === 'number'
          ? inbound.framesPerSecond
          : (dt > 0 ? ((inbound.framesDecoded || 0) - prev.decoded) / dt : null),
        width: inbound.frameWidth || (video && video.videoWidth) || null,
        height: inbound.frameHeight || (video && video.videoHeight) || null,
        codec: codec && codec.mimeType ? codec.mimeType.replace(/^video\//i, '') : null,
        mbps: dt > 0 ? (((inbound.bytesReceived || 0) - prev.bytes) * 8) / dt / 1e6 : null,
        rttMs: pair && typeof pair.currentRoundTripTime === 'number' ? pair.currentRoundTripTime * 1000 : null,
        lost: inbound.packetsLost || 0,
        droppedPerSec: dt > 0 ? ((inbound.framesDropped || 0) - prev.dropped) / dt : null
      };
    }

    var shown = presentedFps(video, now);
    if (!stats && !video) { post('stats', null); return; }
    stats = stats || {
      width: video.videoWidth || null,
      height: video.videoHeight || null
    };
    stats.presentedFps = shown;
    post('stats', stats);
  }

  setInterval(function () { collect().catch(function () {}); }, 1000);
})
"""#
}
