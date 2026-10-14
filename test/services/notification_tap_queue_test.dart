import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/notification_tap_queue.dart';

void main() {
  test('cold click waits for both first frame and authenticated navigation', () {
    final queue = NotificationTapQueue();
    expect(queue.add('message:12:3', token: 'cold-1'), isTrue);
    expect(queue.takeReady(navigatorReady: false, authenticated: true), isEmpty);
    expect(queue.takeReady(navigatorReady: true, authenticated: false), isEmpty);
    final ready = queue.takeReady(navigatorReady: true, authenticated: true);
    expect(ready.single.kind, 'message');
    expect(ready.single.id, 12);
    expect(ready.single.postNumber, 3);
    expect(queue.takeReady(navigatorReady: true, authenticated: true), isEmpty);
  });

  test('hot click and duplicate initial Want navigate once per publication', () {
    final queue = NotificationTapQueue();
    expect(queue.add('chat:42', token: 'hot-1'), isTrue);
    expect(queue.add('chat:42', token: 'hot-1'), isFalse);
    expect(queue.takeReady(navigatorReady: true, authenticated: true).single.kind, 'chat');
    expect(queue.add('chat:42', token: 'hot-1'), isFalse);
    expect(queue.add('chat:42', token: 'hot-2'), isTrue);
  });

  test('invalid navigation data is rejected at the channel boundary', () {
    for (final payload in ['chat:0', 'topic:-1', 'message:1:0', 'chat:1:2', 'topic:1:bad',
      'topic:9007199254740992', 'topic:1:2:3', 'https://example.com']) {
      expect(NotificationTarget.parse(payload), isNull, reason: payload);
    }
    expect(NotificationTarget.parse('topic:9007199254740991')?.id, 9007199254740991);
    expect(NotificationTapQueue().add('topic:1', token: 'bad token'), isFalse);
  });

  test('logout clears private pending navigation without replaying old token', () {
    final queue = NotificationTapQueue();
    queue.add('message:1', token: 'old-user');
    queue.clearPending();
    expect(queue.takeReady(navigatorReady: true, authenticated: true), isEmpty);
    expect(queue.add('message:1', token: 'old-user'), isFalse);
  });
}
