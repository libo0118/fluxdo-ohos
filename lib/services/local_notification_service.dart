import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../l10n/s.dart';
import '../pages/chat/channel/chat_channel_page.dart';
import '../pages/topic_detail_page/topic_detail_page.dart';
import '../utils/notification_navigation.dart';
import 'background/background_notification_service.dart';
import 'notification_tap_queue.dart';

/// 全局 NavigatorKey，用于通知点击时导航
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// APK 更新通知的固定 ID，便于复用/取消同一条进度通知
const int apkUpdateNotificationId = 99001;

const String _apkUpdateChannelId = 'apk_update';

/// 本地系统通知服务
class LocalNotificationService {
  static final LocalNotificationService _instance = LocalNotificationService._internal();
  factory LocalNotificationService() => _instance;
  LocalNotificationService._internal();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  bool _permissionGranted = false;
  static const _ohosChannel = MethodChannel('com.fluxdo/notifications');
  bool get _isOhos => Platform.operatingSystem == 'ohos';
  final _ohosTaps = NotificationTapQueue();
  Future<void>? _initializingOhos;
  Future<void>? _drainingTaps;
  bool _tapDrainAgain = false;
  bool _navigatorReady = false;
  bool _authenticated = false;
  bool _requestedOhosPermission = false;
  int _tapSession = 0;

