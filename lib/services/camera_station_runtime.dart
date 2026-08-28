import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/camera_resolution_profile.dart';
import 'camera_server.dart';
import 'recording_service.dart';
import 'station_config_service.dart';
import 'webrtc_service.dart';

class CameraStationRuntime {
  CameraStationRuntime._();

  static final CameraStationRuntime instance = CameraStationRuntime._();

  final StreamController<void> _stateController =
      StreamController<void>.broadcast();

  WebRtcService? _webRtcService;
  RecordingService? _recordingService;
  CameraServer? _cameraServer;
  Future<void> _lifecycleTail = Future<void>.value();
  Completer<void> _recoveryCancellation = Completer<void>();
  String? _cameraId;
  String? _courtId;
  String? _deviceId;
  Timer? _healthTimer;
  Timer? _storageCleanupTimer;
  Timer? _thermalTimer;
  bool _thermalThrottled = false;
  double? _temperatureC;
  CameraResolutionProfile? _profileBeforeThermalThrottle;
  bool _recovering = false;
  bool _stopping = false;
  bool _cameraEnabled = true;
  bool _profileSwitching = false;
  bool _iosLifecycleSuspended = false;
  CameraResolutionProfile _resolutionProfile =
      CameraResolutionProfile.fullHd1080;
  List<CameraResolutionProfile> _supportedResolutionProfiles = const [
    CameraResolutionProfile.hd720,
  ];
  int _generation = 0;

