import 'dart:async';
import 'dart:io';
import 'dart:developer' as developer;
import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_video/return_code.dart';
import 'package:ffmpeg_kit_flutter_new_video/statistics.dart';
import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier, visibleForTesting;
import 'package:flutter/services.dart' show MethodCall, PlatformException;

import 'audio_cleanup.dart';
import 'cellular_uplink_service.dart';
import 'scoreboard_burn_in.dart';
import 'station_platform_events.dart';

/// Cổng luồng RTSP overlay native iOS (chỉ loopback, hợp đồng C5).
const int nativeOverlayRtspPort = 8555;

/// Luồng RTSP overlay native iOS: video H.264 đã chồng bảng tỉ số, không audio.
const String nativeOverlayRtspUrl =
    'rtsp://127.0.0.1:$nativeOverlayRtspPort/camera';

/// Thời gian chờ native mở luồng overlay.
const Duration nativeOverlayStartTimeout = Duration(seconds: 8);

/// Gọi method trên kênh native (thay được trong test).
typedef NativeOverlayInvoker =
    Future<Object?> Function(String method, Map<String, Object?>? arguments);

/// Mở luồng RTSP overlay native (`startOverlayRtsp`, hợp đồng C5). Trả về
/// null khi native báo đã nghe; ngược lại là lý do lỗi (PlatformException,
/// quá [timeout], native chưa hỗ trợ, trả về khác `true`). Không ném lỗi:
/// người gọi lùi về phát không bảng tỉ số.
Future<String?> startNativeOverlayRtsp(
  NativeOverlayInvoker invoke, {
  required String trackId,
  required int bitrateBps,
  required int fps,
  required String overlayPath,
  int port = nativeOverlayRtspPort,
  Duration timeout = nativeOverlayStartTimeout,
}) async {
  try {
    final result = await invoke('startOverlayRtsp', <String, Object?>{
      'trackId': trackId,
      'port': port,
      'bitrate': bitrateBps,
      'fps': fps,
      'overlayPath': overlayPath,
    }).timeout(timeout);
    if (result == true) return null;
    return 'startOverlayRtsp returned $result';
  } on TimeoutException {
    return 'startOverlayRtsp timed out after ${timeout.inSeconds}s';
  } on PlatformException catch (error) {
    return 'startOverlayRtsp failed: ${error.code} ${error.message ?? ''}'
        .trim();
  } catch (error) {
    return 'startOverlayRtsp failed: $error';
  }
}

/// Tham số đọc một luồng RTSP cục bộ để copy nguyên (không giải mã lại):
/// giống đầu vào của đường phát thường (độ trễ thấp, TCP, timeout I/O).
List<String> localRtspCopyInputArgs(String url) => [
  '-thread_queue_size',
  '4096',
  '-fflags',
  '+genpts+nobuffer+discardcorrupt',
  '-flags',
  'low_delay',
  '-correct_ts_overflow',
  '1',
  '-rtsp_transport',
  'tcp',
  '-buffer_size',
  '4096000',
  // Timeout I/O với RTSP cục bộ (micro giây): không treo nếu nguồn ngừng.
  '-timeout',
  '10000000',
  '-i',
  url,
];

/// iOS, bảng tỉ số do native chồng sẵn: input 0 = luồng overlay [overlayUrl]
/// (chỉ video, copy nguyên), input 1 = luồng RTSP chính [audioSourceUrl] chỉ
/// để lấy audio (map bằng [livestreamAudioMapArg] với `nativeOverlay: true`).
/// Không có bộ lọc và không mã hoá lại video.
List<String> nativeOverlayRelayInputArgs({
  required String overlayUrl,
  required String audioSourceUrl,
}) => [
  ...localRtspCopyInputArgs(overlayUrl),
  ...localRtspCopyInputArgs(audioSourceUrl),
  '-map',
  '0:v:0',
  '-c:v',
  'copy',
];

/// Nguồn audio của livestream: luồng chính là input 1 khi dùng overlay
/// native (iOS), còn lại là input 0.
String livestreamAudioMapArg({required bool nativeOverlay}) =>
    nativeOverlay ? '1:a?' : '0:a?';

/// Phiên dùng overlay native kết thúc trước khi phát vì không đọc được luồng
/// overlay 127.0.0.1:[nativeOverlayRtspPort] (FFmpeg in `<url>: <lỗi>`).
bool isNativeOverlaySourceFailure(String? output) {
  if (output == null || output.isEmpty) return false;
  const marker = '127.0.0.1:$nativeOverlayRtspPort';
  for (final raw in output.split(RegExp(r'[\r\n]+'))) {
    final line = raw.trim();
    if (!line.contains(marker)) continue;
    // "Input #0, rtsp, from '…'" chỉ là thông tin đã mở được luồng.
    if (line.startsWith('Input #')) continue;
    return true;
  }
  return false;
}

enum RtspPublishState {
  idle,
  connecting,
  publishing,
  reconnecting,
  error,
}

enum StreamNetworkQuality {
  unknown,
  good, // Xanh: FPS >= 80% FPS camera và bitrate ổn định trong 8s
  warning, // Cam: FPS hoặc bitrate sụt giảm từ 3s
  poor, // Đỏ: FPS < 50% FPS camera hoặc bitrate < 800 kbps kéo dài >= 10s
}

/// Điều chỉnh bitrate encoder H.264 theo khả năng upload của relay livestream.
///
/// FFmpeg báo `speed` = thời lượng đã đẩy / thời gian thực. Upload không theo
/// kịp thì speed < 1 và FPS đầu ra giảm. Khi đó hạ bitrate 25% mỗi bước (sau
/// 3 giây nghẽn liên tục), ổn định 30 giây thì tăng lại 10% mỗi bước. Encoder
/// đổi bitrate tại chỗ nên không ngắt luồng.
class LiveBitrateController {
  LiveBitrateController({required int maximumBps})
    : _maximumBps = maximumBps,
      _targetBps = maximumBps;

  static const Duration congestionHold = Duration(seconds: 3);
  static const Duration decreaseInterval = Duration(seconds: 4);
  static const Duration recoveryHold = Duration(seconds: 30);

  int _maximumBps;
  int _targetBps;
  DateTime? _congestedSince;
  DateTime? _healthySince;
  DateTime? _lastChange;

  int get maximumBps => _maximumBps;
  int get targetBps => _targetBps;
  int get minimumBps {
    final floor = (_maximumBps * 0.3).round();
    return floor < 800000 ? 800000 : floor;
  }

  /// Trả về true nếu bitrate mục tiêu đổi theo mức tối đa mới.
  bool setMaximum(int bps) {
    if (bps <= 0 || bps == _maximumBps) return false;
    _maximumBps = bps;
    final previous = _targetBps;
    if (_targetBps > bps) _targetBps = bps;
    return previous != _targetBps;
  }

  /// Về lại chất lượng tối đa (camera vừa mở lại encoder, hoặc dừng phát).
  void reset() {
    _targetBps = _maximumBps;
    _congestedSince = null;
    _healthySince = null;
    _lastChange = null;
  }

  /// Phiên FFmpeg mới: bỏ qua giai đoạn khởi động, khi speed chưa ổn định.
  void beginSession(DateTime now) {
    _congestedSince = null;
    _healthySince = null;
    _lastChange = now;
  }

  /// Trả về bitrate mới khi cần đổi, ngược lại null.
  int? observe({
    required double speed,
    required double fps,
    required int expectedFps,
    required DateTime now,
  }) {
    final congested =
        (speed > 0 && speed < 0.95) || (fps > 0 && fps < expectedFps * 0.8);
    final healthy =
        speed >= 0.98 && (fps <= 0 || fps >= expectedFps * 0.9);
    final last = _lastChange;
    if (congested) {
      _healthySince = null;
      final since = _congestedSince ??= now;
      if (now.difference(since) < congestionHold) return null;
      if (last != null && now.difference(last) < decreaseInterval) return null;
      if (_targetBps <= minimumBps) return null;
      final reduced = (_targetBps * 0.75).round();
      _targetBps = reduced < minimumBps ? minimumBps : reduced;
      _lastChange = now;
      _congestedSince = now;
      return _targetBps;
    }
    if (healthy) {
      _congestedSince = null;
      final since = _healthySince ??= now;
      if (_targetBps >= _maximumBps) return null;
      if (now.difference(since) < recoveryHold) return null;
      if (last != null && now.difference(last) < recoveryHold) return null;
      final raised = (_targetBps * 1.1).round();
      _targetBps = raised > _maximumBps ? _maximumBps : raised;
      _lastChange = now;
      _healthySince = now;
      return _targetBps;
    }
    return null;
  }
}

/// FPS/bitrate/tốc độ đẩy TỨC THỜI của phiên FFmpeg.
///
/// `Statistics` của FFmpeg báo FPS/bitrate/speed TRUNG BÌNH từ đầu phiên:
/// sau vài phút live, một lần nghẽn mạng hầu như không làm các số này đổi.
/// Lớp này tính chênh lệch số khung / số byte / thời lượng đã đẩy giữa các
/// lần báo trong một cửa sổ trượt ([window], ~3 giây).
class InstantStreamRates {
  InstantStreamRates({
    this.window = const Duration(seconds: 3),
    this.minimumSpan = const Duration(seconds: 1),
  });

  /// Độ dài cửa sổ trượt.
  final Duration window;

  /// Khoảng đo tối thiểu trước khi trả số liệu (tránh số nhiễu lúc đầu).
  final Duration minimumSpan;

  final List<({DateTime at, double frame, double size, double time})>
  _samples = [];

  void reset() => _samples.clear();

