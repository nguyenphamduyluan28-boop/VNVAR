import 'dart:async';
import 'dart:developer' as developer;
import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_video/return_code.dart';
import 'package:ffmpeg_kit_flutter_new_video/statistics.dart';

enum RtspPublishState {
  idle,
  connecting,
  publishing,
  reconnecting,
  error,
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

  static const int maxReconnectAttempts = 8;
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

  void _setState(RtspPublishState newState) {
    if (_state == newState) return;
    _state = newState;
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
      _currentError = 'Chưa nhập URL đích (RTSP/RTMP).';
      _setState(RtspPublishState.error);
      return;
    }

    final lower = _targetUrl!.toLowerCase();
    if (!lower.startsWith('rtsp://') &&
        !lower.startsWith('rtsps://') &&
        !lower.startsWith('rtmp://') &&
        !lower.startsWith('rtmps://')) {
      _currentError = 'URL không đúng định dạng rtsp:// hoặc rtmp://';
      _setState(RtspPublishState.error);
      return;
    }

    _setState(RtspPublishState.connecting);
    await _executePublish();
  }

  Future<void> _executePublish() async {
    await _cancelActiveSession();

    final isRtmp = _targetUrl!.toLowerCase().startsWith('rtmp://') ||
        _targetUrl!.toLowerCase().startsWith('rtmps://');

    // Build optimized realtime low-latency stream arguments
    final args = <String>[
      '-nostdin',
      '-thread_queue_size',
      '2048',
      '-fflags',
      '+genpts+nobuffer+discardcorrupt',
      '-flags',
      'low_delay',
      '-correct_ts_overflow',
      '1',
      '-rtsp_transport',
      'tcp',
      '-buffer_size',
      '2048000',
      '-i',
      _localRtspUrl!,
      '-map',
      '0:v:0',
      '-c:v',
      'copy',
      if (!isRtmp) ...[
        '-bsf:v',
        'dump_extra=freq=keyframe',
      ],
      '-map',
      '0:a?',
      '-c:a',
      'aac',
      '-b:a',
      '96k',
      '-ar',
      '48000',
      '-af',
      'aresample=async=1000:min_hard_comp=0.100000:first_pts=0',
      '-max_muxing_queue_size',
      '4096',
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
      ] else ...[
        '-f',
        'rtsp',
        '-rtsp_transport',
        'tcp',
        '-rtsp_flags',
        'prefer_tcp',
      ],
      _targetUrl!,
    ];

    developer.log(
      '[RTSP_PUSH] Starting FFmpeg push: ${args.join(" ")}',
      name: 'RtspPublisherService',
    );

    try {
      final session = await FFmpegKit.executeWithArgumentsAsync(
        args,
        (completedSession) async {
          final returnCode = await completedSession.getReturnCode();
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

          if (!isSuccess) {
            final output = await completedSession.getOutput();
            final failureReason = _extractFailureReason(output);
            developer.log(
              '[RTSP_PUSH] Failure reason: $failureReason',
              name: 'RtspPublisherService',
            );
            _scheduleReconnect(failureReason);
          }
        },
        (log) {
          final message = log.getMessage();
          // Detect active streaming
          if (message.contains('Output #0') ||
              message.contains('frame=') ||
              message.contains('bitrate=')) {
            if (_state != RtspPublishState.publishing) {
              _retryAttempt = 0;
              _reconnectTimer?.cancel();
              _currentError = null;
              _setState(RtspPublishState.publishing);
              developer.log(
                '[RTSP_PUSH] Stream is now LIVE on $_targetUrl',
                name: 'RtspPublisherService',
              );
            }
          }
        },
        (Statistics stats) {
          _currentFps = stats.getVideoFps();
          _currentBitrateKbps = stats.getBitrate();
          if (!_stateController.isClosed && _state == RtspPublishState.publishing) {
            _stateController.add(_state);
          }
        },
      );

      _currentSession = session;
    } catch (e) {
      final err = 'Không thể khởi động lệnh đẩy luồng: $e';
      _currentError = err;
      developer.log('[RTSP_PUSH] Exception: $err', name: 'RtspPublisherService');
      _scheduleReconnect(err);
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

  void _scheduleReconnect(String reason) {
    if (_intentionalStop) return;

    _currentError = reason;
    if (_retryAttempt >= maxReconnectAttempts) {
      _currentError =
          'Không thể kết nối lại sau $maxReconnectAttempts lần thử: $reason';
      _setState(RtspPublishState.error);
      return;
    }

    _setState(RtspPublishState.reconnecting);
    final delaySeconds = _backoffDelaysSeconds[
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

  Future<void> stopPublish() async {
    _intentionalStop = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _retryAttempt = 0;
    await _cancelActiveSession();
    _setState(RtspPublishState.idle);
  }

  /// Gracefully stops active stream before camera hardware resets to avoid broken frames
  Future<void> prepareForReconfiguration() async {
    if (!isLive && _state != RtspPublishState.connecting) return;
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

    developer.log(
      '[RTSP_PUSH] Restarting publish session due to camera reconfiguration...',
      name: 'RtspPublisherService',
    );
    _intentionalStop = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _retryAttempt = 0;
    await _cancelActiveSession();
    _setState(RtspPublishState.connecting);
    // Wait for the local RTSP server to stabilize with the new resolution and allow remote server to close old connection
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    await _executePublish();
  }

  Future<void> _cancelActiveSession() async {
    final session = _currentSession;
    _currentSession = null;
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
    _reconnectTimer?.cancel();
    _stopDurationTimer();
    _cancelActiveSession();
    _stateController.close();
  }
}
