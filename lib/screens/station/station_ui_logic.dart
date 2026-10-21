import 'dart:async';

import '../../models/station_identity.dart';

// ============================================================
// LOGIC THUẦN CỦA MÀN HÌNH STATION (không phụ thuộc runtime/platform để
// kiểm thử được bằng unit test).
// ============================================================

/// Mức thay đổi khi người dùng áp dụng cấu hình mới.
enum StationConfigChange {
  /// Không đổi gì: chỉ đóng màn cài đặt, không khởi động lại.
  none,

  /// Chỉ đổi thông tin hiển thị (tên camera, vị trí): lưu lại, không cần
  /// khởi động lại camera/server.
  metadataOnly,

  /// Đổi sân/camera/thiết bị (hoặc trạm đang không chạy): phải khởi động lại.
  restartRequired,
}

/// So sánh cấu hình mới với cấu hình hiện tại. Runtime chỉ dùng
/// courtId/cameraId/deviceId (xem `CameraStationRuntime.initialize`), nên đổi
/// tên/vị trí camera không cần khởi động lại. [stationRunning] = false (đang
/// lỗi/chưa chạy) thì luôn khởi động lại để thử với cấu hình được chọn.
StationConfigChange classifyStationConfigChange({
  required StationIdentity current,
  required StationIdentity next,
  required bool stationRunning,
}) {
  final runtimeChanged =
      current.courtId.trim() != next.courtId.trim() ||
      current.cameraId.trim() != next.cameraId.trim() ||
      current.deviceId.trim() != next.deviceId.trim();
  if (runtimeChanged || !stationRunning) {
    return StationConfigChange.restartRequired;
  }
  final metadataChanged =
      current.cameraName.trim() != next.cameraName.trim() ||
      current.cameraPosition.trim() != next.cameraPosition.trim();
  return metadataChanged
      ? StationConfigChange.metadataOnly
      : StationConfigChange.none;
}

/// Số giây (làm tròn lên, không âm) từ [now] tới [target]; null nếu không có
/// mốc. Dùng cho "Tự thử lại sau Ns" và đếm ngược hạ độ phân giải vì nhiệt.
int? secondsUntil(DateTime? target, DateTime now) {
  if (target == null) return null;
  final micros = target.difference(now).inMicroseconds;
  if (micros <= 0) return 0;
  return (micros + Duration.microsecondsPerSecond - 1) ~/
      Duration.microsecondsPerSecond;
}

/// Rút gọn thông báo lỗi thô (ví dụ lỗi native nhiều dòng) để hiển thị: chỉ
/// dòng đầu có nội dung, tối đa [maxLength] ký tự.
String compactErrorText(String message, {int maxLength = 240}) {
  final firstLine = message
      .split('\n')
      .map((line) => line.trim())
      .firstWhere((line) => line.isNotEmpty, orElse: () => '');
  if (firstLine.length <= maxLength) return firstLine;
  return '${firstLine.substring(0, maxLength - 3)}...';
}

/// Thời lượng livestream: `mm:ss`, hoặc `h:mm:ss` khi quá 1 giờ.
String formatLiveDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// Chạy tuần tự các yêu cầu, chỉ giữ yêu cầu MỚI NHẤT (latest-wins).
///
/// Đang có thao tác chạy thì yêu cầu mới chỉ được ghi nhận làm mục tiêu kế
/// tiếp (ghi đè mục tiêu cũ chưa chạy). Khi thao tác đang chạy xong, mục tiêu
/// mới nhất được áp dụng nếu khác yêu cầu vừa chạy. Lỗi của từng lần chạy
/// được giao cho [onError] và không làm dừng hàng đợi.
class LatestWinsRunner<T> {
  LatestWinsRunner(this._run, {this.onError, this.onIdle});

  final Future<void> Function(T request) _run;
  final void Function(Object error, StackTrace stackTrace)? onError;

  /// Gọi khi hàng đợi chạy hết (không còn yêu cầu chờ).
  final void Function()? onIdle;

  bool _busy = false;
  bool _hasPending = false;
  T? _pending;
  bool _disposed = false;

  /// Đang có thao tác chạy (hoặc còn yêu cầu chờ).
  bool get busy => _busy;

  /// Có yêu cầu mới đang chờ chạy sau thao tác hiện tại. Kết quả của thao
  /// tác đang chạy đã lỗi thời khi giá trị này là true: UI nên giữ giá trị
  /// mục tiêu mới nhất thay vì hiển thị kết quả đó.
  bool get hasPending => _hasPending && !_disposed;

  /// Gửi yêu cầu. Future hoàn tất khi hàng đợi chạy hết (kể cả các yêu cầu
  /// gửi sau), không bao giờ ném lỗi.
  Future<void> submit(T request) {
    if (_disposed) return Future<void>.value();
    _pending = request;
    _hasPending = true;
    if (_busy) return _idle?.future ?? Future<void>.value();
    _busy = true;
    final idle = Completer<void>();
    _idle = idle;
    unawaited(_drain(idle));
    return idle.future;
  }

  Completer<void>? _idle;