  /// Ghi nhận số liệu tích luỹ tại [now]: [frame] khung đã xuất, [sizeBytes]
  /// byte đã ghi, [timeMs] thời lượng media đã đẩy (ms). Trả về null khi
  /// chưa đủ [minimumSpan] để tính.
  ({double fps, double bitrateKbps, double speed})? observe({
    required DateTime now,
    required num frame,
    required num sizeBytes,
    required num timeMs,
  }) {
    final sample = (
      at: now,
      frame: frame.toDouble(),
      size: sizeBytes.toDouble(),
      time: timeMs.toDouble(),
    );
    if (_samples.isNotEmpty) {
      final last = _samples.last;
      // Bộ đếm bị đặt lại (phiên mới) hoặc đồng hồ lùi: đo lại từ đầu.
      if (sample.frame < last.frame ||
          sample.size < last.size ||
          sample.time < last.time ||
          now.isBefore(last.at)) {
        _samples.clear();
      }
    }
    _samples.add(sample);
    // Giữ mẫu cũ nhất sao cho khoảng đo vẫn >= [window].
    while (_samples.length > 2 &&
        now.difference(_samples[1].at) >= window) {
      _samples.removeAt(0);
    }
    final first = _samples.first;
    final elapsedUs = now.difference(first.at).inMicroseconds;
    if (elapsedUs <= 0 || elapsedUs < minimumSpan.inMicroseconds) return null;
    final seconds = elapsedUs / Duration.microsecondsPerSecond;
    return (
      fps: (sample.frame - first.frame) / seconds,
      bitrateKbps: (sample.size - first.size) * 8 / 1000 / seconds,
      speed: (sample.time - first.time) / 1000 / seconds,
    );
  }
}

/// Dòng log nói về địa chỉ loopback (127.0.0.1, localhost, ::1).
bool _mentionsLoopback(String lowerLine) =>
    lowerLine.contains('127.0.0.1') ||
    lowerLine.contains('localhost') ||
    lowerLine.contains('[::1]') ||
    lowerLine.contains('//::1');

/// "host:port" (chữ thường) của [relayUrl] khi đó là địa chỉ loopback (đường
/// 4G/5G đi qua bộ chuyển tiếp `127.0.0.1:<cổng>`): dòng log về địa chỉ này là
/// của server phát, không phải nguồn camera cục bộ.
String? _loopbackRelayAuthority(String? relayUrl) {
  if (relayUrl == null || relayUrl.isEmpty) return null;
  final uri = Uri.tryParse(relayUrl.trim());
  if (uri == null || uri.host.isEmpty || !uri.hasPort) return null;
  final authority = '${uri.host}:${uri.port}'.toLowerCase();
  return _mentionsLoopback(authority) || uri.host == '::1' ? authority : null;
}

bool _isLocalSourceLine(String line, String? relayAuthority) {
  final trimmed = line.trim();
  // "Input #0, rtsp, from '…'" chỉ là thông tin đã mở được nguồn.
  if (trimmed.startsWith('Input #')) return false;
  final lower = trimmed.toLowerCase();
  if (relayAuthority != null && lower.contains(relayAuthority)) return false;
  // DESCRIBE chỉ dùng khi ĐỌC luồng RTSP (nguồn cục bộ), không khi đẩy.
  return _mentionsLoopback(lower) || lower.contains('method describe failed');
}

/// Bỏ các dòng nói về nguồn camera cục bộ (127.0.0.1/localhost/::1), giữ
/// dòng về bộ chuyển tiếp 4G/5G [relayUrl] (cũng là 127.0.0.1).
String remoteRelayDiagnosticText(String output, {String? relayUrl}) {
  final relay = _loopbackRelayAuthority(relayUrl);
  return ffmpegDiagnosticText(output)
      .split('\n')
      .where((line) => !_isLocalSourceLine(line, relay))
      .join('\n');
}

const List<String> _sourceErrorMarkers = [
  'error',
  'fail',
  'refused',
  'timed out',
  'timeout',
  'not found',
  'end of file',
  'invalid data',
  'could not',
  'cannot',
  'unable',
];

const List<String> _remoteRouteErrorMarkers = [
  'broken pipe',
  'connection reset',
  'connection refused',
  'timed out',
  'i/o error',
  'network is unreachable',
  'network is down',
  'no route to host',
  'failed to resolve',
  'name or service not known',
  'nodename nor servname',
  'cannot open connection',
  'error writing trailer',
  'av_interleaved_write_frame',
];

/// Phiên kết thúc vì NGUỒN CAMERA CỤC BỘ (RTSP 127.0.0.1) lỗi, còn phía
/// server phát không báo lỗi mạng: đổi Wi-Fi ↔ 4G/5G không giúp được.
bool isLocalSourceFailure(String? output, {String? relayUrl}) {
  if (output == null || output.trim().isEmpty) return false;
  final relay = _loopbackRelayAuthority(relayUrl);
  final text = ffmpegDiagnosticText(output);
  var localError = false;
  var remoteError = false;
  for (final line in text.split('\n')) {
    final lower = line.trim().toLowerCase();
    if (lower.isEmpty || lower.startsWith('configuration:')) continue;
    if (_isLocalSourceLine(line, relay)) {
      if (_sourceErrorMarkers.any(lower.contains)) localError = true;
    } else if (_remoteRouteErrorMarkers.any(lower.contains)) {
      remoteError = true;
    }
  }
  return localError && !remoteError;
}

/// Cổng của server phát trong [url] (mặc định theo giao thức khi URL không
/// ghi cổng); null nếu không xác định được.
int? relayDestinationPort(String? url) {
  if (url == null || url.trim().isEmpty) return null;
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.hasPort) return uri.port;
  return switch (uri.scheme.toLowerCase()) {
    'rtmp' => 1935,
    'rtmps' => 443,
    'rtsp' => 554,
    'rtsps' => 322,
    _ => null,
  };
}

/// Lỗi relay có thể do đường mạng (timeout, từ chối kết nối, DNS…) hay không.
/// Server từ chối xác thực hoặc không có luồng (401/403/404) thì đổi Wi-Fi ↔
/// 4G/5G cũng không giúp được; lỗi của nguồn camera cục bộ (127.0.0.1) cũng
/// vậy. [relayUrl]: URL FFmpeg thực sự đẩy tới (có thể là bộ chuyển tiếp
/// 4G/5G `127.0.0.1:<cổng>`), để không nhầm nó với nguồn cục bộ.
bool isRouteRelatedRelayFailure(String? output, {String? relayUrl}) {
  if (output == null || output.isEmpty) return true;
  if (isLocalSourceFailure(output, relayUrl: relayUrl)) return false;
  final text = remoteRelayDiagnosticText(output, relayUrl: relayUrl);
  const serverRejections = [
    'Unauthorized',
    'Forbidden',
    'Not Found',
    'Stream not found',
    'NetStream.Publish.BadName',
  ];
  return ffmpegServerRejectionCode(text) == null &&
      !serverRejections.any(text.contains);
}

/// Cách xử lý `onOverlayRtspError` (hợp đồng C6).
enum NativeOverlayErrorAction {
  /// Lỗi listener/socket: chạy lại phiên có bảng tỉ số.
  restartWithScoreboard,

  /// Encoder/compositor hỏng, hoặc đã hết lượt chạy lại: phát không bảng tỉ số.
  continueWithoutScoreboard,
}

/// Số lần tối đa chạy lại phiên có bảng tỉ số sau lỗi recoverable (C6).
const int nativeOverlayRecoverableRestartLimit = 2;

/// Tham số `onOverlayRtspError` báo lỗi phục hồi được (`recoverable: true`).
/// Thiếu khoá / sai kiểu → false (tương thích bản native cũ).
bool isRecoverableNativeOverlayError(Object? arguments) =>
    arguments is Map && arguments['recoverable'] == true;

/// Quyết định khi luồng overlay native báo lỗi; [restartsUsed]: số lần đã
/// chạy lại vì lỗi recoverable trong phiên phát này.
NativeOverlayErrorAction nativeOverlayErrorAction(
  Object? arguments, {
  required int restartsUsed,
}) {
  if (isRecoverableNativeOverlayError(arguments) &&
      restartsUsed < nativeOverlayRecoverableRestartLimit) {
    return NativeOverlayErrorAction.restartWithScoreboard;
  }
  return NativeOverlayErrorAction.continueWithoutScoreboard;
}

/// Che stream key/mật khẩu trước khi ghi log: chỉ giữ scheme, máy chủ và tên
/// app (ví dụ "rtmp://a.rtmp.youtube.com/live2/abcd…").
String maskStreamUrlForLog(String? url) {
  if (url == null || url.isEmpty) return '';
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.isEmpty) return '***';
  final segments = uri.pathSegments.where((part) => part.isNotEmpty).toList();
  final authority = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  final app = segments.isEmpty ? '' : '/${segments.first}';
  final secret = segments.length > 1 ? segments.sublist(1).join('/') : '';
  final hint = secret.isEmpty
      ? ''
      : '/${secret.substring(0, secret.length < 4 ? secret.length : 4)}…';
  return '${uri.scheme}://$authority$app$hint';
}

/// Lỗi kết thúc phiên do phần mã hoá lại/chồng bảng tỉ số (không phải lỗi
/// mạng hay server): khi đó phát tiếp không có bảng tỉ số.
bool isLivestreamOverlayFailure(String? output) {
  if (output == null || output.isEmpty) return false;
  const markers = [
    'Error while opening encoder',
    'Error initializing output stream',
    'Error initializing complex filters',
    'Error reinitializing filters',
    'Error configuring filter',
    'Unknown encoder',
  ];
  for (final raw in output.split(RegExp(r'[\r\n]+'))) {
    final line = raw.trim();
    // Dòng cấu hình FFmpeg ("--enable-mediacodec") không phải lỗi.
    if (line.startsWith('configuration:')) continue;
    if (markers.any(line.contains)) return true;
    final lower = line.toLowerCase();
    final mentionsOverlayPart =
        lower.contains('mediacodec') || lower.contains('scoreboard_burnin');
    if (mentionsOverlayPart &&
        (lower.contains('error') ||
            lower.contains('fail') ||
            lower.contains('no such file') ||
            lower.contains('invalid data'))) {
      return true;
    }
  }
  return false;
}

/// Lỗi khi mở/giải mã bằng MediaCodec (hoặc codec/bộ lọc nói chung) trước
/// khi phiên kịp phát: thử lại bằng giải mã CPU.
bool isHardwareDecodeFailure(String? output) {
  if (output == null || output.isEmpty) return false;
  if (isLivestreamOverlayFailure(output)) return true;
  for (final raw in output.split(RegExp(r'[\r\n]+'))) {
    final line = raw.trim();
    if (line.startsWith('configuration:')) continue;
    final lower = line.toLowerCase();
    if (line.contains('Unknown decoder') ||
        line.contains('Error while opening decoder') ||
        (lower.contains('mediacodec') &&
            (lower.contains('decod') || lower.contains('error')))) {
      return true;
    }
  }
  return false;
}

