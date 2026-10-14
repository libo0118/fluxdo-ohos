"""CI 两阶段接入鸿蒙原生媒体；固定上游源码，模板漂移时停止而不写入半次补丁。"""

import argparse
import json
from pathlib import Path
import re
import tempfile
from urllib.parse import urljoin, urlsplit
from urllib.request import url2pathname

from prepare_ohos_identity import read_json


VIDEO_REF = "6b8fa1e5d3bf085bfe56423555d4ff608459ca4d"
AUDIO_REF = "6f251f641aeb5cb4e07e6b6edbb87b5983f4b2d0"
RECORD_REF = "4396313abb9aa24271bc30a2a6f85415480825f4"
VIDEO_REPOSITORY = "https://gitcode.com/openharmony-tpc/flutter_packages.git"
NATIVE_MARKER = "// Fluxdo OHOS 媒体补丁 v1。"
ENTRY_IMPORTS = [
    "import FluxdoMediaControlsPlugin from '../fluxdo/media/FluxdoMediaControlsPlugin';",
    "import RecordPlugin from 'record_ohos';",
]
ENTRY_BINDINGS = [
    "FluxdoMediaControlsPlugin.abilityContext = this.context;",
    "RecordPlugin.abilityContext = this.context;",
    "flutterEngine.getPlugins()?.add(new FluxdoMediaControlsPlugin());",
]


def replace_once(source, before, after):
    newline = "\r\n" if "\r\n" in source else "\n"
    before, after = (value.replace("\r\n", "\n").replace("\n", newline) for value in (before, after))
    if after and after in source:
        if source.count(after) != 1:
            raise AssertionError("媒体补丁重复")
        return source
    if source.count(before) != 1:
        raise AssertionError(f"媒体源码模板已改变：{before[:90]!r}")
    return source.replace(before, after)


def replace_region(source, begin, end, replacement):
    start = source.find(begin)
    stop = source.find(end, start + len(begin))
    if start < 0 or stop < 0 or source.count(begin) != 1:
        raise AssertionError(f"媒体方法模板已改变：{begin!r}")
    return source[:start] + replacement + source[stop:]


def git_dependency(name, url, revision, path=None):
    block = f"  {name}:\n    git:\n      url: {url}\n      ref: {revision}\n"
    if path:
        block += f"      path: {path}\n"
    return block


def prepare_dependencies(source, sections=("dependencies", "dependency_overrides")):
    dependencies = "".join([
        git_dependency("just_audio_ohos", "https://github.com/ClosedHarmony/just_audio_ohos.git", AUDIO_REF),
        git_dependency("record_ohos", "https://github.com/iptton-ai/record_ohos.git", RECORD_REF),
    ])
    overrides = "".join([
        git_dependency("video_player", VIDEO_REPOSITORY, VIDEO_REF, "packages/video_player/video_player"),
        git_dependency("video_player_ohos", VIDEO_REPOSITORY, VIDEO_REF, "packages/video_player/video_player_ohos"),
    ]) + "  record_platform_interface: 2.1.0\n"
    newline = "\r\n" if "\r\n" in source else "\n"
    for section, block in [("dependencies", dependencies), ("dependency_overrides", overrides)]:
        if section not in sections:
            continue
        headers = list(re.finditer(rf"(?m)^{section}:\r?\n", source))
        if len(headers) != 1:
            raise AssertionError(f"缺少唯一的 {section}")
        header = headers[0]
        marker = f"  # Fluxdo OHOS 原生媒体 {section}。{newline}"
        block = marker + block.replace("\n", newline)
        if marker in source:
            if source.count(marker) != 1 or block not in source:
                raise AssertionError("已有 OHOS 媒体依赖格式不符")
            continue
        for name in re.findall(r"(?m)^  ([a-z_]+):", block):
            # 只检查目标节，其他平台的原有依赖保留，由 OHOS override 选择实现。
            tail = source[header.end():]
            stop = re.search(r"(?m)^[^ \t#\r\n].*:", tail)
            existing = tail[:stop.start()] if stop else tail
            if re.search(rf"(?m)^  {re.escape(name)}:", existing):
                raise AssertionError(f"{section} 已包含 {name}，需先核对已有来源")
        source = source[:header.end()] + block + source[header.end():]
    return source


def package_root(repo, name):
    config_path = repo / ".dart_tool/package_config.json"
    config = json.loads(config_path.read_text(encoding="utf-8"))
    matches = [item for item in config["packages"] if item["name"] == name]
    if len(matches) != 1:
        raise AssertionError(f"pub get 必须解析唯一的 {name}")
    uri = urlsplit(urljoin(config_path.resolve().as_uri(), matches[0]["rootUri"]))
    if uri.scheme != "file" or uri.netloc not in ("", "localhost"):
        raise AssertionError(f"{name} 必须位于本地 pub package")
    return Path(url2pathname(uri.path))


