import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/camera_resolution_profile.dart';
import 'camera_server.dart';
import 'recording_service.dart';
import 'station_config_service.dart';
import 'webrtc_service.dart';
import 'whip_publisher_service.dart';
import 'rtsp_publisher_service.dart';
import 'scoreboard_burn_in.dart';
import 'scoreboard_service.dart';
import 'station_display_service.dart';
import 'station_errors.dart';

bool shouldRecreateIosCameraForLensSwitch(
  CameraResolutionProfile previous,
  CameraResolutionProfile selected,
) => selected != previous;

/// Cấu hình mở camera lúc khởi động: ưu tiên đúng preset + FPS đã lưu (ví dụ
/// 1080p60), rồi tới cùng preset, rồi 1080p, cuối cùng là cấu hình đầu tiên.
CameraResolutionProfile selectStartupResolutionProfile(
  List<CameraResolutionProfile> supported,
  CameraResolutionProfile? saved,
) {
  if (saved != null) {
    for (final profile in supported) {
      if (profile.preset == saved.preset && profile.fps == saved.fps) {
        return profile;
      }
    }
    for (final profile in supported) {
      if (profile.preset == saved.preset) return profile;
    }
  }
  for (final profile in supported) {
    if (profile.preset == CameraResolutionPreset.fullHd1080) return profile;
  }
  return supported.first;
}

Duration iosCaptureWarmupDuration(CameraResolutionProfile profile) {
  return switch (profile.preset) {
    CameraResolutionPreset.ultraHd4k => const Duration(milliseconds: 1500),
    CameraResolutionPreset.qhd2k => const Duration(milliseconds: 500),
    _ => Duration.zero,
  };
}

/// Chuẩn hóa mức nhiệt của hai nền tảng về cùng một ngưỡng.
///
/// - Android `PowerManager.currentThermalStatus`: 0 NONE, 1 LIGHT, 2 MODERATE,
///   3 SEVERE, 4 CRITICAL, 5 EMERGENCY, 6 SHUTDOWN.
/// - iOS (`AppDelegate.thermalStatus`): 0 nominal, 1 fair, 4 serious,
///   5 critical.
///
/// iOS `serious` tương đương Android `SEVERE`, iOS `critical` tương đương
/// Android `CRITICAL`. Trước đây cả hai dùng chung ngưỡng 4/5 nên Android phản
/// ứng chậm hơn iOS một bậc.
///
/// `emergency` chỉ có trên Android (EMERGENCY/SHUTDOWN); iOS không có mức cao
/// hơn `critical`.
({bool hot, bool critical, bool emergency, bool cool})
classifyPlatformThermalStatus(
  int status, {
  required bool isIos,
}) {
  if (isIos) {
    return (
      hot: status >= 4,
      critical: status >= 5,
      emergency: false,
      cool: status <= 1,
    );
  }
  return (
    hot: status >= 3,
    critical: status >= 4,
    emergency: status >= 5,
    cool: status <= 1,
  );
}

enum ThermalAction { none, degrade, suspend }

/// Số lần đọc liên tiếp (mỗi 10 giây) cần để xác nhận một mức nhiệt, tránh
/// một lần đọc nhiễu của cảm biến pin dừng cả quay lẫn livestream.
const int thermalConfirmationReadings = 3;

/// iOS không có mức trên `critical`: nếu vẫn critical sau khi đã giảm tải
/// chừng này thời gian thì mới dừng hẳn.
const Duration iosCriticalSuspendAfterDegrade = Duration(minutes: 3);

/// Chính sách leo thang nhiệt khi máy quá nóng:
/// - critical xác nhận → giảm tải (720p30, giảm bitrate, tối màn hình) nhưng
///   vẫn quay và livestream;
/// - emergency xác nhận (Android) hoặc iOS vẫn critical quá lâu sau khi giảm
///   tải → dừng hẳn để bảo vệ máy.
ThermalAction thermalEscalation({
  required int criticalStreak,
  required int emergencyStreak,
  required Duration criticalDegradedFor,
  required bool isIos,
}) {
  if (!isIos && emergencyStreak >= thermalConfirmationReadings) {
    return ThermalAction.suspend;
  }
  if (criticalStreak < thermalConfirmationReadings) return ThermalAction.none;
  if (isIos && criticalDegradedFor >= iosCriticalSuspendAfterDegrade) {
    return ThermalAction.suspend;
  }
  return ThermalAction.degrade;
}

typedef ThermalLoadPlan = ({
  int level,
  int? fpsCap,
  double bitrateFactor,
  bool dimScreen,
});

const ThermalLoadPlan thermalLoadPlanNormal = (
  level: 0,
  fpsCap: null,
  bitrateFactor: 1.0,
  dimScreen: false,
);

/// Nhiệt độ pin (°C) bắt đầu giảm tải bậc 2 (trước ngưỡng nóng 45°C).
const double thermalEarlyLoadC = 43.0;

/// Giảm tải theo bậc mà KHÔNG mở lại camera (livestream không bị ngắt):
/// - 1 ấm (dự báo sắp nóng): làm tối màn hình;
/// - 2 nóng hoặc dự báo chạm SEVERE: FPS tối đa 30, bitrate 80%;
/// - 3 critical đã xác nhận: FPS tối đa 24, bitrate 60%.
/// [headroom] là PowerManager.getThermalHeadroom (1.0 = SEVERE), null nếu
/// máy không hỗ trợ. [temperatureC] (pin): từ [thermalEarlyLoadC] đã giảm tải
/// bậc 2, trước ngưỡng "nóng" 45°C, để máy ít khi phải hạ độ phân giải.
ThermalLoadPlan thermalLoadPlan({
  required bool hot,
  required bool criticalConfirmed,
  required double? headroom,
  required int profileFps,
  double? temperatureC,
}) {
  int? capTo(int fps) => profileFps > fps ? fps : null;
  if (criticalConfirmed) {
    return (level: 3, fpsCap: capTo(24), bitrateFactor: 0.6, dimScreen: true);
  }
  final warmBattery =
      temperatureC != null && temperatureC >= thermalEarlyLoadC;
  if (hot || warmBattery || (headroom != null && headroom >= 0.95)) {
    return (level: 2, fpsCap: capTo(30), bitrateFactor: 0.8, dimScreen: true);
  }
  if (headroom != null && headroom >= 0.85) {
    return (level: 1, fpsCap: null, bitrateFactor: 1.0, dimScreen: true);
  }
  return thermalLoadPlanNormal;
}

/// Mức ưu tiên của một giao diện mạng khi chọn địa chỉ LAN cho Tablet:
/// 0 = Wi-Fi/Ethernet, 1 = hotspot do điện thoại phát, null = không dùng
/// (mạng di động 4G/5G, VPN, CLAT…). IP 4G thường là 10.x nên nếu không lọc
/// theo tên sẽ bị nhận nhầm là LAN.
int? lanInterfacePriority(String interfaceName) {
  final name = interfaceName.toLowerCase();
  const primary = ['wlan', 'eth', 'en', 'wigig'];
  const hotspot = ['ap', 'swlan', 'softap', 'br', 'bridge'];
  if (primary.any(name.startsWith)) return 0;
  if (hotspot.any(name.startsWith)) return 1;
  return null;
}

/// Chọn địa chỉ LAN riêng tư từ danh sách (tên giao diện, địa chỉ), ưu tiên
/// Wi-Fi/Ethernet rồi tới hotspot; bỏ qua mạng di động.
String? selectStationLanAddress(
  Iterable<({String interface, String address})> candidates,
) {
  final ranked = candidates
      .map((c) => (priority: lanInterfacePriority(c.interface), c: c))
      .where((entry) => entry.priority != null)
      .toList()
    ..sort((a, b) => a.priority!.compareTo(b.priority!));
  return selectPrivateLanIpv4(ranked.map((entry) => entry.c.address));
}

/// Mạng đang mang livestream có vừa mất không, từ các mục "giao diện|IP" đã
/// mất ([lost]) và còn lại ([current]). Còn Wi-Fi/Ethernet thì luồng đi qua đó,
/// nên IP 4G/5G chạy nền (Android giữ sẵn) hay hotspot thay đổi không ảnh hưởng.
bool activeRouteLost(Set<String> lost, Set<String> current) {
  int? priority(String entry) => lanInterfacePriority(entry.split('|').first);
  final relevant = lost.where((entry) => priority(entry) != 1);
  if (relevant.any((entry) => priority(entry) == 0)) return true;
  if (relevant.isEmpty) return false;
  return !current.any((entry) => priority(entry) == 0);
}

/// Bộ đếm định kỳ 60 giây chỉ quét lại toàn bộ thư mục video khi dung lượng
/// đang thấp hoặc đã lâu chưa quét. Khi đang ghi, mỗi segment hoàn tất đã tự
/// quét một lần (3 phút/lần), nên quét thêm mỗi phút là lãng phí I/O.
bool shouldRunPeriodicStorageEnforcement({
  required bool lowStorage,
  required DateTime? lastRun,
  required DateTime now,
  Duration interval = const Duration(minutes: 10),
}) {
  if (lowStorage || lastRun == null) return true;
  return now.difference(lastRun) >= interval;
}

/// Tìm cấu hình thiết bị hỗ trợ khớp [profile]: đúng preset + FPS, nếu không
/// có thì cùng preset với FPS giới hạn theo khả năng. null = không hỗ trợ.
CameraResolutionProfile? resolveSupportedResolutionProfile(
  List<CameraResolutionProfile> supported,
  CameraResolutionProfile profile,
) {
  for (final candidate in supported) {
    if (candidate.preset == profile.preset && candidate.fps == profile.fps) {
      return candidate;
    }
  }
  for (final candidate in supported) {
    if (candidate.preset == profile.preset) {
      return candidate.withFps(profile.fps.clamp(1, candidate.fps));
    }
  }
  return null;
}

/// Tải xử lý tương đối của một cấu hình (điểm ảnh × FPS) để so sánh nặng/nhẹ.
int resolutionProfileLoad(CameraResolutionProfile profile) =>
    profile.width * profile.height * profile.fps;

/// Lý do không được mở/mở lại camera lúc này (null = được phép).
/// - Dừng khẩn cấp vì nhiệt: chỉ thermal monitor mới được mở lại camera.
/// - iOS đang ở nền: AVCaptureSession đã được giải phóng.
/// - Máy quét QR đang giữ camera ([scannerActive]).
@visibleForTesting
StationErrorCode? cameraOpenBlockReason({
  required bool thermalSuspended,
  required bool iosSuspended,
  required bool scannerActive,
}) {
  if (thermalSuspended) return StationErrorCode.thermalSuspended;
  if (iosSuspended) return StationErrorCode.iosSuspended;
  if (scannerActive) return StationErrorCode.scannerActive;
  return null;
}

/// Thời gian chờ trước lần nối lại dịch vụ mạng kế tiếp sau [failures] lần
/// thất bại liên tiếp: 5 s, 15 s, rồi 60 s.
@visibleForTesting
Duration networkReconnectRetryDelay(int failures) {
  if (failures <= 1) return const Duration(seconds: 5);
  if (failures == 2) return const Duration(seconds: 15);
  return const Duration(seconds: 60);
}

/// Có nối lại dịch vụ mạng (đóng mọi peer WebRTC, bind lại discovery) không.
/// Chỉ khi IP LAN thật sự đổi, hoặc lần nối lại trước THẤT BẠI và đã hết thời
/// gian chờ. Lỗi đọc trạng thái mạng thoáng qua không phải lý do nối lại.
@visibleForTesting
bool shouldReconnectNetworkServices({
  required bool firstObservation,
  required String? previousAddress,
  required String? address,
  required bool lastReconnectFailed,
  required DateTime? retryNotBefore,
  required DateTime now,
}) {
  if (firstObservation || address == null) return false;
  if (address != previousAddress) return true;
  if (!lastReconnectFailed) return false;
  return retryNotBefore == null || !now.isBefore(retryNotBefore);
}

/// Thời gian chờ trước lần tự khởi tạo lại thứ [attempt] (0 = lần đầu):
/// 5 s, 15 s, 30 s, rồi giữ 60 s.
@visibleForTesting
Duration initRetryDelay(int attempt) {
  const delays = [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];
  if (attempt < 0) return delays.first;
  if (attempt < delays.length) return delays[attempt];
  return const Duration(seconds: 60);
}

/// Lỗi khởi tạo có nên tự thử lại không. Thiếu quyền camera/micro thì không:
/// người dùng phải cấp quyền trong cài đặt.
@visibleForTesting
bool isRetryableInitError(Object error) => !isPermissionDeniedError(error);

/// Việc cần làm khi một yêu cầu khởi tạo tới lượt trong hàng đợi vòng đời.
@visibleForTesting
enum InitializeEntryAction { skip, initialize, stopThenInitialize }

/// Quyết định cho một yêu cầu khởi tạo. Chỉ bỏ qua khi runtime đã khởi tạo
/// xong toàn bộ ([initCompleted]: server, camera và các monitor) cho đúng
/// camera/sân/thiết bị đó. Server đang chạy nhưng khởi tạo chưa xong (lần
/// trước quá hạn giữa chừng) thì dọn runtime dở dang rồi khởi tạo lại.
@visibleForTesting
InitializeEntryAction initializeEntryAction({
  required bool restart,
  required bool serverRunning,
  required bool initCompleted,
  required bool sameIdentity,
}) {
  if (restart) return InitializeEntryAction.stopThenInitialize;
  if (serverRunning && initCompleted && sameIdentity) {
    return InitializeEntryAction.skip;
  }
  if (serverRunning && !initCompleted) {
    return InitializeEntryAction.stopThenInitialize;
  }
  return InitializeEntryAction.initialize;
}

/// Số lần đọc không-critical liên tiếp cần để thoát trạng thái critical đã
/// giảm tải (chống dao động khi cảm biến đọc nhiễu một lần).
@visibleForTesting
bool shouldExitCriticalDegrade({
  required bool degraded,
  required int nonCriticalStreak,
}) => degraded && nonCriticalStreak >= thermalConfirmationReadings;

/// Recovery có được (tiếp tục) thử mở lại camera không. Kiểm tra trước MỖI
/// lần thử và trước khi mở camera: dừng khẩn cấp vì nhiệt (đã dừng hoặc yêu
/// cầu dừng đang chờ trong hàng đợi), nền iOS, máy quét QR, runtime đang dừng,
/// camera bị tắt hoặc lượt recovery đã bị thay thế ([superseded]) thì không.
@visibleForTesting
bool cameraRecoveryMayProceed({
  required bool stopping,
  required bool cameraEnabled,
  required bool superseded,
  required bool thermalSuspended,
  required bool thermalSuspendPending,
  required bool iosSuspended,
  required bool scannerActive,
}) {
  if (stopping || !cameraEnabled || superseded || thermalSuspendPending) {
    return false;
  }
  return cameraOpenBlockReason(
        thermalSuspended: thermalSuspended,
        iosSuspended: iosSuspended,
        scannerActive: scannerActive,
      ) ==
      null;
}

/// Đủ mát để bắt đầu/tiếp tục đếm thời gian ổn định trước khi khôi phục chất
/// lượng đã hạ vì nhiệt chưa. Hệ điều hành báo mát ([cool]: Android ≤ LIGHT,
/// iOS ≤ fair) hoặc Android báo MODERATE kéo dài nhưng nhiệt độ pin đo được
/// ≤ [maxTemperatureC] đều được; mức nóng ([hot]: SEVERE trở lên) thì không.
/// Nhiệt độ đo được trên [maxTemperatureC] luôn chặn (chống dao động).
@visibleForTesting
bool thermalRestoreCoolEnough({
  required bool hot,
  required bool cool,
  required double? temperatureC,
  required double maxTemperatureC,
}) {
  if (hot) return false;
  if (temperatureC != null && temperatureC > maxTemperatureC) return false;
  // MODERATE (không "cool") chỉ được tính khi có nhiệt độ pin để xác nhận.
  return cool || temperatureC != null;
}

/// Hành động với độ sáng màn hình do nhiệt (xem [thermalScreenDimDecision]).
enum ThermalDimAction { none, dim, undim }

/// Quyết định DUY NHẤT về việc runtime làm tối / bật sáng màn hình vì nhiệt.
///
/// - [dimmedByThermal]: màn hình đang tối do chính runtime làm tối.
/// - [autoDimAllowed]: được phép tự làm tối (màn Station đang hiển thị, chưa
///   tối, người dùng không vừa bật sáng trong khoảng giữ 10 phút).
/// - [planWantsDim]: kế hoạch giảm tải hiện hành yêu cầu làm tối.
/// - [riseWantsDim]: nhiệt độ tăng nhanh (Android) / iOS báo serious.
/// - [cooled]: đã đủ mát để bật sáng lại (pin ≤ 39,5°C / iOS nominal-fair).
///
/// Chỉ bật sáng lại khi đã mát VÀ kế hoạch tải không còn yêu cầu làm tối;
/// nếu không, kế hoạch tải sẽ làm tối lại ngay lần kiểm tra sau (màn hình
/// chớp sáng/tối mỗi 10 giây).
ThermalDimAction thermalScreenDimDecision({
  required bool dimmedByThermal,
  required bool autoDimAllowed,
  required bool planWantsDim,
  required bool riseWantsDim,
  required bool cooled,
}) {
  if (dimmedByThermal) {
    return cooled && !planWantsDim
        ? ThermalDimAction.undim
        : ThermalDimAction.none;
  }
  if (autoDimAllowed && (planWantsDim || riseWantsDim)) {
    return ThermalDimAction.dim;
  }
  return ThermalDimAction.none;
}

/// Lúc khởi động có hạ cấu hình xuống 720p30 vì nhiệt không. Cùng chính sách
/// với lúc chạy: mức "nóng" không đổi độ phân giải (chỉ giảm tải tại chỗ),
/// chỉ critical/khẩn cấp mới hạ (bỏ qua khoá độ phân giải vì là mức an toàn).
bool startupThermalDegradeRequired({
  required bool critical,
  required bool emergency,
}) => critical || emergency;

/// Giới hạn FPS vì nhiệt đang THẬT SỰ áp lên track [trackId] (null = không
/// giới hạn). [appliedKey] là khoá `trackId|cap` của lần áp thành công gần
/// nhất. Chỉ Android áp được giới hạn FPS tại chỗ; iOS giữ FPS cấu hình.
int? reportedThermalFpsCap({
  required bool isAndroid,
  required String? trackId,
  required String? appliedKey,
}) {
  if (!isAndroid || trackId == null || appliedKey == null) return null;
  final prefix = '$trackId|';
  if (!appliedKey.startsWith(prefix)) return null;
  final cap = int.tryParse(appliedKey.substring(prefix.length));
  return cap == null || cap <= 0 ? null : cap;
}

/// Thao tác đổi cấu hình (độ phân giải / ống kính) có huỷ recovery đang chạy
/// không: chỉ khi nó thật sự sẽ mở lại camera. Thao tác bị từ chối (camera
/// tắt, bị chặn) hoặc không đổi gì không được huỷ recovery (camera đang đóng
/// sẽ bị bỏ đóng).
bool reconfigurationShouldInterruptRecovery({
  required bool cameraEnabled,
  required bool openBlocked,
  required bool changesConfiguration,
}) => cameraEnabled && !openBlocked && changesConfiguration;

/// Đổi zoom có được chạy ngay không. Zoom không đi qua hàng đợi vòng đời (để
/// không bị trễ), nên phải bỏ qua khi camera đang được mở/đóng/đổi cấu hình
/// ([lifecycleBusy]: hàng đợi vòng đời đang có thao tác chạy hoặc chờ).
bool cameraZoomAllowed({
  required bool cameraEnabled,
  required bool initialized,
  required bool stopping,
  required bool profileSwitching,
  required bool lensSwitching,
  required bool recovering,
  required bool openBlocked,
  required bool lifecycleBusy,
}) =>
    cameraEnabled &&
    initialized &&
    !stopping &&
    !profileSwitching &&
    !lensSwitching &&
    !recovering &&
    !openBlocked &&
    !lifecycleBusy;

/// Đếm số lần giữ một tác vụ dùng chung (ví dụ background task iOS: native
/// chỉ có một task). [onFirstAcquire] chạy đồng bộ khi chuyển 0 → 1 lần giữ,
/// [onLastRelease] khi lần giữ cuối được trả. Mỗi hàm trả về từ [acquire] chỉ
/// có tác dụng ở lần gọi đầu tiên.
class SharedTaskHold {
  SharedTaskHold({required this.onFirstAcquire, required this.onLastRelease});

  final void Function() onFirstAcquire;
  final Future<void> Function() onLastRelease;
  int _holds = 0;

  int get holds => _holds;

  Future<void> Function() acquire() {
    _holds++;
    if (_holds == 1) onFirstAcquire();
    var released = false;
    return () {
      if (released) return Future<void>.value();
      released = true;
      _holds--;
      if (_holds > 0) return Future<void>.value();
      _holds = 0;
      return onLastRelease();
    };
  }
}

/// Thao tác vòng đời đã quá hạn (hàng đợi đã giao cho thao tác khác) hoặc đã
/// bị thay thế: dừng giữa chừng, không mở camera / đổi trạng thái nữa.
class _StaleLifecycleOperation implements Exception {
  const _StaleLifecycleOperation(this.label);

  final String label;

  @override
  String toString() => 'Stale lifecycle operation: $label';
}

String? selectPrivateLanIpv4(Iterable<String> addresses) {
  for (final address in addresses) {
    final parts = address.split('.');
    if (parts.length != 4) continue;
    final octets = parts.map(int.tryParse).toList(growable: false);
    if (octets.any((value) => value == null)) continue;
    final first = octets[0]!;
    final second = octets[1]!;
    if (first == 10 ||
        (first == 192 && second == 168) ||
        (first == 172 && second >= 16 && second <= 31)) {
      return address;
    }
  }
  return null;
}

typedef _ThermalSnapshot = ({
  double? temperatureC,
  bool hot,
  bool critical,
  bool emergency,
  bool cool,
  double? headroom,
  bool charging,
});

