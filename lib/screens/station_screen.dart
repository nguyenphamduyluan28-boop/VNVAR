import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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
import '../services/station_platform_events.dart';
import '../services/whip_publisher_service.dart';
import '../services/rtsp_publisher_service.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../widgets/scoreboard_hub_dialog.dart';
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

  /// Cụm nút cài đặt (thanh trên + cụm nút camera) đang mở hay thu gọn.
  bool _controlsExpanded = false;

  /// Màn hình nghỉ: sau [_previewRestDelay] không chạm, ngừng vẽ hình camera
  /// lên màn hình (GPU/màn hình là nguồn nhiệt lớn khi chạy nhiều giờ). Ghi
  /// hình, Tablet và livestream không bị ảnh hưởng; chạm để xem lại.
  static const Duration _previewRestDelay = Duration(seconds: 60);
  Timer? _previewRestTimer;
  bool _previewResting = false;

  void _schedulePreviewRest() {
    _previewRestTimer?.cancel();
    _previewRestTimer = Timer(_previewRestDelay, () {
      if (!mounted || _previewResting) return;
      // Đang PiP: hình nhỏ vẫn hiện; thử lại sau.
      if (_isInPipMode) {
        _schedulePreviewRest();
        return;
      }
      setState(() {
        _previewResting = true;
        _controlsExpanded = false;
      });
    });
  }

  /// Mọi lần chạm khi đang xem đều gia hạn thời gian chờ.
  void _notePreviewActivity() {
    if (!_previewResting) _schedulePreviewRest();
  }

  void _wakePreview() {
    if (!mounted) return;
    setState(() => _previewResting = false);
    _schedulePreviewRest();
  }
  /// Hướng màn hình khi ứng dụng đang foreground (chưa bị Keyguard can thiệp).
  /// Giữ nguyên giá trị này khi app chuyển sang background để tránh race
  /// condition: Keyguard ép portrait → LayoutBuilder rebuild → giá trị bị đổi
  /// thành portrait trước khi lifecycle callback kịp chạy.
  bool _lastActiveOrientationLandscape = true;
  bool _appResumed = true;
  bool _isInPipMode = false;

  bool get _recording => _runtime.recordingService?.recording ?? false;

  bool get _cameraReady =>
      _runtime.cameraEnabled &&
      (_runtime.webRtcService?.cameraInitialized ?? false);

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
      if (mounted) {
        setState(() => _screenDimmed = dimmed);
        _runtime.setAutoScreenDimmed(dimmed);
      }
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
    _schedulePreviewRest();
    _cameraQuarterTurns = _runtime.cameraQuarterTurns;
    _runtime.setStationDisplayAttached(true);

    _runtimeSubscription = _runtime.stateChanges.listen((_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _cameraQuarterTurns = _runtime.cameraQuarterTurns;
        if (!_screenDimSwitching && _runtime.autoScreenDimmed != _screenDimmed) {
          _screenDimmed = _runtime.autoScreenDimmed;
        }
        if (!_lensSwitching &&
            (_zoomDebounce == null || !_zoomDebounce!.isActive)) {
          _zoomValue = _runtime.webRtcService?.cameraZoom;
        }
        final address = _runtime.lanAddress;
        final port =
            _runtime.cameraServer?.apiPort ?? CameraServer.defaultApiPort;
        _viewerAddress = address == null
            ? 'Chưa kết nối Wi-Fi'
            : 'http://$address:$port/viewer';
      });
      _showRtspWarningIfNeeded();
    });

    unawaited(_initScreenOrientation());
    unawaited(WakelockPlus.enable());
    if (Platform.isAndroid) {
      StationPlatformEvents.instance.addListener(this, (call) async {
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
      // Quay lại app: hiện hình ngay, đếm lại thời gian màn hình nghỉ.
      _wakePreview();
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
    var result = 'Chưa kết nối Wi-Fi';
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

  /// Camera đã chạy: lỗi bật foreground service không được biến thành màn
  /// hình lỗi (camera/server vẫn chạy phía sau). Chỉ cảnh báo người vận hành.
  Future<void> _startForegroundServiceAfterCamera() async {
    try {
      await CameraStationForegroundService.start(
        cameraId: widget.identity.cameraId,
        courtId: widget.identity.courtId,
      );
    } catch (error) {
      debugPrint('[STATION] Không thể bật foreground service: $error');
      if (!mounted) return;
      _showStationToast(
        appText(
          context,
          'Không bật được chế độ chạy nền. Giữ màn hình mở để camera không bị ngắt.',
          'Background mode unavailable. Keep the screen on so the camera is not cut off.',
        ),
        isError: true,
        duration: const Duration(seconds: 5),
      );
    }
  }

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

      if (!mounted) {
        await _shutdownStation();
        return;
      }

      await _runtime.initialize(
        courtId: widget.identity.courtId,
        cameraId: widget.identity.cameraId,
        deviceId: widget.identity.deviceId,
      );

      // Android 14+: foreground service loại camera|microphone chỉ được khởi
      // động khi app ĐÃ có quyền camera/mic. Lần chạy đầu tiên các quyền này
      // được xin trong lúc mở camera ở trên, nên service phải bật sau đó
      // (lúc này app vẫn đang ở foreground nên camera không bị gián đoạn).
      await _startForegroundServiceAfterCamera();

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

      // Khởi tạo lỗi đã dừng foreground service; bật lại ngay khi camera đã
      // mở (đã có quyền), nếu không Android sẽ cắt camera khi tắt màn hình.
      await _startForegroundServiceAfterCamera();

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

  void _openScoreboardHub() {
    final port = _runtime.cameraServer?.apiPort ?? CameraServer.defaultApiPort;
    unawaited(
      showScoreboardHub(
        context,
        lanAddress: () => _runtime.lanAddress,
        port: port,
        networkChanges: _runtime.stateChanges,
      ),
    );
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

      await CameraStationForegroundService.start(
        cameraId: newIdentity.cameraId,
        courtId: newIdentity.courtId,
      );

      await _runtime.initialize(
        cameraId: newIdentity.cameraId,
        courtId: newIdentity.courtId,
        deviceId: newIdentity.deviceId,
      );

      // Chỉ lưu sau khi sân mới chạy được: nếu khởi tạo lỗi, cấu hình đã lưu
      // vẫn khớp với sân đang hiển thị/"Thử lại" (không gán nhầm sân).
      await StationConfigService().saveIdentity(newIdentity);

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
                            try {
                              await _runtime.setResolutionLocked(nextLock);
                            } catch (error) {
                              if (!mounted) return;
                              _showStationToast(
                                appText(
                                  this.context,
                                  'Không đổi được chế độ khóa: ${userFacingError(error)}',
                                  'Unable to change lock mode: ${userFacingError(error)}',
                                ),
                                isError: true,
                              );
                              return;
                            }
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
    _previewRestTimer?.cancel();
    _runtimeSubscription?.cancel();
    _whipSubscription?.cancel();
    _rtspSubscription?.cancel();
    _zoomDebounce?.cancel();
    if (_screenDimmed || _runtime.autoScreenDimmed) {
      unawaited(StationDisplayService.setDimmed(false));
    }
    _runtime.setStationDisplayAttached(false);
    StationPlatformEvents.instance.removeListener(this);
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

  // ============================================================
  // BỐ CỤC ĐIỀU KHIỂN TRÊN MÀN HÌNH CAMERA
  //
  // Một thanh trạng thái (REC · chất lượng · nhiệt độ · LIVE) cùng kiểu viên
  // thuốc, một nút "Menu" có chữ. Menu mở ra bảng nút có nhãn chia 2 nhóm:
  // Chức năng và Camera. Không còn cụm nút rời bên phải.
  //
  // Dọc:   [logo .................... Menu]
  //        [REC][1080p30][46°C · …][LIVE]
  //        [bảng menu (khi mở)]
  //        [thông báo mạng/bộ nhớ]
  //        ...
  //        [zoom + độ sáng]
  // Ngang: [REC][1080p30][46°C · …][LIVE] ............... [Menu]
  //        [thông báo]                        [bảng menu (khi mở)]
  //        [            zoom + độ sáng            ]
  // ============================================================

  Widget _buildStationHeader(bool compact, bool landscape) {
    return _StationHeader(
      compact: compact,
      landscape: landscape,
      statusPills: _buildStatusPills(compact),
      menuOpen: _controlsExpanded,
      onToggleMenu: () =>
          setState(() => _controlsExpanded = !_controlsExpanded),
    );
  }

  /// Các viên trạng thái: cùng chiều cao, cùng hàng, không lòi ra ngoài.
  List<Widget> _buildStatusPills(bool compact) {
    final rtsp = _runtime.rtspPublisherService;
    return [
      _StatusPill(
        dotColor: _recording ? const Color(0xFFFF5252) : const Color(0xFF69F0AE),
        label: _recording ? 'REC' : 'READY',
        color: _recording ? const Color(0xFFFF8A80) : const Color(0xFFB9F6CA),
        tooltip: _recording
            ? appText(context, 'Đang ghi hình', 'Recording')
            : appText(context, 'Sẵn sàng ghi', 'Ready'),
      ),
      _StatusPill(
        icon: _runtime.profileSwitching
            ? null
            : (_runtime.resolutionLocked
                  ? Icons.lock_rounded
                  : Icons.high_quality_rounded),
        loading: _runtime.profileSwitching,
        label:
            '${_runtime.resolutionProfile.shortLabel} ${_runtime.resolutionProfile.fps} FPS',
        color: _runtime.resolutionLocked
            ? const Color(0xFFFFCC80)
            : const Color(0xFF90CAF9),
        tooltip: appText(
          context,
          'Chất lượng video (chạm để đổi)',
          'Video quality (tap to change)',
        ),
        onTap: _runtime.profileSwitching ? null : _handleResolutionPressed,
      ),
      if (_runtime.thermalWarning || _runtime.justCooledDown)
        _ThermalPill(
          temperatureC: _runtime.temperatureC,
          userOverride: _runtime.thermalUserOverride,
          isCooledDown: _runtime.justCooledDown,
          isLocked: _runtime.resolutionLocked,
          isThrottled: _runtime.thermalThrottled,
          targetProfile: _runtime.pendingThermalTarget,
          pendingIn: _runtime.pendingThermalIn,
          profile: _runtime.resolutionProfile,
          loadLevel: _runtime.thermalLoadLevel,
          onTap: _handleResolutionPressed,
          onDismiss: _runtime.dismissCooledDownNotice,
        ),
      if (_runtime.isLiveStreaming)
        _StatusPill(
          dotColor: Colors.white,
          label:
              'LIVE ${_formatLiveDuration(rtsp.isLive ? rtsp.liveDuration : _runtime.whipPublisherService.liveDuration)}',
          color: Colors.white,
          background: const Color(0xFFD32F2F),
          trailingIcon:
              rtsp.isLive && rtsp.networkQuality != StreamNetworkQuality.unknown
              ? (rtsp.networkQuality == StreamNetworkQuality.good
                    ? Icons.wifi
                    : Icons.wifi_off)
              : null,
          trailingColor: switch (rtsp.networkQuality) {
            StreamNetworkQuality.good => Colors.lightGreenAccent,
            StreamNetworkQuality.warning => Colors.orangeAccent,
            StreamNetworkQuality.poor => Colors.yellowAccent,
            _ => Colors.white70,
          },
          tooltip: appText(context, 'Đang phát trực tiếp', 'Live streaming'),
          onTap: _openLiveStreamScreen,
        ),
    ];
  }

  /// Thông báo mạng, iOS và dung lượng (chỉ hiện khi cần). Nhiệt độ nằm
  /// trong thanh trạng thái.
  List<Widget> _buildNotices(bool compact) {
    return [
      if (_runtime.lanAddress == null ||
          _runtime.networkRecovering ||
          _runtime.networkError != null)
        _NetworkStatusBanner(
          compact: compact,
          connectedAddress: _runtime.lanAddress,
          recovering: _runtime.networkRecovering,
          hasError: _runtime.networkError != null,
          onReconnect: _runtime.networkRecovering ? null : _reconnectNetwork,
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
    ];
  }

  /// Menu chức năng: một hàng nút nhỏ có nhãn, mở dưới nút Menu.
  Widget _buildQuickMenu() {
    return _QuickMenuPanel(
      tiles: [
        _MenuTile(
          icon: Icons.video_library_rounded,
          label: appText(context, 'Video', 'Videos'),
          tooltip: appText(context, 'Kho video', 'Video storage'),
          onTap: _openVideoStorage,
        ),
        _MenuTile(
          icon: Icons.podcasts_rounded,
          label: appText(context, 'Live', 'Live'),
          tooltip: _runtime.isLiveStreaming
              ? appText(context, 'Đang phát trực tiếp', 'Live streaming')
              : appText(
                  context,
                  'Phát trực tiếp lên máy chủ',
                  'Live stream to server',
                ),
          active: _runtime.isLiveStreaming,
          activeColor: const Color(0xFFD32F2F),
          onTap: _openLiveStreamScreen,
        ),
        _MenuTile(
          icon: Icons.scoreboard_rounded,
          label: appText(context, 'Tỉ số', 'Score'),
          tooltip: appText(
            context,
            'Bảng tỉ số & Overlay',
            'Scoreboard & Overlay',
          ),
          onTap: _openScoreboardHub,
        ),
        _MenuTile(
          label: appText(context, 'Ngôn ngữ', 'Language'),
          tooltip: appText(context, 'Ngôn ngữ', 'Language'),
          custom: const AppLanguageButton(
            foregroundColor: Colors.white,
            size: 22,
          ),
        ),
        _MenuTile(
          icon: Icons.settings_rounded,
          label: appText(context, 'Cài đặt', 'Settings'),
          tooltip: appText(
            context,
            'Cấu hình Camera Station',
            'Camera Station settings',
          ),
          onTap: _openSettings,
        ),
      ],
    );
  }

  /// Cụm nút camera luôn hiện ở mép phải (đổi camera, bật/tắt, làm tối,
  /// khoá xoay). Chạm giữ để xem tên nút.
  Widget _buildCameraDock() {
    return _CameraDock(
      buttons: [
        _DockButton(
          icon: Icons.cameraswitch_rounded,
          tooltip: appText(
            context,
            'Đổi camera trước/sau',
            'Switch front/rear camera',
          ),
          loading: _lensSwitching,
          onTap: _cameraReady && !_lensSwitching ? _switchCameraLens : null,
        ),
        _DockButton(
          icon: _runtime.cameraEnabled
              ? Icons.videocam_off_rounded
              : Icons.videocam_rounded,
          tooltip: _runtime.cameraEnabled
              ? appText(context, 'Tắt camera', 'Turn camera off')
              : appText(context, 'Bật camera', 'Turn camera on'),
          loading: _cameraSwitching,
          background: _runtime.cameraEnabled
              ? const Color(0xCCC62828)
              : const Color(0xCC2E7D32),
          onTap: _cameraSwitching ? null : _toggleCamera,
        ),
        _DockButton(
          icon: _screenDimmed
              ? Icons.brightness_7_rounded
              : Icons.dark_mode_rounded,
          tooltip: _screenDimmed
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
          loading: _screenDimSwitching,
          background: _screenDimmed ? _accentBlue : null,
          onTap: _screenDimSwitching ? null : _toggleScreenDim,
        ),
        _DockButton(
          icon: _screenOrientation == 'landscape'
              ? Icons.screen_lock_landscape_rounded
              : _screenOrientation == 'portrait'
              ? Icons.screen_lock_portrait_rounded
              : Icons.screen_rotation_rounded,
          tooltip: _screenOrientation == 'landscape'
              ? appText(
                  context,
                  'Đang khóa xoay ngang (chạm để đổi)',
                  'Locked landscape (tap to change)',
                )
              : _screenOrientation == 'portrait'
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
          background: _screenOrientation != 'auto' ? _accentBlue : null,
          onTap: _toggleScreenOrientation,
        ),
      ],
    );
  }

  Widget _buildBottomPanel(bool compact) {
    return _BottomControlPanel(
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
      exposureEv: _runtime.exposureBiasEv,
      onExposureChanged: (ev) async {
        try {
          await _runtime.setExposureBias(ev);
        } catch (error) {
          if (!mounted) return;
          _showStationToast(
            appText(
              context,
              'Không chỉnh được độ sáng: ${userFacingError(error)}',
              'Unable to adjust exposure: ${userFacingError(error)}',
            ),
            isError: true,
          );
        }
        if (mounted) setState(() {});
      },
    );
  }

  /// Màn dọc: thanh trên, menu (khi mở), thông báo; cụm nút camera ở mép
  /// phải; zoom ở đáy.
  Widget _buildPortraitControls(bool compact) {
    final notices = _buildNotices(compact);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildStationHeader(compact, false),
        if (_controlsExpanded) ...[
          const SizedBox(height: 6),
          Align(alignment: Alignment.topRight, child: _buildQuickMenu()),
        ],
        if (notices.isNotEmpty) ...[
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: compact ? 120 : 180),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: notices,
              ),
            ),
          ),
        ],
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: _buildCameraDock(),
            ),
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: _buildBottomPanel(compact),
          ),
        ),
      ],
    );
  }

  /// Màn ngang: thanh trên một hàng, menu (khi mở) ngay dưới nút Menu;
  /// thông báo bên trái, cụm nút camera ở mép phải; zoom ở đáy.
  Widget _buildLandscapeControls(bool compact) {
    final notices = _buildNotices(compact);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildStationHeader(compact, true),
        const SizedBox(height: 6),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: notices.isEmpty
                      ? const SizedBox.shrink()
                      : ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: compact ? 360 : 420,
                          ),
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: notices,
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (_controlsExpanded) _buildQuickMenu(),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: _buildCameraDock(),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: _buildBottomPanel(compact),
          ),
        ),
      ],
    );
  }

  Widget _buildStation() {
    final webRtc = _runtime.webRtcService;
    final renderer = webRtc?.localRenderer;
    // Match the phone's Camera app: mirror only the local front-camera
    // preview for intuitive movement. Recording, RTSP and tablet video consume
    // the original track and therefore remain in the real capture direction.
    final mirrorPreview = webRtc?.currentFacingMode == 'user';

    return Scaffold(
      backgroundColor: Colors.black,
      // Ghi nhận mọi lần chạm (không chặn chạm) để gia hạn màn hình nghỉ.
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _notePreviewActivity(),
        child: LayoutBuilder(
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
              // Chế độ auto chỉ cần nhớ hướng gần nhất trong bộ nhớ để khoá
              // khi chạy nền; không ghi đè lựa chọn 'auto' đã lưu.
              _lastActiveOrientationLandscape = landscape;
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
                // Không lấy nét/đo sáng khi chạm: camera luôn tự động. Chạm
                // nhầm (máy đặt trên cao, chạm để bấm nút) không đổi hình.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  child: RotatedBox(
                    quarterTurns: _cameraQuarterTurns,
                    // Màn hình nghỉ: giữ nguyên view (không tạo lại surface)
                    // nhưng không vẽ, nên Flutter không phải dựng lại hình
                    // camera mỗi khung.
                    child: Offstage(
                      offstage: _previewResting && !isPip,
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
              // GIAO DIỆN ĐIỀU KHIỂN
              //
              // Bố cục theo luồng (Column/Row) thay vì nhiều Positioned chồng
              // lên nhau: thanh trên, thông báo, cụm nút camera và khung
              // zoom/độ sáng không bao giờ đè lên nhau dù màn hình thấp.
              // Vùng trống không bắt chạm nên chạm-để-lấy-nét vẫn hoạt động.
              // ==============================================
              if (!isPip && _previewResting)
                Positioned.fill(
                  child: _PreviewRestOverlay(
                    statusPills: _buildStatusPills(compact),
                    onWake: _wakePreview,
                  ),
                ),
              if (!isPip && !_previewResting)
                Positioned.fill(
                  child: SafeArea(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        compact ? 8 : 14,
                        compact ? 8 : 12,
                        compact ? 8 : 14,
                        compact ? 10 : 14,
                      ),
                      child: landscape
                          ? _buildLandscapeControls(compact)
                          : _buildPortraitControls(compact),
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
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.warning_amber_rounded,
                                color: Colors.amber,
                                size: 10,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                profileLabel(_runtime.resolutionProfile),
                                style: const TextStyle(
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

            ],
          );
        },
        ),
      ),
    );
  }
}

