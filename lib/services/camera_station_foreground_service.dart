import 'dart:developer' as developer;

import 'package:flutter/services.dart';

class CameraStationForegroundService {
  static const MethodChannel _channel = MethodChannel(
    'vnvar/camera_station_service',
  );

  static Future<void> start({
    required String cameraId,
    required String courtId,
  }) async {
    developer.log(
      '[SERVICE] Request foreground start: $cameraId / $courtId',
      name: 'CameraStationForegroundService',
    );

    await _channel.invokeMethod<void>('start', {
      'cameraId': cameraId,
      'courtId': courtId,
    });
  }

  static Future<void> stop() async {
    developer.log(
      '[SERVICE] Request foreground stop',
      name: 'CameraStationForegroundService',
    );
    await _channel.invokeMethod<void>('stop');
  }
}
