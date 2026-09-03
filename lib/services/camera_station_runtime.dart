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

bool shouldRecreateIosCameraForLensSwitch(
  CameraResolutionProfile previous,
  CameraResolutionProfile selected,
) => selected != previous;

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
  bool _thermalCriticalSuspended = false;
  bool _thermalCheckRunning = false;
  DateTime? _thermalNormalSince;
  double? _temperatureC;
  CameraResolutionProfile? _profileBeforeThermalThrottle;
  bool _recovering = false;
  bool _stopping = false;
  bool _cameraEnabled = true;
  bool _profileSwitching = false;
  bool _iosLifecycleSuspended = false;
  bool _healthCheckRunning = false;
  String? _lastRecordingPath;
  int? _lastRecordingBytes;
  DateTime? _lastRecordingProgressAt;
  String? _lastAudioPath;
  int? _lastAudioBytes;
  DateTime? _lastAudioProgressAt;
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
  static const Duration _thermalRestoreDelay = Duration(minutes: 2);
  static const Duration _recordingStallTimeout = Duration(seconds: 45);
  static const Duration _bufferedVideoHardStallTimeout = Duration(minutes: 2);
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
    if ((Platform.isAndroid || Platform.isIOS) &&
        recording?.recording == true) {
      return recording!.currentSegmentHasAudio;
    }
    return _webRtcService?.microphoneEnabled ?? false;
  }

  bool get profileSwitching => _profileSwitching;
  double? get temperatureC => _temperatureC;
  bool get thermalWarning => _thermalThrottled;
  bool get storageWarning => _recordingService?.lowStorageWarning ?? false;
  bool get lifecycleSuspended => _iosLifecycleSuspended;
  String get captureState {
    if (_thermalCriticalSuspended) return 'thermal_suspended';
    if (_recordingService?.storageSuspended == true) {
      return 'storage_suspended';
    }
    if (_iosLifecycleSuspended) return 'lifecycle_suspended';
    if (_recovering) return 'recovering';
    if (_profileSwitching) return 'profile_switching';
    if (_recordingService?.recording == true) return 'recording';
    return ready ? 'ready' : 'starting';
  }

  String get thermalState {
    if (_thermalCriticalSuspended) return 'critical';
    if (_thermalThrottled) return 'hot';
    return _temperatureC == null ? 'unknown' : 'normal';
  }

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
    await _setIosStationActive(true);

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
      final preflightThermal = await _readThermalSnapshot();
      _temperatureC = preflightThermal.temperatureC;
      final criticalThermal = preflightThermal.critical;
      if (preflightThermal.hot) {
        _profileBeforeThermalThrottle = _resolutionProfile;
        _thermalThrottled = true;
        _resolutionProfile = CameraResolutionProfile.hd720.withFps(15);
      }
      if (criticalThermal) {
        _thermalCriticalSuspended = true;
        developer.log(
          '[THERMAL] Critical state detected before camera startup; capture remains paused',
          name: 'CameraStationRuntime',
        );
      }
      webRtc.setResolutionProfile(_resolutionProfile);
      if (!criticalThermal) {
        await webRtc.initializeCamera(facingMode: 'environment');
        // Camera Station always requests microphone audio. A denied permission
        // intentionally falls back to video-only recording.
        await webRtc.ensureMicrophoneEnabled();
      }

      final server = CameraServer(
        courtId: courtId,
        cameraId: cameraId,
        deviceId: deviceId,
        webRtcService: webRtc,
        recordingService: recording,
        onStateChanged: _emitState,
        captureStateProvider: () => captureState,
        thermalStateProvider: () => thermalState,
        temperatureProvider: () => _temperatureC,
      );
      _cameraServer = server;

      await server.start();
      if (!criticalThermal) {
        try {
          await server.ensureRecording();
        } catch (error, stackTrace) {
          developer.log(
            '[RECORDING] Initial recording start failed; retrying from health monitor.',
            error: error,
            stackTrace: stackTrace,
            name: 'CameraStationRuntime',
          );
        }
      }
      _startHealthMonitor();
      _startThermalMonitor();

      // Giữ màn hình luôn sáng khi camera đang hoạt động.
      // Trên iOS, điều này đảm bảo app luôn ở foreground và camera
      // không bị hệ điều hành dừng khi màn hình tắt.
      await WakelockPlus.enable();
      await _setIosStationActive(true);

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
    _thermalCriticalSuspended = false;
    _thermalCheckRunning = false;
    _thermalNormalSince = null;
    _temperatureC = null;
    _profileBeforeThermalThrottle = null;
    _storageCleanupTimer?.cancel();
    _storageCleanupTimer = null;
    _healthCheckRunning = false;
    _resetRecordingProgressWatchdog();

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
      await _setIosStationActive(false);

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
    await _beginIosBackgroundFinalization();
    try {
      await recording.stop();
    } finally {
      try {
        try {
          await webRtc.disposeConnection();
        } finally {
          await webRtc.disposeCamera();
        }
        await WakelockPlus.disable();
        await _setIosStationActive(false);
        _resetRecordingProgressWatchdog();
        _emitState();
      } finally {
        await _endIosBackgroundFinalization();
      }
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
    if (_thermalCriticalSuspended) {
      _iosLifecycleSuspended = false;
      await WakelockPlus.enable();
      await _setIosStationActive(true);
      _emitState();
      return;
    }
    try {
      // Recreating the stream also rechecks microphone permission. A grant
      // made in iOS Settings therefore takes effect on the first new segment.
      await webRtc.initializeCamera();
      await webRtc.ensureMicrophoneEnabled();
      await server.ensureRecording();
      await WakelockPlus.enable();
      await _setIosStationActive(true);
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
      await _setIosStationActive(false);
      developer.log('[CAMERA] Disabled by user', name: 'CameraStationRuntime');
      _emitState();
      return;
    }

    try {
      await webRtc.initializeCamera();
      await server.ensureRecording();
      await WakelockPlus.enable();
      await _setIosStationActive(true);
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
      if (Platform.isIOS) {
        final recreateCapture = shouldRecreateIosCameraForLensSwitch(
          previousProfile,
          selectedProfile,
        );
        if (!recreateCapture && recording.recording) {
          await recording.checkpointCurrentSegment(
            onRecorderStopped: webRtc.switchCamera,
          );
        } else if (!recreateCapture) {
          await webRtc.switchCamera();
          await server.ensureRecording();
        } else {
          // Helper.switchCamera keeps the constraints of the previous lens.
          // Recreate capture when the target lens needs a lower profile (for
          // example a 4K rear camera switching to a 1080p front camera).
          await recording.stop();
          await webRtc.disposeConnection();
          await webRtc.disposeCamera();
          webRtc.setResolutionProfile(selectedProfile);
          await webRtc.initializeCamera(facingMode: targetFacing);
          await server.ensureRecording();
        }
        _supportedResolutionProfiles = targetProfiles;
        _resolutionProfile = selectedProfile;
        webRtc.setResolutionProfile(selectedProfile);
        if (selectedProfile != previousProfile) {
          await StationConfigService().saveResolutionProfile(selectedProfile);
        }
        developer.log(
          '[CAMERA] Switched iOS lens with a compatible capture profile',
          name: 'CameraStationRuntime',
        );
        return;
      }
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
        // The iOS handoff may already have opened a new recorder on the old
        // VideoTrack before the lens switch error is reported. Finalize that
        // recorder before disposing the track, otherwise its state remains
        // `recording` while no camera frames can reach it.
        await recording.stop();
        await webRtc.disposeConnection();
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
      unawaited(_checkRuntimeHealth());
    });
    unawaited(_checkRuntimeHealth());

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

  Future<void> _checkRuntimeHealth() async {
    if (_healthCheckRunning ||
        _stopping ||
        _recovering ||
        _profileSwitching ||
        _thermalCriticalSuspended ||
        _iosLifecycleSuspended ||
        !_cameraEnabled) {
      return;
    }
    _healthCheckRunning = true;
    try {
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
      if (recording == null || server == null) return;
      if (!recording.recording && !recording.rotating) {
        _resetRecordingProgressWatchdog();
        if (!recording.storageRetryDue) return;
        try {
          await server.ensureRecording();
        } catch (error, stackTrace) {
          developer.log(
            '[RECORDING] Automatic recording retry failed',
            error: error,
            stackTrace: stackTrace,
            name: 'CameraStationRuntime',
          );
        }
        return;
      }
      if (recording.rotating) {
        _resetRecordingProgressWatchdog();
        return;
      }

      final progress = await recording.currentRecordingProgress();
      if (progress == null) {
        _scheduleRecovery('recording_progress_missing');
        return;
      }
      final now = DateTime.now();
      var videoStalled = false;
      var videoHardStalled = false;
      if (_lastRecordingPath != progress.path) {
        _lastRecordingPath = progress.path;
        _lastRecordingBytes = progress.bytes;
        _lastRecordingProgressAt = now;
      } else if (_lastRecordingBytes != progress.bytes) {
        _lastRecordingBytes = progress.bytes;
        _lastRecordingProgressAt = now;
      } else {
        final lastProgress = _lastRecordingProgressAt ?? now;
        final stalledFor = now.difference(lastProgress);
        videoStalled =
            stalledFor >= _recordingStallTimeout &&
            now.difference(progress.startedAt) >= _recordingStallTimeout;
        videoHardStalled =
            stalledFor >= _bufferedVideoHardStallTimeout &&
            now.difference(progress.startedAt) >=
                _bufferedVideoHardStallTimeout;
      }

      final audioProgress = await recording.currentAudioProgress();
      var audioStalled = false;
      if (audioProgress != null) {
        if (!audioProgress.active) {
          _scheduleRecovery('recording_audio_inactive');
          return;
        }
        if (_lastAudioPath != audioProgress.path) {
          _lastAudioPath = audioProgress.path;
          _lastAudioBytes = audioProgress.bytes;
          _lastAudioProgressAt = now;
        } else if (_lastAudioBytes != audioProgress.bytes) {
          _lastAudioBytes = audioProgress.bytes;
          _lastAudioProgressAt = now;
        } else if (now.difference(_lastAudioProgressAt ?? now) >=
                _recordingStallTimeout &&
            now.difference(progress.startedAt) >= _recordingStallTimeout) {
          audioStalled = true;
        }
      }
      if (audioStalled) {
        developer.log(
          '[RECORDING] Native audio stopped growing at ${audioProgress?.bytes} bytes',
          name: 'CameraStationRuntime',
        );
        _scheduleRecovery('recording_audio_stalled');
      } else if (videoStalled && (audioProgress == null || videoHardStalled)) {
        // MP4 writers may buffer metadata/video writes. On Android, continuing
        // WAV progress proves the capture pipeline is alive and avoids a false
        // recovery. Video-only/iOS segments still rely on MP4 growth.
        developer.log(
          '[RECORDING] Staging file stopped growing at ${progress.bytes} bytes',
          name: 'CameraStationRuntime',
        );
        _scheduleRecovery('recording_file_stalled');
      }
    } catch (error, stackTrace) {
      developer.log(
        '[HEALTH] Runtime health check failed',
        error: error,
        stackTrace: stackTrace,
        name: 'CameraStationRuntime',
      );
    } finally {
      _healthCheckRunning = false;
    }
  }

  void _resetRecordingProgressWatchdog() {
    _lastRecordingPath = null;
    _lastRecordingBytes = null;
    _lastRecordingProgressAt = null;
    _lastAudioPath = null;
    _lastAudioBytes = null;
    _lastAudioProgressAt = null;
  }

  void _startThermalMonitor() {
    _thermalTimer?.cancel();
    _thermalTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(_checkThermalState());
    });
    unawaited(_checkThermalState());
  }

  Future<void> _checkThermalState() async {
    if (_thermalCheckRunning ||
        (!Platform.isAndroid && !Platform.isIOS) ||
        _stopping ||
        !_cameraEnabled ||
        _iosLifecycleSuspended) {
      return;
    }
    _thermalCheckRunning = true;
    try {
      final snapshot = await _readThermalSnapshot();
      final temperature = snapshot.temperatureC;
      _temperatureC = temperature;
      final critical = snapshot.critical;
      final hot = snapshot.hot;
      if (critical) {
        _thermalNormalSince = null;
        if (!_thermalCriticalSuspended && !_profileSwitching) {
          await _serializeLifecycle(_suspendForCriticalThermal);
        }
        _emitState();
        return;
      }
      if (_thermalCriticalSuspended) {
        if (hot) {
          _thermalNormalSince = null;
          _emitState();
          return;
        }
        final now = DateTime.now();
        _thermalNormalSince ??= now;
        if (now.difference(_thermalNormalSince!) >= _thermalRestoreDelay) {
          await _serializeLifecycle(_resumeAfterCriticalThermal);
          _thermalNormalSince = DateTime.now();
        }
        _emitState();
        return;
      }
      if (hot) _thermalNormalSince = null;
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
        final now = DateTime.now();
        _thermalNormalSince ??= now;
        if (now.difference(_thermalNormalSince!) < _thermalRestoreDelay) {
          _emitState();
          return;
        }
        final previous = _profileBeforeThermalThrottle;
        if (previous != null) {
          try {
            _thermalThrottled = false;
            await setResolutionProfile(previous);
            _profileBeforeThermalThrottle = null;
            _thermalNormalSince = null;
            developer.log(
              '[THERMAL] Temperature stable for 2 minutes; restored camera profile',
              name: 'CameraStationRuntime',
            );
          } catch (error, stackTrace) {
            _thermalThrottled = true;
            _thermalNormalSince = now;
            developer.log(
              '[THERMAL] Failed to restore camera profile',
              error: error,
              stackTrace: stackTrace,
              name: 'CameraStationRuntime',
            );
          }
        } else {
          _thermalThrottled = false;
          _thermalNormalSince = null;
        }
        _emitState();
      } else {
        _emitState();
      }
    } catch (error) {
      developer.log(
        '[THERMAL] Unable to read thermal state: $error',
        name: 'CameraStationRuntime',
      );
    } finally {
      _thermalCheckRunning = false;
    }
  }

  Future<({double? temperatureC, bool hot, bool critical})>
  _readThermalSnapshot() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return (temperatureC: null, hot: false, critical: false);
    }
    final result = await _platformChannel.invokeMapMethod<String, dynamic>(
      'getThermalStatus',
    );
    final temperature = (result?['temperatureC'] as num?)?.toDouble();
    final status = (result?['thermalStatus'] as num?)?.toInt() ?? 0;
    return (
      temperatureC: temperature,
      hot: (temperature != null && temperature >= 45.0) || status >= 4,
      critical: (temperature != null && temperature >= 50.0) || status >= 5,
    );
  }

  Future<void> _suspendForCriticalThermal() async {
    if (_thermalCriticalSuspended || _stopping || !_cameraEnabled) return;
    final recording = _recordingService;
    final webRtc = _webRtcService;
    if (recording == null || webRtc == null) return;

    _thermalCriticalSuspended = true;
    _profileBeforeThermalThrottle ??= _resolutionProfile;
    _thermalThrottled = true;
    final safeProfile = CameraResolutionProfile.hd720.withFps(15);
    _resolutionProfile = safeProfile;
    webRtc.setResolutionProfile(safeProfile);
    developer.log(
      '[THERMAL] Critical state; finalizing segment and pausing capture',
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
      _resetRecordingProgressWatchdog();
    }
  }

  Future<void> _resumeAfterCriticalThermal() async {
    if (!_thermalCriticalSuspended ||
        _stopping ||
        !_cameraEnabled ||
        _iosLifecycleSuspended) {
      return;
    }
    final webRtc = _webRtcService;
    final server = _cameraServer;
    if (webRtc == null || server == null) return;
    try {
      await webRtc.initializeCamera();
      await webRtc.ensureMicrophoneEnabled();
      await server.ensureRecording();
      _thermalCriticalSuspended = false;
      developer.log(
        '[THERMAL] Device stable; capture resumed at 720p/15fps',
        name: 'CameraStationRuntime',
      );
    } catch (error, stackTrace) {
      developer.log(
        '[THERMAL] Unable to resume capture after critical state',
        error: error,
        stackTrace: stackTrace,
        name: 'CameraStationRuntime',
      );
      await webRtc.disposeCamera();
    }
  }

  Future<void> _setIosStationActive(bool active) async {
    if (!Platform.isIOS) return;
    try {
      await _platformChannel.invokeMethod<void>('setStationActive', {
        'active': active,
      });
    } catch (error) {
      developer.log(
        '[LIFECYCLE] Unable to update iOS idle timer: $error',
        name: 'CameraStationRuntime',
      );
    }
  }

  Future<void> _beginIosBackgroundFinalization() async {
    if (!Platform.isIOS) return;
    try {
      await _platformChannel.invokeMethod<void>('beginBackgroundFinalization');
    } catch (error) {
      developer.log(
        '[LIFECYCLE] Unable to begin iOS background finalization: $error',
        name: 'CameraStationRuntime',
      );
    }
  }

  Future<void> _endIosBackgroundFinalization() async {
    if (!Platform.isIOS) return;
    try {
      await _platformChannel.invokeMethod<void>('endBackgroundFinalization');
    } catch (error) {
      developer.log(
        '[LIFECYCLE] Unable to end iOS background finalization: $error',
        name: 'CameraStationRuntime',
      );
    }
  }

  void _scheduleRecovery(String reason) {
    if (_stopping ||
        _recovering ||
        _thermalCriticalSuspended ||
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
