import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh_proxy/ohos_webview_trust.dart';

void main() {
  final leaf = Uint8List.fromList([48, 1, 2]);
  Future<bool> decide({String? protocol = 'https', String host = 'EXAMPLE.com.',
    String? error = 'UNTRUSTED', Uint8List? der, bool Function()? current,
    Future<bool> Function(String, Uint8List)? match}) => authorizeOhosWebViewLeaf(
      protocol: protocol, host: host, error: error, leaf: der ?? leaf,
      isProxyCurrent: current ?? () => true,
      matchesCurrentLeaf: match ?? (host, candidate) async => host == 'example.com' && candidate.toString() == leaf.toString(),
    );

  test('only Untrusted/current proxy/canonical host and exact leaf may proceed', () async {
    expect(await decide(), isTrue);
    for (final error in [null, 'DATE_INVALID', 'IDMISMATCH', 'INVALID', 'DENY']) {
      expect(await decide(error: error), isFalse);
    }
    expect(await decide(current: () => false), isFalse);
    expect(await decide(host: 'other.com'), isFalse);
    expect(await decide(der: Uint8List.fromList([48, 1, 3])), isFalse);
  });
  test('missing/oversized certificate and invalid DNS never query native matcher', () async {
    Future<bool> unexpected(String host, Uint8List leaf) async => fail('Invalid challenge reached native matcher');
    for (final host in ['', '127.0.0.1', '::1', 'é.com', 'example.com..', 'a_b.com', '-bad.com', 'x/y', 'a:443']) {
      expect(await decide(host: host, match: unexpected), isFalse);
    }
    expect(await decide(protocol: 'http', match: unexpected), isFalse);
    expect(await decide(der: Uint8List(0), match: unexpected), isFalse);
    expect(await decide(der: Uint8List(16385), match: unexpected), isFalse);
    expect(await authorizeOhosWebViewLeaf(protocol: 'https', host: 'example.com', error: 'UNTRUSTED',
      leaf: null, isProxyCurrent: () => true, matchesCurrentLeaf: unexpected), isFalse);
  });
  test('changing proxy generation while lookup waits refuses stale match', () async {
    final pending = Completer<bool>();
    var generation = 1;
    final result = decide(current: () => generation == 1, match: (_, _) => pending.future);
    generation = 2;
    pending.complete(true);
    expect(await result, isFalse);
  });
  test('stopped/reset/no cached leaf and native exceptions refuse', () async {
    expect(await decide(match: (_, _) async => false), isFalse);
    expect(await decide(match: (_, _) async => throw StateError('native unavailable')), isFalse);
  });
}