/// Màn hình nghỉ: nền đen, vẫn hiện trạng thái (REC, nhiệt độ, LIVE); chạm
/// bất kỳ đâu để xem lại hình.
class _PreviewRestOverlay extends StatelessWidget {
  const _PreviewRestOverlay({required this.statusPills, required this.onWake});

  final List<Widget> statusPills;
  final VoidCallback onWake;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onWake,
      child: ColoredBox(
        color: Colors.black,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Chỉ để xem: chạm vào đâu cũng là "xem lại hình".
                IgnorePointer(
                  child: Wrap(spacing: 6, runSpacing: 6, children: statusPills),
                ),
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.touch_app_rounded,
                          color: Colors.white38,
                          size: 30,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          appText(context, 'Chạm để xem hình', 'Tap to view'),
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          appText(
                            context,
                            'Tạm tắt hình xem trước để giảm nhiệt. Ghi hình, Tablet và livestream vẫn chạy.',
                            'Preview paused to reduce heat. Recording, tablet and livestream keep running.',
                          ),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
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
    required this.exposureEv,
    required this.onExposureChanged,
  });

  final bool compact;
  final double exposureEv;
  final ValueChanged<double> onExposureChanged;
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
    // Camera chưa sẵn sàng: không có zoom hay độ sáng để chỉnh, ẩn hẳn khung.
    if (!cameraReady && !zoomSupported) return const SizedBox.shrink();
    // Cùng kiểu nền với thanh trạng thái/menu; không làm mờ nền (đỡ tốn GPU).
    return ClipRRect(
      borderRadius: BorderRadius.circular(compact ? 18 : 20),
      child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 10,
            vertical: compact ? 4 : 6,
          ),
          decoration: BoxDecoration(
            color: _glassColor,
            borderRadius: BorderRadius.circular(compact ? 18 : 20),
            border: Border.all(color: _glassBorder),
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
              if (cameraReady)
                _BrightnessControl(
                  compact: compact,
                  ev: exposureEv,
                  onChanged: onExposureChanged,
                ),
            ],
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
            'Chưa có Wi-Fi. Camera vẫn ghi hình bình thường; Tablet sẽ kết nối được khi điện thoại vào Wi-Fi.',
            'No Wi-Fi. Recording continues; tablets can connect once the phone joins Wi-Fi.',
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

