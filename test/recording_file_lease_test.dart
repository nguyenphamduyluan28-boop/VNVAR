import 'package:camera_station/services/recording_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('file read lease is reference counted', () {
    final recording = RecordingService(cameraId: 'CAM-01');
    const path = r'D:\VNVAR\download\clip.ts';

    recording.acquireFileRead(path);
    recording.acquireFileRead(path);
    expect(recording.isFileReadActive(path), isTrue);

    recording.releaseFileRead(path);
    expect(recording.isFileReadActive(path), isTrue);

    recording.releaseFileRead(path);
    expect(recording.isFileReadActive(path), isFalse);
  });
}
