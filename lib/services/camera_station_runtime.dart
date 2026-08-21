import 'dart:async';
import 'dart:developer' as developer;

import 'camera_server.dart';
import 'recording_service.dart';
import 'webrtc_service.dart';

class CameraStationRuntime {
  CameraStationRuntime._();

  static final CameraStationRuntime instance = CameraStationRuntime._();

  final StreamController<void> _stateController =
      StreamController<void>.broadcast();

  WebRtcService? _webRtcService;
  RecordingService? _recordingService;
  CameraServer? _cameraServer;
  Future<void>? _initializing;
  String? _cameraId;
  String? _courtId;
  String? _deviceId;
  Timer? _healthTimer;
  bool _recovering = false;
  bool _stopping = false;
  bool _cameraEnabled = true;
  int _generation = 0;

  static const List<Duration> _recoveryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 30),
  ];

  Stream<void> get stateChanges => _stateController.stream;
  WebRtcService? get webRtcService => _webRtcService;
  RecordingService? get recordingService => _recordingService;
  CameraServer? get cameraServer => _cameraServer;
  bool get ready => _cameraServer?.running ?? false;
  bool get cameraEnabled => _cameraEnabled;

  Future<void> initialize({
    required String cameraId,
    required String courtId,
    required String deviceId,
  }) async {
    while (true) {
      if (ready &&
          _cameraId == cameraId &&
          _courtId == courtId &&
          _deviceId == deviceId) {
        return;
      }

      final current = _initializing;
      if (current != null) {
        await current;
        continue;
      }

      final operation = _initializeInternal(
        cameraId: cameraId,
        courtId: courtId,
        deviceId: deviceId,
      );
      _initializing = operation;
      try {
        await operation;
        return;
      } finally {
        if (identical(_initializing, operation)) _initializing = null;
      }
    }
  }

  Future<void> _initializeInternal({
    required String cameraId,
    required String courtId,
    required String deviceId,
  }) async {
    _stopping = false;
    _cameraEnabled = true;
    if (_cameraId != null &&
        (_cameraId != cameraId ||
            _courtId != courtId ||
            _deviceId != deviceId)) {
      await stop();
      _stopping = false;
      _cameraEnabled = true;
    }

    developer.log(
      '[SERVICE] Initializing runtime: $cameraId / $courtId',
      name: 'CameraStationRuntime',
    );

    final webRtc = _webRtcService ?? WebRtcService();
    final recording = _recordingService ?? RecordingService(cameraId: cameraId);

    webRtc.onCameraFailure = _scheduleRecovery;
    _webRtcService = webRtc;
    _recordingService = recording;
    _cameraId = cameraId;
    _courtId = courtId;
    _deviceId = deviceId;

    try {
      await webRtc.initializeCamera();

      final server = CameraServer(
        courtId: courtId,
        cameraId: cameraId,
        deviceId: deviceId,
        webRtcService: webRtc,
        recordingService: recording,
        onStateChanged: _emitState,
      );
      _cameraServer = server;

      await server.start();
      await server.ensureRecording();
      _startHealthMonitor();
      developer.log(
        '[RECORDING] Automatic recording is active',
        name: 'CameraStationRuntime',
      );
      _emitState();
    } catch (error, stackTrace) {
      developer.log(
        '[SERVICE] Runtime initialization failed',
        error: error,
        stackTrace: stackTrace,
        name: 'CameraStationRuntime',
      );
      await stop();
      rethrow;
    }
  }

  Future<void> restart({
    required String cameraId,
    required String courtId,
    required String deviceId,
  }) async {
    await stop();
    await initialize(cameraId: cameraId, courtId: courtId, deviceId: deviceId);
  }

  Future<void> stop() async {
    _stopping = true;
    _generation++;
    _healthTimer?.cancel();
    _healthTimer = null;

    final server = _cameraServer;
    final webRtc = _webRtcService;

    _cameraServer = null;
    _recordingService = null;
    _webRtcService = null;
    _cameraId = null;
    _courtId = null;
    _deviceId = null;
    _cameraEnabled = false;

    try {
      await server?.stop();
    } finally {
      if (webRtc != null) webRtc.onCameraFailure = null;
      await webRtc?.dispose();
      _recovering = false;
      _stopping = false;
      _emitState();
    }

    developer.log('[SERVICE] Runtime stopped', name: 'CameraStationRuntime');
  }

  Future<void> setCameraEnabled(bool enabled) async {
    if (_cameraEnabled == enabled) return;
    final webRtc = _webRtcService;
    final recording = _recordingService;
    final server = _cameraServer;
    if (webRtc == null || recording == null || server == null) {
      throw StateError('Camera Station chưa khởi tạo xong.');
    }

    _cameraEnabled = enabled;
    _generation++;
    _recovering = false;
    _emitState();

    if (!enabled) {
      // Camera cleanup must still run when stopping the recorder/connection
      // fails; otherwise the capture track can remain active in background.
      try {
        await recording.stop();
      } catch (error, stackTrace) {
        developer.log(
          '[CAMERA] Failed to stop recording while disabling camera',
          error: error,
          stackTrace: stackTrace,
          name: 'CameraStationRuntime',
        );
      }

      try {
        await webRtc.disposeConnection();
      } finally {
        await webRtc.disposeCamera();
      }

      developer.log('[CAMERA] Disabled by user', name: 'CameraStationRuntime');
      _emitState();
      return;
    }

    try {
      await webRtc.initializeCamera();
      await server.ensureRecording();
      developer.log('[CAMERA] Enabled by user', name: 'CameraStationRuntime');
    } catch (_) {
      _cameraEnabled = false;
      await webRtc.disposeCamera();
      rethrow;
    } finally {
      _emitState();
    }
  }

  Future<void> switchCamera() async {
    if (!_cameraEnabled) {
      throw StateError('Camera đang tắt.');
    }
    final webRtc = _webRtcService;
    if (webRtc == null) {
      throw StateError('Camera Station chưa khởi tạo xong.');
    }
    await webRtc.switchCamera();
    _emitState();
  }

  void _emitState() {
    if (!_stateController.isClosed) _stateController.add(null);
  }

  void _startHealthMonitor() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_stopping || _recovering || !_cameraEnabled) return;

      final webRtc = _webRtcService;
      final track = webRtc?.localVideoTrack;
      if (webRtc == null ||
          !webRtc.cameraInitialized ||
          track == null ||
          !track.enabled) {
        _scheduleRecovery('health_check_failed');
      }
    });
  }

  void _scheduleRecovery(String reason) {
    if (_stopping || _recovering || !_cameraEnabled) return;
    unawaited(_recoverCamera(reason));
  }

  Future<void> _recoverCamera(String reason) async {
    if (_stopping || _recovering) return;
    _recovering = true;
    final generation = _generation;
    _emitState();

    developer.log(
      '[CAMERA] Recovery requested: $reason',
      name: 'CameraStationRuntime',
    );

    final webRtc = _webRtcService;
    final recording = _recordingService;
    final server = _cameraServer;

    if (webRtc == null || recording == null || server == null) {
      _recovering = false;
      return;
    }

    try {
      await recording.stop();
      await webRtc.disposeConnection();
      await webRtc.disposeCamera();

      for (var attempt = 0; attempt < _recoveryDelays.length; attempt++) {
        if (_stopping || generation != _generation) return;

        final delay = _recoveryDelays[attempt];
        developer.log(
          '[CAMERA] Recovery attempt ${attempt + 1} '
          'in ${delay.inSeconds}s',
          name: 'CameraStationRuntime',
        );
        await Future<void>.delayed(delay);

        if (_stopping || generation != _generation) return;

        try {
          await webRtc.initializeCamera();
          await server.ensureRecording();
          developer.log(
            '[CAMERA] Recovery successful on attempt ${attempt + 1}',
            name: 'CameraStationRuntime',
          );
          _emitState();
          return;
        } catch (error, stackTrace) {
          developer.log(
            '[CAMERA] Recovery attempt ${attempt + 1} failed',
            error: error,
            stackTrace: stackTrace,
            name: 'CameraStationRuntime',
          );
          await webRtc.disposeCamera();
        }
      }

      developer.log(
        '[CAMERA] Recovery stopped after ${_recoveryDelays.length} attempts',
        name: 'CameraStationRuntime',
      );
    } finally {
      _recovering = false;
      _emitState();
    }
  }
}