def patch_entry(source):
    newline = "\r\n" if "\r\n" in source else "\n"
    for line in ENTRY_IMPORTS:
        if line not in source:
            source = line + newline + source
        elif source.count(line) != 1:
            raise AssertionError("EntryAbility 媒体 import 重复")
    anchor = re.compile(r"(?m)^([ \t]*)GeneratedPluginRegistrant\.registerWith\(flutterEngine\)[ \t]*;?[ \t]*(?:\r?\n|$)")
    matches = list(anchor.finditer(source))
    if len(matches) != 1:
        raise AssertionError("必须保留唯一的 GeneratedPluginRegistrant")
    present = [line in source for line in ENTRY_BINDINGS]
    if any(present):
        if not all(present) or any(source.count(line) != 1 for line in ENTRY_BINDINGS):
            raise AssertionError("EntryAbility 媒体接线不完整或重复")
        return source
    match = matches[0]
    injected = "".join(match.group(1) + line + newline for line in ENTRY_BINDINGS)
    original = match.group(0).rstrip("\r\n") + newline
    return source[:match.start()] + original + injected + source[match.end():]


def patch_permissions(manifest, strings):
    permissions = manifest["module"].setdefault("requestPermissions", [])
    matches = [item for item in permissions if item["name"] == "ohos.permission.MICROPHONE"]
    if len(matches) > 1:
        raise AssertionError("麦克风权限重复")
    if not matches:
        permissions.append({
            "name": "ohos.permission.MICROPHONE",
            "reason": "$string:fluxdo_microphone_reason",
            "usedScene": {"abilities": ["EntryAbility"], "when": "inuse"},
        })
    values = strings.setdefault("string", [])
    if not any(item["name"] == "fluxdo_microphone_reason" for item in values):
        values.append({"name": "fluxdo_microphone_reason", "value": "用于录制您主动发送的语音消息"})
    return manifest, strings


def patch_wakelock(source):
    source = source.replace("\r\n", "\n")
    source = replace_once(source,
        "import 'package:flutter/foundation.dart';",
        "import 'package:flutter/foundation.dart';\nimport 'package:flutter/services.dart';")
    source = replace_region(source,
        "  static Future<void> toggle(", "\n  /// Returns whether",
        "  static Future<void> toggle({required bool enable}) {\n"
        "    if (!kIsWeb && defaultTargetPlatform.name == 'ohos') {\n"
        "      return const MethodChannel('fluxdo/media_controls').invokeMethod<void>(\n"
        "        'toggle', <String, Object>{'enable': enable},\n"
        "      );\n    }\n"
        "    return wakelockPlusPlatformInstance.toggle(enable: enable);\n  }\n")
    return replace_once(source,
        "  static Future<bool> get enabled => wakelockPlusPlatformInstance.enabled;",
        "  static Future<bool> get enabled async {\n"
        "    if (!kIsWeb && defaultTargetPlatform.name == 'ohos') {\n"
        "      return await const MethodChannel('fluxdo/media_controls')\n"
        "          .invokeMethod<bool>('enabled') ?? false;\n    }\n"
        "    return wakelockPlusPlatformInstance.enabled;\n  }")


