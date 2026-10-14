// Executes production ETS and the production empty JS signal; SDK boundaries are mocked.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const ts = require(path.resolve(process.argv[2] ?? 'node_modules/typescript'));
const repo = path.resolve(process.argv[3] ?? '.');
const source = fs.readFileSync(path.join(repo, 'ohos_support/webview/FluxdoWebViewSecurity.ets'), 'utf8');
const compiled = ts.transpileModule(source.replace(/^import .*;\r?\n/gm, ''), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true,
});
assert.equal(compiled.diagnostics.filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);

function native(api = 26, cookies = [], fail = false) {
  let reads = 0;
  const context = { exports: {}, Uint8Array, deviceInfo: { sdkApiVersion: api }, url: { URL },
    SslError: { Invalid: 0, HostMismatch: 1, DateInvalid: 2, Untrusted: 3 },
    webview: { WebCookieManager: { async fetchAllCookies(incognito) {
      assert.equal(incognito, false); reads++; if (fail) throw new Error('OS read failed'); return cookies;
    } } } };
  vm.runInNewContext(compiled.outputText, context);
  return { security: context.exports.default, reads: () => reads };
}
const leaf = new Uint8Array([48, 1, 2]);
const ssl = { url: 'https://EXAMPLE.com.:8443/resource', error: 3, certChainData: [leaf] };
const cookie = { domain: 'example.com', path: '/', name: '_t', value: 'local-http-only',
  expiresDate: new Date(Date.now() + 3600000).toUTCString(), isSessionCookie: false,
  isHttpOnly: true, isSecure: true, samesitePolicy: 1 };
let passed = 0;
async function test(name, run) { await run(); passed++; process.stdout.write('passed: ' + name + '\n'); }

await test('MITM capability query retains direct connections below API 20', () => {
  for (const api of [18, 19]) assert.equal(native(api).security.supportsBoundLeaf(), false);
  for (const api of [20, 23, 26]) assert.equal(native(api).security.supportsBoundLeaf(), true);
});

await test('bind failing event URL, canonical DNS and exact first DER', () => {
  const result = native().security.leafChallenge(ssl);
  assert.equal(result.host, 'example.com'); assert.equal(result.port, 8443);
  assert.deepEqual([...result.leaf], [...leaf]); assert.notEqual(result.leaf, leaf);
  const unrelatedCurrentPage = 'https://example.com';
  assert.equal(native().security.leafChallenge({ ...ssl, url: 'https://other.com', currentPage: unrelatedCurrentPage }).host, 'other.com');
});
await test('API 18/19 missing URL-to-DER capability refuses', () => {
  for (const api of [18, 19]) assert.equal(native(api).security.leafChallenge(ssl), null);
});
await test('host mismatch, invalid date and generic error refuse', () => {
  for (const error of [0, 1, 2, 99]) assert.equal(native().security.leafChallenge({ ...ssl, error }), null);
});
await test('no chain/empty/oversized first leaf refuses; never searches other entries', () => {
  for (const chain of [undefined, [], [new Uint8Array()], [new Uint8Array(16385)], [new Uint8Array(), leaf]])
    assert.equal(native().security.leafChallenge({ ...ssl, certChainData: chain }), null);
});
await test('http, credentials, IP, Unicode and malformed DNS refuse', () => {
  for (const target of ['http://example.com', 'https://u:p@example.com', 'https://127.0.0.1',
    'https://[::1]', 'https://bad_name.com', 'https://-bad.com', 'https://bad.com..'])
    assert.equal(native().security.leafChallenge({ ...ssl, url: target }), null);
  assert.equal(native().security.dnsHost('é.com'), null);
  assert.throws(() => native().security.leafChallenge({ ...ssl, url: '' }));
});
await test('API 23 native metadata includes HttpOnly, expiry and same-site', async () => {
  const e = native(23, [cookie]); const result = await e.security.cookiesForUrl('https://example.com/topic');
  assert.equal(result.length, 1); assert.equal(result[0].get('value'), 'local-http-only');
  assert.equal(result[0].get('isHttpOnly'), true); assert.equal(result[0].get('sameSite'), 'Lax');
  assert.equal(result[0].get('domain'), 'example.com'); assert.equal(result[0].get('path'), '/');
  assert.ok(result[0].get('expiresDate') > Date.now()); assert.equal(e.reads(), 1);
});
await test('domain cookie subdomains allowed; host-only and suffix attacks excluded', async () => {
  const e = native(26, [cookie, { ...cookie, domain: '.example.com', name: 'shared' },
    { ...cookie, domain: '.evil-example.com', name: 'evil' }]);
  const result = await e.security.cookiesForUrl('https://sub.example.com/');
  assert.deepEqual(result.map(c => c.get('name')).join(','), 'shared');
  assert.equal((await e.security.cookiesForUrl('https://example.com.evil/')).length, 0);
});
await test('RFC path boundaries, secure and expiry filtering', async () => {
  const e = native(26, [{ ...cookie, path: '/topic', name: 'topic' },
    { ...cookie, expiresDate: 'bad date', name: 'bad' },
    { ...cookie, expiresDate: new Date(Date.now() - 1000).toUTCString(), name: 'old' },
    { ...cookie, path: 'topic', name: 'invalid' }]);
  assert.equal((await e.security.cookiesForUrl('https://example.com/topics')).length, 0);
  assert.equal((await e.security.cookiesForUrl('http://example.com/topic')).length, 0);
  assert.equal((await e.security.cookiesForUrl('https://example.com/topic/1')).length, 1);
});
await test('session cookie retains native attributes without invented expiry', async () => {
  const result = await native(26, [{ ...cookie, isSessionCookie: true, expiresDate: '' }]).security.cookiesForUrl('https://example.com/');
  assert.equal(result[0].get('expiresDate'), null); assert.equal(result[0].get('isSessionOnly'), true);
});
await test('API <23 has conservative low-confidence fallback and never calls missing API', async () => {
  const e = native(22, [cookie]); assert.equal(await e.security.cookiesForUrl('https://example.com'), null); assert.equal(e.reads(), 0);
});
await test('native cookie read failure propagates; no fabricated metadata fallback', async () => {
  await assert.rejects(native(26, [], true).security.cookiesForUrl('https://example.com/'));
});

