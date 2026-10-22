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
import '../services/station_config_service.dart';
import '../services/station_display_service.dart';
import '../services/station_errors.dart';
import '../services/station_platform_events.dart';
import '../services/whip_publisher_service.dart';
import '../services/rtsp_publisher_service.dart';
import '../services/scoreboard_service.dart' show ScoreboardService;
import '../theme/app_theme.dart';
import '../widgets/app_notice.dart';
import '../widgets/brand_widgets.dart';
import '../widgets/scoreboard_hub_dialog.dart';
import 'station/station_ui_logic.dart';
import 'setup_screen.dart';
import 'video_storage_screen.dart';
import 'live_stream_screen.dart';

part 'station/station_camera_controls.dart';
part 'station/station_overlay_widgets.dart';
part 'station/station_resolution_sheet.dart';

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

/// Yêu cầu zoom đưa vào hàng đợi latest-wins: [quick] = nút chọn nhanh
/// (0.5×/1×/2×/5×), ngược lại là thanh trượt/nút bước.
@immutable
class _ZoomRequest {
  const _ZoomRequest(this.value, {required this.quick});

  final double value;
  final bool quick;

  @override
  bool operator ==(Object other) =>
      other is _ZoomRequest && other.value == value && other.quick == quick;

  @override
  int get hashCode => Object.hash(value, quick);
}

