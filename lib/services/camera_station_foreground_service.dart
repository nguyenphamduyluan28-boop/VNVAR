import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/services.dart';

class CameraStationForegroundService {
  static const MethodChannel _channel = MethodChannel(
    'vnvar/camera_station_service',
  );

  static Future<void> start({
    required String cameraId,
    required String courtId,
  }) async {
    if (!Platform.isAndroid) return;
    developer.log(
      '[SERVICE] Request foreground start: $cameraId / $courtId',
      name: 'CameraStationForegroundService',
    );

    try {
      await _channel.invokeMethod<void>('start', {
        'cameraId': cameraId,
        'courtId': courtId,
      });
    } on MissingPluginException {
      developer.log(
        '[SERVICE] Android foreground service plugin is unavailable.',
        name: 'CameraStationForegroundService',
      );
    }
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    developer.log(
      '[SERVICE] Request foreground stop',
      name: 'CameraStationForegroundService',
    );
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      developer.log(
        '[SERVICE] Android foreground service plugin is unavailable.',
        name: 'CameraStationForegroundService',
      );
    }
  }
}