/// Không đọc được nhiệt độ: coi như không biết, máy không nóng.
const _ThermalSnapshot _unknownThermalSnapshot = (
  temperatureC: null,
  hot: false,
  critical: false,
  emergency: false,
  cool: true,
  headroom: null,
  charging: false,
);

/// Lens/zoom của camera sau để mở lại đúng góc quay.
typedef _LensState = ({bool isUltraWide, double zoom, String? deviceId});

class CameraStationRuntime {
  CameraStationRuntime._();

  static final CameraStationRuntime instance = CameraStationRuntime._();

  final StreamController<void> _stateController =
      StreamController<void>.broadcast();

  WebRtcService? _webRtcService;
  RecordingService? _recordingService;
  CameraServer? _cameraServer;
  Future<void> _lifecycleTail = Future<void>.value();
  // Số thao tác vòng đời đang chạy hoặc đang chờ trong hàng đợi.
  int _lifecycleOperationsPending = 0;
  Completer<void> _recoveryCancellation = Completer<void>();
  String? _cameraId;
  String? _courtId;
  String? _deviceId;
  Timer? _healthTimer;
  Timer? _storageCleanupTimer;
  Timer? _thermalTimer;
  Timer? _networkTimer;
  Timer? _pendingThermalThrottleTimer;
  CameraResolutionProfile? _pendingThermalTarget;
  DateTime? _pendingThermalAt;
  Timer? _pendingThermalRestoreTimer;
  bool _thermalThrottled = false;
  // Đang khôi phục cấu hình sau khi hạ nhiệt (đã xếp/đang đổi độ phân giải):
  // _thermalThrottled và profile mục tiêu được giữ tới khi khôi phục THÀNH
  // CÔNG, lần kiểm tra nhiệt chen vào không được xoá chúng.
  bool _thermalRestoreInFlight = false;
  // iOS: background task hoàn tất segment (native chỉ có một task, nên đếm ở
  // Dart để begin/end đúng một lần).
  late final SharedTaskHold _iosFinalizationHold = SharedTaskHold(
    onFirstAcquire: () => unawaited(_beginIosBackgroundFinalization()),
    onLastRelease: _endIosBackgroundFinalization,
  );
  bool _thermalUserOverride = false;
  DateTime? _thermalCooledDownSince;
  bool _thermalCriticalSuspended = false;
  // Máy đang ở mức critical đã xác nhận: chạy 720p30 + bitrate thấp nhưng vẫn
  // quay và livestream.
  bool _thermalCriticalDegraded = false;
  DateTime? _thermalCriticalDegradedSince;
  int _thermalCriticalStreak = 0;
  int _thermalEmergencyStreak = 0;
  bool _criticalProfileSwitchFailed = false;
  ThermalLoadPlan _thermalLoadPlan = thermalLoadPlanNormal;
  DateTime? _thermalLoadRelaxSince;
  String? _appliedFpsCapKey;
  bool _charging = false;
  bool _thermalCheckRunning = false;
  DateTime? _thermalNormalSince;
  double? _temperatureC;
  bool _autoScreenDimmed = false;
  // true khi chính runtime làm tối màn hình vì nhiệt độ (không phải người dùng),
  // để chỉ tự bật sáng lại những lần do runtime gây ra.
  bool _screenDimmedByThermal = false;

  /// Người dùng vừa tự bật sáng lại màn hình: nhiệt độ không được tự làm tối
  /// lại cho tới mốc này (trước đây lần đo nhiệt kế tiếp ~10 s sau đã làm tối
  /// lại ngay, như thể nút không có tác dụng).
  DateTime? _userScreenBrightUntil;
  static const Duration _userScreenBrightHold = Duration(minutes: 10);

  bool get _thermalAutoDimAllowed {
    if (!_stationDisplayAttached || _autoScreenDimmed) return false;
    final until = _userScreenBrightUntil;
    return until == null || DateTime.now().isAfter(until);
  }
  // Chỉ tự làm tối khi màn hình Station đang hiển thị.
  bool _stationDisplayAttached = false;
  double? _thermalRiseRatePerMin;
  final List<({DateTime timestamp, double temperatureC})> _temperatureHistory = [];
  CameraResolutionProfile? _profileBeforeThermalThrottle;
  bool _recovering = false;
  bool _stopping = false;
  bool _cameraEnabled = true;
  bool _profileSwitching = false;
  // Camera đang được nhường cho máy quét QR (CameraX/MobileScanner). Health
  // monitor, thermal và recovery không được mở lại camera trong lúc này.
  bool _scannerPaused = false;
  Future<void>? _lensSwitchOperation;
  bool _iosLifecycleSuspended = false;
  bool _iosResumeQueued = false;
  bool _iosAppInForeground = true;
  int _iosLifecycleGeneration = 0;
  bool _healthCheckRunning = false;
  bool _networkCheckRunning = false;
  bool _networkObservationInitialized = false;
  int _missingNetworkObservations = 0;
  bool _networkRecovering = false;
  String? _lanAddress;
  String? _networkError;
  // Tập "giao diện|địa chỉ IPv4" của mọi mạng (Wi-Fi, 4G/5G, hotspot) để phát
  // hiện chuyển mạng. Không dùng IPv6 vì iOS đổi địa chỉ tạm IPv6 thường xuyên.
  Set<String>? _networkSignature;
  int _cameraQuarterTurns = 0;
  double? _iosActualFps;
  int? _iosRequestedFps;
  DateTime? _iosPerformanceMeasuredAt;
  String? _lastRecordingPath;
  int? _lastRecordingBytes;
  DateTime? _lastRecordingProgressAt;
  String? _lastAudioPath;
  int? _lastAudioBytes;
  DateTime? _lastAudioProgressAt;
  DateTime? _healthGraceUntil;
  final Map<String, int> _healthFailureCounts = <String, int>{};
  CameraResolutionProfile _resolutionProfile =
      CameraResolutionProfile.fullHd1080;
  bool _resolutionLocked = false;
  List<CameraResolutionProfile> _supportedResolutionProfiles = const [
    CameraResolutionProfile.hd720,
  ];
  int _generation = 0;
  // Phiên giám sát: tăng mỗi lần dừng runtime. Kết quả của một lần kiểm tra
  // network/thermal/health/dọn bộ nhớ thuộc phiên cũ (còn đang chờ I/O khi
  // runtime dừng/khởi tạo lại) bị bỏ qua và không được reset cờ của phiên mới.
  int _monitorSession = 0;
  bool _storageCleanupRunning = false;
  // Lỗi đọc trạng thái mạng (thoáng qua) tách khỏi lỗi khôi phục dịch vụ mạng
  // ([_networkError]): chỉ lỗi khôi phục mới khiến runtime nối lại lần nữa.
  String? _networkReadError;
  int _networkReconnectFailures = 0;
  DateTime? _networkReconnectRetryAt;
  // Tự khởi tạo lại khi khởi tạo lỗi (trừ lỗi thiếu quyền).
  Timer? _initRetryTimer;
  DateTime? _nextInitRetryAt;
  Object? _lastInitError;
  int _initRetryAttempt = 0;
  // Tăng mỗi lần huỷ lịch tự khởi tạo lại (stop/khởi tạo thủ công): lần khởi
  // tạo đang chạy dở mà lỗi sau đó không được tự lên lịch thử lại nữa.
  int _initRetryEpoch = 0;
  // Phiên khởi tạo: tăng mỗi lần _runInitialize/stop. Lần khởi tạo cũ (bị
  // thay thế hoặc quá hạn vẫn chạy nền) không được dọn runtime, ghi
  // lastInitError hay lên lịch thử lại thay cho phiên hiện tại.
  int _initSession = 0;
  // Chỉ true khi lần khởi tạo hoàn tất toàn bộ (server, camera và các
  // monitor health/thermal/network đã bật). Lần khởi tạo quá hạn sau khi
  // server đã chạy để lại server.running == true nhưng cờ này vẫn false, nên
  // initialize() không coi runtime dở dang đó là đã sẵn sàng.
  bool _initCompleted = false;
  // Tăng mỗi khi một thao tác vòng đời quá hạn và hàng đợi được giải phóng:
  // thao tác treo (vẫn chạy nền) so sánh với giá trị lúc nó bắt đầu để dừng
  // sớm thay vì mở camera song song với thao tác kế tiếp.
  int _lifecycleEpoch = 0;
  // Thermal monitor chỉ đặt yêu cầu vào hàng đợi vòng đời rồi trả về; các cờ
  // này chống xếp trùng yêu cầu khi lần kiểm tra 10 giây sau tới.
  bool _thermalSuspendQueued = false;
  bool _thermalResumeQueued = false;
  bool _thermalDegradeQueued = false;
  int _thermalNonCriticalStreak = 0;
  // Lens/zoom lúc dừng khẩn cấp vì nhiệt, để mở lại đúng góc quay khi nguội.
  _LensState? _thermalSavedLens;

  /// Thời gian tối đa mặc định của một thao tác trong hàng đợi vòng đời.
  static const Duration _lifecycleOperationTimeout = Duration(seconds: 45);
  static const Duration _initializeOperationTimeout = Duration(minutes: 2);
  static const Duration _stopOperationTimeout = Duration(seconds: 90);
  static const Duration _reconfigureOperationTimeout = Duration(seconds: 90);
  static const Duration _iosSuspendOperationTimeout = Duration(seconds: 60);
  // Recovery chờ giữa các lần thử (tổng ~82 giây) ngay trong hàng đợi.
  static const Duration _recoveryOperationTimeout = Duration(minutes: 5);

