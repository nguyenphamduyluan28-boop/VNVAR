import 'dart:async';

import 'package:camera_station/services/rtsp_publisher_service.dart';
import 'package:camera_station/services/scoreboard_burn_in.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _settle([int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Stop while (re)connecting', () {
    test('stop during the initial await never prepares or launches FFmpeg',
        () async {
      final service = RtspPublisherService();
      var prepared = 0;
      final launches = <List<String>>[];
      service.prepareOverlay =
          (String url, {required bool scrollingTicker}) async {
        prepared++;
        return null;
      };
      service.debugOnFfmpegLaunch = launches.add;

      // Không await: Dừng đến ngay khi phiên đang chờ hủy phiên cũ.
      final starting = service.startPublish(
        targetUrl: 'rtmp://example.com/live/key',
      );
      final stopping = service.stopPublish();
      await Future.wait([starting, stopping]);
      await _settle();

      expect(prepared, 0);
      expect(launches, isEmpty);
      expect(service.state, RtspPublishState.idle);
      expect(service.wantsPublishing, isFalse);
      service.dispose();
    });

    test('stop while the scoreboard is being prepared releases it', () async {
      final service = RtspPublisherService();
      final gate = Completer<LivestreamOverlay?>();
      var prepareCalled = false;
      var overlayReady = false;
      var releasedAfterReady = 0;
      final launches = <List<String>>[];
      service.prepareOverlay = (String url, {required bool scrollingTicker}) {
        prepareCalled = true;
        return gate.future;
      };
      service.releaseOverlay = () {
        if (overlayReady) releasedAfterReady++;
      };
      service.debugOnFfmpegLaunch = launches.add;

      final starting = service.startPublish(
        targetUrl: 'rtmp://example.com/live/key',
      );
      for (var i = 0; i < 20 && !prepareCalled; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(prepareCalled, isTrue);

      await service.stopPublish();
      overlayReady = true;
      gate.complete(
        const LivestreamOverlay(
          imagePath: '/tmp/overlay.png',
          width: 1280,
          height: 720,
        ),
      );
      await starting;
      await _settle();

      expect(launches, isEmpty);
      // Ảnh bảng tỉ số chuẩn bị xong SAU khi dừng vẫn được giải phóng.
      expect(releasedAfterReady, greaterThanOrEqualTo(1));
      expect(service.state, RtspPublishState.idle);
      service.dispose();
    });
  });

  group('Instant stream rates', () {
    test('uses deltas instead of whole-session averages', () {
      final rates = InstantStreamRates();
      final start = DateTime(2026, 10, 22, 20);
      // 10 phút phát ổn định 30 fps, 4000 kbps, speed 1.0x.
      const base = 600;
      ({double fps, double bitrateKbps, double speed})? result;
      result = rates.observe(
        now: start,
        frame: 30 * base,
        sizeBytes: 500000 * base,
        timeMs: 1000 * base,
      );
      expect(result, isNull);
      // Sau đó nghẽn: mỗi giây chỉ 15 khung, 1000 kbps, nửa giây media.
      for (var s = 1; s <= 4; s++) {
        result = rates.observe(
          now: start.add(Duration(seconds: s)),
          frame: 30 * base + 15 * s,
          sizeBytes: 500000 * base + 125000 * s,
          timeMs: 1000 * base + 500 * s,
        );
      }
      expect(result, isNotNull);
      expect(result!.fps, closeTo(15, 0.01));
      expect(result.bitrateKbps, closeTo(1000, 0.01));
      expect(result.speed, closeTo(0.5, 0.001));
    });

    test('needs a minimum span and keeps a sliding window', () {
      final rates = InstantStreamRates(window: const Duration(seconds: 3));
      final start = DateTime(2026, 10, 22, 20);
      expect(
        rates.observe(now: start, frame: 0, sizeBytes: 0, timeMs: 0),
        isNull,
      );
      expect(
        rates.observe(
          now: start.add(const Duration(milliseconds: 500)),
          frame: 15,
          sizeBytes: 15000,
          timeMs: 500,
        ),
        isNull,
      );
      // 0–5 s: 30 fps; 5–10 s: 10 fps. Cửa sổ 3 s chỉ thấy phần sau.
      ({double fps, double bitrateKbps, double speed})? last;
      for (var s = 1; s <= 10; s++) {
        final frames = s <= 5 ? 30 * s : 150 + 10 * (s - 5);
        last = rates.observe(
          now: start.add(Duration(seconds: s)),
          frame: frames,
          sizeBytes: frames * 1000,
          timeMs: 1000 * s,
        );
      }
      expect(last!.fps, closeTo(10, 0.01));
      expect(last.speed, closeTo(1.0, 0.001));
    });

    test('counter reset restarts the measurement', () {
      final rates = InstantStreamRates();
      final start = DateTime(2026, 10, 22, 20);
      rates.observe(now: start, frame: 1000, sizeBytes: 1e6, timeMs: 33000);
      rates.observe(
        now: start.add(const Duration(seconds: 2)),
        frame: 1060,
        sizeBytes: 2e6,
        timeMs: 35000,
      );
      expect(
        rates.observe(
          now: start.add(const Duration(seconds: 3)),
          frame: 5,
          sizeBytes: 1000,
          timeMs: 100,
        ),
        isNull,
      );
    });
  });

  group('Local source failures are not route failures', () {
    test('loopback source errors do not switch Wi-Fi/4G', () {
      const output =
          "[tcp @ 0x1] Connection to tcp://127.0.0.1:8554?timeout=0 failed: Connection refused\n"
          'rtsp://127.0.0.1:8554/camera: Connection refused';
      expect(isLocalSourceFailure(output), isTrue);
      expect(isRouteRelatedRelayFailure(output), isFalse);
      expect(
        isRouteRelatedRelayFailure('[rtsp @ 0x1] method DESCRIBE failed: 503'),
        isFalse,
      );
      expect(
        isRouteRelatedRelayFailure('rtsp://localhost:8554/camera: End of file'),
        isFalse,
      );
    });

    test('remote failures stay route related', () {
      const both =
          "Input #0, rtsp, from 'rtsp://127.0.0.1:8554/camera':\n"
          'rtmp://a.rtmp.youtube.com/live2/key: I/O error';
      expect(isLocalSourceFailure(both), isFalse);
      expect(isRouteRelatedRelayFailure(both), isTrue);
      expect(isRouteRelatedRelayFailure('Connection timed out'), isTrue);
      expect(isRouteRelatedRelayFailure(null), isTrue);
    });

    test('the 4G/5G relay on 127.0.0.1 is not the local source', () {
      const relay = 'rtmp://127.0.0.1:41234/live2/key';
      const output = 'rtmp://127.0.0.1:41234/live2/key: Connection refused';
      expect(isLocalSourceFailure(output, relayUrl: relay), isFalse);
      expect(isRouteRelatedRelayFailure(output, relayUrl: relay), isTrue);
      expect(
        remoteRelayDiagnosticText(output, relayUrl: relay),
        contains('Connection refused'),
      );
      // Không có URL relay thì dòng đó bị coi là nguồn cục bộ.
      expect(remoteRelayDiagnosticText(output), isNot(contains('refused')));
    });

    test('relay destination port comes from the real target URL', () {
      expect(relayDestinationPort('rtsp://media.aqvision.net:18554/live/k'),
          18554);
      expect(relayDestinationPort('rtmp://a.rtmp.youtube.com/live2/k'), 1935);
      expect(relayDestinationPort('rtmps://live-api-s.facebook.com/rtmp/k'),
          443);
      expect(relayDestinationPort('rtsp://h/live'), 554);
      expect(relayDestinationPort(''), isNull);
      expect(relayDestinationPort(null), isNull);
    });
  });

  group('Native overlay errors (C6)', () {
    test('recoverable errors restart with the scoreboard up to twice', () {
      final args = {'error': 'listener failed', 'recoverable': true};
      expect(isRecoverableNativeOverlayError(args), isTrue);
      expect(
        nativeOverlayErrorAction(args, restartsUsed: 0),
        NativeOverlayErrorAction.restartWithScoreboard,
      );
      expect(
        nativeOverlayErrorAction(args, restartsUsed: 1),
        NativeOverlayErrorAction.restartWithScoreboard,
      );
      expect(
        nativeOverlayErrorAction(args, restartsUsed: 2),
        NativeOverlayErrorAction.continueWithoutScoreboard,
      );
      expect(nativeOverlayRecoverableRestartLimit, 2);
    });

    test('missing or false recoverable means fall back', () {
      for (final args in <Object?>[
        {'error': 'vt failed', 'recoverable': false},
        {'error': 'old native'},
        {'error': 'string flag', 'recoverable': 'true'},
        null,
        'not a map',
      ]) {
        expect(isRecoverableNativeOverlayError(args), isFalse);
        expect(
          nativeOverlayErrorAction(args, restartsUsed: 0),
          NativeOverlayErrorAction.continueWithoutScoreboard,
        );
      }
    });
  });
}
