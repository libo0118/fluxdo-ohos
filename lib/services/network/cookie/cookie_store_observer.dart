import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'session_cookie_sentinel.dart';
import 'boundary_sync_service.dart';
import 'cookie_jar_service.dart';
import '../../auth_session.dart';
import '../../../constants.dart';

/// 监听 WV cookie store 的外部变化,触发 sweep。
///
/// 设计依据: docs/cookie-sync-design-v0.4.0.md §5.5 (Phase B)
///
/// 工作流:
/// 1. macOS/iOS native 端注册 `WKHTTPCookieStoreObserver`,
///    cookie 变化时通过 channel `com.fluxdo/cookie_observer` 推送
///    `onCookiesChanged` 事件
/// 2. 本服务监听该事件,debounce 500ms 后对所有已知 url 跑 sweepAll
/// 3. native 端在我们自己 setCookie/delete 时通过 internalWriteCount
///    抑制通知, 避免 sweep → setCookie → 又通知 → sweep 死循环
///
/// 已知 url 由 [registerUrl] 维护 (通常在 Priming 时 register)。
/// OHOS 只消费当前主站页面的定向通知，不清扫历史注册 URL。
class CookieStoreObserver {
  CookieStoreObserver._()
      : _boundarySync = BoundarySyncService.instance,
        _ohosForTest = null;
  static final CookieStoreObserver instance = CookieStoreObserver._();

  @visibleForTesting
  CookieStoreObserver.forTest({
    required BoundarySyncService boundarySync,
    bool isOhos = true,
  }) : _boundarySync = boundarySync,
       _ohosForTest = isOhos;

  final BoundarySyncService _boundarySync;
  final bool? _ohosForTest;
  bool get _isOhos => _ohosForTest ?? io.Platform.operatingSystem == 'ohos';

  static const _channel = MethodChannel('com.fluxdo/cookie_observer');
  static const Duration _debounceWindow = Duration(milliseconds: 500);

  bool _attached = false;
  Timer? _debounce;
  final Set<String> _knownUrls = {};
  final Map<String, int> _ohosPendingUrls = {};
  bool _sweeping = false;

  Future<void> notifyOhosWebViewChange(InAppWebViewController controller) async {
    if (!_isOhos) return;
    final generation = AuthSession().generation;
    try {
      final raw = await controller.getUrl();
      final uri = raw == null ? null : Uri.tryParse(raw.toString());
      final trusted = Uri.parse(AppConstants.baseUrl);
      if (uri == null || uri.scheme != 'https' || uri.host != trusted.host ||
          uri.port != trusted.port || uri.userInfo.isNotEmpty ||
          !AuthSession().isValid(generation)) return;
      // The native snapshot stays local. Coalesce paths for the same trusted origin.
      _ohosPendingUrls[uri.replace(query: '', fragment: '').toString()] = generation;
      _onCookiesChanged();
    } catch (_) {
      // Navigation/disposal may invalidate the controller between the empty signal and URL read.
    }
  }

  /// native observer 支持的平台 (macOS / iOS)。
  ///
  /// Android 走 [notifyExternalChange] 由 WV onLoadStop 等 hook 主动触发。
  /// 其它平台 (Windows/Linux) 暂不支持,本服务无操作。
  bool get hasNativeObserver => io.Platform.isMacOS || io.Platform.isIOS;

  /// 启动监听。幂等,重复调用安全。
  ///
  /// Apple 平台会绑定 native `WKHTTPCookieStoreObserver` 通过 channel 通知;
  /// 其它平台依靠 [notifyExternalChange] 主动触发。
  void attach() {
    if (_attached) return;
    _attached = true;
    if (hasNativeObserver) {
      _channel.setMethodCallHandler(_handleNativeCall);
    }
    debugPrint(
      '[CookieObserver] attached on ${io.Platform.operatingSystem} '
      '(nativeObserver=$hasNativeObserver)',
    );
  }

  /// 由 Dart 端主动触发 (例如 WV onLoadStop / Android cookie 变化推测点)。
  ///
  /// 与 native observer 共享 debounce timer, 因此 Apple 平台同时由两端
  /// 触发也只会 sweep 一次 (debounce 内)。
  void notifyExternalChange() {
    _onCookiesChanged();
  }

  /// 注册一个 url, 后续 cookie change 事件会对这个 url 跑 sweepAll。
  ///
  /// 通常在 Priming 时调用 (priming 的 url 就是 WV 主域)。
  void registerUrl(String url) {
    if (url.isEmpty) return;
    _knownUrls.add(url);
  }

  /// 仅测试用。
  @visibleForTesting
  void resetForTest() {
    _debounce?.cancel();
    _debounce = null;
    _knownUrls.clear();
    _ohosPendingUrls.clear();
    _attached = false;
  }

  @visibleForTesting
  Future<void> flushForTest() {
    _debounce?.cancel();
    _debounce = null;
    return _doSweep();
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onCookiesChanged') {
      _onCookiesChanged();
    }
    return null;
  }

  void _onCookiesChanged() {
    _debounce?.cancel();
    _debounce = Timer(_debounceWindow, _doSweep);
  }

  Future<void> _doSweep() async {
    if (!_isOhos) return _sweepKnownUrls();
    if (_sweeping) return;
    _sweeping = true;
    try {
      final pending = Map<String, int>.from(_ohosPendingUrls);
      _ohosPendingUrls.clear();
      for (final entry in pending.entries) {
        await _boundarySync.syncFromWebView(
          currentUrl: entry.key,
          requestGeneration: entry.value,
          rejectLowConfidenceNonSessionCookies: true,
          excludeCookieNames: AuthSession().isLogoutGeneration(entry.value)
              ? CookieJarService.sessionCookieNames
              : null,
        );
      }
    } finally {
      _sweeping = false;
      if (_ohosPendingUrls.isNotEmpty) _onCookiesChanged();
    }
  }

  Future<void> _sweepKnownUrls() async {
    final urls = _knownUrls.toList(growable: false);
    if (urls.isEmpty) return;
    debugPrint(
      '[CookieObserver] external cookie change detected, sweepAll for $urls',
    );
    for (final url in urls) {
      try {
        final results = await SessionCookieSentinel.instance.sweepAll(url);
        final mismatch = results
            .where(
              (r) => r.variantsBefore != r.variantsAfter ||
                  r.variantsAfter > 1,
            )
            .toList();
        if (mismatch.isNotEmpty) {
          debugPrint(
            '[CookieObserver] sweepAll($url) handled ${mismatch.length} cookies: $mismatch',
          );
        }
      } catch (e) {
        debugPrint('[CookieObserver] sweepAll($url) failed: $e');
      }
    }
  }
}
