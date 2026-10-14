import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../../l10n/s.dart';
import 'notification_task_handler.dart';
import '../message_bus_service.dart';

/// 后台通知统一管理入口
///
/// Android 用前台服务保活进程，主 Isolate 的 MessageBus 长轮询继续运行。
class BackgroundNotificationService {
  static final BackgroundNotificationService _instance =
      BackgroundNotificationService._internal();
  factory BackgroundNotificationService() => _instance;
  BackgroundNotificationService._internal()
      : _testBus = null, _ohosForTest = false;
  @visibleForTesting
  BackgroundNotificationService.forTest(MessageBusService bus)
      : _testBus = bus, _ohosForTest = true;

  final MessageBusService? _testBus;
  MessageBusService get _bus => _testBus ?? MessageBusService();
  final bool _ohosForTest;
  bool _enabled = false;
  bool _androidInited = false;
  int _ohosGeneration = 0;
  int? _ohosRequestId;
  bool _ohosInBackground = false;
  static const _ohosChannel = MethodChannel('com.fluxdo/notifications');
  bool get _isOhos => _ohosForTest || Platform.operatingSystem == 'ohos';

  /// 初始化（在 main() 中调用一次）
  Future<void> initialize() async {}

  /// 启用后台通知（App 切后台时调用）
  Future<void> enable(int userId) async {
    if (_isOhos) {
      await enterOhosBackgroundMode(userId);
      return;
    }
    if (_enabled) return;
    _enabled = true;
    debugPrint('[BackgroundNotification] 启用后台通知, userId=$userId');
    await _startAndroidForegroundService();
  }

  Future<void> enterOhosBackgroundMode(int? userId) async {
    if (!_isOhos) return;
    if (_ohosInBackground && _enabled) return;
    _ohosInBackground = true;
    final generation = ++_ohosGeneration;
    _enabled = false;
    _ohosRequestId = null;
    if (userId != null && _bus.isPolling) {
      try {
        final budget = await _ohosChannel.invokeMapMethod<String, dynamic>('beginBackground');
        final requestId = budget?['requestId'];
        if (generation != _ohosGeneration || !_ohosInBackground) {
          if (requestId is int) {
            await _ohosChannel.invokeMethod<void>('endBackground', {'requestId': requestId});
          }
          return;
        }
        _enabled = requestId is int && budget?['remainingMs'] is num && (budget!['remainingMs'] as num) > 0;
        if (_enabled) _ohosRequestId = requestId as int;
      } catch (error) {
        debugPrint('[BackgroundNotification] 系统未提供短时后台额度: $error');
      }
    }
    if (generation != _ohosGeneration || !_ohosInBackground) return;
    _bus.enterBackgroundMode();
    if (!_enabled) _bus.pauseForOhosBackground();
  }

  /// 禁用后台通知（App 回前台时调用）
  Future<void> disable() async {
    if (_isOhos) {
      _ohosGeneration++;
      _enabled = false;
      _ohosRequestId = null;
      _ohosInBackground = false;
      await _ohosChannel.invokeMethod<void>('endBackground');
      return;
    }
    if (!_enabled) return;
    _enabled = false;
    debugPrint('[BackgroundNotification] 禁用后台通知');
    await _stopAndroidForegroundService();
  }

  bool get isEnabled => _enabled;

  /// 系统额度到期后不再发请求；前台恢复时保留的频道及 cursor 继续使用。
  void handleOhosExpired(int? requestId) {
    if (!_isOhos || !_ohosInBackground || !_enabled || requestId == null || requestId != _ohosRequestId) return;
    _ohosGeneration++;
    _enabled = false;
    _ohosRequestId = null;
    _bus.pauseForOhosBackground();
  }

  void _initAndroidForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'foreground_service',
        channelName: S.current.notification_channelBackground,
        channelDescription: S.current.notification_channelBackgroundDesc,
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        // 使用应用默认图标
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // 不需要周期性事件，主 Isolate 的 MessageBus 已在轮询
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  Future<void> _startAndroidForegroundService() async {
    // 延迟到首次启动服务时初始化，此时 navigatorKey.currentContext 已可用
    if (!_androidInited) {
      _androidInited = true;
      _initAndroidForegroundTask();
    }

    final serviceRunning = await FlutterForegroundTask.isRunningService;
    if (serviceRunning) {
      debugPrint('[BackgroundNotification] Android 前台服务已在运行');
      return;
    }

    await FlutterForegroundTask.startService(
      serviceId: 200,
      notificationTitle: 'cfluxdo',
      notificationText: S.current.notification_backgroundRunning,
      callback: startNotificationTaskHandler,
    );
    debugPrint('[BackgroundNotification] Android 前台服务已启动');
  }

  Future<void> _stopAndroidForegroundService() async {
    final serviceRunning = await FlutterForegroundTask.isRunningService;
    if (!serviceRunning) return;

    await FlutterForegroundTask.stopService();
    debugPrint('[BackgroundNotification] Android 前台服务已停止');
  }
}
