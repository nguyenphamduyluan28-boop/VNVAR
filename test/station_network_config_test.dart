import 'package:camera_station/services/station_config_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('uses the compatible HTTP port by default', () async {
    expect(await StationConfigService().loadApiPort(), 8080);
  });

  test('persists a valid configured HTTP port', () async {
    final service = StationConfigService();
    await service.saveApiPort(18080);
    expect(await service.loadApiPort(), 18080);
  });

  test('rejects ports outside the TCP range', () async {
    final service = StationConfigService();
    expect(() => service.saveApiPort(0), throwsArgumentError);
    expect(() => service.saveApiPort(65536), throwsArgumentError);
  });
}
