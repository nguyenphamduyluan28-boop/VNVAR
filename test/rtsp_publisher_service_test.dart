import 'package:camera_station/services/rtsp_publisher_service.dart';
import 'package:camera_station/services/station_config_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RtspPublisherService unit tests', () {
    test('initial state is idle and not live', () {
      final service = RtspPublisherService();
      expect(service.state, RtspPublishState.idle);
      expect(service.isLive, isFalse);
      expect(service.liveDuration, Duration.zero);
      expect(service.currentError, isNull);
      expect(service.targetUrl, isNull);
    });

    test('startPublish with empty target URL sets error state', () async {
      final service = RtspPublisherService();
      final states = <RtspPublishState>[];
      final sub = service.onStateChanged.listen(states.add);

      await service.startPublish(
        targetUrl: '   ',
      );

      expect(service.state, RtspPublishState.error);
      expect(service.currentError, contains('Chưa nhập URL đích'));
      expect(states, contains(RtspPublishState.error));

      await sub.cancel();
      service.dispose();
    });

    test('startPublish with invalid scheme sets error state', () async {
      final service = RtspPublisherService();
      await service.startPublish(
        targetUrl: 'http://invalid-scheme.com/live',
      );

      expect(service.state, RtspPublishState.error);
      expect(service.currentError, contains('URL không đúng định dạng'));
      service.dispose();
    });

    test('stopPublish resets state to idle cleanly', () async {
      final service = RtspPublisherService();
      await service.stopPublish();
      expect(service.state, RtspPublishState.idle);
      expect(service.isLive, isFalse);
      service.dispose();
    });

    test('invalid configuration is not treated as an active publish', () async {
      final service = RtspPublisherService();
      await service.startPublish(targetUrl: 'http://invalid-scheme.com/live');
      expect(service.wantsPublishing, isFalse);

      // Camera reconfiguration must not resurrect a rejected configuration.
      await service.restartIfPublishing();
      expect(service.state, RtspPublishState.error);
      service.dispose();
    });

    test('restartIfPublishing does not restart after the user stopped', () async {
      final service = RtspPublisherService();
      await service.stopPublish();
      await service.restartIfPublishing();
      expect(service.state, RtspPublishState.idle);
      expect(service.wantsPublishing, isFalse);
      service.dispose();
    });

    test('network quality starts unknown', () {
      final service = RtspPublisherService()..expectedFps = 15;
      expect(service.networkQuality, StreamNetworkQuality.unknown);
      service.dispose();
    });
  });

  group('StationConfigService RTSP & Protocol storage tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('save and load RTSP push URL', () async {
      final config = StationConfigService();

      expect(await config.loadRtspPushUrl(), isNull);

      const testUrl =
          'rtsp://media.aqvision.net:18554/live/camera_demo?key=test_key_123';
      await config.saveRtspPushConfig(targetUrl: testUrl);

      expect(await config.loadRtspPushUrl(), testUrl);
    });

    test('save and load stream protocol', () async {
      final config = StationConfigService();

      // Default is rtsp
      expect(await config.loadStreamProtocol(), 'rtsp');

      await config.saveStreamProtocol('whip');
      expect(await config.loadStreamProtocol(), 'whip');

      await config.saveStreamProtocol('rtsp');
      expect(await config.loadStreamProtocol(), 'rtsp');
    });
  });
}
