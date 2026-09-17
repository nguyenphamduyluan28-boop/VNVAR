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
import 'package:wakelock_plus/wakelock_plus.dart';
import 'setup_screen.dart';
import 'video_storage_screen.dart';

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

  bool get _recording => _runtime.recordingService?.recording ?? false;

  bool get _cameraReady =>
      _runtime.cameraEnabled &&
      (_runtime.webRtcService?.cameraInitialized ?? false);

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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              appText(
                context,
                'Không thể đổi trạng thái camera: $error',
                'Cannot change camera state: $error',
              ),
            ),
          ),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              appText(
                context,
                'Không thể thay đổi độ sáng màn hình: $error',
                'Cannot change screen brightness: $error',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _screenDimSwitching = false);
    }
  }

  Future<void> _quickSelectZoom(double target) async {
    final webRtc = _runtime.webRtcService;
    if (webRtc == null) return;
    try {
      if (target < 0.95) {
        if (webRtc.hasUltraWideCamera) {
          await _runtime.switchToLensMode('ultra_wide');
          if (mounted) {
            final actualRatio = webRtc.ultraWideZoomRatio;
            setState(() => _zoomValue = actualRatio);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  appText(
                    context,
                    'Đã chuyển sang Camera góc rộng (${webRtc.ultraWideLabel})',
                    'Switched to Wide-Angle camera (${webRtc.ultraWideLabel})',
                  ),
                ),
                duration: const Duration(seconds: 1),
              ),
            );
          }
        } else {
          try {
            await webRtc.setCameraZoom(target);
            if (mounted) setState(() => _zoomValue = webRtc.cameraZoom);
          } catch (_) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    appText(
                      context,
                      'Thiết bị này không có camera góc rộng (${target.toStringAsFixed(1)}×)',
                      'This device does not have a wide-angle camera (${target.toStringAsFixed(1)}×)',
                    ),
                  ),
                  duration: const Duration(seconds: 2),
                ),
              );
            }
          }
        }
      } else if (target == 1.0) {
        if (webRtc.isCurrentUltraWide || webRtc.currentFacingMode == 'user') {
          await _runtime.switchToLensMode('wide');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  appText(
                    context,
                    'Đã chuyển sang Camera góc chuẩn (1×)',
                    'Switched to standard camera (1×)',
                  ),
                ),
                duration: const Duration(seconds: 1),
              ),
            );
          }
        }
        await webRtc.setCameraZoom(1.0);
        if (mounted) setState(() => _zoomValue = 1.0);
      } else if (target == 2.0) {
        if (webRtc.isCurrentUltraWide || webRtc.currentFacingMode == 'user') {
          await _runtime.switchToLensMode('wide');
        }
        await webRtc.setCameraZoom(2.0);
        if (mounted) setState(() => _zoomValue = 2.0);
      }
    } catch (e) {
      debugPrint('[CAMERA] Quick select zoom error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              appText(
                context,
                'Không thể chuyển đổi camera: $e',
                'Cannot switch camera: $e',
              ),
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  void _changeZoom(double value) {
    setState(() => _zoomValue = value);
    _zoomDebounce?.cancel();
    _zoomDebounce = Timer(const Duration(milliseconds: 50), () async {
      final webRtc = _runtime.webRtcService;
      if (webRtc == null) return;
      try {
        if (value < 0.85 && !webRtc.isCurrentUltraWide && webRtc.hasUltraWideCamera) {
          await _quickSelectZoom(webRtc.ultraWideZoomRatio);
          return;
        } else if (value >= 1.0 && webRtc.isCurrentUltraWide) {
          await _runtime.switchToLensMode('wide');
        }
        await webRtc.setCameraZoom(value);
        if (mounted) setState(() => _zoomValue = webRtc.cameraZoom);
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          appText(
            context,
            'Camera vẫn hoạt động nhưng RTSP không thể khởi động: $error',
            'The camera is running, but RTSP could not start: $error',
          ),
        ),
      ),
    );
  }

  Future<void> _switchCameraLens() async {
    if (_lensSwitching || !_cameraReady) return;
    setState(() => _lensSwitching = true);
    try {
      await _runtime.switchCamera();
      if (mounted) {
        final webRtc = _runtime.webRtcService;
        final isUw = webRtc?.isCurrentUltraWide ?? false;
        final isUser = webRtc?.currentFacingMode == 'user';
        final msg = isUser
            ? appText(context, 'Đã chuyển sang Camera trước', 'Switched to front camera')
            : isUw
                ? appText(context, 'Đã chuyển sang Camera góc siêu rộng (0.5×)', 'Switched to Ultra-Wide (0.5×)')
                : appText(context, 'Đã chuyển sang Camera sau chuẩn (1×)', 'Switched to Rear standard camera (1×)');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            duration: const Duration(seconds: 1),
          ),
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
        }
      });
    }
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
      ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            appText(
              context,
              _runtime.lanAddress == null
                  ? 'Chưa có IP Wi-Fi/LAN. Camera vẫn đang ghi và sẽ tự kết nối khi có mạng.'
                  : 'Đã khởi động lại kết nối live. Camera và video đang ghi không bị reset.',
              _runtime.lanAddress == null
                  ? 'No Wi-Fi/LAN IP yet. Recording continues and live will reconnect automatically.'
                  : 'Live connection restarted. Camera and recording were not reset.',
            ),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            appText(
              context,
              'Không thể làm mới kết nối: $error',
              'Cannot refresh connection: $error',
            ),
          ),
        ),
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
            onConfigured: (identity) {
              Navigator.of(setupContext).pop(identity);
            },
          );
        },
      ),
    );

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
    if (selected == null || !mounted) return;
    try {
      await _runtime.setResolutionProfile(selected);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              appText(
                context,
                'Không thể đổi chất lượng camera: $error',
                'Cannot change camera quality: $error',
              ),
            ),
          ),
        );
      }
    }
  }

  Widget _buildResolutionPicker(BuildContext sheetContext) {
    final media = MediaQuery.of(sheetContext);
    final profiles = _runtime.supportedResolutionProfiles;
    final landscape = media.orientation == Orientation.landscape;
    final columns = landscape && media.size.width >= 560 ? 2 : 1;
    final rows = (profiles.length / columns).ceil();
    final contentHeight = 58.0 + (rows * 88.0) + ((rows - 1) * 10.0) + 16.0;
    final maximumHeight = (media.size.height * (landscape ? 0.72 : 0.48)).clamp(
      220.0,
      400.0,
    );
    final sheetHeight = contentHeight < maximumHeight
        ? contentHeight
        : maximumHeight;

    return SafeArea(
      child: SizedBox(
        height: sheetHeight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                appText(context, 'CHẤT LƯỢNG CAMERA', 'CAMERA QUALITY'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                ),
              ),
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
                    final active =
                        profile.preset == _runtime.resolutionProfile.preset;
                    final displayProfile = active
                        ? _runtime.resolutionProfile
                        : profile;
                    return Material(
                      color: active
                          ? const Color(0xFF183728)
                          : const Color(0xFF1A2028),
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: active
                            ? null
                            : () => Navigator.pop(sheetContext, profile),
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
                                    : Icons.radio_button_unchecked_rounded,
                                color: active
                                    ? Colors.greenAccent
                                    : Colors.white38,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      displayProfile.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${displayProfile.width} × ${displayProfile.height}  •  '
                                      '${displayProfile.fps} FPS\n'
                                      '${(displayProfile.bitrate / 1000000).toStringAsFixed(1)} Mbps',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white60,
                                        fontSize: 12,
                                        height: 1.2,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
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
  }

  void _handleResolutionPressed() {
    if (_runtime.thermalWarning) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              appText(
                context,
                'Thiết bị đang nóng. Chất lượng tạm khóa ở '
                    '${_runtime.resolutionProfile.shortLabel}/'
                    '${_runtime.resolutionProfile.fps} FPS và sẽ tự khôi phục khi nhiệt độ ổn định.',
                'Device temperature is high. Quality is temporarily locked at '
                    '${_runtime.resolutionProfile.shortLabel}/'
                    '${_runtime.resolutionProfile.fps} FPS and will recover when temperature is stable.',
              ),
            ),
          ),
        );
      return;
    }
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
                  const Text(
                    'CAMERA STATION ERROR',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _error ?? '',
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
                RotatedBox(
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

              // ==============================================
              // TOP BAR (identity + primary actions)
              // ==============================================
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
                    child: _StationHeader(
                      identity: widget.identity,
                      courtLabel: _courtLabel(widget.identity.courtId),
                      recording: _recording,
                      thermalWarning: _runtime.thermalWarning,
                      compact: compact,
                      landscape: landscape,
                      resolutionProfile: _runtime.resolutionProfile,
                      resolutionSwitching: _runtime.profileSwitching,
                      onVideoStorage: _openVideoStorage,
                      onResolution: _handleResolutionPressed,
                      onSettings: _openSettings,
                    ),
                  ),
                ),
              ),

              if (_runtime.thermalWarning && !landscape)
                Positioned(
                  top: compact ? 128 : 144,
                  left: compact ? 8 : 14,
                  right: compact ? 8 : 14,
                  child: SafeArea(
                    bottom: false,
                    child: _ThermalToast(
                      compact: compact,
                      landscape: landscape,
                    ),
                  ),
                ),

              // ==============================================
              // RIGHT-SIDE CAMERA CONTROLS
              // ==============================================
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
                      onRotate: _cameraReady
                          ? () {
                              final nextTurns = (_cameraQuarterTurns + 1) % 4;
                              setState(() {
                                _cameraQuarterTurns = nextTurns;
                              });
                              unawaited(
                                _runtime.setCameraQuarterTurns(nextTurns),
                              );
                            }
                          : null,
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
                                _runtime.webRtcService?.maximumCameraZoom ?? 10.0,
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
            ],
          );
        },
      ),
    );
  }
}