const dart = fs.readFileSync(path.join(repo, 'lib/services/webview_settings.dart'), 'utf8');
const signalSource = dart.match(/static const _ohosCookieSignalJs = r'''([\s\S]*?)''';/)[1];
function browser(ready = true) {
  const events = new Map(), calls = [];
  let response = { body: 'private body', headers: 'private headers' };
  let failure;
  class Xhr {
    addEventListener(name, callback) { this[name] = callback; }
    send() { return 'original-send'; }
  }
  const window = { addEventListener: (name, cb) => events.set(name, cb), XMLHttpRequest: Xhr,
    fetch: function (...args) { assert.equal(this, window); return failure ? Promise.reject(failure) : Promise.resolve(response); },
    flutter_inappwebview: ready ? { _platformReady: true, callHandler(...args) { calls.push(args); return new Promise(() => {}); } } : undefined };
  vm.runInNewContext(signalSource, { window, Promise });
  return { window, events, calls, ready() { window.flutter_inappwebview = { callHandler(...args) { calls.push(args); return Promise.resolve(); } }; events.get('flutterInAppWebViewPlatformReady')(); },
    response, fail(error) { failure = error; } };
}
await test('fetch keeps response/error and does not await bridge or transmit data', async () => {
  const e = browser(); assert.equal(await e.window.fetch('/request'), e.response);
  await Promise.resolve(); assert.deepEqual(e.calls, [['onOhosCookieResponse']]);
  const error = new Error('original-fetch'); e.fail(error); await assert.rejects(e.window.fetch('/request'), x => x === error);
  assert.equal(e.calls.length, 2); assert.equal(e.calls[1].length, 1);
});
await test('XHR signal preserves send and only sends empty completion', async () => {
  const e = browser(); const xhr = new e.window.XMLHttpRequest();
  assert.equal(xhr.send('private payload'), 'original-send'); xhr.loadend(); await Promise.resolve();
  assert.deepEqual(e.calls, [['onOhosCookieResponse']]);
});
await test('responses before platform ready remain pending and coalesce', async () => {
  const e = browser(false); await e.window.fetch('/first'); await e.window.fetch('/second');
  assert.equal(e.calls.length, 0); e.ready(); await Promise.resolve(); assert.equal(e.calls.length, 1);
});
await test('document load also signals once; reinjection does not wrap fetch twice', async () => {
  const e = browser(); const fetch = e.window.fetch;
  vm.runInNewContext(signalSource, { window: e.window, Promise }); assert.equal(e.window.fetch, fetch);
  e.events.get('load')(); await Promise.resolve(); assert.deepEqual(e.calls, [['onOhosCookieResponse']]);
});
process.stdout.write(`OHOS production WebView boundary checks passed: ${passed} groups (OS mocked)\n`);