/// Nút chỉnh độ sáng hình cho người dùng phổ thông: "Tối hơn / Tự động /
/// Sáng hơn", mỗi bước 0,5 EV, từ −1 tới +2.
class _BrightnessControl extends StatelessWidget {
  const _BrightnessControl({
    required this.compact,
    required this.ev,
    required this.onChanged,
  });

  static const double _step = 0.5;
  static const double _min = -1.0;
  static const double _max = 2.0;

  final bool compact;
  final double ev;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final label = ev.abs() < 0.01
        ? appText(context, 'Tự động', 'Auto')
        : ev > 0
        ? appText(
            context,
            'Sáng hơn +${ev.toStringAsFixed(1)}',
            'Brighter +${ev.toStringAsFixed(1)}',
          )
        : appText(
            context,
            'Tối hơn ${ev.toStringAsFixed(1)}',
            'Darker ${ev.toStringAsFixed(1)}',
          );
    Widget button(IconData icon, double next, bool enabled) {
      return InkResponse(
        radius: 16,
        onTap: enabled ? () => onChanged(next) : null,
        child: SizedBox(
          width: 30,
          height: 28,
          child: Icon(
            icon,
            size: 17,
            color: enabled ? Colors.white : Colors.white24,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Row(
        children: [
          const Icon(
            Icons.wb_sunny_rounded,
            size: 15,
            color: Colors.amberAccent,
          ),
          const SizedBox(width: 6),
          Text(
            appText(context, 'Độ sáng', 'Brightness'),
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          button(Icons.remove_rounded, ev - _step, ev > _min + 0.01),
          SizedBox(
            width: 92,
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          button(Icons.add_rounded, ev + _step, ev < _max - 0.01),
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
            width: 28,
            height: 28,
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
              size: 16,
            ),
          ),
        ),
      );
    }

    // Một hàng gọn: [nút nhanh] [−] [thanh trượt] [+] [giá trị]. Máy hẹp
    // (dọc ~360px) bỏ ô giá trị để thanh trượt đủ dài.
    return LayoutBuilder(
      builder: (context, constraints) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: Row(
        children: [
          if (hasUltraWide) ...[
            _ZoomPresetButton(
              label: ultraWideLabel,
              selected: (safeValue - ultraWideRatio).abs() < 0.08,
              compact: true,
              onTap: () => onQuickSelect(ultraWideRatio),
            ),
            const SizedBox(width: 3),
          ],
          _ZoomPresetButton(
            label: '1×',
            selected: (safeValue - 1.0).abs() < 0.08,
            compact: true,
            onTap: () => onQuickSelect(1.0),
          ),
          const SizedBox(width: 3),
          _ZoomPresetButton(
            label: '2×',
            selected: (safeValue - 2.0).abs() < 0.08,
            compact: true,
            onTap: () => onQuickSelect(2.0),
          ),
          const SizedBox(width: 3),
          _ZoomPresetButton(
            label: '5×',
            selected: (safeValue - 5.0).abs() < 0.08,
            compact: true,
            onTap: () => onQuickSelect(5.0),
          ),
          const SizedBox(width: 6),
          buildStepButton(
            icon: Icons.remove_rounded,
            onTap: canDecrease ? () => stepZoom(-0.1) : null,
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 8,
                  elevation: 2.0,
                  pressedElevation: 4.0,
                ),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
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
          buildStepButton(
            icon: Icons.add_rounded,
            onTap: canIncrease ? () => stepZoom(0.1) : null,
          ),
          if (constraints.maxWidth >= 360)
            SizedBox(
              width: 38,
              child: Text(
                '${safeValue.toStringAsFixed(1)}×',
                textAlign: TextAlign.right,
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

// ============================================================
// THANH TRẠNG THÁI & MENU (màn hình camera)
// ============================================================

const Color _glassColor = Color(0xA60E1116);
const Color _glassBorder = Color(0x1FFFFFFF);
const Color _accentBlue = Color(0xFF1E88E5);

/// Nền tối dùng chung cho thanh trạng thái, menu và các viên.
class _GlassSurface extends StatelessWidget {
  const _GlassSurface({
    required this.child,
    this.radius = 16,
    this.padding = EdgeInsets.zero,
    this.color = _glassColor,
    this.borderColor = _glassBorder,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final Color color;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    // Không dùng làm mờ nền (BackdropFilter): vẽ lại mỗi khung hình camera
    // tốn GPU và làm máy nóng thêm. Nền tối bán trong suốt là đủ đọc rõ.
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: borderColor),
        ),
        child: child,
      ),
    );
  }
}

/// Một viên trạng thái: cùng chiều cao, cùng kiểu chữ cho mọi thông tin.
class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.label,
    required this.color,
    required this.tooltip,
    this.icon,
    this.dotColor,
    this.loading = false,
    this.background,
    this.trailingIcon,
    this.trailingColor,
    this.onTap,
    this.onClose,
  });

  static const double height = 26;

  final String label;
  final Color color;
  final String tooltip;
  final IconData? icon;
  final Color? dotColor;
  final bool loading;
  final Color? background;
  final IconData? trailingIcon;
  final Color? trailingColor;
  final VoidCallback? onTap;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final leading = loading
        ? SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          )
        : dotColor != null
        ? Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          )
        : icon != null
        ? Icon(icon, size: 13, color: color)
        : null;
    final content = Container(
      height: height,
      padding: EdgeInsets.only(left: 9, right: onClose != null ? 3 : 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[leading, const SizedBox(width: 6)],
          Text(
            label,
            maxLines: 1,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
              height: 1.1,
            ),
          ),
          if (trailingIcon != null) ...[
            const SizedBox(width: 6),
            Icon(trailingIcon, size: 14, color: trailingColor ?? color),
          ],
          if (onTap != null && onClose == null) ...[
            const SizedBox(width: 3),
            Icon(
              Icons.expand_more_rounded,
              size: 15,
              color: color.withValues(alpha: 0.75),
            ),
          ],
          if (onClose != null)
            InkResponse(
              onTap: onClose,
              radius: 14,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.close_rounded,
                  size: 14,
                  color: color.withValues(alpha: 0.8),
                ),
              ),
            ),
        ],
      ),
    );
    return Tooltip(
      message: tooltip,
      child: _GlassSurface(
        radius: height / 2,
        color: background ?? _glassColor,
        borderColor: background != null
            ? Colors.transparent
            : color.withValues(alpha: 0.30),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(onTap: onTap, child: content),
        ),
      ),
    );
  }
}

