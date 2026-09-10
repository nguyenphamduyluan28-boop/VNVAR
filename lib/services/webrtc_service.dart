import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/camera_resolution_profile.dart';

Map<String, dynamic> buildCameraVideoConstraints({
  required bool isEmulator,
  required bool isIos,
  required String facingMode,
  required String? preferredDeviceId,
  required CameraResolutionProfile profile,
}) {
  if (isEmulator) {
    return <String, dynamic>{
      'facingMode': facingMode,
      'width': {'min': 320, 'ideal': 640, 'max': 640},
      'height': {'min': 240, 'ideal': 480, 'max': 480},
      'frameRate': {'ideal': 15, 'max': 20},
    };
  }
  if (isIos) {
    // flutter_webrtc 1.6.0 only reads numeric constraints at the top level;
    // numeric values nested under `ideal` are ignored on Darwin and become
    // 0x0@0fps, which then falls back to 640x480 with an invalid frame rate.
    return <String, dynamic>{
      'facingMode': facingMode,
      'deviceId': ?preferredDeviceId,
      'width': profile.width,
      'height': profile.height,
      'frameRate': profile.fps,
    };
  }
  return <String, dynamic>{
    'facingMode': facingMode,
    'deviceId': ?preferredDeviceId,
    'width': {'ideal': profile.width, 'max': profile.width},
    'height': {'ideal': profile.height, 'max': profile.height},
    'frameRate': {'ideal': profile.fps, 'max': profile.fps},
    'focusMode': 'continuous',
  };
}

class WebRtcService {
  static const MethodChannel _platformChannel = MethodChannel(
    'vnvar/camera_station_service',
  );

  void Function(String reason)? onCameraFailure;
  void Function()? onRtspStateChanged;
  void Function(double actualFps, int requestedFps)? onIosCapturePerformance;
  Future<void> Function()? onAndroidTaskRemoved;

  WebRtcService() {
    if (Platform.isAndroid || Platform.isIOS) {
      _platformChannel.setMethodCallHandler(_handlePlatformCallback);
    }
  }

  // ============================================================
  // LOCAL CAMERA
  // ============================================================

  MediaStream? _localStream;

  // ============================================================
  // PEER CONNECTION
  // ============================================================

  static const int maximumActivePeers = 4;
  static const Duration _disconnectedPeerGrace = Duration(seconds: 10);
  final Map<String, RTCPeerConnection> _peerConnections =
      <String, RTCPeerConnection>{};
  final Map<String, Future<void>> _disposePeerOperations =
      <String, Future<void>>{};
  final Map<String, Timer> _peerDisconnectTimers = <String, Timer>{};
  final Map<String, List<RTCIceCandidate>> _pendingIceCandidates =
      <String, List<RTCIceCandidate>>{};
  final Set<String> _remoteDescriptionReady = <String>{};
  String? _latestPeerId;

  // ============================================================
  // LOCAL PREVIEW
  // ============================================================

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();

  // ============================================================
  // STATE
  // ============================================================

  bool _rendererInitialized = false;
  bool _cameraInitialized = false;
  bool _microphoneEnabled = true;
  bool _iosMicrophonePermissionGranted = false;
  Timer? _muteFailureTimer;
  Timer? _endedFailureTimer;
  Timer? _audioFailureTimer;
  Timer? _firstFrameFailureTimer;
  Completer<void>? _firstFrameCompleter;
  Timer? _rtspRetryTimer;
  int _rtspRetryAttempt = 0;
  bool _rtspStarting = false;
  bool _receivedFirstFrame = false;
  int _cameraLifecycleGeneration = 0;
  String? _currentFacingMode;
  final Map<String, String> _preferredCameraDeviceIds = <String, String>{};
  final Map<String, List<CameraResolutionProfile>> _verifiedResolutionProfiles =
      <String, List<CameraResolutionProfile>>{};
  final Map<String, String> _resolutionProfileDeviceIds = <String, String>{};
  bool? _isEmulator;
  double _cameraZoom = 1;
  double _minimumCameraZoom = 1;
  double _maximumCameraZoom = 1;
  bool _cameraZoomSupported = false;

  double get cameraZoom => _cameraZoom;
  double get minimumCameraZoom => _minimumCameraZoom;
  double get maximumCameraZoom => _maximumCameraZoom;
  bool get cameraZoomSupported => _cameraZoomSupported;

  Future<void> refreshCameraZoom() async {
    final track = localVideoTrack;
    if (track == null || (!Platform.isAndroid && !Platform.isIOS)) return;
    final result = await _platformChannel
        .invokeMapMethod<String, dynamic>('getCameraZoom', {
          'trackId': track.id,
          'facing': currentFacingMode,
          'deviceId': _preferredCameraDeviceIds[currentFacingMode],
        });
    _cameraZoomSupported = result?['supported'] == true;
    _minimumCameraZoom = (result?['min'] as num?)?.toDouble() ?? 1;
    _maximumCameraZoom = (result?['max'] as num?)?.toDouble() ?? 1;
    _cameraZoom = (result?['current'] as num?)?.toDouble() ?? 1;
  }

  Future<void> setCameraZoom(double value) async {
    final track = localVideoTrack;
    if (track == null || !_cameraZoomSupported) return;
    final target = value
        .clamp(_minimumCameraZoom, _maximumCameraZoom)
        .toDouble();
    final result = await _platformChannel
        .invokeMapMethod<String, dynamic>('setCameraZoom', {
          'trackId': track.id,
          'facing': currentFacingMode,
          'deviceId': _preferredCameraDeviceIds[currentFacingMode],
          'zoom': target,
        });
    _cameraZoom =
        (result?['current'] as num?)?.toDouble() ??
        (result?['zoom'] as num?)?.toDouble() ??
        target;
  }