def patch_audio(source):
    source = source.replace("\r\n", "\n")
    if NATIVE_MARKER in source:
        source = replace_once(source, "REASON_OLD_DEVICE_UNAVALIABLE", "REASON_OLD_DEVICE_UNAVAILABLE")
        for required in ["createMediaSourceWithUrl(uri, headers)", "player.on('audioInterrupt'", "this.eventSink?.error", "setPlaybackRate(this.speed)"]:
            if required not in source:
                raise AssertionError("已有音频补丁不完整")
        return source
    source = NATIVE_MARKER + "\n" + source
    source = replace_once(source, "import { media } from '@kit.MediaKit';",
        "import { media } from '@kit.MediaKit';\nimport { audio } from '@kit.AudioKit';\nimport deviceInfo from '@ohos.deviceInfo';")
    source = re.sub(r"(?m)^[ \t]*Log\.[a-z]+\([^\n]*\);?\r?\n", "", source)
    source = source.replace("  Log,\n", "")
    source = source.replace("result.error('JUST_AUDIO_OHOS_ERROR', `${e}`, null);", "result.error('JUST_AUDIO_OHOS_ERROR', '原生音频操作失败。', null);")
    source = replace_once(source, "result.error('LOAD_ERROR', e.message, null);", "result.error('LOAD_ERROR', '音频加载失败。', null);")
    source = replace_once(source, "  private durationUs: number = -1;", "  private durationUs: number = -1;\n  private bufferedUs: number = 0;\n  private prepareTimer: number = -1;")
    source = replace_once(source, "    this.teardownPlayer();", "    this.teardownPlayer().catch((): void => {});")
    source = replace_once(source, "        case 'play':\n          this.handlePlay();\n          result.success(emptyMap());\n          break;",
        "        case 'play':\n          this.handlePlay().then((): void => result.success(emptyMap()))\n"
        "            .catch((): void => result.error('PLAY_ERROR', '音频播放失败。', null));\n          break;")
    source = replace_once(source, "        case 'pause':\n          this.handlePause();\n          result.success(emptyMap());\n          break;",
        "        case 'pause':\n          this.handlePause().then((): void => result.success(emptyMap()))\n"
        "            .catch((): void => result.error('PAUSE_ERROR', '音频暂停失败。', null));\n          break;")
    source = replace_region(source, "        case 'setVolume': {", "        case 'setSpeed': {", """        case 'setVolume': {
          const value: number = call.argument('volume') ?? 1;
          if (!Number.isFinite(value)) throw new Error('音量无效');
          this.volume = Math.max(0, Math.min(1, value));
          if (this.avPlayer !== null && this.prepared) this.avPlayer.setVolume(this.volume);
          this.emitPlayerData();
          result.success(emptyMap());
          break;
        }
""")
    source = replace_once(source, "    const uri = this.resolveLeafUri(source);",
        "    const leaf = this.resolveLeafSource(source);\n"
        "    if (leaf === null) throw new Error('不支持的音频来源');\n"
        "    const uri = (leaf.get('uri') ?? '') as string;\n    const headers: Record<string, string> = {};\n"
        "    const values = leaf.get('headers') as Map<string, Object> | null;\n"
        "    values?.forEach((value: Object, key: string): void => {\n"
        "      if (typeof value !== 'string' || /[\\r\\n]/.test(key + value)) throw new Error('请求头无效');\n"
        "      headers[key] = value;\n    });")
    source = replace_once(source, "    this.durationUs = -1;", "    this.durationUs = -1;\n    this.bufferedUs = 0;")
    source = replace_once(source, "    this.avPlayer = player;", "    this.avPlayer = player;\n"
        "    player.on('audioInterrupt', (event: audio.InterruptEvent): void => {\n"
        "      if (player !== this.avPlayer) return;\n"
        "      if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE ||\n"
        "          event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {\n"
        "        this.handlePause().catch((): void => this.reportError(5400107));\n"
        "      } else if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_DUCK) {\n"
        "        player.setVolume(this.volume * 0.2);\n"
        "      } else if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_UNDUCK) {\n"
        "        player.setVolume(this.volume);\n      }\n    });\n"
        "    player.on('audioOutputDeviceChangeWithInfo', (event: audio.AudioStreamDeviceChangeInfo): void => {\n"
        "      if (player === this.avPlayer && event.changeReason === audio.AudioStreamDeviceChangeReason.REASON_OLD_DEVICE_UNAVAILABLE) {\n"
        "        this.handlePause().catch((): void => this.reportError(5400107));\n      }\n    });\n"
        "    player.on('bufferingUpdate', (kind: media.BufferingInfoType, value: number): void => {\n"
        "      if (player !== this.avPlayer) return;\n"
        "      if (kind === media.BufferingInfoType.BUFFERING_START) this.processingState = PROCESSING_BUFFERING;\n"
        "      if (kind === media.BufferingInfoType.BUFFERING_END) this.processingState = PROCESSING_READY;\n"
        "      if (kind === media.BufferingInfoType.CACHED_DURATION) this.bufferedUs = this.positionUs + value * 1000;\n"
        "      this.emitPlaybackEvent();\n    });\n"
        "    player.on('seekDone', (time: number): void => {\n"
        "      if (player !== this.avPlayer) return;\n"
        "      this.positionUs = time * 1000;\n      this.emitPlaybackEvent();\n    });")
    source = replace_once(source, "      this.positionUs = timeMs * 1000;", "      if (player !== this.avPlayer) return;\n      this.positionUs = timeMs * 1000;")
    source = replace_once(source, "      this.durationUs = durationMs * 1000;", "      if (player !== this.avPlayer) return;\n      this.durationUs = durationMs * 1000;\n      this.emitPlaybackEvent();")
    source = replace_region(source, "    player.on('error'", "    const preparedFuture", "    player.on('error', (err: BusinessError): void => {\n      if (player === this.avPlayer) this.reportError(err.code);\n    });\n\n")
    source = replace_once(source, "      this.prepareRejecter = reject;", "      this.prepareRejecter = reject;\n"
        "      this.prepareTimer = setTimeout((): void => this.reportError(5400104), 30000);")
    source = replace_once(source, "    if (uri.startsWith('file://')) {", "    preparedFuture.catch((): void => {});\n    try {\n    if (uri.startsWith('file://')) {")
    source = replace_once(source, "      player.url = uri;", "      await player.setMediaSource(media.createMediaSourceWithUrl(uri, headers));")
    source = replace_once(source, "    await preparedFuture;", "    await preparedFuture;\n    } catch (error) {\n      await this.teardownPlayer();\n      throw new Error('音频加载失败。');\n    }")
    source = replace_region(source, "  private onStateChange(", "  private handlePlay(", """  private reportError(code: number): void {
    this.processingState = PROCESSING_IDLE;
    this.playing = false;
    this.pendingPlay = false;
    const rejecter = this.prepareRejecter;
    this.finishPreparation();
    rejecter?.(new Error('AVPlayer error ' + code));
    this.eventSink?.error(code.toString(), '原生音频操作失败。', null);
    this.emitPlaybackEvent();
    this.emitPlayerData();
  }

  private finishPreparation(): void {
    if (this.prepareTimer !== -1) clearTimeout(this.prepareTimer);
    this.prepareTimer = -1;
    this.prepareResolver = null;
    this.prepareRejecter = null;
  }

  private onStateChange(state: media.AVPlayerState, player: media.AVPlayer): void {
    if (this.destroyed || player !== this.avPlayer) return;
    switch (state) {
      case 'initialized':
        player.audioRendererInfo = { usage: audio.StreamUsage.STREAM_USAGE_MUSIC, rendererFlags: 0 };
        player.prepare().catch((error: BusinessError): void => this.reportError(error.code));
        break;
      case 'prepared': {
        this.prepared = true;
        this.durationUs = player.duration >= 0 ? player.duration * 1000 : -1;
        player.audioInterruptMode = audio.InterruptMode.INDEPENDENT_MODE;
        try {
          player.loop = this.loopMode !== 0;
          this.applySpeed();
          player.setVolume(this.volume);
          if (this.initialSeekUs > 0) player.seek(Math.floor(this.initialSeekUs / 1000));
        } catch (error) {
          this.reportError(5400102);
          return;
        }
        const resolver = this.prepareResolver;
        this.finishPreparation();
        this.processingState = PROCESSING_READY;
        resolver?.();
        this.emitPlaybackEvent();
        if (this.pendingPlay) {
          this.pendingPlay = false;
          this.handlePlay().catch((): void => this.reportError(5400102));
        }
        break;
      }
      case 'playing':
        this.playing = true;
        this.processingState = PROCESSING_READY;
        this.emitPlaybackEvent();
        this.emitPlayerData();
        break;
      case 'paused':
        this.playing = false;
        this.emitPlaybackEvent();
        this.emitPlayerData();
        break;
      case 'completed':
        this.playing = false;
        this.processingState = PROCESSING_COMPLETED;
        if (this.durationUs >= 0) this.positionUs = this.durationUs;
        this.emitPlaybackEvent();
        this.emitPlayerData();
        break;
      default:
        break;
    }
  }

"""
    )
    source = replace_region(source, "  private handlePlay(", "  /** Walks an AudioSource", """  private async handlePlay(): Promise<void> {
    const player = this.avPlayer;
    if (player === null) throw new Error('音频尚未加载');
    if (!this.prepared) { this.pendingPlay = true; return; }
    if (player.state === 'completed') player.seek(0);
    await player.play();
  }

  private async handlePause(): Promise<void> {
    this.pendingPlay = false;
    const player = this.avPlayer;
    if (player !== null && this.prepared && player.state === 'playing') await player.pause();
  }

  private handleSeek(call: MethodCall): void {
    const position: number | null = call.argument('position');
    if (position === null || !Number.isFinite(position) || position < 0) throw new Error('进度无效');
    const player = this.avPlayer;
    if (player === null || !this.prepared) throw new Error('音频尚未就绪');
    player.seek(Math.floor(position / 1000), media.SeekMode.SEEK_CLOSEST);
  }

  private applySpeed(): void {
    if (!Number.isFinite(this.speed) || this.speed < 0.125 || this.speed > 4) throw new Error('倍速无效');
    const player = this.avPlayer;
    if (player === null || !this.prepared) return;
    if (deviceInfo.sdkApiVersion >= 20) {
      player.setPlaybackRate(this.speed);
      return;
    }
    const values: Array<number> = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];
    const modes: Array<media.PlaybackSpeed> = [media.PlaybackSpeed.SPEED_FORWARD_0_50_X,
      media.PlaybackSpeed.SPEED_FORWARD_0_75_X, media.PlaybackSpeed.SPEED_FORWARD_1_00_X,
      media.PlaybackSpeed.SPEED_FORWARD_1_25_X, media.PlaybackSpeed.SPEED_FORWARD_1_50_X,
      media.PlaybackSpeed.SPEED_FORWARD_1_75_X, media.PlaybackSpeed.SPEED_FORWARD_2_00_X];
    const index = values.indexOf(this.speed);
    if (index < 0) throw new Error('当前系统不支持此倍速');
    player.setSpeed(modes[index]);
  }

"""
    )
    source = replace_once(source, "    this.prepareResolver = null;\n    this.prepareRejecter = null;\n    if (player != null) {", "    this.prepareRejecter?.(new Error('音频加载已取消'));\n    this.finishPreparation();\n    if (player != null) {")
    source = replace_once(source, "if (player.state != 'idle' && player.state != 'released' && player.state != 'error')", "if (player.state != 'released')")
    source = replace_once(source, "event.set('bufferedPosition', this.durationUs >= 0 ? this.durationUs : this.positionUs);", "event.set('bufferedPosition', this.durationUs >= 0 ? Math.min(this.bufferedUs, this.durationUs) : this.bufferedUs);")
    source = replace_once(source, "event.set('duration', this.durationUs);", "event.set('duration', this.durationUs >= 0 ? this.durationUs : null);")
    source = replace_region(source, "  /** Walks an AudioSource", "  private async teardownPlayer(", """  private resolveLeafSource(source: Map<string, Object> | null): Map<string, Object> | null {
    if (source === null) return null;
    const type = (source.get('type') ?? '') as string;
    if (['progressive', 'dash', 'hls'].includes(type)) return source;
    if (type === 'concatenating') {
      const children = source.get('children') as Array<Map<string, Object>>;
      // Fluxdo 的每个上传音频独占一个 player，根 playlist 仅有一个来源。
      if (children !== null && children.length === 1) return this.resolveLeafSource(children[0]);
    }
    return null;
  }

""")
    return source


