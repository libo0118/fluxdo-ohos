import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:fluxdo/services/background/background_notification_service.dart';
import 'package:fluxdo/services/message_bus_service.dart';

class _LatePollingAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final results = <Completer<ResponseBody>>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture) {
    requests.add(options);
    final result = Completer<ResponseBody>();
    results.add(result);
    return result.future;
  }

  @override
  void close({bool force = false}) {}

  void complete(int index, String body) => results[index].complete(ResponseBody.fromString(
    body, 200, headers: {Headers.contentTypeHeader: ['application/json']},
  ));

  Map<String, String> payload(int index) {
    final data = requests[index].data;
    return data is String ? Uri.splitQueryString(data) : Map<String, String>.from(data as Map);
  }
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('polling test timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('expired OHOS budget stops late poll and resumes existing cursors once', () async {
    final adapter = _LatePollingAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid'))..httpClientAdapter = adapter;
    final bus = MessageBusService.forTest(dio);
    final messages = <int>[];
    try {
      bus.subscribe('/a', (message) => messages.add(message.messageId));
      await _until(() => adapter.requests.length == 1);
      adapter.complete(0, '[{"channel":"/a","message_id":1,"data":null}]');
      await _until(() => adapter.requests.length == 2);
      expect(messages, [1]);
      bus.enterBackgroundMode();
      bus.pauseForOhosBackground();
      expect(bus.isPolling, isFalse);
      bus.subscribe('/b', (_) {});
      adapter.complete(1, '[{"channel":"/a","message_id":88,"data":null}]');
      await Future<void>.delayed(const Duration(milliseconds: 180));
      expect(adapter.requests.length, 2);
      expect(messages, [1]);
      bus.exitBackgroundMode();
      bus.exitBackgroundMode();
      await _until(() => adapter.requests.length == 3);
      expect(adapter.payload(2)['/a'], '1');
      expect(adapter.payload(2)['/b'], '-1');
      adapter.complete(2, '[{"channel":"/a","message_id":2,"data":null}]');
      await _until(() => messages.length == 2);
      expect(messages, [1, 2]);
      bus.pauseForOhosBackground();
      bus.stopAll();
      bus.exitBackgroundMode();
      await Future<void>.delayed(const Duration(milliseconds: 180));
      expect(adapter.requests.length, 3);
    } finally {
      bus.dispose();
      dio.close(force: true);
    }
  });

  test('late background budget cannot pause resumed foreground or discard cursor', () async {
    const channel = MethodChannel('com.fluxdo/notifications');
    final budget = Completer<Map<String, Object?>>();
    final cancelled = <Object?>[];
    var begins = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'beginBackground') { begins++; return budget.future; }
      if (call.method == 'endBackground') { cancelled.add((call.arguments as Map?)?['requestId']); return null; }
      throw StateError('Unexpected method ${call.method}');
    });
    final adapter = _LatePollingAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid'))..httpClientAdapter = adapter;
    final bus = MessageBusService.forTest(dio);
    final background = BackgroundNotificationService.forTest(bus);
    try {
      bus.subscribe('/a', (_) {});
      await _until(() => adapter.requests.length == 1);
      adapter.complete(0, '[{"channel":"/a","message_id":1,"data":null}]');
      await _until(() => adapter.requests.length == 2);
      final pending = background.enterOhosBackgroundMode(7);
      await _until(() => begins == 1);
      await background.disable();
      bus.exitBackgroundMode();
      budget.complete({'requestId': 42, 'remainingMs': 30000});
      await pending;
      background.handleOhosExpired(42);
      expect(background.isEnabled, isFalse);
      expect(bus.isPolling, isTrue);
      expect(cancelled, contains(42));
      adapter.complete(1, '[{"channel":"/a","message_id":2,"data":null}]');
      await _until(() => adapter.requests.length == 3);
      expect(adapter.payload(2)['/a'], '2');
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      bus.dispose();
      dio.close(force: true);
    }
  });

  test('expired old budget after foreground or a new background grant is ignored', () async {
    const channel = MethodChannel('com.fluxdo/notifications');
    var requestId = 9;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'beginBackground') return {'requestId': ++requestId, 'remainingMs': 30000};
      if (call.method == 'endBackground') return null;
      throw StateError('Unexpected method ${call.method}');
    });
    final adapter = _LatePollingAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid'))..httpClientAdapter = adapter;
    final bus = MessageBusService.forTest(dio);
    final background = BackgroundNotificationService.forTest(bus);
    try {
      bus.subscribe('/a', (_) {});
      await _until(() => adapter.requests.length == 1);
      adapter.complete(0, '[{"channel":"/a","message_id":1,"data":null}]');
      await _until(() => adapter.requests.length == 2);
      await background.enterOhosBackgroundMode(7);
      expect(background.isEnabled, isTrue);
      await background.disable();
      bus.exitBackgroundMode();
      await _until(() => adapter.requests.length == 3);
      background.handleOhosExpired(10);
      expect(bus.isPolling, isTrue);
      await background.enterOhosBackgroundMode(7);
      background.handleOhosExpired(10);
      expect(background.isEnabled, isTrue);
      expect(bus.isPolling, isTrue);
      background.handleOhosExpired(11);
      expect(background.isEnabled, isFalse);
      expect(bus.isPolling, isFalse);
      bus.exitBackgroundMode();
      await _until(() => adapter.requests.length == 4);
      expect(adapter.payload(3)['/a'], '1');
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      bus.dispose();
      dio.close(force: true);
    }
  });
}
