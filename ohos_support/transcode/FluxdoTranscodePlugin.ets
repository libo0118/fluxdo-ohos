import { media } from '@kit.MediaKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { MethodCall, MethodChannel } from '@ohos/flutter_ohos';
import { FlutterPlugin, FlutterPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import { MethodCallHandler, MethodResult } from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';

interface ProbeInfo {
  durationMs: number;
  hasVideo: boolean;
  width: number | null;
  height: number | null;
}

class TranscodeSpec {
  input: string;
  output: string;
  audioOnly: boolean;
  audioBitrate: number;
  videoBitrate: number | null;
  videoCodec: string;
  maxHeight: number | null;

  constructor(call: MethodCall) {
    this.input = localPath(call.argument('input'));
    this.output = localPath(call.argument('output'));
    if (this.input === this.output) throw new Error('输入和输出必须为不同文件');
    const audioOnly: Object | null = call.argument('audioOnly');
    if (audioOnly !== null && audioOnly !== undefined && typeof audioOnly !== 'boolean') {
      throw new Error('audioOnly 必须为布尔值');
    }
    this.audioOnly = audioOnly === true;
    this.audioBitrate = numberArgument(call, 'audioBitrate', 64000, 500000) as number;
    this.videoBitrate = numberArgument(call, 'videoBitrate', null, 100000000);
    this.maxHeight = numberArgument(call, 'maxHeight', null, 2160);
    const codec: Object | null = call.argument('videoCodec');
    this.videoCodec = codec === null || codec === undefined ? 'h264' : codec as string;
    if (this.videoCodec !== 'h264' && this.videoCodec !== 'hevc') {
      throw new Error('videoCodec 必须为 h264 或 hevc');
    }
    // shortcut: AVTranscoder 不提供降帧/重采样/声道转换；需要这些能力时接入底层 AVCodec。
    numberArgument(call, 'fps', null, 240);
    numberArgument(call, 'audioSampleRate', null, 192000);
    numberArgument(call, 'audioChannels', null, 32);
  }
}

function numberArgument(call: MethodCall, name: string, fallback: number | null, maximum: number): number | null {
  const value: Object | null = call.argument(name);
  if (value === null || value === undefined) return fallback;
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value <= 0 || value > maximum) {
    throw new Error(name + ' 超出有效范围');
  }
  return value;
}

function localPath(value: Object | null): string {
  if (typeof value !== 'string' || !value.startsWith('/') || value.includes('\u0000')) {
    throw new Error('媒体输入/输出必须为本地绝对路径');
  }
  const parts: string[] = [];
  value.split('/').forEach((part: string): void => {
    if (part === '..') parts.pop();
    else if (part !== '' && part !== '.') parts.push(part);
  });
  if (parts.length === 0) throw new Error('媒体路径不能为根目录');
  return '/' + parts.join('/');
}

function positiveMetadata(value: string | undefined): number | null {
  if (value === undefined || value.trim() === '') return null;
  const number = Number(value);
  return Number.isSafeInteger(number) && number > 0 ? number : null;
}

function configuration(spec: TranscodeSpec, info: ProbeInfo): media.AVTranscoderConfig {
  if (spec.audioOnly && info.hasVideo) {
    // shortcut: 公开 AVTranscoder 不能剥离视频轨；出现该调用时使用底层解复用/编码通道。
    throw new Error('鸿蒙系统转码暂不支持从视频单独提取音轨');
  }
  const config: media.AVTranscoderConfig = {
    audioBitrate: spec.audioBitrate,
    audioCodec: media.CodecMimeType.AUDIO_AAC,
    fileFormat: media.ContainerFormatType.CFT_MPEG_4
  };
  if (info.hasVideo && !spec.audioOnly) {
    config.videoCodec = spec.videoCodec === 'hevc' ? media.CodecMimeType.VIDEO_HEVC : media.CodecMimeType.VIDEO_AVC;
    if (spec.videoBitrate !== null) config.videoBitrate = spec.videoBitrate;
    if (info.width === null || info.height === null) throw new Error('无法读取视频尺寸');
    const scale = Math.min(1, 3840 / info.width, 2160 / info.height,
      spec.maxHeight === null ? 1 : spec.maxHeight / info.height);
    if (scale < 1) {
      const width = Math.floor(info.width * scale / 2) * 2;
      const height = Math.floor(info.height * scale / 2) * 2;
      if (width < 240 || height < 240) throw new Error('目标尺寸低于系统转码的 240 像素下限');
      config.videoFrameWidth = width;
      config.videoFrameHeight = height;
    }
  }
  return config;
}

class TranscodeJob {
  readonly spec: TranscodeSpec;
  readonly result: MethodResult;
  readonly temporary: string;
  cancelled: boolean = false;
  complete: boolean = false;
  error: BusinessError | null = null;
  wake: (() => void) | null = null;
  done: Promise<void> = Promise.resolve();

  constructor(spec: TranscodeSpec, result: MethodResult) {
    this.spec = spec;
    this.result = result;
    this.temporary = spec.output + '.fluxdo-' + util.generateRandomUUID() + '.tmp';
  }

  notify(): void {
    this.wake?.();
    this.wake = null;
  }

  wait(): Promise<void> {
    if (this.cancelled || this.complete || this.error !== null) return Promise.resolve();
    return new Promise<void>((resolve: () => void): void => { this.wake = resolve; });
  }
}

