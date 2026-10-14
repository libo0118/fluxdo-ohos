import { common } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { window } from '@kit.ArkUI';
import deviceInfo from '@ohos.deviceInfo';
import { MethodCall, MethodChannel } from '@ohos/flutter_ohos';
import { FlutterPlugin, FlutterPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import { MethodCallHandler, MethodResult } from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import EventChannel, { EventSink, StreamHandler } from '@ohos/flutter_ohos/src/main/ets/plugin/common/EventChannel';

const VOLUME_METHODS = 'com.kurenai7968.volume_controller.method';
const VOLUME_EVENTS = 'com.kurenai7968.volume_controller.volume_listener_event';
const MEDIA_METHODS = 'fluxdo/media_controls';

export default class FluxdoMediaControlsPlugin implements FlutterPlugin, MethodCallHandler, StreamHandler {
  static abilityContext: common.UIAbilityContext | null = null;
  private channels: Array<MethodChannel> = [];
  private events: EventChannel | null = null;
  private sink: EventSink | null = null;
  private readonly volumeManager: audio.AudioVolumeManager = audio.getAudioManager().getVolumeManager();
  private windowClass: window.Window | null = null;
  private originalKeepScreenOn: boolean = false;
  private keptScreenOn: boolean = false;
  private volumeBeforeMute: number = 0.5;
  private pending: Promise<void> = Promise.resolve();
  private readonly volumeChanged = (event: audio.VolumeEvent): void => {
    this.volume().then((value: number): void => this.sink?.success(value)).catch((): void => {});
  };

  getUniqueClassName(): string { return 'FluxdoMediaControlsPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    for (const name of [VOLUME_METHODS, MEDIA_METHODS]) {
      const channel = new MethodChannel(binding.getBinaryMessenger(), name);
      channel.setMethodCallHandler(this);
      this.channels.push(channel);
    }
    this.events = new EventChannel(binding.getBinaryMessenger(), VOLUME_EVENTS);
    this.events.setStreamHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channels.forEach((channel: MethodChannel): void => channel.setMethodCallHandler(null));
    this.channels = [];
    this.events?.setStreamHandler(null);
    this.events = null;
    this.onCancel(null);
    // 排队操作完成后恢复进入播放前的窗口属性。
    this.pending = this.pending.then(async (): Promise<void> => {
      if (this.windowClass !== null && this.keptScreenOn) {
        await this.windowClass.setWindowKeepScreenOn(this.originalKeepScreenOn);
      }
      this.windowClass = null;
      this.keptScreenOn = false;
    }).catch((): void => {});
  }

  private async volume(): Promise<number> {
    if (deviceInfo.sdkApiVersion < 19) throw new Error('当前系统没有应用音量接口');
    return Math.max(0, Math.min(1, (await this.volumeManager.getAppVolumePercentage()) / 100));
  }

  private async setVolume(value: number): Promise<void> {
    if (!Number.isFinite(value)) throw new Error('音量数值无效');
    if (deviceInfo.sdkApiVersion < 19) throw new Error('当前系统没有应用音量接口');
    // 普通应用只能调自身音量；系统总音量由实体音量键调整。
    await this.volumeManager.setAppVolumePercentage(Math.round(Math.max(0, Math.min(1, value)) * 100));
    this.sink?.success(await this.volume());
  }

  private async keepScreenOn(enable: boolean): Promise<void> {
    const context = FluxdoMediaControlsPlugin.abilityContext;
    if (context === null) throw new Error('媒体插件未连接界面');
    if (this.windowClass === null) this.windowClass = await window.getLastWindow(context);
    if (enable && !this.keptScreenOn) {
      this.originalKeepScreenOn = this.windowClass.getWindowProperties().isKeepScreenOn;
    }
    await this.windowClass.setWindowKeepScreenOn(enable ? true : this.originalKeepScreenOn);
    this.keptScreenOn = enable;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    const task = this.pending.then(async (): Promise<void> => {
      try {
        switch (call.method) {
          case 'getVolume':
            result.success(await this.volume());
            break;
          case 'setVolume': {
            const value: Object | null = call.argument('volume');
            if (typeof value !== 'number') throw new Error('音量参数无效');
            await this.setVolume(value);
            result.success(null);
            break;
          }
          case 'isMuted':
            result.success((await this.volume()) === 0);
            break;
          case 'setMute': {
            const mute: Object | null = call.argument('isMute');
            if (typeof mute !== 'boolean') throw new Error('静音参数无效');
            const current = await this.volume();
            if (mute && current > 0) this.volumeBeforeMute = current;
            await this.setVolume(mute ? 0 : this.volumeBeforeMute);
            result.success(null);
            break;
          }
          case 'toggle': {
            const enable: Object | null = call.argument('enable');
            if (typeof enable !== 'boolean') throw new Error('常亮参数无效');
            await this.keepScreenOn(enable);
            result.success(null);
            break;
          }
          case 'enabled':
            result.success(this.windowClass?.getWindowProperties().isKeepScreenOn ?? false);
            break;
          default:
            result.notImplemented();
        }
      } catch (error) {
        const volumeMethod = ['getVolume', 'setVolume', 'isMuted', 'setMute'].includes(call.method);
        result.error(volumeMethod && deviceInfo.sdkApiVersion < 19 ? 'unsupported' : 'media_control_error',
          '系统媒体控制失败。', null);
      }
    });
    this.pending = task.catch((): void => {});
  }

  onListen(arguments: Object | null, sink: EventSink): void {
    this.sink = sink;
    if (deviceInfo.sdkApiVersion >= 19) this.volumeManager.on('appVolumeChange', this.volumeChanged);
    const values = arguments as Map<string, Object> | null;
    if (values?.get('fetchInitialVolume') !== false) {
      this.volume().then((value: number): void => sink.success(value)).catch((): void => {
        sink.error('media_control_error', '无法读取媒体音量。', null);
      });
    }
  }

  onCancel(arguments: Object | null): void {
    this.sink = null;
    if (deviceInfo.sdkApiVersion >= 19) this.volumeManager.off('appVolumeChange', this.volumeChanged);
  }
}
