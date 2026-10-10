import 'dart:async';
import 'dart:developer' as developer;
import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_video/return_code.dart';
import 'package:ffmpeg_kit_flutter_new_video/statistics.dart';

import 'audio_cleanup.dart';
import 'cellular_uplink_service.dart';

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

/// Lỗi relay có thể do đường mạng (timeout, từ chối kết nối, DNS…) hay không.
/// Server từ chối xác thực hoặc không có luồng (401/403/404) thì đổi Wi-Fi ↔
/// 4G/5G cũng không giúp được.
bool isRouteRelatedRelayFailure(String? output) {
  if (output == null || output.isEmpty) return true;
  const serverRejections = [
    '401',
    'Unauthorized',
    '403',
    'Forbidden',
    '404',
    'Not Found',
    'Stream not found',
    'NetStream.Publish.BadName',
  ];
  return !serverRejections.any(output.contains);
}

class RtspPublisherService {
  RtspPublishState _state = RtspPublishState.idle;
  final StreamController<RtspPublishState> _stateController =
      StreamController<RtspPublishState>.broadcast();

  FFmpegSession? _currentSession;
  String? _targetUrl;
  String? _localRtspUrl;
  String? _currentError;

  DateTime? _connectedAt;
  Duration _liveDuration = Duration.zero;
  Timer? _durationTimer;
  Timer? _reconnectTimer;
  int _retryAttempt = 0;
  bool _intentionalStop = false;
  double _currentFps = 0;
  double _currentBitrateKbps = 0;

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
  String? get currentError => _currentError;
  String? get targetUrl => _targetUrl;
  double get currentFps => _currentFps;
  double get currentBitrateKbps => _currentBitrateKbps;
  StreamNetworkQuality get networkQuality => _networkQuality;

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