  /// 初始化通知服务
  Future<void> initialize() async {
    if (_initialized) return;
    if (_isOhos) {
      final initializing = _initializingOhos ??= _initializeOhos();
      try { await initializing; } finally { _initializingOhos = null; }
      return;
    }

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const linuxSettings = LinuxInitializationSettings(defaultActionName: 'Open');
    const windowsSettings = WindowsInitializationSettings(
      appName: 'FluxDO',
      appUserModelId: 'Com.FluxDO.FluxDO',
      guid: 'e965ef8c-b676-47c1-b6e7-297d63942974',
    );

    const settings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
      macOS: darwinSettings,
      linux: linuxSettings,
      windows: windowsSettings,
    );

    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );
    _initialized = true;
    debugPrint('[LocalNotification] 初始化完成');
    
    // 请求通知权限 (Android 13+)
    await _requestPermission();
  }

  Future<void> _initializeOhos() async {
    _ohosChannel.setMethodCallHandler((call) async {
      if (call.method == 'notificationsChanged') {
        await _drainOhosTaps();
      } else if (call.method == 'backgroundExpired') {
        BackgroundNotificationService().handleOhosExpired();
      }
    });
    _permissionGranted = await _ohosChannel.invokeMethod<bool>('isEnabled') ?? false;
    _initialized = true;
    await _drainOhosTaps();
  }

  /// MainPage 首帧之后才能弹系统权限窗口，点击还需等待登录态。
  void navigationReady({required bool authenticated}) {
    _navigatorReady = true;
    _authenticated = authenticated;
    _flushOhosTaps();
    if (_isOhos) {
      unawaited(_prepareOhosUi().catchError((Object error) {
        debugPrint('[LocalNotification] 鸿蒙通知初始化失败: $error');
      }));
    }
  }

  Future<void> _prepareOhosUi() async {
    await initialize();
    if (!_requestedOhosPermission && _navigatorReady) {
      _requestedOhosPermission = true;
      _permissionGranted = await _ohosChannel.invokeMethod<bool>('requestPermission') ?? false;
    } else {
      _permissionGranted = await _ohosChannel.invokeMethod<bool>('isEnabled') ?? false;
    }
    await _drainOhosTaps();
  }

  void setAuthenticated(bool authenticated) {
    _authenticated = authenticated;
    if (_isOhos && authenticated) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _flushOhosTaps());
    }
  }

  void navigationUnavailable() => _navigatorReady = false;

  Future<void> clearForLogout() async {
    if (!_isOhos) return;
    _tapSession++;
    _ohosTaps.clearPending();
    await initialize();
    await _ohosChannel.invokeMethod<void>('clearTaps');
    await _ohosChannel.invokeMethod<void>('cancelAll');
  }

  Future<void> _drainOhosTaps() {
    _tapDrainAgain = true;
    return _drainingTaps ??= _readOhosTaps().whenComplete(() => _drainingTaps = null);
  }

  Future<void> _readOhosTaps() async {
    do {
      _tapDrainAgain = false;
      final session = _tapSession;
      final taps = await _ohosChannel.invokeListMethod<dynamic>('drainTaps') ?? const [];
      if (session != _tapSession) continue;
      for (final tap in taps) {
        if (tap is Map && tap['payload'] is String && tap['token'] is String) {
          _ohosTaps.add(tap['payload'] as String, token: tap['token'] as String);
        }
      }
      _flushOhosTaps();
    } while (_tapDrainAgain);
  }

  void _flushOhosTaps() {
    final context = navigatorKey.currentContext;
    for (final target in _ohosTaps.takeReady(
      navigatorReady: _navigatorReady && context != null && context.mounted,
      authenticated: _authenticated,
    )) {
      final page = target.kind == 'chat'
          ? ChatChannelPage(channelId: target.id)
          : TopicDetailPage(topicId: target.id, scrollToPostNumber: target.postNumber);
      openNotificationPage(context!, page);
    }
  }

  Future<void> _publishOhos({required int id, required String title, required String body,
    String? payload, int? progress, bool alertOnce = false}) async {
    _permissionGranted = await _ohosChannel.invokeMethod<bool>('publish', {
      'id': id, 'title': title, 'body': body, 'payload': payload,
      'progress': progress, 'alertOnce': alertOnce,
    }) ?? false;
  }

  /// 通知点击回调
  void _onNotificationTapped(NotificationResponse response) {
    debugPrint('[LocalNotification] 通知被点击: payload=${response.payload}');

    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;

    // payload 格式: "topic:{topicId}[:{postNumber}]" 或
    // "message:{topicId}[:{postNumber}]"(私信,走私信平行视界栈)或
    // "chat:{channelId}"(聊天,直达聊天窗)。
    if (payload.startsWith('chat:')) {
      final channelId = int.tryParse(payload.substring(5));
      if (channelId == null) return;
      final chatPage = ChatChannelPage(channelId: channelId);
      final chatContext = navigatorKey.currentContext;
      if (chatContext != null && chatContext.mounted) {
        openNotificationPage(chatContext, chatPage);
        return;
      }
      navigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => chatPage),
      );
      return;
    }
    final isMessage = payload.startsWith('message:');
    if (!isMessage && !payload.startsWith('topic:')) return;
    final parts = payload.substring(isMessage ? 8 : 6).split(':');
    final topicId = int.tryParse(parts[0]);
    final postNumber = parts.length > 1 ? int.tryParse(parts[1]) : null;
    if (topicId == null) return;

    debugPrint(
      '[LocalNotification] 跳转到${isMessage ? "私信" : "话题"}: $topicId, 帖子: $postNumber',
    );

    // 与应用内通知落点一致:大屏页面弹窗、窄屏全屏路由(私信/话题
    // 同一入口,不再写工作区栈/切 tab)。拿不到 context(冷启动时通知
    // 先于根 widget 树就绪)退化为直接 push。
    final page = TopicDetailPage(
      topicId: topicId,
      scrollToPostNumber: postNumber,
    );
    final context = navigatorKey.currentContext;
    if (context != null && context.mounted) {
      openNotificationPage(context, page);
      return;
    }
    navigatorKey.currentState?.push(
      MaterialPageRoute(builder: (_) => page),
    );
  }

  /// 请求通知权限
  Future<void> _requestPermission() async {
    // Android 平台请求权限
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      final granted = await androidPlugin.requestNotificationsPermission();
      _permissionGranted = granted ?? false;
      debugPrint('[LocalNotification] Android 权限: $_permissionGranted');
    } else {
      // 非 Android 平台默认已授权
      _permissionGranted = true;
    }
  }

  /// 显示通知
  Future<void> show({
    required String title,
    required String body,
    int? id,
    int? topicId,
    int? postNumber,
    bool isPrivateMessage = false,
    int? chatChannelId,
  }) async {
    if (!_initialized) {
      await initialize();
    }

    if (!_isOhos && !_permissionGranted) {
      debugPrint('[LocalNotification] 权限未授予，跳过通知');
      return;
    }

    final androidDetails = AndroidNotificationDetails(
      'discourse_notifications',
      S.current.notification_channelDiscourse,
      channelDescription: S.current.notification_channelDiscourseDesc,
      importance: Importance.high,
      priority: Priority.high,
    );

    const darwinDetails = DarwinNotificationDetails();

    final details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
      windows: const WindowsNotificationDetails(),
    );

    final notificationId = id ?? DateTime.now().millisecondsSinceEpoch.remainder(100000);
    
    // 构建 payload 用于点击回调:私信用 message: 前缀,走私信自己的
    // 平行视界栈,不能跟普通话题共用 topic: 前缀(否则左栏会显示信息流)。
    // chat 通知用 chat: 前缀直达聊天窗。
    String? payload;
    if (chatChannelId != null) {
      payload = 'chat:$chatChannelId';
    } else if (topicId != null) {
      final prefix = isPrivateMessage ? 'message' : 'topic';
      payload = postNumber != null
          ? '$prefix:$topicId:$postNumber'
          : '$prefix:$topicId';
    }
    
    if (_isOhos) {
      await _publishOhos(id: notificationId, title: title, body: body, payload: payload);
      return;
    }
    await _plugin.show(id: notificationId, title: title, body: body, notificationDetails: details, payload: payload);
    debugPrint('[LocalNotification] 已发送: $title, payload=$payload');
  }

  /// 显示 APK 下载进度通知（持续更新同一条）。
  ///
  /// indeterminate=true 时显示无限循环进度条（用于"连接中/校验中"等阶段）。
  Future<void> showApkProgress({
    required String title,
    String? body,
    int progress = 0,
    bool indeterminate = false,
    int id = apkUpdateNotificationId,
  }) async {
    if (!_initialized) {
      await initialize();
    }
    if (_isOhos) {
      await _publishOhos(id: id, title: title, body: body ?? title,
        progress: indeterminate ? null : progress, alertOnce: true);
      return;
    }
    if (!_permissionGranted) return;

    final androidDetails = AndroidNotificationDetails(
      _apkUpdateChannelId,
      S.current.update_notification_channel,
      channelDescription: S.current.update_notification_channelDesc,
      importance: Importance.low,
      priority: Priority.low,
      showProgress: true,
      maxProgress: 100,
      progress: progress,
      indeterminate: indeterminate,
      ongoing: true,
      onlyAlertOnce: true,
      channelShowBadge: false,
      playSound: false,
      enableVibration: false,
    );

    final details = NotificationDetails(android: androidDetails);
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
    );
  }

  /// 显示 APK 下载完成通知（点击触发安装由 ota_update 自行发起 intent，
  /// 这里只是给用户一个可点击的入口拉起 App，不需要 payload）。
  Future<void> showApkComplete({
    required String title,
    required String body,
    int id = apkUpdateNotificationId,
  }) async {
    if (!_initialized) {
      await initialize();
    }
    if (_isOhos) {
      await _publishOhos(id: id, title: title, body: body);
      return;
    }
    if (!_permissionGranted) return;

    final androidDetails = AndroidNotificationDetails(
      _apkUpdateChannelId,
      S.current.update_notification_channel,
      channelDescription: S.current.update_notification_channelDesc,
      importance: Importance.high,
      priority: Priority.high,
      autoCancel: true,
    );

    final details = NotificationDetails(android: androidDetails);
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
    );
  }

  /// 取消指定通知
  Future<void> cancelNotification(int id) async {
    if (_isOhos) {
      await initialize();
      await _ohosChannel.invokeMethod<void>('cancel', {'id': id});
      return;
    }
    await _plugin.cancel(id: id);
  }
}
