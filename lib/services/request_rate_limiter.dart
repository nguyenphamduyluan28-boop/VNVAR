import 'dart:collection';

class RequestRateLimiter {
  RequestRateLimiter({this.maximumTrackedKeys = 256});

  final int maximumTrackedKeys;
  final Map<String, Queue<DateTime>> _requests = {};

  bool allow(
    String key, {
    required int maximumRequests,
    required Duration window,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    final cutoff = timestamp.subtract(window);
    final entries = _requests.putIfAbsent(key, Queue<DateTime>.new);
    while (entries.isNotEmpty && !entries.first.isAfter(cutoff)) {
      entries.removeFirst();
    }
    if (entries.length >= maximumRequests) return false;
    entries.addLast(timestamp);
    _trimKeys(cutoff);
    return true;
  }

  void _trimKeys(DateTime cutoff) {
    _requests.removeWhere((_, entries) {
      while (entries.isNotEmpty && !entries.first.isAfter(cutoff)) {
        entries.removeFirst();
      }
      return entries.isEmpty;
    });
    while (_requests.length > maximumTrackedKeys) {
      _requests.remove(_requests.keys.first);
    }
  }
}