class _ThermalToast extends StatelessWidget {
  const _ThermalToast({required this.compact, required this.landscape});

  final bool compact;
  final bool landscape;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: landscape ? (compact ? 310 : 430) : double.infinity,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 8 : 10,
              vertical: compact ? 5 : 7,
            ),
            decoration: BoxDecoration(
              color: const Color(0xFF2A1C08).withValues(alpha: 0.38),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.amber.withValues(alpha: 0.42)),
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
                  Icons.warning_amber_rounded,
                  color: Colors.amber,
                  size: compact ? 14 : 16,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    appText(
                      context,
                      'Thiết bị đang nóng. Đã giảm xuống 720p/15 FPS để bảo vệ camera.',
                      'Device temperature is high. Reduced to 720p/15 FPS to protect the camera.',
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.amber.shade100,
                      fontSize: compact ? 9 : 10,
                      height: 1.15,
                      fontWeight: FontWeight.w700,
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
        : minimum.clamp(1.0, maximum);
    final safeValue = value.clamp(effectiveMin, maximum).toDouble();
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
                  selected: (safeValue - ultraWideRatio).abs() < 0.12,
                  compact: compact,
                  onTap: () => onQuickSelect(ultraWideRatio),
                ),
                const SizedBox(width: 4),
              ],
              _ZoomPresetButton(
                label: '1×',
                selected: (safeValue - 1.0).abs() < 0.12,
                compact: compact,
                onTap: () => onQuickSelect(1.0),
              ),
              const SizedBox(width: 4),
              _ZoomPresetButton(
                label: '2×',
                selected: (safeValue - 2.0).abs() < 0.15,
                compact: compact,
                onTap: () => onQuickSelect(2.0),
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
          Row(
            children: [
              Icon(
                Icons.remove_rounded,
                color: Colors.white70,
                size: compact ? 16 : 18,
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: compact ? 2.5 : 3.0,
                    thumbShape: RoundSliderThumbShape(
                      enabledThumbRadius: compact ? 6 : 7,
                    ),
                    overlayShape: RoundSliderOverlayShape(
                      overlayRadius: compact ? 12 : 14,
                    ),
                  ),
                  child: Slider(
                    value: safeValue,
                    min: effectiveMin,
                    max: maximum,
                    divisions: ((maximum - effectiveMin) * 10).round().clamp(1, 100),
                    onChanged: onChanged,
                  ),
                ),
              ),
              Icon(
                Icons.add_rounded,
                color: Colors.white70,
                size: compact ? 16 : 18,
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
              ? Colors.amber.withValues(alpha: 0.9)
              : Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? Colors.amberAccent
                : Colors.white.withValues(alpha: 0.15),
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white,
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
  final bool compact;
  final bool landscape;
  final CameraResolutionProfile resolutionProfile;
  final bool resolutionSwitching;
  final VoidCallback onVideoStorage;
  final VoidCallback? onResolution;
  final VoidCallback onSettings;

  const _StationHeader({
    required this.identity,
    required this.courtLabel,
    required this.recording,
    required this.thermalWarning,
    required this.compact,
    required this.landscape,
    required this.resolutionProfile,
    required this.resolutionSwitching,
    required this.onVideoStorage,
    required this.onResolution,
    required this.onSettings,
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
                if (thermalWarning) ...[
                  const SizedBox(height: 10),
                  _ThermalToast(compact: compact, landscape: true),
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
          // ROW 1 — camera info (left) + settings cluster
          // (right), all on one line. Name shrinks via Expanded
          // so the trailing cluster never gets pushed off.
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
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  identity.cameraName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: compact ? 14 : 16,
                    fontWeight: FontWeight.w900,
                    height: 1.0,
                  ),
                ),
              ),
              SizedBox(width: compact ? 6 : 8),
              _RecordingChip(recording: recording, compact: compact),
              SizedBox(width: compact ? 6 : 8),
              _HeaderIconButton(
                icon: Icons.video_settings_rounded,
                tooltip: appText(context, 'Kho video', 'Video storage'),
                size: actionSize,
                onTap: onVideoStorage,
              ),
              SizedBox(width: compact ? 4 : 6),
              AppLanguageButton(
                foregroundColor: Colors.white,
                size: actionSize,
              ),
              SizedBox(width: compact ? 4 : 6),
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

          SizedBox(height: compact ? 8 : 10),
          Divider(
            height: 1,
            thickness: 1,
            color: Colors.white.withValues(alpha: 0.08),
          ),
          SizedBox(height: compact ? 8 : 10),

          // -------------------------------------------------
          // ROW 3 — identifiers only (camera / court / position)
          // -------------------------------------------------
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _ResolutionChip(
                profile: resolutionProfile,
                switching: resolutionSwitching,
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
  final VoidCallback? onTap;

  const _ResolutionChip({
    required this.profile,
    required this.switching,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1565C0).withValues(alpha: 0.8),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: switching ? null : onTap,
        child: Padding(
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

  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.size,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.12),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, color: Colors.white, size: size * 0.53),
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
  final VoidCallback? onRotate;
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
    required this.onRotate,
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _DockButton(
            icon: Icons.rotate_90_degrees_cw_rounded,
            tooltip: appText(
              context,
              'Xoay hình camera 90°',
              'Rotate camera 90°',
            ),
            size: buttonSize,
            onPressed: onRotate,
          ),
          SizedBox(height: gap),
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
                ? Colors.amber.withValues(alpha: 0.8)
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
                ? Colors.blueAccent.withValues(alpha: 0.8)
                : screenOrientation == 'portrait'
                    ? Colors.amber.withValues(alpha: 0.8)
                    : null,
          ),
        ],
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