  bool _rtspRunning = false;
  bool _rtspAudio = false;
  bool _rtspServerStarted = false;
  String? _rtspError;
  CameraResolutionProfile _resolutionProfile =
      CameraResolutionProfile.fullHd1080;

  // ============================================================
  // GETTERS
  // ============================================================

  bool get cameraInitialized => _cameraInitialized;

  bool get microphoneEnabled => localAudioTrack?.enabled ?? _microphoneEnabled;

  bool get microphoneAvailable =>
      Platform.isAndroid ||
      (Platform.isIOS && _iosMicrophonePermissionGranted) ||
      localAudioTrack != null;

  String? get rtspError => _rtspError;

  bool get rtspRunning => _rtspRunning;
  bool get rtspAudio => _rtspAudio;

  bool get rtspSupported => Platform.isAndroid || Platform.isIOS;

  Future<void> _handlePlatformCallback(MethodCall call) async {
    if (call.method == 'onAndroidTaskRemoved') {
      developer.log(
        '[SERVICE] Android task removed; stopping station cleanly',
        name: 'WebRtcService',
      );
      await onAndroidTaskRemoved?.call();
      return;
    }
    if (!_rtspServerStarted) return;
    switch (call.method) {
      case 'onRtspEncoderConfigured':
        _rtspRetryTimer?.cancel();
        _rtspRetryTimer = null;
        _rtspRetryAttempt = 0;
        _rtspRunning = true;
        _rtspError = null;
        developer.log(
          '[RTSP] H.264 encoder ready at rtsp://0.0.0.0:8554/camera',
          name: 'WebRtcService',
        );
        onRtspStateChanged?.call();
      case 'onRtspEncoderError':
        _rtspRunning = false;
        _rtspAudio = false;
        final arguments = call.arguments;
        final message = arguments is Map ? arguments['error'] : null;
        _rtspError = message is String && message.trim().isNotEmpty
            ? message
            : 'Không thể khởi tạo H.264 encoder.';
        developer.log(
          '[RTSP] H.264 encoder failed: $_rtspError',
          name: 'WebRtcService',
        );
        onRtspStateChanged?.call();
        _scheduleRtspRetry();
      case 'onIosCapturePerformance':
        final arguments = call.arguments;
        if (arguments is Map) {
          final actualFps = (arguments['actualFps'] as num?)?.toDouble();
          final requestedFps = (arguments['requestedFps'] as num?)?.toInt();
          if (actualFps != null && requestedFps != null) {
            onIosCapturePerformance?.call(actualFps, requestedFps);
          }
        }
    }
  }

  CameraResolutionProfile get resolutionProfile => _resolutionProfile;

  String get currentFacingMode => _currentFacingMode ?? 'environment';

  MediaStream? get localStream => _localStream;

  RTCPeerConnection? get peerConnection {
    final latest = _latestPeerId;
    if (latest != null) return _peerConnections[latest];
    return _peerConnections.isEmpty ? null : _peerConnections.values.first;
  }

  int get activePeerCount => _peerConnections.length;
  bool hasPeer(String peerId) => _peerConnections.containsKey(peerId);

  /// Quan trọng cho RecordingService.
  ///
  /// RecordingService sẽ lấy chính video track này
  /// để ghi video mà không mở Camera thứ hai.
  MediaStreamTrack? get localVideoTrack {
    final stream = _localStream;

    if (stream == null) {
      return null;
    }

    final tracks = stream.getVideoTracks();

    if (tracks.isEmpty) {
      return null;
    }

    return tracks.first;
  }

  MediaStreamTrack? get localAudioTrack {
    final tracks = _localStream?.getAudioTracks();
    return tracks == null || tracks.isEmpty ? null : tracks.first;
  }

  Future<void> ensureMicrophoneEnabled() async {
    _microphoneEnabled = true;
    final track = localAudioTrack;
    if (track == null) {
      if (Platform.isAndroid) {
        developer.log(
          '[MICROPHONE] Enabled for native recorder',
          name: 'WebRtcService',
        );
        return;
      }
      if (Platform.isIOS) {
        developer.log(
          microphoneAvailable
              ? '[MICROPHONE] Enabled for native iOS recorder'
              : '[MICROPHONE] Permission denied; continuing video-only on iOS',
          name: 'WebRtcService',
        );
        return;
      }
      throw StateError('Micro chưa sẵn sàng.');
    }
    track.enabled = true;
    developer.log(
      '[MICROPHONE] Enabled (required by Camera Station)',
      name: 'WebRtcService',
    );
  }

  void setResolutionProfile(CameraResolutionProfile profile) {
    _resolutionProfile = profile;
  }

