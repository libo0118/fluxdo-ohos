// 直接转译生产 ETS；仅替换系统边界，AES-GCM 和随机数使用 Node 实际实现。
// 用法：node tool/test_ohos_secure_storage.mjs [TypeScript 模块路径] [检出目录]
import assert from 'node:assert/strict';
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const require = createRequire(import.meta.url);
const ts = require(process.argv[2] || 'typescript');
const repo = process.argv[3] || fileURLToPath(new URL('../', import.meta.url));
const source = readFileSync(resolve(repo, 'ohos_support/secure_storage/FluxdoSecureStoragePlugin.ets'), 'utf8');
const compiled = ts.transpileModule(source, {
  fileName: 'FluxdoSecureStoragePlugin.ts',
  reportDiagnostics: true,
  compilerOptions: {
    module: ts.ModuleKind.CommonJS,
    target: ts.ScriptTarget.ES2022,
    useDefineForClassFields: true,
  },
});
const errors = (compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error);
assert.equal(errors.length, 0, errors.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')).join('\n'));

let cache = new Map();
let disk = new Map();
let savedAsset = null;
let assetUnavailable = false;
let failAtFlush = 0;
let preferenceUnavailable = false;
let addAttempts = 0;
let duplicateAttempts = 0;

function businessError(code) {
  return Object.assign(new Error('系统边界测试故障'), { code });
}

const tags = {
  ALIAS: 'alias', SECRET: 'secret', ACCESSIBILITY: 'accessibility',
  SYNC_TYPE: 'sync', CONFLICT_RESOLUTION: 'conflict', RETURN_TYPE: 'return',
};
function copyAsset(value) {
  return new Map(Array.from(value, ([key, data]) => [
    key, data instanceof Uint8Array ? new Uint8Array(data) : data,
  ]));
}
const asset = {
  Tag: tags,
  Accessibility: { DEVICE_FIRST_UNLOCKED: 1 },
  SyncType: { NEVER: 0 },
  ConflictResolution: { THROW_ERROR: 1 },
  ReturnType: { ALL: 0 },
  async query(query) {
    await Promise.resolve();
    assert.equal(new TextDecoder().decode(query.get(tags.ALIAS)), 'fluxdo.secure_storage.aes256.v1');
    if (assetUnavailable) throw businessError(24000001);
    if (savedAsset === null) throw businessError(24000002);
    return [copyAsset(savedAsset)];
  },
  async add(attributes) {
    addAttempts++;
    assert.equal(attributes.get(tags.CONFLICT_RESOLUTION), 1, '首次密钥生成不可覆盖');
    assert.equal(attributes.get(tags.ACCESSIBILITY), 1);
    assert.equal(attributes.get(tags.SYNC_TYPE), 0);
    assert.equal(attributes.get(tags.SECRET).length, 32, 'AssetStore 只保存 32B 密钥');
    if (savedAsset !== null) {
      duplicateAttempts++;
      throw businessError(24000003);
    }
    savedAsset = copyAsset(attributes);
  },
};

const fakePreferences = {
  getAllSync: () => Object.fromEntries(cache),
  hasSync: key => cache.has(key),
  getSync: (key, fallback) => cache.has(key) ? cache.get(key) : fallback,
  putSync(key, value) {
    assert.ok(Buffer.byteLength(key) <= 1024, '遵守 Preferences key 长度限制');
    assert.ok(typeof value === 'string', '只允许密文字符串和元数据');
    assert.ok(Buffer.byteLength(value) <= 8192, '长值不能绕过 Preferences 单条限制');
    cache.set(key, value);
  },
  deleteSync: key => cache.delete(key),
  clearSync: () => cache.clear(),
  async flush() {
    if (failAtFlush > 0 && --failAtFlush === 0) throw businessError(15500000);
    disk = new Map(cache);
  },
};
const preferences = {
  getPreferencesSync(context, options) {
    assert.equal(options.name, 'fluxdo_secure_storage_v1');
    if (preferenceUnavailable) throw businessError(15500000);
    return fakePreferences;
  },
};

const cryptoFramework = {
  CryptoMode: { ENCRYPT_MODE: 0, DECRYPT_MODE: 1 },
  createRandom: () => ({
    generateRandom: async length => ({ data: new Uint8Array(randomBytes(length)) }),
  }),
  createSymKeyGenerator(algorithm) {
    assert.equal(algorithm, 'AES256');
    return {
      async convertKey(blob) {
        const bytes = new Uint8Array(blob.data);
        assert.equal(bytes.length, 32);
        return { bytes, clearMem: () => bytes.fill(0) };
      },
    };
  },
  createCipher(algorithm) {
    assert.equal(algorithm, 'AES256|GCM|NoPadding');
    let cipher;
    let mode;
    return {
      async init(nextMode, key, params) {
        mode = nextMode;
        assert.equal(params.algName, 'GcmParamsSpec');
        assert.equal(params.iv.data.length, 12);
        cipher = mode === 0
          ? createCipheriv('aes-256-gcm', key.bytes, params.iv.data)
          : createDecipheriv('aes-256-gcm', key.bytes, params.iv.data);
        cipher.setAAD(Buffer.from(params.aad.data));
        if (mode === 1) cipher.setAuthTag(Buffer.from(params.authTag.data));
      },
      async doFinal(blob) {
        const input = blob === null ? Buffer.alloc(0) : Buffer.from(blob.data);
        const value = Buffer.concat([cipher.update(input), cipher.final()]);
        if (mode === 0) {
          return { data: new Uint8Array(Buffer.concat([value, cipher.getAuthTag()])) };
        }
        return value.length === 0 ? null : { data: new Uint8Array(value) };
      },
    };
  },
};

class Base64Helper {
  encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
  decodeSync(value) { return new Uint8Array(Buffer.from(value, 'base64')); }
}
class NativeTextEncoder {
  encodeInto(value) { return new TextEncoder().encode(value); }
}
const util = {
  Base64Helper,
  TextEncoder: NativeTextEncoder,
  TextDecoder: {
    create: charset => ({ decodeToString: bytes => new TextDecoder(charset, { fatal: true }).decode(bytes) }),
  },
};
const channels = [];
class MethodChannel {
  constructor(messenger, name) {
    this.name = name;
    this.handler = null;
    channels.push(this);
  }
  setMethodCallHandler(value) { this.handler = value; }
}
const boundaries = {
  '@kit.AssetStoreKit': { asset },
  '@kit.CryptoArchitectureKit': { cryptoFramework },
  '@kit.ArkData': { preferences },
  '@kit.ArkTS': { util },
  '@ohos/flutter_ohos': { MethodChannel },
};
const module = { exports: {} };
vm.runInNewContext(compiled.outputText, {
  module,
  exports: module.exports,
  require: name => {
    assert.ok(Object.hasOwn(boundaries, name), '未声明的原生模块：' + name);
    return boundaries[name];
  },
  Uint8Array, Map, Object, Array, Number, Promise, Error, JSON,
  console: {
    log() { throw new Error('生产安全存储不得记录日志'); },
    error() { throw new Error('生产安全存储不得记录异常和凭据'); },
  },
}, { filename: 'FluxdoSecureStoragePlugin.js' });

const Plugin = module.exports.default;
const Store = module.exports.AssetProtectedStore;
const binding = { getApplicationContext: () => ({}), getBinaryMessenger: () => ({}) };
function attachedPlugin() {
  const plugin = new Plugin();
  plugin.onAttachedToEngine(binding);
  assert.equal(channels.at(-1).name, 'plugins.it_nomads.com/flutter_secure_storage');
  assert.equal(channels.at(-1).handler, plugin);
  return plugin;
}
function invoke(plugin, method, args = {}) {
  return new Promise((success, reject) => {
    plugin.onMethodCall({ method, argument: key => args[key] ?? null }, {
      success,
      error(code, message, details) {
        assert.equal(details, null);
        reject(Object.assign(new Error(message), { code }));
      },
      notImplemented: () => reject(Object.assign(new Error('未实现'), { code: 'not_implemented' })),
    });
  });
}
const isSecureError = error => error.code === 'secure_storage_error';
const recordName = key => 'r:' + Buffer.from(key).toString('base64');
const checks = [];
async function check(name, run) {
  await run();
  checks.push(name);
}

await check('首次 AssetStore 密钥生成竞态复用，绝不覆盖', async () => {
  const first = new Store({});
  const second = new Store({});
  const keys = await Promise.all([first.key(), second.key()]);
  assert.deepEqual(keys[0].bytes, keys[1].bytes);
  assert.equal(addAttempts, 2);
  assert.equal(duplicateAttempts, 1);
  keys.forEach(key => key.clearMem());
});
const plugin = attachedPlugin();
const peer = attachedPlugin();
const longValue = '凭据🚀\u0000证书内容'.repeat(7000);
await check('UTF8、空字符串、超过 1024B/8192B 长值 round trip', async () => {
  for (const [key, value] of [['中文:key_🚀', '登录凭据🚀'], ['empty', ''], ['long', longValue]]) {
    await invoke(plugin, 'write', { key, value });
    assert.equal(await invoke(plugin, 'read', { key }), value);
    assert.equal(await invoke(plugin, 'containsKey', { key }), true);
  }
  assert.equal(await invoke(plugin, 'read', { key: 'missing' }), null);
  assert.equal(await invoke(plugin, 'containsKey', { key: 'missing' }), false);
  assert.ok(!JSON.stringify(Array.from(cache)).includes('登录凭据'));
  assert.ok(!JSON.stringify(Array.from(cache)).includes('证书内容'));
});
await check('跨引擎读写队列、重复写入和 readAll 返回明文 Map', async () => {
  await Promise.all(Array.from({ length: 20 }, (_, index) =>
    invoke(index % 2 === 0 ? plugin : peer, 'write', { key: 'serial', value: String(index) })));
  assert.equal(await invoke(peer, 'read', { key: 'serial' }), '19');
  const all = await invoke(peer, 'readAll');
  assert.ok(all instanceof Map);
  assert.equal(all.size, 4);
  assert.equal(all.get('long'), longValue);
  assert.equal(all.get('中文:key_🚀'), '登录凭据🚀');
  assert.equal(all.get('empty'), '');
});
await check('write(null)、重复删除、缺失 key 删除保持标准语义', async () => {
  await invoke(plugin, 'write', { key: 'serial', value: null });
  await invoke(plugin, 'delete', { key: 'serial' });
  await invoke(peer, 'delete', { key: 'missing' });
  assert.equal(await invoke(plugin, 'read', { key: 'serial' }), null);
});
await check('新分块落盘失败和索引提交失败保留旧值', async () => {
  await invoke(plugin, 'write', { key: 'rollback', value: '旧值' });
  for (const stage of [1, 2]) {
    const oldRecord = disk.get(recordName('rollback'));
    failAtFlush = stage;
    await assert.rejects(invoke(plugin, 'write', { key: 'rollback', value: longValue }), isSecureError);
    assert.equal(await invoke(peer, 'read', { key: 'rollback' }), '旧值');
    assert.equal(disk.get(recordName('rollback')), oldRecord);
  }
});
await check('删除索引落盘失败恢复旧值', async () => {
  failAtFlush = 1;
  await assert.rejects(invoke(peer, 'delete', { key: 'rollback' }), isSecureError);
  assert.equal(await invoke(plugin, 'read', { key: 'rollback' }), '旧值');
});
await check('认证标签损坏拒绝 read/containsKey/readAll/write/delete', async () => {
  const name = recordName('rollback');
  const original = cache.get(name);
  const record = JSON.parse(original);
  const tag = Buffer.from(record.authTag, 'base64');
  tag[0] ^= 1;
  record.authTag = tag.toString('base64');
  cache.set(name, JSON.stringify(record));
  for (const [method, args] of [
    ['read', { key: 'rollback' }],
    ['containsKey', { key: 'rollback' }],
    ['readAll', {}],
    ['write', { key: 'rollback', value: '不可覆盖' }],
    ['delete', { key: 'rollback' }],
  ]) {
    await assert.rejects(invoke(plugin, method, args), isSecureError);
  }
  cache.set(name, original);
});
await check('AAD 绑定 key，复制密文记录到另一 key 无法读取', async () => {
  cache.set(recordName('copied'), cache.get(recordName('rollback')));
  await assert.rejects(invoke(peer, 'read', { key: 'copied' }), isSecureError);
  cache.delete(recordName('copied'));
});
await check('分块丢失和损坏 schema 拒绝读取', async () => {
  const name = recordName('long');
  const original = cache.get(name);
  const record = JSON.parse(original);
  const chunkName = 'c:' + record.id + ':0';
  const chunk = cache.get(chunkName);
  cache.delete(chunkName);
  await assert.rejects(invoke(plugin, 'read', { key: 'long' }), isSecureError);
  cache.set(chunkName, chunk);
  cache.set(name, JSON.stringify({ ...record, schema: 99 }));
  await assert.rejects(invoke(peer, 'read', { key: 'long' }), isSecureError);
  cache.set(name, original);
});
await check('系统服务故障/密钥丢失报错，既不覆盖密钥也不泄漏参数', async () => {
  assetUnavailable = true;
  const error = await invoke(plugin, 'write', { key: 'private-key', value: 'secret-sentinel' }).catch(value => value);
  assert.ok(isSecureError(error));
  assert.ok(!error.message.includes('secret-sentinel'));
  assert.ok(!error.message.includes('private-key'));
  assetUnavailable = false;
  const previous = savedAsset;
  const attempts = addAttempts;
  savedAsset = null;
  await assert.rejects(invoke(peer, 'read', { key: 'rollback' }), isSecureError);
  assert.equal(addAttempts, attempts);
  assert.equal(savedAsset, null);
  savedAsset = previous;
});
await check('非法参数拒绝任意 string 化，插件初始化故障交回调用方', async () => {
  await assert.rejects(invoke(plugin, 'read', { key: { toString() { throw new Error('不允许转换'); } } }), isSecureError);
  await assert.rejects(invoke(peer, 'write', { key: 'invalid', value: 123 }), isSecureError);
  preferenceUnavailable = true;
  const broken = attachedPlugin();
  await assert.rejects(invoke(broken, 'read', { key: 'probe' }), isSecureError);
  preferenceUnavailable = false;
});
await check('deleteAll 故障恢复、成功清空，保留系统密钥并可再写入', async () => {
  failAtFlush = 1;
  await assert.rejects(invoke(plugin, 'deleteAll'), isSecureError);
  assert.equal(await invoke(peer, 'read', { key: 'rollback' }), '旧值');
  await invoke(peer, 'deleteAll');
  assert.equal(cache.size, 0);
  assert.equal(disk.size, 0);
  assert.ok(savedAsset !== null);
  assert.deepEqual(await invoke(plugin, 'readAll'), new Map());
  await invoke(plugin, 'write', { key: 'after-deleteAll', value: '重启后仍可用' });
  const reopened = attachedPlugin();
  assert.equal(await invoke(reopened, 'read', { key: 'after-deleteAll' }), '重启后仍可用');
  await assert.rejects(invoke(reopened, 'unknown'), error => error.code === 'not_implemented');
  reopened.onDetachedFromEngine(binding);
  assert.equal(channels.at(-1).handler, null);
});

console.log('安全存储行为检查通过：' + checks.length + ' 项（真实 AES-GCM；系统边界测试替身，未代替真机验证）');
