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

    test('streak reset to zero returns to normal', () {
      expect(
        _escalate(degradedFor: const Duration(minutes: 10)),
        ThermalAction.none,
      );
    });
  });
}