export default class FluxdoTranscodePlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private job: TranscodeJob | null = null;
  private lastProgress: number = 0;

  getUniqueClassName(): string { return 'FluxdoTranscodePlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'com.fluxdo/media_transcode');
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
    this.requestCancel();
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'probe':
        this.probe(call.arguments).then((info: ProbeInfo | null): void => result.success(info));
        break;
      case 'progress':
        result.success(this.lastProgress);
        break;
      case 'cancel':
        this.cancel().then((): void => result.success(null));
        break;
      case 'transcode':
        if (this.job !== null) { result.error('BUSY', '已有转码任务进行中', null); break; }
        try {
          const spec = new TranscodeSpec(call);
          const job = new TranscodeJob(spec, result);
          this.job = job;
          this.lastProgress = 0;
          job.done = this.run(job);
        } catch (error) {
          result.error('ARGS', (error as Error).message, null);
        }
        break;
      default:
        result.notImplemented();
    }
  }

  private async probe(path: Object | null): Promise<ProbeInfo | null> {
    let input: fs.File | null = null;
    let extractor: media.AVMetadataExtractor | null = null;
    try {
      input = fs.openSync(localPath(path), fs.OpenMode.READ_ONLY);
      const length = fs.statSync(input.fd).size;
      if (length <= 0) return null;
      extractor = await media.createAVMetadataExtractor();
      extractor.fdSrc = { fd: input.fd, offset: 0, length: length };
      const metadata = await extractor.fetchMetadata();
      const duration = positiveMetadata(metadata.duration);
      if (duration === null) return null;
      const info: ProbeInfo = {
        durationMs: duration,
        hasVideo: metadata.hasVideo === 'yes' || metadata.hasVideo === 'true' || metadata.hasVideo === '1',
        width: positiveMetadata(metadata.videoWidth),
        height: positiveMetadata(metadata.videoHeight)
      };
      return info;
    } catch (error) {
      return null;
    } finally {
      try { await extractor?.release(); } catch (error) {}
      if (input !== null) { try { fs.closeSync(input); } catch (error) {} }
    }
  }

  private requestCancel(): TranscodeJob | null {
    const job = this.job;
    if (job !== null) { job.cancelled = true; job.notify(); }
    return job;
  }

  private async cancel(): Promise<void> {
    const job = this.requestCancel();
    if (job !== null) await job.done;
  }

  private async run(job: TranscodeJob): Promise<void> {
    let input: fs.File | null = null;
    let output: fs.File | null = null;
    let transcoder: media.AVTranscoder | null = null;
    let prepared = false;
    let failure: Error | null = null;
    let success = false;
    try {
      const info = await this.probe(job.spec.input);
      if (job.cancelled) return;
      if (info === null) throw new Error('无法读取媒体信息');
      const config = configuration(job.spec, info);
      input = fs.openSync(job.spec.input, fs.OpenMode.READ_ONLY);
      this.rejectSameFile(input.fd, job.spec.output);
      if (fs.accessSync(job.temporary)) throw new Error('临时输出路径已存在');
      output = fs.openSync(job.temporary, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.NOFOLLOW);
      transcoder = await media.createAVTranscoder();
      if (job.cancelled) return;
      transcoder.on('progressUpdate', (progress: number): void => {
        if (this.job === job && !job.cancelled && Number.isFinite(progress)) {
          this.lastProgress = Math.max(this.lastProgress, Math.max(0, Math.min(1, progress / 100)));
        }
      });
      transcoder.on('error', (error: BusinessError): void => { job.error = error; job.notify(); });
      transcoder.on('complete', (): void => { job.complete = true; job.notify(); });
      transcoder.fdSrc = { fd: input.fd, offset: 0, length: fs.statSync(input.fd).size };
      transcoder.fdDst = output.fd;
      await transcoder.prepare(config);
      prepared = true;
      if (job.cancelled) return;
      if (job.error !== null) throw new Error(job.error.message);
      await transcoder.start();
      await job.wait();
      if (job.error !== null) throw new Error(job.error.message);
      success = job.complete && !job.cancelled;
    } catch (error) {
      failure = error as Error;
    } finally {
      if (transcoder !== null) {
        try {
          transcoder.off('progressUpdate'); transcoder.off('complete'); transcoder.off('error');
        } catch (error) {}
        if (job.cancelled && prepared) { try { await transcoder.cancel(); } catch (error) {} }
        try { await transcoder.release(); }
        catch (error) { failure = error as Error; success = false; }
      }
      for (const file of [input, output]) {
        if (file !== null) {
          try { fs.closeSync(file); }
          catch (error) { failure = error as Error; success = false; }
        }
      }
      if (success && !job.cancelled) {
        try {
          this.rejectSameFilePath(job.spec.input, job.spec.output);
          if (fs.statSync(job.temporary).size <= 0) throw new Error('转码输出为空');
          fs.renameSync(job.temporary, job.spec.output);
        } catch (error) { failure = error as Error; success = false; }
      }
      if (!success || job.cancelled) {
        try { if (output !== null && fs.accessSync(job.temporary)) fs.unlinkSync(job.temporary); }
        catch (error) { failure = error as Error; }
      }
      this.lastProgress = success && !job.cancelled ? 1 : 0;
      if (this.job === job) this.job = null;
      if (job.cancelled) job.result.success(false);
      else if (success) job.result.success(true);
      else job.result.error('TRANSCODE', failure?.message ?? '媒体转码失败', null);
    }
  }

  private rejectSameFile(inputFd: number, outputPath: string): void {
    if (fs.accessSync(outputPath) && fs.statSync(inputFd).ino === fs.statSync(outputPath).ino) {
      throw new Error('输入和输出指向同一文件');
    }
  }

  private rejectSameFilePath(inputPath: string, outputPath: string): void {
    if (fs.accessSync(outputPath) && fs.statSync(inputPath).ino === fs.statSync(outputPath).ino) {
      throw new Error('输入和输出指向同一文件');
    }
  }
}
