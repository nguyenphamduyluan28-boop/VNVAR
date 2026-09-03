import 'package:camera_station/screens/station_screen.dart';
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
  });
}
