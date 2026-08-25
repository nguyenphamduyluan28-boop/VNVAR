import 'dart:io';

import 'package:camera_station/services/camera_station_foreground_service.dart';
import 'package:camera_station/services/webrtc_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('vnvar/camera_station_service');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('foreground service is a no-op outside Android', () async {
    if (Platform.isAndroid) return;
    var nativeCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          nativeCalls++;
          return null;
        });

    await CameraStationForegroundService.start(
      cameraId: 'CAM-01',
      courtId: 'COURT-01',
    );
    await CameraStationForegroundService.stop();

    expect(nativeCalls, 0);
  });

  test('RTSP capability matches the host platform', () {
    final service = WebRtcService();
    expect(service.rtspSupported, Platform.isAndroid);
  });
}