/// FFmpeg không vẽ được chữ chạy (thiếu bộ lọc drawtext, không mở được font
/// hay file chữ).
bool isLivestreamTickerFailure(String? output) {
  if (output == null || output.isEmpty) return false;
  for (final raw in output.split(RegExp(r'[\r\n]+'))) {
    final line = raw.trim();
    if (line.startsWith('configuration:')) continue;
    final lower = line.toLowerCase();
    if (!lower.contains('drawtext')) continue;
    if (lower.contains('no such filter') ||
        lower.contains('error') ||
        lower.contains('fail') ||
        lower.contains('could not') ||
        lower.contains('cannot') ||
        lower.contains('unable') ||
        lower.contains('no such file') ||
        lower.contains('invalid')) {
      return true;
    }
  }
  return false;
}

/// Che mọi URL phát (rtmp/rtsp/srt/http) xuất hiện trong một dòng văn bản.
String maskStreamUrlsInText(String text) {
  return text.replaceAllMapped(
    RegExp(
      '\\b(?:rtmps?|rtsps?|srt|https?)://[^\\s\'"]+',
      caseSensitive: false,
    ),
    (match) {
      var url = match.group(0)!;
      // Bỏ dấu ":" cuối mà FFmpeg nối sau URL ("<url>: I/O error").
      var suffix = '';
      while (url.endsWith(':') || url.endsWith(',') || url.endsWith('.')) {
        suffix = url[url.length - 1] + suffix;
        url = url.substring(0, url.length - 1);
      }
      return '${maskStreamUrlForLog(url)}$suffix';
    },
  );
}

/// Bỏ các dòng tiến trình/thống kê của FFmpeg ("frame= 4010 ... size= 14012kB
/// time=... bitrate=..."). Các số trong đó từng bị khớp nhầm thành mã 401/404,
/// khiến mọi lần rớt mạng sau vài phút live bị báo "Sai Stream Key" và không
/// chuyển sang 4G.
String ffmpegDiagnosticText(String output) {
  return output
      .split(RegExp(r'[\r\n]+'))
      .where((line) {
        final trimmed = line.trim();
        if (trimmed.startsWith('frame=') || trimmed.startsWith('size=')) {
          return false;
        }
        return !(trimmed.contains('time=') && trimmed.contains('bitrate='));
      })
      .join('\n');
}

/// Mã HTTP/RTMP 401/403/404 chỉ khi xuất hiện đúng ngữ cảnh lỗi máy chủ.
int? ffmpegServerRejectionCode(String text) {
  final match = RegExp(
    r'(?:\b(?:error|returned|status|code|http)\b[^\n\d]{0,12}\b(40[134])\b)'
    r'|(?:\b(40[134])\s+(?:Unauthorized|Forbidden|Not Found)\b)',
    caseSensitive: false,
  ).firstMatch(text);
  final code = match?.group(1) ?? match?.group(2);
  return code == null ? null : int.parse(code);
}

/// Relay kết thúc vì server TỪ CHỐI (sai stream key / không có quyền / không
/// có luồng: 401/403/404, NetStream.Publish.BadName…). Thử lại vô ích nên
/// phải dừng tự kết nối lại và báo lỗi cho người dùng.
///
/// Bỏ qua các dòng của nguồn cục bộ (rtsp://127.0.0.1:8554/camera, lệnh
/// DESCRIBE/SETUP của đầu vào): server RTSP trong máy có thể trả 404 tạm thời
/// khi encoder đang khởi động lại, đó không phải server phát từ chối.
bool isPermanentRelayRejection(String? output) {
  if (output == null || output.trim().isEmpty) return false;
  final remote = output
      .split(RegExp(r'[\r\n]+'))
      .where((line) {
        final lower = line.toLowerCase();
        return !lower.contains('127.0.0.1') &&
            !lower.contains('://localhost') &&
            !lower.contains('method describe failed') &&
            !lower.contains('method setup failed');
      })
      .join('\n');
  if (remote.trim().isEmpty) return false;
  return !isRouteRelatedRelayFailure(remote);
}

final RegExp _ffmpegFrameCounter = RegExp(r'frame=\s*(\d+)');

