import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/scoreboard_state.dart';
import 'bounded_json_body.dart';
import 'discovery_service.dart';
import 'recording_service.dart';
import 'request_rate_limiter.dart';
import 'scoreboard_service.dart';
import 'scoreboard_web_pages.dart';
import 'station_errors.dart';
import 'webrtc_service.dart';

String normalizeCheckVarRequestId(String? value, DateTime receivedAt) {
  final trimmed = value?.trim() ?? '';
  if (trimmed.isEmpty) return 'checkvar_${receivedAt.microsecondsSinceEpoch}';
  final safe = trimmed.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  return safe.length <= 96 ? safe : safe.substring(0, 96);
}

DateTime checkVarEventTime(String? epochMilliseconds, DateTime receivedAt) {
  final value = int.tryParse(epochMilliseconds ?? '');
  if (value == null || value <= 0) return receivedAt;
  final candidate = DateTime.fromMillisecondsSinceEpoch(value);
  // Reject corrupt clocks and malicious values while still allowing a tablet
  // to retry a recent event after a temporary LAN outage.
  if (candidate.isBefore(receivedAt.subtract(const Duration(minutes: 10))) ||
      candidate.isAfter(receivedAt.add(const Duration(seconds: 5)))) {
    return receivedAt;
  }
  return candidate;
}

String normalizeWebRtcPeerId(String? value, {required String fallbackAddress}) {
  final raw = (value?.trim().isNotEmpty ?? false)
      ? value!.trim()
      : 'legacy_$fallbackAddress';
  final safe = raw.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  final normalized = safe.isEmpty ? 'legacy_unknown' : safe;
  return normalized.length <= 96 ? normalized : normalized.substring(0, 96);
}

int effectiveWebRtcPeerLimit(String thermalState) {
  switch (thermalState.toLowerCase()) {
    case 'critical':
      return 1;
    case 'hot':
    case 'serious':
      return 2;
    default:
      return WebRtcService.maximumActivePeers;
  }
}

/// Mọi alias của API Check VAR (mọi method).
const Set<String> checkVarRoutePaths = {
  '/checkvar',
  '/check-var',
  '/checkpoint',
  '/recording/checkvar',
};

final RegExp _segmentDownloadedAckPattern = RegExp(
  r'^/segments/[^/]+/downloaded$',
);

/// Bucket giới hạn tần suất cho một request. Check VAR và ACK tải xong có
/// hạn mức riêng để không tranh hạn mức "control" (30/phút) với trim/stop:
/// tablet ACK hàng loạt segment không được làm Check VAR bị 429.
({String bucket, int maximum, Duration window}) cameraServerRateLimitFor({
  required String path,
  required String method,
}) {
  const minute = Duration(minutes: 1);
  if (path.startsWith('/api/score') || path == '/control' || path == '/overlay') {
    // Trọng tài bấm liên tục + nhiều overlay/preview: hạn mức riêng, không
    // dùng chung hạn mức "control" (30 lệnh/phút) của API ghi hình.
    return (bucket: 'scoreboard', maximum: 600, window: minute);
  }
  if (path == '/webrtc/offer') {
    return (bucket: 'webrtc-offer', maximum: 30, window: minute);
  }
  if (path == '/webrtc/epoch') {
    return (bucket: 'webrtc-epoch', maximum: 120, window: minute);
  }
  if (path == '/webrtc/ice') {
    return (bucket: 'webrtc-ice', maximum: 120, window: minute);
  }
  if (checkVarRoutePaths.contains(path)) {
    return (bucket: 'checkvar', maximum: 60, window: minute);
  }
  if (_segmentDownloadedAckPattern.hasMatch(path)) {
    return (bucket: 'ack', maximum: 600, window: minute);
  }
  if (method != 'GET') {
    return (bucket: 'control', maximum: 30, window: minute);
  }
  return (bucket: 'general', maximum: 240, window: minute);
}

/// Khoá phiên tải clip của một tablet: header `X-Peer-ID` nếu có, ngược lại
/// địa chỉ IP của client.
String exportSessionOwner({
  required String? peerId,
  required String remoteAddress,
}) {
  final trimmed = peerId?.trim() ?? '';
  if (trimmed.isNotEmpty) {
    final safe = trimmed.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return 'peer:${safe.length <= 96 ? safe : safe.substring(0, 96)}';
  }
  return 'ip:$remoteAddress';
}

/// Phân loại lỗi Check VAR thành mã lỗi ổn định cho tablet.
({String errorCode, int httpStatus, bool retryable}) classifyCheckVarFailure(
  Object error,
) {
  if (error is CheckVarSegmentUnavailableException) {
    final notRecording = error.code == 'NOT_RECORDING';
    return (
      errorCode: error.code,
      httpStatus: HttpStatus.conflict,
      retryable: notRecording,
    );
  }
  if (error is TrimSegmentNotFoundException) {
    return (
      errorCode: 'NO_SEGMENT',
      httpStatus: HttpStatus.conflict,
      retryable: false,
    );
  }
  if (error is InvalidTrimRangeException) {
    return (
      errorCode: 'TRIM_FAILED',
      httpStatus: HttpStatus.unprocessableEntity,
      retryable: false,
    );
  }
  if (error is TrimInProgressException) {
    return (
      errorCode: 'TRIM_FAILED',
      httpStatus: HttpStatus.conflict,
      retryable: true,
    );
  }
  if (error is TrimProcessingException) {
    return (
      errorCode: 'TRIM_FAILED',
      httpStatus: HttpStatus.internalServerError,
      retryable: true,
    );
  }
  return (
    errorCode: 'INTERNAL',
    httpStatus: HttpStatus.internalServerError,
    retryable: true,
  );
}

/// Kết quả lỗi của một Check VAR, được lưu như kết quả thành công để
/// `GET /checkvar/jobs/{requestId}` và lần gửi lại trả đúng lỗi.
Map<String, dynamic> checkVarFailureResult({
  required String requestId,
  required DateTime requestedAt,
  required Object error,
  DateTime? now,
}) {
  final failure = classifyCheckVarFailure(error);
  return <String, dynamic>{
    'success': false,
    'requestId': requestId,
    'status': 'FAILED',
    'errorCode': failure.errorCode,
    'retryable': failure.retryable,
    'httpStatus': failure.httpStatus,
    'message': userFacingError(error),
    'requestedAt': requestedAt.toIso8601String(),
    'timestamp': (now ?? DateTime.now()).millisecondsSinceEpoch,
  };
}

/// Mốc phải có trong file nguồn của clip Check VAR: thời điểm sự kiện, nhưng
/// không muộn hơn lúc trạm nhận request (đồng hồ tablet có thể nhanh hơn vài
/// giây; sự kiện thật không thể xảy ra sau lúc request đến).
DateTime checkVarCoverageTarget({
  required DateTime requestedAt,
  required DateTime receivedAt,
}) => requestedAt.isAfter(receivedAt) ? receivedAt : requestedAt;

/// Sai số cho phép giữa mốc kết thúc segment và thời điểm sự kiện.
const Duration checkVarCoverageTolerance = Duration(milliseconds: 300);

/// Khoảng hở tối đa giữa hai segment (recorder cũ dừng → recorder mới mở)
/// mà sự kiện rơi vào đó được coi là "không có hình nào bị bỏ sót".
const Duration checkVarMaximumUnrecordedGap = Duration(seconds: 2);

/// Tuổi tối thiểu của segment đang ghi trước khi chốt cho Check VAR: segment
/// ngắn hơn 1 s hình không được công bố (bị chuyển vào FRAGMENTS) nên phải
/// chờ đủ để đoạn chứa sự kiện luôn dùng được.
const Duration checkVarMinimumActiveSegmentAge = Duration(milliseconds: 2200);

enum CheckVarSourceCoverage {
  /// Segment nguồn chứa thời điểm sự kiện.
  covered,

  /// Sự kiện nằm trong segment đang ghi (segment nguồn đã chốt trước đó,
  /// ví dụ Check VAR nhập vào lượt chuyển segment định kỳ): phải chốt tiếp
  /// segment đang ghi rồi mới cắt.
  needsActiveSegment,

  /// Sự kiện rơi vào khoảng hở ngắn giữa hai recorder: không có hình nào
  /// khác được ghi, segment nguồn là bản đầy đủ nhất.
  unrecordedGap,

  /// Thiếu dữ liệu sau segment nguồn.
  missing,
}

/// Segment nguồn kết thúc lúc [sourceEndedAt] có đủ hình tới [target] không.
CheckVarSourceCoverage checkVarSourceCoverage({
  required DateTime sourceEndedAt,
  required DateTime target,
  required DateTime? activeStartedAt,
  Duration tolerance = checkVarCoverageTolerance,
  Duration maximumGap = checkVarMaximumUnrecordedGap,
}) {
  if (!target.isAfter(sourceEndedAt.add(tolerance))) {
    return CheckVarSourceCoverage.covered;
  }
  if (activeStartedAt != null && !activeStartedAt.isAfter(target)) {
    return CheckVarSourceCoverage.needsActiveSegment;
  }
  if (activeStartedAt != null &&
      target.difference(sourceEndedAt) <= maximumGap) {
    return CheckVarSourceCoverage.unrecordedGap;
  }
  return CheckVarSourceCoverage.missing;
}

/// Thời gian cần chờ để segment đang ghi đủ [minimumAge] trước khi chốt.
Duration checkVarActiveSegmentWait({
  required DateTime activeStartedAt,
  required DateTime now,
  Duration minimumAge = checkVarMinimumActiveSegmentAge,
}) {
  final age = now.difference(activeStartedAt);
  if (age.isNegative) return minimumAge;
  return age >= minimumAge ? Duration.zero : minimumAge - age;
}

/// Thời gian chờ tối đa để chốt segment chứa sự kiện: phần đã ghi (tối đa
/// một segment) cộng biên cho việc dừng recorder và đóng gói TS.
Duration checkVarFollowUpTimeout({
  required Duration activeAge,
  required Duration segmentDuration,
  Duration margin = const Duration(seconds: 30),
}) {
  var recorded = activeAge.isNegative ? Duration.zero : activeAge;
  if (recorded > segmentDuration) recorded = segmentDuration;
  return recorded + checkVarMinimumActiveSegmentAge + margin;
}

/// Độ dài tối đa của một clip cắt thủ công qua `/trim`. Clip dài hơn chiếm
/// hàng đợi FFmpeg lâu và làm chậm Check VAR.
const int maximumManualTrimDurationMs = 10 * 60 * 1000;

bool isManualTrimDurationAllowed({required num startMs, required num endMs}) =>
    endMs - startMs <= maximumManualTrimDurationMs;