/// Nhiệt độ trong thanh trạng thái: ngắn gọn, đọc lướt là hiểu. Chạm để chọn
/// chất lượng; giữ để xem giải thích đầy đủ.
class _ThermalPill extends StatelessWidget {
  const _ThermalPill({
    required this.onTap,
    this.onDismiss,
    this.temperatureC,
    this.userOverride = false,
    this.isCooledDown = false,
    this.isLocked = false,
    this.isThrottled = false,
    this.targetProfile,
    this.pendingIn,
    this.profile,
    this.loadLevel = 0,
  });

  final VoidCallback onTap;
  final VoidCallback? onDismiss;
  final double? temperatureC;
  final bool userOverride;
  final bool isCooledDown;
  final bool isLocked;
  final bool isThrottled;
  final CameraResolutionProfile? targetProfile;
  final Duration? pendingIn;
  final CameraResolutionProfile? profile;

  /// Bậc giảm tải tại chỗ của runtime (2 = nóng, 3 = critical).
  final int loadLevel;

  @override
  Widget build(BuildContext context) {
    final temp = temperatureC != null
        ? '${temperatureC!.toStringAsFixed(0)}°C'
        : null;
    String short(CameraResolutionProfile? p) =>
        p != null ? '${p.shortLabel}${p.fps}' : '720p30';
    String full(CameraResolutionProfile? p) =>
        p != null ? '${p.shortLabel} ${p.fps} FPS' : '720p 30 FPS';
    String withTemp(String text) => temp == null ? text : '$temp · $text';

    late final Color color;
    late final IconData icon;
    late final String label;
    late final String tooltip;
    if (isCooledDown) {
      color = const Color(0xFF69F0AE);
      icon = Icons.ac_unit_rounded;
      label = appText(context, 'Đã mát · nâng chất lượng', 'Cool · raise quality');
      tooltip = appText(
        context,
        'Máy đã mát. Chạm để chọn lại chất lượng video.',
        'Device has cooled down. Tap to choose video quality.',
      );
    } else if (targetProfile != null) {
      final secs = (pendingIn?.inSeconds ?? 0).clamp(0, 999);
      color = const Color(0xFFFFB74D);
      icon = Icons.timer_outlined;
      label = withTemp(
        secs < 5
            ? appText(
                context,
                'hạ ${short(targetProfile)}',
                'to ${short(targetProfile)}',
              )
            : appText(
                context,
                'hạ ${short(targetProfile)} sau ${secs}s',
                'to ${short(targetProfile)} in ${secs}s',
              ),
      );
      tooltip = appText(
        context,
        'Máy nóng: sẽ tự hạ xuống ${full(targetProfile)} để giảm nhiệt. Chạm để chọn chất lượng khác.',
        'Device is hot: lowering to ${full(targetProfile)} to cool down. Tap to choose another quality.',
      );
    } else if (isThrottled) {
      color = const Color(0xFFFFB74D);
      icon = Icons.whatshot_rounded;
      label = withTemp(
        appText(context, 'giảm nhiệt', 'cooling'),
      );
      tooltip = appText(
        context,
        'Đã hạ xuống ${full(profile)} để giữ máy mát. Chạm để chọn chất lượng khác.',
        'Lowered to ${full(profile)} to keep the device cool. Tap to choose another quality.',
      );
    } else if (userOverride || isLocked) {
      color = const Color(0xFFFF8A65);
      icon = isLocked ? Icons.lock_rounded : Icons.thermostat_rounded;
      label = withTemp(appText(context, 'máy nóng', 'hot'));
      tooltip = appText(
        context,
        'Máy nóng nhưng đang giữ ${full(profile)} theo lựa chọn của bạn.',
        'Device is hot but keeping ${full(profile)} as you selected.',
      );
    } else if (loadLevel >= 2) {
      color = const Color(0xFFFFB74D);
      icon = Icons.whatshot_rounded;
      label = withTemp(appText(context, 'giảm tải', 'reducing load'));
      tooltip = appText(
        context,
        'Máy nóng: đã giảm FPS/bitrate và làm tối màn hình. Giữ nguyên độ phân giải để Tablet và livestream không mất hình.',
        'Device is hot: FPS/bitrate reduced and screen dimmed. Resolution is kept so the tablet and livestream are not interrupted.',
      );
    } else {
      color = const Color(0xFFFFE082);
      icon = Icons.thermostat_rounded;
      label = withTemp(appText(context, 'máy ấm', 'warm'));
      tooltip = appText(
        context,
        'Máy hơi ấm, app đang theo dõi nhiệt độ.',
        'Device is warm; temperature is being monitored.',
      );
    }
    return _StatusPill(
      icon: icon,
      label: label,
      color: color,
      tooltip: tooltip,
      onTap: onTap,
      onClose: isCooledDown ? onDismiss : null,
    );
  }
}