  Future<void> _drain(Completer<void> idle) async {
    var hasLast = false;
    T? last;
    try {
      while (_hasPending && !_disposed) {
        final request = _pending as T;
        _hasPending = false;
        _pending = null;
        // Yêu cầu chờ trùng với yêu cầu vừa chạy: không chạy lại.
        if (hasLast && request == last) continue;
        hasLast = true;
        last = request;
        try {
          await _run(request);
        } catch (error, stackTrace) {
          onError?.call(error, stackTrace);
        }
      }
    } finally {
      _busy = false;
      _idle = null;
      if (!idle.isCompleted) idle.complete();
      if (!_disposed) onIdle?.call();
    }
  }

  /// Bỏ yêu cầu đang chờ và không nhận yêu cầu mới (thao tác đang chạy vẫn
  /// chạy hết).
  void dispose() {
    _disposed = true;
    _hasPending = false;
    _pending = null;
  }
}

// ============================================================
// BẢNG TỈ SỐ TRÊN LIVESTREAM
// ============================================================

/// Cờ overlay bảng tỉ số cần cho thanh trạng thái: [burnIn] = tính năng in
/// bảng tỉ số vào video live đang bật; [visible] = overlay đang hiện.
typedef ScoreOverlayFlags = ({bool burnIn, bool visible});

/// Mặc định của `ScoreOverlayConfig`: in vào live bật, overlay ẩn.
const ScoreOverlayFlags defaultScoreOverlayFlags = (
  burnIn: true,
  visible: false,
);

/// Đọc cờ overlay từ JSON trạng thái bảng tỉ số (`ScoreboardService.snapshot()`
/// hoặc một sự kiện của `changes`). Thiếu/hỏng dữ liệu → mặc định.
ScoreOverlayFlags readScoreOverlayFlags(Map<String, dynamic>? snapshot) {
  final overlay = snapshot?['overlay'];
  if (overlay is! Map) return defaultScoreOverlayFlags;
  return (
    burnIn: overlay['burnIn'] != false,
    visible: overlay['visible'] == true,
  );
}

/// Gợi ý trạng thái bảng tỉ số trên thanh trạng thái khi đang LIVE.
enum ScoreOverlayHint {
  /// Không hiện gì (không live hoặc tắt tính năng in bảng tỉ số).
  none,

  /// Đang live, có in bảng tỉ số nhưng overlay đang ẩn → người xem không thấy.
  hidden,

  /// Đang live và bảng tỉ số đang hiện trên luồng phát.
  shown,
}

ScoreOverlayHint scoreOverlayHint({
  required bool live,
  required ScoreOverlayFlags flags,
}) {
  if (!live || !flags.burnIn) return ScoreOverlayHint.none;
  return flags.visible ? ScoreOverlayHint.shown : ScoreOverlayHint.hidden;
}

// ============================================================
// CHẤT LƯỢNG LUỒNG PHÁT & MENU NHANH
// ============================================================

/// Số liệu luồng phát cho tooltip: "28 fps · 2450 kbps". Bỏ phần chưa có số
/// liệu (≤ 0 hoặc không hữu hạn); null nếu cả hai đều chưa có.
String? formatStreamMetrics(double fps, double bitrateKbps) {
  final parts = <String>[
    if (fps.isFinite && fps > 0) '${fps.round()} fps',
    if (bitrateKbps.isFinite && bitrateKbps > 0)
      '${bitrateKbps.round()} kbps',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Bố cục menu nhanh: số cột và dòng gọn.
typedef QuickMenuLayout = ({int columns, bool dense});

/// Chiều cao một dòng menu (thường / gọn).
const double quickMenuRowHeight = 52;
const double quickMenuDenseRowHeight = 48;

/// Bề rộng tối thiểu một ô menu khi xếp 2 cột.
const double quickMenuGridTileWidth = 168;

/// Khoảng chiếm thêm theo chiều dọc ngoài các dòng: viền + padding bảng kính
/// (6 + 1 mỗi phía) và padding trên/dưới của vùng cuộn (4 mỗi phía).
const double quickMenuVerticalChrome = 22;

/// Khoảng chiếm thêm theo chiều ngang (viền + padding bảng kính).
const double quickMenuHorizontalChrome = 14;

/// Chọn bố cục menu nhanh vừa vùng [maxWidth]×[maxHeight] (vùng dưới thanh
/// trạng thái, trên thanh zoom): ưu tiên 1 cột dòng thường; thiếu chỗ thì dòng
/// gọn; vẫn thiếu mà đủ rộng thì 2 cột (máy ngang). Không vừa nữa thì menu
/// tự cuộn (bắt đầu từ mục đầu).
QuickMenuLayout quickMenuLayout({
  required double maxWidth,
  required double maxHeight,
  required int itemCount,
}) {
  double heightFor(int rows, double rowHeight) =>
      rows * rowHeight + quickMenuVerticalChrome;
  if (maxHeight >= heightFor(itemCount, quickMenuRowHeight)) {
    return (columns: 1, dense: false);
  }
  if (maxHeight >= heightFor(itemCount, quickMenuDenseRowHeight)) {
    return (columns: 1, dense: true);
  }
  final gridWidth =
      2 * quickMenuGridTileWidth + 8 + quickMenuHorizontalChrome;
  if (itemCount > 1 && maxWidth >= gridWidth) {
    return (columns: 2, dense: true);
  }
  return (columns: 1, dense: true);
}
