import 'package:camera_station/services/station_config_service.dart';
import 'package:camera_station/services/whip_publisher_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WhipPublisherService tests', () {
    test('initial state is idle and not live', () {
      final service = WhipPublisherService();
      expect(service.state, WhipPublishState.idle);
      expect(service.isLive, isFalse);
      expect(service.liveDuration, Duration.zero);
      expect(service.currentError, isNull);
      expect(service.currentEndpoint, isNull);
    });

    test('startPublish with empty URL sets error state', () async {
      final service = WhipPublisherService();
      final states = <WhipPublishState>[];
      final subscription = service.onStateChanged.listen(states.add);

      await service.startPublish(
        endpointUrl: '   ',
        webRtcService: null,
      );

      expect(service.state, WhipPublishState.error);
      expect(service.currentError, contains('Chưa cấu hình URL WHIP Endpoint'));
      expect(states, contains(WhipPublishState.error));

      await subscription.cancel();
      await service.dispose();
    });

    test('localizedError returns Vietnamese and English messages', () async {
      final service = WhipPublisherService();
      expect(service.localizedError(english: false), isNull);
      expect(service.localizedError(english: true), isNull);

      await service.startPublish(endpointUrl: '', webRtcService: null);

      expect(
        service.localizedError(english: false),
        contains('Chưa cấu hình URL WHIP Endpoint'),
      );
      expect(service.localizedError(english: false), service.currentError);
      expect(
        service.localizedError(english: true),
        contains('WHIP endpoint URL is not configured'),
      );
      await service.dispose();
    });

    test('stopPublish resets state to idle cleanly', () async {
      final service = WhipPublisherService();
      await service.stopPublish();
      expect(service.state, WhipPublishState.idle);
      expect(service.isLive, isFalse);
      await service.dispose();
    });
  });

  group('WHIP rejection policy', () {
    test('4xx except 408/429 stops retrying', () {
      expect(isPermanentWhipRejection(400), isTrue);
      expect(isPermanentWhipRejection(401), isTrue);
      expect(isPermanentWhipRejection(403), isTrue);
      expect(isPermanentWhipRejection(404), isTrue);
      expect(isPermanentWhipRejection(408), isFalse);
      expect(isPermanentWhipRejection(429), isFalse);
      expect(isPermanentWhipRejection(500), isFalse);
      expect(isPermanentWhipRejection(503), isFalse);
      expect(isPermanentWhipRejection(201), isFalse);
    });

    test('bearer token only goes to the same origin on DELETE', () {
      const endpoint = 'https://media.example.com:8889/live/whip';
      expect(
        whipSessionSharesOrigin(
          endpoint,
          'https://media.example.com:8889/live/whip/session/1',
        ),
        isTrue,
      );
      expect(
        whipSessionSharesOrigin(endpoint, 'https://other.example.com:8889/s/1'),
        isFalse,
      );
      expect(
        whipSessionSharesOrigin(endpoint, 'http://media.example.com:8889/s/1'),
        isFalse,
      );
      expect(
        whipSessionSharesOrigin(endpoint, 'https://media.example.com/s/1'),
        isFalse,
      );
      expect(
        whipSessionSharesOrigin(
          'https://media.example.com/live/whip',
          'https://MEDIA.example.com:443/s/1',
        ),
        isTrue,
      );
    });

    test('duration listenable starts at zero', () async {
      final service = WhipPublisherService();
      expect(service.durationListenable.value, Duration.zero);
      await service.dispose();
    });
  });

  group('StationConfigService WHIP storage tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('save and load WHIP endpoint and token', () async {
      final config = StationConfigService();

      expect(await config.loadWhipEndpointUrl(), isNull);
      expect(await config.loadWhipAuthToken(), isNull);

      await config.saveWhipConfig(
        endpointUrl: 'https://media.partner.com/live/court1/whip',
        token: 'secret_token_123',
      );

      expect(
        await config.loadWhipEndpointUrl(),
        'https://media.partner.com/live/court1/whip',
      );
      expect(await config.loadWhipAuthToken(), 'secret_token_123');

      // Clear token
      await config.saveWhipConfig(
        endpointUrl: 'https://media.partner.com/live/court1/whip',
        token: null,
      );

      expect(
        await config.loadWhipEndpointUrl(),
        'https://media.partner.com/live/court1/whip',
      );
      expect(await config.loadWhipAuthToken(), isNull);
    });
  });

  group('WHIP TLS policy', () {
    test('accepts self-signed certificates only on the local network', () {
      expect(allowsSelfSignedWhipCertificate('192.168.1.10'), isTrue);
      expect(allowsSelfSignedWhipCertificate('10.0.0.5'), isTrue);
      expect(allowsSelfSignedWhipCertificate('172.20.10.1'), isTrue);
      expect(allowsSelfSignedWhipCertificate('mediamtx.local'), isTrue);
      expect(allowsSelfSignedWhipCertificate('localhost'), isTrue);
    });

    test('always verifies certificates of Internet servers', () {
      expect(allowsSelfSignedWhipCertificate('whip.example.com'), isFalse);
      expect(allowsSelfSignedWhipCertificate('8.8.8.8'), isFalse);
      expect(allowsSelfSignedWhipCertificate('172.32.0.1'), isFalse);
      expect(allowsSelfSignedWhipCertificate('2001:db8::1'), isFalse);
    });

    test('network change does nothing when not publishing', () {
      final service = WhipPublisherService();
      service.handleNetworkChange();
      expect(service.state, WhipPublishState.idle);
    });
  });
}
