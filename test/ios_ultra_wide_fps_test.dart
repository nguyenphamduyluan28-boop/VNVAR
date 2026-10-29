import 'package:camera_station/services/camera_station_runtime.dart';
import 'package:camera_station/services/webrtc_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ultraWideMaxFps', () {
    test('iOS keeps 60 FPS when the ultra-wide lens reports it', () {
      expect(ultraWideMaxFps(isIos: true, reported: 60, requested: 60), 60);
    });

    test('iOS falls back to 30 FPS when nothing is reported', () {
      expect(ultraWideMaxFps(isIos: true, reported: null, requested: 60), 30);
      expect(ultraWideMaxFps(isIos: true, reported: 0, requested: 60), 30);
    });

    test('iOS uses the real lens ceiling when it is below 60', () {
      expect(ultraWideMaxFps(isIos: true, reported: 30, requested: 60), 30);
    });

    test('Android without data keeps the requested FPS', () {
      expect(ultraWideMaxFps(isIos: false, reported: null, requested: 60), 60);
    });

    test('Android uses the real lens ceiling when reported', () {
      expect(ultraWideMaxFps(isIos: false, reported: 30, requested: 60), 30);
      expect(ultraWideMaxFps(isIos: false, reported: 60, requested: 60), 60);
    });
  });

  group('AvailableCameraDevice.maxFps', () {
    test('parses per-size FPS from native', () {
      final camera = AvailableCameraDevice.fromMap({
        'id': 'uw',
        'facing': 'back',
        'isUltraWide': true,
        'maxFps': {'1920x1080': 60, '1280x720': 60.0, 'bad': 'x', '4032x3024': 0},
      });
      expect(camera.maxFpsFor(1920, 1080), 60);
      expect(camera.maxFpsFor(1280, 720), 60);
      expect(camera.maxFpsFor(4032, 3024), isNull);
      expect(camera.maxFpsFor(3840, 2160), isNull);
    });

    test('missing data means unknown', () {
      final camera = AvailableCameraDevice.fromMap({'id': 'a'});
      expect(camera.maxFpsBySize, isEmpty);
      expect(camera.maxFpsFor(1920, 1080), isNull);
    });
  });

  group('evaluateUltraWide (Android)', () {
    test('logical zoom really applied below 1x and fps reached', () {
      expect(
        evaluateUltraWide(
          physicalUltraWide: false,
          appliedZoom: 0.6,
          measuredFps: 59.4,
          expectedFps: 60,
        ),
        UltraWideCheck.ok,
      );
    });

    test('zoom stuck at 1x means the ultra-wide lens is not active', () {
      expect(
        evaluateUltraWide(
          physicalUltraWide: false,
          appliedZoom: 1.0,
          measuredFps: 60,
          expectedFps: 60,
        ),
        UltraWideCheck.notWide,
      );
    });

    test('wide but only ~30 fps measured', () {
      expect(
        evaluateUltraWide(
          physicalUltraWide: true,
          appliedZoom: null,
          measuredFps: 29.8,
          expectedFps: 60,
        ),
        UltraWideCheck.lowerFps,
      );
    });

    test('small fps jitter is fine', () {
      expect(
        evaluateUltraWide(
          physicalUltraWide: true,
          appliedZoom: null,
          measuredFps: 53,
          expectedFps: 60,
        ),
        UltraWideCheck.ok,
      );
    });

    test('no data at all is unknown', () {
      expect(
        evaluateUltraWide(
          physicalUltraWide: false,
          appliedZoom: null,
          measuredFps: null,
          expectedFps: 60,
        ),
        UltraWideCheck.unknown,
      );
    });
  });

  test('ultraWideFpsFromMeasurement picks the highest reachable option', () {
    expect(ultraWideFpsFromMeasurement(29.7, [30, 60]), 30);
    expect(ultraWideFpsFromMeasurement(58.9, [30, 60]), 60);
    expect(ultraWideFpsFromMeasurement(24.0, [30, 60]), 30);
  });
}