  static const List<Duration> _recoveryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 30),
  ];
  static const MethodChannel _platformChannel = MethodChannel(
    'vnvar/camera_station_service',
  );

  Stream<void> get stateChanges => _stateController.stream;
  WebRtcService? get webRtcService => _webRtcService;
  RecordingService? get recordingService => _recordingService;
  CameraServer? get cameraServer => _cameraServer;
  bool get ready => _cameraServer?.running ?? false;
  bool get cameraEnabled => _cameraEnabled;
  bool get microphoneAvailable =>
      _cameraEnabled && (_webRtcService?.microphoneAvailable ?? false);
  bool get microphoneEnabled {
    if (!microphoneAvailable) return false;
    // Android records audio through AudioRecord, not a WebRTC audio track.
    // During recording expose the actual segment state so a failed native
    // microphone start is not presented as an enabled microphone.
    final recording = _recordingService;
    if (Platform.isAndroid && recording?.recording == true) {
      return recording!.currentSegmentHasAudio;
    }
    return _webRtcService?.microphoneEnabled ?? false;
  }

  bool get profileSwitching => _profileSwitching;
  double? get temperatureC => _temperatureC;
  bool get thermalWarning => _thermalThrottled;
  bool get storageWarning => _recordingService?.lowStorageWarning ?? false;
  bool get lifecycleSuspended => _iosLifecycleSuspended;
  CameraResolutionProfile get resolutionProfile => _resolutionProfile;
  List<CameraResolutionProfile> get supportedResolutionProfiles =>
      List.unmodifiable(_supportedResolutionProfiles);

  Future<void> initialize({
    required String cameraId,
    required String courtId,
    required String deviceId,
  }) {
    _interruptRecovery();
    return _serializeLifecycle(() async {
      if (ready &&
          _cameraId == cameraId &&
          _courtId == courtId &&
          _deviceId == deviceId) {
        return;
      }
      await _initializeInternal(
        cameraId: cameraId,
        courtId: courtId,
        deviceId: deviceId,
      );
    });
  }

  Future<T> _serializeLifecycle<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    final previous = _lifecycleTail;
    _lifecycleTail = previous.catchError((Object _) {}).then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  void _interruptRecovery() {
    _generation++;
    if (!_recoveryCancellation.isCompleted) {
      _recoveryCancellation.complete();
    }
    _recoveryCancellation = Completer<void>();
  }

  Future<void> _initializeInternal({
    required String cameraId,
    required String courtId,
    required String deviceId,
  }) async {
    _stopping = false;
    _cameraEnabled = true;
    _iosLifecycleSuspended = false;
    if (_cameraId != null &&
        (_cameraId != cameraId ||
            _courtId != courtId ||
            _deviceId != deviceId)) {
      await _stopInternal();
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
    webRtc.onRtspStateChanged = _emitState;
    _webRtcService = webRtc;
    _recordingService = recording;
    _cameraId = cameraId;
    _courtId = courtId;
    _deviceId = deviceId;

    try {
      _supportedResolutionProfiles = await webRtc
          .getSupportedResolutionProfiles();
      final savedProfile = await StationConfigService().loadResolutionProfile();
      _resolutionProfile = _supportedResolutionProfiles.firstWhere(
        (profile) => profile.preset == savedProfile?.preset,
        orElse: () => _supportedResolutionProfiles.firstWhere(
          (profile) => profile.preset == CameraResolutionPreset.fullHd1080,
          orElse: () => _supportedResolutionProfiles.first,
        ),
      );
      webRtc.setResolutionProfile(_resolutionProfile);
      await webRtc.initializeCamera(facingMode: 'environment');
      // Camera Station always records with microphone audio. The control is
      // intentionally not exposed on Station Screen.
      await webRtc.ensureMicrophoneEnabled();

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
      try {
        await server.ensureRecording();
      } catch (error, stackTrace) {
        developer.log(
          '[RECORDING] Initial start blocked because mandatory audio is unavailable; retrying from health monitor.',
          error: error,
          stackTrace: stackTrace,
          name: 'CameraStationRuntime',
        );
      }
      _startHealthMonitor();
      _startThermalMonitor();

      // Giữ màn hình luôn sáng khi camera đang hoạt động.
      // Trên iOS, điều này đảm bảo app luôn ở foreground và camera
      // không bị hệ điều hành dừng khi màn hình tắt.
      await WakelockPlus.enable();

      developer.log(
        '[RECORDING] Automatic recording is active (wakelock enabled)',
        name: 'CameraStationRuntime',
      );
      _emitState();
    } catch (error, stackTrace) {
      debugPrint('[VNVAR] RUNTIME INIT ERROR: $error');
      debugPrintStack(stackTrace: stackTrace);
      developer.log(
        '[SERVICE] Runtime initialization failed',
        error: error,
        stackTrace: stackTrace,
        name: 'CameraStationRuntime',
      );
      await _stopInternal();
      rethrow;
    }
  }

  Future<void> restart({
    required String cameraId,
    required String courtId,
    required String deviceId,
  }) {
    _interruptRecovery();
    return _serializeLifecycle(() async {
      await _stopInternal();
      await _initializeInternal(
        cameraId: cameraId,
        courtId: courtId,
        deviceId: deviceId,
      );
    });
  }

  Future<void> stop() {
    _stopping = true;
    _interruptRecovery();
    return _serializeLifecycle(_stopInternal);
  }

  Future<void> _stopInternal() async {
    _stopping = true;
    _healthTimer?.cancel();
    _healthTimer = null;
    _thermalTimer?.cancel();
    _thermalTimer = null;
    _thermalThrottled = false;
    _temperatureC = null;
    _profileBeforeThermalThrottle = null;
    _storageCleanupTimer?.cancel();
    _storageCleanupTimer = null;

    final server = _cameraServer;
    final webRtc = _webRtcService;

    _cameraServer = null;
    _recordingService = null;
    _webRtcService = null;
    _cameraId = null;
    _courtId = null;
    _deviceId = null;
    _cameraEnabled = false;
    _iosLifecycleSuspended = false;

    try {
      await server?.stop();
    } finally {
      if (webRtc != null) {
        webRtc.onCameraFailure = null;
        webRtc.onRtspStateChanged = null;
      }
      await webRtc?.dispose();
      _recovering = false;
      _stopping = false;

      // Cho phép màn hình tắt bình thường khi dừng camera.
      await WakelockPlus.disable();

      _emitState();
    }

    developer.log('[SERVICE] Runtime stopped', name: 'CameraStationRuntime');
  }

  Future<void> setCameraEnabled(bool enabled) {
    _interruptRecovery();
    return _serializeLifecycle(() => _setCameraEnabledInternal(enabled));
  }

  Future<void> suspendForIosBackground() {
    if (!Platform.isIOS || _iosLifecycleSuspended || !_cameraEnabled) {
      return Future<void>.value();
    }
    _iosLifecycleSuspended = true;
    _interruptRecovery();
    _emitState();
    return _serializeLifecycle(_suspendForIosBackgroundInternal);
  }

  Future<void> _suspendForIosBackgroundInternal() async {
    if (!Platform.isIOS || !_iosLifecycleSuspended) return;
    final recording = _recordingService;
    final webRtc = _webRtcService;
    if (recording == null || webRtc == null) return;
    developer.log(
      '[LIFECYCLE] iOS entering background; finalizing current segment',
      name: 'CameraStationRuntime',
    );
    try {
      await recording.stop();
    } finally {
      try {
        await webRtc.disposeConnection();
      } finally {
        await webRtc.disposeCamera();
      }
      await WakelockPlus.disable();
      _emitState();
    }
  }

  Future<void> resumeFromIosBackground() {
    if (!Platform.isIOS || !_iosLifecycleSuspended || !_cameraEnabled) {
      return Future<void>.value();
    }
    return _serializeLifecycle(_resumeFromIosBackgroundInternal);
  }

  Future<void> _resumeFromIosBackgroundInternal() async {
    if (!Platform.isIOS || !_iosLifecycleSuspended || !_cameraEnabled) return;
    final webRtc = _webRtcService;
    final server = _cameraServer;
    if (webRtc == null || server == null) return;
    try {
      // Recreating the stream also rechecks microphone permission. A grant
      // made in iOS Settings therefore takes effect on the first new segment.
      await webRtc.initializeCamera();
      await webRtc.ensureMicrophoneEnabled();
      await server.ensureRecording();
      await WakelockPlus.enable();
      _iosLifecycleSuspended = false;
      developer.log(
        '[LIFECYCLE] iOS foreground capture resumed',
        name: 'CameraStationRuntime',
      );
    } catch (error, stackTrace) {
      developer.log(
        '[LIFECYCLE] Unable to resume iOS capture; scheduling recovery',
        error: error,
        stackTrace: stackTrace,
        name: 'CameraStationRuntime',
      );
      _iosLifecycleSuspended = false;
      _scheduleRecovery('ios_foreground_resume_failed');
    } finally {
      _emitState();
    }
  }

  Future<void> _setCameraEnabledInternal(bool enabled) async {
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

      await WakelockPlus.disable();
      developer.log('[CAMERA] Disabled by user', name: 'CameraStationRuntime');
      _emitState();
      return;
    }

    try {
      await webRtc.initializeCamera();
      await server.ensureRecording();
      await WakelockPlus.enable();
      developer.log('[CAMERA] Enabled by user', name: 'CameraStationRuntime');
    } catch (_) {
      _cameraEnabled = false;
      await webRtc.disposeCamera();
      rethrow;
    } finally {
      _emitState();
    }
  }

  Future<void> switchCamera() {
    _interruptRecovery();
    return _serializeLifecycle(_switchCameraInternal);
  }

  Future<void> _switchCameraInternal() async {
    if (!_cameraEnabled) {
      throw StateError('Camera đang tắt.');
    }
    if (_profileSwitching) {
      throw StateError('Camera đang thay đổi cấu hình.');
    }
    final webRtc = _webRtcService;
    final recording = _recordingService;
    final server = _cameraServer;
    if (webRtc == null || recording == null || server == null) {
      throw StateError('Camera Station chưa khởi tạo xong.');
    }

    final previousFacing = webRtc.currentFacingMode;
    final targetFacing = previousFacing == 'environment'
        ? 'user'
        : 'environment';
    final targetProfiles = await webRtc.getSupportedResolutionProfiles(
      facingMode: targetFacing,
      fallbackWhenUnavailable: false,
    );
    if (targetProfiles.isEmpty) {
      throw StateError('Thiết bị không có camera $targetFacing khả dụng.');
    }

    final previousProfile = _resolutionProfile;
    final previousProfiles = _supportedResolutionProfiles;
    final selectedProfile = targetProfiles.firstWhere(
      (profile) => profile.preset == previousProfile.preset,
      orElse: () => targetProfiles.last,
    );

    _profileSwitching = true;
    _generation++;
    _emitState();
    try {
      await recording.stop();
      await webRtc.disposeConnection();
      await webRtc.disposeCamera();
      webRtc.setResolutionProfile(selectedProfile);
      await webRtc.initializeCamera(facingMode: targetFacing);
      await server.ensureRecording();

      _supportedResolutionProfiles = targetProfiles;
      _resolutionProfile = selectedProfile;
      if (selectedProfile != previousProfile) {
        await StationConfigService().saveResolutionProfile(selectedProfile);
      }
      developer.log(
        '[CAMERA] Switched to $targetFacing at '
        '${selectedProfile.shortLabel} ${selectedProfile.fps} FPS',
        name: 'CameraStationRuntime',
      );
    } catch (_) {
      _supportedResolutionProfiles = previousProfiles;
      _resolutionProfile = previousProfile;
      webRtc.setResolutionProfile(previousProfile);
      try {
        await webRtc.disposeCamera();
        await webRtc.initializeCamera(facingMode: previousFacing);
        await server.ensureRecording();
      } catch (rollbackError, stackTrace) {
        developer.log(
          '[CAMERA] Lens switch rollback failed',
          error: rollbackError,
          stackTrace: stackTrace,
          name: 'CameraStationRuntime',
        );
      }
      rethrow;
    } finally {
      _profileSwitching = false;
      _emitState();
    }
  }

  Future<void> setResolutionProfile(CameraResolutionProfile profile) {
    if (_thermalThrottled &&
        (profile.preset != CameraResolutionPreset.hd720 || profile.fps > 15)) {
      return Future<void>.error(
        StateError('Thiết bị đang nóng; camera tạm khóa ở 720p/15 FPS.'),
      );
    }
    _interruptRecovery();
    return _serializeLifecycle(() => _setResolutionProfileInternal(profile));
  }

  Future<void> _setResolutionProfileInternal(
    CameraResolutionProfile profile,
  ) async {
    if (_profileSwitching || profile == _resolutionProfile) {
      return;
    }
    CameraResolutionProfile? selected;
    for (final supported in _supportedResolutionProfiles) {
      if (supported.preset == profile.preset) {
        selected = profile.fps < supported.fps
            ? supported.withFps(profile.fps)
            : supported;
        break;
      }
    }
    if (selected == null) {
      throw ArgumentError('Thiết bị không hỗ trợ ${profile.shortLabel}.');
    }
    final webRtc = _webRtcService;
    final recording = _recordingService;
    final server = _cameraServer;
    if (!_cameraEnabled ||
        webRtc == null ||
        recording == null ||
        server == null) {
      throw StateError('Camera chưa sẵn sàng.');
    }

    final previous = _resolutionProfile;
    _profileSwitching = true;
    _generation++;
    _emitState();
    try {
      await recording.stop();
      await webRtc.disposeConnection();
      await webRtc.disposeCamera();
      webRtc.setResolutionProfile(selected);
      await webRtc.initializeCamera();
      await server.ensureRecording();
      _resolutionProfile = selected;
      await StationConfigService().saveResolutionProfile(selected);
      developer.log(
        '[CAMERA] Resolution changed to ${selected.shortLabel} '
        '${selected.fps} FPS',
        name: 'CameraStationRuntime',
      );
    } catch (_) {
      webRtc.setResolutionProfile(previous);
      try {
        await webRtc.disposeCamera();
        await webRtc.initializeCamera();
        await server.ensureRecording();
      } catch (rollbackError, stackTrace) {
        developer.log(
          '[CAMERA] Resolution rollback failed',
          error: rollbackError,
          stackTrace: stackTrace,
          name: 'CameraStationRuntime',
        );
      }
      rethrow;
    } finally {
      _profileSwitching = false;
      _emitState();
    }
  }

  void _emitState() {
    if (!_stateController.isClosed) _stateController.add(null);
  }

  void _startHealthMonitor() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_stopping ||
          _recovering ||
          _profileSwitching ||
          _iosLifecycleSuspended ||
          !_cameraEnabled) {
        return;
      }

      final webRtc = _webRtcService;
      final track = webRtc?.localVideoTrack;
      if (webRtc == null ||
          !webRtc.cameraInitialized ||
          track == null ||
          !track.enabled) {
        _scheduleRecovery('health_check_failed');
        return;
      }
      final recording = _recordingService;
      final server = _cameraServer;
      if (recording != null &&
          server != null &&
          !recording.recording &&
          !recording.rotating) {
        unawaited(
          server.ensureRecording().catchError((Object error, StackTrace stack) {
            developer.log(
              '[RECORDING] Mandatory-audio retry failed',
              error: error,
              stackTrace: stack,
              name: 'CameraStationRuntime',
            );
          }),
        );
      }
    });

    _storageCleanupTimer?.cancel();
    _storageCleanupTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      final recording = _recordingService;
      if (recording == null) return;
      unawaited(() async {
        try {
          // Never inspect staging files while MediaRecorder/FFmpeg may still
          // be writing them; cleanup runs again after the next stop/start.
          if (!recording.recording && !recording.rotating) {
            await recording.cleanupStagingFiles();
          }
          await recording.enforceStorageLimit();
        } catch (error, stackTrace) {
          developer.log(
            '[STORAGE] Periodic cleanup failed',
            error: error,
            stackTrace: stackTrace,
            name: 'CameraStationRuntime',
          );
        }
      }());
    });
  }

  void _startThermalMonitor() {
    _thermalTimer?.cancel();
    _thermalTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(_checkThermalState());
    });
    unawaited(_checkThermalState());
  }

  Future<void> _checkThermalState() async {
    if ((!Platform.isAndroid && !Platform.isIOS) ||
        _stopping ||
        !_cameraEnabled ||
        _iosLifecycleSuspended) {
      return;
    }
    try {
      final result = await _platformChannel.invokeMapMethod<String, dynamic>(
        'getThermalStatus',
      );
      final temperature = (result?['temperatureC'] as num?)?.toDouble();
      final status = (result?['thermalStatus'] as num?)?.toInt() ?? 0;
      _temperatureC = temperature;
      final hot = (temperature != null && temperature >= 45.0) || status >= 4;
      if (hot && !_thermalThrottled && !_profileSwitching) {
        _profileBeforeThermalThrottle = _resolutionProfile;
        _thermalThrottled = true;
        _emitState();
        developer.log(
          '[THERMAL] Hot device; reducing camera to 720p/15fps',
          name: 'CameraStationRuntime',
        );
        try {
          await setResolutionProfile(CameraResolutionProfile.hd720.withFps(15));
        } catch (error, stackTrace) {
          _thermalThrottled = false;
          developer.log(
            '[THERMAL] Failed to reduce camera profile',
            error: error,
            stackTrace: stackTrace,
            name: 'CameraStationRuntime',
          );
        }
      } else if (!hot && _thermalThrottled && !_profileSwitching) {
        _thermalThrottled = false;
        _emitState();
        final previous = _profileBeforeThermalThrottle;
        _profileBeforeThermalThrottle = null;
        if (previous != null) {
          try {
            await setResolutionProfile(previous);
            developer.log(
              '[THERMAL] Temperature normal; restored camera profile',
              name: 'CameraStationRuntime',
            );
          } catch (error, stackTrace) {
            developer.log(
              '[THERMAL] Failed to restore camera profile',
              error: error,
              stackTrace: stackTrace,
              name: 'CameraStationRuntime',
            );
          }
        }
      } else {
        _emitState();
      }
    } catch (error) {
      developer.log(
        '[THERMAL] Unable to read thermal state: $error',
        name: 'CameraStationRuntime',
      );
    }
  }

  void _scheduleRecovery(String reason) {
    if (_stopping ||
        _recovering ||
        _iosLifecycleSuspended ||
        !_cameraEnabled) {
      return;
    }
    _recovering = true;
    final generation = _generation;
    final cancellation = _recoveryCancellation.future;
    _emitState();
    unawaited(
      _serializeLifecycle(
        () => _recoverCamera(reason, generation, cancellation),
      ).whenComplete(() {
        _recovering = false;
        _emitState();
      }),
    );
  }

  Future<void> _recoverCamera(
    String reason,
    int generation,
    Future<void> cancellation,
  ) async {
    if (_stopping || generation != _generation) return;
    developer.log(
      '[CAMERA] Recovery requested: $reason',
      name: 'CameraStationRuntime',
    );

    final webRtc = _webRtcService;
    final recording = _recordingService;
    final server = _cameraServer;

    if (webRtc == null || recording == null || server == null) {
      return;
    }

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
      await Future.any<void>([Future<void>.delayed(delay), cancellation]);

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
  }
}
