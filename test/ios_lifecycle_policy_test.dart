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

    test('resumed state never requests another suspension', () {
      expect(shouldSuspendIosCapture(AppLifecycleState.resumed), isFalse);
    });
  });

  group('iOS lens handoff policy', () {
    test(
      'keeps the active track when both lenses support the same profile',
      () {
        expect(
          shouldRecreateIosCameraForLensSwitch(
            CameraResolutionProfile.fullHd1080,
            CameraResolutionProfile.fullHd1080,
          ),
          isFalse,
        );
      },
    );

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

  group('iOS high-resolution warm-up policy', () {
    test('4K gets enough time to settle before recorder startup', () {
      expect(
        iosCaptureWarmupDuration(CameraResolutionProfile.ultraHd4k),
        const Duration(milliseconds: 1500),
      );
    });

    test('1080p starts immediately', () {
      expect(
        iosCaptureWarmupDuration(CameraResolutionProfile.fullHd1080),
        Duration.zero,
      );
    });
  });

  group('iOS adaptive 4K FPS policy', () {
    test('steps down without skipping stability levels', () {
      expect(nextLowerIos4kFps(30), 24);
      expect(nextLowerIos4kFps(24), 20);
      expect(nextLowerIos4kFps(20), 15);
    });

    test('stops reducing at the safe floor', () {
      expect(nextLowerIos4kFps(15), isNull);
    });

    test('falls back to 1080p after the 4K safe floor also fails', () {
      final result = nextIosOverloadProfile(
        CameraResolutionProfile.ultraHd4k.withFps(15),
        const [
          CameraResolutionProfile.hd720,
          CameraResolutionProfile.fullHd1080,
          CameraResolutionProfile.ultraHd4k,
        ],
      );

      expect(result, CameraResolutionProfile.fullHd1080);
    });

    test('does not adapt a non-4K profile', () {
      expect(
        nextIosOverloadProfile(
          CameraResolutionProfile.fullHd1080,
          CameraResolutionProfile.values,
        ),
        isNull,
      );
    });
  });
}
