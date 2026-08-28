import 'package:camera_station/services/recording_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('starts with no active segment audio', () {
    final service = RecordingService(cameraId: 'CAM-01');

    expect(service.recording, isFalse);
    expect(service.rotating, isFalse);
    expect(service.currentSegmentHasAudio, isFalse);
    expect(service.segments, isEmpty);
    expect(service.segmentDuration, const Duration(minutes: 3));
    expect(service.segmentMinutes, 3);
  });

  test('stop is safe and idempotent when recording is not active', () async {
    final service = RecordingService(cameraId: 'CAM-01');

    expect(await service.stop(), isNull);
    expect(await service.stop(), isNull);
    expect(service.recording, isFalse);
    expect(service.currentSegmentHasAudio, isFalse);
  });
}