def patch_record(source):
    source = source.replace("\r\n", "\n")
    if NATIVE_MARKER in source:
        if "getAudioCapturerMaxAmplitude()" not in source or "if (encoder !== 'aacLc')" not in source:
            raise AssertionError("已有录音补丁不完整")
        return source
    source = NATIVE_MARKER + "\n" + source
    source = replace_once(source, "import { audio } from '@kit.AudioKit';\n", "")
    source = replace_region(source, "  // Amplitude helpers", "  /** Set this in EntryAbility", "")
    source = replace_once(source, "  private stateHandlers: Map<string, StateStreamHandler> = new Map();", "  private stateHandlers: Map<string, StateStreamHandler> = new Map();\n  private stateChannels: Map<string, EventChannel> = new Map();")
    source = replace_once(source, "    this.stateHandlers.clear();", "    this.stateChannels.forEach((channel: EventChannel): void => channel.setStreamHandler(null));\n    this.stateChannels.clear();\n    this.stateHandlers.clear();")
    source = replace_once(source, "      eventCh.setStreamHandler(handler);", "      eventCh.setStreamHandler(handler);\n      this.stateChannels.set(recorderId, eventCh);")
    source = replace_once(source, "    // Release any existing recorder", "    if (encoder !== 'aacLc') throw new Error('当前录音仅支持 AAC-LC');\n"
        "    if (!path || !Number.isInteger(bitRate) || bitRate <= 0 ||\n"
        "        !Number.isInteger(sampleRate) || sampleRate <= 0 ||\n"
        "        !Number.isInteger(channels) || channels < 1 || channels > 2) throw new Error('录音参数无效');\n"
        "    if (rec.status !== 'stop') throw new Error('录音已经开始');\n    // Release any existing recorder")
    source = replace_once(source, "    const avRecorder = await media.createAVRecorder();", "    try {\n    const avRecorder = await media.createAVRecorder();")
    source = replace_once(source, "    await avRecorder.start();", "    await avRecorder.start();\n"
        "    } catch (error) {\n"
        "      await rec.avRecorder?.release().catch((): void => {});\n"
        "      rec.avRecorder = null;\n"
        "      if (rec.fd >= 0) { await fs.close(rec.fd); rec.fd = -1; }\n"
        "      await fs.unlink(path).catch((): void => {});\n"
        "      rec.filePath = '';\n      throw new Error('原生 AAC 录音启动失败');\n    }")
    source = replace_once(source, "      this.stateHandlers.delete(recorderId);", "      this.stateChannels.get(recorderId)?.setStreamHandler(null);\n      this.stateChannels.delete(recorderId);\n      this.stateHandlers.delete(recorderId);")
    source = replace_region(source, "  private async ensureAmplitudeHelper(", "  private onIsEncoderSupported(", """  private onGetAmplitude(recorderId: string, result: MethodResult): void {
    const rec = this.recorders.get(recorderId);
    if (rec === undefined || rec.avRecorder === null || rec.status !== 'recording') {
      const silent = new Map<string, Object>();
      silent.set('current', -160.0);
      silent.set('max', rec?.maxAmplitude ?? -160.0);
      result.success(silent);
      return;
    }
    rec.avRecorder.getAudioCapturerMaxAmplitude().then((amplitude: number): void => {
      const linear = Math.max(0, Math.min(1, amplitude / 32767));
      const dbfs = linear > 0 ? Math.max(-160, 20 * Math.log10(linear)) : -160;
      rec.maxAmplitude = Math.max(rec.maxAmplitude, dbfs);
      const value = new Map<string, Object>();
      value.set('current', dbfs);
      value.set('max', rec.maxAmplitude);
      result.success(value);
    }).catch((): void => result.error('amplitude_failed', '无法读取录音幅度。', null));
  }

"""
    )
    source = replace_once(source, "const supported = ['aacLc', 'aacHe', 'aacEld'];", "const supported = ['aacLc'];")
    source = replace_once(source,
        "result.success(this.recorders.get(recorderId)?.status === 'recording');",
        "result.success(['recording', 'paused'].includes(this.recorders.get(recorderId)?.status ?? 'stop'));")
    source = re.sub(r"result\.error\(('(?:start|stop|pause|resume|cancel|dispose)_failed'), err\.message, null\)", r"result.error(\1, '原生录音操作失败。', null)", source)
    return source


