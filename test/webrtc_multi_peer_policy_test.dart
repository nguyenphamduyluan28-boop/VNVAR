import 'package:camera_station/services/camera_server.dart';
import 'package:camera_station/services/webrtc_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WebRTC peer identity', () {
    test('keeps a valid peer id supplied by a current tablet', () {
      expect(
        normalizeWebRtcPeerId('tablet-referee_02', fallbackAddress: '10.0.0.2'),
        'tablet-referee_02',
      );
    });

    test('creates a stable legacy id from the tablet address', () {
      expect(
        normalizeWebRtcPeerId(null, fallbackAddress: '192.168.1.158'),
        'legacy_192.168.1.158',
      );
    });

    test('sanitizes and bounds untrusted peer ids', () {
      final value = normalizeWebRtcPeerId(
        '${List.filled(100, 'x').join()}/tablet',
        fallbackAddress: 'unknown',
      );
      expect(value.length, 96);
      expect(value, isNot(contains('/')));
    });
  });

  group('WebRTC thermal resource policy', () {
    test('allows four viewers at normal temperature', () {
      expect(
        effectiveWebRtcPeerLimit('normal'),
        WebRtcService.maximumActivePeers,
      );
    });

    test('reduces admission while hot or critical', () {
      expect(effectiveWebRtcPeerLimit('hot'), 2);
      expect(effectiveWebRtcPeerLimit('serious'), 2);
      expect(effectiveWebRtcPeerLimit('critical'), 1);
    });
  });
}
