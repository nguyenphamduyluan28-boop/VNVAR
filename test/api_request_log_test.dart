import 'package:camera_station/services/camera_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('logs replay/download calls, skips noisy polling', () {
    for (final path in [
      '/checkvar',
      '/segments',
      '/video/CAM-01_15-00-00_15-03-00.ts',
      '/download/clip.mp4',
      '/trim',
    ]) {
      expect(shouldLogApiRequest(path), isTrue, reason: path);
    }
    for (final path in ['/status', '/webrtc/offer', '/api/score/events']) {
      expect(shouldLogApiRequest(path), isFalse, reason: path);
    }
  });
}
