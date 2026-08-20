import 'package:camera_station/models/station_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes station identity JSON', () {
    final identity = StationIdentity.fromJson({
      'courtId': ' COURT-06 ',
      'cameraId': ' CAM-01 ',
      'deviceId': ' PHONE-001 ',
      'cameraName': ' Camera cuối sân ',
      'cameraPosition': ' Baseline A ',
    });

    expect(identity.namespace, 'COURT-06/CAM-01');
    expect(identity.deviceId, 'PHONE-001');
    expect(identity.cameraName, 'Camera cuối sân');
    expect(identity.cameraPosition, 'Baseline A');
  });

  test('rejects incomplete station identity', () {
    expect(
      () => StationIdentity.fromJson({
        'courtId': 'COURT-01',
        'cameraId': '',
        'deviceId': 'PHONE-001',
      }),
      throwsFormatException,
    );
  });
}
