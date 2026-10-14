import 'dart:io' show InternetAddress;
import 'dart:typed_data';

/// The native callback supplies the failing event URL's host, never the current page URL.
Future<bool> authorizeOhosWebViewLeaf({
  required String? protocol,
  required String host,
  required String? error,
  required Uint8List? leaf,
  required bool Function() isProxyCurrent,
  required Future<bool> Function(String, Uint8List) matchesCurrentLeaf,
}) async {
  final dns = host.endsWith('.') ? host.substring(0, host.length - 1) : host;
  if (protocol != 'https' || error != 'UNTRUSTED' || leaf == null ||
      leaf.isEmpty || leaf.length > 16384 || dns.isEmpty || dns.length > 253 ||
      InternetAddress.tryParse(dns) != null || !RegExp(r'^[a-zA-Z0-9.-]+$').hasMatch(dns) ||
      dns.split('.').any((label) => label.isEmpty || label.length > 63 ||
          label.startsWith('-') || label.endsWith('-')) || !isProxyCurrent()) return false;
  try {
    return await matchesCurrentLeaf(dns.toLowerCase(), leaf) && isProxyCurrent();
  } catch (_) {
    return false;
  }
}
