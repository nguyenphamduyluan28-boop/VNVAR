import 'package:camera_station/services/camera_station_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

ThermalAction _escalate({
  int critical = 0,
  int emergency = 0,
  Duration degradedFor = Duration.zero,
  bool isIos = false,
}) => thermalEscalation(
  criticalStreak: critical,
  emergencyStreak: emergency,
  criticalDegradedFor: degradedFor,
  isIos: isIos,
);

void main() {
  group('thermalEscalation', () {
    test('a single noisy critical reading does nothing', () {
      expect(_escalate(critical: 1), ThermalAction.none);
      expect(_escalate(critical: 2), ThermalAction.none);
    });

    test('confirmed critical degrades but keeps capture running', () {
      expect(_escalate(critical: 3), ThermalAction.degrade);
      expect(
        _escalate(critical: 30, degradedFor: const Duration(hours: 1)),
        ThermalAction.degrade,
      );
    });

    test('Android suspends only on confirmed emergency', () {
      expect(_escalate(critical: 3, emergency: 2), ThermalAction.degrade);
      expect(_escalate(critical: 3, emergency: 3), ThermalAction.suspend);
    });

    test('iOS suspends when critical persists after degrading', () {
      expect(
        _escalate(
          critical: 10,
          degradedFor: const Duration(minutes: 2),
          isIos: true,
        ),
        ThermalAction.degrade,
      );
      expect(
        _escalate(
          critical: 20,
          degradedFor: iosCriticalSuspendAfterDegrade,
          isIos: true,
        ),
        ThermalAction.suspend,
      );
      expect(
        _escalate(emergency: 5, isIos: true),
        ThermalAction.none,
      );
    });

    test('load plan steps down without reopening the camera', () {
      ThermalLoadPlan plan({
        bool hot = false,
        bool critical = false,
        double? headroom,
        int fps = 60,
      }) => thermalLoadPlan(
        hot: hot,
        criticalConfirmed: critical,
        headroom: headroom,
        profileFps: fps,
      );

      expect(plan(), thermalLoadPlanNormal);
      expect(plan(headroom: 0.5), thermalLoadPlanNormal);
      // Dự báo sắp nóng: chỉ làm tối màn hình.
      expect(plan(headroom: 0.9).level, 1);
      expect(plan(headroom: 0.9).fpsCap, isNull);
      expect(plan(headroom: 0.9).dimScreen, isTrue);
      // Nóng (hoặc dự báo chạm SEVERE): 60 -> 30 FPS, bitrate 80%.
      expect(plan(hot: true).fpsCap, 30);
      expect(plan(headroom: 0.97).level, 2);
      expect(plan(hot: true, fps: 30).fpsCap, isNull);
      expect(plan(hot: true).bitrateFactor, 0.8);
      // Critical: 24 FPS, bitrate 60%.
      expect(plan(critical: true, fps: 30).fpsCap, 24);
      expect(plan(critical: true).bitrateFactor, 0.6);
      expect(plan(critical: true, fps: 24).fpsCap, isNull);
    });

    test('streak reset to zero returns to normal', () {
      expect(
        _escalate(degradedFor: const Duration(minutes: 10)),
        ThermalAction.none,
      );
    });
  });
}
