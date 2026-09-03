import 'package:camera_station/models/camera_resolution_profile.dart';
import 'package:camera_station/screens/station_screen.dart';
import 'package:camera_station/services/camera_station_runtime.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('iOS capture lifecycle policy', () {
    const expectations = <AppLifecycleState, bool>{
      AppLifecycleState.resumed: false,
      AppLifecycleState.inactive: false,
      AppLifecycleState.hidden: true,
      AppLifecycleState.paused: true,
      AppLifecycleState.detached: true,
    };

    for (final entry in expectations.entries) {
      test('${entry.key.name} => suspend=${entry.value}', () {
        expect(shouldSuspendIosCapture(entry.key), entry.value);
      });
    }

    test('temporary interruption does not finalize the current segment', () {
      expect(shouldSuspendIosCapture(AppLifecycleState.inactive), isFalse);
    });

    test('background states always finalize capture', () {
      for (final state in const [
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.detached,
      ]) {
        expect(
          shouldSuspendIosCapture(state),
          isTrue,
          reason: '${state.name} must close the active iOS recorder safely',
        );
      }
    });
  });

  group('iOS lens handoff policy', () {
    test('keeps the active track when both lenses support the same profile', () {
      expect(
        shouldRecreateIosCameraForLensSwitch(
          CameraResolutionProfile.fullHd1080,
          CameraResolutionProfile.fullHd1080,
        ),
        isFalse,
      );
    });

    test('recreates capture when the target lens requires another profile', () {
      expect(
        shouldRecreateIosCameraForLensSwitch(
          CameraResolutionProfile.ultraHd4k,
          CameraResolutionProfile.fullHd1080,
        ),
        isTrue,
      );
    });
  });
}