class _StationScreenState extends State<StationScreen>
    with WidgetsBindingObserver {
  static const MethodChannel _platformChannel = MethodChannel(
    'vnvar/camera_station_service',
  );
  final CameraStationRuntime _runtime = CameraStationRuntime.instance;

  StreamSubscription<void>? _runtimeSubscription;
  StreamSubscription<WhipPublishState>? _whipSubscription;
  StreamSubscription<RtspPublishState>? _rtspSubscription;

  /// Cờ overlay bảng tỉ số (in vào live / đang hiện) cho viên "Tỉ số ẩn":
  /// chỉ viên đó dựng lại khi bảng tỉ số đổi, không dựng lại cả màn hình.
  final ValueNotifier<ScoreOverlayFlags> _scoreOverlay =
      ValueNotifier<ScoreOverlayFlags>(defaultScoreOverlayFlags);
  StreamSubscription<Map<String, dynamic>>? _scoreboardSubscription;

  /// Trạng thái RTSP/WHIP đã hiển thị lần trước: onStateChanged phát mỗi giây
  /// (thời lượng live), chỉ dựng lại màn hình khi trạng thái/lỗi/ý định phát
  /// thật sự thay đổi. Đồng hồ LIVE tự cập nhật qua durationListenable.
  Object? _lastRtspSignature;
  Object? _lastWhipSignature;

  bool _loading = true;

  /// Lỗi khởi tạo (đối tượng lỗi gốc); thông báo được dịch lúc build theo
  /// ngôn ngữ đang chọn.
  Object? _error;

  /// Cấu hình mới đã chọn nhưng khởi động lỗi. "Thử lại" và lần tự khởi tạo
  /// lại của runtime đều dùng cấu hình này; chỉ lưu khi chạy được.
  StationIdentity? _pendingIdentity;

  /// Đã rời app (paused/hidden) trong lúc đang ở màn lỗi: khi quay lại mà lỗi
  /// là thiếu quyền thì tự thử khởi tạo lại một lần (người dùng có thể vừa
  /// cấp quyền trong Cài đặt).
  bool _leftAppSinceError = false;
  bool _handlingRuntimeRecovery = false;

  int _cameraQuarterTurns = 0;
  bool _cameraSwitching = false;

  /// Đang đổi camera trước/sau.
  bool _facingSwitching = false;

  /// Thao tác zoom đang đổi ống kính vật lý (siêu rộng ↔ chính). Chỉ thao tác
  /// đặt cờ mới được xoá cờ (hàng đợi zoom chạy tuần tự).
  bool _zoomLensSwitching = false;
  bool get _lensSwitching => _facingSwitching || _zoomLensSwitching;

  bool _screenDimmed = false;
  bool _screenDimSwitching = false;
  String? _lastShownRtspError;
  Timer? _zoomDebounce;
  double? _zoomValue;

  /// Zoom/đổi ống kính chạy tuần tự, chỉ giữ yêu cầu mới nhất: bấm chồng
  /// nhiều nút không còn cho kết quả không xác định.
  late final LatestWinsRunner<_ZoomRequest> _zoomRunner =
      LatestWinsRunner<_ZoomRequest>(
        _applyZoomRequest,
        onError: _handleZoomError,
      );

  /// Độ sáng (EV) người dùng vừa chọn, chưa áp dụng xong. Bước kế tiếp tính
  /// từ giá trị này nên bấm nhanh liên tiếp không bị mất bước.
  double? _pendingEv;
  late final LatestWinsRunner<double> _exposureRunner =
      LatestWinsRunner<double>(
        (ev) => _runtime.setExposureBias(ev),
        onError: _handleExposureError,
        onIdle: () {
          if (mounted) setState(() => _pendingEv = null);
        },
      );

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
      // Đang PiP (hình nhỏ vẫn hiện), đang khởi động/lỗi, hoặc màn hình
      // Station đang bị màn khác/hộp thoại che: không nghỉ, thử lại sau.
      final routeCurrent = ModalRoute.of(context)?.isCurrent ?? true;
      if (_isInPipMode || _loading || _error != null || !routeCurrent) {
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

  /// Ngôn ngữ đang chọn (cùng nguồn với [appText]).
  bool get _english => AppLanguageScope.of(context).isEnglish;

  /// Thông báo lỗi cho người dùng theo ngôn ngữ đang chọn (đã rút gọn).
  String _errorText(Object error) =>
      compactErrorText(stationErrorMessage(error, english: _english));

  /// Lý do lỗi đã rút gọn theo ngôn ngữ chỉ định (không cần context).
  String _errorReason(Object error, {required bool english}) =>
      compactErrorText(stationErrorMessage(error, english: english));

  /// Cấu hình mà "Thử lại" sẽ khởi động.
  StationIdentity get _targetIdentity => _pendingIdentity ?? widget.identity;

  /// Gọi kênh native không chờ kết quả; lỗi chỉ ghi log.
  void _invokePlatformQuietly(String method, [Object? arguments]) {
    unawaited(
      _platformChannel.invokeMethod<void>(method, arguments).catchError((
        Object error,
      ) {
        debugPrint('[PLATFORM] $method thất bại: $error');
      }),
    );
  }

  /// Thông báo nổi chuẩn của app (song ngữ, icon theo loại). Bỏ qua khi màn
  /// hình Station không còn hiển thị.
  void _showStationToast({
    required String vi,
    required String en,
    NoticeKind kind = NoticeKind.info,
    Duration? duration,
  }) {
    if (!mounted) return;
    showAppNotice(context, vi: vi, en: en, kind: kind, duration: duration);
  }

  /// Thông báo lỗi kèm lý do (song ngữ).
  void _showErrorToast(
    Object error, {
    required String vi,
    required String en,
  }) {
    _showStationToast(
      vi: '$vi: ${_errorReason(error, english: false)}',
      en: '$en: ${_errorReason(error, english: true)}',
      kind: NoticeKind.error,
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
          vi: 'Không bật/tắt được camera. Thử lại sau.',
          en: "Couldn't toggle the camera. Try again.",
          kind: NoticeKind.error,
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
          vi: 'Không chỉnh được độ sáng màn hình.',
          en: "Couldn't adjust screen brightness.",
          kind: NoticeKind.error,
        );
      }
    } finally {
      if (mounted) setState(() => _screenDimSwitching = false);
    }
  }

  /// Nút chọn nhanh zoom: xếp vào hàng đợi latest-wins (bấm 2× rồi 5× liên
  /// tiếp thì chỉ 5× được áp dụng sau thao tác đang chạy).
  void _quickSelectZoom(double target) {
    _zoomDebounce?.cancel();
    setState(() => _zoomValue = target);
    unawaited(_zoomRunner.submit(_ZoomRequest(target, quick: true)));
  }

  void _changeZoom(double value) {
    setState(() => _zoomValue = value);
    _zoomDebounce?.cancel();
    _zoomDebounce = Timer(const Duration(milliseconds: 60), () {
      if (!mounted) return;
      unawaited(_zoomRunner.submit(_ZoomRequest(value, quick: false)));
    });
  }

  Future<void> _applyZoomRequest(_ZoomRequest request) {
    return request.quick
        ? _performQuickSelectZoom(request.value)
        : _performZoomChange(request.value);
  }

  void _setZoomLensSwitching(bool switching) {
    if (!mounted || _zoomLensSwitching == switching) return;
    setState(() => _zoomLensSwitching = switching);
  }

  Future<void> _performQuickSelectZoom(double target) async {
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

    if (willSwitchHardware) _setZoomLensSwitching(true);
    try {
      if (target < 0.95) {
        if (webRtc.hasUltraWideCamera) {
          await _runtime.switchToLensMode('ultra_wide');
          final actualRatio = webRtc.ultraWideZoomRatio;
          await _runtime.setCameraZoom(actualRatio);
          _showZoomResult(actualRatio);
        } else {
          await _runtime.setCameraZoom(target);
          _showZoomResult(webRtc.cameraZoom);
        }
      } else if (target >= 0.95 && target < 1.5) {
        if (webRtc.isCurrentUltraWide || webRtc.currentFacingMode == 'user') {
          await _runtime.switchToLensMode('wide');
        }
        await _runtime.setCameraZoom(1.0);
        _showZoomResult(1.0);
      } else if (target >= 1.5) {
        if (webRtc.isCurrentUltraWide || webRtc.currentFacingMode == 'user') {
          await _runtime.switchToLensMode('wide');
        }
        await _runtime.setCameraZoom(target);
        _showZoomResult(target);
      }
    } finally {
      if (willSwitchHardware) _setZoomLensSwitching(false);
    }
  }

  Future<void> _performZoomChange(double value) async {
    final webRtc = _runtime.webRtcService;
    if (webRtc == null) return;
    final willSwitchHardwareToUW = value < 0.95 &&
        !webRtc.isCurrentUltraWide &&
        webRtc.ultraWideCamera != null &&
        webRtc.activeCameraId != webRtc.ultraWideCamera!.id;
    final willSwitchHardwareToWide = value >= 0.95 &&
        webRtc.isCurrentUltraWide &&
        webRtc.mainBackCamera != null &&
        webRtc.activeCameraId != webRtc.mainBackCamera!.id;

    if (willSwitchHardwareToUW) {
      _setZoomLensSwitching(true);
      try {
        await _runtime.switchToLensMode('ultra_wide');
      } finally {
        _setZoomLensSwitching(false);
      }
    } else if (willSwitchHardwareToWide) {
      _setZoomLensSwitching(true);
      try {
        await _runtime.switchToLensMode('wide');
      } finally {
        _setZoomLensSwitching(false);
      }
    }
    await _runtime.setCameraZoom(value);
    _showZoomResult(value);
  }

  /// Người dùng đã chọn mức zoom mới (còn chờ trong hàng đợi hoặc đang kéo
  /// thanh trượt): kết quả của thao tác vừa chạy xong đã lỗi thời.
  bool get _zoomResultStale =>
      _zoomRunner.hasPending || (_zoomDebounce?.isActive ?? false);

  /// Hiển thị kết quả zoom thật sau khi áp dụng, trừ khi đã có yêu cầu mới
  /// hơn: khi đó UI giữ giá trị mục tiêu mới nhất của người dùng (tránh thanh
  /// zoom nhảy về giá trị cũ rồi lại nhảy tới giá trị mới).
  void _showZoomResult(double? value) {
    if (!mounted || _zoomResultStale) return;
    setState(() => _zoomValue = value);
  }

  void _handleZoomError(Object error, StackTrace stackTrace) {
    debugPrint('[CAMERA] Không đổi được zoom/ống kính: $error');
    if (!mounted) return;
    // Hiển thị lại mức zoom thật của camera thay vì giá trị vừa chọn (trừ khi
    // còn yêu cầu mới hơn đang chờ áp dụng).
    _showZoomResult(_runtime.webRtcService?.cameraZoom);
    _showErrorToast(
      error,
      vi: 'Không đổi được zoom',
      en: "Couldn't change zoom",
    );
  }

  /// Độ sáng: giữ giá trị chờ ở UI, áp dụng tuần tự (latest-wins).
  void _changeExposure(double ev) {
    setState(() => _pendingEv = ev);
    unawaited(_exposureRunner.submit(ev));
  }

  void _handleExposureError(Object error, StackTrace stackTrace) {
    debugPrint('[CAMERA] Không chỉnh được độ sáng: $error');
    if (!mounted) return;
    _showErrorToast(
      error,
      vi: 'Không chỉnh được độ sáng',
      en: "Couldn't adjust exposure",
    );
  }

  void _showRtspWarningIfNeeded() {
    final webRtc = _runtime.webRtcService;
    if (webRtc == null || !webRtc.rtspSupported) return;
    final error = webRtc.rtspError;
    if (!mounted || error == null || error == _lastShownRtspError) return;
    _lastShownRtspError = error;
    _showStationToast(
      vi: 'Vẫn đang ghi hình. Live đang kết nối lại.',
      en: 'Still recording. Live is reconnecting.',
      kind: NoticeKind.warning,
    );
  }

  Future<void> _switchCameraLens() async {
    if (_lensSwitching || _zoomRunner.busy || !_cameraReady) return;
    _zoomDebounce?.cancel();
    setState(() => _facingSwitching = true);
    try {
      await _runtime.switchCamera();
      if (mounted) {
        final webRtc = _runtime.webRtcService;
        final isUser = webRtc?.currentFacingMode == 'user';
        _showStationToast(
          vi: isUser ? 'Đã chuyển camera trước' : 'Đã chuyển camera sau',
          en: isUser ? 'Switched to front camera' : 'Switched to rear camera',
          kind: NoticeKind.success,
          duration: const Duration(seconds: 1),
        );
      }
    } catch (error) {
      debugPrint('[CAMERA] Bỏ qua yêu cầu đổi camera: $error');
      if (mounted) {
        _showErrorToast(
          error,
          vi: 'Không đổi được camera',
          en: "Couldn't switch camera",
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _facingSwitching = false;
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
            !_zoomRunner.busy &&
            (_zoomDebounce == null || !_zoomDebounce!.isActive)) {
          _zoomValue = _runtime.webRtcService?.cameraZoom;
        }
      });
      _showRtspWarningIfNeeded();
      _syncInitErrorFromRuntime();
    });

    _scoreboardSubscription = ScoreboardService.instance.changes.listen(
      (json) {
        if (!mounted) return;
        _scoreOverlay.value = readScoreOverlayFlags(json);
      },
    );
    unawaited(_syncScoreOverlay());

    // Wakelock do runtime quản lý (bật khi khởi tạo xong, tắt khi dừng).
    unawaited(_initScreenOrientation());
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
    // onStateChanged phát mỗi giây khi đang live (thời lượng): chỉ dựng lại
    // màn hình khi trạng thái/lỗi/ý định phát thay đổi.
    _lastWhipSignature = _whipSignature();
    _lastRtspSignature = _rtspSignature();
    _whipSubscription =
        _runtime.whipPublisherService.onStateChanged.listen((_) {
      final signature = _whipSignature();
      if (signature == _lastWhipSignature) return;
      _lastWhipSignature = signature;
      if (mounted) setState(() {});
    });
    _rtspSubscription =
        _runtime.rtspPublisherService.onStateChanged.listen((_) {
      final signature = _rtspSignature();
      if (signature == _lastRtspSignature) return;
      _lastRtspSignature = signature;
      if (mounted) setState(() {});
    });

    _initialize();
  }

  Object _whipSignature() {
    final whip = _runtime.whipPublisherService;
    return (whip.state, whip.currentError, whip.wantsPublishing);
  }

  Object _rtspSignature() {
    final rtsp = _runtime.rtspPublisherService;
    return (
      rtsp.state,
      rtsp.currentError,
      rtsp.wantsPublishing,
      rtsp.networkQuality,
    );
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

      // Rời hẳn app (không chỉ hộp thoại xin quyền làm app `inactive`) trong
      // lúc đang ở màn lỗi: có thể người dùng đi cấp quyền trong Cài đặt.
      if (_error != null && state != AppLifecycleState.inactive) {
        _leftAppSinceError = true;
      }

      // Khóa cứng ở tầng Android native ngay lập tức khi vuốt thanh thông báo hoặc tắt màn hình
      if (Platform.isAndroid) {
        _invokePlatformQuietly('lockOrientationForBackground');
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
        _invokePlatformQuietly('setScreenOrientation', {
          'mode': _screenOrientation,
        });
      }
      // Khôi phục hướng màn hình theo cấu hình người dùng
      unawaited(_applyScreenOrientation(_screenOrientation));
      _retryAfterPermissionSettingsIfNeeded();
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

  /// Quay lại app khi đang ở màn lỗi thiếu quyền: tự thử khởi tạo lại MỘT
  /// lần (người dùng có thể vừa cấp quyền trong Cài đặt).
  void _retryAfterPermissionSettingsIfNeeded() {
    final error = _error;
    if (!_leftAppSinceError || _loading || error == null) return;
    _leftAppSinceError = false;
    if (!_isPermissionError(error)) return;
    debugPrint('[STATION] Quay lại app từ màn lỗi quyền: thử khởi tạo lại');
    unawaited(_retry());
  }

  bool _isPermissionError(Object error) =>
      isPermissionDeniedError(error) || _runtime.initPermissionDenied;

  /// Runtime tự khởi tạo lại (backoff) trong lúc màn hình đang báo lỗi: cập
  /// nhật lỗi mới nhất, hoặc rời màn lỗi khi runtime đã chạy lại được.
  void _syncInitErrorFromRuntime() {
    if (_loading || _error == null || _handlingRuntimeRecovery) return;
    final runtimeError = _runtime.lastInitError;
    if (runtimeError != null) {
      if (!identical(runtimeError, _error)) {
        setState(() => _error = runtimeError);
      }
      return;
    }
    if (_runtime.ready) unawaited(_handleRuntimeRecovered());
  }

  Future<void> _handleRuntimeRecovered() async {
    _handlingRuntimeRecovery = true;
    try {
      debugPrint('[STATION] Runtime đã tự khởi tạo lại thành công');
      setState(() {
        _error = null;
        _leftAppSinceError = false;
      });
      final identity = _targetIdentity;
      // Khởi tạo lỗi đã dừng foreground service: bật lại khi camera đã chạy.
      await _startForegroundServiceAfterCamera(identity);
      await _commitPendingIdentity(identity);
      if (!mounted) return;
      _showStationToast(
        vi: 'Camera Station đã tự khởi động lại.',
        en: 'Camera Station restarted automatically.',
        kind: NoticeKind.success,
      );
    } finally {
      _handlingRuntimeRecovery = false;
    }
  }

  /// Cấu hình mới (đã chọn nhưng lần khởi động trước lỗi) vừa chạy được:
  /// lưu lại và báo lên trên.
  Future<void> _commitPendingIdentity(StationIdentity identity) async {
    final pending = _pendingIdentity;
    if (pending == null || pending != identity) return;
    _pendingIdentity = null;
    try {
      await StationConfigService().saveIdentity(pending);
    } catch (error) {
      debugPrint('[CONFIG] Không thể lưu cấu hình mới: $error');
    }
    if (!mounted) return;
    widget.onIdentityChanged(pending);
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
        _invokePlatformQuietly('setScreenOrientation', {'mode': mode});
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
    _showStationToast(
      vi: mode == 'landscape'
          ? 'Đã khoá xoay ngang'
          : mode == 'portrait'
              ? 'Đã khoá xoay dọc'
              : 'Đã bật tự xoay màn hình',
      en: mode == 'landscape'
          ? 'Landscape locked'
          : mode == 'portrait'
              ? 'Portrait locked'
              : 'Auto-rotate on',
      kind: NoticeKind.success,
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

  /// Địa chỉ trang xem cho Tablet, dịch theo ngôn ngữ hiện tại. Lấy từ
  /// runtime (đã chọn đúng giao diện LAN, kể cả iOS).
  String _viewerAddressText() {
    final address = _runtime.lanAddress;
    if (address != null) {
      final port =
          _runtime.cameraServer?.apiPort ?? CameraServer.defaultApiPort;
      return 'http://$address:$port/viewer';
    }
    if (_runtime.networkError != null) {
      return appText(
        context,
        'Không đọc được địa chỉ IP',
        "Couldn't read the IP address",
      );
    }
    return appText(context, 'Chưa kết nối Wi-Fi', 'No Wi-Fi connection');
  }

  Future<void> _reconnectNetwork() async {
    if (_runtime.networkRecovering) return;
    try {
      await _runtime.reconnectNetworkServices();
      if (!mounted) return;
      final noAddress = _runtime.lanAddress == null;
      _showStationToast(
        vi: noAddress
            ? 'Chưa có IP mạng. Vẫn ghi hình, sẽ tự kết nối lại.'
            : 'Đã làm mới kết nối mạng.',
        en: noAddress
            ? 'No network IP yet. Still recording; will reconnect.'
            : 'Network connection refreshed.',
        kind: noAddress ? NoticeKind.warning : NoticeKind.success,
      );
    } catch (error) {
      if (!mounted) return;
      _showStationToast(
        vi: 'Không làm mới được mạng. Kiểm tra Wi-Fi/LAN.',
        en: "Couldn't refresh network. Check Wi-Fi/LAN.",
        kind: NoticeKind.error,
      );
    }
  }

  // ============================================================
  // INITIALIZE
  // ============================================================

  /// Camera đã chạy: lỗi bật foreground service không được biến thành màn
  /// hình lỗi (camera/server vẫn chạy phía sau). Chỉ cảnh báo người vận hành.
  Future<void> _startForegroundServiceAfterCamera([
    StationIdentity? identity,
  ]) async {
    final target = identity ?? widget.identity;
    try {
      await CameraStationForegroundService.start(
        cameraId: target.cameraId,
        courtId: target.courtId,
      );
    } catch (error) {
      debugPrint('[STATION] Không thể bật foreground service: $error');
      if (!mounted) return;
      _showStationToast(
        vi: 'Không bật được chạy nền. Hãy giữ màn hình mở.',
        en: 'Background mode unavailable. Keep the screen on.',
        kind: NoticeKind.error,
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
        _error = error;
      });
    }
  }

  // ============================================================
  // RETRY
  // ============================================================

  Future<void> _retry() async {
    if (_loading) return;
    _leftAppSinceError = false;
    // Thử lại cấu hình vừa chọn (nếu lần áp dụng trước lỗi), giống lần tự
    // khởi tạo lại của runtime.
    final identity = _targetIdentity;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      await _runtime.restart(
        cameraId: identity.cameraId,
        courtId: identity.courtId,
        deviceId: identity.deviceId,
      );

      // Khởi tạo lỗi đã dừng foreground service; bật lại ngay khi camera đã
      // mở (đã có quyền), nếu không Android sẽ cắt camera khi tắt màn hình.
      await _startForegroundServiceAfterCamera(identity);
      await _commitPendingIdentity(identity);

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
        _error = error;
      });
    }
  }

  /// Mở trang Cài đặt của ứng dụng để cấp quyền camera/micro.
  Future<void> _openAppSettings() async {
    var opened = false;
    try {
      opened =
          await _platformChannel.invokeMethod<bool>('openAppSettings') ??
          false;
    } catch (error) {
      debugPrint('[STATION] Không mở được Cài đặt ứng dụng: $error');
    }
    if (opened || !mounted) return;
    _showStationToast(
      vi: 'Không mở được Cài đặt. Hãy cấp quyền Camera, Micro thủ công.',
      en: "Couldn't open Settings. Allow Camera and Mic manually.",
      kind: NoticeKind.error,
      duration: const Duration(seconds: 5),
    );
  }

  /// Đọc cờ overlay bảng tỉ số hiện tại (chờ service nạp trạng thái đã lưu;
  /// gọi nhiều lần vẫn an toàn). Thay đổi sau đó đến qua `changes`.
  Future<void> _syncScoreOverlay() async {
    final scoreboard = ScoreboardService.instance;
    try {
      await scoreboard.load();
    } catch (_) {
      // Không đọc được trạng thái đã lưu: dùng trạng thái hiện có.
    }
    if (!mounted) return;
    _scoreOverlay.value = readScoreOverlayFlags(scoreboard.snapshot());
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

    final change = classifyStationConfigChange(
      current: widget.identity,
      next: newIdentity,
      stationRunning: _runtime.ready && _error == null,
    );
    if (change == StationConfigChange.none) {
      // Không đổi gì: chỉ đóng màn cài đặt, không khởi động lại camera.
      return;
    }
    if (change == StationConfigChange.metadataOnly) {
      await _applyMetadataOnlyIdentity(newIdentity);
      return;
    }
    if (!mounted) return;

    // Khởi động lại sẽ cắt ngang segment đang ghi và phiên livestream.
    final interruptsCapture =
        _recording ||
        _runtime.isLiveStreaming ||
        _runtime.rtspPublisherService.wantsPublishing ||
        _runtime.whipPublisherService.wantsPublishing;

    final courtLabel = _courtLabel(newIdentity.courtId);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ApplyConfigDialog(
        identity: newIdentity,
        courtLabel: courtLabel,
        interruptsCapture: interruptsCapture,
      ),
    );

    if (confirmed != true || !mounted) {
      return;
    }

    final stationWasRunning = _runtime.ready;
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

      // Giữ thứ tự cũ: cập nhật foreground service theo sân mới TRƯỚC khi
      // khởi động lại, nhưng chỉ khi camera đang chạy (Android 14 chỉ cho bật
      // service loại camera|micro khi app đã có quyền). Lỗi ở bước này không
      // chặn việc áp dụng cấu hình.
      var foregroundStarted = false;
      if (stationWasRunning) {
        try {
          await CameraStationForegroundService.start(
            cameraId: newIdentity.cameraId,
            courtId: newIdentity.courtId,
          );
          foregroundStarted = true;
        } catch (error) {
          debugPrint('[CONFIG] Không thể cập nhật foreground service: $error');
        }
      }

      // Dừng + khởi tạo trong MỘT thao tác vòng đời của runtime (không để
      // health monitor/recovery chen vào giữa).
      await _runtime.restart(
        cameraId: newIdentity.cameraId,
        courtId: newIdentity.courtId,
        deviceId: newIdentity.deviceId,
      );

      if (!foregroundStarted) {
        await _startForegroundServiceAfterCamera(newIdentity);
      }

      // Chỉ lưu sau khi sân mới chạy được: nếu khởi tạo lỗi, cấu hình đã lưu
      // vẫn khớp với sân đang hiển thị.
      _pendingIdentity = null;
      // Camera đã chạy với cấu hình mới: lỗi LƯU không được rơi vào nhánh
      // lỗi khởi động (dừng chạy nền + màn lỗi) — chỉ cảnh báo.
      var saved = true;
      try {
        await StationConfigService().saveIdentity(newIdentity);
      } catch (saveError) {
        saved = false;
        debugPrint('[CONFIG] Không thể lưu cấu hình mới: $saveError');
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _loading = false;
        _error = null;
      });

      widget.onIdentityChanged(newIdentity);
      if (!saved) {
        _showStationToast(
          vi: 'Đã áp dụng nhưng chưa lưu; mở lại app có thể về cấu hình cũ.',
          en: 'Applied but not saved; may revert after restart.',
          kind: NoticeKind.warning,
        );
      }
    } catch (error, stackTrace) {
      debugPrint(
        '[CONFIG] APPLY ERROR: '
        '$error',
      );

      debugPrintStack(stackTrace: stackTrace);

      // Runtime tự thử lại với cấu hình mới; "Thử lại" cũng dùng cấu hình
      // này. Cấu hình chỉ được lưu khi chạy được.
      _pendingIdentity = newIdentity;

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
        _error = error;
      });
    }
  }

  /// Chỉ đổi tên/vị trí camera: lưu lại, không khởi động lại camera/server.
  Future<void> _applyMetadataOnlyIdentity(StationIdentity identity) async {
    try {
      await StationConfigService().saveIdentity(identity);
    } catch (error) {
      debugPrint('[CONFIG] Không thể lưu cấu hình: $error');
      if (!mounted) return;
      _showStationToast(
        vi: 'Không lưu được cấu hình. Thử lại sau.',
        en: "Couldn't save settings. Try again.",
        kind: NoticeKind.error,
      );
      return;
    }
    if (!mounted) return;
    widget.onIdentityChanged(identity);
    _showStationToast(
      vi: 'Đã lưu cấu hình',
      en: 'Settings saved',
      kind: NoticeKind.success,
    );
  }

  Future<void> _openVideoStorage() async {
    final recording = _runtime.recordingService;
    if (recording == null) return;
    // Chuỗi đã dịch tại thời điểm mở màn Lưu video.
    final viewerAddress = _viewerAddressText();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => VideoStorageScreen(
          recordingService: recording,
          viewerAddress: viewerAddress,
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
      backgroundColor: BrandColors.surface,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => _ResolutionPickerSheet(
        runtime: _runtime,
        showToast: _showStationToast,
        onChanged: () {
          if (mounted) setState(() {});
        },
      ),
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
        // Máy đang quá nóng (critical): runtime chỉ ghi nhận cấu hình mục
        // tiêu, chưa đổi camera.
        final deferredForThermal =
            _runtime.resolutionProfile != selected &&
            _runtime.thermalTargetProfile == selected;
        if (deferredForThermal) {
          _showStationToast(
            vi: 'Máy quá nóng: sẽ áp dụng ${selected.title} khi nguội.',
            en: 'Too hot: ${selected.title} will apply once cool.',
            kind: NoticeKind.warning,
            duration: const Duration(seconds: 4),
          );
        } else if (_runtime.thermalUserOverride) {
          _showStationToast(
            vi: 'Đã áp dụng ${selected.title}',
            en: 'Applied ${selected.title}',
            kind: NoticeKind.success,
          );
        }
      }
    } catch (error) {
      debugPrint('[CAMERA] Không đổi được chất lượng camera: $error');
      if (mounted) {
        _showStationToast(
          vi: error is StationException
              ? error.message(english: false)
              : 'Không đổi được chất lượng. Thử lại sau.',
          en: error is StationException
              ? error.message(english: true)
              : "Couldn't change quality. Try again shortly.",
          kind: NoticeKind.error,
        );
      }
    }
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

    return appText(context, 'Sân $number', 'Court $number');
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
    _scoreboardSubscription?.cancel();
    _scoreOverlay.dispose();
    _zoomDebounce?.cancel();
    _zoomRunner.dispose();
    _exposureRunner.dispose();
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
      _invokePlatformQuietly('setScreenOrientation', {'mode': 'portrait'});
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

  Widget _buildLoading() => const _StationLoadingView();

  // ============================================================
  // ERROR
  // ============================================================

  String _formatErrorMessage(BuildContext context, Object? error) {
    if (error == null || error.toString().trim().isEmpty) {
      return appText(
        context,
        'Không khởi động được camera. Kiểm tra quyền camera rồi thử lại.',
        "Couldn't start the camera. Check camera permission and retry.",
      );
    }
    // Lỗi có mã (gồm thiếu quyền) đã có thông báo hai ngôn ngữ.
    if (error is StationException || _isPermissionError(error)) {
      return _errorText(error);
    }
    final lower = error.toString().toLowerCase();
    if (lower.contains('camera') &&
        (lower.contains('busy') ||
            lower.contains('bận') ||
            lower.contains('in use') ||
            lower.contains('locked'))) {
      return appText(
        context,
        'Camera đang bận hoặc app khác đang dùng. Thử lại sau giây lát.',
        'Camera is busy or used by another app. Try again shortly.',
      );
    }
    if (lower.contains('đã xảy ra lỗi không xác định') ||
        lower.contains('unknown error') ||
        lower.contains('bad state')) {
      return appText(
        context,
        'Kết nối camera gặp sự cố. Bấm Thử lại để khôi phục.',
        'Camera connection failed. Tap Try again to recover.',
      );
    }
    return _errorText(error);
  }

  Widget _buildError() {
    final error = _error;
    final permissionError = error != null && _isPermissionError(error);
    return _StationErrorView(
      message: _formatErrorMessage(context, error),
      permissionError: permissionError,
      retryAt: permissionError ? null : _runtime.nextInitRetryAt,
      onOpenSettings: _openAppSettings,
      onRetry: _retry,
    );
  }

  // ============================================================
  // STATION
  // ============================================================

  // ============================================================
  // BỐ CỤC ĐIỀU KHIỂN TRÊN MÀN HÌNH CAMERA (kiểu bảng điều khiển phát sóng)
  //
  // Dọc:   [logo ........................ (≡)]
  //        [REC][1080p·30][38°C][LIVE]   (cuộn ngang)
  //        [thông báo mạng/bộ nhớ]
  //        ..................................(rail)
  //        [ 0.5× 1× 2× 5× ] (zoom) (độ sáng)
  // Ngang: [logo][REC][1080p·30]…                (≡)
  //        [thông báo]                          (rail)
  //             [ 0.5× 1× 2× 5× ] (zoom) (sáng)
  //
  // Menu mở thành bảng nổi ở góc phải, đè lên hình (không đẩy bố cục).
  // Nền thanh trên/dưới là dải gradient đen → trong suốt (xem _Scrim).
  // ============================================================

  /// Nút tròn mở/đóng menu chức năng (chỉ icon, có tooltip).
  Widget _buildMenuButton() {
    return BrandIconButton(
      icon: _controlsExpanded ? Icons.close_rounded : Icons.menu_rounded,
      tooltip: _controlsExpanded
          ? appText(context, 'Đóng menu', 'Close menu')
          : appText(context, 'Mở menu chức năng', 'Open menu'),
      active: _controlsExpanded,
      size: 48,
      onPressed: () =>
          setState(() => _controlsExpanded = !_controlsExpanded),
    );
  }

  /// Các viên trạng thái: cùng chiều cao, cùng hàng, không lòi ra ngoài.
  List<Widget> _buildStatusPills(bool compact) {
    final rtsp = _runtime.rtspPublisherService;
    final whip = _runtime.whipPublisherService;
    final profile = _runtime.resolutionProfile;
    return [
      if (_recording)
        BrandPill(
          text: 'REC',
          dot: true,
          filled: true,
          color: BrandColors.live,
          tooltip: appText(context, 'Đang ghi hình', 'Recording'),
        )
      else
        BrandPill(
          text: appText(context, 'Sẵn sàng', 'Ready'),
          dot: true,
          color: BrandColors.successSoft,
          tooltip: appText(context, 'Sẵn sàng ghi', 'Ready'),
        ),
      _StatusPill(
        icon: _runtime.profileSwitching
            ? null
            : (_runtime.resolutionLocked
                  ? Icons.lock_rounded
                  : Icons.high_quality_rounded),
        loading: _runtime.profileSwitching,
        label: '${profile.shortLabel}·${profile.fps}',
        color: _runtime.resolutionLocked
            ? BrandColors.warningSoft
            : BrandColors.textPrimary,
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
          pendingAt: _runtime.pendingThermalAt,
          profile: _runtime.resolutionProfile,
          loadLevel: _runtime.thermalLoadLevel,
          onTap: _handleResolutionPressed,
          onDismiss: _runtime.dismissCooledDownNotice,
        ),
      if (_runtime.isLiveStreaming)
        // Chỉ viên LIVE dựng lại mỗi giây (thời lượng/chất lượng mạng), không
        // dựng lại cả màn hình.
        ListenableBuilder(
          listenable: Listenable.merge([
            rtsp.durationListenable,
            rtsp.metricsListenable,
            whip.durationListenable,
          ]),
          builder: (context, _) {
            // Chất lượng LUỒNG PHÁT (FPS/bitrate đẩy lên máy chủ), không phải
            // sóng Wi-Fi: dùng icon cột sóng thay vì icon Wi-Fi.
            final quality = rtsp.isLive
                ? rtsp.networkQuality
                : StreamNetworkQuality.unknown;
            final IconData? qualityIcon = switch (quality) {
              StreamNetworkQuality.good => Icons.signal_cellular_alt_rounded,
              StreamNetworkQuality.warning =>
                Icons.signal_cellular_alt_2_bar_rounded,
              StreamNetworkQuality.poor =>
                Icons.signal_cellular_alt_1_bar_rounded,
              StreamNetworkQuality.unknown => null,
            };
            final String? qualityText = switch (quality) {
              StreamNetworkQuality.good => appText(context, 'Tốt', 'Good'),
              StreamNetworkQuality.warning => appText(
                context,
                'Trung bình',
                'Fair',
              ),
              StreamNetworkQuality.poor => appText(context, 'Kém', 'Poor'),
              StreamNetworkQuality.unknown => null,
            };
            final metrics = rtsp.isLive
                ? formatStreamMetrics(
                    rtsp.currentFps,
                    rtsp.currentBitrateKbps,
                  )
                : null;
            final tooltip = qualityText == null
                ? appText(context, 'Đang phát trực tiếp', 'Live streaming')
                : '${appText(context, 'Chất lượng phát', 'Stream quality')}: '
                      '$qualityText${metrics == null ? '' : ' · $metrics'}';
            return _StatusPill(
              dotColor: Colors.white,
              label:
                  'LIVE ${formatLiveDuration(rtsp.isLive ? rtsp.liveDuration : whip.liveDuration)}',
              color: Colors.white,
              background: BrandColors.live,
              trailingIcon: qualityIcon,
              trailingColor: switch (quality) {
                StreamNetworkQuality.good => BrandColors.successSoft,
                StreamNetworkQuality.warning => BrandColors.warning,
                StreamNetworkQuality.poor => BrandColors.dangerSoft,
                StreamNetworkQuality.unknown => Colors.white70,
              },
              tooltip: tooltip,
              onTap: _openLiveStreamScreen,
            );
          },
        ),
      if (_runtime.isLiveStreaming)
        // Bảng tỉ số in vào live nhưng overlay đang ẩn: người xem không thấy
        // tỉ số. Nhắc bằng viên cam, chạm để mở Hub bật lại.
        ValueListenableBuilder<ScoreOverlayFlags>(
          valueListenable: _scoreOverlay,
          builder: (context, flags, _) {
            switch (scoreOverlayHint(live: true, flags: flags)) {
              case ScoreOverlayHint.none:
                return const SizedBox.shrink();
              case ScoreOverlayHint.hidden:
                return _StatusPill(
                  icon: Icons.scoreboard_rounded,
                  label: appText(context, 'Tỉ số ẩn', 'Score hidden'),
                  color: BrandColors.warning,
                  tooltip: appText(
                    context,
                    'Bảng tỉ số đang ẩn trên live. Chạm để bật',
                    'Scoreboard hidden on live. Tap to show',
                  ),
                  onTap: _openScoreboardHub,
                );
              case ScoreOverlayHint.shown:
                return _StatusPill(
                  icon: Icons.scoreboard_rounded,
                  label: appText(context, 'Tỉ số', 'Score'),
                  color: BrandColors.successSoft,
                  tooltip: appText(
                    context,
                    'Bảng tỉ số đang hiện trên live',
                    'Scoreboard shown on live',
                  ),
                  onTap: _openScoreboardHub,
                );
            }
          },
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
        _buildIosCaptureNotice(compact),
      if (_runtime.storageWarning)
        _CameraNotice(
          compact: compact,
          kind: NoticeKind.warning,
          icon: Icons.sd_card_alert_rounded,
          message: appText(
            context,
            'Bộ nhớ sắp đầy. Video cũ sẽ được tự dọn.',
            'Storage low. Old videos will be auto-cleaned.',
          ),
        ),
    ];
  }

  /// iOS tạm dừng/khôi phục camera khi app ra/vào nền.
  Widget _buildIosCaptureNotice(bool compact) {
    final restoring =
        _runtime.lifecycleResuming || _runtime.captureState == 'recovering';
    return _CameraNotice(
      compact: compact,
      kind: restoring ? NoticeKind.info : NoticeKind.warning,
      icon: restoring ? null : Icons.pause_circle_rounded,
      loading: restoring,
      message: restoring
          ? appText(
              context,
              'Đang khôi phục camera và ghi hình…',
              'Restoring camera and recording…',
            )
          : appText(
              context,
              'iOS đã tạm dừng camera. Giữ app trên màn hình để ghi liên tục.',
              'iOS paused the camera. Keep the app open to keep recording.',
            ),
    );
  }

  /// Menu chức năng: bảng nổi ở góc phải, nằm trọn trong vùng dưới thanh
  /// trạng thái và trên thanh zoom. Màn hình thấp: dòng gọn, máy ngang đủ
  /// rộng thì xếp lưới 2 cột; vẫn thiếu chỗ thì cuộn, bắt đầu từ mục đầu.
  Widget _buildQuickMenu() {
    return LayoutBuilder(
      builder: (context, constraints) {
        const itemCount = 5;
        final layout = quickMenuLayout(
          maxWidth: constraints.maxWidth,
          maxHeight: constraints.maxHeight,
          itemCount: itemCount,
        );
        final dense = layout.dense;
        final tiles = <Widget>[
          _MenuTile(
            icon: Icons.video_library_rounded,
            label: appText(context, 'Video', 'Videos'),
            tooltip: appText(context, 'Kho video', 'Video storage'),
            dense: dense,
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
            activeColor: BrandColors.live,
            dense: dense,
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
            dense: dense,
            onTap: _openScoreboardHub,
          ),
          _MenuTile(
            icon: Icons.translate_rounded,
            label: appText(context, 'Ngôn ngữ', 'Language'),
            tooltip: appText(context, 'Ngôn ngữ', 'Language'),
            dense: dense,
            trailing: const AppLanguageButton(
              foregroundColor: BrandColors.textPrimary,
              size: 36,
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
            dense: dense,
            onTap: _openSettings,
          ),
        ];
        assert(tiles.length == itemCount);
        return Align(
          alignment: Alignment.topRight,
          child: SingleChildScrollView(
            // Không dùng PrimaryScrollController chung: menu luôn mở ở đầu
            // danh sách (offset 0), mục đầu không bị cắt.
            primary: false,
            padding: const EdgeInsets.symmetric(vertical: BrandSpace.xs),
            child: _QuickMenuPanel(
              columns: layout.columns,
              maxWidth: constraints.maxWidth,
              tiles: tiles,
            ),
          ),
        );
      },
    );
  }

  /// Rail nút camera (đổi camera, bật/tắt, làm tối, khoá xoay): cùng kích
  /// thước, cùng kiểu kính; chỉ trạng thái đang bật mới có màu xanh. Màn
  /// hình đủ chỗ thì có nhãn ngắn, máy nhỏ chỉ icon (chạm giữ xem tooltip).
  Widget _buildActionRail(bool compact) {
    final size = compact ? 48.0 : 52.0;
    final showLabels = !compact;
    String? label(String vi, String en) =>
        showLabels ? appText(context, vi, en) : null;
    final cameraOn = _runtime.cameraEnabled;
    final buttons = <Widget>[
      BrandIconButton(
        icon: Icons.cameraswitch_rounded,
        tooltip: appText(
          context,
          'Đổi camera trước/sau',
          'Switch front/rear camera',
        ),
        label: label('Đổi cam', 'Flip'),
        size: size,
        loading: _lensSwitching,
        onPressed: _cameraReady && !_lensSwitching ? _switchCameraLens : null,
      ),
      // Tắt camera là hành động nguy hiểm (ngừng ghi): viền đỏ, không khối
      // đỏ lớn.
      _DangerRing(
        enabled: cameraOn,
        size: size,
        child: BrandIconButton(
          icon: cameraOn ? Icons.videocam_off_rounded : Icons.videocam_rounded,
          tooltip: cameraOn
              ? appText(context, 'Tắt camera', 'Turn camera off')
              : appText(context, 'Bật camera', 'Turn camera on'),
          label: cameraOn
              ? label('Tắt cam', 'Cam off')
              : label('Bật cam', 'Cam on'),
          size: size,
          loading: _cameraSwitching,
          onPressed: _cameraSwitching ? null : _toggleCamera,
        ),
      ),
      BrandIconButton(
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
                'Làm tối màn hình (giảm nhiệt)',
                'Dim screen (reduce heat)',
              ),
        label: label('Làm tối', 'Dim'),
        size: size,
        active: _screenDimmed,
        loading: _screenDimSwitching,
        onPressed: _screenDimSwitching ? null : _toggleScreenDim,
      ),
      BrandIconButton(
        icon: _screenOrientation == 'landscape'
            ? Icons.screen_lock_landscape_rounded
            : _screenOrientation == 'portrait'
            ? Icons.screen_lock_portrait_rounded
            : Icons.screen_rotation_rounded,
        tooltip: _screenOrientation == 'landscape'
            ? appText(context, 'Đang khoá xoay ngang', 'Landscape locked')
            : _screenOrientation == 'portrait'
            ? appText(context, 'Đang khoá xoay dọc', 'Portrait locked')
            : appText(context, 'Tự xoay màn hình', 'Auto-rotate'),
        label: _screenOrientation == 'auto'
            ? label('Tự xoay', 'Rotate')
            : label('Khoá xoay', 'Locked'),
        size: size,
        active: _screenOrientation != 'auto',
        onPressed: _toggleScreenOrientation,
      ),
    ];
    // Màn hình rất thấp: rail tự cuộn, không tràn.
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < buttons.length; i++) ...[
            if (i > 0)
              SizedBox(height: showLabels ? BrandSpace.sm : BrandSpace.md),
            buttons[i],
          ],
        ],
      ),
    );
  }

  /// Thanh nhỏ ở đáy: zoom nhanh + nút zoom chi tiết + nút độ sáng.
  Widget _buildControlBar(bool compact) {
    return _CameraControlBar(
      compact: compact,
      cameraReady: _cameraReady,
      zoomSupported:
          _cameraReady &&
          (_runtime.webRtcService?.cameraZoomSupported ?? false),
      zoomValue: _zoomValue ?? _runtime.webRtcService?.cameraZoom ?? 1,
      minimumZoom: _runtime.webRtcService?.minimumCameraZoom ?? 1.0,
      maximumZoom: math.min(
        _runtime.webRtcService?.maximumCameraZoom ?? 5.0,
        5.0,
      ),
      hasUltraWide: _runtime.webRtcService?.hasUltraWideCamera ?? false,
      ultraWideRatio: _runtime.webRtcService?.ultraWideZoomRatio ?? 0.5,
      ultraWideLabel: _runtime.webRtcService?.ultraWideLabel ?? '0.5×',
      // Đang đổi camera trước/sau: khoá zoom (ống kính sắp thay đổi).
      zoomEnabled: !_facingSwitching,
      onZoomChanged: _changeZoom,
      onQuickSelectZoom: _quickSelectZoom,
      exposureEv: _pendingEv ?? _runtime.exposureBiasEv,
      onExposureChanged: _changeExposure,
    );
  }

  /// Danh sách thông báo (tự cuộn khi nhiều).
  Widget _buildNoticeList(List<Widget> notices) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: notices,
      ),
    );
  }

  /// Màn dọc: thanh trạng thái trên (2 hàng khi máy hẹp), thông báo, rail
  /// nút ở mép phải, thanh zoom/độ sáng ở đáy.
  Widget _buildPortraitControls(bool compact, bool singleRowHeader) {
    final notices = _buildNotices(compact);
    final pills = _buildStatusPills(compact);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (singleRowHeader)
          Row(
            children: [
              _StationLogo(compact: compact),
              const SizedBox(width: BrandSpace.md),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _PillStrip(pills: pills),
                ),
              ),
              const SizedBox(width: BrandSpace.sm),
              _buildMenuButton(),
            ],
          )
        else ...[
          Row(
            children: [
              _StationLogo(compact: compact),
              const Spacer(),
              _buildMenuButton(),
            ],
          ),
          const SizedBox(height: BrandSpace.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: _PillStrip(pills: pills),
          ),
        ],
        const SizedBox(height: BrandSpace.sm),
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (notices.isNotEmpty)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: compact ? 120 : 180,
                      ),
                      child: _buildNoticeList(notices),
                    ),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: _buildActionRail(compact),
                    ),
                  ),
                ],
              ),
              if (_controlsExpanded) _buildQuickMenu(),
            ],
          ),
        ),
        const SizedBox(height: BrandSpace.sm),
        Center(child: _buildControlBar(compact)),
      ],
    );
  }

  /// Màn ngang: cột trái (logo + trạng thái, thông báo, thanh zoom ở đáy);
  /// cột phải (nút Menu, rail nút camera ở giữa).
  Widget _buildLandscapeControls(bool compact) {
    final notices = _buildNotices(compact);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 48,
                child: Row(
                  children: [
                    _StationLogo(compact: compact),
                    const SizedBox(width: BrandSpace.md),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: _PillStrip(pills: _buildStatusPills(compact)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: BrandSpace.sm),
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Align(
                      alignment: Alignment.topLeft,
                      child: notices.isEmpty
                          ? const SizedBox.shrink()
                          : ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: compact ? 360 : 420,
                              ),
                              child: _buildNoticeList(notices),
                            ),
                    ),
                    if (_controlsExpanded) _buildQuickMenu(),
                  ],
                ),
              ),
              const SizedBox(height: BrandSpace.sm),
              Center(child: _buildControlBar(compact)),
            ],
          ),
        ),
        const SizedBox(width: BrandSpace.md),
        // Cột cố định bề rộng: nhãn dưới nút tự cắt (ellipsis), không đẩy
        // cột trái.
        SizedBox(
          width: compact ? 52 : 76,
          child: Column(
            children: [
              _buildMenuButton(),
              const SizedBox(height: BrandSpace.md),
              Expanded(child: Center(child: _buildActionRail(compact))),
            ],
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
          // Thanh trạng thái dọc máy hẹp có 2 hàng; máy rộng gộp 1 hàng.
          final singleRowHeader = landscape || constraints.maxWidth >= 560;
          final viewPadding = MediaQuery.paddingOf(context);
          // Dải tối trên/dưới vừa đủ cao để chữ/nút dễ đọc, giữa màn hình
          // để trống cho hình camera.
          final topScrim =
              viewPadding.top + (singleRowHeader ? 88.0 : 128.0);
          final bottomScrim = viewPadding.bottom + (landscape ? 88.0 : 112.0);
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
              if (!isPip && !_previewResting) ...[
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: topScrim,
                  child: const _Scrim(fromTop: true),
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  height: bottomScrim,
                  child: const _Scrim(fromTop: false),
                ),
                Positioned.fill(
                  child: SafeArea(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        compact ? BrandSpace.sm : BrandSpace.lg,
                        compact ? BrandSpace.sm : BrandSpace.md,
                        compact ? BrandSpace.sm : BrandSpace.lg,
                        compact ? BrandSpace.sm : BrandSpace.md,
                      ),
                      child: landscape
                          ? _buildLandscapeControls(compact)
                          : _buildPortraitControls(compact, singleRowHeader),
                    ),
                  ),
                ),
              ],

              // ==============================================
              // PIP MODE MINIMAL STATUS OVERLAY
              // ==============================================
              if (isPip)
                Positioned(
                  top: 6,
                  left: 8,
                  right: 8,
                  child: _PipStatusOverlay(
                    recording: _recording,
                    live: _runtime.isLiveStreaming,
                    thermalWarning: _runtime.thermalWarning,
                    profileText: profileLabel(_runtime.resolutionProfile),
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

