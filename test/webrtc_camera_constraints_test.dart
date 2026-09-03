import 'package:camera_station/models/camera_resolution_profile.dart';
import 'package:camera_station/services/webrtc_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS uses top-level numeric capture constraints', () {
    final constraints = buildCameraVideoConstraints(
      isEmulator: false,
      isIos: true,
      facingMode: 'environment',
      preferredDeviceId: 'back-camera',
      profile: CameraResolutionProfile.fullHd1080,
    );

    expect(constraints['width'], 1920);
    expect(constraints['height'], 1080);
    expect(constraints['frameRate'], 30);
    expect(constraints['deviceId'], 'back-camera');
  });

  test('Android keeps ideal and maximum capture constraints', () {
    final constraints = buildCameraVideoConstraints(
      isEmulator: false,
      isIos: false,
      facingMode: 'environment',
      preferredDeviceId: '0',
      profile: CameraResolutionProfile.hd720,
    );

    expect(constraints['width'], {'ideal': 1280, 'max': 1280});
    expect(constraints['height'], {'ideal': 720, 'max': 720});
    expect(constraints['frameRate'], {'ideal': 30, 'max': 30});
  });

  test('emulator uses conservative camera constraints', () {
    final constraints = buildCameraVideoConstraints(
      isEmulator: true,
      isIos: false,
      facingMode: 'environment',
      preferredDeviceId: null,
      profile: CameraResolutionProfile.ultraHd4k,
    );

    expect(constraints['width'], {'min': 320, 'ideal': 640, 'max': 640});
    expect(constraints['height'], {'min': 240, 'ideal': 480, 'max': 480});
    expect(constraints['frameRate'], {'ideal': 15, 'max': 20});
  });
}
