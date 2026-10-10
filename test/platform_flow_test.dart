import 'package:camera_station/services/camera_server.dart';
import 'package:camera_station/services/camera_station_runtime.dart';
import 'package:camera_station/services/recording_service.dart';
import 'package:camera_station/services/station_platform_events.dart';
import 'package:camera_station/services/webrtc_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _sendFromNative(String method, [Object? arguments]) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  await messenger.handlePlatformMessage(
    StationPlatformEvents.channel.name,
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)),
    (_) {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StationPlatformEvents', () {
    test('delivers every native callback to all listeners', () async {
      final events = StationPlatformEvents.instance;
      final service = Object();
      final screen = Object();
      final serviceCalls = <String>[];
      final screenCalls = <String>[];
      events.addListener(
        service,
        (call) async => serviceCalls.add(call.method),
      );
      events.addListener(screen, (call) async => screenCalls.add(call.method));
      addTearDown(() {
        events.removeListener(service);
        events.removeListener(screen);
      });

      await _sendFromNative('onRtspEncoderConfigured');
      await _sendFromNative('onDisplayRotationChanged', {
        'effectiveRotation': 90,
      });

      expect(serviceCalls, [
        'onRtspEncoderConfigured',
        'onDisplayRotationChanged',
      ]);
      expect(screenCalls, [
        'onRtspEncoderConfigured',
        'onDisplayRotationChanged',
      ]);
    });

    test('a failing listener does not block the others', () async {
      final events = StationPlatformEvents.instance;
      final failing = Object();
      final healthy = Object();
      var delivered = 0;
      events.addListener(failing, (_) async => throw StateError('boom'));
      events.addListener(healthy, (_) async => delivered++);
      addTearDown(() {
        events.removeListener(failing);
        events.removeListener(healthy);
      });

      await _sendFromNative('onAndroidTaskRemoved');
      expect(delivered, 1);
    });

    test('removed listeners no longer receive callbacks', () async {
      final events = StationPlatformEvents.instance;
      final owner = Object();
      var delivered = 0;
      events.addListener(owner, (_) async => delivered++);
      events.removeListener(owner);

      await _sendFromNative('onPictureInPictureModeChanged', {'inPip': true});
      expect(delivered, 0);
    });
  });

  group('CameraServer recording requests', () {
    CameraServer buildServer() => CameraServer(
      courtId: 'COURT-1',
      cameraId: 'CAM1',
      deviceId: 'DEVICE-1',
      webRtcService: WebRtcService(),
      recordingService: RecordingService(cameraId: 'CAM1'),
    );

    test('a Tablet stop keeps recording stopped until it asks again', () async {
      final server = buildServer();
      await server.stopRecordingByRequest();
      expect(server.stoppedByRequest, isTrue);

      // Health monitor / camera recovery call ensureRecording: it must not
      // restart recording (no camera access is attempted).
      await server.ensureRecording();
      expect(server.recording, isFalse);
    });

    test('a Tablet start clears the stop and tries to record again', () async {
      final server = buildServer();
      await server.stopRecordingByRequest();

      // No camera in unit tests: reaching the recorder proves the gate opened.
      await expectLater(server.resumeRecordingByRequest(), throwsStateError);
      expect(server.stoppedByRequest, isFalse);
    });
  });

  group('periodic storage enforcement', () {
    final now = DateTime(2026, 10, 9, 21);

    test('runs on first use and when storage is low', () {
      expect(
        shouldRunPeriodicStorageEnforcement(
          lowStorage: false,
          lastRun: null,
          now: now,
        ),
        isTrue,
      );
      expect(
        shouldRunPeriodicStorageEnforcement(
          lowStorage: true,
          lastRun: now.subtract(const Duration(seconds: 30)),
          now: now,
        ),
        isTrue,
      );
    });

    test('skips full scans that ran recently', () {
      expect(
        shouldRunPeriodicStorageEnforcement(
          lowStorage: false,
          lastRun: now.subtract(const Duration(minutes: 3)),
          now: now,
        ),
        isFalse,
      );
      expect(
        shouldRunPeriodicStorageEnforcement(
          lowStorage: false,
          lastRun: now.subtract(const Duration(minutes: 10)),
          now: now,
        ),
        isTrue,
      );
    });
  });
}