  static const List<Duration> _recoveryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 30),
  ];
  // Avoid oscillating between 4K and the safe profile. Every profile change
  // recreates AVCaptureSession on iOS and therefore closes the current file.
  static const Duration _thermalRestoreDelay = Duration(minutes: 10);

  /// Chỉ tự khôi phục chất lượng khi pin đã xuống mức này (°C) và hệ điều
  /// hành báo mát (Android MODERATE vẫn được nếu pin đo được ≤ mức này, xem
  /// [thermalRestoreCoolEnough]). Trước đây chỉ cần dưới ngưỡng nóng (45°C)
  /// nên máy dao động quanh ngưỡng bị hạ ↔ khôi phục liên tục; mỗi lần là một lần mở lại camera
  /// (Tablet/RTSP mất hình vài giây).
  static const double _thermalRestoreMaxC = 40.0;

  /// Khôi phục rồi lại phải hạ trong khoảng này: không tự khôi phục nữa cho
  /// tới khi người dùng tự chọn chất lượng hoặc mở lại trạm.
  static const Duration _thermalRestoreRelapseWindow = Duration(minutes: 30);
  DateTime? _lastThermalRestoreAt;
  bool _thermalAutoRestoreBlocked = false;
  // Sau khi dừng khẩn cấp vì nhiệt, chạy lại khi máy hết nóng đủ lâu.
  static const Duration _thermalEmergencyResumeDelay = Duration(minutes: 3);
  // Chỉ nới giảm tải sau khi mức nhiệt thấp hơn liên tục chừng này (chống
  // dao động FPS/bitrate lên xuống).
  static const Duration _thermalLoadRelaxDelay = Duration(minutes: 2);
  static const Duration _recordingTransitionGrace = Duration(seconds: 20);
  static const Duration _recordingStallTimeout = Duration(seconds: 45);
  static const Duration _bufferedVideoHardStallTimeout = Duration(minutes: 2);
  static const Duration _iosBackgroundRequestDrainTimeout = Duration(
    seconds: 6,
  );
  static const Duration _iosBackgroundRecorderTimeout = Duration(seconds: 15);
  static const Duration _iosTransportDisposeTimeout = Duration(seconds: 6);
  static const Duration _iosForegroundResumeTimeout = Duration(seconds: 30);
  static const MethodChannel _platformChannel = MethodChannel(
    'vnvar/camera_station_service',
  );

  final WhipPublisherService _whipPublisherService = WhipPublisherService();
  final RtspPublisherService _rtspPublisherService = RtspPublisherService();

  /// Ảnh bảng tỉ số in vào livestream RTMP/RTSP (Android: FFmpeg mã hoá lại
  /// bằng MediaCodec; iOS: native chồng ảnh lên luồng RTSP overlay riêng,
  /// FFmpeg chỉ copy — gói FFmpeg iOS không có VideoToolbox/libx264).
  final ScoreboardBurnIn _scoreboardBurnIn = ScoreboardBurnIn();
  StreamSubscription<Map<String, dynamic>>? _scoreboardSubscription;
  /// Cờ (burnIn, visible) của bảng tỉ số lần gần nhất runtime thấy (null
  /// cho tới lần chuẩn bị overlay đầu tiên).
  LivestreamOverlayFlags? _lastOverlayFlags;
  bool _wasRtspBeforeCameraDisable = false;
  bool _wasWhipBeforeCameraDisable = false;

  Stream<void> get stateChanges => _stateController.stream;
  WebRtcService? get webRtcService => _webRtcService;
  RecordingService? get recordingService => _recordingService;
  CameraServer? get cameraServer => _cameraServer;
  WhipPublisherService get whipPublisherService => _whipPublisherService;
  RtspPublisherService get rtspPublisherService => _rtspPublisherService;
  bool get isLiveStreaming =>
      _whipPublisherService.isLive || _rtspPublisherService.isLive;
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
  bool get thermalWarning =>
      _thermalThrottled || (_temperatureC != null && _temperatureC! >= 41.0);
  bool get thermalUserOverride => _thermalUserOverride;
  /// Máy đang nóng trong lúc cắm sạc: sạc là nguồn nhiệt lớn, nên gợi ý.
  bool get thermalChargingWhileHot => _charging && thermalWarning;
  /// FPS đang bị giới hạn tạm thời vì nhiệt và đã thật sự áp lên camera
  /// (null = không giới hạn; iOS luôn null vì không giới hạn FPS tại chỗ).
  int? get thermalFpsCap => reportedThermalFpsCap(
    isAndroid: Platform.isAndroid,
    trackId: _webRtcService?.localVideoTrack?.id,
    appliedKey: _appliedFpsCapKey,
  );

  /// Bậc giảm tải tại chỗ: 0 bình thường, 1 ấm, 2 nóng, 3 critical.
  int get thermalLoadLevel => _thermalLoadPlan.level;
  bool get thermalThrottled => _thermalThrottled;
  CameraResolutionProfile? get pendingThermalTarget => _pendingThermalTarget;
  DateTime? get pendingThermalAt => _pendingThermalAt;
  Duration? get pendingThermalIn =>
      _pendingThermalAt?.difference(DateTime.now());
  bool get justCooledDown =>
      _thermalCooledDownSince != null &&
      DateTime.now().difference(_thermalCooledDownSince!) <
          const Duration(seconds: 45);

  void dismissCooledDownNotice() {
    _thermalCooledDownSince = null;
    _emitState();
  }

  bool get autoScreenDimmed => _autoScreenDimmed;
  double? get thermalRiseRatePerMin => _thermalRiseRatePerMin;

  /// Màn hình Station báo trạng thái tối/sáng do người dùng chọn.
  void setAutoScreenDimmed(bool dimmed) {
    // Người dùng đã tự chọn: runtime không tự bật sáng lại nữa, và nếu người
    // dùng bật sáng thì nhiệt độ không tự làm tối lại trong một khoảng.
    _screenDimmedByThermal = false;
    _userScreenBrightUntil =
        dimmed ? null : DateTime.now().add(_userScreenBrightHold);
    if (_autoScreenDimmed == dimmed) return;
    _autoScreenDimmed = dimmed;
    _emitState();
  }

  /// Gọi khi màn hình Station được mở/đóng. Khi đóng, độ sáng được trả về
  /// mặc định nên cờ làm tối cũng phải reset để lần mở sau không hiển thị sai.
  void setStationDisplayAttached(bool attached) {
    _stationDisplayAttached = attached;
    if (!attached) {
      _screenDimmedByThermal = false;
      if (_autoScreenDimmed) {
        _autoScreenDimmed = false;
        _emitState();
      }
    }
  }

  int get cameraQuarterTurns => _cameraQuarterTurns;

  Future<void> setCameraQuarterTurns(int quarterTurns) async {
    final turns = (quarterTurns % 4 + 4) % 4;
    final previousTurns = _cameraQuarterTurns;
    _cameraQuarterTurns = turns;
    _recordingService?.setQuarterTurns(turns);
    await _webRtcService?.setCameraRotation(turns);
    await StationConfigService().saveCameraQuarterTurns(turns);
    if (turns != previousTurns) {
      if (_rtspPublisherService.isLive) {
        unawaited(_rtspPublisherService.restartIfPublishing());
      }
      if (_whipPublisherService.isLive) {
        unawaited(_whipPublisherService.restartIfPublishing());
      }
    }
    _emitState();
  }
  bool get storageWarning => _recordingService?.lowStorageWarning ?? false;
  bool get lifecycleSuspended => _iosLifecycleSuspended;
  bool get lifecycleResuming => _iosResumeQueued;
  bool get networkRecovering => _networkRecovering;
  String? get lanAddress => _lanAddress;
  String? get networkError => _networkError ?? _networkReadError;

  /// Lần nối lại dịch vụ mạng gần nhất thất bại: thời điểm runtime tự thử lại
  /// (null nếu không có lịch thử lại).
  DateTime? get networkReconnectRetryAt => _networkReconnectRetryAt;

  /// Khởi tạo lỗi và runtime đã lên lịch tự khởi tạo lại lúc này (null nếu
  /// không có lịch: chưa lỗi, đã dừng, hoặc lỗi thiếu quyền).
  DateTime? get nextInitRetryAt => _nextInitRetryAt;

  /// Lỗi của lần khởi tạo gần nhất (null nếu lần gần nhất thành công). Lỗi
  /// thiếu quyền là [StationException] mã [StationErrorCode.permissionDenied].
  Object? get lastInitError => _lastInitError;

  /// Khởi tạo lỗi vì thiếu quyền camera/micro (không tự thử lại).
  bool get initPermissionDenied {
    final error = _lastInitError;
    return error is StationException && error.isPermissionDenied;
  }

  /// Cấu hình người dùng muốn, sẽ được khôi phục khi máy nguội (null nếu
  /// không bị hạ vì nhiệt).
  CameraResolutionProfile? get thermalTargetProfile =>
      _thermalThrottled ? _profileBeforeThermalThrottle : null;
  String get captureState {
    if (_thermalCriticalSuspended) return 'thermal_suspended';
    if (_recordingService?.storageSuspended == true) {
      return 'storage_suspended';
    }
    if (_scannerPaused) return 'scanner_paused';
    if (_iosResumeQueued) return 'lifecycle_resuming';
    if (_iosLifecycleSuspended) return 'lifecycle_suspended';
    if (_recovering) return 'recovering';
    if (_profileSwitching) return 'profile_switching';
    if (_recordingService?.recording == true) return 'recording';
    return ready ? 'ready' : 'starting';
  }

  String get thermalState {
    if (_thermalCriticalSuspended || _thermalCriticalDegraded) {
      return 'critical';
    }
    if (_thermalThrottled) return 'hot';
    return _temperatureC == null ? 'unknown' : 'normal';
  }

  Map<String, dynamic> get captureMetrics => {
    'actualFps': _iosActualFps,
    'requestedFps': _iosRequestedFps ?? _resolutionProfile.fps,
    'lowFpsReports': 0,
    'lastMeasuredAt': _iosPerformanceMeasuredAt?.toIso8601String(),
    'lastAdaptedAt': null,
    'adaptive': false,
  };

  CameraResolutionProfile get resolutionProfile => _resolutionProfile;
  bool get resolutionLocked => _resolutionLocked;
  List<CameraResolutionProfile> get supportedResolutionProfiles =>
      List.unmodifiable(_supportedResolutionProfiles);

  /// Livestream RTMP/RTSP: chuẩn bị ảnh bảng tỉ số đúng kích thước video.
  Future<LivestreamOverlay?> _prepareLivestreamOverlay(
    String localRtspUrl, {
    required bool scrollingTicker,
  }) async {
    // Android: FFmpeg mã hoá lại (MediaCodec). iOS: native tạo luồng overlay
    // (RtspPublisherService gọi startOverlayRtsp với ảnh này).
    if (!Platform.isAndroid && !Platform.isIOS) return null;
    final flags = await _scoreboardBurnIn.overlayFlags();
    _lastOverlayFlags = flags;
    // Tắt in hoặc bảng tỉ số đang Ẩn: phát copy nguyên luồng (không giải mã /
    // mã hoá lại; iOS không mở luồng overlay native). Bấm Hiện khi đang phát
    // sẽ phát lại phiên (xem _handleScoreboardChange).
    if (!livestreamOverlayNeeded(flags)) return null;
    var size = await probeRtspVideoSize(localRtspUrl);
    size ??= (width: _resolutionProfile.width, height: _resolutionProfile.height);
    return _scoreboardBurnIn.start(
      size.width,
      size.height,
      scrollingTicker: scrollingTicker,
      // Android: chồng từng vùng nhỏ thay vì PNG toàn khung. iOS giữ một
      // PNG toàn khung cho native (hợp đồng C5).
      cropToRegions: Platform.isAndroid,
    );
  }

  /// Bảng tỉ số đổi cờ "in vào livestream" / Ẩn–Hiện khi đang phát: chạy lại
  /// phiên đẩy luồng khi cần (mất hình vài giây) — xem
  /// [livestreamOverlayRestartNeeded]. Đổi điểm số, tên, cảnh... không phát
  /// lại.
  void _handleScoreboardChange(Map<String, dynamic> json) {
    final next = livestreamOverlayFlags(json);
    final previous = _lastOverlayFlags;
    _lastOverlayFlags = next;
    if (previous == null ||
        previous == next ||
        (!Platform.isAndroid && !Platform.isIOS)) {
      return;
    }
    final rtsp = _rtspPublisherService;
    if (!rtsp.wantsPublishing) return;
    // Vừa bật lại "in vào livestream": cho phép thử in lại sau lỗi cũ.
    if (next.burnIn && !previous.burnIn) rtsp.clearOverlayFailure();
    if (!livestreamOverlayRestartNeeded(
      previous: previous,
      next: next,
      sessionHasOverlay: rtsp.overlayActive,
    )) {
      return;
    }
    // Máy đã báo không in được bảng tỉ số: phát lại cũng không có bảng.
    if (livestreamOverlayNeeded(next) && rtsp.overlayUnavailable) return;
    unawaited(rtsp.restartIfPublishing());
  }

  /// Bảng tỉ số hiện cần in vào livestream (burnIn && visible). Publisher
  /// kiểm sau khi phiên khởi chạy để bắt lần bấm Hiện trong lúc phiên đang
  /// chuẩn bị/kết nối lại (lúc đó [_handleScoreboardChange] so với phiên cũ).
  bool _livestreamOverlayWantedNow() {
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    return livestreamOverlayNeeded(
      livestreamOverlayFlags(ScoreboardService.instance.snapshot()),
    );
  }

  /// Android, chồng từng vùng: bảng tỉ số mới (đổi vị trí, "Kích thước", số
  /// set, lần đầu dùng cảnh lớn) cần vùng lớn hơn vùng đã khoá cho phiên
  /// FFmpeg: phát lại để không bị cắt bảng.
  void _handleScoreboardRegionOutgrown() {
    final rtsp = _rtspPublisherService;
    if (!rtsp.wantsPublishing || !rtsp.overlayActive) return;
    unawaited(rtsp.restartIfPublishing());
  }

  /// Đang phát RTMP/RTSP (chưa in bảng tỉ số) mà bảng đang Ẩn: bấm Hiện sẽ
  /// phát lại phiên (~3 giây) để in bảng tỉ số vào video.
  bool get scoreboardShowRestartsLive {
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    final rtsp = _rtspPublisherService;
    if (!rtsp.wantsPublishing ||
        rtsp.overlayActive ||
        rtsp.overlayUnavailable) {
      return false;
    }
    final flags = livestreamOverlayFlags(ScoreboardService.instance.snapshot());
    return flags.burnIn && !flags.visible;
  }

  Future<void> setResolutionLocked(bool locked) async {
    if (_resolutionLocked == locked) return;
    _resolutionLocked = locked;
    await StationConfigService().saveResolutionLocked(locked);
    if (locked) {
      // Hủy mọi lịch trình hạ độ phân giải do nhiệt độ nếu có
      _pendingThermalThrottleTimer?.cancel();
      _pendingThermalThrottleTimer = null;
      _pendingThermalTarget = null;
      _pendingThermalAt = null;
      _thermalUserOverride = true;
      _thermalAutoRestoreBlocked = false;
      _lastThermalRestoreAt = null;
      developer.log(
        '[LOCK] Chế độ độ phân giải đã được khóa. Tự động vô hiệu hóa hạ độ phân giải khi máy nóng.',
        name: 'CameraStationRuntime',
      );
      // Nếu máy đang bị thermal throttled trước đó, khôi phục lại profile trước khi throttle.
      // Đang critical (đã giảm tải hoặc dừng khẩn cấp) thì KHÔNG mở camera ở
      // cấu hình cao (lần kiểm tra nhiệt kế tiếp sẽ lại hạ = mở lại camera 2
      // lần): profile mục tiêu được giữ và khôi phục khi máy nguội.
      if (_thermalThrottled &&
          _profileBeforeThermalThrottle != null &&
          !_thermalCriticalDegraded &&
          !_thermalCriticalSuspended &&
          _cameraOpenBlockedError() == null) {
        final restoreProfile = _profileBeforeThermalThrottle!;
        // Chỉ xoá cờ hạ nhiệt khi đã khôi phục được profile; nếu lỗi thì giữ
        // nguyên để lần sau (mở khoá/khoá lại, hồi nhiệt) còn thử khôi phục.
        unawaited(
          _serializeLifecycle(
            () => _setResolutionProfileInternal(
              restoreProfile,
              persistSelection: false,
            ),
            timeout: _reconfigureOperationTimeout,
            label: 'lock_restore',
            recoverOnTimeout: true,
          ).then<void>(
            (_) {
              if (identical(_profileBeforeThermalThrottle, restoreProfile) &&
                  _resolutionProfile == restoreProfile) {
                _thermalThrottled = false;
                _profileBeforeThermalThrottle = null;
              }
              _emitState();
            },
            onError: (Object error, StackTrace stackTrace) {
              developer.log(
                '[LOCK] Unable to restore the pre-thermal resolution profile',
                error: error,
                stackTrace: stackTrace,
                name: 'CameraStationRuntime',
              );
              _emitState();
            },
          ),
        );
      }
    }
    _emitState();
  }

  Future<List<CameraResolutionProfile>>
  refreshSupportedResolutionProfiles() async {
    final webRtc = _webRtcService;
    if (webRtc == null || !_cameraEnabled) {
      return supportedResolutionProfiles;
    }
    final detected = await webRtc.getSupportedResolutionProfiles(
      facingMode: webRtc.currentFacingMode,
      fallbackWhenUnavailable: false,
    );
    if (detected.isNotEmpty) {
      _supportedResolutionProfiles = detected;
      _emitState();
    }
    return supportedResolutionProfiles;
  }

  Future<void> initialize({
    required String cameraId,
    required String courtId,
    required String deviceId,
  }) {
    // Khởi tạo thủ công thay thế mọi lịch tự khởi tạo lại đang chờ.
    _cancelInitRetry(resetAttempts: true);
    _interruptRecovery();
    return _runInitialize(
      cameraId: cameraId,
      courtId: courtId,
      deviceId: deviceId,
      restart: false,
    );
  }

  /// Chạy khởi tạo trong hàng đợi vòng đời. Lỗi thiếu quyền được phân loại
  /// thành [StationException] ([StationErrorCode.permissionDenied]) và không
  /// tự thử lại; các lỗi khác được tự thử lại với backoff [initRetryDelay].
  Future<void> _runInitialize({
    required String cameraId,
    required String courtId,
    required String deviceId,
    required bool restart,
  }) async {
    final retryEpoch = _initRetryEpoch;
    final session = ++_initSession;
    try {
      // Hộp thoại quyền lần cài đầu chờ người dùng trả lời, có thể lâu: xin
      // quyền TRƯỚC khi vào hàng đợi vòng đời để không tính vào timeout khởi
      // tạo. Thiếu quyền camera → StationException permissionDenied (không tự
      // thử lại). initializeCamera vẫn gọi lại (đã có quyền nên trả ngay).
      await WebRtcService.ensureCapturePermissions();
      await _serializeLifecycle(() async {
        // Đã bị thay thế (stop/khởi tạo mới) trong lúc chờ hàng đợi.
        if (session != _initSession) {
          developer.log(
            '[SERVICE] Initialization superseded while queued; skipping '
            '(runtime not marked as initialized)',
            name: 'CameraStationRuntime',
          );
          return;
        }
        final action = initializeEntryAction(
          restart: restart,
          serverRunning: ready,
          initCompleted: _initCompleted,
          sameIdentity:
              _cameraId == cameraId &&
              _courtId == courtId &&
              _deviceId == deviceId,
        );
        if (action == InitializeEntryAction.skip) return;
        if (action == InitializeEntryAction.stopThenInitialize) {
          if (!restart) {
            developer.log(
              '[SERVICE] Server is running but the previous initialization '
              'did not complete; cleaning up before initializing again',
              name: 'CameraStationRuntime',
            );
          }
          await _stopInternal();
        }
        await _initializeInternal(
          cameraId: cameraId,
          courtId: courtId,
          deviceId: deviceId,
          session: session,
        );
      }, timeout: _initializeOperationTimeout, label: 'initialize');
    } catch (error, stackTrace) {
      if (session != _initSession) {
        // Lần khởi tạo cũ đã bị thay thế: không ghi đè lỗi/lịch thử lại của
        // phiên hiện tại.
        Error.throwWithStackTrace(error, stackTrace);
      }
      final classified = isPermissionDeniedError(error)
          ? (error is StationException
                ? error
                : StationException.fromCode(
                    StationErrorCode.permissionDenied,
                    cause: error,
                  ))
          : error;
      _lastInitError = classified;
      // Đã dừng hoặc đã có lần khởi tạo thủ công mới trong lúc chờ: không tự
      // lên lịch thử lại cho lần khởi tạo cũ này.
      if (retryEpoch == _initRetryEpoch) {
        if (isRetryableInitError(classified)) {
          _scheduleInitRetry(
            cameraId: cameraId,
            courtId: courtId,
            deviceId: deviceId,
          );
        } else {
          _cancelInitRetry(resetAttempts: true);
          developer.log(
            '[SERVICE] Initialization failed because camera/microphone '
            'permission is missing; not retrying automatically',
            name: 'CameraStationRuntime',
          );
        }
      }
      _emitState();
      Error.throwWithStackTrace(classified, stackTrace);
    }
    if (retryEpoch == _initRetryEpoch && session == _initSession) {
      _lastInitError = null;
      _cancelInitRetry(resetAttempts: true);
    }
    _emitState();
  }

  void _scheduleInitRetry({
    required String cameraId,
    required String courtId,
    required String deviceId,
  }) {
    _initRetryTimer?.cancel();
    final delay = initRetryDelay(_initRetryAttempt);
    _initRetryAttempt++;
    _nextInitRetryAt = DateTime.now().add(delay);
    developer.log(
      '[SERVICE] Scheduling automatic initialization retry '
      '#$_initRetryAttempt in ${delay.inSeconds}s',
      name: 'CameraStationRuntime',
    );
    _initRetryTimer = Timer(delay, () {
      _initRetryTimer = null;
      _nextInitRetryAt = null;
      _emitState();
      // Lỗi đã được ghi vào lastInitError và tự lên lịch lần kế tiếp.
      // restart: lần trước có thể đã quá hạn và dừng giữa chừng (server đã
      // chạy nhưng chưa có camera/monitor): dọn sạch rồi khởi tạo lại thay vì
      // coi runtime dở dang là đã sẵn sàng.
      unawaited(
        _runInitialize(
          cameraId: cameraId,
          courtId: courtId,
          deviceId: deviceId,
          restart: true,
        ).catchError((Object _) {}),
      );
    });
  }

  void _cancelInitRetry({required bool resetAttempts}) {
    _initRetryEpoch++;
    _initRetryTimer?.cancel();
    _initRetryTimer = null;
    _nextInitRetryAt = null;
    if (resetAttempts) _initRetryAttempt = 0;
  }

  /// Chạy [operation] tuần tự sau các thao tác vòng đời trước đó.
  ///
  /// Mỗi thao tác có thời gian tối đa [timeout]: quá hạn thì hàng đợi được
  /// giải phóng (thao tác treo vẫn chạy nền nhưng kết quả bị bỏ qua), người
  /// gọi nhận [StationException] ([StationErrorCode.operationTimeout]); nếu
  /// [recoverOnTimeout] thì lên lịch khôi phục camera.
  Future<T> _serializeLifecycle<T>(
    Future<T> Function() operation, {
    Duration timeout = _lifecycleOperationTimeout,
    String label = 'operation',
    bool recoverOnTimeout = false,
  }) {
    final completer = Completer<T>();
    final previous = _lifecycleTail;
    _lifecycleOperationsPending++;
    _lifecycleTail = previous.catchError((Object _) {}).then((_) async {
      try {
        var timedOut = false;
        final pending = Future<T>.sync(operation);
        try {
          completer.complete(
            await pending.timeout(
              timeout,
              onTimeout: () {
                timedOut = true;
                throw TimeoutException(
                  'Lifecycle $label exceeded ${timeout.inSeconds}s',
                  timeout,
                );
              },
            ),
          );
        } catch (error, stackTrace) {
          if (!timedOut) {
            completer.completeError(error, stackTrace);
            return;
          }
          // Thao tác treo vẫn chạy nền: đổi epoch để nó dừng ở mốc kiểm tra kế
          // tiếp (không mở camera song song với thao tác sau).
          _lifecycleEpoch++;
          developer.log(
            '[LIFECYCLE] "$label" exceeded ${timeout.inSeconds}s; releasing the '
            'lifecycle queue and ignoring its late result',
            error: error,
            stackTrace: stackTrace,
            name: 'CameraStationRuntime',
          );
          unawaited(
            pending.then<void>(
              (_) {},
              onError: (Object lateError, StackTrace lateStackTrace) {
                developer.log(
                  '[LIFECYCLE] Timed-out "$label" failed later',
                  error: lateError,
                  stackTrace: lateStackTrace,
                  name: 'CameraStationRuntime',
                );
              },
            ),
          );
          completer.completeError(
            StationException.fromCode(
              StationErrorCode.operationTimeout,
              cause: error,
            ),
            stackTrace,
          );
          if (recoverOnTimeout) _recoverAfterLifecycleTimeout(label);
        }
      } finally {
        _lifecycleOperationsPending--;
      }
    });
    return completer.future;
  }

  /// Một thao tác mở/đổi camera bị treo: camera có thể đang ở trạng thái dở
  /// dang. Bỏ cờ đổi cấu hình (finally của thao tác treo chưa chạy) và giao
  /// cho recovery mở lại camera.
  void _recoverAfterLifecycleTimeout(String label) {
    // Thao tác treo không còn được tự bỏ cờ (finally của nó bỏ qua khi đã
    // quá hạn): luôn bỏ cờ đổi cấu hình, kể cả khi không khôi phục.
    _profileSwitching = false;
    // Thao tác đổi lens treo vẫn được giữ trong _lensSwitchOperation cho tới
    // khi Future của nó hoàn tất (microtask sau): bỏ ngay để recovery không
    // bị coi là "đang đổi cấu hình".
    _lensSwitchOperation = null;
    if (_stopping || !_cameraEnabled) {
      _emitState();
      return;
    }
    _generation++;
    _emitState();
    _scheduleRecovery('lifecycle_timeout_$label');
  }

  /// Huỷ recovery chỉ khi thao tác đổi cấu hình thật sự sẽ mở lại camera
  /// (xem [reconfigurationShouldInterruptRecovery]).
  void _interruptRecoveryForReconfiguration({
    required bool changesConfiguration,
  }) {
    if (reconfigurationShouldInterruptRecovery(
      cameraEnabled: _cameraEnabled,
      openBlocked: _cameraOpenBlockedError() != null,
      changesConfiguration: changesConfiguration,
    )) {
      _interruptRecovery();
    }
  }

  void _interruptRecovery() {
    _generation++;
    if (!_recoveryCancellation.isCompleted) {
      _recoveryCancellation.complete();
    }
    _recoveryCancellation = Completer<void>();
  }

  /// Ném [_StaleLifecycleOperation] nếu thao tác bắt đầu ở [epoch] đã quá hạn
  /// (hàng đợi vòng đời đã giao cho thao tác khác).
  void _throwIfLifecycleStale(int epoch, String label) {
    if (epoch != _lifecycleEpoch) throw _StaleLifecycleOperation(label);
  }

  /// Bật/tắt giữ màn hình sáng. Lỗi wakelock chỉ được ghi log, không được làm
  /// hỏng thao tác mở/đóng camera.
  Future<void> _setWakelockSafely(bool enabled) async {
    try {
      if (enabled) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (error, stackTrace) {
      developer.log(
        '[SERVICE] Unable to ${enabled ? 'enable' : 'disable'} wakelock',
        error: error,
        stackTrace: stackTrace,
        name: 'CameraStationRuntime',
      );
    }
  }

  Future<void> _initializeInternal({
    required String cameraId,
    required String courtId,
    required String deviceId,
    required int session,
  }) async {
    final epoch = _lifecycleEpoch;
    // Lần khởi tạo này đã quá hạn (hàng đợi giải phóng) hoặc bị thay thế
    // (stop/khởi tạo mới): dừng sớm, không mở camera/server nữa. Nếu vẫn đang
    // giữ hàng đợi thì dọn phần đã khởi tạo dở để thao tác kế tiếp bắt đầu
    // từ trạng thái sạch; đã quá hạn thì không đụng tới runtime của lần sau.
    Future<bool> abortIfStale(String step) async {
      if (session == _initSession && epoch == _lifecycleEpoch) return false;
      final timedOut = epoch != _lifecycleEpoch;
      developer.log(
        '[SERVICE] Initialization ${timedOut ? 'timed out' : 'superseded'} '
        'before "$step"; aborting without marking the runtime as '
        'initialized${timedOut ? ' (cleanup left to the current owner)' : ''}',
        name: 'CameraStationRuntime',
      );
      if (epoch == _lifecycleEpoch) {
        try {
          await _stopInternal();
        } catch (error, stackTrace) {
          developer.log(
            '[SERVICE] Cleanup after superseded initialization failed',
            error: error,
            stackTrace: stackTrace,
            name: 'CameraStationRuntime',
          );
        }
      }
      return true;
    }

    _initCompleted = false;
    _stopping = false;
    _cameraEnabled = true;
    _iosLifecycleSuspended = false;
    _iosResumeQueued = false;
    _iosAppInForeground = true;
    if (_cameraId != null &&
        (_cameraId != cameraId ||
            _courtId != courtId ||
            _deviceId != deviceId)) {
      await _stopInternal();
      _stopping = false;
      _cameraEnabled = true;
    }
    await _setIosStationActive(true);
    if (await abortIfStale('setup')) return;

    developer.log(
      '[SERVICE] Initializing runtime: $cameraId / $courtId',
      name: 'CameraStationRuntime',
    );

    final webRtc = _webRtcService ?? WebRtcService();
    final recording = _recordingService ?? RecordingService(cameraId: cameraId);

    webRtc.onCameraFailure = _scheduleRecovery;
    webRtc.onRtspStateChanged = _emitState;
    webRtc.onIosCapturePerformance = _handleIosCapturePerformance;
    webRtc.onAndroidTaskRemoved = _handleAndroidTaskRemoved;
    _webRtcService = webRtc;
    _whipPublisherService.attachWebRtcService(webRtc);
    _rtspPublisherService.onTargetBitrateChanged = (bps) async {
      await _webRtcService?.setRtspTargetBitrate(bps);
    };
    _rtspPublisherService.waitForLocalSource = () async =>
        await _webRtcService?.waitForRtspReady() ?? false;
    _rtspPublisherService.prepareOverlay = _prepareLivestreamOverlay;
    _rtspPublisherService.releaseOverlay = _scoreboardBurnIn.stop;
    _rtspPublisherService.overlayWanted = _livestreamOverlayWantedNow;
    // iOS: track camera cho luồng overlay native (cùng track với startRtsp)
    // và báo native nạp lại ảnh mỗi khi bảng tỉ số được vẽ lại.
    _rtspPublisherService.videoTrackId = () =>
        _webRtcService?.localVideoTrack?.id;
    _scoreboardBurnIn.onImageWritten =
        _rtspPublisherService.handleOverlayImageWritten;
    _scoreboardBurnIn.onRegionOutgrown = _handleScoreboardRegionOutgrown;
    _scoreboardSubscription ??= ScoreboardService.instance.changes.listen(
      _handleScoreboardChange,
    );
    _rtspPublisherService.hasWifiNetwork = () =>
        _networkSignature?.any(
          (entry) => lanInterfacePriority(entry.split('|').first) == 0,
        ) ??
        false;
    try {
      final ev = await StationConfigService().loadExposureBias();
      // Áp trước khi mở camera để lần đo sáng đầu tiên đã dùng đúng mức.
      if (webRtc.localVideoTrack == null) {
        await webRtc.setExposureBias(ev);
      }
    } catch (_) {}
    try {
      await webRtc.setRtspTabletAudio(
        await StationConfigService().loadRtspTabletAudio(),
      );
    } catch (_) {}
    _recordingService = recording;
    _cameraId = cameraId;
    _courtId = courtId;
    _deviceId = deviceId;

    try {
      _supportedResolutionProfiles = await webRtc
          .getSupportedResolutionProfiles();
      final savedProfile = await StationConfigService().loadResolutionProfile();
      _resolutionLocked = await StationConfigService().loadResolutionLocked();
      _resolutionProfile = selectStartupResolutionProfile(
        _supportedResolutionProfiles,
        savedProfile,
      );
      // Lỗi đọc nhiệt độ không được làm hỏng khởi động: coi như không biết
      // nhiệt độ, thermal monitor sẽ đọc lại sau 10 giây.
      _ThermalSnapshot preflightThermal;
      try {
        preflightThermal = await _readThermalSnapshot();
      } catch (error, stackTrace) {
        developer.log(
          '[THERMAL] Preflight thermal read failed; starting normally',
          error: error,
          stackTrace: stackTrace,
          name: 'CameraStationRuntime',
        );
        preflightThermal = _unknownThermalSnapshot;
      }
      if (await abortIfStale('thermal preflight')) return;
      _temperatureC = preflightThermal.temperatureC;
      // Chỉ mức khẩn cấp mới giữ camera dừng; critical thì khởi động ở cấu
      // hình nhẹ (720p30) để vẫn quay và livestream.
      final criticalThermal = preflightThermal.emergency;
      // Cùng chính sách với lúc chạy: mức "nóng" không hạ độ phân giải (thermal
      // monitor giảm tải tại chỗ: FPS, bitrate, làm tối màn hình); chỉ
      // critical/khẩn cấp mới khởi động ở 720p30.
      if (startupThermalDegradeRequired(
        critical: preflightThermal.critical,
        emergency: preflightThermal.emergency,
      )) {
        _profileBeforeThermalThrottle = _resolutionProfile;
        _thermalThrottled = true;
        _resolutionProfile = CameraResolutionProfile.hd720.withFps(30);
      }
      if (preflightThermal.critical && !criticalThermal) {
        _thermalCriticalDegraded = true;
        _thermalCriticalDegradedSince = DateTime.now();
        developer.log(
          '[THERMAL] Critical state before camera startup; starting at 720p/30fps',
          name: 'CameraStationRuntime',
        );
      }
      if (criticalThermal) {
        _thermalCriticalSuspended = true;
        // Lens/zoom đã lưu để khi nguội camera mở lại đúng góc quay (không
        // rơi về camera chính 1x).
        _thermalSavedLens = await _loadSavedLensState();
        developer.log(
          '[THERMAL] Emergency state detected before camera startup; capture remains paused',
          name: 'CameraStationRuntime',
        );
      }
      webRtc.setResolutionProfile(_resolutionProfile);
      if (!criticalThermal) {
        // Nếu đã có saved lens state (ultra-wide), pre-set preferred device ID
        // để initializeCamera mở đúng lens ngay từ đầu.
        final savedLens = await _loadSavedLensState();
        if (await abortIfStale('camera open')) return;
        _preselectLens(webRtc, savedLens, facingMode: 'environment');
        await webRtc.initializeCamera(facingMode: 'environment');
        if (await abortIfStale('microphone')) return;
        // Camera Station always requests microphone audio. A denied permission
        // intentionally falls back to video-only recording.
        await webRtc.ensureMicrophoneEnabled();
        // Restore lens state và zoom HOÀN TẤT trước khi bắt đầu recording
        // để camera pipeline ổn định, không làm gián đoạn AVAssetWriter/MediaRecorder.
        await _restoreLensState(webRtc, savedLens, context: 'startup');
      }

      final savedQuarterTurns =
          await StationConfigService().loadCameraQuarterTurns();
      _cameraQuarterTurns = savedQuarterTurns;
      recording.setQuarterTurns(savedQuarterTurns);
      recording.setFacingMode(webRtc.currentFacingMode);

      final apiPort = await StationConfigService().loadApiPort();
      if (await abortIfStale('server start')) return;
      final server = CameraServer(
        courtId: courtId,
        cameraId: cameraId,
        deviceId: deviceId,
        webRtcService: webRtc,
        recordingService: recording,
        apiPort: apiPort,
        onStateChanged: _emitState,
        captureStateProvider: () => captureState,
        thermalStateProvider: () => thermalState,
        temperatureProvider: () => _temperatureC,
        captureMetricsProvider: () => captureMetrics,
      );
      _cameraServer = server;

      await server.start();
      if (await abortIfStale('recording start')) return;
      if (!criticalThermal) {
        try {
          await _waitForIosCaptureWarmup();
          if (await abortIfStale('recording start')) return;
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
      if (await abortIfStale('monitors')) return;
      _startHealthMonitor();
      _startThermalMonitor();
      _startNetworkMonitor();
      // Mốc kiểm tra cuối cùng đã qua và các monitor đã bật: runtime đã khởi
      // tạo xong (đặt đồng bộ ngay sau khi bật monitor, không có await xen giữa).
      _initCompleted = true;

      // Giữ màn hình luôn sáng khi camera đang hoạt động.
      // Trên iOS, điều này đảm bảo app luôn ở foreground và camera
      // không bị hệ điều hành dừng khi màn hình tắt.
      // Lỗi wakelock không được làm hỏng khởi động (camera/server đã chạy).
      try {
        await WakelockPlus.enable();
      } catch (error, stackTrace) {
        developer.log(
          '[SERVICE] Unable to enable wakelock',
          error: error,
          stackTrace: stackTrace,
          name: 'CameraStationRuntime',
        );
      }
      await _setIosStationActive(true);

      developer.log(
        '[RECORDING] Automatic recording is active (wakelock enabled)',
        name: 'CameraStationRuntime',
      );
      if (!criticalThermal) _resumeLivePublishers();
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
      // Lần khởi tạo đã quá hạn rồi mới lỗi: hàng đợi đã thuộc về thao tác
      // khác (có thể là runtime mới), không được dọn runtime.
      if (epoch == _lifecycleEpoch) await _stopInternal();
      rethrow;
    }
  }

  Future<void> restart({
    required String cameraId,
    required String courtId,
    required String deviceId,
  }) {
    _cancelInitRetry(resetAttempts: true);
    _interruptRecovery();
    return _runInitialize(
      cameraId: cameraId,
      courtId: courtId,
      deviceId: deviceId,
      restart: true,
    );
  }

  Future<void> stop({Future<void> Function()? onRecorderStopped}) {
    _stopping = true;
    // Dừng chủ động: không tự khởi tạo lại nữa.
    _cancelInitRetry(resetAttempts: true);
    // Lần khởi tạo đang chạy/đang chờ trở thành phiên cũ: dừng sớm, không ghi
    // lỗi hay lên lịch thử lại.
    _initSession++;
    _lastInitError = null;
    _interruptRecovery();
    return _serializeLifecycle(
      () => _stopInternal(onRecorderStopped: onRecorderStopped),
      timeout: _stopOperationTimeout,
      label: 'stop',
    );
  }

  Future<void> _stopInternal({
    Future<void> Function()? onRecorderStopped,
  }) async {
    _stopping = true;
    _initCompleted = false;
    // Kiểm tra network/thermal/health của phiên cũ có thể vẫn đang chờ I/O:
    // đổi phiên để kết quả của chúng bị bỏ qua.
    _monitorSession++;
    _healthTimer?.cancel();
    _healthTimer = null;
    _thermalTimer?.cancel();
    _thermalTimer = null;
    _networkTimer?.cancel();
    _networkTimer = null;
    _networkCheckRunning = false;
    _networkObservationInitialized = false;
    _missingNetworkObservations = 0;
    _networkRecovering = false;
    _lanAddress = null;
    _networkError = null;
    _networkReadError = null;
    _networkReconnectFailures = 0;
    _networkReconnectRetryAt = null;
    _networkSignature = null;
    _pendingThermalThrottleTimer?.cancel();
    _pendingThermalThrottleTimer = null;
    _pendingThermalTarget = null;
    _pendingThermalAt = null;
    _pendingThermalRestoreTimer?.cancel();
    _pendingThermalRestoreTimer = null;
    _thermalThrottled = false;
    _thermalRestoreInFlight = false;
    _thermalCriticalSuspended = false;
    _thermalCriticalDegraded = false;
    _thermalCriticalDegradedSince = null;
    _thermalCriticalStreak = 0;
    _thermalEmergencyStreak = 0;
    _thermalNonCriticalStreak = 0;
    _thermalSuspendQueued = false;
    _thermalResumeQueued = false;
    _thermalDegradeQueued = false;
    _thermalSavedLens = null;
    _criticalProfileSwitchFailed = false;
    _thermalLoadPlan = thermalLoadPlanNormal;
    _thermalLoadRelaxSince = null;
    _appliedFpsCapKey = null;
    _charging = false;
    _thermalCheckRunning = false;
    _thermalNormalSince = null;
    _temperatureC = null;
    _temperatureHistory.clear();
    _thermalRiseRatePerMin = null;
    _thermalAutoRestoreBlocked = false;
    _lastThermalRestoreAt = null;
    if (_screenDimmedByThermal) {
      _screenDimmedByThermal = false;
      _autoScreenDimmed = false;
      unawaited(_setScreenDimmedSafely(false));
    }
    _profileBeforeThermalThrottle = null;
    _storageCleanupTimer?.cancel();
    _storageCleanupTimer = null;
    _storageCleanupRunning = false;
    _healthCheckRunning = false;
    _iosActualFps = null;
    _iosRequestedFps = null;
    _iosPerformanceMeasuredAt = null;
    _resetRecordingProgressWatchdog();

    final server = _cameraServer;
    final webRtc = _webRtcService;

    // Giữ ý định phát của người dùng nhưng dừng phiên đang dùng camera sắp bị
    // dispose; lần khởi tạo kế tiếp sẽ phát lại.
    await _pauseLivePublishers();
    _whipPublisherService.attachWebRtcService(null);
    _scannerPaused = false;

    _cameraServer = null;
    _recordingService = null;
    _webRtcService = null;
    _cameraId = null;
    _courtId = null;
    _deviceId = null;
    _cameraEnabled = false;
    _wasRtspBeforeCameraDisable = false;
    _wasWhipBeforeCameraDisable = false;
    _iosLifecycleSuspended = false;
    _iosResumeQueued = false;
    _iosAppInForeground = true;

    try {
      await server?.stop(onRecorderStopped: onRecorderStopped);
    } finally {
      if (webRtc != null) {
        webRtc.onCameraFailure = null;
        webRtc.onRtspStateChanged = null;
        webRtc.onIosCapturePerformance = null;
        webRtc.onAndroidTaskRemoved = null;
      }
      try {
        await webRtc?.dispose();
      } catch (error, stackTrace) {
        // Lỗi dispose không được bỏ qua phần dọn bên dưới: nếu không wakelock bị
        // giữ mãi và _stopping kẹt true (thermal/health bị bỏ qua).
        developer.log(
          '[RUNTIME] WebRTC dispose failed during stop',
          error: error,
          stackTrace: stackTrace,
          name: 'CameraStationRuntime',
        );
      }
      _recovering = false;
      _stopping = false;

      // Cho phép màn hình tắt bình thường khi dừng camera.
      try {
        await WakelockPlus.disable();
      } catch (_) {}
      await _setIosStationActive(false);

      _emitState();
    }

    developer.log('[SERVICE] Runtime stopped', name: 'CameraStationRuntime');
  }

  Future<void> setCameraEnabled(bool enabled) {
    _interruptRecovery();
    return _serializeLifecycle(
      () => _setCameraEnabledInternal(enabled),
      timeout: _reconfigureOperationTimeout,
      label: 'camera_enable',
      recoverOnTimeout: enabled,
    );
  }

  Future<void> suspendForIosBackground() {
    if (!Platform.isIOS) return Future<void>.value();
    // Update this synchronously even when capture is already suspended. A
    // queued resume can otherwise reopen AVCaptureSession after the app has
    // immediately moved back to the background.
    _iosAppInForeground = false;
    if (_iosLifecycleSuspended || !_cameraEnabled) {
      return Future<void>.value();
    }
    _iosLifecycleSuspended = true;
    final lifecycleGeneration = ++_iosLifecycleGeneration;
    // Xin thời gian chạy nền NGAY (đồng bộ, trước khi xếp hàng): thao tác
    // trước trong hàng đợi có thể chiếm vài giây, iOS sẽ treo app trước khi
    // segment được chốt nếu chỉ xin khi thao tác này bắt đầu chạy.
    final releaseFinalization = _holdIosBackgroundFinalization();
    _interruptRecovery();
    _emitState();
    // Trả background task đúng một lần dù thao tác xong, lỗi, bị bỏ qua hay
    // quá hạn (_serializeLifecycle luôn hoàn tất Future sau tối đa
    // _iosSuspendOperationTimeout).
    return _serializeLifecycle(
      () => _suspendForIosBackgroundInternal(lifecycleGeneration),
      timeout: _iosSuspendOperationTimeout,
      label: 'ios_suspend',
    ).whenComplete(releaseFinalization);
  }

  Future<void> _suspendForIosBackgroundInternal(int lifecycleGeneration) async {
    if (!Platform.isIOS ||
        !_iosLifecycleSuspended ||
        lifecycleGeneration != _iosLifecycleGeneration) {
      return;
    }
    final recording = _recordingService;
    final webRtc = _webRtcService;
    if (recording == null || webRtc == null) return;
    developer.log(
      '[LIFECYCLE] iOS entering background; finalizing current segment',
      name: 'CameraStationRuntime',
    );
    // Background task đã được xin đồng bộ trong suspendForIosBackground.
    await _pauseLivePublishers();
    try {
      try {
        // Finish an already accepted CheckVAR request before stopping the
        // recorder. Without this barrier, the lifecycle queue and HTTP queue
        // could finalize the same recorder concurrently.
        await _cameraServer?.prepareForIosBackground().timeout(
          _iosBackgroundRequestDrainTimeout,
        );
        await _stopRecordingAtIosBoundary(
          recording,
        ).timeout(_iosBackgroundRecorderTimeout);
      } on TimeoutException catch (error, stackTrace) {
        developer.log(
          '[LIFECYCLE] iOS background finalization timed out; releasing the '
          'lifecycle queue so foreground recovery cannot deadlock',
          error: error,
          stackTrace: stackTrace,
          name: 'CameraStationRuntime',
        );
      } catch (error, stackTrace) {
        // iOS grants only a short background execution window. A recorder
        // finalization failure must not prevent the capture session from
        // being released, otherwise the next foreground resume can collide
        // with the old AVCaptureSession and leave a black preview.
        developer.log(
          '[LIFECYCLE] Unable to finalize iOS segment before background',
          error: error,
          stackTrace: stackTrace,
          name: 'CameraStationRuntime',
        );
      }
    } finally {
      try {
        // A foreground event can arrive while iOS is finishing the bounded
        // background task. Never let the stale suspend operation dispose a
        // newly reopened camera.
        if (lifecycleGeneration == _iosLifecycleGeneration &&
            !_iosAppInForeground) {
          try {
            await webRtc.disposeConnection().timeout(
              _iosTransportDisposeTimeout,
            );
          } finally {
            await webRtc.disposeCamera().timeout(_iosTransportDisposeTimeout);
          }
          await _setWakelockSafely(false);
          await _setIosStationActive(false);
          _resetRecordingProgressWatchdog();
          _emitState();
        }
      } on TimeoutException catch (error, stackTrace) {
        developer.log(
          '[LIFECYCLE] Timed out while releasing iOS live transports',
          error: error,
          stackTrace: stackTrace,
          name: 'CameraStationRuntime',
        );
      }
    }
  }

  Future<void> _stopRecordingAtIosBoundary(RecordingService recording) async {
    final recorderSecured = Completer<void>();
    final stopOperation = recording.stop(
      onRecorderStopped: () async {
        if (!recorderSecured.isCompleted) recorderSecured.complete();
      },
    );
    // The source MP4/WAV is already safe when onRecorderStopped fires.
    // Conversion to TS may continue after this method releases the lifecycle
    // queue and must never consume the limited iOS background window.
    unawaited(
      stopOperation.then<void>(
        (_) {
          if (!recorderSecured.isCompleted) recorderSecured.complete();
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!recorderSecured.isCompleted) {
            recorderSecured.completeError(error, stackTrace);
          } else {
            developer.log(
              '[LIFECYCLE] Deferred iOS segment packaging failed',
              error: error,
              stackTrace: stackTrace,
              name: 'CameraStationRuntime',
            );
          }
        },
      ),
    );
    await recorderSecured.future;
  }

  Future<void> resumeFromIosBackground() {
    if (!Platform.isIOS) return Future<void>.value();
    _iosAppInForeground = true;
    if (!_iosLifecycleSuspended || _iosResumeQueued || !_cameraEnabled) {
      return Future<void>.value();
    }
    _iosResumeQueued = true;
    final lifecycleGeneration = ++_iosLifecycleGeneration;
    _emitState();
    return _serializeLifecycle(
          () => _resumeFromIosBackgroundInternal(lifecycleGeneration).timeout(
            _iosForegroundResumeTimeout,
            onTimeout: () {
              // Thao tác treo vẫn chạy nền trong khi hàng đợi được giải phóng
              // và recovery được lên lịch: đổi epoch để nó dừng ở mốc kiểm tra
              // kế tiếp thay vì mở/đóng camera song song (như quá hạn của
              // _serializeLifecycle).
              _lifecycleEpoch++;
              throw TimeoutException(
                'iOS camera resume exceeded '
                '${_iosForegroundResumeTimeout.inSeconds} seconds.',
              );
            },
          ),
        )
        .catchError((Object error, StackTrace stackTrace) {
          developer.log(
            '[LIFECYCLE] Foreground resume operation failed or timed out',
            error: error,
            stackTrace: stackTrace,
            name: 'CameraStationRuntime',
          );
          if (_iosAppInForeground &&
              lifecycleGeneration == _iosLifecycleGeneration) {
            _iosLifecycleSuspended = false;
            _scheduleRecovery('ios_foreground_resume_timeout');
          }
        })
        .whenComplete(() {
          if (lifecycleGeneration == _iosLifecycleGeneration) {
            _iosResumeQueued = false;
          }
          _emitState();
        });
  }

  Future<void> _resumeFromIosBackgroundInternal(int lifecycleGeneration) async {
    if (!Platform.isIOS ||
        !_iosLifecycleSuspended ||
        !_cameraEnabled ||
        !_iosAppInForeground ||
        lifecycleGeneration != _iosLifecycleGeneration) {
      return;
    }
    final webRtc = _webRtcService;
    final server = _cameraServer;
    if (webRtc == null || server == null) return;
    // Quá hạn (recovery đã được giao) thì dừng ở mốc kiểm tra kế tiếp: không
    // mở/đóng camera hay đổi cờ nền iOS nữa.
    final epoch = _lifecycleEpoch;
    if (_thermalCriticalSuspended || _scannerPaused) {
      // Dừng khẩn cấp vì nhiệt: thermal monitor tự mở lại camera khi nguội.
      // Máy quét QR đang giữ camera: chỉ bỏ cờ nền iOS, để
      // resumeCameraAfterScanner mở lại camera (tránh tranh camera).
      await _setWakelockSafely(true);
      await _setIosStationActive(true);
      if (epoch != _lifecycleEpoch) return;
      if (!_iosAppInForeground ||
          lifecycleGeneration != _iosLifecycleGeneration) {
        await _setWakelockSafely(false);
        await _setIosStationActive(false);
        return;
      }
      _iosLifecycleSuspended = false;
      _emitState();
      return;
    }
    try {
      final currentFacing = webRtc.currentFacingMode;
      final lens = _currentLensState(webRtc);
      _preselectLens(webRtc, lens, facingMode: currentFacing);
      await webRtc.initializeCamera(facingMode: currentFacing);
      _throwIfLifecycleStale(epoch, 'ios_resume');
      _recordingService?.setFacingMode(currentFacing);
      if (!_iosAppInForeground ||
          lifecycleGeneration != _iosLifecycleGeneration) {
        await webRtc.disposeCamera();
        return;
      }
      await _restoreLensState(webRtc, lens, context: 'iOS foreground');
      _throwIfLifecycleStale(epoch, 'ios_resume');
      if (!_iosAppInForeground ||
          lifecycleGeneration != _iosLifecycleGeneration) {
        await webRtc.disposeCamera();
        return;
      }
      await webRtc.ensureMicrophoneEnabled();
      await _waitForIosCaptureWarmup();
      _throwIfLifecycleStale(epoch, 'ios_resume');
      if (!_iosAppInForeground ||
          lifecycleGeneration != _iosLifecycleGeneration) {
        await webRtc.disposeCamera();
        return;
      }
      await server.ensureRecording();
      _throwIfLifecycleStale(epoch, 'ios_resume');
      if (!_iosAppInForeground ||
          lifecycleGeneration != _iosLifecycleGeneration) {
        await _recordingService?.stop();
        await webRtc.disposeCamera();
        return;
      }
      await _setWakelockSafely(true);
      await _setIosStationActive(true);
      _throwIfLifecycleStale(epoch, 'ios_resume');
      if (!_iosAppInForeground ||
          lifecycleGeneration != _iosLifecycleGeneration) {
        await _recordingService?.stop();
        await webRtc.disposeCamera();
        await _setWakelockSafely(false);
        await _setIosStationActive(false);
        return;
      }
      _iosLifecycleSuspended = false;
      server.resumeAfterIosBackground();
      _resumeLivePublishers();
      developer.log(
        '[LIFECYCLE] iOS foreground capture resumed',
        name: 'CameraStationRuntime',
      );
    } catch (error, stackTrace) {
      // Đã quá hạn: lần quá hạn đã lên lịch recovery, không lên lịch trùng
      // hay đổi cờ nền iOS của thao tác sau.
      if (error is _StaleLifecycleOperation || epoch != _lifecycleEpoch) {
        developer.log(
          '[LIFECYCLE] Timed-out iOS capture resume stopped',
          error: error,
          stackTrace: stackTrace,
          name: 'CameraStationRuntime',
        );
        return;
      }
      developer.log(
        '[LIFECYCLE] Unable to resume iOS capture; scheduling recovery',
        error: error,
        stackTrace: stackTrace,
        name: 'CameraStationRuntime',
      );
      if (_iosAppInForeground &&
          lifecycleGeneration == _iosLifecycleGeneration) {
        _iosLifecycleSuspended = false;
        _scheduleRecovery('ios_foreground_resume_failed');
      }
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
      throw StationException.fromCode(StationErrorCode.notInitialized);
    }
    if (enabled) {
      if (_thermalCriticalSuspended) {
        // Đang dừng khẩn cấp vì nhiệt: KHÔNG mở camera. Ghi nhận ý định bật để
        // thermal monitor (chỉ chạy khi camera bật) tự mở lại khi máy nguội,
        // rồi báo cho người dùng biết camera chưa mở.
        _cameraEnabled = true;
        _thermalNormalSince = null;
        _emitState();
        throw StationException.fromCode(StationErrorCode.thermalSuspended);
      }
      if (_iosLifecycleSuspended && _iosAppInForeground) {
        // Cờ nền iOS còn sót (camera bị tắt khi app ở nền nên lần trở lại
        // foreground đã bỏ qua): app đang ở foreground nên được mở camera.
        _iosLifecycleSuspended = false;
        server.resumeAfterIosBackground();
      }
      final blocked = _cameraOpenBlockedError();
      if (blocked != null) throw blocked;
    }

    _cameraEnabled = enabled;
    _generation++;
    _recovering = false;
    _emitState();

    if (!enabled) {
      final wasRtspPublishing = _rtspPublisherService.isLive ||
          _rtspPublisherService.state == RtspPublishState.connecting ||
          _rtspPublisherService.state == RtspPublishState.reconnecting;
      final wasWhipPublishing = _whipPublisherService.isLive ||
          _whipPublisherService.state == WhipPublishState.connecting ||
          _whipPublisherService.state == WhipPublishState.reconnecting;
      _wasRtspBeforeCameraDisable = wasRtspPublishing;
      _wasWhipBeforeCameraDisable = wasWhipPublishing;

      if (wasRtspPublishing) {
        await _rtspPublisherService.prepareForReconfiguration();
      }
      if (wasWhipPublishing) {
        await _whipPublisherService.prepareForReconfiguration();
      }

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

      await _setWakelockSafely(false);
      await _setIosStationActive(false);
      developer.log('[CAMERA] Disabled by user', name: 'CameraStationRuntime');
      _emitState();
      return;
    }

    final epoch = _lifecycleEpoch;
    try {
      final currentFacing = webRtc.currentFacingMode;
      final lens = _currentLensState(webRtc);
      _preselectLens(webRtc, lens, facingMode: currentFacing);
      await webRtc.initializeCamera(facingMode: currentFacing);
      _throwIfLifecycleStale(epoch, 'camera_enable');
      recording.setFacingMode(currentFacing);
      await _restoreLensState(webRtc, lens, context: 'camera enable');
      await _waitForIosCaptureWarmup();
      _throwIfLifecycleStale(epoch, 'camera_enable');
      await server.ensureRecording();
      await _setWakelockSafely(true);
      await _setIosStationActive(true);

      if (_wasRtspBeforeCameraDisable) {
        _wasRtspBeforeCameraDisable = false;
        unawaited(_rtspPublisherService.restartIfPublishing());
      }
      if (_wasWhipBeforeCameraDisable) {
        _wasWhipBeforeCameraDisable = false;
        unawaited(_whipPublisherService.restartIfPublishing());
      }

      developer.log('[CAMERA] Enabled by user', name: 'CameraStationRuntime');
    } catch (error) {
      // Đã quá hạn: recovery của lần quá hạn đang lo camera, không tắt cờ
      // camera hay đóng camera của thao tác sau.
      if (error is _StaleLifecycleOperation || epoch != _lifecycleEpoch) {
        rethrow;
      }
      _cameraEnabled = false;
      // Lỗi dọn camera không được che lỗi mở camera gốc.
      try {
        await webRtc.disposeCamera();
      } catch (disposeError) {
        developer.log(
          '[CAMERA] Unable to release camera after failed enable: $disposeError',
          name: 'CameraStationRuntime',
        );
      }
      rethrow;
    } finally {
      _emitState();
    }
  }

  Future<void> switchCamera() {
    final current = _lensSwitchOperation;
    if (current != null) return current;
    // Camera tắt / bị chặn: thao tác sẽ bị từ chối, không huỷ recovery.
    _interruptRecoveryForReconfiguration(changesConfiguration: true);
    final operation = _serializeLifecycle(
      _switchCameraInternal,
      timeout: _reconfigureOperationTimeout,
      label: 'camera_switch',
      recoverOnTimeout: true,
    );
    _lensSwitchOperation = operation;
    return operation.whenComplete(() {
      if (identical(_lensSwitchOperation, operation)) {
        _lensSwitchOperation = null;
      }
    });
  }

  Future<void> switchToLensMode(String mode) {
    final current = _lensSwitchOperation;
    if (current != null) return current;
    // Camera tắt / bị chặn: thao tác sẽ bị từ chối, không huỷ recovery.
    _interruptRecoveryForReconfiguration(changesConfiguration: true);
    final operation = _serializeLifecycle(() async {
      if (!_cameraEnabled) {
        throw StationException.fromCode(StationErrorCode.cameraDisabled);
      }
      final blocked = _cameraOpenBlockedError();
      if (blocked != null) throw blocked;
      final webRtc = _webRtcService;
      if (webRtc == null) {
        throw StationException.fromCode(StationErrorCode.cameraNotReady);
      }
      await webRtc.switchToLensMode(mode);
      // Persist lens state để restore khi đổi resolution hoặc restart app
      final isUltraWide = webRtc.isCurrentUltraWide;
      final zoom = webRtc.cameraZoom;
      unawaited(StationConfigService().saveCameraLensState(
        isUltraWide: isUltraWide,
        zoom: zoom,
        deviceId: isUltraWide ? webRtc.ultraWideCamera?.id : webRtc.mainBackCamera?.id,
      ));
      _emitState();
    }, timeout: _reconfigureOperationTimeout, label: 'lens_switch');
    _lensSwitchOperation = operation;
    return operation.whenComplete(() {
      if (identical(_lensSwitchOperation, operation)) {
        _lensSwitchOperation = null;
      }
    });
  }

  /// Set zoom camera và tự động persist lens state để restore sau khi đổi
  /// resolution hoặc khởi động lại app.
  ///
  /// Không đi qua hàng đợi vòng đời (zoom không bị trễ), nên bị bỏ qua khi
  /// camera đang khởi tạo / đổi ống kính / đổi độ phân giải / khôi phục, và
  /// không lưu trạng thái ống kính nếu cấu hình đổi trong lúc đang zoom.
  Future<void> setCameraZoom(double zoom) async {
    final webRtc = _webRtcService;
    if (webRtc == null || !_cameraZoomAllowedNow) {
      developer.log(
        '[CAMERA] Ignoring zoom while the camera is not ready or is being '
        'reconfigured',
        name: 'CameraStationRuntime',
      );
      return;
    }
    final generation = _generation;
    final epoch = _lifecycleEpoch;
    try {
      await webRtc.setCameraZoom(zoom);
      // Ống kính/độ phân giải bắt đầu đổi (hoặc camera được mở lại) trong lúc
      // zoom: trạng thái ống kính lúc này là dở dang, không lưu.
      if (generation != _generation ||
          epoch != _lifecycleEpoch ||
          !identical(webRtc, _webRtcService) ||
          !_cameraZoomAllowedNow) {
        return;
      }
      final isUltraWide = webRtc.isCurrentUltraWide;
      final actualZoom = webRtc.cameraZoom;
      unawaited(StationConfigService().saveCameraLensState(
        isUltraWide: isUltraWide,
        zoom: actualZoom,
        deviceId: isUltraWide
            ? webRtc.ultraWideCamera?.id
            : webRtc.mainBackCamera?.id,
      ));
    } catch (e) {
      developer.log('[CAMERA] setCameraZoom error: $e', name: 'CameraStationRuntime');
    }
  }

  bool get _cameraZoomAllowedNow => cameraZoomAllowed(
    cameraEnabled: _cameraEnabled,
    initialized: _initCompleted,
    stopping: _stopping,
    profileSwitching: _profileSwitching,
    lensSwitching: _lensSwitchOperation != null,
    recovering: _recovering,
    openBlocked: _cameraOpenBlockedError() != null || _iosResumeQueued,
    lifecycleBusy: _lifecycleOperationsPending > 0,
  );

  Future<void> _switchCameraInternal() async {
    // Quá hạn (hàng đợi đã giao cho recovery/thao tác khác) thì dừng ở mốc
    // kiểm tra kế tiếp: không mở/đóng camera, không rollback.
    final epoch = _lifecycleEpoch;
    if (!_cameraEnabled) {
      throw StationException.fromCode(StationErrorCode.cameraDisabled);
    }
    if (_profileSwitching) {
      throw StationException.fromCode(StationErrorCode.cameraBusy);
    }
    final blocked = _cameraOpenBlockedError();
    if (blocked != null) throw blocked;
    final webRtc = _webRtcService;
    final recording = _recordingService;
    final server = _cameraServer;
    if (webRtc == null || recording == null || server == null) {
      throw StationException.fromCode(StationErrorCode.notInitialized);
    }

    final wasRtspPublishing = _rtspPublisherService.isLive;
    final wasWhipPublishing = _whipPublisherService.isLive;
    final previousFacing = webRtc.currentFacingMode;
    final targetFacing =
        previousFacing == 'environment' ? 'user' : 'environment';

    var targetProfiles = await webRtc.getSupportedResolutionProfiles(
      facingMode: targetFacing,
      fallbackWhenUnavailable: false,
    );
    // On iOS AVCaptureDevice discovery can temporarily return an empty list
    // while the current capture session owns the camera. That is not proof
    // that the opposite lens does not exist. Let flutter_webrtc perform the
    // real lens switch and refresh capabilities after the new lens is active.
    // Android recreates the capture stream, so it still needs a verified
    // target profile before stopping the current recorder.
    if (targetProfiles.isEmpty && !Platform.isIOS) {
      throw StationException(
        StationErrorCode.noCameraAvailable,
        messageVi: 'Thiết bị không có camera $targetFacing khả dụng.',
        messageEn: 'No $targetFacing camera is available on this device.',
      );
    }

    final previousProfile = _resolutionProfile;
    final previousProfiles = _supportedResolutionProfiles;
    // When iOS capability discovery is temporarily unavailable, use 720p as
    // a universally conservative capture profile. If the active profile is
    // already 720p the existing track can switch in place; otherwise the
    // target lens is reopened explicitly instead of asking it to inherit an
    // unsupported 2K/4K constraint from the previous lens.
    var selectedProfile = targetProfiles.isEmpty && Platform.isIOS
        ? CameraResolutionProfile.hd720
        : previousProfile;
    if (targetProfiles.isNotEmpty) {
      selectedProfile = targetProfiles.firstWhere(
        (profile) => profile.preset == previousProfile.preset,
        orElse: () => targetProfiles.last,
      );
    }

    if (wasRtspPublishing) {
      await _rtspPublisherService.prepareForReconfiguration();
    }
    if (wasWhipPublishing) {
      await _whipPublisherService.prepareForReconfiguration();
    }
    // Quá hạn trước khi đặt cờ: _recoverAfterLifecycleTimeout đã bỏ cờ, không
    // được đặt lại (finally bên dưới sẽ không bỏ cờ của thao tác quá hạn).
    _throwIfLifecycleStale(epoch, 'camera_switch');
    _profileSwitching = true;
    _generation++;
    _emitState();
    try {
      if (Platform.isIOS) {
        final recreateCapture = shouldRecreateIosCameraForLensSwitch(
          previousProfile,
          selectedProfile,
        );
        if (!recreateCapture) {
          // flutter_webrtc switches the capturer behind the existing
          // MediaStreamTrack, so WebRTC peers and RTSP keep the same track.
          // The recording is cut at the switch so each segment has a single
          // camera orientation; only the hand-off is awaited, FFmpeg remuxes
          // the previous segment in the background (no UI spinner).
          try {
            await _switchIosLensInPlace(webRtc, recording);
            _throwIfLifecycleStale(epoch, 'camera_switch');
            if (!recording.recording) await server.ensureRecording();
            _throwIfLifecycleStale(epoch, 'camera_switch');
          } catch (error, stackTrace) {
            if (error is _StaleLifecycleOperation ||
                epoch != _lifecycleEpoch) {
              rethrow;
            }
            // Some iOS devices report a successful native lens handoff before
            // the new AVCaptureSession produces its first frame. Reopen the
            // requested facing explicitly so one tap is sufficient instead
            // of rolling back and forcing the operator to tap repeatedly.
            developer.log(
              '[CAMERA] In-place iOS lens switch failed; reopening target lens',
              error: error,
              stackTrace: stackTrace,
              name: 'CameraStationRuntime',
            );
            await recording.stop();
            _throwIfLifecycleStale(epoch, 'camera_switch');
            // Giữ kết nối WebRTC của Tablet, chỉ dispose camera để switch track
            await webRtc.disposeCamera();
            _throwIfLifecycleStale(epoch, 'camera_switch');
            webRtc.setResolutionProfile(selectedProfile);
            await webRtc.initializeCamera(facingMode: targetFacing);
            _throwIfLifecycleStale(epoch, 'camera_switch');
            recording.setFacingMode(targetFacing);
            await _waitForIosCaptureWarmup(profile: selectedProfile);
            _throwIfLifecycleStale(epoch, 'camera_switch');
            await server.ensureRecording();
            _throwIfLifecycleStale(epoch, 'camera_switch');
          }
        } else {
          // Helper.switchCamera keeps the constraints of the previous lens.
          // Recreate capture when the target lens needs a lower profile (for
          // example a 4K rear camera switching to a 1080p front camera).
          await recording.stop();
          _throwIfLifecycleStale(epoch, 'camera_switch');
          // Giữ kết nối WebRTC của Tablet
          await webRtc.disposeCamera();
          _throwIfLifecycleStale(epoch, 'camera_switch');
          webRtc.setResolutionProfile(selectedProfile);
          await webRtc.initializeCamera(facingMode: targetFacing);
          _throwIfLifecycleStale(epoch, 'camera_switch');
          recording.setFacingMode(targetFacing);
          await _waitForIosCaptureWarmup(profile: selectedProfile);
          _throwIfLifecycleStale(epoch, 'camera_switch');
          await server.ensureRecording();
          _throwIfLifecycleStale(epoch, 'camera_switch');
        }
        if (targetProfiles.isEmpty) {
          final refreshed = await webRtc.getSupportedResolutionProfiles(
            facingMode: targetFacing,
            fallbackWhenUnavailable: false,
          );
          _throwIfLifecycleStale(epoch, 'camera_switch');
          targetProfiles = refreshed.isEmpty
              ? <CameraResolutionProfile>[selectedProfile]
              : refreshed;
        }
        _supportedResolutionProfiles = targetProfiles.isEmpty
            ? previousProfiles
            : targetProfiles;
        _resolutionProfile = selectedProfile;
        webRtc.setResolutionProfile(selectedProfile);
        if (selectedProfile != previousProfile) {
          await StationConfigService().saveResolutionProfile(selectedProfile);
        }
        if (wasRtspPublishing) {
          unawaited(_rtspPublisherService.restartIfPublishing());
        }
        if (wasWhipPublishing) {
          unawaited(_whipPublisherService.restartIfPublishing());
        }
        developer.log(
          '[CAMERA] Switched iOS lens with a compatible capture profile',
          name: 'CameraStationRuntime',
        );
        return;
      }
      await recording.stop();
      _throwIfLifecycleStale(epoch, 'camera_switch');
      // Giữ kết nối WebRTC của Tablet
      await webRtc.disposeCamera();
      _throwIfLifecycleStale(epoch, 'camera_switch');
      webRtc.setResolutionProfile(selectedProfile);
      await webRtc.initializeCamera(facingMode: targetFacing);
      _throwIfLifecycleStale(epoch, 'camera_switch');
      recording.setFacingMode(targetFacing);
      await server.ensureRecording();
      _throwIfLifecycleStale(epoch, 'camera_switch');

      _supportedResolutionProfiles = targetProfiles;
      _resolutionProfile = selectedProfile;
      if (selectedProfile != previousProfile) {
        await StationConfigService().saveResolutionProfile(selectedProfile);
      }
      if (wasRtspPublishing) {
        unawaited(_rtspPublisherService.restartIfPublishing());
      }
      if (wasWhipPublishing) {
        unawaited(_whipPublisherService.restartIfPublishing());
      }
      developer.log(
        '[CAMERA] Switched to $targetFacing at '
        '${selectedProfile.shortLabel} ${selectedProfile.fps} FPS',
        name: 'CameraStationRuntime',
      );
    } catch (error) {
      if (error is _StaleLifecycleOperation || epoch != _lifecycleEpoch) {
        developer.log(
          '[CAMERA] Timed-out lens switch stopped without rollback',
          name: 'CameraStationRuntime',
        );
        rethrow;
      }
      _supportedResolutionProfiles = previousProfiles;
      _resolutionProfile = previousProfile;
      webRtc.setResolutionProfile(previousProfile);
      try {
        // The iOS handoff may already have opened a new recorder on the old
        // VideoTrack before the lens switch error is reported. Finalize that
        // recorder before disposing the track, otherwise its state remains
        // `recording` while no camera frames can reach it.
        await recording.stop();
        _throwIfLifecycleStale(epoch, 'camera_switch_rollback');
        await webRtc.disposeCamera();
        _throwIfLifecycleStale(epoch, 'camera_switch_rollback');
        await webRtc.initializeCamera(facingMode: previousFacing);
        _throwIfLifecycleStale(epoch, 'camera_switch_rollback');
        recording.setFacingMode(previousFacing);
        await _waitForIosCaptureWarmup(profile: previousProfile);
        _throwIfLifecycleStale(epoch, 'camera_switch_rollback');
        await server.ensureRecording();
        // Quá hạn trong lúc mở lại ghi hình: không bật lại publisher thay cho
        // thao tác sau (nó tự quyết định phát lại).
        _throwIfLifecycleStale(epoch, 'camera_switch_rollback');
        if (wasRtspPublishing || wasWhipPublishing) _resumeLivePublishers();
      } catch (rollbackError, stackTrace) {
        // Không còn camera để tráo track: đóng peer để Tablet tự kết nối lại
        // thay vì giữ một kết nối "connected" đứng hình. Rollback dừng vì quá
        // hạn thì không đóng kết nối của thao tác sau.
        if (rollbackError is! _StaleLifecycleOperation) {
          await _releasePeersAfterFailedCameraRestore(webRtc);
        }
        developer.log(
          '[CAMERA] Lens switch rollback failed',
          error: rollbackError,
          stackTrace: stackTrace,
          name: 'CameraStationRuntime',
        );
      }
      rethrow;
    } finally {
      // Quá hạn thì _recoverAfterLifecycleTimeout đã bỏ cờ; không bỏ cờ của
      // thao tác đổi cấu hình mới hơn.
      if (epoch == _lifecycleEpoch) _profileSwitching = false;
      _emitState();
    }
  }

  /// Đổi camera iOS tại chỗ đúng ranh giới segment: đoạn cũ giữ hướng camera
  /// cũ, đoạn mới bắt đầu sau khi đổi. Chỉ chờ tới lúc đổi xong, không chờ
  /// FFmpeg đóng gói đoạn cũ.
  Future<void> _switchIosLensInPlace(
    WebRtcService webRtc,
    RecordingService recording,
  ) async {
    var switched = false;
    Future<void> doSwitch() async {
      await webRtc.switchCamera();
      recording.setFacingMode(webRtc.currentFacingMode);
      switched = true;
    }

    if (!recording.recording) {
      await doSwitch();
      return;
    }
    final handedOff = Completer<void>();
    unawaited(
      recording
          .rotateSegmentForSourceChange(
            onRecorderStopped: () async {
              try {
                await doSwitch();
                if (!handedOff.isCompleted) handedOff.complete();
              } catch (error, stackTrace) {
                if (!handedOff.isCompleted) {
                  handedOff.completeError(error, stackTrace);
                }
                rethrow;
              }
            },
          )
          .then<void>(
            (_) {
              // Không có đoạn nào để cắt (recorder chưa mở): đổi trực tiếp.
              if (!handedOff.isCompleted) handedOff.complete();
            },
            onError: (Object error, StackTrace stackTrace) {
              if (!handedOff.isCompleted) {
                handedOff.completeError(error, stackTrace);
              }
              developer.log(
                '[CAMERA] Segment cut around iOS lens switch failed',
                error: error,
                stackTrace: stackTrace,
                name: 'CameraStationRuntime',
              );
            },
          ),
    );
    await handedOff.future;
    if (!switched) await doSwitch();
  }

  Future<void> setResolutionProfile(
    CameraResolutionProfile profile, {
    bool ignoreLock = false,
    bool userInitiated = true,
  }) {
    // Kiểm tra hợp lệ TRƯỚC khi đụng tới trạng thái nhiệt: lựa chọn bị từ
    // chối không được xoá cờ hạ nhiệt hay profile mục tiêu.
    if (_resolutionLocked && !ignoreLock) {
      return Future<void>.error(
        StationException.fromCode(StationErrorCode.resolutionLocked),
      );
    }
    if (resolveSupportedResolutionProfile(
          _supportedResolutionProfiles,
          profile,
        ) ==
        null) {
      return Future<void>.error(_unsupportedProfileError(profile));
    }
    final blocked = _cameraOpenBlockedError();
    if (blocked != null) return Future<void>.error(blocked);
    if (!_cameraEnabled) {
      return Future<void>.error(
        StationException.fromCode(StationErrorCode.cameraDisabled),
      );
    }
    if (userInitiated && _thermalCriticalDegraded) {
      // Máy đang critical (đã giảm tải): ghi nhận lựa chọn làm profile mục
      // tiêu để khôi phục khi máy nguội, nhưng KHÔNG mở camera ở cấu hình
      // nặng hơn (lần kiểm tra nhiệt kế tiếp sẽ lại hạ = mở lại camera 2 lần).
      _profileBeforeThermalThrottle = profile;
      _thermalThrottled = true;
      _thermalCooledDownSince = null;
      _thermalAutoRestoreBlocked = false;
      _lastThermalRestoreAt = null;
      if (resolutionProfileLoad(profile) >
          resolutionProfileLoad(_resolutionProfile)) {
        developer.log(
          '[THERMAL] Máy đang critical; ghi nhận ${profile.shortLabel} '
          '(${profile.fps} FPS) để khôi phục khi máy nguội',
          name: 'CameraStationRuntime',
        );
        unawaited(
          StationConfigService().saveResolutionProfile(profile).catchError((
            Object error,
          ) {
            developer.log(
              '[THERMAL] Unable to save deferred resolution profile: $error',
              name: 'CameraStationRuntime',
            );
          }),
        );
        _emitState();
        return Future<void>.value();
      }
      // Cấu hình nhẹ hơn cấu hình hiện tại: áp dụng ngay (giảm tải thêm).
      _interruptRecoveryForReconfiguration(
        changesConfiguration: profile != _resolutionProfile,
      );
      return _serializeLifecycle(
        () => _setResolutionProfileInternal(profile),
        timeout: _reconfigureOperationTimeout,
        label: 'resolution',
        recoverOnTimeout: true,
      );
    }
    // Khách hàng có toàn quyền lựa chọn độ phân giải theo ý muốn.
    // Nếu máy đang nóng hoặc đang có hẹn giờ hạ độ phân giải, ghi nhận quyền
    // ưu tiên của khách hàng (user override) và hủy lệnh tự động ép về 720p.
    if (userInitiated) {
      if (_thermalThrottled ||
          _pendingThermalThrottleTimer != null ||
          thermalWarning) {
        _thermalUserOverride = true;
        _thermalThrottled = false;
        _pendingThermalThrottleTimer?.cancel();
        _pendingThermalThrottleTimer = null;
        _pendingThermalTarget = null;
        _pendingThermalAt = null;
        _profileBeforeThermalThrottle = profile;
        developer.log(
          '[THERMAL] Khách hàng chủ động chọn ${profile.shortLabel} (${profile.fps} FPS) '
          'khi thiết bị ấm; kích hoạt user override',
          name: 'CameraStationRuntime',
        );
      }
      _thermalCooledDownSince = null;
      // Người dùng tự chọn: cho phép tự khôi phục lại ở các lần nóng sau.
      _thermalAutoRestoreBlocked = false;
      _lastThermalRestoreAt = null;
    }
    // Cùng cấu hình: thao tác không mở lại camera nên không được huỷ recovery
    // đang chạy (camera đang đóng sẽ bị bỏ đóng).
    _interruptRecoveryForReconfiguration(
      changesConfiguration: profile != _resolutionProfile,
    );
    return _serializeLifecycle(
      () => _setResolutionProfileInternal(profile),
      timeout: _reconfigureOperationTimeout,
      label: 'resolution',
      recoverOnTimeout: true,
    );
  }

  StationException _unsupportedProfileError(CameraResolutionProfile profile) {
    return StationException(
      StationErrorCode.resolutionUnsupported,
      messageVi: 'Thiết bị không hỗ trợ ${profile.shortLabel}.',
      messageEn: 'This device does not support ${profile.shortLabel}.',
    );
  }

  /// Lỗi nếu lúc này không được mở/mở lại camera (null = được phép).
  StationException? _cameraOpenBlockedError() {
    final code = cameraOpenBlockReason(
      thermalSuspended: _thermalCriticalSuspended,
      iosSuspended: _iosLifecycleSuspended,
      scannerActive: _scannerPaused,
    );
    return code == null ? null : StationException.fromCode(code);
  }

  Future<void> _setResolutionProfileInternal(
    CameraResolutionProfile profile, {
    bool persistSelection = true,
  }) async {
    if (_profileSwitching || profile == _resolutionProfile) {
      return;
    }
    // Kiểm tra trước khi đụng tới camera/trạng thái: dừng khẩn cấp vì nhiệt,
    // iOS ở nền hoặc máy quét QR đang giữ camera thì không được mở camera.
    final blocked = _cameraOpenBlockedError();
    if (blocked != null) throw blocked;
    var selected = resolveSupportedResolutionProfile(
      _supportedResolutionProfiles,
      profile,
    );
    if (selected == null) {
      throw _unsupportedProfileError(profile);
    }
    final webRtc = _webRtcService;
    final recording = _recordingService;
    final server = _cameraServer;
    if (!_cameraEnabled) {
      throw StationException.fromCode(StationErrorCode.cameraDisabled);
    }
    if (webRtc == null || recording == null || server == null) {
      throw StationException.fromCode(StationErrorCode.cameraNotReady);
    }

    final lens = _currentLensState(webRtc);
    // Camera góc rộng (Ultra-Wide) phần cứng trên iPhone chỉ hỗ trợ tối đa 30 FPS.
    // Giới hạn ở 30 FPS để tránh ngoại lệ phần cứng AVFoundation làm thoát app.
    if (lens.isUltraWide && Platform.isIOS && selected.fps > 30) {
      selected = selected.withFps(30);
      developer.log(
        '[CAMERA] Capping iOS ultra-wide to 30 FPS to prevent hardware exception',
        name: 'CameraStationRuntime',
      );
    }

    final previous = _resolutionProfile;
    final currentFacing = webRtc.currentFacingMode;
    final wasRtspPublishing = _rtspPublisherService.isLive;
    final wasWhipPublishing = _whipPublisherService.isLive;
    if (wasRtspPublishing) {
      await _rtspPublisherService.prepareForReconfiguration();
    }
    if (wasWhipPublishing) {
      await _whipPublisherService.prepareForReconfiguration();
    }
    _profileSwitching = true;
    _generation++;
    // Quá hạn (hàng đợi đã giao cho recovery/thao tác khác) thì dừng ở mốc
    // kiểm tra kế tiếp: không mở camera, không rollback.
    final epoch = _lifecycleEpoch;
    _emitState();
    try {
      await recording.stop();
      // Giữ kết nối WebRTC của Tablet, chỉ dispose camera để switch resolution
      await webRtc.disposeCamera();
      if (Platform.isIOS) {
        // Cho AVFoundation đủ thời gian giải phóng hoàn toàn AVCaptureSession cũ
        // trước khi tạo session mới ở độ phân giải cao hơn, tránh xung đột phần cứng.
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      _throwIfLifecycleStale(epoch, 'resolution');

      // Nếu đang ở ultra-wide mode, ghi nhớ preferred device ID để
      // initializeCamera mở đúng lens ngay từ đầu (không cần switch sau init).
      _preselectLens(webRtc, lens, facingMode: currentFacing, profile: selected);

      webRtc.setResolutionProfile(selected);
      await webRtc.initializeCamera(facingMode: currentFacing);
      _throwIfLifecycleStale(epoch, 'resolution');
      recording.setFacingMode(currentFacing);

      // Khôi phục lại góc quay / zoom TRƯỚC KHI bắt đầu ghi hình.
      // Cấu hình hoàn tất phần cứng camera để pipeline video ổn định,
      // tránh làm gián đoạn AVAssetWriter / MediaRecorder dẫn đến crash app.
      await _restoreLensState(
        webRtc,
        lens,
        context: 'resolution change',
        profile: selected,
        persist: true,
      );

      await _waitForIosCaptureWarmup(profile: selected);
      _throwIfLifecycleStale(epoch, 'resolution');
      await server.ensureRecording();
      _throwIfLifecycleStale(epoch, 'resolution');
      _resolutionProfile = selected;

      if (persistSelection) {
        await StationConfigService().saveResolutionProfile(selected);
      }
      if (wasRtspPublishing) {
        unawaited(_rtspPublisherService.restartIfPublishing());
      }
      if (wasWhipPublishing) {
        unawaited(_whipPublisherService.restartIfPublishing());
      }
      try {
        server.updateDiscoveryStatus(
          recording.recording ? 'RECORDING' : 'READY',
        );
      } catch (e) {
        developer.log(
          '[CAMERA] Updating discovery status failed: $e',
          name: 'CameraStationRuntime',
        );
      }
      developer.log(
        '[CAMERA] Resolution changed to ${selected.shortLabel} '
        '${selected.fps} FPS ($currentFacing)',
        name: 'CameraStationRuntime',
      );
    } catch (error) {
      if (error is _StaleLifecycleOperation || epoch != _lifecycleEpoch) {
        developer.log(
          '[CAMERA] Timed-out resolution change stopped without rollback',
          name: 'CameraStationRuntime',
        );
        rethrow;
      }
      webRtc.setResolutionProfile(previous);
      try {
        await webRtc.disposeCamera();
        if (Platform.isIOS) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        _throwIfLifecycleStale(epoch, 'resolution_rollback');
        _preselectLens(
          webRtc,
          lens,
          facingMode: currentFacing,
          profile: previous,
        );
        await webRtc.initializeCamera(facingMode: currentFacing);
        recording.setFacingMode(currentFacing);
        await _restoreLensState(
          webRtc,
          lens,
          context: 'resolution rollback',
          profile: previous,
        );
        await _waitForIosCaptureWarmup(profile: previous);
        _throwIfLifecycleStale(epoch, 'resolution_rollback');
        await server.ensureRecording();
        if (wasRtspPublishing) {
          unawaited(_rtspPublisherService.restartIfPublishing());
        }
        if (wasWhipPublishing) {
          unawaited(_whipPublisherService.restartIfPublishing());
        }
      } catch (rollbackError, stackTrace) {
        // Rollback dừng vì quá hạn: không đóng kết nối của thao tác sau.
        if (rollbackError is! _StaleLifecycleOperation) {
          await _releasePeersAfterFailedCameraRestore(webRtc);
        }
        developer.log(
          '[CAMERA] Resolution rollback failed',
          error: rollbackError,
          stackTrace: stackTrace,
          name: 'CameraStationRuntime',
        );
      }
      rethrow;
    } finally {
      // Quá hạn thì _recoverAfterLifecycleTimeout đã bỏ cờ; không bỏ cờ của
      // thao tác đổi cấu hình mới hơn.
      if (epoch == _lifecycleEpoch) _profileSwitching = false;
      _emitState();
    }
  }

  Future<void> _releasePeersAfterFailedCameraRestore(WebRtcService webRtc) async {
    try {
      await webRtc.disposeConnection();
    } catch (error) {
      developer.log(
        '[CAMERA] Unable to release WebRTC peers after failed restore: $error',
        name: 'CameraStationRuntime',
      );
    }
  }

  /// Lens/zoom đang dùng (giá trị vẫn giữ sau disposeCamera), để mở lại đúng
  /// góc quay sau khi camera bị đóng.
  _LensState _currentLensState(WebRtcService webRtc) {
    final ultraWide = webRtc.isCurrentUltraWide;
    return (
      isUltraWide: ultraWide,
      zoom: webRtc.cameraZoom,
      deviceId: ultraWide ? webRtc.ultraWideCamera?.id : null,
    );
  }

  /// Lens/zoom đã lưu (đổi lens, zoom, đổi độ phân giải). Lỗi đọc → null.
  Future<_LensState?> _loadSavedLensState() async {
    try {
      return await StationConfigService().loadCameraLensState();
    } catch (error) {
      developer.log(
        '[CAMERA] Unable to load saved lens state: $error',
        name: 'CameraStationRuntime',
      );
      return null;
    }
  }

  /// Camera góc rộng (Ultra-Wide) phần cứng trên iPhone chỉ hỗ trợ tối đa
  /// 30 FPS: không tự mở ultra-wide ở cấu hình cao hơn.
  bool _ultraWideAllowedFor(CameraResolutionProfile profile) =>
      !Platform.isIOS || profile.fps <= 30;

  /// Trước initializeCamera: chọn sẵn thiết bị ultra-wide để camera mở đúng
  /// lens ngay từ đầu (không cần đổi lens sau khi mở).
  void _preselectLens(
    WebRtcService webRtc,
    _LensState? lens, {
    required String facingMode,
    CameraResolutionProfile? profile,
  }) {
    if (lens == null || !lens.isUltraWide || facingMode != 'environment') {
      return;
    }
    if (!_ultraWideAllowedFor(profile ?? _resolutionProfile)) return;
    final deviceId = lens.deviceId ?? webRtc.ultraWideCamera?.id;
    if (deviceId == null) return;
    webRtc.setPreferredCameraDevice('environment', deviceId);
    developer.log(
      '[CAMERA] Pre-setting ultra-wide device=$deviceId before opening camera',
      name: 'CameraStationRuntime',
    );
  }

  /// Khôi phục lens (ultra-wide) và zoom ngay sau khi camera vừa được mở lại,
  /// TRƯỚC khi bắt đầu ghi để pipeline video ổn định. Dùng chung cho mọi
  /// đường mở lại camera (khởi động, đổi độ phân giải, máy quét QR, recovery,
  /// hồi nhiệt, iOS trở lại foreground). Lỗi chỉ ghi log, không chặn ghi hình.
  /// [persist]: lưu lại trạng thái lens (đổi độ phân giải do người dùng chọn).
  Future<void> _restoreLensState(
    WebRtcService webRtc,
    _LensState? lens, {
    required String context,
    CameraResolutionProfile? profile,
    bool persist = false,
  }) async {
    if (lens == null) return;
    if (webRtc.currentFacingMode != 'environment') {
      if (persist) unawaited(StationConfigService().clearCameraLensState());
      return;
    }
    if (lens.isUltraWide && _ultraWideAllowedFor(profile ?? _resolutionProfile)) {
      try {
        if (!webRtc.isCurrentUltraWide) {
          await webRtc.switchToLensMode('ultra_wide');
        }
        final targetRatio = webRtc.ultraWideZoomRatio;
        await webRtc.setCameraZoom(targetRatio);
        if (persist) {
          unawaited(
            StationConfigService().saveCameraLensState(
              isUltraWide: true,
              zoom: targetRatio,
              deviceId: webRtc.ultraWideCamera?.id,
            ),
          );
        }
        developer.log(
          '[CAMERA] Restored ultra-wide lens ($targetRatio) after $context',
          name: 'CameraStationRuntime',
        );
      } catch (error) {
        developer.log(
          '[CAMERA] Unable to restore ultra-wide lens after $context: $error',
          name: 'CameraStationRuntime',
        );
      }
    } else if (lens.zoom > 1.05) {
      try {
        await webRtc.setCameraZoom(lens.zoom);
        if (persist) {
          unawaited(
            StationConfigService().saveCameraLensState(
              isUltraWide: false,
              zoom: lens.zoom,
            ),
          );
        }
        developer.log(
          '[CAMERA] Restored zoom (${lens.zoom}) after $context',
          name: 'CameraStationRuntime',
        );
      } catch (error) {
        developer.log(
          '[CAMERA] Unable to restore zoom after $context: $error',
          name: 'CameraStationRuntime',
        );
      }
    } else if (persist) {
      // Reset về 1x, clear persisted lens state
      unawaited(StationConfigService().clearCameraLensState());
    }
  }

  _LensState? _scannerSavedLens;
  String _scannerSavedFacing = 'environment';

  /// Tạm thời giải phóng camera phần cứng để các tính năng quét QR bên ngoài
  /// (MobileScanner / CameraX) có thể sử dụng mà không xung đột tài nguyên độc quyền.
  Future<void> pauseCameraForScanner() {
    _interruptRecovery();
    return _serializeLifecycle(
      _pauseCameraForScannerInternal,
      // Dừng ghi (chốt segment cuối bằng FFmpeg) như stop(): cùng hạn 90 giây.
      timeout: _stopOperationTimeout,
      label: 'scanner_pause',
    );
  }

  Future<void> _pauseCameraForScannerInternal() async {
    final webRtc = _webRtcService;
    final recording = _recordingService;
    if (webRtc == null || !_cameraEnabled || _scannerPaused) return;

    developer.log(
      '[RUNTIME] Pausing station camera for external QR scanner...',
      name: 'CameraStationRuntime',
    );
    _scannerPaused = true;
    _resetRecordingProgressWatchdog();
    _emitState();
    try {
      _scannerSavedLens = _currentLensState(webRtc);
      _scannerSavedFacing = webRtc.currentFacingMode;

      await _pauseLivePublishers();
      if (recording != null) {
        await recording.stop();
      }
      await webRtc.disposeConnection();
      await webRtc.disposeCamera();
    } catch (e) {
      developer.log(
        '[RUNTIME] Error pausing camera for scanner: $e',
        name: 'CameraStationRuntime',
      );
    }
    _emitState();
  }

  /// Khôi phục camera của trạm sau khi quét mã QR hoàn tất.
  Future<void> resumeCameraAfterScanner() {
    _interruptRecovery();
    return _serializeLifecycle(
      _resumeCameraAfterScannerInternal,
      label: 'scanner_resume',
      recoverOnTimeout: true,
    );
  }

  Future<void> _resumeCameraAfterScannerInternal() async {
    if (!_scannerPaused) return;
    _scannerPaused = false;
    final webRtc = _webRtcService;
    final recording = _recordingService;
    final server = _cameraServer;
    if (webRtc == null || !_cameraEnabled || _stopping) {
      _emitState();
      return;
    }
    if (_thermalCriticalSuspended || _iosLifecycleSuspended) {
      // Thermal / iOS lifecycle sẽ tự mở lại camera khi điều kiện cho phép.
      _emitState();
      return;
    }

    developer.log(
      '[RUNTIME] Resuming station camera after QR scanner...',
      name: 'CameraStationRuntime',
    );
    final epoch = _lifecycleEpoch;
    try {
      final lens = _scannerSavedLens;
      _preselectLens(webRtc, lens, facingMode: _scannerSavedFacing);
      await webRtc.initializeCamera(facingMode: _scannerSavedFacing);
      _throwIfLifecycleStale(epoch, 'scanner_resume');
      recording?.setFacingMode(_scannerSavedFacing);
      await _restoreLensState(webRtc, lens, context: 'QR scan');

      await _waitForIosCaptureWarmup(profile: _resolutionProfile);
      _throwIfLifecycleStale(epoch, 'scanner_resume');
      if (server != null) {
        await server.ensureRecording();
        // iOS có thể đã trở lại foreground trong lúc máy quét giữ camera.
        if (Platform.isIOS && _iosAppInForeground) {
          server.resumeAfterIosBackground();
        }
      }
      _resumeLivePublishers();
    } catch (e) {
      developer.log(
        '[RUNTIME] Error resuming camera after scanner: $e',
        name: 'CameraStationRuntime',
      );
      // Giao lại cho cơ chế recovery thay vì để camera tắt vĩnh viễn. Đã quá
      // hạn thì recovery đã được lên lịch lúc quá hạn.
      if (e is! _StaleLifecycleOperation && epoch == _lifecycleEpoch) {
        _scheduleRecovery('scanner_resume_failed');
      }
    }
    _emitState();
  }

  /// Dừng các phiên phát đang dùng camera sắp bị dispose, nhưng giữ ý định
  /// phát của người dùng để [_resumeLivePublishers] phát lại.
  Future<void> _pauseLivePublishers() async {
    try {
      await _rtspPublisherService.prepareForReconfiguration();
    } catch (error) {
      developer.log(
        '[LIVE] Unable to pause RTSP relay: $error',
        name: 'CameraStationRuntime',
      );
    }
    try {
      await _whipPublisherService.prepareForReconfiguration();
    } catch (error) {
      developer.log(
        '[LIVE] Unable to pause WHIP: $error',
        name: 'CameraStationRuntime',
      );
    }
  }

  /// Phát lại các luồng mà người dùng chưa dừng sau khi camera đã sẵn sàng.
  void _resumeLivePublishers() {
    if (_rtspPublisherService.wantsPublishing) {
      unawaited(_rtspPublisherService.restartIfPublishing());
    }
    if (_whipPublisherService.wantsPublishing) {
      _whipPublisherService.attachWebRtcService(_webRtcService);
      unawaited(_whipPublisherService.restartIfPublishing());
    }
  }

  bool get rtspTabletAudio => _webRtcService?.rtspTabletAudio ?? false;

  double get exposureBiasEv => _webRtcService?.exposureBiasEv ?? 0;

  /// Người dùng chỉnh độ sáng hình: lưu lại và áp ngay cho camera đang mở.
  Future<void> setExposureBias(double ev) async {
    await StationConfigService().saveExposureBias(ev);
    await _webRtcService?.setExposureBias(ev);
    _emitState();
  }

  /// Điện thoại đang kết nối Wi-Fi/Ethernet (không tính hotspot, 4G/5G).
  bool get onWifiNetwork =>
      _networkSignature?.any(
        (entry) => lanInterfacePriority(entry.split('|').first) == 0,
      ) ??
      false;

  /// Bật/tắt tiếng cho Tablet xem RTSP. Tablet đang xem cần kết nối lại.
  Future<void> setRtspTabletAudio(bool enabled) async {
    await StationConfigService().saveRtspTabletAudio(enabled);
    await _webRtcService?.setRtspTabletAudio(enabled);
    _emitState();
  }

  void _emitState() {
    // Chỉ báo FPS bị giới hạn khi giới hạn đã thật sự áp lên camera (Android);
    // iOS không giới hạn FPS tại chỗ nên giữ FPS cấu hình.
    final fpsCap = thermalFpsCap;
    _rtspPublisherService.expectedFps = fpsCap == null
        ? _resolutionProfile.fps
        : math.min(fpsCap, _resolutionProfile.fps);
    _rtspPublisherService.maxBitrateBps =
        (_resolutionProfile.rtspBitrate * _thermalLoadPlan.bitrateFactor)
            .round();
    if (!_stateController.isClosed) _stateController.add(null);
  }

  Future<void> _handleAndroidTaskRemoved() async {
    if (!Platform.isAndroid) return;
    developer.log(
      '[SERVICE] Finalizing the active segment before Android exits',
      name: 'CameraStationRuntime',
    );
    final webRtc = _webRtcService;
    await stop(
      onRecorderStopped: () async {
        // MediaRecorder and native audio have finalized their source files.
        // Camera/live transports can now close immediately while FFmpeg
        // continues remuxing the already-safe source into its final TS file.
        await webRtc?.disposeConnection();
        await webRtc?.disposeCamera();
      },
    );
  }

  void _startNetworkMonitor() {
    _networkTimer?.cancel();
    _networkTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_checkNetworkState());
    });
    unawaited(_checkNetworkState());
  }

  /// Phát hiện chuyển đổi Wi-Fi ↔ 4G/5G, mất hoặc có lại mạng và báo cho
  /// luồng livestream để nối lại ngay.
  Future<void> _observeNetworkPaths(int session) async {
    final Set<String> current;
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      current = {
        for (final interface in interfaces)
          for (final address in interface.addresses)
            if (!address.address.startsWith('169.254.'))
              '${interface.name}|${address.address}',
      };
    } catch (_) {
      return;
    }
    // Runtime đã dừng/khởi tạo lại trong lúc chờ: bỏ kết quả cũ.
    if (session != _monitorSession) return;
    final previous = _networkSignature;
    _networkSignature = current;
    if (previous == null) return;
    final lost = previous.difference(current);
    final gained = current.difference(previous);
    if (lost.isEmpty && gained.isEmpty) return;
    developer.log(
      '[NETWORK] Network paths changed: lost=$lost gained=$gained',
      name: 'CameraStationRuntime',
    );
    _rtspPublisherService.handleNetworkChange(
      interfaceLost: activeRouteLost(lost, current),
    );
    _whipPublisherService.handleNetworkChange(
      interfaceLost: activeRouteLost(lost, current),
    );
  }

  Future<String?> _readLanAddress() async {
    if (Platform.isIOS) {
      final value = await _platformChannel
          .invokeMethod<String>('getWifiIpAddress')
          .timeout(const Duration(seconds: 2));
      return selectPrivateLanIpv4([?value]);
    }
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    return selectStationLanAddress(
      interfaces.expand(
        (interface) => interface.addresses.map(
          (address) => (interface: interface.name, address: address.address),
        ),
      ),
    );
  }

  Future<void> _checkNetworkState() async {
    if (_networkCheckRunning || _stopping) return;
    final session = _monitorSession;
    _networkCheckRunning = true;
    try {
      final String? address;
      try {
        await _observeNetworkPaths(session);
        address = await _readLanAddress();
      } catch (error, stackTrace) {
        if (session != _monitorSession) return;
        // Lỗi ĐỌC trạng thái mạng (thường thoáng qua): chỉ báo cho UI, không
        // nối lại dịch vụ (nối lại = đóng mọi peer WebRTC của Tablet).
        _networkReadError = error.toString();
        developer.log(
          '[NETWORK] Cannot inspect LAN state',
          error: error,
          stackTrace: stackTrace,
          name: 'CameraStationRuntime',
        );
        _emitState();
        return;
      }
      if (session != _monitorSession || _stopping) return;
      final hadReadError = _networkReadError != null;
      _networkReadError = null;
      final previous = _lanAddress;
      final firstObservation = !_networkObservationInitialized;
      _networkObservationInitialized = true;

      // iOS can briefly return no Wi-Fi address while its window and network
      // state settle during an orientation transition. Keep the last valid
      // address for one missed poll. Otherwise the next successful poll looks
      // like an IP change and unnecessarily recreates live transports,
      // disconnecting every tablet peer even though Wi-Fi never changed.
      if (address == null && previous != null) {
        _missingNetworkObservations++;
        if (_missingNetworkObservations < 2) {
          if (hadReadError) _emitState();
          return;
        }
      } else {
        _missingNetworkObservations = 0;
      }

      _lanAddress = address;
      final reconnect = shouldReconnectNetworkServices(
        firstObservation: firstObservation,
        previousAddress: previous,
        address: address,
        lastReconnectFailed: _networkReconnectFailures > 0,
        retryNotBefore: _networkReconnectRetryAt,
        now: DateTime.now(),
      );
      if (reconnect) {
        try {
          await reconnectNetworkServices();
        } catch (_) {
          // Lỗi đã được ghi vào networkError và lần thử lại có backoff
          // (networkReconnectRetryDelay).
        }
      } else if (address != previous || hadReadError) {
        _emitState();
      }
    } finally {
      if (session == _monitorSession) _networkCheckRunning = false;
    }
  }

  /// Restarts only live/discovery transports. Camera capture and the current
  /// recording segment are deliberately preserved.
  Future<void> reconnectNetworkServices() async {
    if (_networkRecovering) return;
    final session = _monitorSession;
    final server = _cameraServer;
    if (server == null || !server.running) {
      throw StationException.fromCode(
        StationErrorCode.networkServerNotRunning,
      );
    }
    final currentAddress = _lanAddress ?? await _readLanAddress();
    if (session != _monitorSession) return;
    _lanAddress = currentAddress;
    if (currentAddress == null) {
      _networkError = null;
      _emitState();
      return;
    }
    _networkRecovering = true;
    _networkError = null;
    _emitState();
    try {
      await server.reconnectNetworkServices();
      if (session != _monitorSession) return;
      // RTSP server cục bộ không bị khởi động lại khi đổi mạng, nên relay
      // livestream (đặc biệt khi đi 4G/5G) giữ nguyên. Nếu đường mạng của nó
      // thực sự đứt, FFmpeg/WHIP tự kết nối lại.
      _networkReconnectFailures = 0;
      _networkReconnectRetryAt = null;
      try {
        _lanAddress = await _readLanAddress();
      } catch (error) {
        developer.log(
          '[NETWORK] Cannot re-read LAN address after recovery: $error',
          name: 'CameraStationRuntime',
        );
      }
      developer.log(
        '[NETWORK] Live services ready at ${_lanAddress ?? 'no LAN address'}',
        name: 'CameraStationRuntime',
      );
    } catch (error, stackTrace) {
      if (session == _monitorSession) {
        // Khôi phục thất bại: thử lại sau 5 s, 15 s rồi mỗi 60 s.
        _networkError = error.toString();
        _networkReconnectFailures++;
        final delay = networkReconnectRetryDelay(_networkReconnectFailures);
        _networkReconnectRetryAt = DateTime.now().add(delay);
      }
      developer.log(
        '[NETWORK] Live service recovery failed',
        error: error,
        stackTrace: stackTrace,
        name: 'CameraStationRuntime',
      );
      rethrow;
    } finally {
      if (session == _monitorSession) _networkRecovering = false;
      _emitState();
    }
  }

  Future<void> _waitForIosCaptureWarmup({CameraResolutionProfile? profile}) {
    if (!Platform.isIOS) return Future<void>.value();
    final delay = iosCaptureWarmupDuration(profile ?? _resolutionProfile);
    if (delay == Duration.zero) return Future<void>.value();
    return Future<void>.delayed(delay);
  }

  /// FPS thực tế iOS báo về: dùng cho /status và health monitor.
  void _handleIosCapturePerformance(double actualFps, int requestedFps) {
    _iosActualFps = actualFps;
    _iosRequestedFps = requestedFps;
    _iosPerformanceMeasuredAt = DateTime.now();
    _emitState();
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
      // Lần dọn trước (quét thư mục lớn) chưa xong: không chạy chồng.
      if (recording == null || _storageCleanupRunning) return;
      final session = _monitorSession;
      _storageCleanupRunning = true;
      unawaited(() async {
        try {
          // Never inspect staging files while MediaRecorder/FFmpeg may still
          // be writing them; cleanup runs again after the next stop/start.
          if (!recording.recording && !recording.rotating) {
            await recording.cleanupStagingFiles();
          }
          if (shouldRunPeriodicStorageEnforcement(
            lowStorage: recording.lowStorageWarning,
            lastRun: recording.lastStorageEnforcedAt,
            now: DateTime.now(),
          )) {
            await recording.enforceStorageLimit();
          }
        } catch (error, stackTrace) {
          developer.log(
            '[STORAGE] Periodic cleanup failed',
            error: error,
            stackTrace: stackTrace,
            name: 'CameraStationRuntime',
          );
        } finally {
          if (session == _monitorSession) _storageCleanupRunning = false;
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
        _scannerPaused ||
        !_cameraEnabled) {
      return;
    }
    final session = _monitorSession;
    _healthCheckRunning = true;
    try {
      final webRtc = _webRtcService;
      final track = webRtc?.localVideoTrack;
      if (webRtc == null ||
          !webRtc.cameraInitialized ||
          track == null ||
          !track.enabled) {
        _reportHealthFailure('health_check_failed', requiredFailures: 2);
        return;
      }

      final recording = _recordingService;
      final server = _cameraServer;
      if (recording == null || server == null) return;
      if (!recording.recording && !recording.rotating) {
        _resetRecordingProgressWatchdog();
        if (server.stoppedByRequest || !recording.storageRetryDue) return;
        final generation = _generation;
        try {
          // Chạy trong hàng đợi vòng đời để không mở recorder song song với
          // đổi cấu hình / recovery / nền iOS; kiểm tra lại mọi điều kiện vì
          // trạng thái có thể đã đổi trong lúc chờ hàng đợi.
          await _serializeLifecycle(() async {
            if (session != _monitorSession ||
                generation != _generation ||
                _stopping ||
                _recovering ||
                _profileSwitching ||
                _thermalCriticalSuspended ||
                _iosLifecycleSuspended ||
                _scannerPaused ||
                !_cameraEnabled ||
                !identical(_cameraServer, server) ||
                !identical(_recordingService, recording) ||
                server.stoppedByRequest ||
                recording.recording ||
                recording.rotating) {
              return;
            }
            await server.ensureRecording();
          }, label: 'health_ensure_recording');
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
        _beginRecordingTransitionGrace();
        _resetRecordingProgressWatchdog();
        return;
      }
      // Recorder đang tạm treo (vd thiếu dung lượng) và RecordingService tự
      // thử mở lại theo nhịp riêng: mở lại camera không giúp gì, chỉ gây
      // khoảng hở và nóng máy, nên không tính là lỗi tiến trình ghi.
      if (recording.isRecordingSuspended) {
        _resetRecordingProgressWatchdog();
        return;
      }

      final progress = await recording.currentRecordingProgress();
      if (session != _monitorSession) return;
      if (progress == null) {
        _reportHealthFailure('recording_progress_missing', requiredFailures: 2);
        return;
      }
      final now = DateTime.now();
      var videoStalled = false;
      var videoHardStalled = false;
      if (_lastRecordingPath != progress.path) {
        _beginRecordingTransitionGrace(now: now);
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
      if (session != _monitorSession) return;
      var audioStalled = false;
      if (audioProgress != null) {
        if (!audioProgress.active) {
          if (!_inRecordingTransitionGrace(now)) {
            _reportHealthFailure(
              'recording_audio_inactive',
              requiredFailures: 3,
            );
          }
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
        _reportHealthFailure('recording_audio_stalled', requiredFailures: 2);
      } else if (videoStalled &&
          !_hasRecentHealthyIosCapture(now) &&
          (audioProgress == null || videoHardStalled)) {
        // MP4 writers may buffer metadata/video writes. On Android, continuing
        // WAV progress proves the capture pipeline is alive and avoids a false
        // recovery. Video-only/iOS segments still rely on MP4 growth.
        developer.log(
          '[RECORDING] Staging file stopped growing at ${progress.bytes} bytes',
          name: 'CameraStationRuntime',
        );
        _reportHealthFailure('recording_file_stalled', requiredFailures: 2);
      } else {
        _healthFailureCounts.clear();
      }
    } catch (error, stackTrace) {
      developer.log(
        '[HEALTH] Runtime health check failed',
        error: error,
        stackTrace: stackTrace,
        name: 'CameraStationRuntime',
      );
    } finally {
      if (session == _monitorSession) _healthCheckRunning = false;
    }
  }

  bool _hasRecentHealthyIosCapture(DateTime now) {
    if (!Platform.isIOS) return false;
    final measuredAt = _iosPerformanceMeasuredAt;
    final actualFps = _iosActualFps;
    if (measuredAt == null || actualFps == null || actualFps < 1) return false;
    return now.difference(measuredAt) <= const Duration(seconds: 30);
  }

  void _resetRecordingProgressWatchdog() {
    _lastRecordingPath = null;
    _lastRecordingBytes = null;
    _lastRecordingProgressAt = null;
    _lastAudioPath = null;
    _lastAudioBytes = null;
    _lastAudioProgressAt = null;
    _healthFailureCounts.clear();
  }

  void _beginRecordingTransitionGrace({DateTime? now}) {
    _healthGraceUntil = (now ?? DateTime.now()).add(_recordingTransitionGrace);
    _healthFailureCounts.clear();
  }

  bool _inRecordingTransitionGrace(DateTime now) {
    final until = _healthGraceUntil;
    return until != null && now.isBefore(until);
  }

  void _reportHealthFailure(String reason, {required int requiredFailures}) {
    if (_inRecordingTransitionGrace(DateTime.now())) return;
    final failures = (_healthFailureCounts[reason] ?? 0) + 1;
    _healthFailureCounts
      ..clear()
      ..[reason] = failures;
    developer.log(
      '[HEALTH] $reason confirmation $failures/$requiredFailures',
      name: 'CameraStationRuntime',
    );
    if (failures < requiredFailures) return;
    _healthFailureCounts.clear();
    _scheduleRecovery(reason);
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
        _scannerPaused ||
        _iosLifecycleSuspended) {
      return;
    }
    final session = _monitorSession;
    _thermalCheckRunning = true;
    try {
      final snapshot = await _readThermalSnapshot();
      // Runtime đã dừng/khởi tạo lại trong lúc đọc: bỏ kết quả cũ.
      if (session != _monitorSession || _stopping) return;
      final temperature = snapshot.temperatureC;
      _temperatureC = temperature;

      final dimSignals = _readThermalDimSignals(
        temperature,
        hot: snapshot.hot,
        cool: snapshot.cool,
      );

      final critical = snapshot.critical;
      final hot = snapshot.hot;
      _thermalCriticalStreak = critical ? _thermalCriticalStreak + 1 : 0;
      _thermalNonCriticalStreak = critical ? 0 : _thermalNonCriticalStreak + 1;
      _thermalEmergencyStreak =
          snapshot.emergency ? _thermalEmergencyStreak + 1 : 0;
      if (shouldExitCriticalDegrade(
        degraded: _thermalCriticalDegraded,
        nonCriticalStreak: _thermalNonCriticalStreak,
      )) {
        // Hết critical (đủ số lần đọc liên tiếp): trả bitrate. Cấu hình 720p
        // giữ nguyên và được khôi phục theo luồng _thermalThrottled bên dưới
        // (không khôi phục khi đang livestream để tránh ngắt luồng thêm lần nữa).
        _thermalCriticalDegraded = false;
        _thermalCriticalDegradedSince = null;
        developer.log(
          '[THERMAL] Critical state cleared; restoring livestream bitrate',
          name: 'CameraStationRuntime',
        );
      }
      _charging = snapshot.charging;
      if (_thermalCriticalSuspended) {
        _applyThermalScreenDim(dimSignals, temperature: temperature);
      } else {
        await _applyThermalLoadPlan(
          thermalLoadPlan(
            hot: hot,
            criticalConfirmed:
                _thermalCriticalStreak >= thermalConfirmationReadings,
            headroom: snapshot.headroom,
            profileFps: _resolutionProfile.fps,
            temperatureC: temperature,
          ),
        );
        if (session != _monitorSession || _stopping) return;
        _applyThermalScreenDim(dimSignals, temperature: temperature);
        final degradedSince = _thermalCriticalDegradedSince;
        final action = thermalEscalation(
          criticalStreak: _thermalCriticalStreak,
          emergencyStreak: _thermalEmergencyStreak,
          criticalDegradedFor: degradedSince == null
              ? Duration.zero
              : DateTime.now().difference(degradedSince),
          isIos: Platform.isIOS,
        );
        if (action != ThermalAction.none) {
          _cancelPendingThermalTimers();
          _thermalNormalSince = null;
          if (action == ThermalAction.suspend) {
            // Chỉ đặt yêu cầu vào hàng đợi rồi trả về: không chờ hàng đợi
            // (có thể đang bận đổi cấu hình) để monitor không bị kẹt.
            _requestThermalSuspend();
          } else {
            _degradeForCriticalThermal();
          }
          _emitState();
          return;
        }
      }
      if (!hot && !_thermalThrottled && !_thermalRestoreInFlight) {
        _pendingThermalThrottleTimer?.cancel();
        _pendingThermalThrottleTimer = null;
        _pendingThermalTarget = null;
        _pendingThermalAt = null;
        _profileBeforeThermalThrottle = null;
      }
      if (_thermalCriticalSuspended) {
        if (hot) {
          _thermalNormalSince = null;
          _emitState();
          return;
        }
        final now = DateTime.now();
        _thermalNormalSince ??= now;
        if (now.difference(_thermalNormalSince!) >=
            _thermalEmergencyResumeDelay) {
          // Đếm lại thời gian chờ cho lần thử kế tiếp nếu lần này thất bại.
          _thermalNormalSince = now;
          _requestThermalResume();
        }
        _emitState();
        return;
      }
      if (hot) {
        _thermalNormalSince = null;
        _thermalCooledDownSince = null;
        _pendingThermalRestoreTimer?.cancel();
        _pendingThermalRestoreTimer = null;
      }
      // Mức "nóng": KHÔNG đổi độ phân giải (đổi = mở lại camera = Tablet và
      // livestream mất hình). Tải đã được giảm tại chỗ bởi
      // _applyThermalLoadPlan (giới hạn FPS, bitrate, làm tối màn hình). Chỉ
      // khi critical đã xác nhận mới hạ độ phân giải (_degradeForCriticalThermal),
      // trước khi phải dừng hẳn ở mức khẩn cấp.
      if (!hot) {
        if (_thermalUserOverride) {
          _thermalUserOverride = false;
          _thermalCooledDownSince = DateTime.now();
          developer.log(
            '[THERMAL] Thiết bị đã hạ nhiệt an toàn; giải phóng cờ user override',
            name: 'CameraStationRuntime',
          );
        }
        // Còn trong trạng thái critical (chưa đủ số lần đọc mát liên tiếp)
        // thì chưa tính thời gian khôi phục cấu hình.
        if (_thermalThrottled &&
            !_profileSwitching &&
            !_thermalRestoreInFlight &&
            !_thermalCriticalDegraded) {
          final now = DateTime.now();
          // Android MODERATE kéo dài vẫn được tính nếu pin ≤ 40°C; thời gian
          // ổn định 10 phút bên dưới (đếm lại mỗi lần chưa đủ mát) chống dao
          // động.
          final coolEnough = thermalRestoreCoolEnough(
            hot: hot,
            cool: snapshot.cool,
            temperatureC: temperature,
            maxTemperatureC: _thermalRestoreMaxC,
          );
          if (_profileBeforeThermalThrottle != null &&
              (!coolEnough || _thermalAutoRestoreBlocked)) {
            // Chưa đủ mát (hoặc đã từng khôi phục rồi nóng lại): giữ cấu hình
            // đã hạ để hình ổn định, không mở lại camera.
            _thermalNormalSince = null;
            _pendingThermalRestoreTimer?.cancel();
            _pendingThermalRestoreTimer = null;
            _emitState();
            return;
          }
          _thermalNormalSince ??= now;
          if (now.difference(_thermalNormalSince!) < _thermalRestoreDelay) {
            _emitState();
            return;
          }
          final previous = _profileBeforeThermalThrottle;
          if (previous != null && _livePublishingActive) {
            // Khôi phục cấu hình = mở lại camera = livestream ngắt thêm một
            // lần. Giữ cấu hình đã hạ cho tới khi dừng livestream.
            _emitState();
            return;
          }
          if (previous != null) {
            if (_pendingThermalRestoreTimer == null) {
              _scheduleThermalRestoreAtSegmentBoundary(previous);
            }
          } else {
            _thermalThrottled = false;
            _thermalNormalSince = null;
            _thermalCooledDownSince = DateTime.now();
          }
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
      if (session == _monitorSession) _thermalCheckRunning = false;
    }
  }

  static const Duration _thermalRiseWindow = Duration(seconds: 180);
  static const Duration _thermalRiseMinimumSpan = Duration(seconds: 90);
  static const double _thermalRiseDimRatePerMin = 0.8;
  static const double _thermalAutoDimMinimumC = 41.0;
  static const double _thermalAutoUndimBelowC = 39.5;

  /// Giám sát tốc độ tăng nhiệt (ΔT/Δt) và trả về tín hiệu làm tối / bật sáng
  /// màn hình. Không tự đổi độ sáng: quyết định duy nhất nằm ở
  /// [_applyThermalScreenDim] (kết hợp với kế hoạch giảm tải).
  ({bool riseWantsDim, bool cooled}) _readThermalDimSignals(
    double? temperature, {
    required bool hot,
    required bool cool,
  }) {
    if (temperature == null) {
      // iOS không công bố nhiệt độ, chỉ có ProcessInfo.thermalState: làm tối
      // khi đạt mức serious, bật sáng lại khi về nominal/fair.
      return (riseWantsDim: hot, cooled: cool);
    }
    final now = DateTime.now();
    _temperatureHistory.add((timestamp: now, temperatureC: temperature));
    _temperatureHistory.removeWhere(
      (e) => now.difference(e.timestamp) > _thermalRiseWindow,
    );

    final cooled = temperature <= _thermalAutoUndimBelowC;
    if (_screenDimmedByThermal && cooled) {
      return (riseWantsDim: false, cooled: true);
    }

    // Cần đủ mẫu và khoảng thời gian dài để tránh nhiễu cảm biến pin (0,1°C).
    if (_temperatureHistory.length < 3) {
      return (riseWantsDim: false, cooled: cooled);
    }
    final oldest = _temperatureHistory.first;
    final elapsedSeconds = now.difference(oldest.timestamp).inSeconds;
    if (elapsedSeconds < _thermalRiseMinimumSpan.inSeconds) {
      return (riseWantsDim: false, cooled: cooled);
    }
    final riseRate =
        (temperature - oldest.temperatureC) / elapsedSeconds * 60.0;
    _thermalRiseRatePerMin = riseRate;
    return (
      riseWantsDim:
          riseRate > _thermalRiseDimRatePerMin &&
          temperature >= _thermalAutoDimMinimumC,
      cooled: cooled,
    );
  }

  /// Nơi DUY NHẤT tự làm tối / bật sáng màn hình vì nhiệt (xem
  /// [thermalScreenDimDecision]).
  void _applyThermalScreenDim(
    ({bool riseWantsDim, bool cooled}) signals, {
    double? temperature,
  }) {
    final action = thermalScreenDimDecision(
      dimmedByThermal: _screenDimmedByThermal,
      autoDimAllowed: _thermalAutoDimAllowed,
      planWantsDim: !_thermalCriticalSuspended && _thermalLoadPlan.dimScreen,
      riseWantsDim: signals.riseWantsDim,
      cooled: signals.cooled,
    );
    switch (action) {
      case ThermalDimAction.none:
        return;
      case ThermalDimAction.undim:
        _screenDimmedByThermal = false;
        _autoScreenDimmed = false;
        developer.log(
          '[THERMAL] Máy đã nguội'
          '${temperature == null ? '' : ' (${temperature.toStringAsFixed(1)}°C)'}'
          '; bật sáng lại màn hình',
          name: 'CameraStationRuntime',
        );
        unawaited(_setScreenDimmedSafely(false));
      case ThermalDimAction.dim:
        _autoScreenDimmed = true;
        _screenDimmedByThermal = true;
        final rate = _thermalRiseRatePerMin;
        developer.log(
          signals.riseWantsDim && rate != null && temperature != null
              ? '[THERMAL] Tốc độ tăng nhiệt cao: '
                    '${rate.toStringAsFixed(2)}°C/phút (nhiệt độ hiện tại: '
                    '${temperature.toStringAsFixed(1)}°C). Tự động làm tối '
                    'màn hình để giải nhiệt.'
              : '[THERMAL] Tự động làm tối màn hình để giải nhiệt '
                    '(giảm tải bậc ${_thermalLoadPlan.level}).',
          name: 'CameraStationRuntime',
        );
        unawaited(_setScreenDimmedSafely(true));
    }
    _emitState();
  }

  Future<void> _setScreenDimmedSafely(bool dimmed) async {
    try {
      await StationDisplayService.setDimmed(dimmed);
    } catch (error) {
      developer.log(
        '[THERMAL] Unable to change screen brightness: $error',
        name: 'CameraStationRuntime',
      );
    }
  }

  bool get _livePublishingActive =>
      _rtspPublisherService.wantsPublishing ||
      _whipPublisherService.wantsPublishing;

  void _scheduleThermalRestoreAtSegmentBoundary(
    CameraResolutionProfile profile,
  ) {
    final delay = _delayUntilSegmentBoundary();
    developer.log(
      '[THERMAL] Temperature stable; scheduling ${profile.shortLabel}/'
      '${profile.fps}fps restore at the segment boundary in ${delay.inSeconds}s',
      name: 'CameraStationRuntime',
    );
    _pendingThermalRestoreTimer = Timer(delay, () {
      _pendingThermalRestoreTimer = null;
      unawaited(_applyPendingThermalRestore(profile));
    });
  }

  Future<void> _applyPendingThermalRestore(
    CameraResolutionProfile profile,
  ) async {
    if (_stopping ||
        !_cameraEnabled ||
        _thermalCriticalSuspended ||
        _thermalCriticalDegraded ||
        _iosLifecycleSuspended ||
        _scannerPaused ||
        !_thermalThrottled ||
        _thermalRestoreInFlight ||
        _livePublishingActive ||
        _profileSwitching) {
      return;
    }
    // Giữ _thermalThrottled và profile mục tiêu trong lúc chờ đổi độ phân
    // giải: lần kiểm tra nhiệt chen vào không được coi là "đã hết hạ nhiệt"
    // mà xoá profile mục tiêu (lỗi thì kẹt ở 720p).
    _thermalRestoreInFlight = true;
    final session = _monitorSession;
    try {
      await _serializeLifecycle(
        () async {
          // Đang đổi cấu hình khác: _setResolutionProfileInternal sẽ bỏ qua
          // im lặng, không được coi là đã khôi phục.
          if (_profileSwitching) {
            throw StationException.fromCode(StationErrorCode.cameraBusy);
          }
          await _setResolutionProfileInternal(
            profile,
            persistSelection: false,
          );
        },
        timeout: _reconfigureOperationTimeout,
        label: 'thermal_restore',
        recoverOnTimeout: true,
      );
      if (session != _monitorSession) return;
      // Critical quay lại trong lúc khôi phục: giữ profile mục tiêu để khôi
      // phục lần sau khi nguội.
      if (!_thermalCriticalDegraded && !_thermalCriticalSuspended) {
        _thermalThrottled = false;
        _profileBeforeThermalThrottle = null;
      }
      _thermalNormalSince = null;
      _thermalCooledDownSince = DateTime.now();
      _lastThermalRestoreAt = DateTime.now();
      developer.log(
        '[THERMAL] Segment boundary reached; restored camera profile to ${profile.shortLabel}',
        name: 'CameraStationRuntime',
      );
    } catch (error, stackTrace) {
      if (session != _monitorSession) return;
      // Giữ profile mục tiêu (và cờ hạ nhiệt) để thử lại sau thời gian ổn
      // định kế tiếp.
      _thermalNormalSince = DateTime.now();
      developer.log(
        '[THERMAL] Failed to restore camera profile; keeping '
        '${profile.shortLabel} as the restore target',
        error: error,
        stackTrace: stackTrace,
        name: 'CameraStationRuntime',
      );
    } finally {
      if (session == _monitorSession) {
        _thermalRestoreInFlight = false;
        _emitState();
      }
    }
  }

  Duration _delayUntilSegmentBoundary() {
    final remaining = _recordingService?.currentSegmentRemaining;
    if (remaining == null || remaining <= const Duration(milliseconds: 250)) {
      return Duration.zero;
    }
    return remaining - const Duration(milliseconds: 250);
  }

  Future<_ThermalSnapshot> _readThermalSnapshot() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return _unknownThermalSnapshot;
    }
    final result = await _platformChannel.invokeMapMethod<String, dynamic>(
      'getThermalStatus',
    );
    final temperature = (result?['temperatureC'] as num?)?.toDouble();
    final status = (result?['thermalStatus'] as num?)?.toInt() ?? 0;
    final level = classifyPlatformThermalStatus(
      status,
      isIos: Platform.isIOS,
    );
    return (
      temperatureC: temperature,
      hot: (temperature != null && temperature >= 45.0) || level.hot,
      critical: (temperature != null && temperature >= 50.0) || level.critical,
      emergency:
          (temperature != null && temperature >= 55.0) || level.emergency,
      cool: level.cool,
      headroom: (result?['headroom'] as num?)?.toDouble(),
      charging: result?['charging'] == true,
    );
  }

  /// Áp dụng bậc giảm tải: tăng ngay, chỉ nới sau [_thermalLoadRelaxDelay].
  Future<void> _applyThermalLoadPlan(ThermalLoadPlan plan) async {
    final now = DateTime.now();
    if (plan.level >= _thermalLoadPlan.level) {
      _thermalLoadRelaxSince = null;
    } else {
      _thermalLoadRelaxSince ??= now;
      if (now.difference(_thermalLoadRelaxSince!) < _thermalLoadRelaxDelay) {
        plan = _thermalLoadPlan;
      } else {
        _thermalLoadRelaxSince = null;
      }
    }
    if (plan != _thermalLoadPlan) {
      developer.log(
        '[THERMAL] Load level ${_thermalLoadPlan.level} -> ${plan.level}: '
        'fps cap ${plan.fpsCap ?? 'none'}, bitrate x${plan.bitrateFactor}',
        name: 'CameraStationRuntime',
      );
      _thermalLoadPlan = plan;
      _emitState();
    }
    // Làm tối màn hình theo kế hoạch được quyết định chung ở
    // _applyThermalScreenDim (không bật/tắt ở hai nơi gây chớp màn hình).
    await _applyThermalFpsCap(plan.fpsCap);
  }

  Future<void> _applyThermalFpsCap(int? cap) async {
    final webRtc = _webRtcService;
    final trackId = webRtc?.localVideoTrack?.id;
    if (webRtc == null || trackId == null || !Platform.isAndroid) return;
    final key = '$trackId|${cap ?? 0}';
    if (key == _appliedFpsCapKey) return;
    // Track mới (camera vừa mở lại) chưa bị giới hạn: không cần gọi để bỏ cap.
    final sameTrack = _appliedFpsCapKey?.startsWith('$trackId|') ?? false;
    if (cap == null && !sameTrack) {
      _appliedFpsCapKey = key;
      return;
    }
    if (await webRtc.setCaptureFpsCap(cap)) {
      _appliedFpsCapKey = key;
      // FPS mong đợi của RTSP publisher theo giới hạn vừa áp.
      _emitState();
    }
  }

  void _cancelPendingThermalTimers() {
    _pendingThermalThrottleTimer?.cancel();
    _pendingThermalThrottleTimer = null;
    _pendingThermalTarget = null;
    _pendingThermalAt = null;
    _pendingThermalRestoreTimer?.cancel();
    _pendingThermalRestoreTimer = null;
  }

  /// Critical đã xác nhận: giảm tải ngay nhưng vẫn quay và livestream.
  /// Bỏ qua khoá độ phân giải / lựa chọn của người dùng vì đây là mức an toàn.
  /// Gọi mỗi lần kiểm tra khi critical đã xác nhận. FPS/bitrate/màn hình đã
  /// giảm tại chỗ; chỉ hạ độ phân giải (mở lại camera) khi KHÔNG livestream.
  /// Không chờ hàng đợi vòng đời: chỉ xếp yêu cầu hạ cấu hình rồi trả về.
  void _degradeForCriticalThermal() {
    // Đang đổi cấu hình (người dùng/lens): để lần kiểm tra 10 giây sau thử lại.
    if (_stopping || !_cameraEnabled || _profileSwitching) return;
    if (!_thermalCriticalDegraded) {
      _thermalCriticalDegraded = true;
      _thermalCriticalDegradedSince = DateTime.now();
      _criticalProfileSwitchFailed = false;
      _thermalUserOverride = false;
      _profileBeforeThermalThrottle ??= _resolutionProfile;
      _thermalThrottled = true;
      developer.log(
        '[THERMAL] Critical state confirmed; reducing load while keeping '
        'recording and livestream running',
        name: 'CameraStationRuntime',
      );
      _emitState();
    }
    final safeProfile = CameraResolutionProfile.hd720.withFps(30);
    if (_resolutionProfile == safeProfile ||
        _livePublishingActive ||
        _criticalProfileSwitchFailed ||
        _thermalDegradeQueued) {
      return;
    }
    // Thật sự hạ cấu hình vì nhiệt: luôn ghi nhận profile người dùng muốn để
    // khôi phục khi nguội (kể cả khi trước đó người dùng đã chọn lại).
    _profileBeforeThermalThrottle ??= _resolutionProfile;
    _thermalThrottled = true;
    _thermalDegradeQueued = true;
    unawaited(
      _serializeLifecycle(
            () => _setResolutionProfileInternal(
              safeProfile,
              persistSelection: false,
            ),
            timeout: _reconfigureOperationTimeout,
            label: 'thermal_degrade',
            recoverOnTimeout: true,
          )
          .then<void>(
            (_) {
              final restoredAt = _lastThermalRestoreAt;
              if (restoredAt != null &&
                  DateTime.now().difference(restoredAt) <
                      _thermalRestoreRelapseWindow) {
                _thermalAutoRestoreBlocked = true;
                developer.log(
                  '[THERMAL] Device overheated again soon after restoring quality; '
                  'keeping 720p until the user changes it',
                  name: 'CameraStationRuntime',
                );
              }
            },
            onError: (Object error, StackTrace stackTrace) {
              // Bị chặn tạm thời (máy quét QR, nền iOS, dừng khẩn cấp) thì lần
              // kiểm tra sau thử lại; lỗi thật thì không thử lại liên tục.
              if (error is! StationException ||
                  error.code == StationErrorCode.operationTimeout) {
                _criticalProfileSwitchFailed = true;
              }
              developer.log(
                '[THERMAL] Failed to reduce camera profile for critical state',
                error: error,
                stackTrace: stackTrace,
                name: 'CameraStationRuntime',
              );
            },
          )
          .whenComplete(() {
            _thermalDegradeQueued = false;
            _emitState();
          }),
    );
  }

  /// Xếp yêu cầu dừng khẩn cấp vào hàng đợi vòng đời rồi trả về ngay.
  void _requestThermalSuspend() {
    if (_thermalSuspendQueued || _thermalCriticalSuspended || _profileSwitching) {
      return;
    }
    // Ngắt recovery ngay (trước khi xếp hàng): lượt recovery đang chờ giữa
    // các lần thử thoát sớm để lệnh dừng được chạy, lượt đã xếp trước lệnh
    // dừng sẽ bỏ qua (generation đổi), và không xếp recovery mới trong lúc
    // yêu cầu dừng đang chờ (_thermalSuspendQueued).
    _interruptRecovery();
    _thermalSuspendQueued = true;
    unawaited(
      _serializeLifecycle(
            _suspendForCriticalThermal,
            timeout: _stopOperationTimeout,
            label: 'thermal_suspend',
          )
          .catchError((Object error, StackTrace stackTrace) {
            developer.log(
              '[THERMAL] Emergency suspend failed',
              error: error,
              stackTrace: stackTrace,
              name: 'CameraStationRuntime',
            );
          })
          .whenComplete(() {
            _thermalSuspendQueued = false;
            _emitState();
          }),
    );
  }

  /// Xếp yêu cầu mở lại camera sau dừng khẩn cấp vào hàng đợi rồi trả về.
  void _requestThermalResume() {
    if (_thermalResumeQueued || !_thermalCriticalSuspended) return;
    _thermalResumeQueued = true;
    unawaited(
      _serializeLifecycle(
            _resumeAfterCriticalThermal,
            timeout: _reconfigureOperationTimeout,
            label: 'thermal_resume',
          )
          .catchError((Object error, StackTrace stackTrace) {
            developer.log(
              '[THERMAL] Resume after emergency suspend failed',
              error: error,
              stackTrace: stackTrace,
              name: 'CameraStationRuntime',
            );
          })
          .whenComplete(() {
            _thermalResumeQueued = false;
            _emitState();
          }),
    );
  }

  Future<void> _suspendForCriticalThermal() async {
    if (_thermalCriticalSuspended || _stopping || !_cameraEnabled) return;
    final recording = _recordingService;
    final webRtc = _webRtcService;
    if (recording == null || webRtc == null) return;

    _thermalCriticalSuspended = true;
    // Recovery đã quá hạn còn chạy nền (nếu có) không được mở lại camera.
    _interruptRecovery();
    _thermalCriticalDegraded = false;
    _thermalCriticalDegradedSince = null;
    _profileBeforeThermalThrottle ??= _resolutionProfile;
    _thermalThrottled = true;
    // Máy quét QR / nền iOS đã giải phóng camera: lens đã lưu lúc đó mới đúng.
    _thermalSavedLens = _scannerPaused && _scannerSavedLens != null
        ? _scannerSavedLens
        : _currentLensState(webRtc);
    final safeProfile = CameraResolutionProfile.hd720.withFps(30);
    _resolutionProfile = safeProfile;
    webRtc.setResolutionProfile(safeProfile);
    developer.log(
      '[THERMAL] Emergency state; finalizing segment and pausing capture',
      name: 'CameraStationRuntime',
    );
    await _pauseLivePublishers();
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
        _iosLifecycleSuspended ||
        _scannerPaused) {
      return;
    }
    final webRtc = _webRtcService;
    final server = _cameraServer;
    if (webRtc == null || server == null) return;
    final epoch = _lifecycleEpoch;
    try {
      final currentFacing = webRtc.currentFacingMode;
      final lens = _thermalSavedLens;
      _preselectLens(webRtc, lens, facingMode: currentFacing);
      await webRtc.initializeCamera(facingMode: currentFacing);
      _throwIfLifecycleStale(epoch, 'thermal_resume');
      _recordingService?.setFacingMode(currentFacing);
      await webRtc.ensureMicrophoneEnabled();
      await _restoreLensState(webRtc, lens, context: 'thermal resume');
      await _waitForIosCaptureWarmup();
      _throwIfLifecycleStale(epoch, 'thermal_resume');
      await server.ensureRecording();
      _throwIfLifecycleStale(epoch, 'thermal_resume');
      if (Platform.isIOS && _iosAppInForeground) {
        server.resumeAfterIosBackground();
      }
      _thermalCriticalSuspended = false;
      _thermalSavedLens = null;
      // Camera có thể đã được bật lại trong lúc dừng khẩn cấp (wakelock tắt).
      try {
        await WakelockPlus.enable();
      } catch (error) {
        developer.log(
          '[THERMAL] Unable to enable wakelock after resume: $error',
          name: 'CameraStationRuntime',
        );
      }
      await _setIosStationActive(true);
      _resumeLivePublishers();
      developer.log(
        '[THERMAL] Device stable; capture resumed at 720p/30fps',
        name: 'CameraStationRuntime',
      );
    } catch (error, stackTrace) {
      developer.log(
        '[THERMAL] Unable to resume capture after critical state',
        error: error,
        stackTrace: stackTrace,
        name: 'CameraStationRuntime',
      );
      // Quá hạn: không đóng camera của thao tác sau (lần kiểm tra nhiệt kế
      // tiếp tự thử mở lại vì cờ dừng khẩn cấp vẫn còn).
      if (error is _StaleLifecycleOperation || epoch != _lifecycleEpoch) {
        return;
      }
      try {
        await webRtc.disposeCamera();
      } catch (disposeError) {
        developer.log(
          '[THERMAL] Unable to release camera after failed resume: $disposeError',
          name: 'CameraStationRuntime',
        );
      }
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

  /// Giữ background task hoàn tất segment của iOS (begin gửi lên native ngay
  /// trong lời gọi này). Hàm trả về trả lần giữ này đúng một lần.
  Future<void> Function() _holdIosBackgroundFinalization() {
    if (!Platform.isIOS) return () => Future<void>.value();
    return _iosFinalizationHold.acquire();
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
    final recording = _recordingService;
    if (Platform.isIOS &&
        reason == 'video_track_ended' &&
        recording?.recording == true) {
      developer.log(
        '[CAMERA] Ignoring iOS recorder-boundary video_track_ended; '
        'waiting for health confirmation.',
        name: 'CameraStationRuntime',
      );
      _beginRecordingTransitionGrace();
      return;
    }
    if (recording?.rotating == true) {
      developer.log(
        '[CAMERA] Ignoring transient $reason during recorder hand-off; '
        'the health monitor will confirm a persistent failure.',
        name: 'CameraStationRuntime',
      );
      _beginRecordingTransitionGrace();
      return;
    }
    if (_profileSwitching || _lensSwitchOperation != null) {
      // Đổi độ phân giải / lens đang chủ động đóng-mở camera: track cũ kết
      // thúc (kể cả audio track iOS onEnded) là bình thường. Thao tác đó tự
      // rollback khi lỗi; health monitor xác nhận nếu hỏng thật.
      developer.log(
        '[CAMERA] Ignoring $reason during a camera reconfiguration',
        name: 'CameraStationRuntime',
      );
      _beginRecordingTransitionGrace();
      return;
    }
    if (_recovering || !_recoveryMayProceed(superseded: false)) return;
    _recovering = true;
    final generation = _generation;
    final cancellation = _recoveryCancellation.future;
    _emitState();
    unawaited(
      _serializeLifecycle(
            () => _recoverCamera(reason, generation, cancellation),
            timeout: _recoveryOperationTimeout,
            label: 'recovery',
          )
          .catchError((Object error, StackTrace stackTrace) {
            developer.log(
              '[CAMERA] Recovery operation failed',
              error: error,
              stackTrace: stackTrace,
              name: 'CameraStationRuntime',
            );
          })
          .whenComplete(() {
            _recovering = false;
            _emitState();
          }),
    );
  }

  /// Recovery có được (tiếp tục) mở lại camera không; xem
  /// [cameraRecoveryMayProceed]. Yêu cầu dừng vì nhiệt đang chờ cũng chặn.
  bool _recoveryMayProceed({required bool superseded}) =>
      cameraRecoveryMayProceed(
        stopping: _stopping,
        cameraEnabled: _cameraEnabled,
        superseded: superseded,
        thermalSuspended: _thermalCriticalSuspended,
        thermalSuspendPending: _thermalSuspendQueued,
        iosSuspended: _iosLifecycleSuspended,
        scannerActive: _scannerPaused,
      );

  Future<void> _recoverCamera(
    String reason,
    int generation,
    Future<void> cancellation,
  ) async {
    final epoch = _lifecycleEpoch;
    // Lượt recovery bị thay thế (generation đổi: dừng vì nhiệt, đổi cấu hình,
    // stop…) hoặc đã quá hạn (hàng đợi giao cho thao tác khác).
    bool superseded() => generation != _generation || epoch != _lifecycleEpoch;
    if (!_recoveryMayProceed(superseded: superseded())) return;
    developer.log(
      '[CAMERA] Recovery requested: $reason',
      name: 'CameraStationRuntime',
    );
    debugPrint('[VNVAR] CAMERA RECOVERY REQUESTED: $reason');

    final webRtc = _webRtcService;
    final recording = _recordingService;
    final server = _cameraServer;

    if (webRtc == null || recording == null || server == null) {
      return;
    }

    // Mỗi bước dọn độc lập: một bước lỗi (camera đã hỏng là chuyện thường khi
    // cần khôi phục) không được chặn việc mở lại camera bên dưới.
    Future<void> teardownStep(String name, Future<void> Function() step) async {
      try {
        await step();
      } catch (error, stackTrace) {
        developer.log(
          '[CAMERA] Recovery teardown step "$name" failed; continuing',
          error: error,
          stackTrace: stackTrace,
          name: 'CameraStationRuntime',
        );
      }
    }

    // Lens/zoom trước khi đóng camera (giá trị vẫn giữ sau dispose) để mở lại
    // đúng góc quay thay vì rơi về camera chính 1x.
    final lens = _currentLensState(webRtc);
    // Đã quá hạn giữa các bước dọn: không đóng camera/kết nối của thao tác sau.
    if (epoch != _lifecycleEpoch) return;
    await teardownStep('pause publishers', _pauseLivePublishers);
    if (epoch != _lifecycleEpoch) return;
    await teardownStep('stop recording', () => recording.stop());
    if (epoch != _lifecycleEpoch) return;
    await teardownStep('dispose connection', webRtc.disposeConnection);
    if (epoch != _lifecycleEpoch) return;
    await teardownStep('dispose camera', webRtc.disposeCamera);

    for (var attempt = 0; attempt < _recoveryDelays.length; attempt++) {
      if (!_recoveryMayProceed(superseded: superseded())) return;

      final delay = _recoveryDelays[attempt];
      developer.log(
        '[CAMERA] Recovery attempt ${attempt + 1} '
        'in ${delay.inSeconds}s',
        name: 'CameraStationRuntime',
      );
      await Future.any<void>([Future<void>.delayed(delay), cancellation]);

      // Kiểm tra lại ngay trước khi mở camera: trong lúc chờ có thể đã có yêu
      // cầu dừng vì nhiệt, nền iOS, máy quét QR hoặc stop.
      if (!_recoveryMayProceed(superseded: superseded())) return;

      try {
        final currentFacing = webRtc.currentFacingMode;
        _preselectLens(webRtc, lens, facingMode: currentFacing);
        await webRtc.initializeCamera(facingMode: currentFacing);
        // Camera đã mở: chỉ dừng khi bị chặn hẳn (nhiệt, nền, quét QR, stop)
        // hoặc đã quá hạn; thao tác chặn đó (đang chờ trong hàng đợi) tự đóng
        // camera. Generation đổi vì đổi cấu hình thì vẫn hoàn tất để camera
        // không bị bỏ mở mà không ghi.
        if (!_recoveryMayProceed(superseded: epoch != _lifecycleEpoch)) return;
        _recordingService?.setFacingMode(currentFacing);
        await _restoreLensState(webRtc, lens, context: 'recovery');
        await _waitForIosCaptureWarmup();
        if (!_recoveryMayProceed(superseded: epoch != _lifecycleEpoch)) return;
        await server.ensureRecording();
        if (Platform.isIOS && _iosAppInForeground) {
          server.resumeAfterIosBackground();
        }
        _resumeLivePublishers();
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
        // Đã quá hạn: không đóng camera của thao tác sau.
        if (epoch != _lifecycleEpoch) return;
        // Lỗi dọn camera không được dừng các lần thử còn lại.
        try {
          await webRtc.disposeCamera();
        } catch (disposeError) {
          developer.log(
            '[CAMERA] Unable to release camera after failed recovery: '
            '$disposeError',
            name: 'CameraStationRuntime',
          );
        }
      }
    }

    developer.log(
      '[CAMERA] Recovery stopped after ${_recoveryDelays.length} attempts',
      name: 'CameraStationRuntime',
    );
  }
}
