// Runs the JavaScript that Sedef injects into GeForce NOW against fake browser globals.
// Usage: node --test Sedef/tests
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const swift = readFileSync(new URL('../Sedef.swiftpm/App/GFNScript.swift', import.meta.url), 'utf8');
const match = swift.match(/static let core = #"""\n([\s\S]*?)\n"""#/);
assert.ok(match, 'could not find the script in GFNScript.swift');
const core = match[1];

const SESSION_URL = 'https://np-ams-06.cloudmatchbeta.nvidiagrid.net/v2/session?keyboardLayout=de-DE';

function sessionBody(monitor = { widthInPixels: 1600, heightInPixels: 1200, framesPerSecond: 60, sdrHdrMode: 0, dpi: 0 }) {
  return JSON.stringify({
    sessionRequestData: {
      appId: 100932911,
      clientRequestMonitorSettings: [monitor],
      requestedAudioFormat: 1
    }
  });
}

function makeWindow(config, pageUrl = 'https://play.geforcenow.com/mall/') {
  const fetchCalls = [];
  const messages = [];
  class Navigator {}
  for (const [prop, value] of Object.entries({ platform: 'MacIntel', maxTouchPoints: 5, vendor: 'Apple Computer, Inc.' })) {
    Object.defineProperty(Navigator.prototype, prop, { configurable: true, get: () => value });
  }
  class Element {}
  class HTMLInputElement extends Element {
    constructor(type = 'text', rect = { width: 300, height: 30, bottom: 400, right: 600 }) {
      super();
      this.tagName = 'INPUT';
      this.type = type;
      this.attrs = { type, placeholder: 'E-posta' };
      this.rect = rect;
      this.raw = '';
      this.events = [];
      this.isConnected = true;
      this.disabled = false;
      this.readOnly = false;
      this.isContentEditable = false;
    }
    getAttribute(name) { return name in this.attrs ? this.attrs[name] : null; }
    getBoundingClientRect() { return this.rect; }
    focus() { this.focused = true; }
    dispatchEvent(event) { this.events.push(event.type); return true; }
  }
  Object.defineProperty(HTMLInputElement.prototype, 'value', {
    configurable: true,
    get() { return this.raw; },
    set(v) { this.raw = String(v); }
  });
  class HTMLTextAreaElement extends HTMLInputElement {}
  class Document extends EventTarget {
    addEventListener(type, listener, options) {
      (this.listeners[type] ||= []).push(listener);
      super.addEventListener(type, listener, options);
    }
    fire(type, target) { for (const l of this.listeners[type] || []) l({ type, target }); }
  }
  const document = new Document();
  document.listeners = {};
  const credentialCalls = [];
  class PublicKeyCredential {
    static isConditionalMediationAvailable() { return Promise.resolve(true); }
  }
  Object.assign(document, {
    readyState: 'complete',
    hidden: false,
    head: { appendChild() {} },
    documentElement: { appendChild() {} },
    createElement: () => ({}),
    getElementsByTagName: () => []
  });

  class FakeXHR {
    constructor() { this.headers = {}; }
    open(method, url) { this.method = method; this.url = String(url); }
    setRequestHeader(name, value) { this.headers[name.toLowerCase()] = value; }
    send(body) { this.body = body; FakeXHR.sent.push(this); }
  }
  FakeXHR.sent = [];

  const window = {
    location: new URL(pageUrl),
    Navigator,
    navigator: new Navigator(),
    Element,
    HTMLInputElement,
    HTMLTextAreaElement,
    PublicKeyCredential,
    Document,
    document,
    XMLHttpRequest: FakeXHR,
    Request, Headers, Blob, TextDecoder, URL, Promise, JSON, Object, Array, String, WeakMap, ArrayBuffer, Event, DOMException,
    performance,
    setInterval: () => 0,
    console,
    webkit: { messageHandlers: { sedef: { postMessage: (m) => messages.push(m) } } },
    fetch: async (input, init) => {
      const req = new Request(input, init);
      fetchCalls.push({ url: req.url, headers: Object.fromEntries(req.headers), body: await req.text() });
      return { ok: true };
    }
  };
  window.navigator.credentials = { get: (options) => { credentialCalls.push(options); return Promise.resolve('credential'); } };
  window.window = window;
  vm.createContext(window);
  vm.runInContext(core + '(' + JSON.stringify(config) + ');', window);
  return { window, fetchCalls, messages, FakeXHR, credentialCalls };
}

const windowsConfig = { fps: 120, identity: 'windowsChrome', reportWindows: true, chromeMajor: '140' };

test('fetch: session request gets 120 FPS and the WINDOWS header', async () => {
  const { window, fetchCalls, messages } = makeWindow(windowsConfig);
  await window.fetch(SESSION_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'nv-device-os': 'IOS', 'nv-client-type': 'BROWSER' },
    body: sessionBody()
  });
  assert.equal(fetchCalls.length, 1);
  const sent = JSON.parse(fetchCalls[0].body);
  const monitor = sent.sessionRequestData.clientRequestMonitorSettings[0];
  assert.equal(monitor.framesPerSecond, 120);
  assert.equal(monitor.widthInPixels, 1600, 'resolution untouched when not configured');
  assert.equal(monitor.heightInPixels, 1200);
  assert.equal(sent.sessionRequestData.appId, 100932911, 'other fields untouched');
  assert.equal(fetchCalls[0].headers['nv-device-os'], 'WINDOWS');
  assert.equal(fetchCalls[0].headers['nv-client-type'], 'BROWSER');
  assert.equal(fetchCalls[0].headers['content-type'], 'application/json');
  const session = messages.find((m) => m.type === 'session');
  assert.deepEqual(JSON.parse(JSON.stringify(session.payload)), { width: 1600, height: 1200, fps: 120, before: { width: 1600, height: 1200, fps: 60 } });
});

