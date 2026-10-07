import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/camera_resolution_profile.dart';
import '../models/station_identity.dart';
import '../services/camera_station_foreground_service.dart';
import '../services/app_language_service.dart';
import '../services/camera_server.dart';
import '../services/camera_station_runtime.dart';
import '../services/recording_service.dart';
import '../services/station_config_service.dart';
import '../services/station_display_service.dart';
import '../services/whip_publisher_service.dart';
import '../services/rtsp_publisher_service.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'setup_screen.dart';
import 'video_storage_screen.dart';
import 'live_stream_screen.dart';

@visibleForTesting
bool shouldSuspendIosCapture(AppLifecycleState state) {
  return state == AppLifecycleState.hidden ||
      state == AppLifecycleState.paused ||
      state == AppLifecycleState.detached;
}

@visibleForTesting
List<DeviceOrientation> orientationsForMode(String mode) {
  switch (mode) {
    case 'landscape':
      return const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ];
    case 'portrait':
      return const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ];
    case 'auto':
    default:
      return const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ];
  }
}

@visibleForTesting
List<DeviceOrientation> orientationsForBackgroundLock({
  required bool isCurrentLayoutLandscape,
}) {
  return isCurrentLayoutLandscape
      ? const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]
      : const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ];
}

// ============================================================
// STATION SCREEN
// ============================================================

class StationScreen extends StatefulWidget {
  final StationIdentity identity;
  final ValueChanged<StationIdentity> onIdentityChanged;

  const StationScreen({
    super.key,
    required this.identity,
    required this.onIdentityChanged,
  });

  @override
  State<StationScreen> createState() => _StationScreenState();
}

// ============================================================
// STATE
// ============================================================

