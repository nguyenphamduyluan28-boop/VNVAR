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
