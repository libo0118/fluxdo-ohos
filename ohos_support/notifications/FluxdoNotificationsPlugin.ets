import { common, Want } from '@kit.AbilityKit';
import notificationManager from '@ohos.notificationManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import { MethodCall, MethodChannel } from '@ohos/flutter_ohos';
import { FlutterPlugin, FlutterPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import { MethodCallHandler, MethodResult } from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';

const CHANNEL = 'com.fluxdo/notifications';
const ACTION = 'com.github.molchuan.cfluxdo.NOTIFICATION';
const PAYLOAD = 'fluxdo.notification.payload';
const TOKEN = 'fluxdo.notification.token';

class NotificationTap {
  payload: string;
  token: string;
  constructor(payload: string, token: string) {
    this.payload = payload;
    this.token = token;
  }
}

function validPayload(payload: string): boolean {
  if (!/^(chat:[1-9][0-9]{0,15}|(topic|message):[1-9][0-9]{0,15}(:[1-9][0-9]{0,15})?)$/.test(payload)) return false;
  const parts = payload.split(':');
  return parts.slice(1).every((value: string): boolean => Number.isSafeInteger(Number(value)));
}

export default class FluxdoNotificationsPlugin implements FlutterPlugin, MethodCallHandler {
  static abilityContext: common.UIAbilityContext | null = null;
  private static taps: Array<NotificationTap> = [];
  private static seen: Array<string> = [];
  private static active: FluxdoNotificationsPlugin | null = null;
  private channel: MethodChannel | null = null;
  private pending: Promise<void> = Promise.resolve();
  private backgroundId: number | null = null;
  private backgroundTimer: number | null = null;
  private backgroundGeneration: number = 0;
  private publication: number = 0;

  static receiveWant(want: Want): void {
    if (want.action !== ACTION) return;
    const payload = want.parameters?.[PAYLOAD];
    const token = want.parameters?.[TOKEN];
    if (typeof payload !== 'string' || !validPayload(payload) || typeof token !== 'string' ||
      !/^[A-Za-z0-9._:-]{1,128}$/.test(token) || this.seen.includes(token)) return;
    this.seen.push(token);
    if (this.seen.length > 128) this.seen.shift();
    this.taps.push(new NotificationTap(payload, token));
    // 此处只发变更信号；点击留在原生队列，直到 Dart 主动读取。
    this.active?.channel?.invokeMethod('notificationsChanged', null);
  }

  getUniqueClassName(): string { return 'FluxdoNotificationsPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    this.channel.setMethodCallHandler(this);
    FluxdoNotificationsPlugin.active = this;
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
    try { this.endBackground(); } catch (_) {}
    if (FluxdoNotificationsPlugin.active === this) {
      FluxdoNotificationsPlugin.active = null;
      FluxdoNotificationsPlugin.abilityContext = null;
    }
  }

  private endBackground(): void {
    this.backgroundGeneration++;
    if (this.backgroundTimer !== null) clearTimeout(this.backgroundTimer);
    this.backgroundTimer = null;
    const id = this.backgroundId;
    this.backgroundId = null;
    if (id !== null) backgroundTaskManager.cancelSuspendDelay(id);
  }

  private expireBackground(generation: number): void {
    if (generation !== this.backgroundGeneration) return;
    const requestId = this.backgroundId;
    try { this.endBackground(); } catch (_) {}
    this.channel?.invokeMethod('backgroundExpired', requestId);
  }

  private beginBackground(): Map<string, number> {
    this.endBackground();
    const generation = this.backgroundGeneration;
    const info = backgroundTaskManager.requestSuspendDelay('完成正在进行的通知轮询', (): void => {
      this.expireBackground(generation);
    });
    if (!Number.isInteger(info.requestId) || info.requestId < 0 ||
      !Number.isFinite(info.actualDelayTime) || info.actualDelayTime <= 0) {
      if (Number.isInteger(info.requestId) && info.requestId >= 0) backgroundTaskManager.cancelSuspendDelay(info.requestId);
      throw new Error('系统未提供后台时间');
    }
    if (generation !== this.backgroundGeneration) {
      backgroundTaskManager.cancelSuspendDelay(info.requestId);
      throw new Error('后台任务已过期');
    }
    this.backgroundId = info.requestId;
    // 只完成这一段有限轮询，不重复申请系统额度维持无限运行。
    const remaining = Math.min(info.actualDelayTime, 30000);
    this.backgroundTimer = setTimeout((): void => this.expireBackground(generation), remaining);
    return new Map<string, number>([['requestId', info.requestId], ['remainingMs', remaining]]);
  }

  private async requestPermission(): Promise<boolean> {
    if (await notificationManager.isNotificationEnabled()) return true;
    const context = FluxdoNotificationsPlugin.abilityContext;
    if (context === null) throw new Error('通知插件未连接界面');
    try {
      await notificationManager.requestEnableNotification(context);
    } catch (_) {
      // 用户拒绝时 API 可能 reject；最终权限只能以系统重新查询为准。
    }
    return notificationManager.isNotificationEnabled();
  }

  private async publish(call: MethodCall): Promise<boolean> {
    const id = call.argument('id');
    const title = call.argument('title');
    const body = call.argument('body');
    const rawPayload = call.argument('payload');
    const progress = call.argument('progress');
    if (typeof id !== 'number' || !Number.isInteger(id) || id < 0 || id > 2147483647 ||
      typeof title !== 'string' || title.trim().length === 0 || typeof body !== 'string' ||
      (rawPayload !== null && (typeof rawPayload !== 'string' || !validPayload(rawPayload)))) {
      throw new Error('通知参数无效');
    }
    if (!(await notificationManager.isNotificationEnabled())) return false;
    const context = FluxdoNotificationsPlugin.abilityContext;
    if (context === null) throw new Error('通知插件未连接界面');
    const token = `${id}:${Date.now()}:${++this.publication}`;
    const parameters: Record<string, Object> = {};
    if (typeof rawPayload === 'string') {
      parameters[PAYLOAD] = rawPayload;
      parameters[TOKEN] = token;
    }
    const agent = await wantAgent.getWantAgent({
      wants: [{
        bundleName: context.abilityInfo.bundleName,
        moduleName: context.abilityInfo.moduleName,
        abilityName: context.abilityInfo.name,
        action: ACTION,
        parameters: parameters
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: id,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
    let text = body.trim().length > 0 ? body : title;
    if (typeof progress === 'number' && Number.isFinite(progress)) text += ` (${Math.max(0, Math.min(100, Math.round(progress)))}%)`;
    const request: notificationManager.NotificationRequest = {
      id: id,
      notificationSlotType: typeof rawPayload === 'string' ? notificationManager.SlotType.SOCIAL_COMMUNICATION : notificationManager.SlotType.SERVICE_INFORMATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: { title: title, text: text }
      },
      wantAgent: agent,
      tapDismissed: true,
      isAlertOnce: call.argument('alertOnce') === true
    };
    await notificationManager.publish(request);
    return true;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    // 后台时限不能被等待用户回应的通知权限窗口阻塞。
    if (call.method === 'beginBackground' || call.method === 'endBackground') {
      if (this.channel === null) { result.error('DETACHED', '通知插件已关闭。', null); return; }
      try {
        if (call.method === 'beginBackground') result.success(this.beginBackground());
        else {
          const expected = call.argument('requestId');
          if (expected !== null && (typeof expected !== 'number' || !Number.isInteger(expected) || expected < 0)) throw new Error('后台任务编号无效');
          if (expected === null || expected === this.backgroundId) this.endBackground();
          result.success(null);
        }
      } catch (_) { result.error('NOTIFICATION_FAILED', '系统后台任务操作失败。', null); }
      return;
    }
    const task = this.pending.then(async (): Promise<void> => {
      if (this.channel === null) { result.error('DETACHED', '通知插件已关闭。', null); return; }
      try {
        switch (call.method) {
          case 'isEnabled': result.success(await notificationManager.isNotificationEnabled()); break;
          case 'requestPermission': result.success(await this.requestPermission()); break;
          case 'publish': result.success(await this.publish(call)); break;
          case 'drainTaps': {
            const taps = FluxdoNotificationsPlugin.taps;
            FluxdoNotificationsPlugin.taps = [];
            result.success(taps.map((tap: NotificationTap): Map<string, string> =>
              new Map<string, string>([['payload', tap.payload], ['token', tap.token]])));
            break;
          }
          case 'clearTaps': FluxdoNotificationsPlugin.taps = []; result.success(null); break;
          case 'cancel': {
            const id = call.argument('id');
            if (typeof id !== 'number' || !Number.isInteger(id) || id < 0 || id > 2147483647) throw new Error('通知编号无效');
            await notificationManager.cancel(id);
            result.success(null);
            break;
          }
          case 'cancelAll': await notificationManager.cancelAll(); result.success(null); break;
          default: result.notImplemented();
        }
      } catch (_) {
        result.error('NOTIFICATION_FAILED', '系统通知操作失败。', null);
      }
    });
    this.pending = task.catch((): void => {});
  }
}
