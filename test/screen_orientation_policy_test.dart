import 'package:camera_station/screens/station_screen.dart';
import 'package:camera_station/services/station_config_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('StationConfigService screen orientation', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('defaults to landscape for court camera station', () async {
      final service = StationConfigService();
      expect(await service.loadScreenOrientation(), 'landscape');
    });

    test('persists chosen orientation mode', () async {
      final service = StationConfigService();
      await service.saveScreenOrientation('portrait');
      expect(await service.loadScreenOrientation(), 'portrait');

      await service.saveScreenOrientation('auto');
      expect(await service.loadScreenOrientation(), 'auto');

      await service.saveScreenOrientation('landscape');
      expect(await service.loadScreenOrientation(), 'landscape');
    });
  });

  group('orientationsForMode', () {
    test('returns landscape orientations for landscape mode', () {
      final orientations = orientationsForMode('landscape');
      expect(orientations, const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    });

    test('returns portrait orientations for portrait mode', () {
      final orientations = orientationsForMode('portrait');
      expect(orientations, const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    });

    test('returns all 4 orientations for auto mode', () {
      final orientations = orientationsForMode('auto');
      expect(orientations, const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    });
  });

  group('orientationsForBackgroundLock', () {
    test('locks to landscape if current layout is landscape', () {
      final orientations = orientationsForBackgroundLock(
        isCurrentLayoutLandscape: true,
      );
      expect(orientations, const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    });

    test('locks to portrait if current layout is portrait', () {
      final orientations = orientationsForBackgroundLock(
        isCurrentLayoutLandscape: false,
      );
      expect(orientations, const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    });
  });
}
