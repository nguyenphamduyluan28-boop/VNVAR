import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/services.dart';

typedef PlatformEventHandler = Future<void> Function(MethodCall call);

/// Bộ điều phối duy nhất cho các callback native → Dart trên kênh
/// `vnvar/camera_station_service`.
///
/// Flutter chỉ giữ MỘT handler cho mỗi kênh: trước đây `WebRtcService` và
/// `StationScreen` cùng gọi `setMethodCallHandler`, bên đăng ký sau ghi đè bên
/// trước nên một bên luôn mất callback (encoder RTSP, onAndroidTaskRemoved hoặc
/// xoay màn hình/PiP). Lớp này đăng ký handler một lần và chuyển mọi sự kiện
/// tới tất cả các bên đang lắng nghe.
class StationPlatformEvents {
  StationPlatformEvents._();

  static final StationPlatformEvents instance = StationPlatformEvents._();

  static const MethodChannel channel = MethodChannel(
    'vnvar/camera_station_service',
  );

  final Map<Object, PlatformEventHandler> _listeners =
      <Object, PlatformEventHandler>{};
  bool _installed = false;

  /// Đăng ký [handler] cho [owner]; đăng ký lại cùng owner sẽ thay handler cũ.
  void addListener(Object owner, PlatformEventHandler handler) {
    _listeners[owner] = handler;
    if (!_installed) {
      channel.setMethodCallHandler(_dispatch);
      _installed = true;
    }
  }

  void removeListener(Object owner) {
    _listeners.remove(owner);
  }

  int get listenerCount => _listeners.length;

  Future<void> _dispatch(MethodCall call) async {
    for (final handler in _listeners.values.toList(growable: false)) {
      try {
        await handler(call);
      } catch (error, stackTrace) {
        developer.log(
          '[PLATFORM] Listener failed for ${call.method}',
          error: error,
          stackTrace: stackTrace,
          name: 'StationPlatformEvents',
        );
      }
    }
  }
}