def patch_video(source):
    source = source.replace("\r\n", "\n")
    if NATIVE_MARKER in source:
        for details in ['null', '{}']:
            previous = "this.eventSink?.error('VideoError', '原生视频播放失败。', " + details + ");"
            if previous in source:
                source = replace_once(source, previous,
                    "this.eventSink?.error('VideoError', '原生视频播放失败。', new Map<string, Object>());")
        if "setPlaybackRate(rate)" not in source:
            raise AssertionError("已有视频补丁不完整")
        return source
    source = NATIVE_MARKER + "\n" + source
    # 不记录 URL、请求头或原生错误文本；错误通道只传稳定错误信息。
    source = replace_once(source, "import Log from '@ohos/flutter_ohos/src/main/ets/util/Log';", "import Log from './FluxdoMediaLog';")
    source = replace_once(source, 'console.error(TAG, "reportBufferedPositionFromPlaybackInfo error:" + JSON.stringify(e))', "Log.e(TAG, '缓冲位置读取失败');")
    source = replace_region(source, "  watchStatus() {", "  /**\n   * Sets the playback page size", "  watchStatus() {\n    // 窗口常亮由 Dart 播放 session 统一管理，避免多个播放器相互关闭。\n  }\n\n")
    source = replace_once(source, "    this.avPlayer.on(Events.TIME_UPDATE", "    this.avPlayer.on('audioInterrupt', (event: audio.InterruptEvent): void => {\n"
        "      if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE ||\n"
        "          event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) this.pause();\n"
        "    });\n\n    this.avPlayer.on(Events.TIME_UPDATE")
    source = replace_once(source, "              this.avPlayer.url = iUri;",
        "              if (iUri.startsWith('http')) {\n"
        "                this.avPlayer.setMediaSource(media.createMediaSourceWithUrl(iUri, this.headers))\n"
        "                  .catch((error: BusinessError): void => this.sendError(error));\n"
        "              } else { this.avPlayer.url = iUri; }")
    source = replace_once(source, "          this.avPlayer.prepare();",
        "          this.avPlayer.prepare().catch((error: BusinessError): void => this.sendError(error));")
    source = replace_once(source, "      this.avPlayer?.reset();", "")
    source = replace_once(source, "  setSpeed(playSpeed: number) {", "  setPlaybackRate(rate: number): void {\n"
        "    if (!Number.isFinite(rate) || rate < 0.125 || rate > 4) throw new Error('倍速无效');\n"
        "    this.avPlayer?.setPlaybackRate(rate);\n  }\n\n  setSpeed(playSpeed: number) {")
    source = replace_region(source, "  sendError(error: Object): void {", "  getIUri(): string {", "  sendError(error: Object): void {\n    this.eventSink?.error('VideoError', '原生视频播放失败。', new Map<string, Object>());\n  }\n\n")
    # 单个 Flutter 视频结束时无需访问示例应用的全局播放列表。
    source = replace_region(source, "          if (!this.loop) {", "          break;\n        case AvplayerStatus.RELEASED:", "          if (!this.loop) this.pendingPlay = false;\n")
    return source


