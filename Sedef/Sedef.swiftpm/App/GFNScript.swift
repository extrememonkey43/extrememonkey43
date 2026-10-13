import Foundation

/// JavaScript injected at document start into play.geforcenow.com.
///
/// What it does, in order:
/// 1. Identity: makes the page believe it runs on a desktop (Windows/Chrome or Mac/Safari),
///    so GeForce NOW stops applying its iPad/Safari limits (60 FPS, 1600×1200, H.264 only).
/// 2. Session request: GeForce NOW asks its servers for a stream with a POST to
///    `https://<zone>.nvidiagrid.net/v2/session`. The body carries
///    `sessionRequestData.clientRequestMonitorSettings[0].framesPerSecond`. We rewrite that
///    (and optionally the resolution) and report the device OS as WINDOWS in the
///    `nv-device-os` header. This is the same trick desktop tools use, done inside the page.
/// 3. Fullscreen shim: the app is already full screen, but desktop GFN calls
///    `requestFullscreen()`, which WKWebView on iPad doesn't expose.
/// 4. Stats: reads WebRTC stats once a second and posts them to the native HUD.
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
  var desktop = CFG.identity === 'windowsChrome' || CFG.identity === 'macSafari';

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
  var navProto = window.Navigator && window.Navigator.prototype;
  if (navProto && desktop) {
    // iPadOS already reports a Mac user agent; GFN spots the iPad through touch points.
    override(navProto, 'maxTouchPoints', 0);
    override(navProto, 'platform', CFG.identity === 'windowsChrome' ? 'Win32' : 'MacIntel');
  }
  if (navProto && CFG.identity === 'windowsChrome') {
    var major = String(CFG.chromeMajor || '140');
    var brands = [
      { brand: 'Chromium', version: major },
      { brand: 'Google Chrome', version: major },
      { brand: 'Not=A?Brand', version: '24' }
    ];
    var fullVersion = major + '.0.0.0';
    var uaData = {
      brands: brands,
      mobile: false,
      platform: 'Windows',
      getHighEntropyValues: function () {
        return Promise.resolve({
          brands: brands,
          mobile: false,
          platform: 'Windows',
          platformVersion: '15.0.0',
          architecture: 'x86',
          bitness: '64',
          model: '',
          wow64: false,
          uaFullVersion: fullVersion,
          fullVersionList: brands.map(function (b) {
            return { brand: b.brand, version: b.brand === 'Not=A?Brand' ? '24.0.0.0' : fullVersion };
          })
        });
      },
      toJSON: function () { return { brands: brands, mobile: false, platform: 'Windows' }; }
    };
    override(navProto, 'vendor', 'Google Inc.');
    override(navProto, 'userAgentData', uaData);
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

  // Replace the OS header wherever GFN sends it. Only the session request gets it added when
  // missing: adding a custom header elsewhere could trigger a CORS preflight the server rejects.
  function rewriteHeaders(source, isSession) {
    var headers = new Headers(source == null ? undefined : source);
    if (CFG.reportWindows && (isSession || headers.has('nv-device-os'))) headers.set('nv-device-os', 'WINDOWS');
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
      try { flags.set(this, { api: isGridApi(url), session: isSessionUrl(url) }); } catch (e) {}
      return xhrOpen.apply(this, arguments);
    };
    xhrProto.setRequestHeader = function (name, value) {
      var f = flags.get(this);
      if (f && f.api && CFG.reportWindows && String(name).toLowerCase() === 'nv-device-os') {
        f.sentOs = true;
        value = 'WINDOWS';
      }
      return xhrSetHeader.call(this, name, value);
    };
    xhrProto.send = function (body) {
      var f = flags.get(this);
      if (f && f.api) {
        if (CFG.reportWindows && f.session && !f.sentOs) {
          try { xhrSetHeader.call(this, 'nv-device-os', 'WINDOWS'); } catch (e) {}
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

  /* ---------- 5. Stream stats for the HUD ---------- */
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