test('fetch: Request object input with configured resolution', async () => {
  const { window, fetchCalls } = makeWindow({ ...windowsConfig, width: 2560, height: 1440 });
  const request = new window.Request(SESSION_URL, { method: 'POST', headers: { 'nv-device-os': 'MACOS' }, body: sessionBody() });
  await window.fetch(request);
  const monitor = JSON.parse(fetchCalls[0].body).sessionRequestData.clientRequestMonitorSettings[0];
  assert.deepEqual([monitor.widthInPixels, monitor.heightInPixels, monitor.framesPerSecond], [2560, 1440, 120]);
  assert.equal(fetchCalls[0].headers['nv-device-os'], 'WINDOWS');
});

test('fetch: empty monitor list gets a complete entry', async () => {
  const { window, fetchCalls } = makeWindow({ ...windowsConfig, width: 1920, height: 1080 });
  await window.fetch(SESSION_URL, { method: 'POST', body: JSON.stringify({ sessionRequestData: { clientRequestMonitorSettings: [] } }) });
  const monitor = JSON.parse(fetchCalls[0].body).sessionRequestData.clientRequestMonitorSettings[0];
  assert.equal(monitor.framesPerSecond, 120);
  assert.equal(monitor.widthInPixels, 1920);
  assert.equal(monitor.sdrHdrMode, 0);
});

test('fetch: ArrayBuffer body is rewritten too', async () => {
  const { window, fetchCalls } = makeWindow(windowsConfig);
  await window.fetch(SESSION_URL, { method: 'POST', body: new TextEncoder().encode(sessionBody()).buffer });
  const monitor = JSON.parse(fetchCalls[0].body).sessionRequestData.clientRequestMonitorSettings[0];
  assert.equal(monitor.framesPerSecond, 120);
});

test('fetch: other hosts and other GFN endpoints are left alone', async () => {
  const { window, fetchCalls } = makeWindow(windowsConfig);
  const body = sessionBody();
  await window.fetch('https://example.com/v2/session', { method: 'POST', body });
  await window.fetch('https://nvidiagrid.net.evil.com/v2/session', { method: 'POST', body });
  await window.fetch('https://prod.cloudmatchbeta.nvidiagrid.net/v2/serverInfo', { headers: { accept: 'application/json' } });
  assert.equal(fetchCalls[0].body, body);
  assert.equal(fetchCalls[1].body, body);
  assert.equal(fetchCalls[0].headers['nv-device-os'], undefined);
  assert.equal(fetchCalls[2].headers['nv-device-os'], undefined, 'header is not added outside the session request');
});

test('fetch: non-session JSON on the session URL is not touched', async () => {
  const { window, fetchCalls, messages } = makeWindow(windowsConfig);
  const body = JSON.stringify({ action: 2, sessionRequestData: { audioMode: 1 } });
  await window.fetch(SESSION_URL.replace('?', '/abc123?'), { method: 'PUT', body });
  assert.equal(fetchCalls[0].body, body);
  assert.equal(messages.filter((m) => m.type === 'session').length, 0);
});

test('iPad identity with fps "leave alone" changes nothing', async () => {
  const { window, fetchCalls } = makeWindow({ fps: 0, identity: 'iPad', reportWindows: false });
  const body = sessionBody();
  await window.fetch(SESSION_URL, { method: 'POST', headers: { 'nv-device-os': 'IOS' }, body });
  assert.equal(fetchCalls[0].body, body);
  assert.equal(fetchCalls[0].headers['nv-device-os'], 'IOS');
  assert.equal(window.navigator.maxTouchPoints, 5);
  assert.equal(window.navigator.platform, 'MacIntel');
});

test('XMLHttpRequest session request is rewritten', () => {
  const { window, FakeXHR } = makeWindow(windowsConfig);
  const xhr = new window.XMLHttpRequest();
  xhr.open('POST', SESSION_URL);
  xhr.setRequestHeader('nv-device-os', 'IOS');
  xhr.send(sessionBody());
  const sent = FakeXHR.sent[0];
  assert.equal(JSON.parse(sent.body).sessionRequestData.clientRequestMonitorSettings[0].framesPerSecond, 120);
  assert.equal(sent.headers['nv-device-os'], 'WINDOWS');

  const other = new window.XMLHttpRequest();
  other.open('GET', 'https://example.com/data');
  other.send(null);
  assert.deepEqual(FakeXHR.sent[1].headers, {});
});