/// Thanh trên: viên trạng thái + nút "Menu" có chữ.
class _StationHeader extends StatelessWidget {
  const _StationHeader({
    required this.compact,
    required this.landscape,
    required this.statusPills,
    required this.menuOpen,
    required this.onToggleMenu,
  });

  final bool compact;
  final bool landscape;
  final List<Widget> statusPills;
  final bool menuOpen;
  final VoidCallback onToggleMenu;

  @override
  Widget build(BuildContext context) {
    final menuButton = _MenuButton(open: menuOpen, onTap: onToggleMenu);
    if (landscape) {
      return Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              // Máy hẹp: hàng trạng thái tự cuộn ngang, không đẩy nút Menu.
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < statusPills.length; i++) ...[
                      if (i > 0) const SizedBox(width: 6),
                      statusPills[i],
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          menuButton,
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _GlassSurface(
              radius: 10,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: SizedBox(
                width: compact ? 70 : 84,
                height: compact ? 22 : 26,
                child: Image.asset(
                  'assets/images/vnvar_logo.png',
                  fit: BoxFit.contain,
                ),
              ),
            ),
            const Spacer(),
            menuButton,
          ],
        ),
        SizedBox(height: compact ? 6 : 8),
        Wrap(spacing: 6, runSpacing: 6, children: statusPills),
      ],
    );
  }
}

