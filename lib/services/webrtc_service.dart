import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class WebRtcService {
  static const MethodChannel _platformChannel = MethodChannel(
    'vnvar/camera_station_service',
  );

  void Function(String reason)? onCameraFailure;

  // ============================================================
  // LOCAL CAMERA
  // ============================================================

  MediaStream? _localStream;

  // ============================================================
  // PEER CONNECTION
  // ============================================================

  RTCPeerConnection? _peerConnection;

  // ============================================================
  // LOCAL PREVIEW
  // ============================================================

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();

  // ============================================================
  // STATE
  // ============================================================

  bool _rendererInitialized = false;
  bool _cameraInitialized = false;
  Timer? _muteFailureTimer;
  Timer? _firstFrameFailureTimer;
  bool _receivedFirstFrame = false;
  int _cameraOpenAttempt = 0;
  int _cameraLifecycleGeneration = 0;
  bool? _isEmulator;
  bool _rtspRunning = false;
  String? _rtspError;

  // ============================================================
  // GETTERS
  // ============================================================

  bool get cameraInitialized => _cameraInitialized;

  String? get rtspError => _rtspError;

  bool get rtspSupported => Platform.isAndroid;

  MediaStream? get localStream => _localStream;

  RTCPeerConnection? get peerConnection => _peerConnection;

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

  Future<void> initializeCamera() async {
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
    final preferFrontCamera = _isEmulator == true
        ? _cameraOpenAttempt.isEven
        : _cameraOpenAttempt.isOdd;
    final facingMode = preferFrontCamera ? 'user' : 'environment';
    _cameraOpenAttempt++;
    developer.log(
      '[CAMERA] Open attempt $_cameraOpenAttempt, facingMode=$facingMode',
      name: 'WebRtcService',
    );

    final videoConstraints = _isEmulator == true
        ? <String, dynamic>{
            'facingMode': facingMode,
            'width': {'min': 320, 'ideal': 640, 'max': 640},
            'height': {'min': 240, 'ideal': 480, 'max': 480},
            'frameRate': {'min': 10, 'ideal': 15, 'max': 20},
          }
        : <String, dynamic>{
            'facingMode': facingMode,
            // 720p is broadly supported; capable phones may negotiate 1080p.
            'width': {'min': 640, 'ideal': 1280, 'max': 1920},
            'height': {'min': 360, 'ideal': 720, 'max': 1080},
            // `ideal` is not mandatory: 30/24/15 FPS phones automatically use
            // their highest supported capture mode.
            'frameRate': {'min': 10, 'ideal': 60, 'max': 60},
          };

    final streamFuture = navigator.mediaDevices.getUserMedia({
      'audio': false,
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
        'Camera $facingMode không trả dữ liệu sau 12 giây.',
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
    // LOCAL PREVIEW
    // ==========================================================

    _receivedFirstFrame = false;
    _firstFrameFailureTimer?.cancel();
    localRenderer.srcObject = stream;
    _firstFrameFailureTimer = Timer(const Duration(seconds: 6), () {
      if (_receivedFirstFrame || _localStream != stream) return;
      developer.log(
        '[CAMERA] No frame received; switching camera source',
        name: 'WebRtcService',
      );
      onCameraFailure?.call('first_frame_timeout');
    });

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

    videoTrack.onEnded = () {
      _cameraInitialized = false;
      developer.log('[CAMERA] Video track ended', name: 'WebRtcService');
      onCameraFailure?.call('video_track_ended');
    };

    videoTrack.onMute = () {
      developer.log('[CAMERA] Video track muted', name: 'WebRtcService');
      _muteFailureTimer?.cancel();
      _muteFailureTimer = Timer(const Duration(seconds: 2), () {
        onCameraFailure?.call('video_track_muted');
      });
    };

    videoTrack.onUnMute = () {
      _muteFailureTimer?.cancel();
      _muteFailureTimer = null;
      developer.log('[CAMERA] Video track unmuted', name: 'WebRtcService');
    };

    _cameraInitialized = true;

    await _startRtsp(videoTrack);

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
    if (!rtspSupported) {
      _rtspRunning = false;
      _rtspError = 'RTSP chỉ được hỗ trợ trên Android.';
      developer.log(
        '[RTSP] Unsupported on ${Platform.operatingSystem}.',
        name: 'WebRtcService',
      );
      return;
    }
    try {
      await _platformChannel.invokeMethod<Map<Object?, Object?>>('startRtsp', {
        'trackId': track.id,
        'port': 8554,
      });
      _rtspRunning = true;
      _rtspError = null;
      developer.log(
        '[RTSP] Running at rtsp://0.0.0.0:8554/camera',
        name: 'WebRtcService',
      );
    } catch (error, stackTrace) {
      _rtspRunning = false;
      _rtspError = error.toString();
      developer.log(
        '[RTSP] Cannot start server',
        error: error,
        stackTrace: stackTrace,
        name: 'WebRtcService',
      );
    }
  }

  Future<void> _stopRtsp() async {
    if (!Platform.isAndroid) return;
    if (!_rtspRunning) return;
    _rtspRunning = false;
    try {
      await _platformChannel.invokeMethod<void>('stopRtsp');
    } catch (error) {
      developer.log('[RTSP] Stop failed: $error', name: 'WebRtcService');
    }
  }

  Future<void> switchCamera() async {
    final track = localVideoTrack;
    if (!_cameraInitialized || track == null) {
      throw StateError('Camera chưa sẵn sàng.');
    }
    final switched = await Helper.switchCamera(track);
    if (!switched) {
      throw StateError('Thiết bị không có camera khác để chuyển.');
    }
    developer.log(
      '[CAMERA] Switched front/back on the current VideoTrack',
      name: 'WebRtcService',
    );
  }

  // ============================================================
  // CREATE PEER CONNECTION
  // ============================================================

  Future<void> _createPeerConnection() async {
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

    await disposeConnection();

    // ==========================================================
    // CREATE NEW PC
    // ==========================================================

    final pc = await createPeerConnection(_rtcConfiguration);

    _peerConnection = pc;

    developer.log('Station PeerConnection created', name: 'WebRtcService');

    // ==========================================================
    // CONNECTION STATE
    // ==========================================================

    pc.onConnectionState = (state) {
      developer.log('Station connection state: $state', name: 'WebRtcService');
    };

    // ==========================================================
    // ICE CONNECTION STATE
    // ==========================================================

    pc.onIceConnectionState = (state) {
      developer.log(
        'Station ICE connection state: $state',
        name: 'WebRtcService',
      );
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
          encoding.maxBitrate = 1500000;
          encoding.maxFramerate = 60;
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
  }

  // ============================================================
  // HANDLE TABLET OFFER
  // ============================================================

  Future<RTCSessionDescription> handleOffer({
    required String sdp,
    required String type,
  }) async {
    developer.log('Handling Tablet offer', name: 'WebRtcService');

    // ==========================================================
    // CREATE PC
    // ==========================================================

    await _createPeerConnection();

    final pc = _peerConnection;

    if (pc == null) {
      throw Exception('Không tạo được Station PeerConnection.');
    }

    // ==========================================================
    // REMOTE OFFER
    // ==========================================================

    await pc.setRemoteDescription(RTCSessionDescription(sdp, type));

    developer.log('Tablet offer applied', name: 'WebRtcService');

    // ==========================================================
    // ICE COMPLETER
    // ==========================================================

    final iceCompleter = Completer<void>();

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
      await iceCompleter.future.timeout(const Duration(seconds: 8));
    } catch (_) {
      developer.log('Station ICE gathering timeout', name: 'WebRtcService');
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
  }) async {
    final pc = _peerConnection;

    if (pc == null) {
      developer.log(
        'Ignore remote ICE candidate: '
        'PeerConnection is null',
        name: 'WebRtcService',
      );

      return;
    }

    await pc.addCandidate(RTCIceCandidate(candidate, sdpMid, sdpMLineIndex));

    developer.log('Station remote ICE candidate added', name: 'WebRtcService');
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

  Future<void> disposeConnection() async {
    final pc = _peerConnection;

    _peerConnection = null;

    if (pc != null) {
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

      developer.log('Station PeerConnection closed', name: 'WebRtcService');
    }
  }

  // ============================================================
  // STOP CAMERA ONLY
  // ============================================================

  Future<void> disposeCamera() async {
    // Hủy hiệu lực mọi yêu cầu mở/khôi phục camera đang chạy. Stream trả về
    // muộn sẽ tự đóng thay vì trở thành một camera chạy ẩn.
    _cameraLifecycleGeneration++;
    await _stopRtsp();
    _muteFailureTimer?.cancel();
    _muteFailureTimer = null;
    _firstFrameFailureTimer?.cancel();
    _firstFrameFailureTimer = null;
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

    // ==========================================================
    // CAMERA
    // ==========================================================

    await disposeCamera();

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
