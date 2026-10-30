import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Ghi log chẩn đoán. `developer.log` chỉ hiện khi gỡ lỗi bằng DevTools; bản
/// cài trên máy thật cần thấy log livestream / bảng tỉ số qua `adb logcat`
/// (thẻ `flutter`), nên in thêm bằng [debugPrint]. Không ghi URL có khóa phát
/// (dùng `maskStreamUrlForLog`).
void stationLog(
  String message, {
  String name = '',
  Object? error,
  StackTrace? stackTrace,
}) {
  developer.log(message, name: name, error: error, stackTrace: stackTrace);
  debugPrint(error == null ? message : '$message: $error');
}