/// Nút mở/đóng menu: có chữ để người dùng nhìn là biết.
class _MenuButton extends StatelessWidget {
  const _MenuButton({required this.open, required this.onTap});

  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: open
          ? appText(context, 'Đóng menu', 'Close menu')
          : appText(context, 'Mở menu chức năng', 'Open menu'),
      child: _GlassSurface(
        radius: 15,
        color: open ? _accentBlue : _glassColor,
        borderColor: open ? Colors.transparent : const Color(0x33FFFFFF),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              height: 30,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 11),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      open ? Icons.close_rounded : Icons.menu_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      open
                          ? appText(context, 'Đóng', 'Close')
                          : appText(context, 'Menu', 'Menu'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
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

/// Menu chức năng: một hàng nút nhỏ, gọn.
class _QuickMenuPanel extends StatelessWidget {
  const _QuickMenuPanel({required this.tiles});

  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
    return _GlassSurface(
      radius: 14,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(mainAxisSize: MainAxisSize.min, children: tiles),
    );
  }
}

/// Một nút trong menu: biểu tượng nhỏ + nhãn ngắn bên dưới.
class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.label,
    required this.tooltip,
    this.icon,
    this.custom,
    this.onTap,
    this.active = false,
    this.activeColor = _accentBlue,
  });

  static const double width = 52;

  final String label;
  final String tooltip;
  final IconData? icon;

  /// Nút tự xử lý chạm (ví dụ chọn ngôn ngữ).
  final Widget? custom;
  final VoidCallback? onTap;
  final bool active;
  final Color activeColor;

  @override
  Widget build(BuildContext context) {
    final body = SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 30,
              child: Center(
                child: custom ??
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: active
                            ? activeColor.withValues(alpha: 0.9)
                            : Colors.white.withValues(alpha: 0.10),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(icon, size: 17, color: Colors.white),
                    ),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
    if (custom != null) return body;
    return Tooltip(
      message: tooltip,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: body,
        ),
      ),
    );
  }
}

/// Cụm nút camera dọc ở mép phải, luôn hiện.
class _CameraDock extends StatelessWidget {
  const _CameraDock({required this.buttons});

  final List<Widget> buttons;

  @override
  Widget build(BuildContext context) {
    return _GlassSurface(
      radius: 22,
      padding: const EdgeInsets.all(5),
      // Màn hình rất thấp (menu đang mở): cụm nút tự cuộn, không tràn.
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < buttons.length; i++) ...[
              if (i > 0) const SizedBox(height: 6),
              buttons[i],
            ],
          ],
        ),
      ),
    );
  }
}

class _DockButton extends StatelessWidget {
  const _DockButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.loading = false,
    this.background,
  });

  static const double size = 36;

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool loading;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: background ?? Colors.white.withValues(alpha: 0.10),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: loading
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      icon,
                      size: 18,
                      color: onTap == null ? Colors.white30 : Colors.white,
                    ),
            ),
          ),
        ),
      ),
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
