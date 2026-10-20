enum StreamPlatform {
  sporto,
  facebook,
  youtube,
  tiktok,
  obs,
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

  // Không in nguyên stream key ra log/thông báo lỗi.
  @override
  String toString() =>
      'ParsedStreamUrl(platform: $platform, server: $server, '
      'key: ${maskStreamSecret(key)})';
}

/// Tên miền chính xác hoặc tên miền con của [domain] (so khớp hậu tố theo
/// nhãn, nên "evilyoutube.com" KHÔNG khớp "youtube.com").
bool _hostUnder(String host, String domain) =>
    host == domain || host.endsWith('.$domain');

String _hostOf(String url) {
  try {
    return Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
  } catch (_) {
    return '';
  }
}

const List<String> _youtubeDomains = ['youtube.com'];
const List<String> _facebookDomains = ['facebook.com', 'fbcdn.net'];
const List<String> _tiktokDomains = [
  'tiktok.com',
  'tiktokv.com',
  'tiktokcdn.com',
];

bool _isTiktokHost(String host) =>
    _tiktokDomains.any((d) => _hostUnder(host, d)) ||
    // CDN theo vùng: tiktokcdn-us.com, tiktokcdn-eu.com…
    RegExp(r'(^|\.)tiktokcdn-[a-z0-9]+\.com$').hasMatch(host);

/// Nhận diện nền tảng từ tên máy chủ (so khớp hậu tố tên miền).
StreamPlatform streamPlatformForHost(String rawHost) {
  final host = rawHost.toLowerCase();
  if (host.isEmpty) return StreamPlatform.custom;
  if (_hostUnder(host, 'sporto.vn')) return StreamPlatform.sporto;
  if (_youtubeDomains.any((d) => _hostUnder(host, d))) {
    return StreamPlatform.youtube;
  }
  if (_facebookDomains.any((d) => _hostUnder(host, d))) {
    return StreamPlatform.facebook;
  }
  if (_isTiktokHost(host)) return StreamPlatform.tiktok;
  return StreamPlatform.custom;
}

ParsedStreamUrl parseStreamUrl(String raw) {
  final url = raw.trim();
  // scheme://authority/app/<key...> — key = mọi thứ sau segment app, gồm cả query
  final m = RegExp(
    r'^(rtmps?://[^/]+/[^/?]+)/(.+)$',
    caseSensitive: false,
  ).firstMatch(url);
  final platform = streamPlatformForHost(_hostOf(url));

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

/// Phân loại đích phát nhận được từ mã QR.
enum StreamDestinationKind {
  /// Máy chủ đối tác (SportO, AQVision): được tự phát.
  partner,

  /// Máy chủ trong mạng nội bộ (LAN, localhost, *.local): được tự phát.
  local,

  /// Nền tảng công cộng (YouTube, Facebook, TikTok…): kênh có thể là của
  /// bất kỳ ai nên LUÔN phải hỏi người dùng.
  publicPlatform,

  /// Máy chủ lạ: phải hỏi người dùng.
  unknown,
}

const List<String> _partnerDomains = ['sporto.vn', 'aqvision.net'];

/// Nền tảng công cộng khác ngoài các nền tảng có trong [StreamPlatform].
const List<String> _otherPublicDomains = [
  'twitch.tv',
  'live-video.net', // máy chủ nhận luồng của Twitch
  'kick.com',
];

/// Octet IPv4 hợp lệ (0–255); null nếu [host] không phải IPv4 dạng số.
List<int>? _parseIpv4(String host) {
  final m = RegExp(
    r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$',
  ).firstMatch(host);
  if (m == null) return null;
  final octets = <int>[for (var i = 1; i <= 4; i++) int.parse(m.group(i)!)];
  if (octets.any((o) => o > 255)) return null;
  return octets;
}

bool _isLocalHost(String host) {
  if (host == 'localhost' || host.endsWith('.local')) return true;
  final ipv4 = _parseIpv4(host);
  if (ipv4 != null) {
    final a = ipv4[0];
    final b = ipv4[1];
    return a == 10 ||
        a == 127 ||
        (a == 192 && b == 168) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 169 && b == 254);
  }
  // IPv6: loopback, unique local fc00::/7, link-local fe80::/10.
  if (host.contains(':')) {
    final h = host.replaceAll('[', '').replaceAll(']', '');
    return h == '::1' ||
        RegExp(r'^f[cd][0-9a-f]{0,2}:').hasMatch(h) ||
        RegExp(r'^fe[89ab][0-9a-f]?:').hasMatch(h);
  }
  return false;
}