/// Giải mã requestId trong `/checkvar/jobs/{requestId}`; null khi mã `%`
/// hỏng hoặc không phải UTF-8 hợp lệ (trả 400 thay vì 500).
String? decodeCheckVarJobId(String raw) {
  try {
    return Uri.decodeComponent(raw);
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
}

/// HTTP status trả cho một kết quả Check VAR đã lưu.
int checkVarResponseStatus(Map<String, dynamic> result) {
  if (result['status'] != 'FAILED') return HttpStatus.ok;
  final status = result['httpStatus'];
  return status is int ? status : HttpStatus.internalServerError;
}

/// Video track của camera chưa sẵn sàng (runtime đang mở lại camera) khi
/// mở recorder. Là [StateError] để giữ tương thích với nơi bắt lỗi cũ.
class CameraVideoTrackUnavailableError extends StateError {
  CameraVideoTrackUnavailableError() : super('Camera video track unavailable.');
}

/// Số giây gợi ý trong `Retry-After` khi mở recorder lỗi tạm thời.
const int transientRecorderStartRetryAfterSeconds = 2;

/// Lỗi mở recorder là tạm thời (trả 503 + `Retry-After` thay vì 500).
bool isTransientRecorderStartError(Object error) =>
    error is CameraVideoTrackUnavailableError;

/// Nội dung JSON khi xử lý yêu cầu lỗi: lỗi tạm thời (503) ghi
/// `Service Unavailable` và `retryable: true`; lỗi khác giữ nguyên phản hồi
/// 500 như trước.
Map<String, dynamic> transientRequestErrorBody({required bool transient}) => {
  'error': transient ? 'Service Unavailable' : 'Internal Server Error',
  'message': 'Camera Station không thể xử lý yêu cầu.',
  if (transient) 'retryable': true,
};

/// Trạng thái runtime mà /start không được tự gắn recorder: camera đang được
/// đổi cấu hình, khôi phục hoặc tạm dừng (track hiện tại sắp bị huỷ). Runtime
/// sẽ tự gọi ensureRecording() khi camera mở lại.
bool captureStateBlocksRecorderStart(String? captureState) {
  const blocking = {
    'profile_switching',
    'recovering',
    'lifecycle_suspended',
    'lifecycle_resuming',
    'thermal_suspended',
    'scanner_paused',
  };
  return blocking.contains(captureState);
}

/// Request cũ (đặc tả đầu tiên) gửi thẳng tỉ số dạng phẳng, không có
/// trường "action": chuyển thành lệnh ghi đè "setScore".
bool isLegacyScoreboardBody(Map<String, dynamic> body) {
  if (body.containsKey('action')) return false;
  const keys = [
    'scoreA',
    'scoreB',
    'setsA',
    'setsB',
    'gamesA',
    'gamesB',
    'teamA',
    'teamB',
    'serving',
    'matchFinished',
  ];
  return keys.any(body.containsKey);
}

/// Một kết nối Server-Sent Events của bảng tỉ số. Mọi lần ghi được xếp hàng
/// (HttpResponse không cho ghi khi đang flush).
class _ScoreboardStream {
  _ScoreboardStream(this.response);

  final HttpResponse response;
  final Completer<void> done = Completer<void>();
  Future<void> _tail = Future<void>.value();
  StreamSubscription<Map<String, dynamic>>? subscription;
  Timer? heartbeat;
  bool closed = false;
  int _pending = 0;

  /// Client không đọc (mất Wi-Fi, OBS treo) mà hàng chờ vượt mức này thì
  /// đóng kết nối thay vì giữ dữ liệu trong RAM; client sẽ tự kết nối lại.
  static const int maximumPendingChunks = 20;

  void send(String chunk) {
    if (closed) return;
    _pending += 1;
    if (_pending > maximumPendingChunks) {
      close();
      return;
    }
    _tail = _tail
        .then((_) async {
          if (closed) return;
          response.write(chunk);
          await response.flush();
        })
        .whenComplete(() {
          _pending -= 1;
        })
        .catchError((Object _) {
          close();
        });
  }

  void close() {
    if (closed) return;
    closed = true;
    heartbeat?.cancel();
    heartbeat = null;
    subscription?.cancel();
    subscription = null;
    _tail = _tail.then((_) => response.close()).catchError((Object _) {});
    if (!done.isCompleted) done.complete();
  }
}

class CameraServer {
  // ============================================================
  // SERVER
  // ============================================================

  HttpServer? _server;

  static const int defaultApiPort = 8080;
  static const int maximumJsonBodyBytes = 256 * 1024;
  final int apiPort;

  // ============================================================
  // IDENTITY
  // ============================================================

  final String courtId;
  final String cameraId;
  final String deviceId;

  // ============================================================
  // SERVICES
  // ============================================================

  final WebRtcService webRtcService;
  final RecordingService recordingService;

  final VoidCallback? onStateChanged;
  final String Function()? captureStateProvider;
  final String Function()? thermalStateProvider;
  final double? Function()? temperatureProvider;
  final Map<String, dynamic> Function()? captureMetricsProvider;

  final DiscoveryService _discovery = DiscoveryService();

  /// Bảng tỉ số/overlay nội bộ (dùng chung toàn app, sống qua các lần
  /// khởi động lại server).
  final ScoreboardService scoreboard;
  final Set<_ScoreboardStream> _scoreStreams = <_ScoreboardStream>{};
  static const int maximumScoreboardStreams = 32;

  // ============================================================
  // STATE
  // ============================================================

  bool recording = false;
  // stop() đang chạy: không nhận request mới, không mở recorder mới, không
  // bind lại discovery (tránh recorder/socket mồ côi khi đang huỷ server).
  bool _stopping = false;
  Future<void>? _ensureRecordingOperation;
  Future<void> _recordingRequestTail = Future<void>.value();
  bool _iosLifecycleSuspended = false;
  final Map<String, Future<Map<String, dynamic>>> _checkVarJobs = {};
  final Map<String, Map<String, dynamic>> _checkVarResults = {};
  Future<void> _checkVarProcessingTail = Future<void>.value();
  final RequestRateLimiter _rateLimiter = RequestRateLimiter();
  Future<void> _webRtcOfferTail = Future<void>.value();
  // Dọn/khôi phục lưu trữ lúc khởi động (chạy nền, xem start()).
  Future<void>? _startupMaintenance;

  /// Lượt dọn/khôi phục lưu trữ lúc khởi động server (null nếu chưa chạy).
  Future<void>? get startupMaintenance => _startupMaintenance;
  int _pendingWebRtcOffers = 0;
  static const int maximumPendingWebRtcOffers = 4;

  bool get running => _server != null;

  // ============================================================
  // CONSTRUCTOR
  // ============================================================

  CameraServer({
    required this.courtId,
    required this.cameraId,
    required this.deviceId,
    required this.webRtcService,
    required this.recordingService,
    this.apiPort = defaultApiPort,
    this.onStateChanged,
    this.captureStateProvider,
    this.thermalStateProvider,
    this.temperatureProvider,
    this.captureMetricsProvider,
    ScoreboardService? scoreboardService,
  }) : scoreboard = scoreboardService ?? ScoreboardService.instance,
       assert(apiPort > 0 && apiPort <= 65535);

  // ============================================================
  // START SERVER
  // ============================================================

  Future<void> start() async {
    if (_server != null) {
      return;
    }
    _stopping = false;
    // Trạng thái bảng tỉ số phải sẵn sàng trước khi nhận request đầu tiên.
    await scoreboard.load();

    final HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, apiPort);
    } on SocketException catch (error) {
      throw BilingualStateError(
        'Không thể mở HTTP port $apiPort. '
        'Port có thể đang được ứng dụng khác sử dụng: ${error.message}',
        'Cannot open HTTP port $apiPort (in use?): ${error.message}',
      );
    }

    _server = server;

    developer.log(
      'Camera Server started '
      '[$courtId/$cameraId/$deviceId] '
      'on port $apiPort',
      name: 'CameraServer',
    );

    server.listen(
      _handleRequest,
      onError: (Object error, StackTrace stackTrace) {
        developer.log(
          'HTTP server error',
          error: error,
          stackTrace: stackTrace,
          name: 'CameraServer',
        );
      },
    );

    await recordingService.loadSettings();

    // Nạp lại video đã lưu trên điện thoại, khôi phục file ghi dở sau crash
    // và dọn thư mục ngày hết hạn (removeExpiredData). Việc này có thể mất
    // nhiều giây/phút (FFmpeg) nên chạy NỀN: HTTP + discovery bật ngay để
    // tablet thấy camera. An toàn khi recorder ghi song song: dọn staging bỏ
    // qua file đang/vừa ghi, lượt khôi phục nối tiếp theo camera, và cắt clip
    // chờ lượt dọn clip xuất tạm (được xếp hàng ngay trong lời gọi này).
    _startupMaintenance = recordingService.cleanupOldTempFiles().catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      developer.log(
        'Startup storage recovery failed',
        error: error,
        stackTrace: stackTrace,
        name: 'CameraServer',
      );
    });

    // Legacy tablet discovery uses a short TCP request/response on port 40404.
    try {
      await _discovery.startTcpDiscovery(
        courtId: courtId,
        cameraId: cameraId,
        deviceId: deviceId,
        port: apiPort,
        status: recordingService.recording ? 'RECORDING' : 'READY',
      );
    } on SocketException catch (error) {
      await server.close(force: true);
      _server = null;
      throw BilingualStateError(
        'HTTP port $apiPort đã mở nhưng discovery port '
        '${DiscoveryService.discoveryPort} không khả dụng: ${error.message}',
        'Discovery port ${DiscoveryService.discoveryPort} '
            'unavailable: ${error.message}',
      );
    }
  }

  // ============================================================
  // STOP SERVER
  // ============================================================

  Future<void> stop({Future<void> Function()? onRecorderStopped}) async {
    // Đóng cổng HTTP TRƯỚC: request đến trong lúc recorder/WebRTC đang được
    // huỷ không được mở recorder mới trên track sắp chết.
    _stopping = true;
    final server = _server;
    _server = null;
    // Đóng các luồng SSE của bảng tỉ số (overlay sẽ tự kết nối lại khi server
    // chạy lại) và ghi trạng thái xuống máy.
    for (final stream in _scoreStreams.toList()) {
      stream.close();
    }
    _scoreStreams.clear();
    unawaited(scoreboard.flush());
    // Ngừng nhận kết nối mới nhưng để request đang xử lý (CheckVAR, /stop...)
    // kịp trả lời; request mới trên kết nối keep-alive bị trả 503 (_stopping).
    if (server != null) {
      unawaited(
        server.close().catchError((Object error) {
          developer.log('HTTP server close error: $error', name: 'CameraServer');
        }),
      );
    }

    await _discovery.stop();

    // Chờ request ghi hình đã được nhận (start/stop/CheckVAR) chạy xong.
    try {
      await _recordingRequestTail.timeout(const Duration(seconds: 15));
    } catch (_) {}
    final ensuring = _ensureRecordingOperation;
    if (ensuring != null) {
      try {
        await ensuring.timeout(const Duration(seconds: 15));
      } catch (_) {}
    }
    // Đóng hẳn mọi kết nối còn lại (tải video dở...) trước khi huỷ recorder.
    try {
      await server?.close(force: true);
    } catch (error, stackTrace) {
      developer.log(
        'HTTP server close error',
        error: error,
        stackTrace: stackTrace,
        name: 'CameraServer',
      );
    }

    try {
      await recordingService.dispose(onRecorderStopped: onRecorderStopped);
    } catch (error, stackTrace) {
      developer.log(
        'Recording dispose error',
        error: error,
        stackTrace: stackTrace,
        name: 'CameraServer',
      );
    }

    try {
      await webRtcService.disposeConnection();
    } catch (error, stackTrace) {
      developer.log(
        'WebRTC dispose error',
        error: error,
        stackTrace: stackTrace,
        name: 'CameraServer',
      );
    }

    recording = false;

    developer.log('Camera Server stopped', name: 'CameraServer');
  }

  /// Rebinds discovery and native live transports without touching the
  /// camera or RecordingService. HTTP is bound to anyIPv4 and automatically
  /// becomes reachable when a Wi-Fi interface receives an address.
  Future<void> reconnectNetworkServices() async {
    bool stopped() => _server == null || _stopping;
    if (stopped()) {
      throw StateError('Camera Server is not running.');
    }
    await webRtcService.reconnectNetworkTransports();
    // stop() có thể chạy trong lúc chờ: không bind lại discovery cho một
    // server đã dừng (socket mồ côi trả cameraId/courtId cũ cho tablet).
    if (stopped()) return;
    await _discovery.stop();
    if (stopped()) return;
    await _discovery.startTcpDiscovery(
      courtId: courtId,
      cameraId: cameraId,
      deviceId: deviceId,
      port: apiPort,
      status: recordingService.recording ? 'RECORDING' : 'READY',
    );
    if (stopped()) {
      await _discovery.stop();
      return;
    }
    developer.log(
      'Network services rebound without restarting capture',
      name: 'CameraServer',
    );
  }

  /// Cập nhật trạng thái Discovery để tablet trên mạng LAN nhận diện ngay lập tức.
  void updateDiscoveryStatus(String status) {
    _discovery.updateStatus(status);
  }

  Future<void> _viewerPage(HttpRequest request) async {
    request.response.headers.contentType = ContentType.html;
    request.response.write('''<!doctype html>
<html lang="vi">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>VNVAR - $cameraId</title>
  <style>
    *{box-sizing:border-box}body{margin:0;background:#050b16;color:#fff;font-family:Arial,sans-serif}
    main{width:100vw;height:100vh;display:flex;flex-direction:column}header{padding:10px 16px;background:#09254b;font-weight:700}
    video{width:100%;height:calc(100vh - 42px);object-fit:contain;background:#000}.state{position:fixed;right:14px;top:11px;color:#b9d7ff;font-size:13px}
  </style>
</head>
<body><main><header>VNVAR · $courtId · $cameraId</header><span class="state" id="state">Đang kết nối...</span><video id="video" autoplay playsinline muted></video></main>
<script>
(()=>{
  const state=document.getElementById('state'), video=document.getElementById('video');
  let cur=null;
  let connecting=false, timer=null, backoff=1000;
  const beacon=function(id){
    if(id&&navigator.sendBeacon){
      navigator.sendBeacon('/webrtc/disconnect',new Blob([JSON.stringify({peerId:id})],{type:'application/json'}));
    }
  };
  const getEpoch=async()=>{
    try{
      const r=await fetch('/webrtc/epoch',{cache:'no-store'});
      if(!r.ok)return null;
      const data=await r.json();
      return data.epoch;
    }catch(_){return null;}
  };

  function teardown(){
    if(!cur)return;
    const old=cur; cur=null;
    old.pc.ontrack=null;
    old.pc.onconnectionstatechange=null;
    try{old.pc.close();}catch(_){}
    beacon(old.peerId);
  }
  function schedule(ms){
    if(timer||connecting)return;
    timer=setTimeout(()=>{timer=null;connect();},ms);
  }
  function scheduleBackoff(){
    schedule(backoff);
    backoff=Math.min(backoff*2,15000);
  }

  async function connect(){
    if(connecting)return;
    connecting=true;
    teardown();
    const peerId='viewer_'+(globalThis.crypto?.randomUUID?.()||Date.now()+'_'+Math.random());
    const pc=new RTCPeerConnection({iceServers:[{urls:'stun:stun.l.google.com:19302'}]});
    const currentEpoch=await getEpoch();
    const me={pc:pc,peerId:peerId,epoch:currentEpoch,lastFrames:-1,stallSince:0};
    cur=me;
    pc.addTransceiver('video',{direction:'recvonly'});
    pc.ontrack=function(e){
      try{e.receiver.playoutDelayHint=0;e.receiver.jitterBufferTarget=0;}catch(_){}
      video.srcObject=e.streams[0];
    };
    pc.onconnectionstatechange=function(){
      if(cur!==me)return;
      state.textContent=pc.connectionState==='connected'?'LIVE':pc.connectionState;
      if(pc.connectionState==='failed')scheduleBackoff();
    };
    try{
      await pc.setLocalDescription(await pc.createOffer());
      if(pc.iceGatheringState!=='complete'){
        await new Promise(function(resolve){
          const done=function(){
            if(pc.iceGatheringState==='complete'){
              pc.removeEventListener('icegatheringstatechange',done);
              resolve();
            }
          };
          pc.addEventListener('icegatheringstatechange',done);
          setTimeout(resolve,8000);
        });
      }
      const offer=pc.localDescription;
      const response=await fetch('/webrtc/offer',{
        method:'POST',
        headers:{'Content-Type':'application/json'},
        body:JSON.stringify({sdp:offer.sdp,type:offer.type,peerId:peerId})
      });
      if(!response.ok)throw new Error('HTTP '+response.status);
      const answer=await response.json();
      await pc.setRemoteDescription(answer);
    }catch(e){
      state.textContent='Lỗi kết nối';
      connecting=false;
      scheduleBackoff();
    }finally{
      connecting=false;
    }
  }

  setInterval(async()=>{
    const me=cur;
    if(!me||connecting)return;
    const ep=await getEpoch();
    if(ep!==null&&me.epoch===null){
      me.epoch=ep;
      return;
    }
    if(ep!==null&&me.epoch!==null&&ep!==me.epoch){
      schedule(300);
      return;
    }
    if(me.pc.connectionState!=='connected')return;
    try{
      const stats=await me.pc.getStats();
      let frames=-1;
      stats.forEach(function(s){
        if(s.type==='inbound-rtp'&&s.kind==='video')frames=s.framesDecoded;
      });
      const now=Date.now();
      if(frames>me.lastFrames){
        me.lastFrames=frames;
        me.stallSince=0;
        backoff=1000;
      }else if(!me.stallSince){
        me.stallSince=now;
      }else if(now-me.stallSince>=4000){
        me.stallSince=0;
        scheduleBackoff();
      }
    }catch(_){}
  },1000);

  addEventListener('pagehide',function(){teardown();});
  connect();
})();
</script></body></html>''');
    await request.response.close();
  }

  // ============================================================
  // ROUTER
  // ============================================================

  Future<void> _handleRequest(HttpRequest request) async {
    final path = request.uri.path;

    final method = request.method;

    developer.log('$method $path', name: 'CameraServer');

    try {
      if (_stopping) {
        await _sendJson(request.response, HttpStatus.serviceUnavailable, {
          'error': 'Camera station is stopping',
          'retryable': true,
        });
        return;
      }
      if (!await _admitRequest(request, path: path, method: method)) return;

      // ========================================================
      // BẢNG TỈ SỐ / OVERLAY NỘI BỘ
      // ========================================================

      if (await _handleScoreboardRequest(request, path, method)) return;

      if ((path == '/' || path == '/viewer') && method == 'GET') {
        await _viewerPage(request);
        return;
      }

      // ========================================================
      // STATUS
      // ========================================================

      if (path == '/status' && method == 'GET') {
        await _status(request);
        return;
      }

      // ========================================================
      // AUTO START
      //
      // Tablet gọi ngay khi tìm thấy/kết nối camera.
      //
      // Không phụ thuộc BẮT ĐẦU TRẬN.
      // ========================================================

      if (path == '/recording/auto-start' && method == 'POST') {
        await _serializeRecordingRequest(() => _autoStartRecording(request));
        return;
      }

      // ========================================================
      // START CŨ
      //
      // Giữ để tương thích.
      // ========================================================

      if (path == '/start' && method == 'POST') {
        await _serializeRecordingRequest(() => _startRecording(request));
        return;
      }

      // ========================================================
      // STOP
      // ========================================================

      if (path == '/stop' && method == 'POST') {
        await _serializeRecordingRequest(() => _stopRecording(request));
        return;
      }

      // ========================================================
      // CHECKVAR
      //
      // Chốt segment hiện tại và mở segment kế tiếp. Live WebRTC vẫn dùng
      // video track đang chạy nên không được đóng camera/peer connection.
      // ========================================================

      if (path.startsWith('/checkvar/jobs/') && method == 'GET') {
        final decodedId = decodeCheckVarJobId(
          path.substring('/checkvar/jobs/'.length),
        );
        if (decodedId == null) {
          await _sendBadRequest(
            request.response,
            'Bad Request',
            message: 'requestId không hợp lệ.',
          );
          return;
        }
        final requestId = normalizeCheckVarRequestId(decodedId, DateTime.now());
        final result = _checkVarResults[requestId];
        final processing = _checkVarJobs.containsKey(requestId);
        await _sendJson(
          request.response,
          result != null
              ? checkVarResponseStatus(result)
              : processing
              ? HttpStatus.accepted
              : HttpStatus.notFound,
          result ??
              {
                'success': processing,
                'requestId': requestId,
                'status': processing ? 'PROCESSING' : 'NOT_FOUND',
                'retryable': !processing,
              },
        );
        return;
      }
      if (checkVarRoutePaths.contains(path) &&
          (method == 'POST' || method == 'GET')) {
        if (_iosLifecycleSuspended) {
          request.response.headers.set(HttpHeaders.retryAfterHeader, '2');
          await _sendJson(request.response, HttpStatus.serviceUnavailable, {
            'success': false,
            'status': 'LIFECYCLE_SUSPENDED',
            'retryable': true,
            'message': 'Camera Station is entering the iOS background.',
          });
          return;
        }
        final receivedAt = DateTime.now();
        final requestId = normalizeCheckVarRequestId(
          request.headers.value('X-Request-ID') ??
              request.uri.queryParameters['requestId'],
          receivedAt,
        );
        final requestedAt = checkVarEventTime(
          request.headers.value('X-Event-Time-Ms') ??
              request.uri.queryParameters['eventTimeMs'],
          receivedAt,
        );
        developer.log(
          '[CHECKVAR] Request received ($method) at ${requestedAt.toIso8601String()} '
          'from ${request.connectionInfo?.remoteAddress.address ?? 'unknown'}',
          name: 'CameraServer',
        );
        final completed = _checkVarResults[requestId];
        if (completed != null) {
          final retryableFailure =
              completed['status'] == 'FAILED' && completed['retryable'] == true;
          if (!retryableFailure) {
            if (request.contentLength != 0) await request.drain<void>();
            await _sendJson(
              request.response,
              checkVarResponseStatus(completed),
              completed,
            );
            return;
          }
          // Lỗi tạm thời: lần gửi lại cùng requestId được chạy lại.
          _checkVarResults.remove(requestId);
        }
        var operation = _checkVarJobs[requestId];
        if (operation == null) {
          operation = _checkVar(
            request,
            requestId: requestId,
            requestedAt: requestedAt,
            receivedAt: receivedAt,
          );
          _checkVarJobs[requestId] = operation;
        } else if (request.contentLength != 0) {
          // A retry has its own HTTP body even though it shares the original
          // operation. Drain it so the keep-alive connection remains valid.
          await request.drain<void>();
        }
        Map<String, dynamic> result;
        try {
          result = await operation;
        } catch (error, stackTrace) {
          developer.log(
            '[CHECKVAR] Request $requestId failed',
            error: error,
            stackTrace: stackTrace,
            name: 'CameraServer',
          );
          // Lưu lỗi như một kết quả (FAILED + mã lỗi) thay vì 500 trơn để
          // tablet tra cứu được qua /checkvar/jobs/{requestId}.
          result = checkVarFailureResult(
            requestId: requestId,
            requestedAt: requestedAt,
            error: error,
          );
        }
        _checkVarResults[requestId] = result;
        if (identical(_checkVarJobs[requestId], operation)) {
          _checkVarJobs.remove(requestId);
        }
        while (_checkVarResults.length > 100) {
          _checkVarResults.remove(_checkVarResults.keys.first);
        }
        await _sendJson(
          request.response,
          checkVarResponseStatus(result),
          result,
        );
        return;
      }

      // ========================================================
      // SEGMENTS
      //
      // Tablet hỏi danh sách segment đã hoàn tất.
      // ========================================================

      if (path == '/segments' && method == 'GET') {
        await _segments(request);
        return;
      }

      // ========================================================
      // ACK DOWNLOAD
      //
      // POST /segments/{id}/downloaded
      // ========================================================

      if (_isDownloadedRoute(request) && method == 'POST') {
        await _markSegmentDownloaded(request);
        return;
      }

      // ========================================================
      // VIDEO LIST CŨ
      // ========================================================

      if (path == '/video' && method == 'GET') {
        await _videos(request);
        return;
      }

      // ========================================================
      // TRIM VIDEO
      //
      // Route tĩnh phải được kiểm tra trước /video/{fileName}, nếu không
      // GET /video/trim sẽ bị hiểu nhầm "trim" là tên một file video.
      // ========================================================

      const trimPaths = {'/trim', '/videos/process/trim', '/video/trim'};
      if (trimPaths.contains(path)) {
        if (method == 'POST') {
          await _trimVideo(request);
        } else {
          request.response.headers.set(HttpHeaders.allowHeader, 'POST');
          await _sendJson(request.response, HttpStatus.methodNotAllowed, {
            'error': 'API /video/trim chỉ hỗ trợ POST',
            'requiredContentType': 'application/json',
            'requiredBody': {
              'segmentId': 'ID lấy từ GET /segments',
              'startMs': 0,
              'endMs': 10000,
            },
          });
        }
        return;
      }

      // ========================================================
      // VIDEO FILE
      //
      // GET /video/file.mp4
      // ========================================================

      if (path.startsWith('/video/') && method == 'GET') {
        await _serveVideo(request);
        return;
      }

      // ========================================================
      // DOWNLOAD CŨ
      // ========================================================

      if (path == '/download/session/close' && method == 'POST') {
        await _closeDownloadSession(request);
        return;
      }

      if (path.startsWith('/download/') && method == 'GET') {
        await _downloadVideo(request);
        return;
      }

      // ========================================================
      // WEBRTC EPOCH
      // ========================================================

      if (path == '/webrtc/epoch' && method == 'GET') {
        await _handleWebRtcEpoch(request);
        return;
      }

      // ========================================================
      // WEBRTC OFFER
      // ========================================================

      if (path == '/webrtc/offer' && method == 'POST') {
        await _handleWebRtcOffer(request);
        return;
      }

      // ========================================================
      // WEBRTC ICE
      // ========================================================

      if (path == '/webrtc/ice' && method == 'POST') {
        await _handleWebRtcIce(request);
        return;
      }

      if (path == '/webrtc/disconnect' && method == 'POST') {
        await _handleWebRtcDisconnect(request);
        return;
      }

      // ========================================================
      // 404
      // ========================================================

      await _sendJson(request.response, HttpStatus.notFound, {
        'error': 'Not Found',
        'path': path,
      });
    } on RequestBodyTimeoutException catch (error) {
      developer.log(
        'CameraServer request body timed out: $error',
        name: 'CameraServer',
      );
      try {
        await _sendJson(request.response, HttpStatus.requestTimeout, {
          'error': 'Request body timeout',
          'retryable': true,
        });
      } catch (_) {
        // The client may already be gone.
      }
    } on PayloadTooLargeException catch (error, stackTrace) {
      developer.log(
        'CameraServer rejected oversized request body',
        error: error,
        stackTrace: stackTrace,
        name: 'CameraServer',
      );
      try {
        await _sendJson(request.response, HttpStatus.requestEntityTooLarge, {
          'error': 'Payload Too Large',
          'maximumBytes': maximumJsonBodyBytes,
        });
      } catch (_) {
        // The client may have disconnected while uploading the body.
      }
    } catch (error, stackTrace) {
      developer.log(
        'CameraServer request error',
        error: error,
        stackTrace: stackTrace,
        name: 'CameraServer',
      );

      try {
        // Mất video track (camera đang mở lại) là lỗi tạm thời: 503 kèm
        // Retry-After và `retryable: true`; lỗi khác giữ nguyên phản hồi 500.
        final transient = isTransientRecorderStartError(error);
        if (transient) {
          request.response.headers.set(
            HttpHeaders.retryAfterHeader,
            '$transientRecorderStartRetryAfterSeconds',
          );
        }
        await _sendJson(
          request.response,
          transient
              ? HttpStatus.serviceUnavailable
              : HttpStatus.internalServerError,
          transientRequestErrorBody(transient: transient),
        );
      } catch (_) {
        // Response có thể đã đóng.
      }
    }
  }

  Future<bool> _admitRequest(
    HttpRequest request, {
    required String path,
    required String method,
  }) async {
    final client = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final limit = cameraServerRateLimitFor(path: path, method: method);
    final allowed = _rateLimiter.allow(
      '$client:${limit.bucket}',
      maximumRequests: limit.maximum,
      window: limit.window,
    );
    if (allowed) return true;
    request.response.headers.set(HttpHeaders.retryAfterHeader, '5');
    await _sendJson(request.response, HttpStatus.tooManyRequests, {
      'error': 'Too Many Requests',
      'message': 'Thiết bị gửi yêu cầu quá nhanh. Vui lòng thử lại.',
    });
    return false;
  }

  Future<T> _serializeRecordingRequest<T>(Future<T> Function() operation) {
    final previous = _recordingRequestTail;
    final current = previous.catchError((Object _) {}).then((_) => operation());
    _recordingRequestTail = current.then<void>((_) {}, onError: (_) {});
    return current;
  }

  Future<T> _serializeCheckVarProcessing<T>(
    Future<T> Function() operation,
  ) {
    final previous = _checkVarProcessingTail;
    final current = previous.catchError((Object _) {}).then((_) => operation());
    _checkVarProcessingTail = current.then<void>((_) {}, onError: (_) {});
    return current;
  }

  /// Prevents a lifecycle stop from racing an accepted CheckVAR/recording
  /// request. iOS calls this while a native background task is active, so an
  /// already accepted checkpoint gets the best available chance to finish
  /// before the camera session is released.
  Future<void> prepareForIosBackground() async {
    _iosLifecycleSuspended = true;
    try {
      await _recordingRequestTail.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      developer.log(
        '[LIFECYCLE] Pending recording request exceeded the iOS background '
        'drain window; continuing camera finalization',
        name: 'CameraServer',
      );
    } catch (error, stackTrace) {
      developer.log(
        '[LIFECYCLE] Pending recording request failed before iOS background',
        error: error,
        stackTrace: stackTrace,
        name: 'CameraServer',
      );
    }
  }

  void resumeAfterIosBackground() {
    _iosLifecycleSuspended = false;
  }

  // ============================================================
  // STATUS
  // ============================================================

  Future<void> _status(HttpRequest request) async {
    recording = recordingService.recording;

    await _sendJson(request.response, HttpStatus.ok, {
      'type': 'VNVAR_CAMERA_STATUS_V1',

      'courtId': courtId,

      'cameraId': cameraId,

      'deviceId': deviceId,

      'status': recordingService.recording ? 'RECORDING' : 'READY',

      'recording': recordingService.recording,
      'acceptingCheckVar': !_iosLifecycleSuspended,

      'serverTimeMs': DateTime.now().millisecondsSinceEpoch,
      'timestamp': DateTime.now().millisecondsSinceEpoch,

      'webrtc': true,

      'cameraReady': webRtcService.cameraInitialized,

      'rtspSupported': webRtcService.rtspSupported,

      'rtspRunning': webRtcService.rtspRunning,

      'rtspAudio': webRtcService.rtspAudio,

      'rtspError': webRtcService.rtspError,

      'videoProfile': {
        'id': webRtcService.resolutionProfile.id,
        'label': webRtcService.resolutionProfile.shortLabel,
        'width': webRtcService.resolutionProfile.width,
        'height': webRtcService.resolutionProfile.height,
        'fps': webRtcService.resolutionProfile.fps,
        'bitrate': webRtcService.resolutionProfile.bitrate,
        'rtspBitrate': webRtcService.resolutionProfile.rtspBitrate,
      },

      'segmentCount': recordingService.segments.length,

      'currentSegmentStartedAt': recordingService.currentSegmentStartedAt
          ?.toIso8601String(),

      'recordingAudio': recordingService.currentSegmentHasAudio,
      // Phiên ghi bật nhưng recorder chưa mở lại được (đang tự thử lại).
      'recordingSuspended': recordingService.isRecordingSuspended,
      'recordingSuspendedReason': recordingService.recordingSuspendedReason,
      'storageWarning': recordingService.lowStorageWarning,
      'storageSuspended': recordingService.storageSuspended,
      'captureState':
          captureStateProvider?.call() ??
          (recordingService.recording ? 'recording' : 'ready'),
      'thermalState': thermalStateProvider?.call() ?? 'unknown',
      'temperatureC': temperatureProvider?.call(),
      'captureMetrics': captureMetricsProvider?.call() ?? const {},
      'webrtcPeers': webRtcService.activePeerCount,
      'webrtcPeerLimit': effectiveWebRtcPeerLimit(
        thermalStateProvider?.call() ?? 'normal',
      ),
      'capabilities': {
        'continuousBackgroundCapture': Platform.isAndroid,
        'foregroundCaptureRequired': Platform.isIOS,
        'rtspFeedback': Platform.isAndroid || Platform.isIOS,
        'preservedShortFragments': true,
      },

      'apiPort': apiPort,
    });
  }

  // ============================================================
  // AUTO START RECORDING
  // ============================================================

  // Tablet đã gọi /stop: không tự ghi lại (health monitor, khôi phục camera,
  // đổi cấu hình…) cho tới khi Tablet gọi /start hoặc /recording/auto-start.
  bool _stoppedByRequest = false;

  bool get stoppedByRequest => _stoppedByRequest;

  /// Tablet yêu cầu dừng ghi: chốt segment cuối và giữ trạng thái dừng.
  Future<RecordedSegment?> stopRecordingByRequest() {
    _stoppedByRequest = true;
    return recordingService.stop();
  }

  /// Tablet yêu cầu ghi lại sau khi đã dừng.
  Future<void> resumeRecordingByRequest() {
    _stoppedByRequest = false;
    return ensureRecording();
  }

  Future<void> ensureRecording() async {
    if (_stoppedByRequest || _stopping) return;
    if (recordingService.recording) {
      recording = true;
      _discovery.updateStatus('RECORDING');
      onStateChanged?.call();
      return;
    }

    final current = _ensureRecordingOperation;
    if (current != null) return current;

    final operation = _startRecorder();
    _ensureRecordingOperation = operation;
    try {
      await operation;
    } finally {
      if (identical(_ensureRecordingOperation, operation)) {
        _ensureRecordingOperation = null;
      }
    }
  }

  Future<void> _autoStartRecording(HttpRequest request) async {
    final captureState = captureStateProvider?.call();
    if (!recordingService.recording &&
        captureStateBlocksRecorderStart(captureState)) {
      // Giống /start: runtime đang đổi cấu hình/khôi phục camera. Chỉ ghi nhận
      // yêu cầu; runtime tự gọi ensureRecording() khi camera sẵn sàng.
      _stoppedByRequest = false;
      await _sendJson(request.response, HttpStatus.ok, {
        'success': true,
        'cameraId': cameraId,
        'recording': false,
        'deferred': true,
        'captureState': captureState,
        'alreadyRunning': false,
      });
      return;
    }
    if (recordingService.recording) {
      recording = true;
      // Giống /start: tablet muốn ghi nên xoá cờ "đã dừng theo yêu cầu" còn
      // sót lại (ví dụ /stop trước đó bị lỗi), để lần đổi profile/khôi phục
      // sau vẫn tự mở lại recorder.
      _stoppedByRequest = false;

      _discovery.updateStatus('RECORDING');

      await _sendJson(request.response, HttpStatus.ok, {
        'success': true,

        'cameraId': cameraId,

        'recording': true,

        'recordingSuspended': recordingService.isRecordingSuspended,

        'alreadyRunning': true,
      });

      return;
    }

    await resumeRecordingByRequest();

    // Trả trạng thái thật sau khi start xong: /stop có thể chen vào hoặc
    // recorder không mở được (phiên bị treo, đang tự thử lại).
    await _sendJson(request.response, HttpStatus.ok, {
      'success': true,

      'cameraId': cameraId,

      'recording': recordingService.recording,

      'recordingSuspended': recordingService.isRecordingSuspended,

      'alreadyRunning': false,
    });
  }

  // ============================================================
  // START RECORDING OLD API
  // ============================================================

  Future<void> _startRecording(HttpRequest request) async {
    final alreadyRunning = recordingService.recording;
    final captureState = captureStateProvider?.call();
    if (!alreadyRunning && captureStateBlocksRecorderStart(captureState)) {
      // Runtime đang đổi cấu hình/khôi phục/tạm dừng camera: gắn recorder lúc
      // này sẽ bám vào track sắp bị huỷ. Chỉ ghi nhận yêu cầu; runtime tự gọi
      // ensureRecording() khi camera sẵn sàng.
      _stoppedByRequest = false;
      await _sendJson(request.response, HttpStatus.ok, {
        'success': true,
        'courtId': courtId,
        'cameraId': cameraId,
        'deviceId': deviceId,
        'status': 'STARTING',
        'recording': false,
        'deferred': true,
        'captureState': captureState,
        'alreadyRunning': false,
      });
      return;
    }
    if (!alreadyRunning) {
      await resumeRecordingByRequest();
    } else {
      _stoppedByRequest = false;
    }

    // Trả trạng thái thật sau khi start hoàn tất: một /stop chen vào hoặc
    // recorder không mở được thì không được báo `recording: true`.
    final nowRecording = recordingService.recording;
    await _sendJson(request.response, HttpStatus.ok, {
      'success': true,

      'courtId': courtId,

      'cameraId': cameraId,

      'deviceId': deviceId,

      'status': nowRecording ? 'RECORDING' : 'READY',

      'recording': nowRecording,

      'recordingSuspended': recordingService.isRecordingSuspended,

      'alreadyRunning': alreadyRunning,
    });
  }

  // ============================================================
  // INTERNAL START
  // ============================================================

  Future<void> _startRecorder() async {
    bool cancelled() => _stoppedByRequest || _stopping;
    if (cancelled()) return;
    final videoTrack = webRtcService.localVideoTrack;

    if (videoTrack == null) {
      throw CameraVideoTrackUnavailableError();
    }

    // /stop có thể đến trong lúc chờ (RecordingService.start chờ lần dừng
    // trước): kiểm tra lại cờ dừng sau mỗi await, không mở recorder sau /stop.
    await recordingService.start(
      videoTrack: videoTrack,
      audioAvailable: webRtcService.microphoneAvailable,
      facingMode: webRtcService.currentFacingMode,
      isCancelled: cancelled,
    );
    // /stop đến trong lúc recorder đang mở: RecordingService.stop() đã chờ
    // lần mở này rồi chốt lại; không báo trạng thái RECORDING sai.
    if (cancelled() || !recordingService.recording) return;

    recording = true;

    _discovery.updateStatus('RECORDING');

    onStateChanged?.call();

    developer.log(
      'AUTO RECORDING STARTED '
      '[$courtId/$cameraId]',
      name: 'CameraServer',
    );
  }

  // ============================================================
  // STOP RECORDING
  // ============================================================

  Future<void> _stopRecording(HttpRequest request) async {
    // Luôn gọi stop để chốt cả recorder/rotation đang finalize, kể cả khi cờ
    // recording vừa đổi trạng thái do một thao tác lifecycle đồng thời.
    final finalSegment = await stopRecordingByRequest();

    recording = false;

    _discovery.updateStatus('READY');

    onStateChanged?.call();

    await _sendJson(request.response, HttpStatus.ok, {
      'success': true,

      'courtId': courtId,

      'cameraId': cameraId,

      'status': 'READY',

      'recording': false,

      'segmentCount': recordingService.segments.length,

      'finalSegment': finalSegment == null
          ? null
          : {
              'id': finalSegment.id,
              'fileName': finalSegment.fileName,
              'durationMs': finalSegment.durationMs,
              'downloadUrl': '/video/${finalSegment.fileName}',
            },
    });
  }

  // ============================================================
  // CHECKVAR
  //
  // Chốt ngay file đang quay và mở file kế tiếp để ghi liên tục.
  // ============================================================

  Future<Map<String, dynamic>> _checkVar(
    HttpRequest request, {
    required String requestId,
    required DateTime requestedAt,
    required DateTime receivedAt,
  }) async {
    final owner = _exportOwnerFor(request);
    int? requestedLookback = int.tryParse(
      request.uri.queryParameters['lookbackSeconds'] ??
          request.uri.queryParameters['lookback'] ??
          request.uri.queryParameters['duration'] ??
          '',
    );
    // Hold the recorder queue only until RecordingService has secured the
    // boundary and handed capture to the next file. Post-checkpoint trimming
    // runs on a separate queue below, so it cannot keep the recorder lock.
    final source = await _serializeRecordingRequest(
      () => _checkpointCheckVar(requestedAt, receivedAt: receivedAt),
    );
    // The recorder boundary is the time-sensitive part of CheckVAR. Never
    // wait for a slow HTTP body before stopping it: on a weak LAN that used
    // to turn a 14:00:31 press into a source file ending at 14:00:45. The
    // optional lookback only affects the exported clip and can be parsed once
    // the source boundary is already secured.
    if (requestedLookback == null && request.contentLength != 0) {
      try {
        final body = await _readJson(request);
        final raw =
            body['lookbackSeconds'] ?? body['lookback'] ?? body['duration'];
        if (raw is num) requestedLookback = raw.toInt();
        if (raw is String) requestedLookback = int.tryParse(raw);
      } catch (_) {
        // No or non-JSON body is safe to ignore.
      }
    }
    final lookbackSeconds = (requestedLookback ?? 15).clamp(5, 60).toInt();
    return _serializeCheckVarProcessing(
      () => _finishCheckVar(
        requestId: requestId,
        requestedAt: requestedAt,
        source: source,
        lookbackSeconds: lookbackSeconds,
        owner: owner,
      ),
    );
  }

  Future<({RecordedSegment segment, bool usedPrevious})> _checkpointCheckVar(
    DateTime requestedAt, {
    required DateTime receivedAt,
  }) async {
    final target = checkVarCoverageTarget(
      requestedAt: requestedAt,
      receivedAt: receivedAt,
    );
    final activeStartedAt = recordingService.currentSegmentStartedAt;
    RecordedSegment? historical;
    if (activeStartedAt == null) {
      // Không có segment đang ghi (đã /stop, đang treo ghi...): sự kiện vẫn
      // có thể nằm trong một segment đã chốt. Không có thì mới xét chốt
      // segment hiện tại (trả NOT_RECORDING nếu không có gì để chốt).
      historical = recordingService.findByTime(requestedAt);
    } else if (requestedAt.isBefore(activeStartedAt)) {
      historical = recordingService.findByTime(requestedAt);
      if (historical == null) {
        throw CheckVarSegmentUnavailableException(
          'NO_SEGMENT',
          'Không còn segment chứa thời điểm CheckVAR '
              '${requestedAt.toIso8601String()}.',
        );
      }
    }
    RecordedSegment segment;
    bool usedPrevious;
    if (historical != null) {
      segment = historical;
      usedPrevious = true;
    } else {
      // Sự kiện nằm trong segment đang ghi: để segment đó đủ dài để được
      // công bố (≥ 1 s hình) trước khi chốt, nếu không đoạn chứa sự kiện bị
      // chuyển vào FRAGMENTS và clip thiếu khoảnh khắc.
      if (activeStartedAt != null) {
        await _waitForCheckVarActiveSegment(activeStartedAt);
      }
      segment = await recordingService.checkpointCurrentSegment();
      usedPrevious = recordingService.lastCheckpointUsedPrevious;
      final resolved = await _ensureCheckVarSourceCovers(segment, target);
      if (!identical(resolved, segment)) {
        segment = resolved;
        usedPrevious = false;
      }
    }
    developer.log(
      '[CHECKVAR] Recorder boundary secured: ${segment.fileName} '
      '(${segment.durationMs}ms)',
      name: 'CameraServer',
    );
    // Chỉ mở lại recorder sau một lần chốt thật; tra segment đã chốt (đã
    // /stop, treo ghi, tạm dừng camera) không được tự bật ghi lại.
    if (historical == null &&
        !recordingService.recording &&
        !recordingService.rotating) {
      try {
        await ensureRecording();
      } catch (error, stackTrace) {
        developer.log(
          '[CHECKVAR] Failed to restart recording after checkpoint',
          error: error,
          stackTrace: stackTrace,
          name: 'CameraServer',
        );
      }
    }
    return (segment: segment, usedPrevious: usedPrevious);
  }

  Future<void> _waitForCheckVarActiveSegment(DateTime activeStartedAt) async {
    final wait = checkVarActiveSegmentWait(
      activeStartedAt: activeStartedAt,
      now: DateTime.now(),
    );
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  CheckVarSegmentUnavailableException _checkVarSourceNotReady(
    DateTime target,
  ) => CheckVarSegmentUnavailableException(
    'NOT_RECORDING',
    'Đoạn video chứa thời điểm CheckVAR ${target.toIso8601String()} '
        'chưa được chốt xong; vui lòng gửi lại.',
  );

  /// Segment nguồn trả về khi nhập vào một lượt chuyển segment đang chạy kết
  /// thúc TRƯỚC thời điểm sự kiện: chốt tiếp segment đang ghi (chứa sự kiện)
  /// rồi mới cắt; clip sẽ ghép phần cuối segment trước. Không đủ dữ liệu thì
  /// báo lỗi thử lại được thay vì trả clip thiếu khoảnh khắc.
  Future<RecordedSegment> _ensureCheckVarSourceCovers(
    RecordedSegment segment,
    DateTime target,
  ) async {
    final activeStartedAt = recordingService.currentSegmentStartedAt;
    final coverage = checkVarSourceCoverage(
      sourceEndedAt: segment.endedAt,
      target: target,
      activeStartedAt: activeStartedAt,
    );
    if (coverage == CheckVarSourceCoverage.covered ||
        coverage == CheckVarSourceCoverage.unrecordedGap) {
      return segment;
    }
    // Một lượt chuyển segment khác có thể đã chốt đoạn chứa sự kiện.
    final finalized = recordingService.findByTime(target);
    if (finalized != null) return finalized;
    if (coverage != CheckVarSourceCoverage.needsActiveSegment ||
        activeStartedAt == null) {
      throw _checkVarSourceNotReady(target);
    }
    developer.log(
      '[CHECKVAR] ${segment.fileName} ends before the event '
      '(${segment.endedAt.toIso8601String()} < ${target.toIso8601String()}); '
      'checkpointing the active segment',
      name: 'CameraServer',
    );
    final timeout = checkVarFollowUpTimeout(
      activeAge: DateTime.now().difference(activeStartedAt),
      segmentDuration: recordingService.segmentDuration,
    );
    final RecordedSegment next;
    try {
      next = await () async {
        await _waitForCheckVarActiveSegment(activeStartedAt);
        return recordingService.checkpointCurrentSegment();
      }().timeout(timeout);
    } on TimeoutException {
      throw _checkVarSourceNotReady(target);
    }
    final nextCoverage = checkVarSourceCoverage(
      sourceEndedAt: next.endedAt,
      target: target,
      activeStartedAt: recordingService.currentSegmentStartedAt,
    );
    if (nextCoverage == CheckVarSourceCoverage.covered &&
        !next.startedAt.isAfter(target.add(checkVarCoverageTolerance))) {
      return next;
    }
    final contained = recordingService.findByTime(target);
    if (contained != null) return contained;
    throw _checkVarSourceNotReady(target);
  }

  Future<Map<String, dynamic>> _finishCheckVar({
    required String requestId,
    required DateTime requestedAt,
    required ({RecordedSegment segment, bool usedPrevious}) source,
    required int lookbackSeconds,
    required String owner,
  }) async {
    final segment = source.segment;
    RecordedSegment checkpoint = segment;
    var autoTrimmed = false;
    String? trimError;
    final range = checkVarClipRange(
      segmentStartedAt: segment.startedAt,
      segmentEndedAt: segment.endedAt,
      requestedAt: requestedAt,
      lookback: Duration(seconds: lookbackSeconds),
      keyframeSafetyMargin: const Duration(seconds: 5),
    );
    // Trọng tài bấm ngay sau lúc chuyển segment: đoạn trước sự kiện nằm ở
    // segment trước. Lấy phần còn thiếu từ đó để clip luôn đủ thời lượng.
    final requestedWindowMs = (lookbackSeconds + 5) * 1000;
    final missingBeforeMs = requestedWindowMs - (range.endMs - range.startMs);
    final preceding = range.startMs == 0 && missingBeforeMs > 500
        ? recordingService.precedingSegmentOf(segment)
        : null;
    final clipStartMs = preceding == null
        ? range.startMs
        : range.endMs - requestedWindowMs;
    if (range.endMs - clipStartMs >= 500) {
      try {
        Future<RecordedSegment> trim() => recordingService.trimSegment(
          segmentId: segment.id,
          startMs: clipStartMs,
          endMs: range.endMs,
          streamCopy: true,
          minimumOutputDurationMs: 500,
          precedingSegmentId: preceding?.id,
          owner: owner,
          // Check VAR chen trước các lệnh /trim thủ công đang chờ.
          priority: true,
        );
        try {
          checkpoint = await trim();
        } on TrimInProgressException {
          // Dự phòng (job ưu tiên không bị giới hạn hàng đợi): chờ xong rồi
          // cắt, không bỏ clip Check VAR.
          await recordingService.waitForTrimIdle();
          checkpoint = await trim();
        }
        autoTrimmed = true;
        developer.log(
          '[CHECKVAR] Clip ready: ${checkpoint.fileName} '
          '(${checkpoint.durationMs}ms)',
          name: 'CameraServer',
        );
      } catch (error, stackTrace) {
        trimError = userFacingError(error);
        developer.log(
          'Unable to create automatic Check VAR clip; returning source segment',
          error: error,
          stackTrace: stackTrace,
          name: 'CameraServer',
        );
      }
    }
    final checkpointDownloadUrl = autoTrimmed
        ? '/download/${checkpoint.fileName}'
        : '/video/${checkpoint.fileName}';
    final now = DateTime.now().millisecondsSinceEpoch;
    final result = <String, dynamic>{
      'success': true,
      'message': 'Flushed active segment successfully',
      'timestamp': now,
      'requestId': requestId,
      'status': 'READY',
      'requestedAt': requestedAt.toIso8601String(),
      'usedPreviousSegment': source.usedPrevious,
      // Clip đã nối thêm phần cuối segment liền trước (false nếu không cần
      // hoặc hai file khác codec/kích thước/góc xoay nên không nối được).
      'joinedPrecedingSegment':
          autoTrimmed && checkpoint.joinedPrecedingSegment,
      'autoTrimmed': autoTrimmed,
      'lookbackSeconds': lookbackSeconds,
      'trimError': trimError,
      'checkpointSegment': {
        'id': segment.id,
        'fileName': segment.fileName,
        'durationMs': segment.durationMs,
        'downloadUrl': '/video/${segment.fileName}',
      },
      'checkVarClip': autoTrimmed
          ? {
              'id': checkpoint.id,
              'fileName': checkpoint.fileName,
              'durationMs': checkpoint.durationMs,
              'downloadUrl': checkpointDownloadUrl,
              'eventOffsetMs': checkpoint.durationMs,
            }
          : null,
      'preferredDownloadUrl': checkpointDownloadUrl,
    };
    developer.log(
      '[CHECKVAR] Response sent: autoTrimmed=$autoTrimmed '
      'url=$checkpointDownloadUrl',
      name: 'CameraServer',
    );
    return result;
  }

  // ============================================================
  // SEGMENTS
  // ============================================================

  Future<void> _segments(HttpRequest request) async {
    final now = DateTime.now();
    final segments = recordingService.segments.map((segment) {
      final safeDuration = segment.durationMs <= 0 ? 1 : segment.durationMs;
      return {
        ...segment.toJson(),
        'durationMs': safeDuration,
        'downloadUrl': '/video/${segment.fileName}',
      };
    }).toList();

    Map<String, dynamic>? activeSegmentJson;
    final activeStartedAt = recordingService.currentSegmentStartedAt;
    final activePath = recordingService.currentPath;
    if (recordingService.recording &&
        activeStartedAt != null &&
        activePath != null) {
      final activeDurationMs = now.difference(activeStartedAt).inMilliseconds;
      final fileName = activePath.split(Platform.pathSeparator).last;
      activeSegmentJson = {
        'id': fileName,
        'fileName': fileName,
        'startTime': activeStartedAt.toIso8601String(),
        'endTime': now.toIso8601String(),
        'durationMs': activeDurationMs <= 0 ? 1 : activeDurationMs,
        // File đang ghi nằm ở staging và chưa được index nên không phục vụ
        // được; chỉ trả URL sau khi segment hoàn tất.
        'downloadUrl': null,
        'downloadable': false,
        'type': 'RECORDING',
        'active': true,
      };
    }

    await _sendJson(request.response, HttpStatus.ok, {
      'type': 'VNVAR_SEGMENT_LIST_V1',

      'courtId': courtId,

      'cameraId': cameraId,

      'recording': recordingService.recording,

      'serverTimeMs': now.millisecondsSinceEpoch,

      'segments': segments,

      'activeSegment': ?activeSegmentJson,
    });
  }

  // ============================================================
  // CHECK ROUTE:
  //
  // /segments/{id}/downloaded
  // ============================================================

  bool _isDownloadedRoute(HttpRequest request) {
    final parts = request.uri.pathSegments;

    if (parts.length != 3) {
      return false;
    }

    return parts[0] == 'segments' && parts[2] == 'downloaded';
  }

  // ============================================================
  // TABLET ACK DOWNLOAD
  // ============================================================

  Future<void> _markSegmentDownloaded(HttpRequest request) async {
    final parts = request.uri.pathSegments;

    if (parts.length != 3) {
      await _sendJson(request.response, HttpStatus.badRequest, {
        'error': 'Invalid segment route',
      });

      return;
    }

    final segmentId = parts[1];

    developer.log(
      'Tablet confirmed segment downloaded: '
      '$segmentId',
      name: 'CameraServer',
    );

    final marked = await recordingService.acknowledgeDownloaded(segmentId);

    if (!marked) {
      await _sendJson(request.response, HttpStatus.notFound, {
        'success': false,

        'segmentId': segmentId,

        'error': 'Segment not found',
      });

      return;
    }

    await _sendJson(request.response, HttpStatus.ok, {
      'success': true,

      'segmentId': segmentId,

      'downloaded': true,

      'keptOnCamera': true,
    });
  }

  // ============================================================
  // OLD VIDEO LIST
  // ============================================================

  Future<void> _videos(HttpRequest request) async {
    final videos = recordingService.segments
        .map((segment) => segment.toJson())
        .toList();

    await _sendJson(request.response, HttpStatus.ok, {
      'courtId': courtId,

      'cameraId': cameraId,

      'videos': videos,
    });
  }

  // ============================================================
  // FIND VIDEO
  // ============================================================

  RecordedSegment? _findVideo(String fileName) {
    return recordingService.findByFileName(fileName) ??
        recordingService.findExportByFileName(fileName);
  }

  // ============================================================
  // SERVE VIDEO
  // ============================================================

  Future<void> _serveVideo(HttpRequest request) async {
    if (request.uri.pathSegments.isEmpty) {
      await _sendNotFound(request.response);

      return;
    }

    final fileName = request.uri.pathSegments.last;

    final segment = _findVideo(fileName);

    if (segment == null) {
      await _sendNotFound(request.response);

      return;
    }

    final file = File(segment.path);

    if (!await file.exists()) {
      await _sendNotFound(request.response);

      return;
    }

    await _sendVideoFile(request, file, attachment: false);
  }

  // ============================================================
  // DOWNLOAD
  // ============================================================

  Future<void> _downloadVideo(HttpRequest request) async {
    if (request.uri.pathSegments.isEmpty) {
      await _sendNotFound(request.response);

      return;
    }

    final fileName = request.uri.pathSegments.last;

    final segment =
        recordingService.findExportByFileName(fileName) ?? _findVideo(fileName);

    if (segment == null) {
      await _sendNotFound(request.response);

      return;
    }

    final file = File(segment.path);

    if (!await file.exists()) {
      await _sendNotFound(request.response);

      return;
    }

    await _sendVideoFile(request, file, attachment: true);
  }

  /// Khoá phiên tải clip của request (xem [exportSessionOwner]).
  String _exportOwnerFor(HttpRequest request) => exportSessionOwner(
    peerId: request.headers.value('X-Peer-ID'),
    remoteAddress: request.connectionInfo?.remoteAddress.address ?? 'unknown',
  );

  Future<void> _closeDownloadSession(HttpRequest request) async {
    // Chỉ xoá clip của chính tablet đóng phiên (và clip mồ côi quá hạn);
    // clip các tablet khác đang dùng được giữ nguyên.
    final owner = _exportOwnerFor(request);
    await recordingService.cleanupExportDownloads(owner: owner);
    onStateChanged?.call();
    await _sendJson(request.response, HttpStatus.ok, {
      'success': true,
      'downloadSession': 'closed',
    });
  }

  Future<void> _trimVideo(HttpRequest request) async {
    late final Map<String, dynamic> body;
    try {
      body = await _readJson(request);
    } on FormatException catch (error) {
      await _sendJson(request.response, HttpStatus.badRequest, {
        'error': 'Bad Request',
        'message': error.message,
      });
      return;
    }
    final segmentId = body['segmentId'];
    final startMs = body['startMs'];
    final endMs = body['endMs'];
    if (segmentId is! String ||
        segmentId.trim().isEmpty ||
        startMs is! num ||
        endMs is! num) {
      await _sendJson(request.response, HttpStatus.badRequest, {
        'error': 'Bad Request',
        'message': 'segmentId, startMs và endMs là bắt buộc',
      });
      return;
    }
    if (!isManualTrimDurationAllowed(startMs: startMs, endMs: endMs)) {
      // Clip quá dài giữ hàng đợi FFmpeg lâu và làm chậm Check VAR.
      await _sendJson(request.response, HttpStatus.unprocessableEntity, {
        'error': 'Unprocessable Entity',
        'errorCode': 'TRIM_FAILED',
        'message':
            'Đoạn cắt tối đa ${maximumManualTrimDurationMs ~/ 60000} phút.',
        'maximumDurationMs': maximumManualTrimDurationMs,
      });
      return;
    }
    late final RecordedSegment clip;
    try {
      clip = await recordingService.trimSegment(
        segmentId: segmentId.trim(),
        startMs: startMs.toInt(),
        endMs: endMs.toInt(),
        owner: _exportOwnerFor(request),
      );
    } on InvalidTrimRangeException catch (error) {
      await _sendJson(request.response, HttpStatus.badRequest, {
        'error': 'Bad Request',
        'message': error.message,
      });
      return;
    } on TrimSegmentNotFoundException catch (error) {
      await _sendJson(request.response, HttpStatus.notFound, {
        'error': 'Not Found',
        'message': error.message,
      });
      return;
    } on TrimInProgressException catch (error) {
      await _sendJson(request.response, HttpStatus.conflict, {
        'error': 'Conflict',
        'message': error.message,
      });
      return;
    }
    onStateChanged?.call();
    await _sendJson(request.response, HttpStatus.ok, {
      'success': true,
      'courtId': courtId,
      ...clip.toJson(),
      'downloadUrl': '/download/${clip.fileName}',
      'cleanupUrl': '/download/session/close',
      'cleanupMethod': 'POST',
    });
  }

  // ============================================================
  // SEND VIDEO FILE
  //
  // Có hỗ trợ HTTP Range để:
  //
  // - Tablet download
  // - video_player seek
  // - tua video ổn định
  // ============================================================

  Future<void> _sendVideoFile(
    HttpRequest request,
    File file, {
    required bool attachment,
  }) async {
    recordingService.acquireFileRead(file.path);
    try {
      await _sendVideoFileWhileLeased(request, file, attachment: attachment);
    } finally {
      recordingService.releaseFileRead(file.path);
    }
  }

  Future<void> _sendVideoFileWhileLeased(
    HttpRequest request,
    File file, {
    required bool attachment,
  }) async {
    final response = request.response;

    final int fileLength = await file.length();

    final String fileName = file.uri.pathSegments.last;

    // Tắt bufferOutput của HttpResponse để tránh buffer dữ liệu video vào heap RAM,
    // đẩy thẳng qua TCP socket giúp tablet stream mượt, không bị nghẽn giật cục.
    response.bufferOutput = false;

    response.headers.set('Accept-Ranges', 'bytes');

    response.headers.set(
      HttpHeaders.contentTypeHeader,
      fileName.toLowerCase().endsWith('.ts') ? 'video/mp2t' : 'video/mp4',
    );

    response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');

    if (attachment) {
      response.headers.set(
        'Content-Disposition',
        'attachment; filename="$fileName"',
      );
    }

    final String? rangeHeader = request.headers.value('Range');

    // ==========================================================
    // NORMAL FULL FILE
    // ==========================================================

    if (rangeHeader == null || !rangeHeader.startsWith('bytes=')) {
      response.statusCode = HttpStatus.ok;

      response.headers.set(HttpHeaders.contentLengthHeader, fileLength);

      await response.addStream(file.openRead());

      await response.close();

      return;
    }

    // ==========================================================
    // RANGE
    // ==========================================================

    final String rawRange = rangeHeader.substring(6).trim();
    final parts = rawRange.split('-');

    int? start;
    int? end;
    var validRange =
        fileLength > 0 &&
        !rawRange.contains(',') &&
        parts.length == 2 &&
        (parts[0].isNotEmpty || parts[1].isNotEmpty);

    if (validRange && parts[0].isEmpty) {
      // Suffix range, ví dụ bytes=-500: lấy 500 byte cuối file.
      final suffixLength = int.tryParse(parts[1]);
      if (suffixLength == null || suffixLength <= 0) {
        validRange = false;
      } else {
        end = fileLength - 1;
        start = suffixLength >= fileLength ? 0 : fileLength - suffixLength;
      }
    } else if (validRange) {
      start = int.tryParse(parts[0]);
      if (start == null || start < 0 || start >= fileLength) {
        validRange = false;
      } else if (parts[1].isEmpty) {
        end = fileLength - 1;
      } else {
        end = int.tryParse(parts[1]);
        if (end == null || end < start) {
          validRange = false;
        } else if (end >= fileLength) {
          end = fileLength - 1;
        }
      }
    }

    if (!validRange || start == null || end == null) {
      response.statusCode = 416;

      response.headers.set('Content-Range', 'bytes */$fileLength');

      await response.close();

      return;
    }

    final int contentLength = end - start + 1;

    response.statusCode = HttpStatus.partialContent;

    response.headers.set('Content-Range', 'bytes $start-$end/$fileLength');

    response.headers.set(HttpHeaders.contentLengthHeader, contentLength);

    await response.addStream(file.openRead(start, end + 1));

    await response.close();
  }

  // ============================================================
  // WEBRTC OFFER
  // ============================================================

  Future<void> _handleWebRtcOffer(HttpRequest request) async {
    if (_pendingWebRtcOffers >= maximumPendingWebRtcOffers) {
      request.response.headers.set(HttpHeaders.retryAfterHeader, '1');
      await _sendJson(request.response, HttpStatus.serviceUnavailable, {
        'error': 'WebRTC negotiation queue is full',
        'retryable': true,
      });
      return;
    }
    // Giữ chỗ TRƯỚC khi đọc body (không có await giữa kiểm tra và tăng bộ
    // đếm), nếu không nhiều offer đến cùng lúc đều vượt qua trần 4.
    _pendingWebRtcOffers++;
    try {
      // Đọc xong body TRƯỚC khi vào hàng đợi tuần tự: một tablet gửi body
      // chậm không được chặn lượt kết nối của các tablet khác.
      final body = await _readJsonOrBadRequest(request);
      if (body == null) return;

      final sdp = body['sdp'];
      final type = body['type'];
      if (sdp is! String || sdp.isEmpty || type is! String || type.isEmpty) {
        await _sendBadRequest(request.response, 'Invalid WebRTC offer');
        return;
      }
      final peerId = _peerIdForRequest(request, body);

      final previous = _webRtcOfferTail;
      final turn = Completer<void>();
      _webRtcOfferTail = turn.future;
      try {
        try {
          await previous;
        } catch (_) {
          // A failed older offer must not poison the next handover.
        }

        developer.log('Received WebRTC offer', name: 'CameraServer');

        final peerLimit = effectiveWebRtcPeerLimit(
          thermalStateProvider?.call() ?? 'normal',
        );
        if (!webRtcService.hasPeer(peerId) &&
            webRtcService.activePeerCount >= peerLimit) {
          request.response.headers.set(HttpHeaders.retryAfterHeader, '2');
          await _sendJson(request.response, HttpStatus.serviceUnavailable, {
            'error': 'WebRTC peer capacity reached',
            'retryable': true,
            'peerId': peerId,
            'activePeers': webRtcService.activePeerCount,
            'maximumPeers': peerLimit,
          });
          return;
        }

        if (!webRtcService.cameraInitialized) {
          request.response.headers.set(HttpHeaders.retryAfterHeader, '2');
          await _sendJson(request.response, HttpStatus.serviceUnavailable, {
            'error': 'Camera is not ready',
            'retryable': true,
            'captureState': captureStateProvider?.call(),
            'peerId': peerId,
          });
          return;
        }

        late final RTCSessionDescription answer;
        try {
          answer = await webRtcService.handleOffer(
            sdp: sdp,
            type: type,
            peerId: peerId,
            maximumPeers: peerLimit,
          );
        } on CameraNotReadyException {
          // Camera vừa bị dispose trong lúc chờ hàng đợi offer.
          await webRtcService.disposePeerConnection(peerId);
          request.response.headers.set(HttpHeaders.retryAfterHeader, '2');
          await _sendJson(request.response, HttpStatus.serviceUnavailable, {
            'error': 'Camera is not ready',
            'retryable': true,
            'captureState': captureStateProvider?.call(),
            'peerId': peerId,
          });
          return;
        } catch (_) {
          // A malformed/aborted negotiation must not consume a peer slot.
          await webRtcService.disposePeerConnection(peerId);
          rethrow;
        }

        await _sendJson(request.response, HttpStatus.ok, {
          'sdp': answer.sdp,

          'type': answer.type,

          'peerId': peerId,
        });

        developer.log('WebRTC answer returned', name: 'CameraServer');
      } finally {
        if (!turn.isCompleted) turn.complete();
      }
    } finally {
      _pendingWebRtcOffers--;
    }
  }

  // ============================================================
  // WEBRTC ICE
  // ============================================================

  Future<void> _handleWebRtcIce(HttpRequest request) async {
    final body = await _readJsonOrBadRequest(request);
    if (body == null) return;

    final candidate = body['candidate'];
    final sdpMid = body['sdpMid'];

    if (candidate is! String ||
        candidate.isEmpty ||
        (sdpMid != null && sdpMid is! String)) {
      await _sendBadRequest(request.response, 'Invalid ICE candidate');

      return;
    }

    final peerId = _peerIdForRequest(request, body);

    final rawIndex = body['sdpMLineIndex'];

    int? index;

    if (rawIndex is int) {
      index = rawIndex;
    } else if (rawIndex is num && rawIndex.isFinite) {
      index = rawIndex.toInt();
    }

    await webRtcService.addIceCandidate(
      candidate: candidate,

      sdpMid: sdpMid is String ? sdpMid : null,

      sdpMLineIndex: index,

      peerId: peerId,
    );

    await _sendJson(request.response, HttpStatus.ok, {
      'success': true,
      'peerId': peerId,
    });
  }

  Future<void> _handleWebRtcDisconnect(HttpRequest request) async {
    final body = await _readJsonOrBadRequest(request);
    if (body == null) return;
    final peerId = _peerIdForRequest(request, body);
    final existed = webRtcService.hasPeer(peerId);
    await webRtcService.disposePeerConnection(peerId);
    await _sendJson(request.response, HttpStatus.ok, {
      'success': true,
      'peerId': peerId,
      'disconnected': existed,
      'activePeers': webRtcService.activePeerCount,
    });
  }

  Future<void> _handleWebRtcEpoch(HttpRequest request) async {
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    await _sendJson(request.response, HttpStatus.ok, {
      'epoch': webRtcService.videoEpoch,
    });
  }

  String _peerIdForRequest(HttpRequest request, Map<String, dynamic> body) {
    final supplied =
        body['peerId'] ??
        body['sessionId'] ??
        request.headers.value('X-Peer-ID');
    return normalizeWebRtcPeerId(
      supplied?.toString(),
      fallbackAddress:
          request.connectionInfo?.remoteAddress.address ?? 'unknown',
    );
  }

  // ============================================================
  // SCOREBOARD
  // ============================================================

  Future<bool> _handleScoreboardRequest(
    HttpRequest request,
    String path,
    String method,
  ) async {
    if (method == 'GET' && path == '/control') {
      await _sendHtml(request.response, scoreboardControlPageHtml);
      return true;
    }
    if (method == 'GET' && path == '/overlay') {
      await _sendHtml(request.response, scoreboardOverlayPageHtml);
      return true;
    }
    if (!path.startsWith('/api/score')) return false;

    if (method == 'GET' && path == '/api/score') {
      await _sendJson(request.response, HttpStatus.ok, scoreboard.snapshot());
      return true;
    }
    if (method == 'GET' && path == '/api/score/events') {
      await _scoreboardEvents(request);
      return true;
    }
    if (method == 'POST' && path == '/api/score') {
      await _scoreboardAction(request);
      return true;
    }
    if (method == 'POST' && path == '/api/score/logo') {
      await _scoreboardLogoUpload(request);
      return true;
    }
    if (method == 'GET' && path.startsWith('/api/score/logo/')) {
      await _scoreboardLogo(request, path.substring('/api/score/logo/'.length));
      return true;
    }
    await _sendJson(request.response, HttpStatus.notFound, {
      'ok': false,
      'error': 'not_found',
      'path': path,
    });
    return true;
  }

  bool _scoreboardKeyOk(HttpRequest request) {
    final candidate =
        request.headers.value('x-score-key') ?? request.uri.queryParameters['k'];
    return scoreboard.verifyKey(candidate);
  }

  Future<void> _sendScoreboardError(
    HttpResponse response,
    int statusCode,
    String code,
    String message,
  ) {
    return _sendJson(response, statusCode, {
      'ok': false,
      'error': code,
      'message': message,
    });
  }

  Future<void> _sendHtml(HttpResponse response, String html) async {
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType.html;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.write(html);
    await response.close();
  }

  Future<void> _scoreboardAction(HttpRequest request) async {
    if (!_scoreboardKeyOk(request)) {
      await _sendScoreboardError(
        request.response,
        HttpStatus.unauthorized,
        'invalid_key',
        'Mã điều khiển không đúng. Quét lại mã QR trên app Camera Station.',
      );
      return;
    }
    final Map<String, dynamic> body;
    try {
      body = await _readJson(request);
    } on FormatException {
      await _sendScoreboardError(
        request.response,
        HttpStatus.badRequest,
        'invalid_json',
        'Nội dung gửi lên không phải JSON hợp lệ.',
      );
      return;
    }
    final action = isLegacyScoreboardBody(body)
        ? <String, dynamic>{...body, 'action': 'setScore'}
        : body;
    try {
      final state = scoreboard.apply(action);
      await _sendJson(request.response, HttpStatus.ok, {
        'ok': true,
        'state': state,
      });
    } on ScoreboardException catch (error) {
      await _sendScoreboardError(
        request.response,
        error.statusCode,
        error.code,
        error.message,
      );
    }
  }

  Future<void> _scoreboardLogoUpload(HttpRequest request) async {
    if (!_scoreboardKeyOk(request)) {
      await _sendScoreboardError(
        request.response,
        HttpStatus.unauthorized,
        'invalid_key',
        'Mã điều khiển không đúng.',
      );
      return;
    }
    const maximum = ScoreboardService.maximumLogoBytes;
    if (request.contentLength > maximum) {
      await _sendScoreboardError(
        request.response,
        HttpStatus.requestEntityTooLarge,
        'logo_too_large',
        'Logo phải nhỏ hơn 512 KB.',
      );
      return;
    }
    final bytes = <int>[];
    var tooLarge = false;
    try {
      await request
          .forEach((chunk) {
            if (tooLarge) return;
            if (bytes.length + chunk.length > maximum) {
              tooLarge = true;
              return;
            }
            bytes.addAll(chunk);
          })
          .timeout(requestBodyTimeout);
    } on TimeoutException {
      throw const RequestBodyTimeoutException(requestBodyTimeout);
    }
    if (tooLarge) {
      await _sendScoreboardError(
        request.response,
        HttpStatus.requestEntityTooLarge,
        'logo_too_large',
        'Logo phải nhỏ hơn 512 KB.',
      );
      return;
    }
    final team = (request.uri.queryParameters['team'] ?? '').toUpperCase();
    try {
      final state = await scoreboard.saveLogo(team, bytes);
      await _sendJson(request.response, HttpStatus.ok, {
        'ok': true,
        'state': state,
      });
    } on ScoreboardException catch (error) {
      await _sendScoreboardError(
        request.response,
        error.statusCode,
        error.code,
        error.message,
      );
    }
  }

  Future<void> _scoreboardLogo(HttpRequest request, String rawId) async {
    String id;
    try {
      id = Uri.decodeComponent(rawId);
    } catch (_) {
      id = '';
    }
    final file = isValidScoreboardLogoId(id)
        ? await scoreboard.logoFile(id)
        : null;
    if (file == null) {
      await _sendScoreboardError(
        request.response,
        HttpStatus.notFound,
        'logo_not_found',
        'Không tìm thấy logo.',
      );
      return;
    }
    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType.parse(
      scoreboardContentTypeForLogo(id),
    );
    // Mỗi lần tải logo mới có id mới nên được phép cache lâu.
    response.headers.set(HttpHeaders.cacheControlHeader, 'public, max-age=86400');
    await response.addStream(file.openRead());
    await response.close();
  }

  Future<void> _scoreboardEvents(HttpRequest request) async {
    if (_scoreStreams.length >= maximumScoreboardStreams) {
      request.response.headers.set(HttpHeaders.retryAfterHeader, '5');
      await _sendScoreboardError(
        request.response,
        HttpStatus.serviceUnavailable,
        'too_many_streams',
        'Quá nhiều màn hình đang kết nối bảng tỉ số.',
      );
      return;
    }
    final response = request.response;
    response.bufferOutput = false;
    response.statusCode = HttpStatus.ok;
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      'text/event-stream; charset=utf-8',
    );
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache, no-transform');
    response.headers.set('X-Accel-Buffering', 'no');

    final stream = _ScoreboardStream(response);
    _scoreStreams.add(stream);
    String event(String name, Object data) =>
        'event: $name\ndata: ${jsonEncode(data)}\n\n';

    stream.send('retry: 2000\n\n');
    stream.send(event('state', scoreboard.snapshot()));
    stream.subscription = scoreboard.changes.listen(
      (json) => stream.send(event('state', json)),
    );
    // Heartbeat có tên để client biết kết nối còn sống (comment SSE không
    // kích hoạt sự kiện ở trình duyệt).
    stream.heartbeat = Timer.periodic(
      const Duration(seconds: 15),
      (_) => stream.send('event: ping\ndata: {}\n\n'),
    );
    unawaited(
      response.done.then<void>(
        (_) => stream.close(),
        onError: (Object _) => stream.close(),
      ),
    );
    await stream.done.future;
    _scoreStreams.remove(stream);
  }

  // ============================================================
  // READ JSON
  // ============================================================

  Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
    final declaredLength = request.contentLength;
    if (declaredLength > maximumJsonBodyBytes) {
      throw const PayloadTooLargeException(maximumJsonBodyBytes);
    }

    final decoder = BoundedJsonBodyDecoder(maximumBytes: maximumJsonBodyBytes);
    try {
      await request
          .forEach(decoder.add)
          .timeout(requestBodyTimeout);
    } on TimeoutException {
      throw const RequestBodyTimeoutException(requestBodyTimeout);
    }
    return decoder.decode();
  }

  /// Thời gian tối đa để nhận xong body JSON của một request.
  static const Duration requestBodyTimeout = Duration(seconds: 10);

  /// Đọc body JSON; body không phải JSON object hợp lệ → trả 400 (không để
  /// lỗi định dạng của client thành 500) và trả về null.
  Future<Map<String, dynamic>?> _readJsonOrBadRequest(
    HttpRequest request,
  ) async {
    try {
      return await _readJson(request);
    } on FormatException catch (error) {
      await _sendBadRequest(
        request.response,
        'Invalid JSON body',
        message: error.message,
      );
      return null;
    }
  }

  Future<void> _sendBadRequest(
    HttpResponse response,
    String error, {
    String? message,
  }) {
    return _sendJson(response, HttpStatus.badRequest, {
      'error': error,
      'message': ?message,
    });
  }

  // ============================================================
  // NOT FOUND
  // ============================================================

  Future<void> _sendNotFound(HttpResponse response) async {
    response.statusCode = HttpStatus.notFound;

    response.headers.contentType = ContentType.json;

    response.write(jsonEncode({'error': 'Not Found'}));

    await response.close();
  }

  // ============================================================
  // SEND JSON
  // ============================================================

  Future<void> _sendJson(
    HttpResponse response,
    int statusCode,
    Map<String, dynamic> data,
  ) {
    response.statusCode = statusCode;

    response.headers.contentType = ContentType.json;

    response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');

    response.write(jsonEncode(data));

    return response.close();
  }
}