/// Số khung đã xuất trong một dòng tiến trình FFmpeg ("frame= 123 fps=…").
int? ffmpegProgressFrame(String line) {
  final match = _ffmpegFrameCounter.firstMatch(line);
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// Chỉ coi relay là ĐANG PHÁT khi số khung đầu ra tăng liên tục trong ít
/// nhất [window]. Dòng "Output #0" chỉ cho biết FFmpeg đã mở kết nối: server
/// (YouTube/Facebook…) vẫn có thể ngắt ngay sau đó vì sai key; báo LIVE sớm
/// làm bộ đếm thử lại bị reset sai và kết nối lại mãi.
class RelayProgressGate {
  RelayProgressGate({this.window = const Duration(seconds: 3)});

  final Duration window;
  int? _firstFrame;
  DateTime? _firstAt;
  int _lastFrame = -1;
  bool _confirmed = false;

  bool get confirmed => _confirmed;

  /// Ghi nhận số khung [frame] tại [now]. Trả về true đúng MỘT lần, khi vừa
  /// xác nhận luồng đang chạy.
  bool observe(int frame, DateTime now) {
    if (_confirmed) return false;
    final first = _firstFrame;
    final firstAt = _firstAt;
    if (first == null || firstAt == null || frame < _lastFrame) {
      // Mốc đầu tiên, hoặc bộ đếm bị đặt lại: bắt đầu đo lại.
      _firstFrame = frame;
      _firstAt = now;
      _lastFrame = frame;
      return false;
    }
    final advanced = frame > _lastFrame;
    _lastFrame = frame;
    if (advanced && frame > first && now.difference(firstAt) >= window) {
      _confirmed = true;
      return true;
    }
    return false;
  }
}

class RtspPublisherService {
  RtspPublishState _state = RtspPublishState.idle;
  final StreamController<RtspPublishState> _stateController =
      StreamController<RtspPublishState>.broadcast();

  FFmpegSession? _currentSession;
  String? _targetUrl;
  String? _localRtspUrl;
  String? _currentError;
  // Bản tiếng Anh của [_currentError] (lỗi thô từ thư viện thì giống hệt).
  String? _currentErrorEn;

  DateTime? _connectedAt;
  Duration _liveDuration = Duration.zero;
  Timer? _durationTimer;
  Timer? _reconnectTimer;
  int _retryAttempt = 0;
  bool _intentionalStop = false;
  double _currentFps = 0;
  double _currentBitrateKbps = 0;

  // Thời lượng phát và số liệu (FPS/bitrate) đổi mỗi giây: tách ra notifier
  // riêng để UI chỉ dựng lại phần hiển thị số liệu thay vì cả màn hình.
  final ValueNotifier<Duration> _durationNotifier = ValueNotifier<Duration>(
    Duration.zero,
  );
  final ValueNotifier<int> _metricsNotifier = ValueNotifier<int>(0);
  bool _disposed = false;

  StreamNetworkQuality _networkQuality = StreamNetworkQuality.unknown;
  DateTime? _congestionStartedAt;
  DateTime? _stableStartedAt;
  int _expectedFps = 30;
  double _currentSpeed = 0;
  final LiveBitrateController _bitrate = LiveBitrateController(
    maximumBps: 5000000,
  );

  /// Gọi khi cần đổi bitrate encoder RTSP (runtime nối tới WebRtcService).
  Future<void> Function(int bitrateBps)? onTargetBitrateChanged;

  /// Chờ RTSP server cục bộ có encoder sẵn sàng trước khi chạy lại relay.
  Future<bool> Function()? waitForLocalSource;

  /// Máy đang có Wi-Fi/Ethernet (runtime cung cấp). Dùng để biết khi nào nên
  /// thử quay lại mạng mặc định sau khi đã chuyển sang 4G/5G dự phòng.
  bool Function()? hasWifiNetwork;

  /// Chuẩn bị ảnh bảng tỉ số để in vào video livestream (runtime cung cấp).
  /// Trả về null khi không in (tắt, không hỗ trợ, chưa có kích thước).
  /// [scrollingTicker]: cho FFmpeg vẽ chữ chạy (false sau khi máy báo lỗi).
  Future<LivestreamOverlay?> Function(
    String localRtspUrl, {
    required bool scrollingTicker,
  })?
  prepareOverlay;

  /// Dừng cập nhật ảnh bảng tỉ số khi không còn phiên nào dùng.
  void Function()? releaseOverlay;

  /// iOS: id track video WebRTC của camera (giống `trackId` của `startRtsp`),
  /// để native chồng bảng tỉ số lên cùng khung camera (runtime cung cấp).
  String? Function()? videoTrackId;

  /// Chỉ cho test: gọi ngay trước khi chạy FFmpeg với tham số của phiên.
  @visibleForTesting
  void Function(List<String> args)? debugOnFfmpegLaunch;

  // iOS: luồng RTSP overlay native (hợp đồng C5). [_nativeOverlayMayRun]:
  // đã gửi startOverlayRtsp và chưa gửi stopOverlayRtsp (kể cả lúc native còn
  // đang mở). [_nativeOverlayActive]: phiên hiện tại đang copy luồng overlay.
  bool _nativeOverlayMayRun = false;
  bool _nativeOverlayActive = false;
  int _nativeOverlayStartToken = 0;
  int _nativeOverlaySourceFailures = 0;
  // Số lần đã chạy lại phiên có bảng tỉ số sau lỗi overlay recoverable (C6).
  int _nativeOverlayRecoverableRestarts = 0;
  bool _platformListenerInstalled = false;
  static const int _nativeOverlaySourceFailuresBeforeFallback = 2;

  bool _overlayActive = false;
  bool _overlayUnavailable = false;
  // FFmpeg trên máy không vẽ được chữ chạy (thiếu drawtext/font): dùng chữ
  // đứng yên trong ảnh cho tới khi tắt app.
  bool _tickerScrollUnavailable = false;

  // In bảng tỉ số: giải mã hình bằng chip phần cứng (MediaCodec) thay vì CPU
  // để máy mát hơn. Máy không hỗ trợ / lỗi thì tắt cho tới khi tắt app và
  // giải mã bằng CPU như trước.
  bool _hwDecodeUnavailable = false;
  int _hwDecodeEarlyFailures = 0;
  String? _overlayIssue;

  /// Phiên hiện tại đang in bảng tỉ số vào video.
  bool get overlayActive => _overlayActive;

  /// Lý do không in được bảng tỉ số (máy không mã hoá lại được video...).
  String? get overlayIssue => _overlayIssue;

  /// Máy đã báo không in được bảng tỉ số: các phiên sau phát không kèm bảng
  /// cho tới [clearOverlayFailure].
  bool get overlayUnavailable => _overlayUnavailable;

  /// Cho phép thử in bảng tỉ số lại ở phiên sau (người dùng vừa bật lại).
  void clearOverlayFailure() {
    _overlayUnavailable = false;
    _overlayIssue = null;
    // Lần phát mới: thử lại giải mã phần cứng (lỗi cũ có thể do mạng/tạm thời).
    _hwDecodeUnavailable = false;
    _hwDecodeEarlyFailures = 0;
    _nativeOverlaySourceFailures = 0;
    _nativeOverlayRecoverableRestarts = 0;
  }

  static Future<Object?> _invokeNative(
    String method,
    Map<String, Object?>? arguments,
  ) => StationPlatformEvents.channel.invokeMethod<Object?>(method, arguments);

  /// Không in được bảng tỉ số cho tới khi người dùng bật lại / phát lại;
  /// UI hiện thông báo song ngữ khi [overlayIssue] khác null.
  void _markOverlayUnavailable() {
    _overlayUnavailable = true;
    _overlayActive = false;
    _overlayIssue =
        'Máy này không in được bảng tỉ số vào livestream; đang phát không có bảng tỉ số.';
    releaseOverlay?.call();
    _bumpMetrics();
  }

  void _installPlatformListener() {
    if (_platformListenerInstalled || _disposed) return;
    _platformListenerInstalled = true;
    StationPlatformEvents.instance.addListener(this, _handlePlatformEvent);
  }

  Future<void> _handlePlatformEvent(MethodCall call) async {
    if (call.method != 'onOverlayRtspError') return;
    final arguments = call.arguments;
    final error = arguments is Map ? arguments['error']?.toString() : null;
    // Lỗi của phiên overlay đã dừng: bỏ qua.
    if (!_nativeOverlayActive || _intentionalStop) return;
    final action = nativeOverlayErrorAction(
      arguments,
      restartsUsed: _nativeOverlayRecoverableRestarts,
    );
    final restart = action == NativeOverlayErrorAction.restartWithScoreboard;
    final next = restart
        ? 'restarting with scoreboard ($_nativeOverlayRecoverableRestarts/'
              '$nativeOverlayRecoverableRestartLimit restarts used)'
        : 'continuing without scoreboard';
    developer.log(
      '[RTSP_PUSH] Native overlay stream failed: ${error ?? 'unknown'} '
      '(recoverable=${isRecoverableNativeOverlayError(arguments)}); $next',
      name: 'RtspPublisherService',
    );
    if (restart) {
      // C6: lỗi listener/socket (iOS thu hồi khi vào nền…): máy vẫn in được
      // bảng tỉ số, chỉ cần mở lại luồng overlay.
      _nativeOverlayRecoverableRestarts++;
    } else {
      _markOverlayUnavailable();
    }
    // Ngừng gửi ảnh/bitrate.
    _nativeOverlayActive = false;
    // Hủy ngay phiên FFmpeg đang đọc luồng overlay hỏng (và dừng luồng
    // overlay): callback kết thúc của nó không còn tính thành lỗi mạng.
    unawaited(_cancelActiveSession());
    // Phiên mới: có bảng tỉ số (restart) hoặc không (_overlayUnavailable).
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(milliseconds: 300), () {
      if (!_intentionalStop) _executePublish();
    });
  }

  /// iOS: mở luồng overlay native cho [overlay]. Trả về true khi dùng được.
  /// Lỗi → đánh dấu không in bảng tỉ số (phiên này phát không bảng tỉ số).
  Future<bool> _startNativeOverlay(LivestreamOverlay overlay) async {
    final trackId = videoTrackId?.call();
    if (trackId == null || trackId.isEmpty) {
      // Camera chưa có track (đang mở lại): phiên này không in, lần kết nối
      // sau thử lại.
      developer.log(
        '[RTSP_PUSH] No camera track for the native overlay; '
        'publishing without scoreboard',
        name: 'RtspPublisherService',
      );
      return false;
    }
    _installPlatformListener();
    final token = ++_nativeOverlayStartToken;
    _nativeOverlayMayRun = true;
    final error = await startNativeOverlayRtsp(
      _invokeNative,
      trackId: trackId,
      bitrateBps: _bitrate.targetBps,
      fps: _expectedFps,
      overlayPath: overlay.imagePath,
    );
    if (error == null) {
      // Chờ luồng overlay có khung (SPS/PPS) để FFmpeg không mở hụt ngay sau
      // khi server vừa nghe. Không đọc được thì vẫn chạy (FFmpeg tự báo lỗi).
      await probeRtspVideoSize(
        nativeOverlayRtspUrl,
        timeout: const Duration(seconds: 5),
      );
      return token == _nativeOverlayStartToken && _nativeOverlayMayRun;
    }
    developer.log(
      '[RTSP_PUSH] $error; publishing without scoreboard',
      name: 'RtspPublisherService',
    );
    // Đã bị dừng/thay thế trong lúc mở (stopOverlayRtsp đã được gửi): không
    // coi là máy không in được.
    if (token == _nativeOverlayStartToken && _nativeOverlayMayRun) {
      _markOverlayUnavailable();
      await _stopNativeOverlay();
    }
    return false;
  }

  /// Dừng luồng overlay native (an toàn khi chưa chạy; bỏ qua lỗi).
  Future<void> _stopNativeOverlay() async {
    _nativeOverlayActive = false;
    if (!_nativeOverlayMayRun) return;
    _nativeOverlayMayRun = false;
    try {
      await _invokeNative('stopOverlayRtsp', null);
    } catch (error) {
      developer.log(
        '[RTSP_PUSH] stopOverlayRtsp failed (ignored): $error',
        name: 'RtspPublisherService',
      );
    }
  }

  /// Ảnh bảng tỉ số vừa được ghi lại (ScoreboardBurnIn): báo native nạp lại
  /// khi phiên đang dùng luồng overlay native.
  void handleOverlayImageWritten(String path) {
    if (!_nativeOverlayActive) return;
    unawaited(_invokeNativeQuietly('updateOverlayImage', {'path': path}));
  }

  void _applyNativeOverlayBitrate() {
    if (!_nativeOverlayActive) return;
    unawaited(
      _invokeNativeQuietly('setOverlayRtspBitrate', {
        'bitrate': _bitrate.targetBps,
      }),
    );
  }

  Future<void> _invokeNativeQuietly(
    String method,
    Map<String, Object?> arguments,
  ) async {
    try {
      await _invokeNative(method, arguments);
    } catch (error) {
      developer.log(
        '[RTSP_PUSH] $method failed (ignored): $error',
        name: 'RtspPublisherService',
      );
    }
  }

  // Đường truyền livestream: luôn thử mạng mặc định trước (Wi-Fi khi có, 4G/5G
  // khi không có Wi-Fi). Thất bại liên tiếp [routeFailuresBeforeSwitch] lần thì
  // đổi sang đường còn lại; vì vậy Wi-Fi không có Internet sẽ tự chuyển sang
  // 4G/5G dự phòng, và ngược lại.
  static const int routeFailuresBeforeSwitch = 2;
  static const Duration routeProbeInterval = Duration(seconds: 60);
  bool _preferCellular = false;
  bool _cellularActive = false;
  int _routeFailures = 0;
  Timer? _routeProbeTimer;
  bool _routeProbeRunning = false;

  /// Livestream đang đi 4G/5G dự phòng (mạng mặc định không tới được server).
  bool get cellularFallbackActive => _cellularActive;
  // Tăng mỗi khi mở/hủy một phiên FFmpeg. Callback của phiên cũ (đã bị thay
  // thế hoặc hủy) mang generation khác nên không được ghi đè trạng thái mới.
  int _sessionGeneration = 0;

  /// Số lần thử nhanh theo [_backoffDelaysSeconds]; sau đó vẫn thử tiếp mỗi
  /// [slowRetrySeconds] giây cho tới khi có mạng hoặc người dùng bấm Dừng.
  static const int maxReconnectAttempts = 8;
  static const int slowRetrySeconds = 30;
  static const List<int> _backoffDelaysSeconds = [2, 3, 5, 8, 12, 15, 20, 30];

  RtspPublishState get state => _state;
  Stream<RtspPublishState> get onStateChanged => _stateController.stream;
  bool get isLive => _state == RtspPublishState.publishing;
  DateTime? get connectedAt => _connectedAt;
  Duration get liveDuration => _liveDuration;
  /// Thông báo lỗi hiện tại (tiếng Việt). Giữ cho tương thích; UI nên dùng
  /// [localizedError].
  String? get currentError => _currentError;

  /// Thông báo lỗi hiện tại theo ngôn ngữ giao diện (null nếu không có lỗi).
  String? localizedError({required bool english}) =>
      english ? (_currentErrorEn ?? _currentError) : _currentError;

  String? get targetUrl => _targetUrl;
  double get currentFps => _currentFps;
  double get currentBitrateKbps => _currentBitrateKbps;
  StreamNetworkQuality get networkQuality => _networkQuality;

  /// Thời lượng phát, cập nhật mỗi giây (cùng giá trị với [liveDuration]).
  ValueListenable<Duration> get durationListenable => _durationNotifier;

  /// Tăng mỗi khi FPS/bitrate/tốc độ đẩy/trạng thái bảng tỉ số có số liệu
  /// mới. Dùng với ValueListenableBuilder/ListenableBuilder để chỉ dựng lại
  /// phần hiển thị số liệu.
  ValueListenable<int> get metricsListenable => _metricsNotifier;

  /// Đặt lỗi hiện tại kèm bản tiếng Anh ([english] null: dùng chung [vietnamese]).
  void _setError(String? vietnamese, [String? english]) {
    _currentError = vietnamese;
    _currentErrorEn = vietnamese == null ? null : (english ?? vietnamese);
  }

  void _publishDuration(Duration value) {
    _liveDuration = value;
    if (!_disposed) _durationNotifier.value = value;
  }

  void _bumpMetrics() {
    if (!_disposed) _metricsNotifier.value++;
  }

  /// Người dùng đang muốn phát (chưa bấm dừng), kể cả khi phiên đang tạm dừng
  /// vì camera đổi cấu hình hoặc đang kết nối lại.
  bool get wantsPublishing =>
      !_intentionalStop &&
      (_targetUrl?.isNotEmpty ?? false) &&
      _state != RtspPublishState.idle;

  /// FPS của profile camera hiện tại, dùng làm chuẩn đánh giá chất lượng mạng.
  set expectedFps(int fps) => _expectedFps = fps.clamp(1, 60);

  /// Bitrate RTSP tối đa của profile hiện tại.
  set maxBitrateBps(int bps) {
    if (_bitrate.setMaximum(bps)) _applyTargetBitrate();
  }

  int get targetBitrateKbps => _bitrate.targetBps ~/ 1000;
  int get maxBitrateKbps => _bitrate.maximumBps ~/ 1000;

  /// Đã tự hạ chất lượng vì upload không theo kịp.
  bool get bitrateReduced => _bitrate.targetBps < _bitrate.maximumBps;

  /// Tốc độ đẩy so với thời gian thực (1.0 = theo kịp), 0 khi chưa có số liệu.
  double get uploadSpeed => _currentSpeed;

  /// Bitrate cần đặt cho encoder H.264 native (dùng chung với Tablet RTSP).
  /// Khi đang in bảng tỉ số, FFmpeg tự mã hoá lại ở bitrate mục tiêu nên
  /// encoder native giữ chất lượng đầy đủ cho Tablet. iOS: luồng overlay
  /// native có encoder riêng nên cũng vậy (bitrate mục tiêu đặt cho nó).
  int get _nativeEncoderBitrateBps =>
      _overlayActive ? _bitrate.maximumBps : _bitrate.targetBps;

  void _applyTargetBitrate() {
    _applyNativeOverlayBitrate();
    final callback = onTargetBitrateChanged;
    if (callback == null) return;
    final bps = _nativeEncoderBitrateBps;
    unawaited(
      callback(bps).catchError((Object error) {
        developer.log(
          '[RTSP_PUSH] Unable to apply bitrate $bps: $error',
          name: 'RtspPublisherService',
        );
      }),
    );
  }

  void _setState(RtspPublishState newState) {
    if (_state == newState) return;
    _state = newState;
    _updateRouteProbe();
    if (newState != RtspPublishState.publishing) _resetNetworkHealth();
    if (newState == RtspPublishState.publishing) {
      _connectedAt ??= DateTime.now();
      _startDurationTimer();
    } else if (newState == RtspPublishState.idle ||
        newState == RtspPublishState.error) {
      _stopDurationTimer();
      _connectedAt = null;
      _publishDuration(Duration.zero);
    }
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  void _startDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final connectedAt = _connectedAt;
      if (connectedAt != null && !_stateController.isClosed) {
        _publishDuration(DateTime.now().difference(connectedAt));
        // Giữ sự kiện mỗi giây trên onStateChanged cho các màn hình cũ.
        _stateController.add(_state);
      }
    });
  }

  void _stopDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = null;
  }

  /// Starts publishing the local RTSP feed directly to remote RTSP/RTMP endpoint
  Future<void> startPublish({
    required String targetUrl,
    String? localRtspUrl,
  }) async {
    _intentionalStop = false;
    clearOverlayFailure();
    _targetUrl = targetUrl.trim();
    _localRtspUrl = (localRtspUrl?.trim().isNotEmpty ?? false)
        ? localRtspUrl!.trim()
        : 'rtsp://127.0.0.1:8554/camera';
    _setError(null);

    if (_targetUrl == null || _targetUrl!.isEmpty) {
      _intentionalStop = true; // Cấu hình sai: không tự phát lại.
      _setError(
        'Chưa nhập URL đích (RTSP/RTMP).',
        'No destination URL entered (RTSP/RTMP).',
      );
      _setState(RtspPublishState.error);
      return;
    }

    final lower = _targetUrl!.toLowerCase();
    if (!lower.startsWith('rtsp://') &&
        !lower.startsWith('rtsps://') &&
        !lower.startsWith('rtmp://') &&
        !lower.startsWith('rtmps://')) {
      _intentionalStop = true; // Cấu hình sai: không tự phát lại.
      _setError(
        'URL không đúng định dạng rtsp:// hoặc rtmp://',
        'URL must be in rtsp:// or rtmp:// format',
      );
      _setState(RtspPublishState.error);
      return;
    }

    _setState(RtspPublishState.connecting);
    await _executePublish();
  }

  Future<void> _executePublish() async {
    // Chốt generation NGAY khi hủy phiên cũ (trước mọi await): phần đồng bộ
    // của _cancelActiveSession đã tăng _sessionGeneration. Nếu người dùng bấm
    // Dừng (hoặc một phiên khác thay thế) trong lúc chờ, generation tăng tiếp
    // và phiên này tự thoát thay vì vượt qua lệnh dừng rồi vẫn chạy FFmpeg.
    final cancelling = _cancelActiveSession();
    final generation = _sessionGeneration;
    bool isCurrent() => generation == _sessionGeneration;
    bool aborted() => !isCurrent() || _intentionalStop;
    await cancelling;
    if (aborted()) return;
    _resetNetworkHealth();
    _currentSpeed = 0;
    _bitrate.beginSession(DateTime.now());

    final isRtmp = _targetUrl!.toLowerCase().startsWith('rtmp://') ||
        _targetUrl!.toLowerCase().startsWith('rtmps://');

    var outputUrl = _targetUrl!;
    final outputRouteArgs = <String>[];
    final wasCellular = _cellularActive;
    _cellularActive = false;
    // Người dùng bấm Dừng giữa chừng: dọn những gì phiên này đã mở (tunnel
    // 4G/5G, luồng overlay native, ảnh bảng tỉ số). Nếu bị một phiên khác
    // thay thế (không phải Dừng) thì phiên đó tự quản lý các tài nguyên này.
    void abandonAfterStop({
      bool tunnelOpened = false,
      bool overlayPrepared = false,
    }) {
      if (!_intentionalStop) return;
      if (overlayPrepared) releaseOverlay?.call();
      unawaited(_stopNativeOverlay());
      if (tunnelOpened || wasCellular || _cellularActive) {
        _cellularActive = false;
        unawaited(CellularUplinkService.closeTunnel());
      }
    }

    if (_preferCellular) {
      final endpoint = cellularTunnelEndpoint(outputUrl);
      final localPort = endpoint == null
          ? null
          : await CellularUplinkService.openTunnel(endpoint);
      if (aborted()) {
        // Phiên đã bị thay thế/dừng trong lúc mở tunnel. Nếu không còn phiên
        // nào cần 4G (đã stop hoặc phiên mới không dùng tunnel) thì đóng nó,
        // tránh tunnel mồ côi giữ mạng di động.
        if (_intentionalStop) {
          abandonAfterStop(tunnelOpened: localPort != null);
        } else if (localPort != null && !_preferCellular) {
          unawaited(CellularUplinkService.closeTunnel());
        }
        return;
      }
      if (localPort != null) {
        final relay = buildCellularRelayTarget(outputUrl, localPort);
        outputUrl = relay.url;
        outputRouteArgs.addAll(relay.args);
        _cellularActive = true;
      }
    }
    if (wasCellular && !_cellularActive) {
      unawaited(CellularUplinkService.closeTunnel());
    }
    // Bảng tỉ số in vào video: cần mã hoá lại hình (thay vì copy nguyên luồng).
    LivestreamOverlay? overlay;
    final prepare = prepareOverlay;
    if (prepare != null && !_overlayUnavailable) {
      try {
        overlay = await prepare(
          _localRtspUrl!,
          scrollingTicker: !_tickerScrollUnavailable,
        );
      } catch (error) {
        developer.log(
          '[RTSP_PUSH] Scoreboard overlay unavailable: $error',
          name: 'RtspPublisherService',
        );
        overlay = null;
      }
      if (aborted()) {
        // Người dùng đã dừng phát trong lúc chuẩn bị: không để ảnh tiếp tục
        // được vẽ lại khi không còn phiên nào dùng.
        abandonAfterStop(overlayPrepared: overlay != null);
        return;
      }
    }
    // iOS: gói FFmpeg không mã hoá lại được video (không có VideoToolbox).
    // Native chồng bảng tỉ số và phục vụ luồng RTSP overlay loopback; FFmpeg
    // chỉ copy. Không mở được thì phát không bảng tỉ số.
    var nativeOverlay = false;
    if (overlay != null && Platform.isIOS) {
      nativeOverlay = await _startNativeOverlay(overlay);
      if (aborted()) {
        // Bị dừng/thay thế trong lúc mở: bên dừng đã gửi stopOverlayRtsp
        // (abandonAfterStop gửi lại cho chắc; an toàn khi đã dừng).
        abandonAfterStop(overlayPrepared: true);
        return;
      }
      if (!nativeOverlay) overlay = null;
    }
    final usedNativeOverlay = nativeOverlay;
    if (overlay == null) releaseOverlay?.call();
    _overlayActive = overlay != null;
    // Phiên mới (kết nối lại) giữ mức bitrate đã thích ứng; áp lại cho chắc
    // encoder đang đúng mức đó (in bảng tỉ số: encoder native về mức đầy đủ,
    // FFmpeg mã hoá lại ở bitrate mục tiêu).
    _applyTargetBitrate();
    // Sau _applyTargetBitrate: luồng overlay vừa mở đã đúng bitrate mục tiêu.
    _nativeOverlayActive = usedNativeOverlay;
    if (usedNativeOverlay) {
      // Ảnh bảng tỉ số ghi lại trong lúc native mở luồng (chờ probe tới ~5
      // giây) bị bỏ qua vì khi đó _nativeOverlayActive còn false: gửi ngay
      // ảnh hiện tại để luồng không hiện tỉ số cũ sau khi kết nối lại.
      handleOverlayImageWritten(overlay!.imagePath);
    }
    final usedOverlay = overlay != null;
    final usedTicker = overlay?.ticker != null;
    final usedHwDecode =
        overlay != null && Platform.isAndroid && !_hwDecodeUnavailable;
    DateTime? outputStartedAt;
    var sawOutput = false;
    final progressGate = RelayProgressGate();
    void markPublishingIfProgressing(int? frame) {
      if (frame == null || !progressGate.observe(frame, DateTime.now())) {
        return;
      }
      if (_state == RtspPublishState.publishing) return;
      _retryAttempt = 0;
      _routeFailures = 0;
      _nativeOverlaySourceFailures = 0;
      _reconnectTimer?.cancel();
      _setError(null);
      _setState(RtspPublishState.publishing);
      developer.log(
        '[RTSP_PUSH] Stream is now LIVE on ${maskStreamUrlForLog(_targetUrl)} '
        '(${_cellularActive ? '4G/5G fallback' : 'default network'})',
        name: 'RtspPublisherService',
      );
    }
    // Build optimized realtime low-latency stream arguments
    final args = <String>[
      '-nostdin',
      if (usedNativeOverlay)
        // iOS: video đã có bảng tỉ số (input 0, copy), audio từ luồng chính.
        ...nativeOverlayRelayInputArgs(
          overlayUrl: nativeOverlayRtspUrl,
          audioSourceUrl: _localRtspUrl!,
        )
      else ...[
        '-thread_queue_size',
        '4096',
        '-fflags',
        // "nobuffer" làm bộ lọc chồng ảnh không nhận được thông số luồng và
        // treo (đã thử trên FFmpeg 6): chỉ dùng khi copy nguyên luồng.
        overlay != null
            ? '+genpts+discardcorrupt'
            : '+genpts+nobuffer+discardcorrupt',
        // low_delay tắt giải mã đa luồng: chỉ dùng khi copy nguyên luồng. Khi
        // in bảng tỉ số, máy phải giải mã lại hình nên cần đủ luồng CPU để
        // theo kịp thời gian thực (không thì FFmpeg tụt tốc độ và luồng bị
        // ngắt).
        if (overlay == null) ...['-flags', 'low_delay'],
        '-correct_ts_overflow',
        '1',
        '-rtsp_transport',
        'tcp',
        '-buffer_size',
        '4096000',
        // Timeout I/O với RTSP cục bộ (micro giây): không treo nếu nguồn ngừng.
        '-timeout',
        '10000000',
        if (usedHwDecode) ...['-c:v', 'h264_mediacodec'],
        '-i',
        _localRtspUrl!,
        if (overlay != null) ...[
          // Android: mỗi vùng bảng tỉ số là một ảnh PNG (input 1..N), chồng
          // lần lượt tại vị trí của vùng.
          for (final region in overlay.regions)
            ...livestreamOverlayInputArgs(region.imagePath),
          ...livestreamOverlayVideoArgs(
            bitrateBps: _bitrate.targetBps,
            fps: _expectedFps,
            ticker: overlay.ticker,
            regions: overlay.regions,
          ),
        ] else ...[
          '-map',
          '0:v:0',
          '-c:v',
          'copy',
        ],
      ],
      // Chèn SPS/PPS vào mỗi Keyframe để server Sporto và decoder người xem
      // cập nhật độ phân giải mới mượt mà, không bị nghẽn buffer hay lỗi phân giải.
      '-bsf:v',
      'dump_extra=freq=keyframe',
      '-map',
      livestreamAudioMapArg(nativeOverlay: usedNativeOverlay),
      '-c:a',
      'aac',
      '-b:a',
      '96k',
      '-ar',
      '48000',
      '-af',
      // Lọc gió/mưa/tạp âm giống file ghi (xem audio_cleanup.dart), rồi
      // aresample để giữ hình–tiếng khớp nhau.
      '$outdoorAudioCleanupFilter,aresample=async=1000:min_hard_comp=0.100000:first_pts=0',
      '-max_muxing_queue_size',
      '8192',
      '-avoid_negative_ts',
      'make_zero',
      '-flush_packets',
      '1',
      if (isRtmp) ...[
        '-f',
        'flv',
        '-flvflags',
        'no_duration_filesize',
        '-rtmp_live',
        'live',
        // Timeout đọc/ghi socket tới server (micro giây). Khi đổi Wi-Fi ↔ 4G/5G,
        // kết nối TCP cũ chết im lặng; không có timeout FFmpeg có thể treo ở
        // trạng thái LIVE nhiều phút mà không đẩy được dữ liệu.
        '-rw_timeout',
        '15000000',
      ] else ...[
        '-f',
        'rtsp',
        '-rtsp_transport',
        'tcp',
        '-rtsp_flags',
        'prefer_tcp',
        '-timeout',
        '15000000',
      ],
      ...outputRouteArgs,
      outputUrl,
    ];

    developer.log(
      '[RTSP_PUSH] Starting FFmpeg push to ${maskStreamUrlForLog(_targetUrl)}',
      name: 'RtspPublisherService',
    );

    final instantRates = InstantStreamRates();
    debugOnFfmpegLaunch?.call(args);
    try {
      final session = await FFmpegKit.executeWithArgumentsAsync(
        args,
        (completedSession) async {
          if (!isCurrent()) return;
          final returnCode = await completedSession.getReturnCode();
          if (!isCurrent()) return;
          final isSuccess = ReturnCode.isSuccess(returnCode);
          final isCancel = ReturnCode.isCancel(returnCode);

          developer.log(
            '[RTSP_PUSH] Session ended: returnCode=$returnCode (success=$isSuccess, cancel=$isCancel)',
            name: 'RtspPublisherService',
          );
          // Phiên kết thúc: luồng overlay native không còn ai đọc (phiên sau
          // tự mở lại nếu vẫn in bảng tỉ số).
          if (usedNativeOverlay) unawaited(_stopNativeOverlay());

          if (_intentionalStop || isCancel) {
            if (_state != RtspPublishState.connecting) {
              _setState(RtspPublishState.idle);
            }
            return;
          }

          // Luồng phát không bao giờ tự kết thúc hợp lệ: FFmpeg trả mã thành
          // công khi nguồn RTSP cục bộ đóng (camera bị dispose / đổi mạng). Phải
          // kết nối lại, nếu không trạng thái kẹt ở "LIVE" mà không còn phiên.
          final output = await completedSession.getOutput();
          if (!isCurrent()) return;
          // Giải mã phần cứng lỗi ngay khi mở, hoặc phiên chết sớm 2 lần liên
          // tiếp sau khi đã phát: chuyển sang giải mã CPU (vẫn in bảng tỉ số).
          final startedAt = outputStartedAt;
          final diedEarly = startedAt != null &&
              DateTime.now().difference(startedAt) <
                  const Duration(seconds: 60);
          if (usedHwDecode &&
              !isSuccess &&
              !(usedTicker && !sawOutput && isLivestreamTickerFailure(output))) {
            if (!sawOutput) {
              // Chỉ đổ lỗi cho giải mã phần cứng khi FFmpeg báo lỗi
              // codec/bộ lọc (không phải lỗi mạng tới server).
              if (isHardwareDecodeFailure(output)) _hwDecodeUnavailable = true;
            } else if (diedEarly &&
                !isRouteRelatedRelayFailure(output, relayUrl: outputUrl) &&
                isHardwareDecodeFailure(output)) {
              _hwDecodeEarlyFailures++;
              if (_hwDecodeEarlyFailures >= 2) _hwDecodeUnavailable = true;
            } else {
              _hwDecodeEarlyFailures = 0;
            }
            if (_hwDecodeUnavailable && !sawOutput) {
              developer.log(
                '[RTSP_PUSH] Hardware decoding unavailable; retrying with CPU decoding',
                name: 'RtspPublisherService',
              );
              _currentSession = null;
              _reconnectTimer?.cancel();
              _reconnectTimer = Timer(const Duration(milliseconds: 300), () {
                if (!_intentionalStop) _executePublish();
              });
              return;
            }
          }
          if (usedTicker &&
              !sawOutput &&
              !isSuccess &&
              isLivestreamTickerFailure(output)) {
            // Không vẽ được chữ chạy: vẫn in bảng tỉ số, chữ chạy đứng yên.
            _tickerScrollUnavailable = true;
            developer.log(
              '[RTSP_PUSH] Scrolling ticker unavailable; using a static ticker',
              name: 'RtspPublisherService',
            );
            _currentSession = null;
            _reconnectTimer?.cancel();
            _reconnectTimer = Timer(const Duration(milliseconds: 300), () {
              if (!_intentionalStop) _executePublish();
            });
            return;
          }
          if (usedNativeOverlay &&
              !sawOutput &&
              !isSuccess &&
              isNativeOverlaySourceFailure(output)) {
            // iOS: không đọc được luồng overlay native. Thử lại nhanh một lần
            // (không tính lỗi mạng); lặp lại thì phát không bảng tỉ số.
            _nativeOverlaySourceFailures++;
            if (_nativeOverlaySourceFailures >=
                _nativeOverlaySourceFailuresBeforeFallback) {
              _nativeOverlaySourceFailures = 0;
              _markOverlayUnavailable();
            }
            developer.log(
              '[RTSP_PUSH] Native overlay stream unreadable; retrying '
              '${_overlayUnavailable ? 'without scoreboard' : 'with scoreboard'}',
              name: 'RtspPublisherService',
            );
            _currentSession = null;
            _reconnectTimer?.cancel();
            _reconnectTimer = Timer(const Duration(seconds: 1), () {
              if (!_intentionalStop) _executePublish();
            });
            return;
          }
          if (usedOverlay &&
              !sawOutput &&
              !isSuccess &&
              isLivestreamOverlayFailure(output)) {
            // Máy không mã hoá lại được video (encoder/bộ lọc): phát tiếp
            // không có bảng tỉ số thay vì làm hỏng cả livestream.
            _overlayUnavailable = true;
            _overlayActive = false;
            _overlayIssue =
                'Máy này không in được bảng tỉ số vào livestream; đang phát không có bảng tỉ số.';
            releaseOverlay?.call();
            developer.log(
              '[RTSP_PUSH] Overlay encoding failed; retrying without scoreboard',
              name: 'RtspPublisherService',
            );
            _currentSession = null;
            _reconnectTimer?.cancel();
            _reconnectTimer = Timer(const Duration(milliseconds: 300), () {
              if (!_intentionalStop) _executePublish();
            });
            return;
          }
          final failureReason = isSuccess
              ? (
                  vi: 'Nguồn camera cục bộ đã đóng; đang kết nối lại.',
                  en: 'The local camera feed closed; reconnecting.',
                )
              : _extractFailureReason(output, relayUrl: outputUrl);
          if (!isSuccess && isPermanentRelayRejection(output)) {
            // Sai stream key / không có quyền / không có luồng: thử lại vô
            // ích (và có thể bị server chặn). Dừng hẳn, giữ thông báo lỗi.
            developer.log(
              '[RTSP_PUSH] Server rejected the stream; not retrying: ${failureReason.en}',
              name: 'RtspPublisherService',
            );
            _currentSession = null;
            _haltWithError(failureReason);
            return;
          }
          developer.log(
            '[RTSP_PUSH] Session ended unexpectedly: ${failureReason.en}',
            name: 'RtspPublisherService',
          );
          _currentSession = null;
          // Nguồn camera cục bộ đóng (FFmpeg trả mã thành công) hay lỗi nguồn
          // 127.0.0.1 không phải lỗi đường mạng: không tính vào việc đổi
          // Wi-Fi ↔ 4G/5G.
          _scheduleReconnect(
            failureReason,
            routeRelated: !isSuccess &&
                isRouteRelatedRelayFailure(output, relayUrl: outputUrl),
          );
        },
        (log) {
          if (!isCurrent()) return;
          final message = log.getMessage();
          // Detect active streaming
          if (message.contains('frame=') || message.contains('bitrate=')) {
            if (!sawOutput) outputStartedAt = DateTime.now();
            sawOutput = true;
          }
          // "Output #0" chỉ là đã mở kết nối; chờ số khung tăng đều ~3 giây.
          markPublishingIfProgressing(ffmpegProgressFrame(message));
        },
        (Statistics stats) {
          if (!isCurrent()) return;
          final now = DateTime.now();
          final frame = stats.getVideoFrameNumber();
          markPublishingIfProgressing(frame);
          // Số của Statistics là trung bình từ đầu phiên: tính số tức thời
          // (cửa sổ ~3 giây) để phát hiện nghẽn mạng ngay cả khi đã live lâu.
          final rates = instantRates.observe(
            now: now,
            frame: frame,
            sizeBytes: stats.getSize(),
            timeMs: stats.getTime(),
          );
          if (rates == null) {
            // Chưa đủ khoảng đo (vừa mở phiên): chỉ hiển thị, chưa đánh giá.
            _currentFps = stats.getVideoFps();
            _currentBitrateKbps = stats.getBitrate();
            _currentSpeed = stats.getSpeed();
          } else {
            _currentFps = rates.fps;
            _currentBitrateKbps = rates.bitrateKbps;
            _currentSpeed = rates.speed;
            _evaluateNetworkHealth(_currentFps, _currentBitrateKbps);
          }
          // Android in bảng tỉ số: FFmpeg mã hoá lại ở bitrate cố định của
          // phiên, không đổi được tại chỗ (khởi động lại phiên thì ngắt live)
          // và KHÔNG được hạ encoder native dùng chung (hạ chất lượng RTSP
          // của Tablet mà không giảm tải upload). Khi đó không hạ
          // _targetBps, tránh mức bitrate "đã thích ứng" mà không áp được.
          // iOS overlay native: luồng overlay có encoder riêng nên đổi
          // bitrate tại chỗ, encoder chính giữ nguyên cho Tablet.
          final canAdaptBitrate = usedNativeOverlay || !usedOverlay;
          if (rates != null &&
              canAdaptBitrate &&
              _state == RtspPublishState.publishing) {
            final next = _bitrate.observe(
              speed: _currentSpeed,
              fps: _currentFps,
              expectedFps: _expectedFps,
              now: now,
            );
            if (next != null) {
              developer.log(
                '[RTSP_PUSH] Upload speed ${_currentSpeed.toStringAsFixed(2)}x, '
                'FPS ${_currentFps.toStringAsFixed(1)}; bitrate -> ${next ~/ 1000} kbps',
                name: 'RtspPublisherService',
              );
              if (usedNativeOverlay) {
                _applyNativeOverlayBitrate();
              } else {
                _applyTargetBitrate();
              }
            }
          }
          _bumpMetrics();
          if (!_stateController.isClosed && _state == RtspPublishState.publishing) {
            _stateController.add(_state);
          }
        },
      );

      if (!aborted()) {
        _currentSession = session;
      } else {
        // Phiên đã bị thay thế (hoặc người dùng bấm Dừng) trong lúc khởi
        // động: hủy để không chạy song song / không phát sau khi đã dừng.
        unawaited(session.cancel());
        abandonAfterStop(overlayPrepared: usedOverlay);
      }
    } catch (e) {
      if (aborted()) {
        abandonAfterStop(overlayPrepared: usedOverlay);
        return;
      }
      if (usedNativeOverlay) unawaited(_stopNativeOverlay());
      final err = (
        vi: 'Không thể khởi động lệnh đẩy luồng: $e',
        en: 'Unable to start the stream relay: $e',
      );
      _setError(err.vi, err.en);
      developer.log(
        '[RTSP_PUSH] Exception: ${err.en}',
        name: 'RtspPublisherService',
      );
      _scheduleReconnect(err);
    }
  }

  void _resetNetworkHealth() {
    _networkQuality = StreamNetworkQuality.unknown;
    _congestionStartedAt = null;
    _stableStartedAt = null;
  }

  void _evaluateNetworkHealth(double fps, double bitrateKbps) {
    if (_state != RtspPublishState.publishing) {
      _resetNetworkHealth();
      return;
    }

    final now = DateTime.now();
    final poorFps = _expectedFps * 0.5;
    final goodFps = _expectedFps * 0.8;
    final isStruggling =
        (fps > 0 && fps < poorFps) || (bitrateKbps > 0 && bitrateKbps < 800);
    final isDegraded = fps > 0 && fps < goodFps;

    if (isStruggling || isDegraded) {
      _stableStartedAt = null;
      _congestionStartedAt ??= now;
      final congestionSec = now.difference(_congestionStartedAt!).inSeconds;

      if (isStruggling && congestionSec >= 10) {
        if (_networkQuality != StreamNetworkQuality.poor) {
          _networkQuality = StreamNetworkQuality.poor;
          developer.log(
            '[RTSP_PUSH] Mạng nghẽn kéo dài ${congestionSec}s '
            '(FPS: $fps/$_expectedFps, Bitrate: ${bitrateKbps}kbps).',
            name: 'RtspPublisherService',
          );
        }
      } else if (congestionSec >= 3 &&
          _networkQuality != StreamNetworkQuality.poor) {
        _networkQuality = StreamNetworkQuality.warning;
      }
    } else if (fps >= goodFps && bitrateKbps >= 1200) {
      _congestionStartedAt = null;
      _stableStartedAt ??= now;
      final stableSec = now.difference(_stableStartedAt!).inSeconds;
      if (stableSec >= 8) {
        _networkQuality = StreamNetworkQuality.good;
      }
    }
  }

  /// Lý do phiên đẩy luồng kết thúc, bằng tiếng Việt và tiếng Anh.
  ({String vi, String en}) _extractFailureReason(
    String? output, {
    String? relayUrl,
  }) {
    if (output == null || output.isEmpty) {
      return (
        vi: 'Mất kết nối tới server phát (Server ngắt kết nối).',
        en: 'Lost connection to the streaming server (server disconnected).',
      );
    }
    if (isLocalSourceFailure(output, relayUrl: relayUrl)) {
      return (
        vi: 'Nguồn camera cục bộ chưa sẵn sàng; đang kết nối lại.',
        en: 'The local camera feed is not ready; reconnecting.',
      );
    }
    if (remoteRelayDiagnosticText(output, relayUrl: relayUrl)
        .contains('Connection refused')) {
      // Cổng của server đích thật (không phải cổng bộ chuyển tiếp 4G/5G).
      final port = relayDestinationPort(_targetUrl);
      return port == null
          ? (
              vi: 'Không thể kết nối (Connection refused). Vui lòng kiểm tra IP/Domain và cổng.',
              en: 'Unable to connect (Connection refused). Please check the IP/domain and port.',
            )
          : (
              vi: 'Không thể kết nối (Connection refused). Vui lòng kiểm tra IP/Domain và cổng $port.',
              en: 'Unable to connect (Connection refused). Please check the IP/domain and port $port.',
            );
    }
    final diagnostic = ffmpegDiagnosticText(output);
    final rejection = ffmpegServerRejectionCode(diagnostic);
    if (rejection == 401 || diagnostic.contains('Unauthorized')) {
      return (
        vi: 'Server từ chối (401 Unauthorized). Stream Key không chính xác.',
        en: 'Server rejected the stream (401 Unauthorized). The Stream Key is incorrect.',
      );
    }
    if (rejection == 403 || diagnostic.contains('Forbidden')) {
      return (
        vi: 'Server từ chối (403 Forbidden). Không có quyền phát hoặc Stream Key không hợp lệ.',
        en: 'Server rejected the stream (403 Forbidden). No permission to publish or the Stream Key is invalid.',
      );
    }
    if (diagnostic.contains('NetStream.Publish.BadName')) {
      return (
        vi: 'Server từ chối Stream Key (BadName). Kiểm tra lại Stream Key.',
        en: 'Server rejected the Stream Key (BadName). Please check the Stream Key.',
      );
    }
    if (rejection == 404 || diagnostic.contains('Not Found')) {
      return (
        vi: 'Server không tìm thấy luồng (404 Not Found). Kiểm tra App Name hoặc Stream Name.',
        en: 'Server could not find the stream (404 Not Found). Check the App Name or Stream Name.',
      );
    }
    if (output.contains('Immediate exit requested')) {
      return (vi: 'Luồng bị dừng.', en: 'The stream was stopped.');
    }
    // Return last line of error output
    final lines = output
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('ffmpeg version'))
        .toList();
    if (lines.isNotEmpty) {
      // Dòng lỗi FFmpeg thường có dạng "rtmp://host/app/<stream key>: I/O
      // error" và được hiện trên màn hình: che key/mật khẩu trước. Lỗi thô
      // của FFmpeg không dịch được nên dùng chung cho cả hai ngôn ngữ.
      final raw = maskStreamUrlsInText(lines.last);
      return (vi: raw, en: raw);
    }
    return (vi: 'Lỗi truyền luồng RTSP.', en: 'RTSP streaming error.');
  }

  /// Dừng tự kết nối lại và giữ lỗi trên màn hình (server từ chối luồng).
  /// Người dùng sửa cấu hình rồi bấm phát/thử lại sẽ gọi [startPublish].
  void _haltWithError(({String vi, String en}) reason) {
    _intentionalStop = true; // Như cấu hình sai: không tự phát lại.
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _retryAttempt = 0;
    _overlayActive = false;
    releaseOverlay?.call();
    unawaited(_stopNativeOverlay());
    _preferCellular = false;
    _routeFailures = 0;
    if (_cellularActive) {
      _cellularActive = false;
      unawaited(CellularUplinkService.closeTunnel());
    }
    _bitrate.reset();
    _applyTargetBitrate();
    _setError(reason.vi, reason.en);
    final wasError = _state == RtspPublishState.error;
    _setState(RtspPublishState.error);
    // Đã ở trạng thái error từ trước: _setState không phát sự kiện, vẫn báo
    // để UI cập nhật thông báo mới.
    if (wasError && !_stateController.isClosed) _stateController.add(_state);
  }

  void _scheduleReconnect(
    ({String vi, String en}) reason, {
    bool routeRelated = true,
  }) {
    if (_intentionalStop) return;

    // Đường hiện tại thất bại liên tiếp: lần sau thử đường còn lại. Lỗi do
    // server từ chối (sai stream key, sai đường dẫn) không phải lỗi mạng nên
    // không đổi Wi-Fi ↔ 4G/5G.
    if (routeRelated) _routeFailures++;
    if (_routeFailures >= routeFailuresBeforeSwitch) {
      _routeFailures = 0;
      _preferCellular = !_preferCellular;
      developer.log(
        '[RTSP_PUSH] Switching livestream route to '
        '${_preferCellular ? '4G/5G fallback' : 'the default network'}',
        name: 'RtspPublisherService',
      );
    }

    _setError(reason.vi, reason.en);
    // Hết các lần thử nhanh thì vẫn tiếp tục thử thưa hơn: mạng di động có thể
    // mất vài phút mới có lại. Trước đây livestream dừng hẳn sau ~95 giây.
    final slowRetry = _retryAttempt >= maxReconnectAttempts;
    if (slowRetry) {
      _setError(
        'Mất kết nối tới server phát; tự thử lại mỗi $slowRetrySeconds giây: ${reason.vi}',
        'Lost connection to the streaming server; retrying every $slowRetrySeconds seconds: ${reason.en}',
      );
    }

    _setState(RtspPublishState.reconnecting);
    final delaySeconds = slowRetry
        ? slowRetrySeconds
        : _backoffDelaysSeconds[
            _retryAttempt.clamp(0, _backoffDelaysSeconds.length - 1)];
    _retryAttempt++;

    developer.log(
      '[RTSP_PUSH] Reconnecting in ${delaySeconds}s (attempt $_retryAttempt/$maxReconnectAttempts)...',
      name: 'RtspPublisherService',
    );

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      if (!_intentionalStop) {
        _executePublish();
      }
    });
  }

  /// Mạng của điện thoại vừa thay đổi (Wi-Fi ↔ 4G/5G, mất hoặc có lại mạng).
  ///
  /// Đang chờ kết nối lại: thử ngay thay vì đợi hết backoff. Đang phát mà
  /// mạng mang luồng vừa mất (ví dụ rời Wi-Fi, hệ điều hành chuyển sang
  /// 4G/5G): kết nối TCP cũ đã chết nên nối lại ngay thay vì đợi timeout.
  void handleNetworkChange({required bool interfaceLost}) {
    if (!wantsPublishing) return;
    final waiting = _state == RtspPublishState.reconnecting ||
        _state == RtspPublishState.error;
    // Luồng đi 4G/5G dự phòng không phụ thuộc Wi-Fi nên Wi-Fi đổi không
    // làm hỏng nó; chỉ cần thử xem Wi-Fi đã có Internet để quay lại chưa.
    if (_cellularActive && _state == RtspPublishState.publishing) {
      unawaited(_probeDefaultRoute());
      return;
    }
    final staleRoute =
        interfaceLost && _state == RtspPublishState.publishing;
    if (!waiting && !staleRoute) return;
    developer.log(
      '[RTSP_PUSH] Network changed; reconnecting now',
      name: 'RtspPublisherService',
    );
    _retryAttempt = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _setState(RtspPublishState.reconnecting);
    unawaited(_executePublish());
  }

  void _updateRouteProbe() {
    final shouldProbe =
        _cellularActive && _state == RtspPublishState.publishing;
    if (!shouldProbe) {
      _routeProbeTimer?.cancel();
      _routeProbeTimer = null;
      return;
    }
    _routeProbeTimer ??= Timer.periodic(
      routeProbeInterval,
      (_) => unawaited(_probeDefaultRoute()),
    );
  }

  /// Đang đi 4G/5G dự phòng mà máy có Wi-Fi: thử xem Wi-Fi đã tới được server
  /// chưa. Được thì quay lại mạng mặc định để tiết kiệm dữ liệu di động
  /// (ngắt khoảng 1–2 giây).
  Future<void> _probeDefaultRoute() async {
    if (_routeProbeRunning ||
        !_cellularActive ||
        _state != RtspPublishState.publishing ||
        !(hasWifiNetwork?.call() ?? false)) {
      return;
    }
    final url = _targetUrl;
    final endpoint = url == null ? null : cellularTunnelEndpoint(url);
    if (endpoint == null) return;
    _routeProbeRunning = true;
    try {
      final reachable = await CellularUplinkService.defaultRouteReaches(
        endpoint,
      );
      if (!reachable ||
          !_cellularActive ||
          _state != RtspPublishState.publishing ||
          _intentionalStop) {
        return;
      }
      developer.log(
        '[RTSP_PUSH] Wi-Fi reaches the server again; leaving 4G/5G fallback',
        name: 'RtspPublisherService',
      );
      _preferCellular = false;
      _routeFailures = 0;
      _retryAttempt = 0;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _setState(RtspPublishState.reconnecting);
      unawaited(_executePublish());
    } finally {
      _routeProbeRunning = false;
    }
  }

  Future<void> stopPublish() async {
    _intentionalStop = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _retryAttempt = 0;
    await _cancelActiveSession();
    _overlayActive = false;
    releaseOverlay?.call();
    _preferCellular = false;
    _routeFailures = 0;
    if (_cellularActive) {
      _cellularActive = false;
      unawaited(CellularUplinkService.closeTunnel());
    }
    // Hết livestream: trả encoder về chất lượng đầy đủ cho Tablet.
    _bitrate.reset();
    _applyTargetBitrate();
    _setState(RtspPublishState.idle);
  }

  /// Gracefully stops active stream before camera hardware resets to avoid broken frames
  Future<void> prepareForReconfiguration() async {
    if (!wantsPublishing) return;
    developer.log(
      '[RTSP_PUSH] Preparing for camera reconfiguration (pausing stream)...',
      name: 'RtspPublisherService',
    );
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _setState(RtspPublishState.connecting);
    await _cancelActiveSession();
  }

  /// Restarts the publishing pipeline seamlessly when camera resolution or lens changes
  Future<void> restartIfPublishing() async {
    final url = _targetUrl;
    if (url == null || url.isEmpty) return;
    // Người dùng đã bấm dừng trong lúc camera đang đổi cấu hình: không tự phát lại.
    if (_intentionalStop) return;

    developer.log(
      '[RTSP_PUSH] Restarting publish session due to camera reconfiguration...',
      name: 'RtspPublisherService',
    );
    _intentionalStop = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _retryAttempt = 0;
    await _cancelActiveSession();
    // Camera vừa mở lại encoder ở bitrate đầy đủ của profile.
    _bitrate.reset();
    _setState(RtspPublishState.connecting);
    // Chạy lại ngay khi encoder RTSP cục bộ sẵn sàng thay vì chờ cố định 2,5
    // giây; giữ một khoảng ngắn để server phía xa giải phóng kết nối cũ.
    final waitForSource = waitForLocalSource;
    if (waitForSource != null) {
      try {
        await waitForSource();
      } catch (_) {}
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 2500));
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (_intentionalStop) return;
    await _executePublish();
  }

  Future<void> _cancelActiveSession() async {
    final session = _currentSession;
    _currentSession = null;
    // Vô hiệu hóa mọi callback của phiên đang bị hủy.
    _sessionGeneration++;
    // iOS: dừng luồng overlay native của phiên này. Gửi lệnh ngay (trước mọi
    // await) để lệnh dừng không đến sau lệnh mở của phiên kế tiếp.
    final stopOverlay = _stopNativeOverlay();
    if (session != null) {
      try {
        await session.cancel();
      } catch (e) {
        developer.log(
          '[RTSP_PUSH] Cancel session error (ignored): $e',
          name: 'RtspPublisherService',
        );
      }
    }
    await stopOverlay;
  }

  void dispose() {
    _intentionalStop = true;
    _routeProbeTimer?.cancel();
    _reconnectTimer?.cancel();
    _stopDurationTimer();
    _overlayActive = false;
    releaseOverlay?.call();
    if (_platformListenerInstalled) {
      _platformListenerInstalled = false;
      StationPlatformEvents.instance.removeListener(this);
    }
    unawaited(
      _cancelActiveSession().catchError((Object error) {
        developer.log(
          '[RTSP_PUSH] Cancel session during dispose failed: $error',
          name: 'RtspPublisherService',
        );
      }),
    );
    if (_cellularActive || _preferCellular) {
      _cellularActive = false;
      _preferCellular = false;
      unawaited(CellularUplinkService.closeTunnel());
    }
    _stateController.close();
    if (!_disposed) {
      _disposed = true;
      _durationNotifier.dispose();
      _metricsNotifier.dispose();
    }
  }
}
