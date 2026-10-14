import 'dart:async';
import 'dart:io' as io;

import 'package:cookie_jar/cookie_jar.dart';
import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/constants.dart';
import 'package:fluxdo/services/auth_session.dart';
import 'package:fluxdo/services/cf_clearance_authority.dart';
import 'package:fluxdo/services/network/cookie/boundary_sync_service.dart';
import 'package:fluxdo/services/network/cookie/cookie_full_info.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';
import 'package:fluxdo/services/network/cookie/cookie_store_observer.dart';
import 'package:fluxdo/services/network/cookie/raw_cookie_writer.dart';
import 'package:fluxdo/services/network/cookie/session_cookie_sentinel.dart';
import 'package:fluxdo/services/network/cookie/strategy/platform_cookie_strategy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final uri = Uri.parse(AppConstants.baseUrl);
  late _TestJar jar;
  late _TestStrategy strategy;
  late BoundarySyncService boundary;
  late CookieStoreObserver observer;
  late _TestRawWriter rawWriter;

  Cookie fullCookie(String name, String value) => Cookie(
    name: name,
    value: value,
    domain: uri.host,
    path: '/',
    isSecure: true,
    isHttpOnly: true,
  );

  Future<Map<String, String>> saved() async => {
    for (final cookie in await jar.cookieJar.loadForRequest(uri))
      cookie.name: cookie.value,
  };

  setUp(() {
    AuthSession().advance();
    jar = _TestJar();
    strategy = _TestStrategy();
    boundary = BoundarySyncService.forTest(jar: jar, strategy: strategy);
    observer = CookieStoreObserver.forTest(boundarySync: boundary);
    rawWriter = _TestRawWriter();
    SessionCookieSentinel.instance
      ..resetForTest()
      ..replaceDependenciesForTest(writer: rawWriter, jar: jar);
    CfClearanceAuthority.instance
      ..reset()
      ..debugCookieReader = () => jar.getCanonicalCookie('cf_clearance');
  });

  tearDown(() {
    observer.resetForTest();
    SessionCookieSentinel.instance
      ..resetForTest()
      ..replaceDependenciesForTest(
        writer: RawCookieWriter.instance,
        jar: CookieJarService(),
      );
    CfClearanceAuthority.instance
      ..reset()
      ..debugCookieReader = null;
    AuthSession().advance();
  });

  test('advancing while Jar initialization waits drops the old session', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    jar.initialized = false;
    jar.beforeInitialize = () async {
      started.complete();
      await release.future;
    };
    strategy.cookies = [fullCookie('_t', 'old-session')];

    final syncing = boundary.syncFromWebView(
      requestGeneration: AuthSession().generation,
    );
    await started.future;
    AuthSession().advanceForLogout();
    release.complete();
    await syncing;

    expect(await saved(), isEmpty);
    expect(jar.policyCalls, 0);
  });

  test('OHOS implicit generation also protects initialization wait', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    jar.initialized = false;
    jar.beforeInitialize = () async {
      started.complete();
      await release.future;
    };
    strategy.cookies = [fullCookie('_forum_session', 'old-session')];

    final syncing = boundary.syncFromWebView();
    await started.future;
    AuthSession().advance();
    release.complete();
    await syncing;

    expect(await saved(), isEmpty);
  });

  test('OHOS boundary uses the guarded persistent save after cleanup', () async {
    final directory = await io.Directory.systemTemp.createTemp('cookie_boundary_epoch_');
    try {
      final persistentJar = _DelayedSaveJar(store: FileCookieStore(directory.path));
      jar = _TestJar(persistentJar);
      boundary = BoundarySyncService.forTest(jar: jar, strategy: strategy);
      strategy.cookies = [fullCookie('_t', 'old-session')];
      final syncing = boundary.syncFromWebView(
        requestGeneration: AuthSession().generation,
        trusted: true,
      );
      await persistentJar.saveStarted.future;
      AuthSession().advanceForLogout();
      await persistentJar.deleteAll();
      persistentJar.saveRelease.complete();
      await syncing;

      expect(await persistentJar.readAllCookies(), isEmpty);
      expect(jar.policyCalls, 0);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('late logout signal excludes sessions but keeps native clearance rules', () async {
    final generation = AuthSession().advanceForLogout();
    expect(AuthSession().isLogoutGeneration(generation), isTrue);
    strategy.cookies = [
      fullCookie('_t', 'old-session'),
      fullCookie('_forum_session', 'old-forum-session'),
      fullCookie('cf_clearance', 'new-clearance'),
    ];

    await observer.notifyOhosWebViewChange(_TestController('${uri}/t/1'));
    await observer.flushForTest();
    expect(await saved(), {'cf_clearance': 'new-clearance'});

    // A healthy incumbent still blocks a different WebView clearance.
    strategy.cookies = [fullCookie('cf_clearance', 'stale-clearance')];
    await observer.notifyOhosWebViewChange(_TestController('${uri}/t/1'));
    await observer.flushForTest();
    expect(await saved(), {'cf_clearance': 'new-clearance'});
  });

  test('explicit login accepts low-confidence session after logout', () async {
    AuthSession().advanceForLogout();
    strategy.cookies = [Cookie(name: '_t', value: 'new-session')];
    // The dialog's direct boundary is explicit even before finalize advances.
    await boundary.syncFromWebView(
      cookieNames: CookieJarService.authCookieNames,
      allowLowConfidenceSessionCookies: true,
      requestGeneration: AuthSession().generation,
      trusted: true,
    );
    expect(await saved(), {'_t': 'new-session'});

    final loginGeneration = AuthSession().advance();
    expect(AuthSession().isLogoutGeneration(loginGeneration), isFalse);
    strategy.cookies = [Cookie(name: '_t', value: 'finalized-session')];
    await boundary.syncFromWebView(
      cookieNames: CookieJarService.authCookieNames,
      allowLowConfidenceSessionCookies: true,
      requestGeneration: loginGeneration,
      trusted: true,
    );
    expect(await saved(), {'_t': 'finalized-session'});
  });

  test('explicit CF boundary retains old SDK name/value candidate support', () async {
    strategy.cookies = [Cookie(name: 'cf_clearance', value: 'verified-clearance')];
    expect(
      await boundary.readCfClearanceCandidatesFromWebView(),
      ['verified-clearance'],
    );
    expect(
      await boundary.readCookieValueFromWebView(name: 'cf_clearance'),
      'verified-clearance',
    );
    await boundary.syncFromWebView(
      cookieNames: const {'cf_clearance'},
      acceptValues: const {'cf_clearance': 'verified-clearance'},
      trusted: true,
    );
    expect(await saved(), {'cf_clearance': 'verified-clearance'});
  });

  test('OHOS trusted signal never sweeps registered third-party or low-confidence variants', () async {
    observer.registerUrl('https://example.com/post');
    observer.registerUrl('${uri}/previous');
    strategy.cookies = [
      Cookie(name: '_t', value: 'old-session'),
      Cookie(name: '_t', value: 'longer-old-session'),
      Cookie(name: 'cf_clearance', value: 'old-clearance'),
    ];

    await observer.notifyOhosWebViewChange(_TestController('${uri}/t/2?x=1#post'));
    await observer.flushForTest();

    expect(strategy.readUrls, ['${uri}/t/2']);
    expect(rawWriter.readUrls, isEmpty);
    expect(await saved(), isEmpty);

    strategy.readUrls.clear();
    observer.notifyExternalChange();
    await observer.flushForTest();
    expect(strategy.readUrls, isEmpty);
    expect(rawWriter.readUrls, isEmpty);
  });

  test('OHOS rejects untrusted signal and generation changes during URL read', () async {
    for (final url in [
      'https://example.com/',
      'http://${uri.host}/',
      'https://user@${uri.host}/',
      'https://${uri.host}:444/',
    ]) {
      await observer.notifyOhosWebViewChange(_TestController(url));
    }
    final urlReady = Completer<WebUri?>();
    final signal = observer.notifyOhosWebViewChange(
      _TestController.fromFuture(urlReady.future),
    );
    AuthSession().advanceForLogout();
    urlReady.complete(WebUri('${uri}/t/3'));
    await signal;
    await observer.flushForTest();
    expect(strategy.readUrls, isEmpty);
    expect(rawWriter.readUrls, isEmpty);
  });

  test('non-OHOS external notification retains the legacy sweep', () async {
    observer = CookieStoreObserver.forTest(
      boundarySync: boundary,
      isOhos: false,
    );
    observer.registerUrl('https://example.com/post');
    observer.notifyExternalChange();
    await observer.flushForTest();
    expect(rawWriter.readUrls, ['https://example.com/post']);
  });

  test('auth normalization pending after logout cannot restore its old winner', () async {
    final directory = await io.Directory.systemTemp.createTemp('cookie_policy_epoch_');
    try {
      final persistentJar = _DelayedPolicyJar(store: FileCookieStore(directory.path));
      await persistentJar.saveFromResponse(uri, [
        io.Cookie('_t', 'old-session')
          ..path = '/old'
          ..expires = DateTime.utc(2098),
      ]);
      final service = CookieJarService.forTest(jar: persistentJar);
      final generation = AuthSession().generation;
      final normalizing = service.enforceAuthCookiePolicy(
        names: const {'_t'},
        isCurrent: () => AuthSession().isValid(generation),
      );
      await persistentJar.replaceStarted.future;
      AuthSession().advanceForLogout();
      await persistentJar.deleteAll();
      persistentJar.replaceRelease.complete();

      expect(await normalizing, 0);
      expect(await persistentJar.readAllCookies(), isEmpty);
      expect(
        await EnhancedPersistCookieJar(store: FileCookieStore(directory.path)).readAllCookies(),
        isEmpty,
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });
}

class _DelayedPolicyJar extends EnhancedPersistCookieJar {
  _DelayedPolicyJar({required super.store});

  final replaceStarted = Completer<void>();
  final replaceRelease = Completer<void>();

  @override
  Future<int> replaceByNameForSite(
    Uri uri,
    String name,
    List<CanonicalCookie> replacements, {
    bool Function()? isCurrent,
  }) async {
    replaceStarted.complete();
    await replaceRelease.future;
    return super.replaceByNameForSite(
      uri,
      name,
      replacements,
      isCurrent: isCurrent,
    );
  }
}

class _DelayedSaveJar extends EnhancedPersistCookieJar {
  _DelayedSaveJar({required super.store});

  final saveStarted = Completer<void>();
  final saveRelease = Completer<void>();

  @override
  Future<bool> saveFromResponseGuarded(
    Uri uri,
    List<io.Cookie> cookies, {
    required bool Function() isCurrent,
    bool trusted = false,
  }) async {
    saveStarted.complete();
    await saveRelease.future;
    return super.saveFromResponseGuarded(
      uri,
      cookies,
      isCurrent: isCurrent,
      trusted: trusted,
    );
  }
}

class _TestJar implements CookieJarService {
  _TestJar([CookieJar? cookies]) : _cookies = cookies ?? CookieJar();

  final CookieJar _cookies;
  bool initialized = true;
  Future<void> Function()? beforeInitialize;
  int policyCalls = 0;

  @override
  bool get isInitialized => initialized;

  @override
  CookieJar get cookieJar => _cookies;

  @override
  CookieManager get webViewCookieManager => _UnusedCookieManager();

  @override
  Future<void> initialize() async {
    await beforeInitialize?.call();
    initialized = true;
  }

  @override
  Future<CanonicalCookie?> getCanonicalCookie(String name) async {
    final uri = Uri.parse(AppConstants.baseUrl);
    for (final cookie in await _cookies.loadForRequest(uri)) {
      if (cookie.name == name) return SetCookieParser.fromIoCookie(cookie, uri: uri);
    }
    return null;
  }

  @override
  Future<List<CanonicalCookie>> loadCanonicalCookiesForRequest(Uri uri) async => [];

  @override
  Future<int> enforceAuthCookiePolicy({
    String reason = 'unknown',
    Iterable<String>? names,
    bool Function()? isCurrent,
  }) async {
    policyCalls++;
    return 0;
  }

  @override
  Future<DateTime> resolveSessionTokenExpiryFor(DateTime? candidate) async =>
      CookieJarService.resolveSessionTokenExpiry(candidate: candidate);

  @override
  Future<List<Map<String, dynamic>>> getCookieDiagnosticsForRequest(
    Uri uri, {
    Iterable<String>? names,
  }) async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedCookieManager implements CookieManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestStrategy implements PlatformCookieStrategy {
  List<Cookie> cookies = [];
  final List<String> readUrls = [];

  @override
  Future<List<Cookie>> readCookiesFromWebView(CookieManager manager, String url) async {
    readUrls.add(url);
    return cookies;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestController implements InAppWebViewController {
  _TestController(String url) : _url = Future.value(WebUri(url));
  _TestController.fromFuture(this._url);
  final Future<WebUri?> _url;

  @override
  Future<WebUri?> getUrl() => _url;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestRawWriter implements RawCookieWriter {
  final List<String> readUrls = [];

  @override
  Future<List<CookieFullInfo>> getAllCookieInfos(String url) async {
    readUrls.add(url);
    return [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
