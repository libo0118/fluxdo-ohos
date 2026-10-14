import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const ts = require(path.resolve(process.argv[2]));
const repo = path.resolve(process.argv[3] ?? '.');
const source = fs.readFileSync(path.join(repo, 'ohos_support/notifications/FluxdoNotificationsPlugin.ets'), 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
assert.equal(compiled.diagnostics?.length ?? 0, 0);

let enabled = false, queryError = false, promptError = false, grantAfterPrompt = false;
let publishError = false, cancelError = false, backgroundError = false;
let queryCount = 0, promptCount = 0, nextTimer = 0, nextRequest = 10;
let holdPrompt = false, releasePrompt;
let immediateExpiry = false, delay = 180000;
const published = [], agents = [], cancellations = [], callbacks = new Map(), timers = new Map(), channels = [];
const manager = {
  SlotType: { SOCIAL_COMMUNICATION: 1, SERVICE_INFORMATION: 2 },
  ContentType: { NOTIFICATION_CONTENT_BASIC_TEXT: 0 },
  async isNotificationEnabled() { queryCount++; if (queryError) throw Error('query secret'); return enabled; },
  async requestEnableNotification(context) { assert.equal(context.abilityInfo.bundleName, 'com.github.molchuan.cfluxdo'); promptCount++; if (holdPrompt) await new Promise(resolve => { releasePrompt = resolve; }); if (promptError) throw Error('denied'); enabled = grantAfterPrompt; },
  async publish(request) { if (publishError) throw Error('private notification body'); published.push(request); },
  async cancel(id) { if (cancelError) throw Error('cancel secret'); cancellations.push(id); },
  async cancelAll() { if (cancelError) throw Error('cancel secret'); cancellations.push('all'); }
};
const bg = {
  requestSuspendDelay(reason, callback) {
    if (backgroundError) throw Error('quota exhausted');
    const requestId = nextRequest++;
    callbacks.set(requestId, callback);
    if (immediateExpiry) callback();
    return { requestId, actualDelayTime: delay };
  },
  cancelSuspendDelay(id) { cancellations.push(`bg:${id}`); if (cancelError) throw Error('cancel failed'); }
};
class MethodChannel {
  constructor(messenger, name) { this.name = name; this.events = []; channels.push(this); }
  setMethodCallHandler(handler) { this.handler = handler; }
  invokeMethod(method, args) { this.events.push({ method, args }); }
}
const module = { exports: {} };
vm.runInNewContext(compiled.outputText, {
  exports: module.exports, module,
  require(name) {
    if (name === '@ohos.notificationManager') return manager;
    if (name === '@ohos.app.ability.wantAgent') return {
      OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 4 },
      async getWantAgent(info) { agents.push(info); return { info }; }
    };
    if (name === '@ohos.resourceschedule.backgroundTaskManager') return bg;
    if (name === '@ohos/flutter_ohos') return { MethodChannel };
    throw Error(`Unexpected runtime import ${name}`);
  },
  setTimeout(callback, milliseconds) { const id = ++nextTimer; timers.set(id, { callback, milliseconds }); return id; },
  clearTimeout(id) { timers.delete(id); }
}, { filename: 'FluxdoNotificationsPlugin.ets' });
const Plugin = module.exports.default;
const binding = { getBinaryMessenger() { return {}; } };
const context = { abilityInfo: { bundleName: 'com.github.molchuan.cfluxdo', moduleName: 'entry', name: 'EntryAbility' } };
const plugin = new Plugin();
const invoke = (method, args = {}, target = plugin) => new Promise(resolve => target.onMethodCall(
  { method, argument(name) { return args[name] ?? null; } },
  { success(value) { resolve({ value }); }, error(code, message, details) { resolve({ error: code, message, details }); }, notImplemented() { resolve({ missing: true }); } }
));
const want = (payload, token) => ({ action: 'com.github.molchuan.cfluxdo.NOTIFICATION', parameters: { 'fluxdo.notification.payload': payload, 'fluxdo.notification.token': token } });
let checks = 0;
async function test(name, run) { await run(); checks++; console.log(`PASS ${name}`); }