  void _applyTargetBitrate() {
    final callback = onTargetBitrateChanged;
    if (callback == null) return;
    final bps = _bitrate.targetBps;
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
      _liveDuration = Duration.zero;
    }
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  void _startDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_connectedAt != null && !_stateController.isClosed) {
        _liveDuration = DateTime.now().difference(_connectedAt!);
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
    _targetUrl = targetUrl.trim();
    _localRtspUrl = (localRtspUrl?.trim().isNotEmpty ?? false)
        ? localRtspUrl!.trim()
        : 'rtsp://127.0.0.1:8554/camera';
    _currentError = null;

    if (_targetUrl == null || _targetUrl!.isEmpty) {
      _intentionalStop = true; // Cấu hình sai: không tự phát lại.
      _currentError = 'Chưa nhập URL đích (RTSP/RTMP).';
      _setState(RtspPublishState.error);
      return;
    }

    final lower = _targetUrl!.toLowerCase();
    if (!lower.startsWith('rtsp://') &&
        !lower.startsWith('rtsps://') &&
        !lower.startsWith('rtmp://') &&
        !lower.startsWith('rtmps://')) {
      _intentionalStop = true; // Cấu hình sai: không tự phát lại.
      _currentError = 'URL không đúng định dạng rtsp:// hoặc rtmp://';
      _setState(RtspPublishState.error);
      return;
    }

    _setState(RtspPublishState.connecting);
    await _executePublish();
  }

  Future<void> _executePublish() async {
    await _cancelActiveSession();
    final generation = ++_sessionGeneration;
    _resetNetworkHealth();
    _currentSpeed = 0;
    _bitrate.beginSession(DateTime.now());
    // Phiên mới (kết nối lại) giữ mức bitrate đã thích ứng; áp lại cho chắc
    // encoder đang đúng mức đó.
    _applyTargetBitrate();
    bool isCurrent() => generation == _sessionGeneration;

    final isRtmp = _targetUrl!.toLowerCase().startsWith('rtmp://') ||
        _targetUrl!.toLowerCase().startsWith('rtmps://');

    var outputUrl = _targetUrl!;
    final outputRouteArgs = <String>[];
    final wasCellular = _cellularActive;
    _cellularActive = false;
    if (_preferCellular) {
      final endpoint = cellularTunnelEndpoint(outputUrl);
      final localPort = endpoint == null
          ? null
          : await CellularUplinkService.openTunnel(endpoint);
      if (!isCurrent()) return;
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
    // Build optimized realtime low-latency stream arguments
    final args = <String>[
      '-nostdin',
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
      _localRtspUrl!,
      '-map',
      '0:v:0',
      '-c:v',
      'copy',
      // Chèn SPS/PPS vào mỗi Keyframe để server Sporto và decoder người xem
      // cập nhật độ phân giải mới mượt mà, không bị nghẽn buffer hay lỗi phân giải.
      '-bsf:v',
      'dump_extra=freq=keyframe',
      '-map',
      '0:a?',
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
      '[RTSP_PUSH] Starting FFmpeg push to $_targetUrl',
      name: 'RtspPublisherService',
    );

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
          final failureReason = isSuccess
              ? 'Nguồn camera cục bộ đã đóng; đang kết nối lại.'
              : _extractFailureReason(output);
          developer.log(
            '[RTSP_PUSH] Session ended unexpectedly: $failureReason',
            name: 'RtspPublisherService',
          );
          _currentSession = null;
          _scheduleReconnect(
            failureReason,
            routeRelated: isSuccess || isRouteRelatedRelayFailure(output),
          );
        },
        (log) {
          if (!isCurrent()) return;
          final message = log.getMessage();
          // Detect active streaming
          if (message.contains('Output #0') ||
              message.contains('frame=') ||
              message.contains('bitrate=')) {
            if (_state != RtspPublishState.publishing) {
              _retryAttempt = 0;
              _routeFailures = 0;
              _reconnectTimer?.cancel();
              _currentError = null;
              _setState(RtspPublishState.publishing);
              developer.log(
                '[RTSP_PUSH] Stream is now LIVE on $_targetUrl '
                '(${_cellularActive ? '4G/5G fallback' : 'default network'})',
                name: 'RtspPublisherService',
              );
            }
          }
        },
        (Statistics stats) {
          if (!isCurrent()) return;
          _currentFps = stats.getVideoFps();
          _currentBitrateKbps = stats.getBitrate();
          _currentSpeed = stats.getSpeed();
          _evaluateNetworkHealth(_currentFps, _currentBitrateKbps);
          if (_state == RtspPublishState.publishing) {
            final next = _bitrate.observe(
              speed: _currentSpeed,
              fps: _currentFps,
              expectedFps: _expectedFps,
              now: DateTime.now(),
            );
            if (next != null) {
              developer.log(
                '[RTSP_PUSH] Upload speed ${_currentSpeed.toStringAsFixed(2)}x, '
                'FPS ${_currentFps.toStringAsFixed(1)}; bitrate -> ${next ~/ 1000} kbps',
                name: 'RtspPublisherService',
              );
              _applyTargetBitrate();
            }
          }
          if (!_stateController.isClosed && _state == RtspPublishState.publishing) {
            _stateController.add(_state);
          }
        },
      );

      if (isCurrent()) {
        _currentSession = session;
      } else {
        // Phiên đã bị thay thế trong lúc khởi động: hủy để không chạy song song.
        unawaited(session.cancel());
      }
    } catch (e) {
      if (!isCurrent()) return;
      final err = 'Không thể khởi động lệnh đẩy luồng: $e';
      _currentError = err;
      developer.log('[RTSP_PUSH] Exception: $err', name: 'RtspPublisherService');
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

  String _extractFailureReason(String? output) {
    if (output == null || output.isEmpty) {
      return 'Mất kết nối tới server phát (Server ngắt kết nối).';
    }
    if (output.contains('Connection refused')) {
      return 'Không thể kết nối (Connection refused). Vui lòng kiểm tra IP/Domain và cổng 18554.';
    }
    if (output.contains('401') || output.contains('Unauthorized')) {
      return 'Server từ chối (401 Unauthorized). Stream Key không chính xác.';
    }
    if (output.contains('404') || output.contains('Not Found')) {
      return 'Server không tìm thấy luồng (404 Not Found). Kiểm tra App Name hoặc Stream Name.';
    }
    if (output.contains('Immediate exit requested')) {
      return 'Luồng bị dừng.';
    }
    // Return last line of error output
    final lines = output
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('ffmpeg version'))
        .toList();
    if (lines.isNotEmpty) {
      return lines.last;
    }
    return 'Lỗi truyền luồng RTSP.';
  }

  void _scheduleReconnect(String reason, {bool routeRelated = true}) {
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

    _currentError = reason;
    // Hết các lần thử nhanh thì vẫn tiếp tục thử thưa hơn: mạng di động có thể
    // mất vài phút mới có lại. Trước đây livestream dừng hẳn sau ~95 giây.
    final slowRetry = _retryAttempt >= maxReconnectAttempts;
    if (slowRetry) {
      _currentError =
          'Mất kết nối tới server phát; tự thử lại mỗi $slowRetrySeconds giây: $reason';
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
  }

  void dispose() {
    _intentionalStop = true;
    _routeProbeTimer?.cancel();
    _reconnectTimer?.cancel();
    _stopDurationTimer();
    _cancelActiveSession();
    _stateController.close();
  }
}
