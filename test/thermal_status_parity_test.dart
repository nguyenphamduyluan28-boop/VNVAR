import 'package:camera_station/services/camera_station_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifyPlatformThermalStatus', () {
    test('iOS serious is hot and critical pauses capture', () {
      expect(classifyPlatformThermalStatus(0, isIos: true).hot, isFalse);
      expect(classifyPlatformThermalStatus(1, isIos: true).cool, isTrue);
      expect(classifyPlatformThermalStatus(4, isIos: true).hot, isTrue);
      expect(classifyPlatformThermalStatus(4, isIos: true).critical, isFalse);
      expect(classifyPlatformThermalStatus(5, isIos: true).critical, isTrue);
    });

    test('Android SEVERE/CRITICAL match iOS serious/critical', () {
      expect(classifyPlatformThermalStatus(2, isIos: false).hot, isFalse);
      expect(classifyPlatformThermalStatus(3, isIos: false).hot, isTrue);
      expect(classifyPlatformThermalStatus(3, isIos: false).critical, isFalse);
      expect(classifyPlatformThermalStatus(4, isIos: false).critical, isTrue);
      expect(classifyPlatformThermalStatus(1, isIos: false).cool, isTrue);
      expect(classifyPlatformThermalStatus(2, isIos: false).cool, isFalse);
    });
  });
}
