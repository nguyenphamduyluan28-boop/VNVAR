import 'dart:io';

import 'package:flutter/services.dart';

class StationDisplayService {
  static const MethodChannel _channel = MethodChannel(
    'vnvar/camera_station_service',
  );

  static Future<void> setDimmed(bool dimmed) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    await _channel.invokeMethod<void>('setScreenDimmed', {'dimmed': dimmed});
  }
}