/// Phân loại đích phát (hàm thuần, dùng cho quyết định tự phát sau khi quét QR).
StreamDestinationKind classifyStreamDestination(String url) {
  final host = _hostOf(url);
  if (host.isEmpty) return StreamDestinationKind.unknown;
  if (_partnerDomains.any((d) => _hostUnder(host, d))) {
    return StreamDestinationKind.partner;
  }
  if (_isLocalHost(host)) return StreamDestinationKind.local;
  final platform = streamPlatformForHost(host);
  if (platform == StreamPlatform.youtube ||
      platform == StreamPlatform.facebook ||
      platform == StreamPlatform.tiktok ||
      _otherPublicDomains.any((d) => _hostUnder(host, d))) {
    return StreamDestinationKind.publicPlatform;
  }
  return StreamDestinationKind.unknown;
}

/// Đích được phép tự phát ngay sau khi quét QR: CHỈ máy chủ đối tác và máy chủ
/// trong mạng nội bộ (MediaMTX tại sân). Nền tảng công cộng (YouTube,
/// Facebook, TikTok…) luôn phải xác nhận: QR dán đè có thể chứa stream key
/// của kênh người khác. Đích lạ cũng phải xác nhận, tránh QR lạ âm thầm phát
/// camera + mic ra ngoài.
bool isTrustedAutoStartDestination(String url) {
  final kind = classifyStreamDestination(url);
  return kind == StreamDestinationKind.partner ||
      kind == StreamDestinationKind.local;
}

/// Che khoá bí mật: chỉ giữ tối đa 4 ký tự đầu (ít hơn nếu khoá quá ngắn,
/// để không lộ gần hết khoá).
String maskStreamSecret(String secret) {
  final s = secret.trim();
  if (s.isEmpty) return '';
  final visible = s.length >= 8 ? 4 : s.length ~/ 2;
  return '${s.substring(0, visible)}••••';
}

/// Phần "khoá" của URL phát (mọi thứ sau segment app, gồm cả query), đã che.
/// Rỗng nếu URL không có phần khoá.
String maskedStreamKeyOf(String url) {
  final u = url.trim();
  final m = RegExp(r'^[a-z][a-z0-9+.-]*://[^/]+/[^/?]+/(.+)$',
          caseSensitive: false)
      .firstMatch(u);
  if (m != null) return maskStreamSecret(m.group(1)!);
  // rtmp://host/app?key=... : khoá nằm trong query.
  final q = u.indexOf('?');
  if (q >= 0 && q < u.length - 1) return maskStreamSecret(u.substring(q + 1));
  return '';
}

/// Tên hiển thị của nền tảng/đích cho hộp xác nhận.
String streamDestinationLabel(String url) {
  switch (streamPlatformForHost(_hostOf(url))) {
    case StreamPlatform.sporto:
      return 'SportO';
    case StreamPlatform.youtube:
      return 'YouTube';
    case StreamPlatform.facebook:
      return 'Facebook';
    case StreamPlatform.tiktok:
      return 'TikTok';
    case StreamPlatform.obs:
    case StreamPlatform.custom:
      final host = _hostOf(url);
      if (_otherPublicDomains.any((d) => _hostUnder(host, d))) {
        return _hostUnder(host, 'kick.com') ? 'Kick' : 'Twitch';
      }
      return '';
  }
}

String buildStreamUrl(String server, String key) {
  final s = server.trim().replaceAll(RegExp(r'/+$'), '');
  final k = key.trim().replaceAll(RegExp(r'^/+'), '');
  return k.isEmpty ? s : (s.isEmpty ? k : '$s/$k');
}

/// URL đã chứa sẵn [key] dưới dạng một segment đường dẫn, một giá trị query
/// hoặc toàn bộ phần đuôi sau app. Không dùng `contains` thô: token ngắn
/// (vd "1") sẽ khớp nhầm bất kỳ chữ số nào trong URL.
bool _urlAlreadyHasKey(String url, String key) {
  if (url.endsWith('/$key')) return true;
  try {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      if (uri.pathSegments.contains(key)) return true;
      if (uri.queryParametersAll.values.any((values) => values.contains(key))) {
        return true;
      }
    }
  } catch (_) {
    // Query mã hoá sai: coi như chưa có khoá.
  }
  final parsed = parseStreamUrl(url);
  return parsed.platform != StreamPlatform.custom && parsed.key == key;
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
  if (k.isEmpty || _urlAlreadyHasKey(u, k)) return u;

  final parsed = parseStreamUrl(u);
  if (parsed.platform != StreamPlatform.custom) {
    return buildStreamUrl(parsed.server, k);
  }

  final segments = Uri.tryParse(u)?.pathSegments.where((s) => s.isNotEmpty);
  if (segments != null && segments.length >= 2) return u;
  return buildStreamUrl(u, k);
}

const Map<StreamPlatform, String> kDefaultServers = {
  StreamPlatform.sporto: 'rtmp://live.sporto.vn/live',
  StreamPlatform.facebook: 'rtmps://live-api-s.facebook.com:443/rtmp',
  StreamPlatform.youtube: 'rtmp://a.rtmp.youtube.com/live2',
  StreamPlatform.tiktok: '', // KHÔNG có mặc định — bắt buộc người dùng dán
  StreamPlatform.obs: '', // RTSP Local
  StreamPlatform.custom: '',
};
