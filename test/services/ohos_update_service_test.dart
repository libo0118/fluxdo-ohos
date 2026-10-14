import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxdo/services/update_service.dart';

class _ReleaseAdapter implements HttpClientAdapter {
  final int status;
  final List<RequestOptions> requests = [];
  _ReleaseAdapter(this.status);

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream,
      Future<dynamic>? cancelFuture) async {
    requests.add(options);
    final body = status == 200
        ? {'tag_name': 'v1.2.0', 'html_url': 'https://github.com/1molchuan/fluxdo/releases/tag/v1.2.0', 'body': 'Release', 'assets': []}
        : {'message': 'Not Found'};
    return ResponseBody.fromString(jsonEncode(body), status,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType], 'etag': ['release-etag']});
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(appName: 'cfluxdo', packageName: 'com.github.molchuan.cfluxdo',
        version: '1.0.0', buildNumber: '2026101422', buildSignature: 'test');
  });

  test('HarmonyOS missing release returns no release and clears its ETag/cache', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ohos_update_etag', 'obsolete');
    await prefs.setString('ohos_update_cache', 'obsolete');
    await prefs.setInt('ohos_update_cache_time', 1);
    final adapter = _ReleaseAdapter(404);
    final service = UpdateService.forTest(dio: Dio()..httpClientAdapter = adapter, prefs: prefs, isOhos: true);
    expect(await service.checkForUpdate(), isNull);
    expect(adapter.requests.single.uri.toString(), 'https://api.github.com/repos/libo0118/fluxdo-ohos/releases/latest');
    expect(prefs.getString('ohos_update_etag'), isNull);
    expect(prefs.getString('ohos_update_cache'), isNull);
    expect(prefs.getInt('ohos_update_cache_time'), isNull);
  });

  test('Android missing release preserves the original error contract', () async {
    final adapter = _ReleaseAdapter(404);
    final service = UpdateService.forTest(dio: Dio()..httpClientAdapter = adapter,
        prefs: await SharedPreferences.getInstance(), isOhos: false);
    await expectLater(service.checkForUpdate(), throwsA(isA<DioException>()));
    expect(adapter.requests.single.uri.toString(), 'https://api.github.com/repos/1molchuan/fluxdo/releases/latest');
  });

  test('HarmonyOS cannot reuse an Android cached release or ETag', () async {
    final prefs = await SharedPreferences.getInstance();
    final android = _ReleaseAdapter(200);
    final service = UpdateService.forTest(dio: Dio()..httpClientAdapter = android, prefs: prefs, isOhos: false);
    expect((await service.checkForUpdate())?.hasUpdate, true);
    final harmony = _ReleaseAdapter(404);
    final harmonyService = UpdateService.forTest(dio: Dio()..httpClientAdapter = harmony, prefs: prefs, isOhos: true);
    expect(await harmonyService.checkForUpdate(useCache: true), isNull);
    expect(harmony.requests.single.headers.containsKey('If-None-Match'), false);
    expect((await service.checkForUpdate(useCache: true))?.remoteVersion, '1.2.0');
    expect(android.requests.length, 1);
    expect(prefs.getString('update_etag'), 'release-etag');
  });
}
