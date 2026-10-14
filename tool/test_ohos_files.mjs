// 执行生产 ETS；系统接口替身只验证行为合同，不能代替 SDK 编译和真机验证。
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const ts = require(path.resolve(process.argv[2] ?? 'node_modules/typescript'));
const repo = path.resolve(process.argv[3] ?? '.');
const source = fs.readFileSync(path.join(repo, 'ohos_support/system_files/FluxdoSystemFilesPlugin.ets'), 'utf8');
const transpiled = ts.transpileModule(source.replace(/^import .*;\r?\n/gm, ''), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true,
});
assert.equal(transpiled.diagnostics.filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);

function deferred() {
  let resolve;
  const promise = new Promise(yes => { resolve = yes; });
  return { promise, resolve };
}

function environment(options = {}) {
  const state = { pickerResult: ['file://docs/test.txt'], photoResult: ['file://media/picture.png'],
    permission: 0, records: [], files: new Map([['/input', 'source bytes'], ['file://docs/test.txt', ''], ['file://media/picture.png', '']]),
    handles: new Map(), shares: [], wants: [], persisted: [], activated: [], released: 0, ...options };
  let descriptor = 0;
  const fileIo = {
    OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, TRUNC: 2 },
    async open(name, mode) {
      if (!state.files.has(name)) throw new Error('File does not exist');
      if (mode & 2) state.files.set(name, '');
      const file = { fd: ++descriptor }; state.handles.set(file.fd, name); return file;
    },
    async close(file) { assert.ok(state.handles.delete(file.fd), '不重复关闭文件'); },
    async copyFile(input, output) {
      if (state.copyFailure) throw new Error('copy failed');
      const sourceName = typeof input === 'number' ? state.handles.get(input) : input;
      const destination = typeof output === 'number' ? state.handles.get(output) : output;
      assert.ok(state.files.has(sourceName)); state.files.set(destination, state.files.get(sourceName));
    },
    async access(name) { return state.files.has(name); },
    async mkdir(name) { state.files.set(name, null); },
  };
  class ShareController {
    constructor(data) { this.data = data; this.events = {}; state.shares.push(this); }
    on(name, listener) { this.events[name] = listener; }
    off(name, listener) { assert.equal(this.events[name], listener); delete this.events[name]; }
    async show(context, settings) {
      this.settings = settings;
      if (state.shareFailure) throw new Error('panel failed');
    }
    dismiss() { this.events.dismiss(); }
  }
  class SharedData { constructor(record) { this.record = record; } }
  const board = {
    async getData() { return { getRecordCount: () => state.records.length, getRecord: i => state.records[i] }; },
    async setData(data) { if (state.writeFailure) throw new Error('write failed'); state.written = data; },
  };
  const imageApi = {
    createImageSource(buffer) { return { async getImageInfo() { return state.imageInfo ?? { size: { width: 4, height: 3 } }; },
      async createPixelMap() { return { release() { state.released++; } }; }, release() { state.released++; } }; },
    createImagePacker() { return { async packing(pixel, opts) { assert.equal(opts.format, 'image/png'); return Uint8Array.from([1, 2, 3]).buffer; }, release() { state.released++; } }; },
  };
  const sandbox = {
    exports: {}, Uint8Array, ArrayBuffer, Error, Map, Date, Math,
    fs: fileIo,
    fileUri: { getUriFromPath: value => { assert.ok(value.startsWith('/')); return 'file://app' + value; },
      FileUri: class { constructor(value) { this.name = decodeURIComponent(value.split('/').at(-1)); } } },
    picker: { DocumentViewPicker: class { async save(settings) { state.pickerSettings = settings; return state.pickerDeferred ? state.pickerDeferred.promise : state.pickerResult; } } },
    fileShare: { OperationMode: { READ_MODE: 1 },
      async persistPermission(policies) { if (state.persistFailure) throw new Error('permission denied'); state.persisted.push(policies); },
      async checkPersistentPermission() { return [state.hasPersistent !== false]; },
      async activatePermission(policies) { state.activated.push(policies); } },
    photoAccessHelper: { PhotoType: { IMAGE: 1 }, getPhotoAccessHelper(context) { return {
      async showAssetsCreationDialog(uris, configs) { state.photoInput = { uris, configs }; return state.photoResult; },
      release() { state.released++; },
    }; } },
    abilityAccessCtrl: { createAtManager() { return { async requestPermissionsFromUser(context, permissions) {
      state.requested = permissions; return { authResults: [state.permission] };
    } }; } },
    wantConstant: { Flags: { FLAG_AUTH_READ_URI_PERMISSION: 1 } },
    utd: { UniformDataType: { FILE: 'general.file', PLAIN_TEXT: 'general.plain-text' },
      getUniformDataTypeByMIMEType: value => 'utd:' + value, getUniformDataTypeByFilenameExtension: value => 'ext:' + value },
    systemShare: { ShareController, SharedData, SelectionMode: { SINGLE: 0 }, SharePreviewMode: { DEFAULT: 0 } },
    pasteboard: { MIMETYPE_TEXT_HTML: 'text/html', MIMETYPE_TEXT_PLAIN: 'text/plain', MIMETYPE_PIXELMAP: 'pixelmap',
      getSystemPasteboard: () => board,
      createData(mime, buffer) { return { records: [{ mime, value: buffer }], addRecord(mime, value) { this.records.push({ mime, value }); } }; },
    },
    image: imageApi,
    util: { TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } } },
  };
  vm.runInNewContext(transpiled.outputText, sandbox);
  const Plugin = sandbox.exports.default;
  Plugin.abilityContext = { filesDir: '/files', async startAbility(want) { if (state.openFailure) throw new Error('no handler'); state.wants.push(want); } };
  const plugin = new Plugin();
  function invoke(method, args = {}) {
    return new Promise(resolve => plugin.onMethodCall({ method, argument: key => args[key] ?? null }, {
      success(value) { resolve({ value }); }, error(code) { resolve({ error: code }); }, notImplemented() { resolve({ error: 'NOT_IMPLEMENTED' }); },
    }));
  }
  return { state, invoke, plugin, Plugin };
}

