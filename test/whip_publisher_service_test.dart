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

    test('stopPublish resets state to idle cleanly', () async {
      final service = WhipPublisherService();
      await service.stopPublish();
      expect(service.state, WhipPublishState.idle);
      expect(service.isLive, isFalse);
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
}