def patch_video_api(source):
    source = source.replace("\r\n", "\n")
    return replace_once(source, "      const enumSpeed = mapPlaybackSpeed(speed);", "      if (deviceInfo.sdkApiVersion >= 20) {\n        videoPlayer.setPlaybackRate(speed);\n        return;\n      }\n      const enumSpeed = mapPlaybackSpeed(speed);") if "import deviceInfo from '@ohos.deviceInfo';" in source else patch_video_api(replace_once(source, "import { image } from '@kit.ImageKit';", "import { image } from '@kit.ImageKit';\nimport deviceInfo from '@ohos.deviceInfo';"))


def write_prepared(prepared):
    changed = []
    for path, data in prepared.items():
        if path.is_file() and path.read_bytes() == data:
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        changed.append(path)
    return changed


def prepare(repo, stage):
    repo = Path(repo).resolve()
    if stage == "before-pub-get":
        pubspec = repo / "pubspec.yaml"
        overrides = repo / "pubspec_overrides.yaml"
        # pub 的 overrides 文件替换整个 override 节，媒体实现必须写入实际生效的节。
        sections = ("dependencies",) if overrides.is_file() else ("dependencies", "dependency_overrides")
        prepared = {pubspec: prepare_dependencies(pubspec.read_bytes().decode("utf-8"), sections).encode("utf-8")}
        if overrides.is_file():
            prepared[overrides] = prepare_dependencies(overrides.read_bytes().decode("utf-8"), ("dependency_overrides",)).encode("utf-8")
        return write_prepared(prepared)
    prepared = {}
    paths = {
        package_root(repo, "wakelock_plus") / "lib/wakelock_plus.dart": patch_wakelock,
        package_root(repo, "just_audio_ohos") / "ohos/src/main/ets/plugins/JustAudioOhosPlugin.ets": patch_audio,
        package_root(repo, "record_ohos") / "ohos/src/main/ets/RecordPlugin.ets": patch_record,
        package_root(repo, "video_player_ohos") / "ohos/src/main/ets/components/videoplayer/VideoPlayer.ets": patch_video,
        package_root(repo, "video_player_ohos") / "ohos/src/main/ets/components/videoplayer/VideoPlayerApiImpl.ets": patch_video_api,
        repo / "ohos/entry/src/main/ets/entryability/EntryAbility.ets": patch_entry,
    }
    for path, patch in paths.items():
        prepared[path] = patch(path.read_bytes().decode("utf-8")).encode("utf-8")
    video_directory = package_root(repo, "video_player_ohos") / "ohos/src/main/ets/components/videoplayer"
    prepared[video_directory / "FluxdoMediaLog.ets"] = ("export default class FluxdoMediaLog {\n"
        "  static i(tag: string, message: string): void {}\n  static d(tag: string, message: string): void {}\n"
        "  static w(tag: string, message: string): void {}\n  static e(tag: string, message: string): void {}\n}\n").encode("utf-8")
    native = repo / "ohos_support/media/FluxdoMediaControlsPlugin.ets"
    prepared[repo / "ohos/entry/src/main/ets/fluxdo/media" / native.name] = native.read_bytes()
    manifest_path = repo / "ohos/entry/src/main/module.json5"
    strings_path = repo / "ohos/entry/src/main/resources/base/element/string.json"
    manifest, strings = patch_permissions(read_json(manifest_path), read_json(strings_path))
    prepared[manifest_path] = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    prepared[strings_path] = (json.dumps(strings, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    return write_prepared(prepared)


def self_test(source_root=None):
    source = "dependencies:\n  just_audio: ^0.10.6\ndependency_overrides:\n  other: 1.0.0\ndev_dependencies:\n  flutter_test:\n    sdk: flutter\n"
    patched = prepare_dependencies(source)
    assert prepare_dependencies(patched) == patched
    assert VIDEO_REF in patched and AUDIO_REF in patched and RECORD_REF in patched
    assert "  other: 1.0.0" in patched
    with tempfile.TemporaryDirectory(prefix="fluxdo-media-overrides-") as temporary:
        repo = Path(temporary)
        (repo / "pubspec.yaml").write_text(source, encoding="utf-8")
        override = repo / "pubspec_overrides.yaml"
        override.write_text("dependency_overrides:\n  existing: 2.0.0\n", encoding="utf-8")
        assert len(prepare(repo, "before-pub-get")) == 2
        assert prepare(repo, "before-pub-get") == []
        assert VIDEO_REF in override.read_text(encoding="utf-8")
        assert "  existing: 2.0.0" in override.read_text(encoding="utf-8")
        assert VIDEO_REF not in (repo / "pubspec.yaml").read_text(encoding="utf-8")
    entry = "import ExistingSecurePlugin from '../secure';\nclass EntryAbility {\n  configureFlutterEngine(flutterEngine) {\n    GeneratedPluginRegistrant.registerWith(flutterEngine)\n    flutterEngine.getPlugins()?.add(new ExistingSecurePlugin());\n  }\n}\n"
    patched = patch_entry(entry.replace("\n", "\r\n"))
    assert patch_entry(patched) == patched
    assert patched.count("GeneratedPluginRegistrant.registerWith") == 1
    assert "new ExistingSecurePlugin()" in patched
    assert patched.count("\n") == patched.count("\r\n")
    manifest = {"module": {"requestPermissions": [{"name": "ohos.permission.INTERNET"}]}}
    strings = {"string": [{"name": "existing", "value": "保留"}]}
    first = json.dumps(patch_permissions(manifest, strings), ensure_ascii=False)
    assert json.dumps(patch_permissions(manifest, strings), ensure_ascii=False) == first
    assert len(manifest["module"]["requestPermissions"]) == 2
    assert manifest["module"]["requestPermissions"][1]["usedScene"]["when"] == "inuse"
    with tempfile.TemporaryDirectory(prefix="fluxdo-media-") as temporary:
        base = Path(temporary)
        manifest_path = base / "module.json5"
        manifest_path.write_text('{/* Flutter template */ "module": {"url": "https://linux.do/a,}", "requestPermissions": [{"name": "ohos.permission.INTERNET"},],},}', encoding="utf-8")
        parsed = read_json(manifest_path)["module"]
        assert parsed["url"] == "https://linux.do/a,}"
        assert parsed["requestPermissions"] == [{"name": "ohos.permission.INTERNET"}]
        config = base / ".dart_tool/package_config.json"
        config.parent.mkdir()
        package = base / "package with spaces"
        package.mkdir()
        config.write_text(json.dumps({"packages": [{"name": "test", "rootUri": package.as_uri()}]}), encoding="utf-8")
        assert package_root(base, "test") == package
    try:
        patch_entry("模板已改变")
    except AssertionError:
        pass
    else:
        raise AssertionError("模板漂移必须拒绝")
    if source_root is not None:
        source_root = Path(source_root)
        fixtures = [
            (source_root / "pub-packages/wakelock_plus-1.3.3/lib/wakelock_plus.dart", patch_wakelock),
            (source_root / "audio-source/ClosedHarmony-just_audio_ohos-6f251f6/ohos/src/main/ets/plugins/JustAudioOhosPlugin.ets", patch_audio),
            (source_root / "record-source/iptton-ai-record_ohos-4396313/ohos/src/main/ets/RecordPlugin.ets", patch_record),
            (source_root / "flutter-video-ohos/packages/video_player/video_player_ohos/ohos/src/main/ets/components/videoplayer/VideoPlayer.ets", patch_video),
            (source_root / "flutter-video-ohos/packages/video_player/video_player_ohos/ohos/src/main/ets/components/videoplayer/VideoPlayerApiImpl.ets", patch_video_api),
        ]
        for path, patch in fixtures:
            patched = patch(path.read_text(encoding="utf-8"))
            assert patch(patched) == patched, path.name + " 幂等失败"
            if patch is patch_audio:
                assert "Log." not in patched
                assert "createMediaSourceWithUrl(uri, headers)" in patched
                assert "this.eventSink?.error" in patched and "this.prepareTimer = setTimeout" in patched
                assert "player.seek(Math.floor(position / 1000), media.SeekMode.SEEK_CLOSEST)" in patched
                assert "REASON_OLD_DEVICE_UNAVAILABLE" in patched
                assert patch_audio(patched.replace("REASON_OLD_DEVICE_UNAVAILABLE", "REASON_OLD_DEVICE_UNAVALIABLE")) == patched
            if patch is patch_video:
                report = "this.eventSink?.error('VideoError', '原生视频播放失败。', new Map<string, Object>());"
                assert report in patched
                for details in ['null', '{}']:
                    assert patch_video(patched.replace(report, report.replace('new Map<string, Object>()', details))) == patched
            if patch is patch_record:
                assert "getMaxAmplitudeForInputDevice" not in patched
                assert "getAudioCapturerMaxAmplitude()" in patched
                assert "await avRecorder.prepare(config)" in patched and "await avRecorder.start()" in patched
            print(f"固定上游补丁回归通过：{path.name}")
        with tempfile.TemporaryDirectory(prefix="fluxdo-media-integration-") as temporary:
            repo = Path(temporary) / "repo with spaces"
            repo.mkdir()
            (repo / "pubspec.yaml").write_text(source, encoding="utf-8")
            assert len(prepare(repo, "before-pub-get")) == 1
            assert prepare(repo, "before-pub-get") == []
            config = repo / ".dart_tool/package_config.json"
            config.parent.mkdir()
            packages = {}
            package_names = ["wakelock_plus", "just_audio_ohos", "record_ohos", "video_player_ohos", "video_player_ohos"]
            for (path, _), name in zip(fixtures, package_names):
                package = repo / "pub cache" / name
                packages[name] = package
                relative = path.as_posix().split('/lib/', 1)[-1] if name == "wakelock_plus" else path.as_posix().split('/ohos/', 1)[-1]
                destination = package / ("lib" if name == "wakelock_plus" else "ohos") / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(path.read_bytes())
            config.write_text(json.dumps({"packages": [{"name": name, "rootUri": package.as_uri()} for name, package in packages.items()]}), encoding="utf-8")
            entry_path = repo / "ohos/entry/src/main/ets/entryability/EntryAbility.ets"
            entry_path.parent.mkdir(parents=True)
            entry_path.write_text(entry, encoding="utf-8")
            manifest_path = repo / "ohos/entry/src/main/module.json5"
            manifest_path.write_text('// Flutter JSON5 template\n{"module": {"requestPermissions": [{"name": "ohos.permission.INTERNET"},],},}', encoding="utf-8")
            strings_path = repo / "ohos/entry/src/main/resources/base/element/string.json"
            strings_path.parent.mkdir(parents=True)
            strings_path.write_text(json.dumps({"string": []}), encoding="utf-8")
            native = repo / "ohos_support/media/FluxdoMediaControlsPlugin.ets"
            native.parent.mkdir(parents=True)
            native.write_bytes((Path(__file__).resolve().parents[1] / "ohos_support/media" / native.name).read_bytes())
            assert len(prepare(repo, "after-pub-get")) == 10
            assert prepare(repo, "after-pub-get") == []
            # 任一固定模板漂移时，其他已解析 package 不得被提前写入。
            wakelock_path = packages["wakelock_plus"] / "lib/wakelock_plus.dart"
            wakelock_path.write_bytes(fixtures[0][0].read_bytes())
            record_path = packages["record_ohos"] / "ohos/src/main/ets/RecordPlugin.ets"
            record_path.write_text("模板已改变", encoding="utf-8")
            try:
                prepare(repo, "after-pub-get")
            except AssertionError:
                pass
            else:
                raise AssertionError("固定插件模板漂移必须拒绝")
            assert wakelock_path.read_bytes() == fixtures[0][0].read_bytes()
        print("两阶段临时工程回归通过：权限、注册、pub cache 幂等和模板漂移")
    print("OHOS 媒体准备脚本自检通过")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=["before-pub-get", "after-pub-get", "--self-test"], nargs="?")
    parser.add_argument("repo", nargs="?", type=Path, default=Path.cwd())
    parser.add_argument("--self-test", action="store_true", dest="test")
    parser.add_argument("--source-root", type=Path)
    arguments = parser.parse_args()
    if arguments.test:
        self_test(arguments.source_root)
    elif arguments.stage in ("before-pub-get", "after-pub-get"):
        for changed in prepare(arguments.repo, arguments.stage):
            print(f"已准备 OHOS 媒体：{changed.name}")
    else:
        parser.error("请指定 before-pub-get、after-pub-get 或 --self-test")