function record(entries) {
  const values = new Map(Object.entries(entries));
  return { getValidTypes(types) { return types.filter(type => values.has(type)); }, async getData(type) { return values.get(type); } };
}

const cases = [];
function test(name, run) { cases.push([name, run]); }

test('另存为取消不复制也不伪报成功', async () => {
  const { state, invoke } = environment({ pickerResult: [] });
  assert.equal((await invoke('saveAs', { sourcePath: '/input', fileName: 'test.txt' })).value, null);
  assert.equal(state.handles.size, 0); assert.equal(state.persisted.length, 0);
});
test('保存实际字节并保留持久 URI 和最终文件名', async () => {
  const { state, invoke } = environment();
  const result = await invoke('saveAs', { sourcePath: '/input', fileName: 'original.txt' });
  assert.equal(result.value.get('uri'), 'file://docs/test.txt'); assert.equal(result.value.get('displayName'), 'test.txt');
  assert.equal(state.files.get('file://docs/test.txt'), 'source bytes'); assert.equal(state.handles.size, 0);
  assert.equal(state.persisted[0][0].operationMode, 1);
});
test('持久授权拒绝后保留独立副本而非取消', async () => {
  const { state, invoke } = environment({ persistFailure: true });
  const result = await invoke('saveAs', { sourcePath: '/input', fileName: 'test.txt' });
  assert.match(result.value.get('uri'), /^\/files\/export_history\//);
  assert.equal(state.files.get(result.value.get('uri')), 'source bytes'); assert.equal(state.handles.size, 0);
  const path = result.value.get('uri');
  assert.equal((await invoke('openUri', { uri: path, mimeType: 'text/plain' })).value, true);
  assert.equal(state.wants.at(-1).uri, 'file://app' + path);
  assert.equal((await invoke('shareUri', { uri: path, mimeType: 'text/plain' })).value, true);
  assert.equal(state.shares.at(-1).data.record.uri, 'file://app' + path);
  assert.equal(state.activated.length, 0);
});
test('复制失败仍关闭两个 fd', async () => {
  const { state, invoke } = environment({ copyFailure: true });
  assert.equal((await invoke('saveAs', { sourcePath: '/input', fileName: 'test.txt' })).error, 'FILE_OPERATION_FAILED');
  assert.equal(state.handles.size, 0);
});
test('目标打开失败仍关闭源 fd', async () => {
  const { state, invoke } = environment({ pickerResult: ['file://docs/missing'] });
  assert.equal((await invoke('saveAs', { sourcePath: '/input', fileName: 'test.txt' })).error, 'FILE_OPERATION_FAILED');
  assert.equal(state.handles.size, 0);
});
test('已有选择窗口返回 BUSY', async () => {
  const pending = deferred(); const { invoke } = environment({ pickerDeferred: pending });
  const first = invoke('saveAs', { sourcePath: '/input', fileName: 'test.txt' });
  await Promise.resolve();
  assert.equal((await invoke('saveAs', { sourcePath: '/input', fileName: 'test.txt' })).error, 'BUSY');
  pending.resolve([]); assert.equal((await first).value, null);
});
test('参数错误和不支持静默下载不会伪造路径', async () => {
  const { invoke } = environment();
  assert.equal((await invoke('saveAs', { sourcePath: 'file://docs/input', fileName: 'test.txt' })).error, 'INVALID_ARGS');
  assert.equal((await invoke('saveToDownloads')).value, null);
  assert.equal((await invoke('openUri', { uri: 'https://example.com' })).error, 'INVALID_ARGS');
});
test('公开 URI 直接交系统且恢复持久授权，本地路径通过 API 转 URI', async () => {
  const { state, invoke } = environment();
  assert.equal((await invoke('openUri', { uri: 'file://docs/test.txt', mimeType: 'text/plain' })).value, true);
  assert.equal(state.activated.length, 1); assert.equal(state.wants[0].uri, 'file://docs/test.txt');
  assert.equal(state.wants[0].type, 'utd:text/plain'); assert.equal(state.wants[0].flags, 1);
  await invoke('openUri', { uri: '/input' }); assert.equal(state.wants[1].uri, 'file://app/input');
});
test('没有文件处理应用时报告失败', async () => {
  const { invoke } = environment({ openFailure: true });
  assert.equal((await invoke('openUri', { uri: '/input' })).error, 'FILE_OPERATION_FAILED');
});
test('官方分享区分文件 URI 和文本，仅报告面板显示', async () => {
  const { state, invoke } = environment();
  assert.equal((await invoke('shareUri', { uri: 'file://docs/test.txt', mimeType: 'text/plain' })).value, true);
  assert.equal(state.shares[0].data.record.uri, 'file://docs/test.txt');
  assert.equal((await invoke('shareText', { text: 'hello' })).error, 'BUSY');
  state.shares[0].dismiss();
  assert.equal((await invoke('shareText', { text: 'hello', subject: 'title' })).value, true);
  assert.equal(state.shares[1].data.record.content, 'hello'); assert.equal(state.shares[1].data.record.title, 'title');
});
test('分享面板失败后允许重试', async () => {
  const { state, invoke } = environment({ shareFailure: true });
  assert.equal((await invoke('shareText', { text: 'hello' })).error, 'FILE_OPERATION_FAILED');
  state.shareFailure = false; assert.equal((await invoke('shareText', { text: 'hello' })).value, true);
});
test('相册取消不写入，授权后复制并释放 helper', async () => {
  const cancelled = environment({ photoResult: [] });
  assert.equal((await cancelled.invoke('saveImageToGallery', { sourcePath: '/input', fileName: 'picture.png' })).value, false);
  assert.equal(cancelled.state.released, 1);
  const { state, invoke } = environment();
  assert.equal((await invoke('saveImageToGallery', { sourcePath: '/input', fileName: 'picture.png' })).value, true);
  assert.equal(state.files.get('file://media/picture.png'), 'source bytes'); assert.equal(state.handles.size, 0);
  assert.equal(state.photoInput.configs[0].title, 'picture'); assert.equal(state.released, 1);
});
test('剪贴板授权拒绝返回真实权限错误', async () => {
  const { state, invoke } = environment({ permission: -1 });
  assert.equal((await invoke('readClipboard')).error, 'PERMISSION_DENIED');
  assert.deepEqual(Array.from(state.requested), ['ohos.permission.READ_PASTEBOARD']);
});
test('HTML、文本和 PNG/JPEG/GIF/WebP 原始字节都保留', async () => {
  for (const mime of ['image/png', 'image/jpeg', 'image/gif', 'image/webp']) {
    const bytes = Uint8Array.from([11, 22, 33]);
    const { invoke } = environment({ records: [record({ [mime]: bytes.buffer, 'text/html': '<b>Hello</b>', 'text/plain': 'Hello' })] });
    const result = (await invoke('readClipboard')).value;
    assert.equal(result.get('mimeType'), mime); assert.deepEqual(result.get('bytes'), bytes);
    assert.equal(result.get('html'), '<b>Hello</b>'); assert.equal(result.get('text'), 'Hello');
  }
});
test('只有 PixelMap 的系统剪贴板转 PNG 并释放资源', async () => {
  let released = 0; const { state, invoke } = environment({ records: [record({ pixelmap: {
    async getImageInfo() { return { size: { width: 4, height: 3 } }; }, release() { released++; },
  } })] });
  const value = (await invoke('readClipboard')).value;
  assert.equal(value.get('mimeType'), 'image/png'); assert.equal(released, 1); assert.equal(state.released, 1);
});
test('仅有 AVIF/SVG MIME 的剪贴板保留原始字节供 Dart 转换', async () => {
  for (const mime of ['image/avif', 'image/svg+xml']) {
    const bytes = Uint8Array.from([11, 22, 33]);
    const { invoke } = environment({ records: [record({ [mime]: bytes.buffer })] });
    const value = (await invoke('readClipboard')).value;
    assert.equal(value.get('mimeType'), mime);
    assert.deepEqual(value.get('bytes'), bytes);
    assert.equal(value.has('html'), false);
  }
  const text = '<svg xmlns="http://www.w3.org/2000/svg" width="2" height="2"/>';
  const { invoke } = environment({ records: [record({ 'image/svg+xml': text })] });
  const value = (await invoke('readClipboard')).value;
  assert.equal(new TextDecoder().decode(value.get('bytes')), text);
  assert.equal(value.get('mimeType'), 'image/svg+xml');
});
test('空 AVIF/SVG 和过大剪贴板图像不能进入 Dart 解码', async () => {
  for (const entries of [{ 'image/avif': new ArrayBuffer(0) },
    { 'image/svg+xml': 'x'.repeat(4 * 1024 * 1024 + 1) }]) {
    const { invoke } = environment({ records: [record(entries)] });
    assert.ok((await invoke('readClipboard')).error);
  }
});
test('写图包含原格式和系统 PixelMap，失败同样释放资源', async () => {
  for (const failed of [false, true]) {
    const { state, invoke } = environment({ writeFailure: failed });
    const result = await invoke('writeClipboardImage', { bytes: Uint8Array.from([1, 2, 3]), mimeType: 'image/jpeg' });
    assert.equal(state.released, 2);
    if (failed) assert.equal(result.error, 'FILE_OPERATION_FAILED');
    else assert.deepEqual(state.written.records.map(record => record.mime), ['image/jpeg', 'pixelmap']);
  }
});
test('未知方法和坏图片不报告成功', async () => {
  const { invoke } = environment();
  assert.equal((await invoke('unknown')).error, 'NOT_IMPLEMENTED');
  assert.equal((await invoke('writeClipboardImage', { bytes: new Uint8Array(), mimeType: 'image/png' })).error, 'INVALID_ARGS');
});
test('超大位图在完整解码前拒绝并释放 ImageSource', async () => {
  const { state, invoke } = environment({ imageInfo: { size: { width: 10000, height: 10000 } } });
  const result = await invoke('writeClipboardImage', { bytes: Uint8Array.from([1, 2, 3]), mimeType: 'image/png' });
  assert.equal(result.error, 'IMAGE_TOO_LARGE'); assert.equal(state.released, 1); assert.equal(state.written, undefined);
});

for (const [name, run] of cases) { await run(); console.log('PASS ' + name); }
console.log(`生产系统文件 ETS 行为验证通过：${cases.length} 项（OS 接口替身，未声称真机通过）`);