test('Windows identity spoofs navigator and adds a fullscreen shim', async () => {
  const { window } = makeWindow(windowsConfig);
  const nav = window.navigator;
  assert.equal(nav.platform, 'Win32');
  assert.equal(nav.maxTouchPoints, 0);
  assert.equal(nav.vendor, 'Google Inc.');
  assert.equal(nav.userAgentData.platform, 'Windows');
  const high = await nav.userAgentData.getHighEntropyValues(['platformVersion']);
  assert.equal(high.uaFullVersion, '140.0.0.0');

  let changes = 0;
  window.document.addEventListener('fullscreenchange', () => changes++);
  const element = new window.Element();
  await element.requestFullscreen();
  assert.equal(window.document.fullscreenElement, element);
  assert.equal(window.document.fullscreenEnabled, true);
  await window.document.exitFullscreen();
  assert.equal(window.document.fullscreenElement, null);
  assert.equal(changes, 2);
});

test('script is idempotent', async () => {
  const { window, fetchCalls } = makeWindow(windowsConfig);
  vm.runInContext(core + '(' + JSON.stringify({ ...windowsConfig, fps: 60 }) + ');', window);
  await window.fetch(SESSION_URL, { method: 'POST', body: sessionBody() });
  assert.equal(JSON.parse(fetchCalls[0].body).sessionRequestData.clientRequestMonitorSettings[0].framesPerSecond, 120);
});

test('text bridge reports focused fields and fills them like typing', () => {
  const { window, messages } = makeWindow(windowsConfig);
  const email = new window.HTMLInputElement('email');
  window.document.fire('focusin', email);
  const focus = messages.filter((m) => m.type === 'editFocus');
  assert.equal(focus.length, 1);
  assert.equal(focus[0].payload.type, 'email');
  assert.equal(focus[0].payload.label, 'E-posta');

  assert.equal(window.__sedefInsertText('yusuf@example.com'), true);
  assert.equal(email.value, 'yusuf@example.com');
  assert.deepEqual(email.events, ['input', 'change']);
  assert.equal(email.focused, true);

  window.document.fire('focusout', email);
  assert.equal(messages.filter((m) => m.type === 'editBlur').length, 1);
});

test('text bridge never reports password values and ignores hidden fields', () => {
  const { window, messages } = makeWindow(windowsConfig);
  const password = new window.HTMLInputElement('password');
  password.value = 'secret';
  window.document.fire('focusin', password);
  assert.equal(messages.find((m) => m.type === 'editFocus').payload.value, '');

  const hidden = new window.HTMLInputElement('text', { width: 1, height: 1, bottom: 1, right: 1 });
  window.document.fire('focusin', hidden);
  const checkbox = new window.HTMLInputElement('checkbox');
  window.document.fire('focusin', checkbox);
  assert.equal(messages.filter((m) => m.type === 'editFocus').length, 1);
  assert.equal(window.__sedefInsertText('x'), true, 'still targets the password field');
  assert.equal(password.value, 'x');
});

test('passkey autofill requests stay pending; other credential requests pass through', async () => {
  const { window, credentialCalls } = makeWindow(windowsConfig);
  assert.equal(await window.PublicKeyCredential.isConditionalMediationAvailable(), false);
  const conditional = window.navigator.credentials.get({ mediation: 'conditional', publicKey: {} });
  const outcome = await Promise.race([conditional.then(() => 'settled'), new Promise((r) => setTimeout(() => r('pending'), 50))]);
  assert.equal(outcome, 'pending');
  assert.equal(await window.navigator.credentials.get({ publicKey: {} }), 'credential');
  assert.equal(credentialCalls.length, 1);
});

test('sign-in pages keep the real iPad identity but still get the text bridge', () => {
  const { window, messages } = makeWindow(windowsConfig, 'https://login.nvgs.nvidia.com/v1/login/identifier?locale=tr-TR');
  assert.equal(window.navigator.platform, 'MacIntel');
  assert.equal(window.navigator.maxTouchPoints, 5);
  assert.equal(window.navigator.vendor, 'Apple Computer, Inc.');
  assert.equal(window.navigator.userAgentData, undefined);
  assert.equal(typeof window.Element.prototype.requestFullscreen, 'undefined', 'no fullscreen shim off GFN');
  const email = new window.HTMLInputElement('email');
  window.document.fire('focusin', email);
  assert.equal(messages.filter((m) => m.type === 'editFocus').length, 1);
});

test('aborting a passkey autofill request rejects it', async () => {
  const { window } = makeWindow(windowsConfig, 'https://login.nvgs.nvidia.com/');
  const controller = new AbortController();
  const request = window.navigator.credentials.get({ mediation: 'conditional', signal: controller.signal, publicKey: {} });
  controller.abort();
  await assert.rejects(request, (error) => error.name === 'AbortError');
  const already = new AbortController();
  already.abort();
  await assert.rejects(window.navigator.credentials.get({ mediation: 'conditional', signal: already.signal }), (error) => error.name === 'AbortError');
});