class _StationScreenState extends State<StationScreen>
    with WidgetsBindingObserver {
  static const MethodChannel _platformChannel = MethodChannel(
    'vnvar/camera_station_service',
  );
  final CameraStationRuntime _runtime = CameraStationRuntime.instance;

  StreamSubscription<void>? _runtimeSubscription;
  StreamSubscription<WhipPublishState>? _whipSubscription;
  StreamSubscription<RtspPublishState>? _rtspSubscription;

  bool _loading = true;
  String? _error;
  int _cameraQuarterTurns = 0;
  bool _cameraSwitching = false;
  bool _lensSwitching = false;
  bool _screenDimmed = false;
  bool _screenDimSwitching = false;
  String? _lastShownRtspError;
  String _viewerAddress = 'Đang kiểm tra mạng...';
  Timer? _zoomDebounce;
  double? _zoomValue;
  String _screenOrientation = 'landscape';
  bool _isCurrentLayoutLandscape = true;
  /// Hướng màn hình khi ứng dụng đang foreground (chưa bị Keyguard can thiệp).
  /// Giữ nguyên giá trị này khi app chuyển sang background để tránh race
  /// condition: Keyguard ép portrait → LayoutBuilder rebuild → giá trị bị đổi
  /// thành portrait trước khi lifecycle callback kịp chạy.
  bool _lastActiveOrientationLandscape = true;
  bool _appResumed = true;
  bool _isInPipMode = false;
  Offset? _focusIndicatorPosition;
  int _focusIndicatorKey = 0;

  bool get _recording => _runtime.recordingService?.recording ?? false;

  bool get _cameraReady =>
      _runtime.cameraEnabled &&
      (_runtime.webRtcService?.cameraInitialized ?? false);

  void _handlePreviewTap(TapDownDetails details, BoxConstraints constraints) {
    if (!_cameraReady || _isInPipMode) return;
    final pos = details.localPosition;
    setState(() {
      _focusIndicatorPosition = pos;
      _focusIndicatorKey++;
    });

    final nx = (pos.dx / constraints.maxWidth).clamp(0.0, 1.0);
    final ny = (pos.dy / constraints.maxHeight).clamp(0.0, 1.0);

    unawaited(
      _runtime.webRtcService?.remeterAndLock(
        point: math.Point<double>(nx, ny),
      ),
    );
  }

  void _showStationToast(
    String message, {
    bool isError = false,
    bool isSuccess = false,
    Duration duration = const Duration(seconds: 2),
    IconData? icon,
  }) {
    if (!mounted) return;
    final Color bg = isError
        ? const Color(0xFFC62828)
        : isSuccess
            ? const Color(0xFF2E7D32)
            : const Color(0xFF1565C0);
    final IconData defaultIcon = isError
        ? Icons.error_outline_rounded
        : isSuccess
            ? Icons.check_circle_outline_rounded
            : Icons.info_outline_rounded;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          backgroundColor: bg,
          duration: duration,
          content: Row(
            children: [
              Icon(icon ?? defaultIcon, color: Colors.white, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
  }

  Future<void> _toggleCamera() async {
    if (_cameraSwitching) return;
    setState(() => _cameraSwitching = true);
    final enableCamera = !_runtime.cameraEnabled;
    try {
      if (enableCamera) {
        // Foreground service is required before Android allows camera capture
        // to continue while the app is in background.
        await CameraStationForegroundService.start(
          cameraId: widget.identity.cameraId,
          courtId: widget.identity.courtId,
        );
      }

      await _runtime.setCameraEnabled(enableCamera);

      if (enableCamera) _showRtspWarningIfNeeded();

      if (!enableCamera) {
        // The camera track has been released; remove the persistent
        // "camera active" notification as well.
        await CameraStationForegroundService.stop();
      }
    } catch (error) {
      if (enableCamera && !_runtime.cameraEnabled) {
        // Do not leave a misleading foreground notification when opening the
        // camera failed.
        try {
          await CameraStationForegroundService.stop();
        } catch (_) {}
      }
      if (mounted) {
        _showStationToast(
          appText(
            context,
            'Không thể chuyển đổi trạng thái camera lúc này. Vui lòng thử lại sau.',
            'Cannot switch camera state right now. Please try again shortly.',
          ),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _cameraSwitching = false);
    }
  }

  Future<void> _toggleScreenDim() async {
    if (_screenDimSwitching) return;

    final dimmed = !_screenDimmed;
    setState(() => _screenDimSwitching = true);
    try {
      await StationDisplayService.setDimmed(dimmed);
      if (mounted) setState(() => _screenDimmed = dimmed);
    } catch (error) {
      if (mounted) {
        _showStationToast(
          appText(
            context,
            'Không thể điều chỉnh độ sáng màn hình. Vui lòng kiểm tra quyền hệ thống.',
            'Cannot adjust screen brightness. Please check system permissions.',
          ),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _screenDimSwitching = false);
    }
  }

  Future<void> _quickSelectZoom(double target) async {
    final webRtc = _runtime.webRtcService;
    if (webRtc == null) return;

    final willSwitchHardware = (target < 0.95 &&
            !webRtc.isCurrentUltraWide &&
            webRtc.ultraWideCamera != null &&
            webRtc.activeCameraId != webRtc.ultraWideCamera!.id) ||
        (target >= 0.95 &&
            webRtc.isCurrentUltraWide &&
            webRtc.mainBackCamera != null &&
            webRtc.activeCameraId != webRtc.mainBackCamera!.id) ||
        (webRtc.currentFacingMode == 'user');

    if (willSwitchHardware) {
      setState(() => _lensSwitching = true);
    }
    try {
      if (target < 0.95) {
        if (webRtc.hasUltraWideCamera) {
          await _runtime.switchToLensMode('ultra_wide');
          final actualRatio = webRtc.ultraWideZoomRatio;
          await _runtime.setCameraZoom(actualRatio);
          if (mounted) {
            setState(() => _zoomValue = actualRatio);
          }
        } else {
          await _runtime.setCameraZoom(target);
          if (mounted) setState(() => _zoomValue = webRtc.cameraZoom);
        }
      } else if (target >= 0.95 && target < 1.5) {
        if (webRtc.isCurrentUltraWide || webRtc.currentFacingMode == 'user') {
          await _runtime.switchToLensMode('wide');
        }
        await _runtime.setCameraZoom(1.0);
        if (mounted) setState(() => _zoomValue = 1.0);
      } else if (target >= 1.5) {
        if (webRtc.isCurrentUltraWide || webRtc.currentFacingMode == 'user') {
          await _runtime.switchToLensMode('wide');
        }
        await _runtime.setCameraZoom(target);
        if (mounted) setState(() => _zoomValue = target);
      }
    } catch (e) {
      debugPrint('[CAMERA] Quick select zoom error: $e');
    } finally {
      if (willSwitchHardware && mounted) {
        setState(() => _lensSwitching = false);
      }
    }
  }

  void _changeZoom(double value) {
    setState(() => _zoomValue = value);
    _zoomDebounce?.cancel();
    _zoomDebounce = Timer(const Duration(milliseconds: 60), () async {
      final webRtc = _runtime.webRtcService;
      if (webRtc == null) return;
      try {
        final willSwitchHardwareToUW = value < 0.95 &&
            !webRtc.isCurrentUltraWide &&
            webRtc.ultraWideCamera != null &&
            webRtc.activeCameraId != webRtc.ultraWideCamera!.id;
        final willSwitchHardwareToWide = value >= 0.95 &&
            webRtc.isCurrentUltraWide &&
            webRtc.mainBackCamera != null &&
            webRtc.activeCameraId != webRtc.mainBackCamera!.id;

        if (willSwitchHardwareToUW) {
          setState(() => _lensSwitching = true);
          try {
            await _runtime.switchToLensMode('ultra_wide');
          } finally {
            if (mounted) setState(() => _lensSwitching = false);
          }
        } else if (willSwitchHardwareToWide) {
          setState(() => _lensSwitching = true);
          try {
            await _runtime.switchToLensMode('wide');
          } finally {
            if (mounted) setState(() => _lensSwitching = false);
          }
        }
        await _runtime.setCameraZoom(value);
        if (mounted) setState(() => _zoomValue = value);
      } catch (error) {
        debugPrint('[CAMERA] Cannot set zoom: $error');
      }
    });
  }

  void _showRtspWarningIfNeeded() {
    final webRtc = _runtime.webRtcService;
    if (webRtc == null || !webRtc.rtspSupported) return;
    final error = webRtc.rtspError;
    if (!mounted || error == null || error == _lastShownRtspError) return;
    _lastShownRtspError = error;
    _showStationToast(
      appText(
        context,
        'Camera vẫn ghi hình bình thường. Đường truyền live đang thử kết nối lại.',
        'Camera is recording normally. Live stream is attempting to reconnect.',
      ),
      icon: Icons.info_outline_rounded,
    );
  }

  Future<void> _switchCameraLens() async {
    if (_lensSwitching || !_cameraReady) return;
    setState(() => _lensSwitching = true);
    try {
      await _runtime.switchCamera();
      if (mounted) {
        final webRtc = _runtime.webRtcService;
        final isUser = webRtc?.currentFacingMode == 'user';
        final msg = isUser
            ? appText(context, 'Đã chuyển sang Camera trước', 'Switched to front camera')
            : appText(context, 'Đã chuyển sang Camera sau', 'Switched to rear camera');
        _showStationToast(
          msg,
          icon: isUser ? Icons.person_rounded : Icons.camera_rear_rounded,
          duration: const Duration(seconds: 1),
        );
      }
    } catch (error) {
      debugPrint('[CAMERA] Bỏ qua yêu cầu đổi camera: $error');
    } finally {
      if (mounted) {
        setState(() {
          _lensSwitching = false;
          _zoomValue = null;
        });
      }
    }
  }

  // ============================================================
  // INIT & LIFECYCLE
  // ============================================================

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cameraQuarterTurns = _runtime.cameraQuarterTurns;

    _runtimeSubscription = _runtime.stateChanges.listen((_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _cameraQuarterTurns = _runtime.cameraQuarterTurns;
        if (!_lensSwitching &&
            (_zoomDebounce == null || !_zoomDebounce!.isActive)) {
          _zoomValue = _runtime.webRtcService?.cameraZoom;
        }
        final address = _runtime.lanAddress;
        final port =
            _runtime.cameraServer?.apiPort ?? CameraServer.defaultApiPort;
        _viewerAddress = address == null
            ? 'Chưa kết nối Wi-Fi/LAN'
            : 'http://$address:$port/viewer';
      });
      _showRtspWarningIfNeeded();
    });

    unawaited(_initScreenOrientation());
    unawaited(WakelockPlus.enable());
    if (Platform.isAndroid) {
      _platformChannel.setMethodCallHandler((call) async {
        if (call.method == 'onDisplayRotationChanged') {
          final args = call.arguments as Map<dynamic, dynamic>?;
          final effectiveRot = args?['effectiveRotation'] as int? ?? 0;
          debugPrint('[ROTATION] Native auto-sync rotation changed: $effectiveRot°');
          if (mounted) setState(() {});
        } else if (call.method == 'onPictureInPictureModeChanged') {
          final args = call.arguments as Map<dynamic, dynamic>?;
          final inPip = args?['inPip'] as bool? ?? false;
          if (mounted && _isInPipMode != inPip) {
            setState(() {
              _isInPipMode = inPip;
            });
          }
        }
      });
      unawaited(_checkInitialPipMode());
    }
    _whipSubscription =
        _runtime.whipPublisherService.onStateChanged.listen((_) {
      if (mounted) setState(() {});
    });
    _rtspSubscription =
        _runtime.rtspPublisherService.onStateChanged.listen((_) {
      if (mounted) setState(() {});
    });

    _initialize();
    _loadViewerAddress();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Đánh dấu app không còn foreground – LayoutBuilder không được cập nhật
      // _lastActiveOrientationLandscape nữa (tránh Keyguard ép portrait làm
      // sai giá trị).
      _appResumed = false;

      // Khóa cứng ở tầng Android native ngay lập tức khi vuốt thanh thông báo hoặc tắt màn hình
      if (Platform.isAndroid) {
        unawaited(_platformChannel.invokeMethod('lockOrientationForBackground'));
      }

      // Nếu người dùng đã chọn landscape/portrait cố định → luôn khóa theo
      // lựa chọn đó. Nếu auto → khóa theo hướng active cuối cùng.
      final List<DeviceOrientation> lockOrientations;
      if (_screenOrientation == 'landscape') {
        lockOrientations = orientationsForMode('landscape');
      } else if (_screenOrientation == 'portrait') {
        lockOrientations = orientationsForMode('portrait');
      } else {
        lockOrientations = orientationsForBackgroundLock(
          isCurrentLayoutLandscape: _lastActiveOrientationLandscape,
        );
      }
      unawaited(SystemChrome.setPreferredOrientations(lockOrientations));
      debugPrint(
        '[ORIENTATION] Background lock: mode=$_screenOrientation, '
        'lastActive=${_lastActiveOrientationLandscape ? "landscape" : "portrait"}',
      );
    } else if (state == AppLifecycleState.resumed) {
      _appResumed = true;
      if (Platform.isAndroid) {
        unawaited(_checkInitialPipMode());
        unawaited(
          _platformChannel.invokeMethod('setScreenOrientation', {
            'mode': _screenOrientation,
          }),
        );
      }
      // Khôi phục hướng màn hình theo cấu hình người dùng
      unawaited(_applyScreenOrientation(_screenOrientation));
    }

    if (!Platform.isIOS) return;
    if (state == AppLifecycleState.resumed) {
      unawaited(_resumeIosCapture());
      return;
    }
    // `inactive` is transient on iOS (Control Center, notification shade,
    // permission prompts and some system overlays). Stopping capture there
    // needlessly finalizes a segment and leaves a blue preview while the
    // camera is recreated. Only suspend once the app is actually hidden or
    // backgrounded.
    if (shouldSuspendIosCapture(state)) {
      unawaited(_suspendIosCapture());
    }
  }

  Future<void> _initScreenOrientation() async {
    try {
      final savedOrientation =
          await StationConfigService().loadScreenOrientation();
      if (!mounted) return;
      setState(() => _screenOrientation = savedOrientation);
      await _applyScreenOrientation(savedOrientation);
    } catch (error) {
      debugPrint('[ORIENTATION] Không thể tải hướng màn hình đã lưu: $error');
    }
  }

  Future<void> _applyScreenOrientation(String mode) async {
    try {
      await SystemChrome.setPreferredOrientations(orientationsForMode(mode));
      // Đồng bộ hướng màn hình sang tầng Android native để onPause() có thể
      // khóa orientation trước khi Keyguard can thiệp. MethodChannel async
      // của Flutter có thể đến chậm, nhưng Android native onPause() chạy
      // trước lifecycle callback nên sẽ dùng giá trị đã lưu.
      if (Platform.isAndroid) {
        unawaited(
          _platformChannel.invokeMethod('setScreenOrientation', {
            'mode': mode,
          }),
        );
      }
    } catch (error) {
      debugPrint('[ORIENTATION] Không thể thiết lập hướng màn hình: $error');
    }
  }

  Future<void> _checkInitialPipMode() async {
    if (!Platform.isAndroid) return;
    try {
      final inPip =
          await _platformChannel.invokeMethod<bool>('isInPictureInPictureMode');
      if (mounted && inPip != null && inPip != _isInPipMode) {
        setState(() {
          _isInPipMode = inPip;
        });
      }
    } catch (_) {}
  }

  Future<void> _toggleScreenOrientation() async {
    String nextMode;
    if (_screenOrientation == 'landscape') {
      nextMode = 'portrait';
    } else if (_screenOrientation == 'portrait') {
      nextMode = 'auto';
    } else {
      nextMode = 'landscape';
    }
    await _setScreenOrientation(nextMode);
  }

  Future<void> _setScreenOrientation(String mode) async {
    setState(() => _screenOrientation = mode);
    try {
      await StationConfigService().saveScreenOrientation(mode);
      await _applyScreenOrientation(mode);
    } catch (error) {
      debugPrint('[ORIENTATION] Không thể lưu hướng màn hình: $error');
    }

    if (!mounted) return;
    final msg = mode == 'landscape'
        ? appText(
            context,
            'Đã khóa hướng màn hình ngang',
            'Locked landscape orientation',
          )
        : mode == 'portrait'
            ? appText(
                context,
                'Đã khóa hướng màn hình dọc',
                'Locked portrait orientation',
              )
            : appText(
                context,
                'Đã bật tự động xoay màn hình',
                'Auto-rotate screen enabled',
              );
    _showStationToast(
      msg,
      icon: mode == 'landscape'
          ? Icons.screen_lock_landscape_rounded
          : mode == 'portrait'
              ? Icons.screen_lock_portrait_rounded
              : Icons.screen_rotation_rounded,
      duration: const Duration(seconds: 2),
    );
  }

  Future<void> _suspendIosCapture() async {
    try {
      await _runtime.suspendForIosBackground();
    } catch (error) {
      debugPrint('[LIFECYCLE] Không thể chốt camera iOS: $error');
    }
  }

  Future<void> _resumeIosCapture() async {
    try {
      await _runtime.resumeFromIosBackground();
    } catch (error) {
      debugPrint('[LIFECYCLE] Không thể phục hồi camera iOS: $error');
    }
  }

  Future<void> _loadViewerAddress() async {
    var result = 'Chưa kết nối Wi-Fi/LAN';
    final apiPort =
        _runtime.cameraServer?.apiPort ?? CameraServer.defaultApiPort;
    try {
      if (Platform.isIOS) {
        final wifiIp = await _platformChannel
            .invokeMethod<String>('getWifiIpAddress')
            .timeout(const Duration(seconds: 2));
        if (wifiIp != null && wifiIp.isNotEmpty) {
          result = 'http://$wifiIp:$apiPort/viewer';
        }
        if (mounted) setState(() => _viewerAddress = result);
        return;
      }
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final addresses = interfaces
          .expand((interface) => interface.addresses)
          .where((address) => !address.isLoopback && !address.isLinkLocal)
          .toList();
      if (addresses.isNotEmpty) {
        final localAddresses = addresses.where(
          (address) =>
              address.address.startsWith('192.168.') ||
              address.address.startsWith('10.') ||
              address.address.startsWith('172.'),
        );
        final address =
            (localAddresses.isNotEmpty ? localAddresses.first : addresses.first)
                .address;
        result = 'http://$address:$apiPort/viewer';
      }
    } catch (_) {
      result = 'Không đọc được địa chỉ IP';
    }
    if (mounted) {
      setState(() {
        _viewerAddress = result;
      });
    }
  }

  Future<void> _reconnectNetwork() async {
    if (_runtime.networkRecovering) return;
    try {
      await _runtime.reconnectNetworkServices();
      if (!mounted) return;
      _showStationToast(
        appText(
          context,
          _runtime.lanAddress == null
              ? 'Chưa nhận diện IP mạng. Quá trình ghi hình vẫn an toàn và sẽ tự kết nối khi có Wi-Fi.'
              : 'Đã làm mới kết nối mạng thành công. Quá trình ghi hình vẫn an toàn.',
          _runtime.lanAddress == null
              ? 'No network IP yet. Recording continues and will reconnect automatically.'
              : 'Network connection refreshed successfully. Recording is safe.',
        ),
        isSuccess: _runtime.lanAddress != null,
      );
    } catch (error) {
      if (!mounted) return;
      _showStationToast(
        appText(
          context,
          'Không thể làm mới kết nối mạng. Vui lòng kiểm tra lại sóng Wi-Fi hoặc dây mạng.',
          'Cannot refresh network. Please check Wi-Fi or LAN connection.',
        ),
        isError: true,
      );
    }
  }

  // ============================================================
  // INITIALIZE
  // ============================================================

  Future<void> _initialize() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      debugPrint(
        '[STATION] INITIALIZE '
        '${widget.identity.courtId}/'
        '${widget.identity.cameraId}',
      );

      await CameraStationForegroundService.start(
        cameraId: widget.identity.cameraId,
        courtId: widget.identity.courtId,
      );

      if (!mounted) {
        await _shutdownStation();
        return;
      }

      await _runtime.initialize(
        courtId: widget.identity.courtId,
        cameraId: widget.identity.cameraId,
        deviceId: widget.identity.deviceId,
      );

      unawaited(_runtime.setCameraQuarterTurns(_cameraQuarterTurns));

      _showRtspWarningIfNeeded();

      if (!mounted) {
        await _shutdownStation();
        return;
      }

      setState(() {
        _loading = false;
        _error = null;
      });
    } catch (error, stackTrace) {
      debugPrint('[STATION] INIT ERROR: $error');

      debugPrintStack(stackTrace: stackTrace);

      try {
        await CameraStationForegroundService.stop();
      } catch (stopError) {
        debugPrint('[STATION] Không thể dừng foreground service: $stopError');
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _loading = false;
        _error = userFacingError(error);
      });
    }
  }

  // ============================================================
  // RETRY
  // ============================================================

  Future<void> _retry() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      await _runtime.restart(
        cameraId: widget.identity.cameraId,
        courtId: widget.identity.courtId,
        deviceId: widget.identity.deviceId,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _loading = false;
        _error = null;
      });
    } catch (error, stackTrace) {
      debugPrint('[STATION] RETRY ERROR: $error');

      debugPrintStack(stackTrace: stackTrace);

      try {
        await CameraStationForegroundService.stop();
      } catch (stopError) {
        debugPrint('[STATION] Không thể dừng foreground service: $stopError');
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _loading = false;
        _error = userFacingError(error);
      });
    }
  }

  String _formatLiveDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  void _openLiveStreamScreen() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LiveStreamScreen(
          runtime: _runtime,
          configService: StationConfigService(),
        ),
      ),
    );
  }

  // ============================================================
  // SETTINGS
  // ============================================================

  Future<void> _openSettings() async {
    final updated = await Navigator.of(context).push<StationIdentity>(
      MaterialPageRoute(
        builder: (setupContext) {
          return SetupScreen(
            initialIdentity: widget.identity,
            persistOnSave: false,
            isLandscape: true,
            onConfigured: (identity) {
              Navigator.of(setupContext).pop(identity);
            },
          );
        },
      ),
    );

    if (mounted) {
      unawaited(_applyScreenOrientation(_screenOrientation));
    }

    if (updated == null || !mounted) {
      return;
    }
    final newIdentity = updated;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final media = MediaQuery.of(dialogContext);
        final landscape = media.orientation == Orientation.landscape;
        final compactHeight = media.size.height < 480;
        final identityDetails = landscape
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _ConfigLine(
                          title: appText(context, 'Tên', 'Name'),
                          value: newIdentity.cameraName,
                        ),
                        _ConfigLine(
                          title: 'Camera',
                          value: newIdentity.cameraId,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _ConfigLine(
                          title: appText(context, 'Sân', 'Court'),
                          value: _courtLabel(newIdentity.courtId),
                        ),
                        _ConfigLine(
                          title: appText(context, 'Vị trí', 'Position'),
                          value: newIdentity.cameraPosition,
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ConfigLine(
                    title: appText(context, 'Tên', 'Name'),
                    value: newIdentity.cameraName,
                  ),
                  _ConfigLine(title: 'Camera', value: newIdentity.cameraId),
                  _ConfigLine(
                    title: appText(context, 'Sân', 'Court'),
                    value: _courtLabel(newIdentity.courtId),
                  ),
                  _ConfigLine(
                    title: appText(context, 'Vị trí', 'Position'),
                    value: newIdentity.cameraPosition,
                  ),
                ],
              );
        return AlertDialog(
          scrollable: true,
          insetPadding: EdgeInsets.symmetric(
            horizontal: landscape ? 32 : 20,
            vertical: landscape ? 12 : 24,
          ),
          iconPadding: EdgeInsets.fromLTRB(20, compactHeight ? 12 : 20, 20, 4),
          titlePadding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          contentPadding: EdgeInsets.fromLTRB(
            landscape ? 18 : 20,
            0,
            landscape ? 18 : 20,
            compactHeight ? 8 : 14,
          ),
          actionsPadding: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            compactHeight ? 10 : 16,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          icon: Icon(
            Icons.settings_rounded,
            color: const Color(0xFF1565C0),
            size: compactHeight ? 30 : 38,
          ),
          title: Text(
            appText(context, 'ÁP DỤNG CẤU HÌNH MỚI?', 'APPLY NEW SETTINGS?'),
            textAlign: TextAlign.center,
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                appText(
                  context,
                  'Camera Station sẽ khởi động lại dịch vụ với cấu hình mới.',
                  'Camera Station will restart its services with the new settings.',
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: compactHeight ? 8 : 14),
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(compactHeight ? 9 : 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF4F6F9),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: identityDetails,
              ),
            ],
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            OutlinedButton(
              onPressed: () {
                Navigator.pop(dialogContext, false);
              },
              child: Text(appText(context, 'HỦY', 'CANCEL')),
            ),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(dialogContext, true);
              },
              icon: const Icon(Icons.check_rounded),
              label: Text(appText(context, 'ÁP DỤNG', 'APPLY')),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      debugPrint(
        '[CONFIG] APPLY '
        '${newIdentity.courtId}/'
        '${newIdentity.cameraId}',
      );

      await _runtime.stop();

      await StationConfigService().saveIdentity(newIdentity);

      await CameraStationForegroundService.start(
        cameraId: newIdentity.cameraId,
        courtId: newIdentity.courtId,
      );

      await _runtime.initialize(
        cameraId: newIdentity.cameraId,
        courtId: newIdentity.courtId,
        deviceId: newIdentity.deviceId,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _loading = false;
        _error = null;
      });

      widget.onIdentityChanged(newIdentity);
    } catch (error, stackTrace) {
      debugPrint(
        '[CONFIG] APPLY ERROR: '
        '$error',
      );

      debugPrintStack(stackTrace: stackTrace);

      try {
        await CameraStationForegroundService.stop();
      } catch (stopError) {
        debugPrint('[CONFIG] Không thể dừng foreground service: $stopError');
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _loading = false;
        _error = userFacingError(error);
      });
    }
  }

  Future<void> _openVideoStorage() async {
    final recording = _runtime.recordingService;
    if (recording == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => VideoStorageScreen(
          recordingService: recording,
          viewerAddress: _viewerAddress,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openResolutionPicker() async {
    if (!_cameraReady || _runtime.profileSwitching) return;
    try {
      await _runtime.refreshSupportedResolutionProfiles();
    } catch (error) {
      debugPrint('[CAMERA] Cannot refresh camera profiles: $error');
    }
    if (!mounted || !_cameraReady || _runtime.profileSwitching) return;
    final selected = await showModalBottomSheet<CameraResolutionProfile>(
      context: context,
      backgroundColor: const Color(0xFF11161D),
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: _buildResolutionPicker,
    );
    if (!mounted) return;
    _runtime.dismissCooledDownNotice();
    if (selected == null) return;
    try {
      await _runtime.setResolutionProfile(selected);
      if (mounted) {
        setState(() {
          _zoomValue = _runtime.webRtcService?.cameraZoom;
        });
        if (_runtime.thermalUserOverride) {
          _showStationToast(
            appText(
              context,
              'Đã áp dụng ${selected.title}. Chế độ chất lượng được duy trì theo lựa chọn của bạn.',
              'Applied ${selected.title}. Quality maintained per your selection.',
            ),
            icon: Icons.check_circle_rounded,
          );
        }
      }
    } catch (error) {
      if (mounted) {
        _showStationToast(
          appText(
            context,
            'Không thể đổi chất lượng camera lúc này. Vui lòng thử lại sau vài giây.',
            'Cannot change camera quality right now. Please try again shortly.',
          ),
          isError: true,
        );
      }
    }
  }

  Widget _buildResolutionPicker(BuildContext sheetContext) {
    return StatefulBuilder(
      builder: (context, setSheetState) {
        final media = MediaQuery.of(sheetContext);
        final profiles = _runtime.supportedResolutionProfiles;
        final landscape = media.orientation == Orientation.landscape;
        final columns = landscape && media.size.width >= 560 ? 2 : 1;
        final rows = (profiles.length / columns).ceil();
        final hasThermalBanner =
            (_runtime.temperatureC != null && _runtime.temperatureC! >= 38.0) ||
            _runtime.justCooledDown;
        final contentHeight = 58.0 +
            (rows * 88.0) +
            ((rows - 1) * 10.0) +
            (hasThermalBanner ? 52.0 : 16.0);
        final maximumHeight = (media.size.height * (landscape ? 0.85 : 0.65)).clamp(
          240.0,
          480.0,
        );
        final sheetHeight = contentHeight < maximumHeight
            ? contentHeight
            : maximumHeight;
        final isLocked = _runtime.resolutionLocked;

        return SafeArea(
          child: SizedBox(
            height: sheetHeight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          appText(context, 'CHẤT LƯỢNG CAMERA', 'CAMERA QUALITY'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: () async {
                            final nextLock = !_runtime.resolutionLocked;
                            final currentTitle = _runtime.resolutionProfile.title;
                            final lockMsg = nextLock
                                ? appText(
                                    sheetContext,
                                    'Đã khóa chế độ $currentTitle. Camera sẽ giữ nguyên chất lượng này kể cả khi máy nóng.',
                                    'Locked $currentTitle. Camera will remain at this quality even when device is hot.',
                                  )
                                : appText(
                                    sheetContext,
                                    'Đã mở khóa chế độ phân giải. Camera sẽ tự động điều chỉnh khi máy nóng.',
                                    'Resolution mode unlocked. Camera will automatically adjust when hot.',
                                  );
                            await _runtime.setResolutionLocked(nextLock);
                            if (!sheetContext.mounted) return;
                            setSheetState(() {});
                            if (mounted) {
                              setState(() {});
                              _showStationToast(
                                lockMsg,
                                icon: nextLock
                                    ? Icons.lock_rounded
                                    : Icons.lock_open_rounded,
                              );
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: isLocked
                                  ? const Color(0xFFE65100).withValues(alpha: 0.25)
                                  : Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: isLocked
                                    ? const Color(0xFFFF9800)
                                    : Colors.white24,
                                width: 1.2,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  isLocked
                                      ? Icons.lock_rounded
                                      : Icons.lock_open_rounded,
                                  size: 14,
                                  color: isLocked
                                      ? const Color(0xFFFFB74D)
                                      : Colors.white70,
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  isLocked
                                      ? appText(context, 'Đã khóa', 'Locked')
                                      : appText(context, 'Khóa chế độ', 'Lock mode'),
                                  style: TextStyle(
                                    color: isLocked
                                        ? const Color(0xFFFFB74D)
                                        : Colors.white70,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (hasThermalBanner) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: _runtime.justCooledDown
                            ? const Color(0xFF00C853).withValues(alpha: 0.15)
                            : _runtime.thermalWarning
                                ? const Color(0xFFC62828).withValues(alpha: 0.18)
                                : const Color(0xFFE65100).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: _runtime.justCooledDown
                              ? const Color(0xFF00E676).withValues(alpha: 0.35)
                              : _runtime.thermalWarning
                                  ? const Color(0xFFEF5350).withValues(alpha: 0.35)
                                  : const Color(0xFFFF9800).withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _runtime.justCooledDown
                                ? Icons.ac_unit_rounded
                                : _runtime.thermalWarning
                                    ? Icons.whatshot_rounded
                                    : Icons.thermostat_rounded,
                            size: 15,
                            color: _runtime.justCooledDown
                                ? const Color(0xFF69F0AE)
                                : _runtime.thermalWarning
                                    ? const Color(0xFFFF8A80)
                                    : const Color(0xFFFFB74D),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _runtime.justCooledDown
                                  ? appText(
                                      context,
                                      'Thiết bị đã hạ nhiệt an toàn (${_runtime.temperatureC?.toStringAsFixed(0) ?? ''}°C). Bạn có thể chọn lại độ phân giải mong muốn.',
                                      'Device has cooled down (${_runtime.temperatureC?.toStringAsFixed(0) ?? ''}°C). You can re-select your preferred quality.',
                                    )
                                  : _runtime.thermalWarning
                                      ? appText(
                                          context,
                                          'Thiết bị đang nóng (${_runtime.temperatureC?.toStringAsFixed(0)}°C). Bạn vẫn có thể chủ động chọn độ phân giải theo ý muốn.',
                                          'Device is warm (${_runtime.temperatureC?.toStringAsFixed(0)}°C). You can still choose your preferred quality.',
                                        )
                                      : appText(
                                          context,
                                          'Nhiệt độ hiện tại: ${_runtime.temperatureC?.toStringAsFixed(0)}°C.',
                                          'Current temperature: ${_runtime.temperatureC?.toStringAsFixed(0)}°C.',
                                        ),
                              style: TextStyle(
                                color: _runtime.justCooledDown
                                    ? const Color(0xFFB9F6CA)
                                    : _runtime.thermalWarning
                                        ? const Color(0xFFFFCDD2)
                                        : const Color(0xFFFFE0B2),
                                fontSize: 11.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Expanded(
                    child: GridView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: profiles.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                        mainAxisExtent: 88,
                      ),
                      itemBuilder: (context, index) {
                        final profile = profiles[index];
                        final active = profile == _runtime.resolutionProfile;
                        final displayProfile = profile;
                        return Material(
                          color: active
                              ? const Color(0xFF1565C0)
                              : isLocked
                                  ? const Color(0xFF15181E)
                                  : const Color(0xFF1A2028),
                          borderRadius: BorderRadius.circular(14),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: active
                                ? null
                                : () {
                                    if (isLocked) {
                                      _showStationToast(
                                        appText(
                                          context,
                                          'Chế độ phân giải đang khóa. Vui lòng bấm nút mở khóa ở góc trên để đổi.',
                                          'Resolution mode is locked. Please unlock using the top button to change.',
                                        ),
                                        icon: Icons.lock_rounded,
                                      );
                                      return;
                                    }
                                    Navigator.pop(sheetContext, profile);
                                  },
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: active
                                      ? const Color(0xFF64B5F6)
                                      : Colors.white.withValues(alpha: 0.08),
                                  width: active ? 1.5 : 1.0,
                                ),
                                boxShadow: active
                                    ? [
                                        BoxShadow(
                                          color: const Color(0xFF1565C0)
                                              .withValues(alpha: 0.35),
                                          blurRadius: 8,
                                          offset: const Offset(0, 2),
                                        ),
                                      ]
                                    : null,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      active
                                          ? Icons.check_circle_rounded
                                          : isLocked
                                              ? Icons.lock_outline_rounded
                                              : Icons.radio_button_unchecked_rounded,
                                      color: active
                                          ? Colors.white
                                          : isLocked
                                              ? Colors.white24
                                              : Colors.white38,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  displayProfile.title,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color: isLocked && !active
                                                        ? Colors.white54
                                                        : Colors.white,
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 6,
                                                  vertical: 2,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: displayProfile.fps >=
                                                          50
                                                      ? const Color(0xFF00E676)
                                                          .withValues(
                                                              alpha: 0.18)
                                                      : Colors.white
                                                          .withValues(
                                                              alpha: 0.08),
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                  border: Border.all(
                                                    color: displayProfile.fps >=
                                                            50
                                                        ? const Color(
                                                                0xFF00E676)
                                                            .withValues(
                                                                alpha: 0.5)
                                                        : Colors.white24,
                                                    width: 0.8,
                                                  ),
                                                ),
                                                child: Text(
                                                  '${displayProfile.fps} FPS',
                                                  style: TextStyle(
                                                    color: displayProfile.fps >=
                                                            50
                                                        ? const Color(
                                                            0xFF69F0AE)
                                                        : Colors.white70,
                                                    fontSize: 10.5,
                                                    fontWeight:
                                                        FontWeight.w800,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            '${displayProfile.width} × ${displayProfile.height}  •  '
                                            '${(displayProfile.bitrate / 1000000).toStringAsFixed(1)} Mbps',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: isLocked && !active
                                                  ? Colors.white30
                                                  : Colors.white60,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _handleResolutionPressed() {
    _openResolutionPicker();
  }

  // ============================================================
  // COURT LABEL
  // ============================================================

  String _courtLabel(String courtId) {
    final match = RegExp(r'(\d+)$').firstMatch(courtId);

    if (match == null) {
      return courtId;
    }

    final number = int.tryParse(match.group(1) ?? '');

    if (number == null) {
      return courtId;
    }

    return 'SÂN $number';
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  Future<void> _shutdownStation() async {
    try {
      await _runtime.stop();
    } catch (error, stackTrace) {
      debugPrint('[STATION] Không thể dừng camera runtime: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      try {
        await CameraStationForegroundService.stop();
      } catch (error, stackTrace) {
        debugPrint('[STATION] Không thể dừng foreground service: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _runtimeSubscription?.cancel();
    _whipSubscription?.cancel();
    _rtspSubscription?.cancel();
    _zoomDebounce?.cancel();
    if (_screenDimmed) {
      unawaited(StationDisplayService.setDimmed(false));
    }
    // Khôi phục hướng xoay dọc (portrait) khi thoát khỏi màn hình Station về màn hình thiết lập
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]),
    );
    if (Platform.isAndroid) {
      unawaited(
        _platformChannel.invokeMethod('setScreenOrientation', {
          'mode': 'portrait',
        }),
      );
    }
    super.dispose();
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return _buildLoading();
    }

    if (_error != null) {
      return _buildError();
    }

    return _buildStation();
  }

  // ============================================================
  // LOADING
  // ============================================================

  Widget _buildLoading() {
    return Scaffold(
      backgroundColor: const Color(0xFF05070A),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/vnvar_logo.png',
                width: 240,
                height: 54,
                fit: BoxFit.contain,
              ),
              const SizedBox(height: 28),
              const CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2.6,
              ),
              const SizedBox(height: 18),
              Text(
                appText(
                  context,
                  'ĐANG KHỞI ĐỘNG CAMERA STATION...',
                  'STARTING CAMERA STATION...',
                ),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // ERROR
  // ============================================================

  String _formatErrorMessage(BuildContext context, String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return appText(
        context,
        'Không thể khởi động hệ thống camera. Vui lòng kiểm tra quyền truy cập camera và thử lại.',
        'Unable to initialize camera system. Please check camera permissions and try again.',
      );
    }
    final lower = raw.toLowerCase();
    if (lower.contains('permission') || lower.contains('quyền') || lower.contains('denied')) {
      return appText(
        context,
        'Ứng dụng chưa được cấp quyền truy cập Camera hoặc Micro. Vui lòng kiểm tra cài đặt thiết bị.',
        'Camera or Microphone permissions not granted. Please check device settings.',
      );
    }
    if (lower.contains('camera') &&
        (lower.contains('busy') ||
            lower.contains('bận') ||
            lower.contains('in use') ||
            lower.contains('locked'))) {
      return appText(
        context,
        'Camera đang bị ứng dụng khác sử dụng hoặc chưa sẵn sàng. Vui lòng thử lại sau vài giây.',
        'Camera is busy or in use by another app. Please try again shortly.',
      );
    }
    if (lower.contains('đã xảy ra lỗi không xác định') ||
        lower.contains('unknown error') ||
        lower.contains('bad state')) {
      return appText(
        context,
        'Đã xảy ra sự cố khi kết nối camera. Vui lòng bấm Thử lại để khôi phục.',
        'An issue occurred while connecting the camera. Please tap Try Again to recover.',
      );
    }
    return raw;
  }

  Widget _buildError() {
    return Scaffold(
      backgroundColor: const Color(0xFF05070A),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxWidth: 460),
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: const Color(0xFF11161D),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.videocam_off_rounded,
                      color: Colors.redAccent,
                      size: 48,
                    ),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    appText(context, 'LỖI KHỞI ĐỘNG CAMERA', 'CAMERA STATION ERROR'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _formatErrorMessage(context, _error),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 26),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: _retry,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(
                        appText(context, 'THỬ LẠI', 'TRY AGAIN'),
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // STATION
  // ============================================================

  Widget _buildStation() {
    final webRtc = _runtime.webRtcService;
    final renderer = webRtc?.localRenderer;
    // Match the phone's Camera app: mirror only the local front-camera
    // preview for intuitive movement. Recording, RTSP and tablet video consume
    // the original track and therefore remain in the real capture direction.
    final mirrorPreview = webRtc?.currentFacingMode == 'user';

    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          // ----------------------------------------------------
          // RESPONSIVE BREAKPOINTS
          // Scale paddings / icon sizes down on small phones and
          // short (landscape) viewports so nothing overflows.
          // ----------------------------------------------------
          final narrow = constraints.maxWidth < 380;
          final short = constraints.maxHeight < 560;
          final compact = narrow || short;
          final landscape = constraints.maxWidth > constraints.maxHeight;
          final isPip = _isInPipMode || (constraints.maxHeight < 240);
          if (_isCurrentLayoutLandscape != landscape) {
            _isCurrentLayoutLandscape = landscape;
            // Chỉ cập nhật _lastActiveOrientationLandscape khi app đang
            // foreground. Khi Android Keyguard ép portrait (tắt màn hình),
            // LayoutBuilder rebuild trước khi lifecycle callback chạy.
            // Nếu cập nhật ở đây, giá trị sẽ bị đổi thành portrait → khóa
            // sai hướng.
            if (_appResumed) {
              _lastActiveOrientationLandscape = landscape;
            }
            if (_screenOrientation == 'auto' && _appResumed) {
              unawaited(
                StationConfigService().saveScreenOrientation(
                  landscape ? 'landscape' : 'portrait',
                ),
              );
            }
          }
          // Scrim height scales with the viewport instead of being a
          // fixed 180px — on short screens a fixed height made the
          // top + bottom scrims overlap and blanket the whole preview
          // in black. Capped so it never exceeds ~22% of the height
          // and top+bottom together leave the middle clear.
          return Stack(
            fit: StackFit.expand,
            children: [
              // ==============================================
              // CAMERA PREVIEW
              // ==============================================
              if (renderer != null && _cameraReady)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) => _handlePreviewTap(details, constraints),
                  child: RotatedBox(
                    quarterTurns: _cameraQuarterTurns,
                    child: RTCVideoView(
                      renderer,
                      // Keep the native rendering surface alive while Flutter
                      // relays out portrait/landscape. Re-keying this view on
                      // every rotation destroys the surface and can leave iOS
                      // showing the last frame until the camera is restarted.
                      key: const ValueKey('camera-preview'),
                      mirror: mirrorPreview,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                    ),
                  ),
                )
              else
                const ColoredBox(
                  color: Colors.black,
                  child: Center(
                    child: Icon(
                      Icons.videocam_off_rounded,
                      color: Colors.white24,
                      size: 80,
                    ),
                  ),
                ),

              // Smooth transition shutter mask during camera/lens switch
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 180),
                    opacity: (_lensSwitching || _cameraSwitching) ? 0.82 : 0.0,
                    child: Container(
                      color: Colors.black,
                      child: const Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // ==============================================
              // TOP BAR (identity + primary actions + live status + toast)
              // ==============================================
              if (!isPip)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        compact ? 10 : 14,
                        compact ? 8 : 12,
                        compact ? 10 : 14,
                        0,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _StationHeader(
                            identity: widget.identity,
                            courtLabel: _courtLabel(widget.identity.courtId),
                            recording: _recording,
                            thermalWarning: _runtime.thermalWarning,
                            temperatureC: _runtime.temperatureC,
                            thermalUserOverride: _runtime.thermalUserOverride,
                            justCooledDown: _runtime.justCooledDown,
                            onDismissCooledDown: _runtime.dismissCooledDownNotice,
                            compact: compact,
                            landscape: landscape,
                            resolutionProfile: _runtime.resolutionProfile,
                            resolutionSwitching: _runtime.profileSwitching,
                            resolutionLocked: _runtime.resolutionLocked,
                            whipLive: _runtime.isLiveStreaming,
                            onVideoStorage: _openVideoStorage,
                            onResolution: _handleResolutionPressed,
                            onSettings: _openSettings,
                            onWhipLive: _openLiveStreamScreen,
                          ),
                          if (_runtime.isLiveStreaming) ...[
                            SizedBox(height: compact ? 6 : 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.red.withValues(alpha: 0.85),
                                borderRadius: BorderRadius.circular(14),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.red.withValues(alpha: 0.4),
                                    blurRadius: 8,
                                    spreadRadius: 1,
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.circle, color: Colors.white, size: 8),
                                  const SizedBox(width: 6),
                                  Text(
                                    'LIVE (${_runtime.rtspPublisherService.isLive ? "RTSP" : "WHIP"}) · ${_formatLiveDuration(_runtime.rtspPublisherService.isLive ? _runtime.rtspPublisherService.liveDuration : _runtime.whipPublisherService.liveDuration)}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 0.3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          if ((_runtime.thermalWarning || _runtime.justCooledDown) && !landscape) ...[
                            SizedBox(height: compact ? 6 : 8),
                            _ThermalToast(
                              compact: compact,
                              landscape: landscape,
                              temperatureC: _runtime.temperatureC,
                              userOverride: _runtime.thermalUserOverride,
                              isCooledDown: _runtime.justCooledDown,
                              onTap: _openResolutionPicker,
                              onDismiss: _runtime.dismissCooledDownNotice,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),

              // ==============================================
              // RIGHT-SIDE CAMERA CONTROLS
              // ==============================================
              if (!isPip)
                Positioned(
                right: compact ? 8 : 14,
                top: 0,
                bottom: 0,
                child: SafeArea(
                  child: Center(
                    child: _CameraControlDock(
                      compact: compact,
                      cameraReady: _cameraReady,
                      cameraEnabled: _runtime.cameraEnabled,
                      cameraSwitching: _cameraSwitching,
                      screenDimmed: _screenDimmed,
                      screenDimSwitching: _screenDimSwitching,
                      lensSwitching: _lensSwitching,
                      screenOrientation: _screenOrientation,
                      onSwitchLens: _cameraReady && !_lensSwitching
                          ? _switchCameraLens
                          : null,
                      onToggleCamera: _cameraSwitching ? null : _toggleCamera,
                      onToggleScreenDim: _screenDimSwitching
                          ? null
                          : _toggleScreenDim,
                      onToggleOrientation: _toggleScreenOrientation,
                    ),
                  ),
                ),
              ),

              // ==============================================
              // BOTTOM STATUS
              // ==============================================
              if (!isPip)
                Positioned(
                left: compact ? 8 : 14,
                right: compact ? 8 : 14,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  minimum: EdgeInsets.only(bottom: compact ? 10 : 14),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: landscape ? 440 : 520,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_runtime.lanAddress == null ||
                              _runtime.networkRecovering ||
                              _runtime.networkError != null)
                            _NetworkStatusBanner(
                              compact: compact,
                              connectedAddress: _runtime.lanAddress,
                              recovering: _runtime.networkRecovering,
                              hasError: _runtime.networkError != null,
                              onReconnect: _runtime.networkRecovering
                                  ? null
                                  : _reconnectNetwork,
                            ),
                          if (Platform.isIOS &&
                              (_runtime.lifecycleSuspended ||
                                  _runtime.lifecycleResuming ||
                                  _runtime.captureState == 'recovering'))
                            Container(
                              width: double.infinity,
                              margin: EdgeInsets.only(bottom: compact ? 6 : 8),
                              padding: EdgeInsets.symmetric(
                                horizontal: compact ? 10 : 12,
                                vertical: compact ? 6 : 8,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFF1565C0,
                                ).withValues(alpha: 0.94),
                                borderRadius: BorderRadius.circular(
                                  compact ? 10 : 12,
                                ),
                              ),
                              child: Text(
                                _runtime.lifecycleResuming ||
                                        _runtime.captureState == 'recovering'
                                    ? appText(
                                        context,
                                        'Đang khôi phục camera và ghi hình sau khi quay lại ứng dụng…',
                                        'Restoring camera and recording…',
                                      )
                                    : appText(
                                        context,
                                        'iOS đã tạm dừng camera khi ứng dụng ở nền. Hãy giữ Camera Station trên màn hình để ghi liên tục.',
                                        'iOS paused the camera in the background. Keep Camera Station visible for continuous recording.',
                                      ),
                                maxLines: compact ? 2 : 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: compact ? 11 : 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          if (_runtime.storageWarning)
                            Container(
                              width: double.infinity,
                              margin: EdgeInsets.only(bottom: compact ? 6 : 8),
                              padding: EdgeInsets.symmetric(
                                horizontal: compact ? 10 : 12,
                                vertical: compact ? 6 : 8,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.orange.withValues(alpha: 0.92),
                                borderRadius: BorderRadius.circular(
                                  compact ? 10 : 12,
                                ),
                              ),
                              child: Text(
                                appText(
                                  context,
                                  'Dung lượng lưu trữ thấp. Hệ thống sẽ dọn video cũ theo chính sách lưu trữ.',
                                  'Storage is low. Old videos will be cleaned according to the retention policy.',
                                ),
                                maxLines: compact ? 2 : 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.black,
                                  fontSize: compact ? 11 : 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          _BottomControlPanel(
                            compact: compact,
                            cameraReady: _cameraReady,
                            recording: _recording,
                            zoomSupported:
                                _cameraReady &&
                                (_runtime.webRtcService?.cameraZoomSupported ??
                                    false),
                            zoomValue:
                                _zoomValue ??
                                _runtime.webRtcService?.cameraZoom ??
                                1,
                            minimumZoom:
                                _runtime.webRtcService?.minimumCameraZoom ?? 1.0,
                            maximumZoom:
                                math.min(_runtime.webRtcService?.maximumCameraZoom ?? 5.0, 5.0),
                            hasUltraWide:
                                _runtime.webRtcService?.hasUltraWideCamera ?? false,
                            ultraWideRatio:
                                _runtime.webRtcService?.ultraWideZoomRatio ?? 0.5,
                            ultraWideLabel:
                                _runtime.webRtcService?.ultraWideLabel ?? '0.5×',
                            onZoomChanged: _changeZoom,
                            onQuickSelectZoom: _quickSelectZoom,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // ==============================================
              // PIP MODE MINIMAL STATUS OVERLAY
              // ==============================================
              if (isPip)
                Positioned(
                  top: 6,
                  left: 8,
                  right: 8,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_recording)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 2,
                              ),
                              margin: const EdgeInsets.only(right: 4),
                              decoration: BoxDecoration(
                                color: Colors.red.withValues(alpha: 0.85),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.circle, color: Colors.white, size: 6),
                                  SizedBox(width: 3),
                                  Text(
                                    'REC',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 9,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (_runtime.isLiveStreaming)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.blue.withValues(alpha: 0.85),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                'LIVE',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (_runtime.thermalWarning)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF2A1C08).withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: Colors.amber.withValues(alpha: 0.7),
                            ),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.warning_amber_rounded,
                                color: Colors.amber,
                                size: 10,
                              ),
                              SizedBox(width: 3),
                              Text(
                                '720p',
                                style: TextStyle(
                                  color: Colors.amber,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),

              // ==============================================
              // TAP-TO-FOCUS & REMETER INDICATOR
              // ==============================================
              if (_focusIndicatorPosition != null)
                _FocusIndicator(
                  key: ValueKey('focus-$_focusIndicatorKey'),
                  position: _focusIndicatorPosition!,
                  onDismissed: () {
                    if (mounted) {
                      setState(() => _focusIndicatorPosition = null);
                    }
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

class _FocusIndicator extends StatefulWidget {
  final Offset position;
  final VoidCallback onDismissed;

  const _FocusIndicator({
    super.key,
    required this.position,
    required this.onDismissed,
  });

  @override
  State<_FocusIndicator> createState() => _FocusIndicatorState();
}

class _FocusIndicatorState extends State<_FocusIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _scaleAnimation = Tween<double>(begin: 1.35, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.25, curve: Curves.easeOutCubic),
      ),
    );
    _opacityAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.65, 1.0, curve: Curves.easeIn),
      ),
    );
    _controller.forward().then((_) {
      if (mounted) widget.onDismissed();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const size = 64.0;
    return Positioned(
      left: widget.position.dx - size / 2,
      top: widget.position.dy - size / 2,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return Opacity(
              opacity: _opacityAnimation.value,
              child: Transform.scale(
                scale: _scaleAnimation.value,
                child: child,
              ),
            );
          },
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              border: Border.all(
                color: const Color(0xFFFFD54F),
                width: 1.5,
              ),
              borderRadius: BorderRadius.circular(size / 2),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black38,
                  blurRadius: 6,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Center(
              child: Container(
                width: 4,
                height: 4,
                decoration: const BoxDecoration(
                  color: Color(0xFFFFD54F),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black45,
                      blurRadius: 2,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ThermalToast extends StatelessWidget {
  const _ThermalToast({
    required this.compact,
    required this.landscape,
    required this.onTap,
    this.onDismiss,
    this.temperatureC,
    this.userOverride = false,
    this.isCooledDown = false,
  });

  final bool compact;
  final bool landscape;
  final VoidCallback onTap;
  final VoidCallback? onDismiss;
  final double? temperatureC;
  final bool userOverride;
  final bool isCooledDown;

  @override
  Widget build(BuildContext context) {
    final tempStr =
        temperatureC != null ? '${temperatureC!.toStringAsFixed(0)}°C' : '';

    Color bgColor;
    Color borderColor;
    Color textColor;
    IconData icon;
    String message;

    if (isCooledDown) {
      bgColor = const Color(0xFF0D2818).withValues(alpha: 0.75);
      borderColor = const Color(0xFF00E676).withValues(alpha: 0.45);
      textColor = const Color(0xFFB9F6CA);
      icon = Icons.ac_unit_rounded;
      message = appText(
        context,
        tempStr.isNotEmpty
            ? 'Thiết bị đã hạ nhiệt an toàn ($tempStr). Chạm để chọn lại độ phân giải.'
            : 'Thiết bị đã hạ nhiệt an toàn. Chạm để chọn lại độ phân giải.',
        tempStr.isNotEmpty
            ? 'Device has cooled down ($tempStr). Tap to choose resolution.'
            : 'Device has cooled down. Tap to choose resolution.',
      );
    } else if (userOverride) {
      bgColor = const Color(0xFF2E1C0A).withValues(alpha: 0.75);
      borderColor = const Color(0xFFFF9800).withValues(alpha: 0.45);
      textColor = const Color(0xFFFFE0B2);
      icon = Icons.thermostat_rounded;
      message = appText(
        context,
        tempStr.isNotEmpty
            ? 'Thiết bị đang ấm ($tempStr). Đang dùng độ phân giải bạn chọn. Chạm để đổi.'
            : 'Thiết bị đang ấm. Đang dùng độ phân giải bạn chọn. Chạm để đổi.',
        tempStr.isNotEmpty
            ? 'Device is warm ($tempStr). Using your selected resolution. Tap to change.'
            : 'Device is warm. Using your selected resolution. Tap to change.',
      );
    } else {
      bgColor = const Color(0xFF2A1C08).withValues(alpha: 0.75);
      borderColor = Colors.amber.withValues(alpha: 0.50);
      textColor = Colors.amber.shade100;
      icon = Icons.whatshot_rounded;
      message = appText(
        context,
        tempStr.isNotEmpty
            ? 'Thiết bị đang nóng ($tempStr). Tạm hạ để bảo vệ máy. Chạm để chọn lại.'
            : 'Thiết bị đang nóng. Tạm hạ để bảo vệ máy. Chạm để chọn lại.',
        tempStr.isNotEmpty
            ? 'Device is hot ($tempStr). Temporarily lowered to protect camera. Tap to change.'
            : 'Device is hot. Temporarily lowered to protect camera. Tap to change.',
      );
    }

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: landscape ? (compact ? 330 : 450) : double.infinity,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: onTap,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 8 : 10,
                  vertical: compact ? 5 : 7,
                ),
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: borderColor),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 12,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      icon,
                      color: isCooledDown
                          ? const Color(0xFF69F0AE)
                          : (userOverride
                              ? const Color(0xFFFFB74D)
                              : Colors.amber),
                      size: compact ? 14 : 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: textColor,
                          fontSize: compact ? 9.5 : 10.5,
                          height: 1.18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.arrow_forward_ios_rounded,
                      size: compact ? 10 : 12,
                      color: textColor.withValues(alpha: 0.7),
                    ),
                    if (isCooledDown && onDismiss != null) ...[
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: onDismiss,
                        child: Padding(
                          padding: const EdgeInsets.all(2.0),
                          child: Icon(
                            Icons.close_rounded,
                            size: compact ? 12 : 14,
                            color: textColor.withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomControlPanel extends StatelessWidget {
  const _BottomControlPanel({
    required this.compact,
    required this.cameraReady,
    required this.recording,
    required this.zoomSupported,
    required this.zoomValue,
    required this.minimumZoom,
    required this.maximumZoom,
    required this.hasUltraWide,
    required this.ultraWideRatio,
    required this.ultraWideLabel,
    required this.onZoomChanged,
    required this.onQuickSelectZoom,
  });

  final bool compact;
  final bool cameraReady;
  final bool recording;
  final bool zoomSupported;
  final double zoomValue;
  final double minimumZoom;
  final double maximumZoom;
  final bool hasUltraWide;
  final double ultraWideRatio;
  final String ultraWideLabel;
  final ValueChanged<double> onZoomChanged;
  final ValueChanged<double> onQuickSelectZoom;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(compact ? 18 : 20),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 10,
            vertical: compact ? 4 : 6,
          ),
          decoration: BoxDecoration(
            color: const Color(0xFF101216).withValues(alpha: 0.30),
            borderRadius: BorderRadius.circular(compact ? 18 : 20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.11)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x40000000),
                blurRadius: 16,
                offset: Offset(0, 5),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (zoomSupported) ...[
                _CameraZoomSlider(
                  compact: compact,
                  value: zoomValue,
                  minimum: minimumZoom,
                  maximum: maximumZoom,
                  hasUltraWide: hasUltraWide,
                  ultraWideRatio: ultraWideRatio,
                  ultraWideLabel: ultraWideLabel,
                  onChanged: onZoomChanged,
                  onQuickSelect: onQuickSelectZoom,
                ),
                Container(
                  height: 1,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  color: Colors.white.withValues(alpha: 0.09),
                ),
              ],
              _BottomStatusBar(
                compact: compact,
                cameraReady: cameraReady,
                recording: recording,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NetworkStatusBanner extends StatelessWidget {
  const _NetworkStatusBanner({
    required this.compact,
    required this.connectedAddress,
    required this.recovering,
    required this.hasError,
    required this.onReconnect,
  });

  final bool compact;
  final String? connectedAddress;
  final bool recovering;
  final bool hasError;
  final VoidCallback? onReconnect;

  @override
  Widget build(BuildContext context) {
    final message = recovering
        ? appText(
            context,
            'Đang khởi động lại kết nối live…',
            'Restarting live connection…',
          )
        : connectedAddress == null
        ? appText(
            context,
            'Chưa có Wi-Fi/LAN. Camera vẫn ghi hình và sẽ tự kết nối khi có IP.',
            'No Wi-Fi/LAN. Recording continues and live will connect automatically.',
          )
        : appText(
            context,
            hasError
                ? 'Kết nối live gặp lỗi. Camera vẫn tiếp tục ghi hình.'
                : 'Kết nối live cần được làm mới.',
            hasError
                ? 'Live connection has an error. Recording is still active.'
                : 'Live connection needs to be refreshed.',
          );
    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(bottom: compact ? 6 : 8),
      padding: EdgeInsets.fromLTRB(
        compact ? 10 : 12,
        compact ? 6 : 8,
        6,
        compact ? 6 : 8,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF37474F).withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(compact ? 10 : 12),
      ),
      child: Row(
        children: [
          if (recovering)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          else
            const Icon(Icons.wifi_off_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: compact ? 2 : 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: compact ? 11 : 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: onReconnect,
            icon: const Icon(Icons.sync_rounded, size: 17),
            label: Text(
              appText(context, 'KẾT NỐI LẠI', 'RECONNECT'),
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraZoomSlider extends StatelessWidget {
  const _CameraZoomSlider({
    required this.compact,
    required this.value,
    required this.minimum,
    required this.maximum,
    required this.hasUltraWide,
    required this.ultraWideRatio,
    required this.ultraWideLabel,
    required this.onChanged,
    required this.onQuickSelect,
  });

  final bool compact;
  final double value;
  final double minimum;
  final double maximum;
  final bool hasUltraWide;
  final double ultraWideRatio;
  final String ultraWideLabel;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onQuickSelect;

  @override
  Widget build(BuildContext context) {
    final effectiveMin = hasUltraWide
        ? math.min(ultraWideRatio, minimum)
        : minimum.clamp(1.0, 5.0);
    final effectiveMax = math.min(maximum, 5.0).clamp(effectiveMin + 0.1, 5.0);
    final safeValue = value.clamp(effectiveMin, effectiveMax).toDouble();

    void stepZoom(double delta) {
      final raw = safeValue + delta;
      final stepped = (raw * 10).round() / 10.0;
      final clamped = stepped.clamp(effectiveMin, effectiveMax).toDouble();
      onChanged(clamped);
    }

    final canDecrease = safeValue > (effectiveMin + 0.04);
    final canIncrease = safeValue < (effectiveMax - 0.04);

    Widget buildStepButton({
      required IconData icon,
      required VoidCallback? onTap,
    }) {
      final enabled = onTap != null;
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            width: compact ? 34 : 38,
            height: compact ? 34 : 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: enabled
                  ? Colors.white.withValues(alpha: 0.12)
                  : Colors.white.withValues(alpha: 0.04),
              shape: BoxShape.circle,
              border: Border.all(
                color: enabled
                    ? Colors.white.withValues(alpha: 0.22)
                    : Colors.white.withValues(alpha: 0.06),
                width: 1,
              ),
            ),
            child: Icon(
              icon,
              color: enabled ? Colors.white : Colors.white24,
              size: compact ? 18 : 20,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (hasUltraWide) ...[
                _ZoomPresetButton(
                  label: ultraWideLabel,
                  selected: (safeValue - ultraWideRatio).abs() < 0.08,
                  compact: compact,
                  onTap: () => onQuickSelect(ultraWideRatio),
                ),
                const SizedBox(width: 4),
              ],
              _ZoomPresetButton(
                label: '1×',
                selected: (safeValue - 1.0).abs() < 0.08,
                compact: compact,
                onTap: () => onQuickSelect(1.0),
              ),
              const SizedBox(width: 4),
              _ZoomPresetButton(
                label: '2×',
                selected: (safeValue - 2.0).abs() < 0.08,
                compact: compact,
                onTap: () => onQuickSelect(2.0),
              ),
              const SizedBox(width: 4),
              _ZoomPresetButton(
                label: '5×',
                selected: (safeValue - 5.0).abs() < 0.08,
                compact: compact,
                onTap: () => onQuickSelect(5.0),
              ),
              const Spacer(),
              Text(
                '${safeValue.toStringAsFixed(1)}×',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: compact ? 12 : 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              buildStepButton(
                icon: Icons.remove_rounded,
                onTap: canDecrease ? () => stepZoom(-0.1) : null,
              ),
              const SizedBox(width: 2),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: compact ? 4.5 : 6.0,
                    thumbShape: RoundSliderThumbShape(
                      enabledThumbRadius: compact ? 8.5 : 10.5,
                      elevation: 2.0,
                      pressedElevation: 4.0,
                    ),
                    overlayShape: RoundSliderOverlayShape(
                      overlayRadius: compact ? 16 : 20,
                    ),
                    activeTrackColor: const Color(0xFF22C55E),
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.20),
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: safeValue,
                    min: effectiveMin,
                    max: effectiveMax,
                    divisions: ((effectiveMax - effectiveMin) * 10)
                        .round()
                        .clamp(1, 100),
                    onChanged: onChanged,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              buildStepButton(
                icon: Icons.add_rounded,
                onTap: canIncrease ? () => stepZoom(0.1) : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ZoomPresetButton extends StatelessWidget {
  final String label;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  const _ZoomPresetButton({
    required this.label,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 10,
          vertical: compact ? 2 : 3,
        ),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF1565C0)
              : Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? const Color(0xFF64B5F6)
                : Colors.white.withValues(alpha: 0.15),
            width: selected ? 1.5 : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: const Color(0xFF1565C0).withValues(alpha: 0.4),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: Colors.white,
            fontWeight: selected ? FontWeight.w900 : FontWeight.w600,
            fontSize: compact ? 11 : 12,
          ),
        ),
      ),
    );
  }
}

// ============================================================
// HEADER
// ============================================================

class _StationHeader extends StatelessWidget {
  final StationIdentity identity;
  final String courtLabel;
  final bool recording;
  final bool thermalWarning;
  final double? temperatureC;
  final bool thermalUserOverride;
  final bool justCooledDown;
  final VoidCallback? onDismissCooledDown;
  final bool compact;
  final bool landscape;
  final CameraResolutionProfile resolutionProfile;
  final bool resolutionSwitching;
  final bool resolutionLocked;
  final bool whipLive;
  final VoidCallback onVideoStorage;
  final VoidCallback? onResolution;
  final VoidCallback onSettings;
  final VoidCallback onWhipLive;

  const _StationHeader({
    required this.identity,
    required this.courtLabel,
    required this.recording,
    required this.thermalWarning,
    this.temperatureC,
    this.thermalUserOverride = false,
    this.justCooledDown = false,
    this.onDismissCooledDown,
    required this.compact,
    required this.landscape,
    required this.resolutionProfile,
    required this.resolutionSwitching,
    required this.resolutionLocked,
    required this.whipLive,
    required this.onVideoStorage,
    required this.onResolution,
    required this.onSettings,
    required this.onWhipLive,
  });

  @override
  Widget build(BuildContext context) {
    final logoWidth = compact ? 76.0 : 94.0;
    final logoHeight = compact ? 26.0 : 30.0;
    final actionSize = compact ? 34.0 : 38.0;

    // Only landscape uses the condensed one-row header. A narrow portrait
    // phone still needs the second row below, where the quality selector has
    // enough room and cannot be pushed off-screen by the action buttons.
    if (landscape) {
      return Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: _HeaderGlassCluster(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.videocam_rounded,
                      color: Colors.white70,
                      size: 18,
                    ),
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(
                        '${identity.cameraName} · ${identity.cameraId} · $courtLabel',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _HeaderGlassCluster(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _RecordingChip(recording: recording, compact: true),
                      const SizedBox(width: 5),
                      _ResolutionChip(
                        profile: resolutionProfile,
                        switching: resolutionSwitching,
                        locked: resolutionLocked,
                        onTap: onResolution,
                      ),
                      const SizedBox(width: 5),
                      _HeaderIconButton(
                        icon: Icons.video_settings_rounded,
                        tooltip: appText(context, 'Kho video', 'Video storage'),
                        size: 32,
                        onTap: onVideoStorage,
                      ),
                      const SizedBox(width: 4),
                      _HeaderIconButton(
                        icon: Icons.podcasts_rounded,
                        tooltip: whipLive
                            ? appText(context, 'Đang phát trực tiếp', 'Live streaming')
                            : appText(context, 'Phát trực tiếp lên máy chủ', 'Live stream to server'),
                        iconColor: whipLive ? Colors.redAccent : Colors.white,
                        backgroundColor: whipLive ? Colors.red.withValues(alpha: 0.35) : null,
                        size: 32,
                        onTap: onWhipLive,
                      ),
                      const SizedBox(width: 4),
                      AppLanguageButton(
                        foregroundColor: Colors.white,
                        size: 32,
                      ),
                      const SizedBox(width: 4),
                      _HeaderIconButton(
                        icon: Icons.settings_rounded,
                        tooltip: appText(
                          context,
                          'Cấu hình Camera Station',
                          'Camera Station settings',
                        ),
                        size: 32,
                        onTap: onSettings,
                      ),
                    ],
                  ),
                ),
                if (thermalWarning || justCooledDown) ...[
                  const SizedBox(height: 10),
                  _ThermalToast(
                    compact: compact,
                    landscape: true,
                    temperatureC: temperatureC,
                    userOverride: thermalUserOverride,
                    isCooledDown: justCooledDown,
                    onTap: onResolution ?? () {},
                    onDismiss: onDismissCooledDown,
                  ),
                ],
              ],
            ),
          ),
        ],
      );
    }

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 10 : 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.30),
        borderRadius: BorderRadius.circular(compact ? 14 : 18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // -------------------------------------------------
          // ROW 1 — Camera Info (left) + Action Buttons (right)
          // -------------------------------------------------
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: logoWidth,
                  height: logoHeight,
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  color: Colors.white.withValues(alpha: 0.08),
                  child: Image.asset(
                    'assets/images/vnvar_logo.png',
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  identity.cameraName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: compact ? 13 : 15,
                    fontWeight: FontWeight.w900,
                    height: 1.0,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _HeaderIconButton(
                icon: Icons.video_settings_rounded,
                tooltip: appText(context, 'Kho video', 'Video storage'),
                size: actionSize,
                onTap: onVideoStorage,
              ),
              const SizedBox(width: 4),
              _HeaderIconButton(
                icon: Icons.podcasts_rounded,
                tooltip: whipLive
                    ? appText(context, 'Đang phát trực tiếp', 'Live streaming')
                    : appText(context, 'Phát trực tiếp lên máy chủ', 'Live stream to server'),
                iconColor: whipLive ? Colors.redAccent : Colors.white,
                backgroundColor: whipLive ? Colors.red.withValues(alpha: 0.35) : null,
                size: actionSize,
                onTap: onWhipLive,
              ),
              const SizedBox(width: 4),
              AppLanguageButton(
                foregroundColor: Colors.white,
                size: actionSize,
              ),
              const SizedBox(width: 4),
              _HeaderIconButton(
                icon: Icons.settings_rounded,
                tooltip: appText(
                  context,
                  'Cấu hình Camera Station',
                  'Camera Station settings',
                ),
                size: actionSize,
                onTap: onSettings,
              ),
            ],
          ),

          SizedBox(height: compact ? 6 : 8),
          Divider(
            height: 1,
            thickness: 1,
            color: Colors.white.withValues(alpha: 0.08),
          ),
          SizedBox(height: compact ? 6 : 8),

          // -------------------------------------------------
          // ROW 2 — Recording status + Resolution + Identifiers (All in Wrap)
          // -------------------------------------------------
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _RecordingChip(recording: recording, compact: compact),
              _ResolutionChip(
                profile: resolutionProfile,
                switching: resolutionSwitching,
                locked: resolutionLocked,
                onTap: onResolution,
              ),
              _HeaderTag(icon: Icons.videocam_rounded, text: identity.cameraId),
              _HeaderTag(icon: Icons.stadium_rounded, text: courtLabel),
              _HeaderTag(
                icon: Icons.location_on_rounded,
                text: identity.cameraPosition,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeaderGlassCluster extends StatelessWidget {
  const _HeaderGlassCluster({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF101216).withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x26000000),
                blurRadius: 10,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _ResolutionChip extends StatelessWidget {
  final CameraResolutionProfile profile;
  final bool switching;
  final bool locked;
  final VoidCallback? onTap;

  const _ResolutionChip({
    required this.profile,
    required this.switching,
    this.locked = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: locked
          ? const Color(0xFFE65100).withValues(alpha: 0.85)
          : const Color(0xFF1565C0).withValues(alpha: 0.8),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: switching ? null : onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: locked
                ? Border.all(
                    color: const Color(0xFFFFB74D).withValues(alpha: 0.7),
                    width: 1,
                  )
                : null,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (switching)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              else if (locked)
                const Icon(
                  Icons.lock_rounded,
                  size: 12,
                  color: Color(0xFFFFE082),
                )
              else
                const Icon(Icons.high_quality_rounded, size: 13),
              const SizedBox(width: 5),
              Text(
                '${profile.shortLabel} ${profile.fps}FPS',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// RECORDING CHIP
// ============================================================

class _RecordingChip extends StatelessWidget {
  final bool recording;
  final bool compact;

  const _RecordingChip({required this.recording, required this.compact});

  @override
  Widget build(BuildContext context) {
    final color = recording ? Colors.redAccent : Colors.greenAccent;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 9,
        vertical: compact ? 5 : 6,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            recording ? 'REC' : 'READY',
            style: TextStyle(
              color: color,
              fontSize: compact ? 9 : 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// HEADER ICON BUTTON
// ============================================================

class _HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final double size;
  final VoidCallback onTap;
  final Color? iconColor;
  final Color? backgroundColor;

  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.size,
    required this.onTap,
    this.iconColor,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: backgroundColor ?? Colors.white.withValues(alpha: 0.12),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(
              icon,
              color: iconColor ?? Colors.white,
              size: size * 0.53,
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// HEADER TAG
// ============================================================

class _HeaderTag extends StatelessWidget {
  final IconData icon;
  final String text;

  const _HeaderTag({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 160),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: Colors.white70),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// CAMERA CONTROL DOCK (rotate / switch lens / toggle camera)
// ============================================================

class _CameraControlDock extends StatelessWidget {
  final bool compact;
  final bool cameraReady;
  final bool cameraEnabled;
  final bool cameraSwitching;
  final bool screenDimmed;
  final bool screenDimSwitching;
  final bool lensSwitching;
  final String screenOrientation;
  final VoidCallback? onSwitchLens;
  final VoidCallback? onToggleCamera;
  final VoidCallback? onToggleScreenDim;
  final VoidCallback? onToggleOrientation;

  const _CameraControlDock({
    required this.compact,
    required this.cameraReady,
    required this.cameraEnabled,
    required this.cameraSwitching,
    required this.screenDimmed,
    required this.screenDimSwitching,
    required this.lensSwitching,
    required this.screenOrientation,
    required this.onSwitchLens,
    required this.onToggleCamera,
    required this.onToggleScreenDim,
    required this.onToggleOrientation,
  });

  @override
  Widget build(BuildContext context) {
    final gap = compact ? 8.0 : 10.0;
    final buttonSize = compact ? 36.0 : 40.0;

    return Container(
      padding: EdgeInsets.symmetric(vertical: compact ? 7 : 9, horizontal: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF101216).withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.11)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
        children: [
          _DockButton(
            icon: Icons.cameraswitch_rounded,
            tooltip: appText(
              context,
              'Đổi camera trước/sau',
              'Switch front/rear camera',
            ),
            size: buttonSize,
            onPressed: onSwitchLens,
            loading: lensSwitching,
          ),
          SizedBox(height: gap),
          _DockButton(
            icon: cameraEnabled
                ? Icons.videocam_off_rounded
                : Icons.videocam_rounded,
            tooltip: cameraEnabled
                ? appText(context, 'Tắt camera', 'Turn camera off')
                : appText(context, 'Bật camera', 'Turn camera on'),
            size: buttonSize,
            onPressed: onToggleCamera,
            loading: cameraSwitching,
            background: cameraEnabled
                ? Colors.red.withValues(alpha: 0.75)
                : Colors.green.withValues(alpha: 0.75),
          ),
          SizedBox(height: gap),
          _DockButton(
            icon: screenDimmed
                ? Icons.brightness_7_rounded
                : Icons.dark_mode_rounded,
            tooltip: screenDimmed
                ? appText(
                    context,
                    'Khôi phục độ sáng màn hình',
                    'Restore screen brightness',
                  )
                : appText(
                    context,
                    'Làm mờ màn hình để giảm nhiệt',
                    'Dim screen to reduce heat',
                  ),
            size: buttonSize,
            onPressed: onToggleScreenDim,
            loading: screenDimSwitching,
            background: screenDimmed
                ? const Color(0xFF1565C0)
                : Colors.blueGrey.withValues(alpha: 0.75),
          ),
          SizedBox(height: gap),
          _DockButton(
            icon: screenOrientation == 'landscape'
                ? Icons.screen_lock_landscape_rounded
                : screenOrientation == 'portrait'
                    ? Icons.screen_lock_portrait_rounded
                    : Icons.screen_rotation_rounded,
            tooltip: screenOrientation == 'landscape'
                ? appText(
                    context,
                    'Đang khóa xoay ngang (chạm để đổi)',
                    'Locked landscape (tap to change)',
                  )
                : screenOrientation == 'portrait'
                    ? appText(
                        context,
                        'Đang khóa xoay dọc (chạm để đổi)',
                        'Locked portrait (tap to change)',
                      )
                    : appText(
                        context,
                        'Tự động xoay màn hình (chạm để khóa)',
                        'Auto-rotate screen (tap to lock)',
                      ),
            size: buttonSize,
            onPressed: onToggleOrientation,
            background: screenOrientation == 'landscape'
                ? const Color(0xFF1565C0)
                : screenOrientation == 'portrait'
                    ? const Color(0xFF0288D1)
                    : null,
          ),
        ],
      ),
    ),
  );
  }
}

class _DockButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final double size;
  final VoidCallback? onPressed;
  final bool loading;
  final Color? background;

  const _DockButton({
    required this.icon,
    required this.tooltip,
    required this.size,
    required this.onPressed,
    this.loading = false,
    this.background,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background ?? Colors.white.withValues(alpha: 0.10),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: loading
                  ? SizedBox(
                      width: size * 0.4,
                      height: size * 0.4,
                      child: const CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      icon,
                      size: size * 0.5,
                      color: onPressed == null ? Colors.white30 : Colors.white,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// BOTTOM STATUS BAR
// ============================================================

class _BottomStatusBar extends StatelessWidget {
  final bool compact;
  final bool cameraReady;
  final bool recording;

  const _BottomStatusBar({
    required this.compact,
    required this.cameraReady,
    required this.recording,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 7 : 9,
      ),
      child: Row(
        children: [
          Expanded(
            child: _CompactStatus(
              icon: Icons.videocam_rounded,
              text: cameraReady
                  ? appText(context, 'CAMERA SẴN SÀNG', 'CAMERA READY')
                  : appText(context, 'CAMERA TẮT', 'CAMERA OFF'),
              color: cameraReady ? Colors.greenAccent : Colors.orangeAccent,
              compact: compact,
            ),
          ),
          Container(
            width: 1,
            height: 22,
            color: Colors.white.withValues(alpha: 0.10),
          ),
          Expanded(
            child: _CompactStatus(
              icon: Icons.fiber_manual_record_rounded,
              text: recording
                  ? appText(context, 'ĐANG GHI', 'RECORDING')
                  : appText(context, 'SẴN SÀNG', 'READY'),
              color: recording ? Colors.redAccent : Colors.greenAccent,
              compact: compact,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// COMPACT STATUS
// ============================================================

class _CompactStatus extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  final bool compact;

  const _CompactStatus({
    required this.icon,
    required this.text,
    required this.color,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: compact ? 12 : 13),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: compact ? 8 : 9,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================
// GRADIENT
// ============================================================

// ============================================================
// CONFIG LINE
// ============================================================

class _ConfigLine extends StatelessWidget {
  final String title;
  final String value;

  const _ConfigLine({required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.black54,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: Color(0xFF112341),
                fontSize: 12,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
