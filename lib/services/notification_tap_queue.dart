/// 系统点击先于登录和 Navigator 就绪时，保留落点而不丢弃。
class NotificationTarget {
  const NotificationTarget(this.kind, this.id, this.postNumber);
  final String kind;
  final int id;
  final int? postNumber;

  static NotificationTarget? parse(String payload) {
    if (!RegExp(r'^(chat:[1-9][0-9]{0,15}|(topic|message):[1-9][0-9]{0,15}(:[1-9][0-9]{0,15})?)$').hasMatch(payload)) return null;
    final parts = payload.split(':');
    final numbers = parts.skip(1).map(int.tryParse).toList();
    if (numbers.any((number) => number == null || number > 9007199254740991)) return null;
    return NotificationTarget(parts[0], numbers[0]!, numbers.length > 1 ? numbers[1] : null);
  }
}

class NotificationTapQueue {
  final List<NotificationTarget> _pending = [];
  final Set<String> _seen = {};

  bool add(String payload, {required String token}) {
    final target = NotificationTarget.parse(payload);
    if (target == null || !RegExp(r'^[A-Za-z0-9._:-]{1,128}$').hasMatch(token) || _seen.contains(token)) return false;
    _seen.add(token);
    if (_seen.length > 128) _seen.remove(_seen.first);
    _pending.add(target);
    return true;
  }

  List<NotificationTarget> takeReady({required bool navigatorReady, required bool authenticated}) {
    if (!navigatorReady || !authenticated) return const [];
    final ready = List<NotificationTarget>.of(_pending);
    _pending.clear();
    return ready;
  }

  void clearPending() => _pending.clear();
}