await test('cold Want survives engine startup and drains exactly once', async () => {
  Plugin.receiveWant(want('message:123:7', 'cold-1'));
  Plugin.abilityContext = context;
  plugin.onAttachedToEngine(binding);
  const cold = (await invoke('drainTaps')).value;
  assert.equal(cold.length, 1);
  assert.equal(cold[0].get('payload'), 'message:123:7');
  assert.equal((await invoke('drainTaps')).value.length, 0);
});
await test('hot Wants signal Dart; invalid and duplicate payloads do not navigate', async () => {
  const channel = channels.at(-1);
  Plugin.receiveWant(want('chat:42', 'hot-1'));
  Plugin.receiveWant(want('chat:42', 'hot-1'));
  for (const payload of ['topic:0', 'chat:-2', 'chat:1:2', 'topic:2:bad', 'topic:9007199254740992', 'https://example.com']) Plugin.receiveWant(want(payload, `bad-${payload}`));
  Plugin.receiveWant({ action: 'unrelated', parameters: want('topic:3', 'wrong').parameters });
  assert.equal(channel.events.filter(event => event.method === 'notificationsChanged').length, 1);
  assert.equal((await invoke('drainTaps')).value.length, 1);
});
await test('permission request always re-queries real system state after denial', async () => {
  enabled = false; promptError = true;
  const before = queryCount;
  assert.equal((await invoke('requestPermission')).value, false);
  assert.equal(queryCount - before, 2);
  promptError = false; grantAfterPrompt = false;
  assert.equal((await invoke('requestPermission')).value, false);
  grantAfterPrompt = true;
  assert.equal((await invoke('requestPermission')).value, true);
  const prompts = promptCount;
  assert.equal((await invoke('requestPermission')).value, true);
  assert.equal(promptCount, prompts);
});
await test('permission query failure is an error, never a grant', async () => {
  queryError = true;
  assert.equal((await invoke('isEnabled')).error, 'NOTIFICATION_FAILED');
  queryError = false;
});
await test('publishing uses original identity and real notification API', async () => {
  enabled = true;
  assert.equal((await invoke('publish', { id: 5, title: 'title', body: 'body', payload: 'topic:9:2' })).value, true);
  const agent = agents.at(-1);
  assert.equal(agent.wants[0].bundleName, 'com.github.molchuan.cfluxdo');
  assert.equal(agent.actionType, 1);
  assert.equal(agent.actionFlags[0], 4);
  assert.equal(agent.wants[0].parameters['fluxdo.notification.payload'], 'topic:9:2');
  assert.equal(published.at(-1).notificationSlotType, 1);
  assert.equal(published.at(-1).tapDismissed, true);
});
await test('permission revocation and publish failure are observable', async () => {
  enabled = false;
  const count = published.length;
  assert.equal((await invoke('publish', { id: 7, title: 'title', body: '' })).value, false);
  assert.equal(published.length, count);
  enabled = true; publishError = true;
  const failure = await invoke('publish', { id: 7, title: 'title', body: 'private' });
  assert.equal(failure.error, 'NOTIFICATION_FAILED');
  assert(!failure.message.includes('private'));
  publishError = false;
  assert.equal((await invoke('publish', { id: -1, title: 'title', body: 'body' })).error, 'NOTIFICATION_FAILED');
});
await test('download progress uses same notification id and bounded actual percent', async () => {
  await invoke('publish', { id: 99001, title: 'update', body: 'downloading', progress: 125, alertOnce: true });
  assert.equal(published.at(-1).id, 99001);
  assert.equal(published.at(-1).content.normal.text, 'downloading (100%)');
  assert.equal(published.at(-1).isAlertOnce, true);
});
await test('cancel, cancelAll and failures return real OS result', async () => {
  await invoke('cancel', { id: 5 }); await invoke('cancelAll');
  assert(cancellations.includes(5)); assert(cancellations.includes('all'));
  cancelError = true;
  assert.equal((await invoke('cancel', { id: 5 })).error, 'NOTIFICATION_FAILED');
  cancelError = false;
  assert.equal((await invoke('cancel', { id: '5' })).error, 'NOTIFICATION_FAILED');
});
await test('short background task is bounded and old expiry cannot affect new task', async () => {
  const first = (await invoke('beginBackground')).value;
  assert.equal(first.get('remainingMs'), 30000);
  const oldCallback = callbacks.get(first.get('requestId'));
  await invoke('endBackground');
  const second = (await invoke('beginBackground')).value;
  const channel = channels.at(-1), count = channel.events.length;
  await invoke('endBackground', { requestId: first.get('requestId') });
  assert(!cancellations.includes(`bg:${second.get('requestId')}`));
  oldCallback(); assert.equal(channel.events.length, count);
  callbacks.get(second.get('requestId'))();
  assert.equal(channel.events.at(-1).method, 'backgroundExpired');
  assert.equal(timers.size, 0);
});
await test('background expiry is not blocked by an unanswered permission prompt', async () => {
  enabled = false; holdPrompt = true;
  const before = promptCount;
  const permission = invoke('requestPermission');
  while (promptCount === before) await Promise.resolve();
  const budget = (await invoke('beginBackground')).value;
  assert.equal(budget.get('remainingMs'), 30000);
  await invoke('endBackground');
  releasePrompt(); holdPrompt = false;
  assert.equal((await permission).value, true);
});
await test('quota rejection or synchronous expiry cannot fake a background budget', async () => {
  backgroundError = true;
  assert.equal((await invoke('beginBackground')).error, 'NOTIFICATION_FAILED');
  backgroundError = false; immediateExpiry = true;
  assert.equal((await invoke('beginBackground')).error, 'NOTIFICATION_FAILED');
  immediateExpiry = false;
});
await test('expiry still stops Dart polling if OS cancellation reports failure', async () => {
  const budget = (await invoke('beginBackground')).value;
  cancelError = true;
  callbacks.get(budget.get('requestId'))();
  cancelError = false;
  assert.equal(channels.at(-1).events.at(-1).method, 'backgroundExpired');
  assert.equal(timers.size, 0);
});
await test('engine detach cancels short task and retains unread Want for next engine', async () => {
  await invoke('beginBackground');
  const detached = channels.at(-1);
  plugin.onDetachedFromEngine(binding);
  assert.equal(detached.handler, null);
  assert.equal(timers.size, 0);
  assert.equal((await invoke('isEnabled')).error, 'DETACHED');
  Plugin.receiveWant(want('topic:17', 'after-detach'));
  const next = new Plugin(); Plugin.abilityContext = context; next.onAttachedToEngine(binding);
  assert.equal((await invoke('drainTaps', {}, next)).value[0].get('payload'), 'topic:17');
  Plugin.receiveWant(want('chat:99', 'logout-clear')); await invoke('clearTaps', {}, next);
  assert.equal((await invoke('drainTaps', {}, next)).value.length, 0);
  next.onDetachedFromEngine(binding);
});
console.log(`OHOS production notification behavior: ${checks} cases passed (OS boundaries mocked).`);
