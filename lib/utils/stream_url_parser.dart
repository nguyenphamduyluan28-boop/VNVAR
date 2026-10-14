enum StreamPlatform {
  youtube,
  facebook,
  tiktok,
  custom,
}

class ParsedStreamUrl {
  final StreamPlatform platform;
  final String server; // vd rtmp://push-rtmp-l11.tiktokcdn.com/game
  final String key; // vd stream-123?expire=1&sign=abc (GIỮ query)

  const ParsedStreamUrl({
    required this.platform,
    required this.server,
    required this.key,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ParsedStreamUrl &&
          runtimeType == other.runtimeType &&
          platform == other.platform &&
          server == other.server &&
          key == other.key;

  @override
  int get hashCode => platform.hashCode ^ server.hashCode ^ key.hashCode;

  @override
  String toString() =>
      'ParsedStreamUrl(platform: $platform, server: $server, key: $key)';
}

ParsedStreamUrl parseStreamUrl(String raw) {
  final url = raw.trim();
  // scheme://authority/app/<key...> — key = mọi thứ sau segment app, gồm cả query
  final m = RegExp(
    r'^(rtmps?://[^/]+/[^/?]+)/(.+)$',
    caseSensitive: false,
  ).firstMatch(url);
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  final platform = host.contains('youtube.com')
      ? StreamPlatform.youtube
      : (host.contains('facebook.com') || host.contains('fbcdn'))
          ? StreamPlatform.facebook
          : host.contains('tiktok')
              ? StreamPlatform.tiktok // tiktok.com, tiktokcdn.com, tiktokv.com
              : StreamPlatform.custom;

  if (m == null || platform == StreamPlatform.custom) {
    return ParsedStreamUrl(
      platform: StreamPlatform.custom,
      server: '',
      key: url,
    );
  }
  return ParsedStreamUrl(
    platform: platform,
    server: m.group(1)!,
    key: m.group(2)!,
  );
}

String buildStreamUrl(String server, String key) {
  final s = server.trim().replaceAll(RegExp(r'/+$'), '');
  final k = key.trim().replaceAll(RegExp(r'^/+'), '');
  return k.isEmpty ? s : (s.isEmpty ? k : '$s/$k');
}

/// Ghép URL từ QR với key/token đi kèm mà không lặp key.
///
/// - URL nền tảng đã có key (YouTube/Facebook/TikTok): thay key bằng token.
/// - URL đã chứa sẵn token: giữ nguyên.
/// - URL chỉ có server/app (rtmp://host/live): nối token vào cuối.
/// - URL tùy chỉnh đã có app/stream (rtmp://host/live/cam1): giữ nguyên, vì
///   không phân biệt được token là stream name hay tham số khác.
String mergeStreamUrlWithKey(String url, String? key) {
  final u = url.trim();
  final k = key?.trim() ?? '';
  if (k.isEmpty || u.contains(k)) return u;

  final parsed = parseStreamUrl(u);
  if (parsed.platform != StreamPlatform.custom) {
    return buildStreamUrl(parsed.server, k);
  }

  final segments = Uri.tryParse(u)?.pathSegments.where((s) => s.isNotEmpty);
  if (segments != null && segments.length >= 2) return u;
  return buildStreamUrl(u, k);
}

const Map<StreamPlatform, String> kDefaultServers = {
  StreamPlatform.youtube: 'rtmp://a.rtmp.youtube.com/live2',
  StreamPlatform.facebook: 'rtmps://live-api-s.facebook.com:443/rtmp',
  StreamPlatform.tiktok: '', // KHÔNG có mặc định — bắt buộc người dùng dán
  StreamPlatform.custom: '',
};