  Future<List<CameraResolutionProfile>> getSupportedResolutionProfiles({
    String facingMode = 'environment',
    bool fallbackWhenUnavailable = true,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return const [
        CameraResolutionProfile.hd720,
        CameraResolutionProfile.fullHd1080,
      ];
    }
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final result = await _platformChannel.invokeListMethod<Object?>(
          'getCameraResolutionProfiles',
          {'facing': facingMode},
        );
        final supported = <CameraResolutionProfile>[];
        String? detectedDeviceId;
        for (final item in result ?? const []) {
          if (item is! Map) continue;
          final deviceId = item['deviceId'];
          if (deviceId is String && deviceId.isNotEmpty) {
            detectedDeviceId ??= deviceId;
          }
          final profile = CameraResolutionProfile.fromId(item['id'] as String?);
          final maxFps = item['maxFps'];
          if (profile != null && maxFps is num && maxFps.toInt() > 0) {
            final detectedFps = maxFps.toInt();
            final platformFps =
                Platform.isAndroid &&
                    profile.preset == CameraResolutionPreset.ultraHd4k
                ? math.min(detectedFps, 20)
                : detectedFps;
            supported.add(profile.withFps(platformFps));
          }
        }
        if (supported.isNotEmpty && detectedDeviceId != null) {
          supported.sort(
            (left, right) => left.preset.index.compareTo(right.preset.index),
          );
          _preferredCameraDeviceIds[facingMode] = detectedDeviceId;
          _resolutionProfileDeviceIds[facingMode] = detectedDeviceId;
          _verifiedResolutionProfiles[facingMode] = List.unmodifiable(
            supported,
          );
          developer.log(
            '[CAMERA] Verified ${supported.map((item) => item.shortLabel).join(', ')} '
            'for $facingMode camera $detectedDeviceId',
            name: 'WebRtcService',
          );
          return List.unmodifiable(supported);
        }
        lastError = StateError(
          'Camera $facingMode returned no usable WebRTC profile.',
        );
      } catch (error) {
        lastError = error;
      }
      if (attempt < 2) {
        await Future<void>.delayed(Duration(milliseconds: 120 * (attempt + 1)));
      }
    }
    final cached = _verifiedResolutionProfiles[facingMode];
    if (cached != null && cached.isNotEmpty) {
      developer.log(
        '[CAMERA] Capability scan failed; using verified cache for '
        '$facingMode camera ${_resolutionProfileDeviceIds[facingMode]}: '
        '$lastError',
        name: 'WebRtcService',
      );
      return List.unmodifiable(cached);
    }
    developer.log(
      '[CAMERA] Cannot detect resolution profiles after 3 attempts: $lastError',
      name: 'WebRtcService',
    );
    if (!fallbackWhenUnavailable) return const [];
    return const [CameraResolutionProfile.hd720];
  }

  // ============================================================
  // ICE CONFIG
  // ============================================================

  Map<String, dynamic> get _rtcConfiguration {
    return {
      'iceServers': [
        {
          'urls': [
            'stun:stun.l.google.com:19302',
            'stun:stun1.l.google.com:19302',
          ],
        },
      ],
    };
  }

  // ============================================================
  // INITIALIZE RENDERER
  // ============================================================

  Future<void> initializeRenderer() async {
    if (_rendererInitialized) {
      return;
    }

    await localRenderer.initialize();

    _rendererInitialized = true;

    localRenderer.onFirstFrameRendered = () {
      _receivedFirstFrame = true;
      final completer = _firstFrameCompleter;
      if (completer != null && !completer.isCompleted) completer.complete();
      _firstFrameFailureTimer?.cancel();
      _firstFrameFailureTimer = null;
      developer.log(
        'Station local first frame rendered',
        name: 'WebRtcService',
      );
    };

    developer.log('Station renderer initialized', name: 'WebRtcService');
  }

  // ============================================================
  // INITIALIZE CAMERA
  // ============================================================

  Future<void> initializeCamera({String? facingMode}) async {
    // Camera đã mở rồi thì không mở lại.
    if (_cameraInitialized && _localStream != null && localVideoTrack != null) {
      return;
    }

    final cameraGeneration = ++_cameraLifecycleGeneration;

    await initializeRenderer();
    if (cameraGeneration != _cameraLifecycleGeneration) return;

    developer.log('Opening Station camera...', name: 'WebRtcService');

    // Nếu có stream cũ nhưng state không hợp lệ,
    // dispose trước khi mở lại.
    final oldStream = _localStream;

    _localStream = null;
    _cameraInitialized = false;

    if (oldStream != null) {
      try {
        for (final track in oldStream.getTracks()) {
          await track.stop();
        }

        await oldStream.dispose();
      } catch (e, stackTrace) {
        developer.log(
          'Failed to dispose old camera stream',
          error: e,
          stackTrace: stackTrace,
          name: 'WebRtcService',
        );
      }
    }

    // ==========================================================
    // OPEN CAMERA
    // ==========================================================

    _isEmulator ??= await _detectEmulator();
    if (cameraGeneration != _cameraLifecycleGeneration) return;
    final selectedFacingMode = facingMode ?? currentFacingMode;
    final preferredDeviceId = _preferredCameraDeviceIds[selectedFacingMode];
    developer.log(
      '[CAMERA] Opening facingMode=$selectedFacingMode',
      name: 'WebRtcService',
    );

    final videoConstraints = buildCameraVideoConstraints(
      isEmulator: _isEmulator == true,
      isIos: Platform.isIOS,
      facingMode: selectedFacingMode,
      preferredDeviceId: preferredDeviceId,
      profile: _resolutionProfile,
    );

    final captureAudio = await _shouldCaptureMicrophone();
    final streamFuture = navigator.mediaDevices.getUserMedia({
      // Android microphone is recorded by NativeAudioSegmentRecorder. Keeping
      // a WebRTC AudioRecord open at the same time can make the native capture
      // silent or unavailable on Unisoc devices.
      'audio': captureAudio,
      'video': videoConstraints,
    });

    late final MediaStream stream;
    try {
      stream = await streamFuture.timeout(const Duration(seconds: 12));
    } on TimeoutException {
      // getUserMedia không thể bị hủy. Nếu Android trả stream sau timeout,
      // đóng stream đó ngay để camera không tiếp tục chạy ẩn.
      unawaited(
        streamFuture.then<void>(
          _disposeMediaStream,
          onError: (Object _, StackTrace _) {},
        ),
      );
      throw TimeoutException(
        'Camera $selectedFacingMode không trả dữ liệu sau 12 giây.',
      );
    }

    if (cameraGeneration != _cameraLifecycleGeneration) {
      await _disposeMediaStream(stream);
      return;
    }

    // ==========================================================
    // SAVE STREAM
    // ==========================================================

    _localStream = stream;

    // ==========================================================
    // VALIDATE TRACK
    // ==========================================================

    final videoTracks = stream.getVideoTracks();

    if (videoTracks.isEmpty) {
      await stream.dispose();

      _localStream = null;

      throw Exception('Camera Station không tạo được video track.');
    }

    final videoTrack = videoTracks.first;

    if (!videoTrack.enabled) {
      videoTrack.enabled = true;
    }

    // Bind only after validating the track, then keep initialization pending
    // until the new capture source has produced a real frame.
    final firstFrame = _bindRendererAndWaitForFirstFrame(stream);
    await _configureNaturalCameraMetering(videoTrack);

    try {
      await firstFrame;
    } on TimeoutException {
      if (_localStream == stream) {
        localRenderer.srcObject = null;
        _localStream = null;
      }
      await _disposeMediaStream(stream);
      throw TimeoutException(
        'Camera $selectedFacingMode không phát frame đầu tiên sau 6 giây.',
      );
    }

    final audioTracks = stream.getAudioTracks();
    for (final track in audioTracks) {
      track.enabled = _microphoneEnabled;
      if (Platform.isIOS) {
        track.onEnded = () {
          developer.log(
            '[MICROPHONE] iOS audio track ended',
            name: 'WebRtcService',
          );
          onCameraFailure?.call('ios_audio_track_ended');
        };
        track.onMute = () {
          _audioFailureTimer?.cancel();
          _audioFailureTimer = Timer(const Duration(seconds: 8), () {
            onCameraFailure?.call('ios_audio_track_muted');
          });
        };
        track.onUnMute = () {
          _audioFailureTimer?.cancel();
          _audioFailureTimer = null;
        };
      }
    }

    videoTrack.onEnded = () {
      developer.log(
        '[CAMERA] Video track ended; waiting for transition confirmation',
        name: 'WebRtcService',
      );
      _endedFailureTimer?.cancel();
      final observedGeneration = cameraGeneration;
      _endedFailureTimer = Timer(const Duration(seconds: 8), () {
        if (observedGeneration != _cameraLifecycleGeneration ||
            _localStream != stream) {
          return;
        }
        _cameraInitialized = false;
        onCameraFailure?.call('video_track_ended');
      });
    };

    videoTrack.onMute = () {
      developer.log('[CAMERA] Video track muted', name: 'WebRtcService');
      _muteFailureTimer?.cancel();
      _muteFailureTimer = Timer(const Duration(seconds: 8), () {
        onCameraFailure?.call('video_track_muted');
      });
    };

    videoTrack.onUnMute = () {
      _endedFailureTimer?.cancel();
      _endedFailureTimer = null;
      _muteFailureTimer?.cancel();
      _muteFailureTimer = null;
      developer.log('[CAMERA] Video track unmuted', name: 'WebRtcService');
    };

    _cameraInitialized = true;
    _currentFacingMode = selectedFacingMode;

    await _startRtsp(videoTrack);
    try {
      await refreshCameraZoom();
    } catch (error) {
      developer.log('[CAMERA] Zoom unavailable: $error', name: 'WebRtcService');
    }

    if (cameraGeneration != _cameraLifecycleGeneration) {
      await disposeCamera();
      return;
    }

    developer.log('[CAMERA] Station camera ready', name: 'WebRtcService');

    developer.log(
      'Station video tracks: '
      '${videoTracks.length}',
      name: 'WebRtcService',
    );

    for (final track in videoTracks) {
      developer.log(
        'Station video track: '
        '${track.id}, '
        'enabled=${track.enabled}',
        name: 'WebRtcService',
      );
    }
  }

  Future<bool> _shouldCaptureMicrophone() async {
    if (Platform.isAndroid) return false;
    if (!Platform.isIOS) return true;
    try {
      final granted =
          await _platformChannel.invokeMethod<bool>(
            'requestMicrophonePermission',
          ) ??
          false;
      _iosMicrophonePermissionGranted = granted;
      if (!granted) {
        developer.log(
          '[MICROPHONE] iOS permission denied; opening camera video-only',
          name: 'WebRtcService',
        );
      }
      // AVAudioRecorder owns microphone capture on iOS. A local WebRTC audio
      // track does not deliver captured PCM to RTCAudioRenderer, and keeping
      // WebRTC's voice-processing audio unit active starves the native writer.
      return false;
    } on PlatformException catch (error, stackTrace) {
      developer.log(
        '[MICROPHONE] Unable to read iOS permission; using video-only',
        error: error,
        stackTrace: stackTrace,
        name: 'WebRtcService',
      );
      _iosMicrophonePermissionGranted = false;
      return false;
    }
  }

  Future<void> _configureNaturalCameraMetering(MediaStreamTrack track) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    // flutter_webrtc 1.6.0 implements Android's setExposurePoint by replacing
    // the active Camera2 repeating request with a new, minimally configured
    // TEMPLATE_RECORD request. That drops the capturer's FPS/AE configuration
    // and can make indoor video darker. Keep Android's original repeating
    // request intact; selecting the 1x sensor and capturing at 30 fps already
    // gives its automatic exposure the best input available through WebRTC.
    if (Platform.isAndroid) {
      await _applyAndroidExposureBoost(track);
      return;
    }

    if (Platform.isIOS) {
      try {
        await Helper.setExposureMode(
          track,
          CameraExposureMode.auto,
        ).timeout(const Duration(seconds: 2));
        developer.log(
          '[CAMERA] Continuous auto exposure enabled on iOS',
          name: 'WebRtcService',
        );
      } catch (error) {
        developer.log(
          '[CAMERA] Cannot enable continuous exposure: $error',
          name: 'WebRtcService',
        );
      }
    }

    try {
      // Meter the centre of the court so bright lamps near the frame edges do
      // not cause the players and playing surface to be underexposed.
      await Helper.setExposurePoint(
        track,
        const math.Point<double>(0.5, 0.5),
      ).timeout(const Duration(seconds: 2));
      developer.log(
        '[CAMERA] Centre-weighted auto exposure enabled',
        name: 'WebRtcService',
      );
    } catch (error) {
      developer.log(
        '[CAMERA] Centre-weighted exposure unavailable: $error',
        name: 'WebRtcService',
      );
    }
  }

  Future<void> _applyAndroidExposureBoost(MediaStreamTrack track) async {
    const targetEv = 1.3;
    const retryDelay = Duration(milliseconds: 300);
    Map<String, dynamic>? lastResult;

    // getUserMedia can return its VideoTrack before Camera2 has published the
    // active capture session. Retry briefly so the setting reaches both the
    // initial lens and every newly opened front/back lens.
    for (var attempt = 1; attempt <= 6; attempt++) {
      try {
        lastResult = await _platformChannel
            .invokeMapMethod<String, dynamic>('setCameraExposureBoost', {
              'trackId': track.id,
              'targetEv': targetEv,
            })
            .timeout(const Duration(seconds: 2));
        if (lastResult?['applied'] == true) {
          developer.log(
            '[CAMERA] Android exposure boost: '
            '${lastResult?['appliedEv']} EV (attempt $attempt)',
            name: 'WebRtcService',
          );
          return;
        }

        final reason = lastResult?['reason'];
        if (reason == 'positive_compensation_unsupported' ||
            reason == 'unsupported_capturer') {
          break;
        }
      } catch (error) {
        lastResult = <String, dynamic>{'reason': error.toString()};
      }

      if (attempt < 6) await Future<void>.delayed(retryDelay);
    }

    developer.log(
      '[CAMERA] Keeping default Android auto-exposure: '
      '${lastResult?['reason'] ?? 'unknown'}',
      name: 'WebRtcService',
    );
  }

  Future<bool> _detectEmulator() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _platformChannel.invokeMethod<bool>('isEmulator') ?? false;
    } catch (error) {
      developer.log(
        '[CAMERA] Cannot detect emulator: $error',
        name: 'WebRtcService',
      );
      return false;
    }
  }

  Future<void> _startRtsp(MediaStreamTrack track) async {
    if (_rtspStarting) return;
    _rtspStarting = true;
    if (!rtspSupported) {
      _rtspRunning = false;
      _rtspError = 'RTSP không được hỗ trợ trên nền tảng này.';
      developer.log(
        '[RTSP] Unsupported on ${Platform.operatingSystem}.',
        name: 'WebRtcService',
      );
      _rtspStarting = false;
      return;
    }
    try {
      _rtspRunning = false;
      _rtspAudio = false;
      _rtspError = null;
      _rtspServerStarted = true;
      _rtspRetryTimer?.cancel();
      final result = await _platformChannel.invokeMethod<Map<Object?, Object?>>(
        'startRtsp',
        {
          'trackId': track.id,
          'audioTrackId': localAudioTrack?.id,
          'port': 8554,
          // RTSP/TCP cannot adapt to congestion like WebRTC. Use the
          // profile's LAN-safe budget while WebRTC keeps its higher ceiling.
          'bitrate': _resolutionProfile.rtspBitrate,
          'fps': _resolutionProfile.fps,
        },
      );
      _rtspAudio = result?['audio'] == true;
      developer.log(
        '[RTSP] Server opened; waiting for H.264 encoder readiness.',
        name: 'WebRtcService',
      );
    } catch (error, stackTrace) {
      // Keep the logical server state so transient encoder/network failures
      // can be retried without requiring the tablet to reconnect manually.
      _rtspServerStarted = true;
      _rtspRunning = false;
      _rtspAudio = false;
      _rtspError = error.toString();
      developer.log(
        '[RTSP] Cannot start server',
        error: error,
        stackTrace: stackTrace,
        name: 'WebRtcService',
      );
      _scheduleRtspRetry();
    } finally {
      _rtspStarting = false;
    }
  }

  Future<void> _stopRtsp() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    if (!_rtspServerStarted) return;
    _rtspRetryTimer?.cancel();
    _rtspRetryTimer = null;
    _rtspRetryAttempt = 0;
    _rtspServerStarted = false;
    _rtspRunning = false;
    _rtspAudio = false;
    try {
      await _platformChannel.invokeMethod<void>('stopRtsp');
    } catch (error) {
      developer.log('[RTSP] Stop failed: $error', name: 'WebRtcService');
    }
  }

  /// Recreates only network-facing transports after Wi-Fi/IP changes.
  /// The shared camera stream remains open, so recording is never finalized
  /// or restarted by this operation.
  Future<void> reconnectNetworkTransports() async {
    await disposeConnection();
    final track = localVideoTrack;
    if (track == null || !_cameraInitialized) return;
    await _stopRtsp();
    await _startRtsp(track);
  }

  void _scheduleRtspRetry() {
    if (!_rtspServerStarted ||
        _localStream == null ||
        _rtspRetryTimer != null) {
      return;
    }
    final track = localVideoTrack;
    if (track == null) return;
    const delays = <Duration>[
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
      Duration(seconds: 20),
    ];
    final delay = delays[math.min(_rtspRetryAttempt, delays.length - 1)];
    _rtspRetryAttempt++;
    developer.log(
      '[RTSP] Retrying encoder in ${delay.inSeconds}s',
      name: 'WebRtcService',
    );
    _rtspRetryTimer = Timer(delay, () async {
      _rtspRetryTimer = null;
      if (!_rtspServerStarted || _localStream == null) return;
      await _startRtsp(track);
      if (!_rtspRunning) _scheduleRtspRetry();
    });
  }

  Future<void> switchCamera() async {
    final track = localVideoTrack;
    if (!_cameraInitialized || track == null) {
      throw StateError('Camera chưa sẵn sàng.');
    }
    final previousFacing = currentFacingMode;
    final targetFacing = previousFacing == 'environment'
        ? 'user'
        : 'environment';
    final switchResult = await Helper.switchCamera(
      track,
    ).timeout(const Duration(seconds: 8));
    // flutter_webrtc's iOS implementation returns `_usingFrontCamera`, not a
    // success flag: true means the new lens is front-facing and false means
    // it is back-facing. Therefore false is the expected result when switching
    // from the selfie camera back to the rear camera. Android uses this value
    // as an actual success flag.
    if (!Platform.isIOS && !switchResult) {
      throw StateError('Thiết bị không có camera khác để chuyển.');
    }
    // Keep the renderer attached to the MediaStream while the native capturer
    // changes lens. Detaching/rebinding the same stream can leave iOS holding
    // its last texture, and onFirstFrameRendered is not guaranteed to fire a
    // second time for that stream. The native switch future is the handoff
    // boundary; a short delay lets the new capture session settle before
    // applying lens-specific controls.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (_localStream == null || localVideoTrack != track) {
      throw StateError('Camera stream không còn tồn tại.');
    }
    await _configureNaturalCameraMetering(track);
    _currentFacingMode = targetFacing;
    await refreshCameraZoom();
    developer.log(
      '[CAMERA] Switched front/back on the current VideoTrack',
      name: 'WebRtcService',
    );
  }

  Future<void> _bindRendererAndWaitForFirstFrame(MediaStream stream) async {
    _receivedFirstFrame = false;
    _firstFrameFailureTimer?.cancel();
    final completer = Completer<void>();
    _firstFrameCompleter = completer;
    localRenderer.srcObject = stream;
    _firstFrameFailureTimer = Timer(const Duration(seconds: 6), () {
      if (_receivedFirstFrame) return;
      if (!completer.isCompleted) {
        completer.completeError(
          _localStream == stream
              ? TimeoutException('Camera did not render a fresh frame.')
              : StateError('Camera stream changed before its first frame.'),
        );
      }
    });
    await completer.future;
  }

  // ============================================================
  // CREATE PEER CONNECTION
  // ============================================================

  Future<RTCPeerConnection> _createPeerConnection(
    String peerId, {
    required int maximumPeers,
  }) async {
    // ==========================================================
    // CAMERA PHẢI SẴN SÀNG
    // ==========================================================

    await initializeCamera();

    // ==========================================================
    // CHỈ ĐÓNG PEER CONNECTION CŨ
    //
    // Không được dispose _localStream ở đây.
    // RecordingService cũng đang dùng video track này.
    // ==========================================================

    await disposePeerConnection(peerId);
    final effectiveMaximum = maximumPeers.clamp(1, maximumActivePeers);
    if (_peerConnections.length >= effectiveMaximum) {
      throw StateError(
        'WEBRTC_PEER_LIMIT: ${_peerConnections.length}/$effectiveMaximum',
      );
    }

    // ==========================================================
    // CREATE NEW PC
    // ==========================================================

    final pc = await createPeerConnection(_rtcConfiguration);

    _peerConnections[peerId] = pc;
    _latestPeerId = peerId;

    developer.log(
      'Station PeerConnection created: $peerId '
      '(${_peerConnections.length}/$effectiveMaximum)',
      name: 'WebRtcService',
    );

    // ==========================================================
    // CONNECTION STATE
    // ==========================================================

    pc.onConnectionState = (state) {
      developer.log(
        'Station connection state [$peerId]: $state',
        name: 'WebRtcService',
      );
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _peerDisconnectTimers.remove(peerId)?.cancel();
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        unawaited(disposePeerConnection(peerId, expectedPeer: pc));
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _scheduleDisconnectedPeerCleanup(peerId, pc);
      }
    };

    // ==========================================================
    // ICE CONNECTION STATE
    // ==========================================================

    pc.onIceConnectionState = (state) {
      developer.log(
        'Station ICE connection state [$peerId]: $state',
        name: 'WebRtcService',
      );
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _peerDisconnectTimers.remove(peerId)?.cancel();
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
        unawaited(disposePeerConnection(peerId, expectedPeer: pc));
      } else if (state ==
          RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        _scheduleDisconnectedPeerCleanup(peerId, pc);
      }
    };

    // ==========================================================
    // SIGNALING STATE
    // ==========================================================

    pc.onSignalingState = (state) {
      developer.log('Station signaling state: $state', name: 'WebRtcService');
    };

    // ==========================================================
    // ICE GATHERING
    // ==========================================================

    pc.onIceGatheringState = (state) {
      developer.log(
        'Station ICE gathering state: $state',
        name: 'WebRtcService',
      );
    };

    // ==========================================================
    // LOCAL ICE
    // ==========================================================

    pc.onIceCandidate = (candidate) {
      final value = candidate.candidate;

      if (value == null || value.isEmpty) {
        return;
      }

      developer.log('Station ICE candidate: $value', name: 'WebRtcService');
    };

    // ==========================================================
    // ADD LOCAL VIDEO TRACK
    // ==========================================================

    final stream = _localStream;

    if (stream == null) {
      throw Exception('Camera Station local stream chưa sẵn sàng.');
    }

    final tracks = stream.getVideoTracks();

    if (tracks.isEmpty) {
      throw Exception('Camera Station không có video track.');
    }

    for (final track in tracks) {
      final sender = await pc.addTrack(track, stream);

      // Prefer fresh frames over preserving every frame. This keeps the live
      // feed responsive when Wi-Fi bandwidth fluctuates instead of allowing a
      // delayed queue to build up.
      try {
        final parameters = sender.parameters;
        parameters.degradationPreference =
            RTCDegradationPreference.MAINTAIN_FRAMERATE;
        for (final encoding in parameters.encodings ?? <RTCRtpEncoding>[]) {
          encoding.minBitrate = 300000;
          encoding.maxBitrate = math.min(_resolutionProfile.bitrate, 2500000);
          encoding.maxFramerate = math.min(_resolutionProfile.fps, 30);
          encoding.priority = RTCPriorityType.high;
          encoding.networkPriority = RTCPriorityType.high;
        }
        await sender.setParameters(parameters);
      } catch (error) {
        developer.log(
          '[WEBRTC] Cannot apply low-latency sender parameters: $error',
          name: 'WebRtcService',
        );
      }

      developer.log(
        'Station added video track: '
        '${track.id}',
        name: 'WebRtcService',
      );
    }

    for (final track in stream.getAudioTracks()) {
      await pc.addTrack(track, stream);
      developer.log(
        'Station added audio track: ${track.id}, enabled=${track.enabled}',
        name: 'WebRtcService',
      );
    }
    return pc;
  }

  // ============================================================
  // HANDLE TABLET OFFER
  // ============================================================

  Future<RTCSessionDescription> handleOffer({
    required String sdp,
    required String type,
    String peerId = 'default',
    int maximumPeers = maximumActivePeers,
  }) async {
    developer.log('Handling Tablet offer: $peerId', name: 'WebRtcService');

    // ==========================================================
    // CREATE PC
    // ==========================================================

    final pc = await _createPeerConnection(peerId, maximumPeers: maximumPeers);

    // ==========================================================
    // REMOTE OFFER
    // ==========================================================

    await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
    _remoteDescriptionReady.add(peerId);
    await _flushPendingIceCandidates(peerId, pc);

    developer.log('Tablet offer applied', name: 'WebRtcService');

    // ==========================================================
    // ICE COMPLETER
    // ==========================================================

    final iceCompleter = Completer<void>();

    // Both devices normally communicate on the same Wi-Fi/LAN. The first
    // host candidate is enough to return a usable SDP answer; waiting for all
    // STUN candidates adds several seconds and leaves the tablet renderer on
    // its empty/blue frame after returning from Check VAR.
    pc.onIceCandidate = (candidate) {
      final value = candidate.candidate;
      if (value == null || value.isEmpty) return;
      developer.log(
        'Station ICE candidate ready: $value',
        name: 'WebRtcService',
      );
      if (!iceCompleter.isCompleted) iceCompleter.complete();
    };

    pc.onIceGatheringState = (state) {
      developer.log('Station ICE gathering: $state', name: 'WebRtcService');

      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !iceCompleter.isCompleted) {
        iceCompleter.complete();
      }
    };

    // ==========================================================
    // CREATE ANSWER
    // ==========================================================

    final answer = await pc.createAnswer();

    await pc.setLocalDescription(answer);

    developer.log('Station answer created', name: 'WebRtcService');

    // ==========================================================
    // WAIT ICE
    // ==========================================================

    try {
      await iceCompleter.future.timeout(const Duration(milliseconds: 1500));
    } catch (_) {
      developer.log(
        'Station ICE first-candidate timeout; returning current SDP',
        name: 'WebRtcService',
      );
    }

    // ==========================================================
    // FINAL ANSWER
    // ==========================================================

    final finalAnswer = await pc.getLocalDescription();

    if (finalAnswer == null ||
        finalAnswer.sdp == null ||
        finalAnswer.type == null) {
      throw Exception('Không lấy được WebRTC answer hoàn chỉnh.');
    }

    developer.log('Station answer + ICE ready', name: 'WebRtcService');

    return finalAnswer;
  }

  // ============================================================
  // REMOTE ICE CANDIDATE
  // ============================================================

  Future<void> addIceCandidate({
    required String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
    String? peerId,
  }) async {
    final targetPeerId =
        peerId ??
        (_peerConnections.length == 1 ? _peerConnections.keys.first : null);
    if (targetPeerId == null) {
      throw StateError('peerId is required when multiple WebRTC peers exist.');
    }
    final ice = RTCIceCandidate(candidate, sdpMid, sdpMLineIndex);
    final pc = _peerConnections[targetPeerId];

    if (pc == null || !_remoteDescriptionReady.contains(targetPeerId)) {
      if (!_pendingIceCandidates.containsKey(targetPeerId) &&
          _pendingIceCandidates.length >= 8) {
        throw StateError('Too many pending WebRTC peer candidates.');
      }
      final pending = _pendingIceCandidates.putIfAbsent(
        targetPeerId,
        () => <RTCIceCandidate>[],
      );
      if (pending.length >= 64) pending.removeAt(0);
      pending.add(ice);
      developer.log(
        'Queued remote ICE candidate [$targetPeerId]',
        name: 'WebRtcService',
      );
      return;
    }

    await pc.addCandidate(ice);

    developer.log(
      'Station remote ICE candidate added [$targetPeerId]',
      name: 'WebRtcService',
    );
  }

  // ============================================================
  // CLOSE PEER CONNECTION ONLY
  //
  // KHÔNG đóng Camera.
  // KHÔNG stop localStream.
  //
  // Điều này quan trọng để:
  //
  // Tablet reconnect WebRTC
  // trong khi RecordingService vẫn ghi video.
  // ============================================================

  Future<void> disposePeerConnection(
    String peerId, {
    RTCPeerConnection? expectedPeer,
  }) {
    final activeDispose = _disposePeerOperations[peerId];
    if (activeDispose != null) return activeDispose;
    final pc = _peerConnections[peerId];
    if (pc == null || (expectedPeer != null && !identical(pc, expectedPeer))) {
      return Future<void>.value();
    }
    _peerConnections.remove(peerId);
    _remoteDescriptionReady.remove(peerId);
    _pendingIceCandidates.remove(peerId);
    _peerDisconnectTimers.remove(peerId)?.cancel();
    if (_latestPeerId == peerId) {
      _latestPeerId = _peerConnections.isEmpty
          ? null
          : _peerConnections.keys.last;
    }
    final operation = _closePeerConnection(pc, peerId);
    _disposePeerOperations[peerId] = operation;
    return operation.whenComplete(() {
      if (identical(_disposePeerOperations[peerId], operation)) {
        _disposePeerOperations.remove(peerId);
      }
    });
  }

  Future<void> disposeConnection([String? peerId]) async {
    if (peerId != null) {
      await disposePeerConnection(peerId);
      return;
    }
    final peerIds = _peerConnections.keys.toList(growable: false);
    await Future.wait(peerIds.map(disposePeerConnection));
    if (_disposePeerOperations.isNotEmpty) {
      await Future.wait(_disposePeerOperations.values.toList(growable: false));
    }
  }

  void _scheduleDisconnectedPeerCleanup(
    String peerId,
    RTCPeerConnection expectedPeer,
  ) {
    _peerDisconnectTimers.remove(peerId)?.cancel();
    _peerDisconnectTimers[peerId] = Timer(_disconnectedPeerGrace, () {
      unawaited(disposePeerConnection(peerId, expectedPeer: expectedPeer));
    });
  }

  Future<void> _flushPendingIceCandidates(
    String peerId,
    RTCPeerConnection expectedPeer,
  ) async {
    if (!identical(_peerConnections[peerId], expectedPeer)) return;
    final pending = _pendingIceCandidates.remove(peerId) ?? const [];
    for (final candidate in pending) {
      if (!identical(_peerConnections[peerId], expectedPeer)) return;
      await expectedPeer.addCandidate(candidate);
    }
  }

  Future<void> _closePeerConnection(RTCPeerConnection pc, String peerId) async {
    try {
      await pc.close();
    } catch (e, stackTrace) {
      developer.log(
        'Failed to close PeerConnection',
        error: e,
        stackTrace: stackTrace,
        name: 'WebRtcService',
      );
    }

    developer.log(
      'Station PeerConnection closed: $peerId',
      name: 'WebRtcService',
    );
  }

  // ============================================================
  // STOP CAMERA ONLY
  // ============================================================

  Future<void> disposeCamera() async {
    // Hủy hiệu lực mọi yêu cầu mở/khôi phục camera đang chạy. Stream trả về
    // muộn sẽ tự đóng thay vì trở thành một camera chạy ẩn.
    _cameraLifecycleGeneration++;
    final exposureTrackId = localVideoTrack?.id;
    if (Platform.isAndroid) {
      try {
        await _platformChannel.invokeMethod<void>('clearCameraExposureBoost', {
          'trackId': exposureTrackId,
        });
      } catch (error) {
        developer.log(
          '[CAMERA] Unable to clear Android exposure monitor: $error',
          name: 'WebRtcService',
        );
      }
    }
    await _stopRtsp();
    _muteFailureTimer?.cancel();
    _muteFailureTimer = null;
    _endedFailureTimer?.cancel();
    _endedFailureTimer = null;
    _audioFailureTimer?.cancel();
    _audioFailureTimer = null;
    _firstFrameFailureTimer?.cancel();
    _firstFrameFailureTimer = null;
    final firstFrameCompleter = _firstFrameCompleter;
    if (firstFrameCompleter != null && !firstFrameCompleter.isCompleted) {
      firstFrameCompleter.completeError(
        StateError('Camera disposed before its first frame.'),
      );
    }
    _firstFrameCompleter = null;
    _receivedFirstFrame = false;
    localRenderer.srcObject = null;

    final stream = _localStream;

    _localStream = null;

    _cameraInitialized = false;

    if (stream != null) await _disposeMediaStream(stream);

    developer.log('Station camera disposed', name: 'WebRtcService');
  }

  Future<void> _disposeMediaStream(MediaStream stream) async {
    for (final track in stream.getTracks()) {
      try {
        track.enabled = false;
        await track.stop();
      } catch (e) {
        developer.log('Failed to stop track: $e', name: 'WebRtcService');
      }
    }

    try {
      await stream.dispose();
    } catch (e) {
      developer.log(
        'Failed to dispose local stream: $e',
        name: 'WebRtcService',
      );
    }
  }

  // ============================================================
  // DISPOSE EVERYTHING
  // ============================================================

  Future<void> dispose() async {
    // ==========================================================
    // PEER CONNECTION
    // ==========================================================

    await disposeConnection();
    _rtspRetryTimer?.cancel();
    _rtspRetryTimer = null;

    // ==========================================================
    // CAMERA
    // ==========================================================

    await disposeCamera();

    onRtspStateChanged = null;
    onIosCapturePerformance = null;
    onAndroidTaskRemoved = null;
    if (Platform.isAndroid || Platform.isIOS) {
      _platformChannel.setMethodCallHandler(null);
    }

    // ==========================================================
    // RENDERER
    // ==========================================================

    if (_rendererInitialized) {
      try {
        await localRenderer.dispose();
      } catch (e, stackTrace) {
        developer.log(
          'Failed to dispose renderer',
          error: e,
          stackTrace: stackTrace,
          name: 'WebRtcService',
        );
      }

      _rendererInitialized = false;
    }

    developer.log('WebRtcService disposed', name: 'WebRtcService');
  }
}
