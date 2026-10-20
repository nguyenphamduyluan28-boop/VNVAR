import 'dart:io' show FileSystemException, SocketException;

import 'package:flutter/services.dart';

/// Mã lỗi của Camera Station runtime để UI phân biệt và hiển thị đúng ngôn
/// ngữ, thay vì dò chuỗi trong thông báo lỗi.
enum StationErrorCode {
  /// Runtime chưa khởi tạo xong (chưa có camera/server).
  notInitialized,

  /// Camera đang bị người dùng tắt.
  cameraDisabled,

  /// Camera chưa sẵn sàng để đổi cấu hình.
  cameraNotReady,

  /// Chế độ phân giải đang bị khóa.
  resolutionLocked,

  /// Thiết bị không hỗ trợ cấu hình độ phân giải được chọn.
  resolutionUnsupported,

  /// Đã dừng khẩn cấp vì máy quá nóng; camera tự mở lại khi máy nguội.
  thermalSuspended,

  /// Ứng dụng chưa được cấp quyền camera/micro. Không tự thử lại.
  permissionDenied,

  /// Camera đang bận đổi cấu hình (lens/độ phân giải).
  cameraBusy,

  /// Camera đang được nhường cho máy quét QR.
  scannerActive,

  /// iOS đang ở nền nên camera đã được giải phóng.
  iosSuspended,

  /// Không tìm thấy camera theo hướng yêu cầu.
  noCameraAvailable,

  /// Server mạng của trạm không chạy.
  networkServerNotRunning,

  /// Thao tác vòng đời camera quá thời gian cho phép.
  operationTimeout,

  unknown,
}

/// Lỗi có mã của Camera Station. [toString] trả câu tiếng Việt để giữ tương
/// thích với các chỗ đang hiển thị `error.toString()`.
class StationException implements Exception {
  const StationException(
    this.code, {
    required this.messageVi,
    required this.messageEn,
    this.cause,
  });

  /// Lỗi với thông báo mặc định theo [code].
  factory StationException.fromCode(StationErrorCode code, {Object? cause}) {
    final messages = _defaultMessages(code);
    return StationException(
      code,
      messageVi: messages.vi,
      messageEn: messages.en,
      cause: cause,
    );
  }

  final StationErrorCode code;
  final String messageVi;
  final String messageEn;

  /// Lỗi gốc (nếu có), ví dụ lỗi getUserMedia khi thiếu quyền.
  final Object? cause;

  bool get isPermissionDenied => code == StationErrorCode.permissionDenied;

  String message({required bool english}) => english ? messageEn : messageVi;

  @override
  String toString() => messageVi;
}

({String vi, String en}) _defaultMessages(StationErrorCode code) {
  return switch (code) {
    StationErrorCode.notInitialized => (
      vi: 'Camera Station chưa khởi tạo xong.',
      en: 'Camera Station has not finished initializing.',
    ),
    StationErrorCode.cameraDisabled => (
      vi: 'Camera đang tắt.',
      en: 'The camera is turned off.',
    ),
    StationErrorCode.cameraNotReady => (
      vi: 'Camera chưa sẵn sàng.',
      en: 'The camera is not ready.',
    ),
    StationErrorCode.resolutionLocked => (
      vi: 'Chế độ phân giải đang bị khóa.',
      en: 'The resolution setting is locked.',
    ),
    StationErrorCode.resolutionUnsupported => (
      vi: 'Thiết bị không hỗ trợ độ phân giải này.',
      en: 'This device does not support the selected resolution.',
    ),
    StationErrorCode.thermalSuspended => (
      vi:
          'Máy quá nóng nên camera đang tạm dừng; camera sẽ tự bật lại khi '
          'máy nguội.',
      en:
          'The device is overheating, so the camera is paused; it will '
          'restart automatically once the device cools down.',
    ),
    StationErrorCode.permissionDenied => (
      vi:
          'Ứng dụng chưa được cấp quyền truy cập Camera hoặc Micro. Vui lòng '
          'kiểm tra cài đặt thiết bị.',
      en:
          'Camera or Microphone permissions not granted. Please check device '
          'settings.',
    ),
    StationErrorCode.cameraBusy => (
      vi: 'Camera đang thay đổi cấu hình.',
      en: 'The camera is changing its configuration.',
    ),
    StationErrorCode.scannerActive => (
      vi: 'Camera đang được dùng để quét mã QR.',
      en: 'The camera is in use by the QR scanner.',
    ),
    StationErrorCode.iosSuspended => (
      vi: 'Ứng dụng đang chạy nền nên camera tạm dừng.',
      en: 'The app is in the background, so the camera is paused.',
    ),
    StationErrorCode.noCameraAvailable => (
      vi: 'Thiết bị không có camera khả dụng.',
      en: 'No camera is available on this device.',
    ),
    StationErrorCode.networkServerNotRunning => (
      vi: 'Máy chủ mạng của Camera Station chưa chạy.',
      en: 'Camera Station network server is not running.',
    ),
    StationErrorCode.operationTimeout => (
      vi: 'Thao tác camera quá thời gian cho phép.',
      en: 'The camera operation timed out.',
    ),
    StationErrorCode.unknown => (
      vi: 'Đã xảy ra lỗi không xác định.',
      en: 'An unknown error occurred.',
    ),
  };
}

/// Lỗi mở camera/micro có phải do bị từ chối quyền không. Lỗi từ
/// getUserMedia (flutter_webrtc) và MethodChannel không có mã thống nhất giữa
/// Android/iOS nên vẫn dò theo chuỗi (heuristic cũ của màn hình Station).
bool isPermissionDeniedError(Object error) {
  if (error is StationException) {
    return error.code == StationErrorCode.permissionDenied;
  }
  // Lỗi I/O (bind cổng, ghi file) có thể chứa "Permission denied" nhưng không
  // phải quyền camera/micro: vẫn để runtime tự khởi tạo lại.
  if (error is SocketException || error is FileSystemException) return false;
  final parts = <String>[error.toString()];
  if (error is PlatformException) {
    parts.add(error.code);
    final message = error.message;
    if (message != null) parts.add(message);
    final details = error.details;
    if (details != null) parts.add(details.toString());
  }
  final text = parts.join(' ').toLowerCase();
  return text.contains('permission') ||
      text.contains('notallowederror') ||
      text.contains('not allowed') ||
      text.contains('quyền') ||
      text.contains('denied');
}

/// Thông báo lỗi cho người dùng theo ngôn ngữ đang chọn.
String stationErrorMessage(Object error, {required bool english}) {
  if (error is StationException) return error.message(english: english);
  if (isPermissionDeniedError(error)) {
    return StationException.fromCode(
      StationErrorCode.permissionDenied,
    ).message(english: english);
  }
  final raw = error
      .toString()
      .replaceFirst(RegExp(r'^(Exception|Bad state|StateError): '), '')
      .trim();
  if (raw.isEmpty) {
    return StationException.fromCode(
      StationErrorCode.unknown,
    ).message(english: english);
  }
  return raw;
}
