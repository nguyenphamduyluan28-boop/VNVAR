import 'package:camera_station/services/webrtc_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WebRtcService.ensureCapturePermissions', () {
    test('concurrent calls share one pending request', () async {
      final first = WebRtcService.ensureCapturePermissions();
      final second = WebRtcService.ensureCapturePermissions();
      expect(identical(first, second), isTrue);
      await first;
    });

    test('a later call after completion starts a new request', () async {
      final first = WebRtcService.ensureCapturePermissions();
      await first;
      // Dọn Future dùng chung chạy ở microtask sau khi hoàn tất.
      await Future<void>.delayed(Duration.zero);
      final second = WebRtcService.ensureCapturePermissions();
      expect(identical(first, second), isFalse);
      await second;
    });

    test('completes without a platform on desktop/test hosts', () async {
      await expectLater(WebRtcService.ensureCapturePermissions(), completes);
    });
  });
}
