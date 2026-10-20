import 'dart:async';

import 'package:camera_station/services/rtsp_publisher_service.dart';
import 'package:camera_station/services/station_config_service.dart';
import 'package:flutter/services.dart';
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

      await service.startPublish(targetUrl: '   ');

      expect(service.state, RtspPublishState.error);
      expect(service.currentError, contains('Chưa nhập URL đích'));
      expect(states, contains(RtspPublishState.error));

      await sub.cancel();
      service.dispose();
    });

    test('localizedError is null when there is no error', () {
      final service = RtspPublisherService();
      expect(service.localizedError(english: false), isNull);
      expect(service.localizedError(english: true), isNull);
      service.dispose();
    });

    test('localizedError returns Vietnamese and English messages', () async {
      final service = RtspPublisherService();
      await service.startPublish(targetUrl: '   ');

      expect(
        service.localizedError(english: false),
        contains('Chưa nhập URL đích'),
      );
      expect(
        service.localizedError(english: false),
        service.currentError,
      );
      expect(
        service.localizedError(english: true),
        contains('No destination URL'),
      );

      await service.startPublish(targetUrl: 'http://invalid-scheme.com/live');
      expect(
        service.localizedError(english: false),
        contains('URL không đúng định dạng'),
      );
      expect(
        service.localizedError(english: true),
        contains('rtsp:// or rtmp://'),
      );
      service.dispose();
    });

    test('startPublish with invalid scheme sets error state', () async {
      final service = RtspPublisherService();
      await service.startPublish(targetUrl: 'http://invalid-scheme.com/live');

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

    test(
      'restartIfPublishing does not restart after the user stopped',
      () async {
        final service = RtspPublisherService();
        await service.stopPublish();
        await service.restartIfPublishing();
        expect(service.state, RtspPublishState.idle);
        expect(service.wantsPublishing, isFalse);
        service.dispose();
      },
    );

    test('adaptive bitrate lowers after sustained congestion', () {
      final controller = LiveBitrateController(maximumBps: 5000000);
      final start = DateTime(2026, 10, 8, 20);
      controller.beginSession(start.subtract(const Duration(seconds: 10)));
      int? changed;
      for (var second = 0; second <= 3; second++) {
        changed = controller.observe(
          speed: 0.8,
          fps: 22,
          expectedFps: 30,
          now: start.add(Duration(seconds: second)),
        );
      }
      expect(changed, 3750000);
      expect(controller.targetBps, 3750000);
    });

    test(
      'adaptive bitrate ignores short hiccups and never drops below floor',
      () {
        final controller = LiveBitrateController(maximumBps: 3000000);
        final start = DateTime(2026, 10, 8, 20);
        controller.beginSession(start.subtract(const Duration(seconds: 10)));
        expect(
          controller.observe(speed: 0.5, fps: 10, expectedFps: 30, now: start),
          isNull,
        );
        var now = start;
        for (var step = 0; step < 40; step++) {
          now = now.add(const Duration(seconds: 1));
          controller.observe(speed: 0.5, fps: 10, expectedFps: 30, now: now);
        }
        expect(controller.targetBps, controller.minimumBps);
        expect(controller.minimumBps, 900000);
      },
    );

    test('adaptive bitrate recovers gradually after stable upload', () {
      final controller = LiveBitrateController(maximumBps: 5000000);
      final start = DateTime(2026, 10, 8, 20);
      controller.beginSession(start.subtract(const Duration(seconds: 10)));
      for (var second = 0; second <= 3; second++) {
        controller.observe(
          speed: 0.8,
          fps: 20,
          expectedFps: 30,
          now: start.add(Duration(seconds: second)),
        );
      }
      expect(controller.targetBps, 3750000);
      var now = start.add(const Duration(seconds: 4));
      int? raised;
      for (var second = 0; second <= 40 && raised == null; second++) {
        now = now.add(const Duration(seconds: 1));
        raised = controller.observe(
          speed: 1.0,
          fps: 30,
          expectedFps: 30,
          now: now,
        );
      }
      expect(raised, 4125000);
      controller.reset();
      expect(controller.targetBps, 5000000);
    });

    test('network change does not resurrect a stopped stream', () async {
      final service = RtspPublisherService();
      await service.stopPublish();
      service.handleNetworkChange(interfaceLost: true);
      expect(service.state, RtspPublishState.idle);
      service.dispose();
    });

    test('server rejections do not switch Wi-Fi/4G routes', () {
      expect(
        isRouteRelatedRelayFailure('Server returned 401 Unauthorized'),
        isFalse,
      );
      expect(
        isRouteRelatedRelayFailure('rtmp: NetStream.Publish.BadName'),
        isFalse,
      );
      expect(isRouteRelatedRelayFailure('Connection timed out'), isTrue);
      expect(isRouteRelatedRelayFailure('Connection refused'), isTrue);
      expect(isRouteRelatedRelayFailure(null), isTrue);
    });

    test('network quality starts unknown', () {
      final service = RtspPublisherService()..expectedFps = 15;
      expect(service.networkQuality, StreamNetworkQuality.unknown);
      service.dispose();
    });
  });

  group('Relay rejection and LIVE detection', () {
    test('server rejections stop automatic retries', () {
      expect(
        isPermanentRelayRejection('rtmp://a/live/k: Server returned 401 Unauthorized'),
        isTrue,
      );
      expect(isPermanentRelayRejection('Server returned 403 Forbidden'), isTrue);
      expect(
        isPermanentRelayRejection('[rtmp @ 0x1] Server error: NetStream.Publish.BadName'),
        isTrue,
      );
    });

    test('network failures keep retrying', () {
      expect(isPermanentRelayRejection('Connection timed out'), isFalse);
      expect(isPermanentRelayRejection('Connection refused'), isFalse);
      expect(isPermanentRelayRejection(null), isFalse);
      expect(isPermanentRelayRejection(''), isFalse);
      // Số trong dòng tiến trình không phải mã lỗi máy chủ.
      expect(
        isPermanentRelayRejection(
          'frame= 4010 fps= 30 size= 14012kB time=00:02:13.66 '
          'bitrate= 401.0kbits/s speed=1.0x\nBroken pipe',
        ),
        isFalse,
      );
    });

    test('local source 404 is not a server rejection', () {
      expect(
        isPermanentRelayRejection(
          'rtsp://127.0.0.1:8554/camera: Server returned 404 Not Found',
        ),
        isFalse,
      );
      expect(
        isPermanentRelayRejection(
          '[rtsp @ 0x1] method SETUP failed: 404 Not Found',
        ),
        isFalse,
      );
    });

    test('parses FFmpeg progress frame counters', () {
      expect(ffmpegProgressFrame('frame=  123 fps= 30 q=-1.0'), 123);
      expect(ffmpegProgressFrame("Output #0, flv, to 'rtmp://h/live/k':"), isNull);
    });

    test('LIVE only after frames keep increasing for ~3 seconds', () {
      final gate = RelayProgressGate();
      final start = DateTime(2026, 10, 20, 9);
      expect(gate.observe(0, start), isFalse);
      expect(gate.observe(30, start.add(const Duration(seconds: 1))), isFalse);
      expect(gate.observe(60, start.add(const Duration(seconds: 2))), isFalse);
      expect(gate.observe(90, start.add(const Duration(seconds: 3))), isTrue);
      expect(gate.confirmed, isTrue);
      // Chỉ báo một lần.
      expect(gate.observe(120, start.add(const Duration(seconds: 4))), isFalse);
    });

    test('stalled frame counter is not LIVE', () {
      final gate = RelayProgressGate();
      final start = DateTime(2026, 10, 20, 9);
      gate.observe(10, start);
      expect(gate.observe(10, start.add(const Duration(seconds: 5))), isFalse);
      expect(gate.confirmed, isFalse);
    });

    test('duration listenable starts at zero', () {
      final service = RtspPublisherService();
      expect(service.durationListenable.value, Duration.zero);
      expect(service.metricsListenable.value, 0);
      service.dispose();
    });
  });

  group('iOS native scoreboard overlay (C5)', () {
    test('FFmpeg copies the overlay stream and takes audio from the main one', () {
      final args = nativeOverlayRelayInputArgs(
        overlayUrl: nativeOverlayRtspUrl,
        audioSourceUrl: 'rtsp://127.0.0.1:8554/camera',
      );
      expect(nativeOverlayRtspUrl, 'rtsp://127.0.0.1:8555/camera');
      // Hai input: 0 = luồng overlay native, 1 = luồng RTSP chính.
      final inputs = <String>[
        for (var i = 0; i < args.length - 1; i++)
          if (args[i] == '-i') args[i + 1],
      ];
      expect(inputs, [
        'rtsp://127.0.0.1:8555/camera',
        'rtsp://127.0.0.1:8554/camera',
      ]);
      // Mỗi input đọc RTSP cục bộ qua TCP với timeout như đường thường.
      expect(
        args,
        containsAllInOrder([
          '-rtsp_transport', 'tcp', '-timeout', '10000000',
          '-i', 'rtsp://127.0.0.1:8555/camera',
          '-rtsp_transport', 'tcp', '-timeout', '10000000',
          '-i', 'rtsp://127.0.0.1:8554/camera',
          '-map', '0:v:0', '-c:v', 'copy',
        ]),
      );
      // Không bộ lọc, không mã hoá lại video.
      expect(args, isNot(contains('-filter_complex')));
      expect(args.any((arg) => arg.contains('videotoolbox')), isFalse);
      expect(args, isNot(contains('h264_mediacodec')));
      expect(args, isNot(contains('-hwaccel')));
      expect(livestreamAudioMapArg(nativeOverlay: true), '1:a?');
    });

    test('Android/plain relay keeps audio from input 0', () {
      expect(livestreamAudioMapArg(nativeOverlay: false), '0:a?');
      expect(localRtspCopyInputArgs('rtsp://a/camera'), [
        '-thread_queue_size',
        '4096',
        '-fflags',
        '+genpts+nobuffer+discardcorrupt',
        '-flags',
        'low_delay',
        '-correct_ts_overflow',
        '1',
        '-rtsp_transport',
        'tcp',
        '-buffer_size',
        '4096000',
        '-timeout',
        '10000000',
        '-i',
        'rtsp://a/camera',
      ]);
    });

    test('startOverlayRtsp is called with the C5 arguments', () async {
      String? method;
      Map<String, Object?>? arguments;
      final error = await startNativeOverlayRtsp(
        (name, args) async {
          method = name;
          arguments = args;
          return true;
        },
        trackId: 'track-1',
        bitrateBps: 4000000,
        fps: 30,
        overlayPath: '/tmp/overlay.png',
      );
      expect(error, isNull);
      expect(method, 'startOverlayRtsp');
      expect(arguments, {
        'trackId': 'track-1',
        'port': 8555,
        'bitrate': 4000000,
        'fps': 30,
        'overlayPath': '/tmp/overlay.png',
      });
    });

    test('start failures fall back to publishing without the scoreboard', () async {
      Future<String?> start(NativeOverlayInvoker invoke) => startNativeOverlayRtsp(
        invoke,
        trackId: 't',
        bitrateBps: 1000000,
        fps: 30,
        overlayPath: '/tmp/o.png',
        timeout: const Duration(milliseconds: 20),
      );
      final platformError = await start(
        (_, _) async => throw PlatformException(
          code: 'OVERLAY_RTSP_FAILED',
          message: 'encoder',
        ),
      );
      expect(platformError, contains('OVERLAY_RTSP_FAILED'));
      // Native chưa cài method (bản iOS cũ).
      expect(
        await start((_, _) async => throw MissingPluginException()),
        isNotNull,
      );
      // Native không trả lời: hết thời gian chờ, không treo.
      expect(
        await start((_, _) => Completer<Object?>().future),
        contains('timed out'),
      );
      expect(await start((_, _) async => false), isNotNull);
      expect(await start((_, _) async => null), isNotNull);
      expect(nativeOverlayStartTimeout, const Duration(seconds: 8));
    });

    test('only unreadable overlay streams count as native overlay failures', () {
      expect(
        isNativeOverlaySourceFailure(
          'rtsp://127.0.0.1:8555/camera: Connection refused',
        ),
        isTrue,
      );
      expect(
        isNativeOverlaySourceFailure(
          'rtsp://127.0.0.1:8555/camera: Server returned 404 Not Found',
        ),
        isTrue,
      );
      expect(
        isNativeOverlaySourceFailure(
          "Input #0, rtsp, from 'rtsp://127.0.0.1:8555/camera':\n"
          'rtmp://a.rtmp.youtube.com/live2/key: I/O error',
        ),
        isFalse,
      );
      expect(
        isNativeOverlaySourceFailure(
          'rtsp://127.0.0.1:8554/camera: Connection refused',
        ),
        isFalse,
      );
      expect(isNativeOverlaySourceFailure(null), isFalse);
      // Lỗi luồng overlay cục bộ không phải server phát từ chối.
      expect(
        isPermanentRelayRejection(
          'rtsp://127.0.0.1:8555/camera: Server returned 404 Not Found',
        ),
        isFalse,
      );
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
