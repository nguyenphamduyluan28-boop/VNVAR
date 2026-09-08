import 'package:camera_station/services/camera_station_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LAN address selection', () {
    test('returns null when the device has no private LAN address', () {
      expect(selectPrivateLanIpv4(const []), isNull);
      expect(selectPrivateLanIpv4(const ['127.0.0.1', '169.254.1.2']), isNull);
    });

    test('accepts standard private IPv4 ranges', () {
      expect(selectPrivateLanIpv4(const ['192.168.1.24']), '192.168.1.24');
      expect(selectPrivateLanIpv4(const ['10.10.0.5']), '10.10.0.5');
      expect(selectPrivateLanIpv4(const ['172.16.2.3']), '172.16.2.3');
      expect(selectPrivateLanIpv4(const ['172.31.2.3']), '172.31.2.3');
    });

    test('rejects public and non-private 172 addresses', () {
      expect(selectPrivateLanIpv4(const ['8.8.8.8']), isNull);
      expect(selectPrivateLanIpv4(const ['172.15.2.3']), isNull);
      expect(selectPrivateLanIpv4(const ['172.32.2.3']), isNull);
    });

    test('prefers the first valid private address', () {
      expect(
        selectPrivateLanIpv4(const ['8.8.8.8', '10.0.0.20', '192.168.1.3']),
        '10.0.0.20',
      );
    });
  });
}
