// 执行生产 ETS 的状态机；OS 边界替身不能代替 Hvigor 编译和真机编解码。
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const ts = require(path.resolve(process.argv[2] ?? 'node_modules/typescript'));
const repo = path.resolve(process.argv[3] ?? '.');
const source = fs.readFileSync(path.join(repo, 'ohos_support/transcode/FluxdoTranscodePlugin.ets'), 'utf8');
const transpiled = ts.transpileModule(source.replace(/^import .*;\r?\n/gm, ''), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
  reportDiagnostics: true,
});
assert.equal(transpiled.diagnostics.filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

async function until(predicate) {
  for (let i = 0; i < 100; i++) {
    if (predicate()) return;
    await new Promise(resolve => setImmediate(resolve));
  }
  assert.fail('生产转码通道未到达预期状态');
}

function environment(options = {}) {
  const files = new Map();
  const handles = new Map();
  const events = [];
  let inode = 1;
  let descriptor = 10;
  let uuid = 0;
  const state = { metadata: { duration: '8000', hasVideo: 'yes', videoWidth: '1920', videoHeight: '1080' },
    transcoders: [], extractors: [], configs: [], prepared: 0, started: 0, cancelled: 0, released: 0, ...options };
  function put(name, data = 'original') { files.set(name, { ino: BigInt(inode++), data }); }
  put('/input');
  const fileIo = {
    OpenMode: { READ_ONLY: 0, READ_WRITE: 2, CREATE: 64, NOFOLLOW: 131072 },
    openSync(name, mode) {
      if (!files.has(name)) {
        if (!(mode & 64)) throw new Error('missing input');
        put(name, '');
      }
      const file = { fd: descriptor++ };
      handles.set(file.fd, { path: name, file: files.get(name) });
      events.push('open:' + name);
      return file;
    },
    closeSync(file) {
      const fd = typeof file === 'number' ? file : file.fd;
      assert.ok(handles.has(fd), '句柄不应重复关闭');
      events.push('close:' + handles.get(fd).path);
      handles.delete(fd);
    },
    statSync(file) {
      const entry = typeof file === 'number' ? handles.get(file)?.file : files.get(file);
      if (!entry) throw new Error('missing stat');
      return { size: entry.data.length, ino: entry.ino };
    },
    accessSync(name) { return files.has(name); },
    unlinkSync(name) { events.push('unlink:' + name); files.delete(name); },
    renameSync(from, to) {
      assert.equal(handles.size, 0, '发布产物前必须关闭文件句柄');
      assert.ok(events.includes('release:transcoder'), '发布产物前必须释放原生转码器');
      files.set(to, files.get(from)); files.delete(from); events.push('rename');
    },
  };
  const media = {
    CodecMimeType: { AUDIO_AAC: 'audio/mp4a-latm', VIDEO_AVC: 'video/avc', VIDEO_HEVC: 'video/hevc' },
    ContainerFormatType: { CFT_MPEG_4: 'mp4' },
    async createAVMetadataExtractor() {
      if (state.failMetadataCreate) throw new Error('metadata creation failed');
      if (state.metadataGate) await state.metadataGate.promise;
      const extractor = {
        async fetchMetadata() {
          if (state.failMetadataFetch) throw new Error('metadata failure');
          return state.metadata;
        },
        async release() { events.push('release:metadata'); },
      };
      state.extractors.push(extractor);
      return extractor;
    },
    async createAVTranscoder() {
      state.creating = true;
      if (state.createGate) await state.createGate.promise;
      if (state.failCreate) throw new Error('transcoder creation failed');
      const callbacks = new Map();
      const transcoder = {
        on(name, callback) { callbacks.set(name, callback); },
        off(name) { callbacks.delete(name); },
        async prepare(config) {
          state.configs.push(config); state.prepared++;
          assert.ok(handles.has(this.fdSrc.fd)); assert.ok(handles.has(this.fdDst));
          if (state.prepareGate) await state.prepareGate.promise;
          if (state.failPrepare) throw new Error('unsupported codec');
        },
        async start() {
          state.started++;
          if (state.failStart) throw new Error('start failure');
        },
        async cancel() { state.cancelled++; events.push('cancel:transcoder'); },
        async release() {
          if (state.releaseGate) await state.releaseGate.promise;
          state.released++; events.push('release:transcoder');
          if (state.failRelease) throw new Error('release failure');
        },
        emit(name, value) { callbacks.get(name)?.(value); },
        complete(data = 'encoded') { handles.get(this.fdDst).file.data = data; this.emit('complete'); },
      };
      state.transcoders.push(transcoder);
      return transcoder;
    },
  };
  class MethodChannel { setMethodCallHandler(handler) { this.handler = handler; } }
  const context = { exports: {}, fs: fileIo, media, util: { generateRandomUUID: () => 'test-' + ++uuid }, MethodChannel };
  vm.runInNewContext(transpiled.outputText, context, { filename: 'FluxdoTranscodePlugin.ets' });
  const plugin = new context.exports.default();
  plugin.onAttachedToEngine({ getBinaryMessenger() {} });
  function invoke(method, args = null) {
    return new Promise(resolve => {
      let replies = 0;
      plugin.onMethodCall({ method, args, argument: key => args?.[key] ?? null }, {
        success(value) { assert.equal(++replies, 1, '通道只能回包一次'); resolve({ value }); },
        error(code, message, details) { assert.equal(++replies, 1); resolve({ error: code, message, details }); },
        notImplemented() { assert.fail('未知通道'); },
      });
    });
  }
  const spec = { input: '/input', output: '/output', audioBitrate: 32000, videoBitrate: 500000,
    videoCodec: 'h264', maxHeight: 480, fps: 24, audioSampleRate: 16000, audioChannels: 1 };
  return { state, files, handles, events, invoke, spec, put, plugin };
}

let passed = 0;
async function test(name, body) {
  await body(); passed++; process.stdout.write('通过：' + name + '\n');
}

await test('probe 输出真实元数据并先 release 后 close', async () => {
  const e = environment();
  const result = await e.invoke('probe', '/input');
  assert.deepEqual(JSON.parse(JSON.stringify(result.value)), { durationMs: 8000, hasVideo: true, width: 1920, height: 1080 });
  assert.equal(e.handles.size, 0); assert.ok(e.events.indexOf('release:metadata') < e.events.indexOf('close:/input'));
});
await test('损坏/无时长/创建失败媒体返回 null 且关闭输入', async () => {
  for (const options of [{ failMetadataCreate: true }, { failMetadataFetch: true }, { metadata: { duration: '8000x' } }]) {
    const e = environment(options); assert.equal((await e.invoke('probe', '/input')).value, null); assert.equal(e.handles.size, 0);
  }
});
await test('校验同路径、URI、码率和编码器参数，保留输入', async () => {
  for (const change of [{ output: '/a/../input' }, { input: 'content://input' }, { audioBitrate: 0 },
    { videoCodec: 'unknown' }, { fps: -1 }]) {
    const e = environment(); assert.equal((await e.invoke('transcode', { ...e.spec, ...change })).error, 'ARGS');
    assert.equal(e.files.get('/input').data, 'original'); assert.equal(e.handles.size, 0);
  }
});
await test('H264 缩放、进度边界和发布顺序', async () => {
  const e = environment(); const result = e.invoke('transcode', e.spec);
  await until(() => e.state.started === 1);
  const native = e.state.transcoders[0]; const config = e.state.configs[0];
  assert.equal(config.videoFrameWidth, 852); assert.equal(config.videoFrameHeight, 480);
  assert.equal(config.videoCodec, 'video/avc'); assert.equal(config.audioCodec, 'audio/mp4a-latm');
  assert.ok(!('fps' in config) && !('audioSampleRate' in config) && !('audioChannels' in config));
  native.emit('progressUpdate', -10); assert.equal((await e.invoke('progress')).value, 0);
  native.emit('progressUpdate', 42); assert.equal((await e.invoke('progress')).value, 0.42);
  native.emit('progressUpdate', NaN); assert.equal((await e.invoke('progress')).value, 0.42);
  native.emit('progressUpdate', 200); assert.equal((await e.invoke('progress')).value, 1);
  native.complete(); assert.equal((await result).value, true);
  assert.equal(e.files.get('/output').data, 'encoded'); assert.equal(e.handles.size, 0);
});
await test('纯 WAV/录音的 AAC 通道不配置视频轨', async () => {
  const e = environment({ metadata: { duration: '8000', hasAudio: 'yes' } });
  const result = e.invoke('transcode', { ...e.spec, audioOnly: true }); await until(() => e.state.started === 1);
  assert.equal(e.state.configs[0].audioBitrate, 32000); assert.ok(!('videoCodec' in e.state.configs[0]));
  e.state.transcoders[0].complete(); assert.equal((await result).value, true);
});
await test('HEVC 的系统配置与失败关闭资源、保留已有输出', async () => {
  const e = environment({ failPrepare: true }); e.put('/output', 'previous');
  const result = await e.invoke('transcode', { ...e.spec, videoCodec: 'hevc' });
  assert.equal(result.error, 'TRANSCODE'); assert.equal(e.state.configs[0].videoCodec, 'video/hevc');
  assert.equal(e.files.get('/input').data, 'original'); assert.equal(e.files.get('/output').data, 'previous');
  assert.equal(e.handles.size, 0); assert.equal(e.files.size, 2); assert.equal(e.state.released, 1);
});
await test('创建期间 BUSY 和取消，不启动已经取消的任务', async () => {
  const gate = deferred(); const e = environment({ createGate: gate }); const result = e.invoke('transcode', e.spec);
  await until(() => e.state.creating); assert.equal((await e.invoke('transcode', e.spec)).error, 'BUSY');
  const cancel = e.invoke('cancel'); gate.resolve(); assert.equal((await result).value, false);
  assert.equal((await cancel).value, null); assert.equal(e.state.started, 0); assert.equal(e.handles.size, 0); assert.equal(e.files.size, 1);
});
await test('prepare 期间取消，在 prepare 完成后 cancel/release', async () => {
  const gate = deferred(); const e = environment({ prepareGate: gate }); const result = e.invoke('transcode', e.spec);
  await until(() => e.state.prepared === 1); const cancel = e.invoke('cancel'); gate.resolve();
  assert.equal((await result).value, false); await cancel;
  assert.equal(e.state.cancelled, 1); assert.equal(e.state.started, 0); assert.equal(e.handles.size, 0);
});
await test('运行中取消等释放完成才回包，晚到 complete 不发布', async () => {
  const gate = deferred(); const e = environment({ releaseGate: gate }); const result = e.invoke('transcode', e.spec);
  await until(() => e.state.started === 1); const native = e.state.transcoders[0]; const cancel = e.invoke('cancel');
  await until(() => e.state.cancelled === 1); assert.equal((await e.invoke('transcode', e.spec)).error, 'BUSY');
  native.emit('complete'); gate.resolve(); assert.equal((await result).value, false); await cancel;
  assert.equal(e.handles.size, 0); assert.equal(e.files.size, 1); assert.equal((await e.invoke('progress')).value, 0);
});
await test('native error/start/create/release 失败均清理句柄和临时文件', async () => {
  for (const options of [{ failCreate: true }, { failStart: true }, { failRelease: true }, {}]) {
    const e = environment(options); const result = e.invoke('transcode', e.spec);
    if (!options.failCreate && !options.failStart) {
      await until(() => e.state.started === 1);
      if (options.failRelease) e.state.transcoders[0].complete();
      else e.state.transcoders[0].emit('error', { code: 5400106, message: 'unsupported' });
    }
    const failure = await result;
    assert.equal(failure.error, 'TRANSCODE'); assert.equal(e.handles.size, 0); assert.equal(e.files.size, 1);
    if (Object.keys(options).length === 0) {
      assert.equal(failure.message, 'unsupported'); assert.equal(failure.details, 5400106);
    }
  }
});
await test('同 inode 别名和输出为空不能假成功', async () => {
  const alias = environment(); alias.files.set('/output', alias.files.get('/input'));
  assert.equal((await alias.invoke('transcode', alias.spec)).error, 'TRANSCODE'); assert.equal(alias.files.get('/input').data, 'original');
  const empty = environment(); const result = empty.invoke('transcode', empty.spec); await until(() => empty.state.started === 1);
  empty.state.transcoders[0].complete(''); assert.equal((await result).error, 'TRANSCODE'); assert.equal(empty.handles.size, 0);
});
await test('拒绝未支持的音轨剥离和过小视频尺寸且保留输入', async () => {
  for (const change of [{ audioOnly: true }, { maxHeight: 120 }]) {
    const e = environment(); assert.equal((await e.invoke('transcode', { ...e.spec, ...change })).error, 'TRANSCODE');
    assert.equal(e.state.transcoders.length, 0); assert.equal(e.files.size, 1); assert.equal(e.handles.size, 0);
  }
});
await test('detach 取消活动任务并释放资源', async () => {
  const e = environment(); const result = e.invoke('transcode', e.spec); await until(() => e.state.started === 1);
  e.plugin.onDetachedFromEngine({}); assert.equal((await result).value, false); assert.equal(e.handles.size, 0);
});
process.stdout.write(`OHOS 生产转码插件行为验证通过：${passed} 组\n`);
