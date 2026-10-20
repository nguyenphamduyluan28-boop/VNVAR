import 'package:camera_station/models/camera_resolution_profile.dart';
import 'package:camera_station/services/camera_station_runtime.dart';
import 'package:camera_station/services/station_errors.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

bool _reconnect({
  bool first = false,
  String? previous = '192.168.1.10',
  String? address = '192.168.1.10',
  bool failed = false,
  DateTime? retryAt,
  DateTime? now,
}) => shouldReconnectNetworkServices(
  firstObservation: first,
  previousAddress: previous,
  address: address,
  lastReconnectFailed: failed,
  retryNotBefore: retryAt,
  now: now ?? DateTime(2026, 1, 1, 12),
);

bool _recovery({
  bool stopping = false,
  bool cameraEnabled = true,
  bool superseded = false,
  bool thermalSuspended = false,
  bool thermalSuspendPending = false,
  bool iosSuspended = false,
  bool scannerActive = false,
}) => cameraRecoveryMayProceed(
  stopping: stopping,
  cameraEnabled: cameraEnabled,
  superseded: superseded,
  thermalSuspended: thermalSuspended,
  thermalSuspendPending: thermalSuspendPending,
  iosSuspended: iosSuspended,
  scannerActive: scannerActive,
);

bool _coolEnough({
  bool hot = false,
  bool cool = false,
  double? temperatureC,
}) => thermalRestoreCoolEnough(
  hot: hot,
  cool: cool,
  temperatureC: temperatureC,
  maxTemperatureC: 40.0,
);

void main() {
  group('cameraRecoveryMayProceed', () {
    test('proceeds when nothing blocks the camera', () {
      expect(_recovery(), isTrue);
    });

    test('thermal suspend (active or pending) blocks every attempt', () {
      expect(_recovery(thermalSuspended: true), isFalse);
      expect(_recovery(thermalSuspendPending: true), isFalse);
    });

    test('stop, disabled camera or a superseded recovery stops it', () {
      expect(_recovery(stopping: true), isFalse);
      expect(_recovery(cameraEnabled: false), isFalse);
      expect(_recovery(superseded: true), isFalse);
    });

    test('iOS background and QR scanner block reopening', () {
      expect(_recovery(iosSuspended: true), isFalse);
      expect(_recovery(scannerActive: true), isFalse);
    });
  });

  group('thermalRestoreCoolEnough', () {
    test('OS cool state allows restore when the battery is not warm', () {
      expect(_coolEnough(cool: true), isTrue);
      expect(_coolEnough(cool: true, temperatureC: 38.5), isTrue);
      expect(_coolEnough(cool: true, temperatureC: 40.0), isTrue);
      expect(_coolEnough(cool: true, temperatureC: 40.5), isFalse);
    });

    test('prolonged Android MODERATE allows restore at <= 40 C', () {
      expect(_coolEnough(temperatureC: 39.0), isTrue);
      expect(_coolEnough(temperatureC: 40.0), isTrue);
      expect(_coolEnough(temperatureC: 41.0), isFalse);
    });

    test('MODERATE without a battery temperature does not restore', () {
      expect(_coolEnough(), isFalse);
    });

    test('SEVERE or higher never restores', () {
      expect(_coolEnough(hot: true, temperatureC: 35.0), isFalse);
      expect(_coolEnough(hot: true, cool: true), isFalse);
    });
  });

  group('shouldReconnectNetworkServices', () {
    test('same IP and no failed recovery never reconnects', () {
      expect(_reconnect(), isFalse);
    });

    test('a real IP change reconnects immediately', () {
      expect(_reconnect(address: '192.168.1.20'), isTrue);
      expect(_reconnect(previous: null, address: '10.0.0.5'), isTrue);
    });

    test('first observation or missing address never reconnects', () {
      expect(_reconnect(first: true, address: '192.168.1.20'), isFalse);
      expect(_reconnect(address: null), isFalse);
      expect(_reconnect(address: null, failed: true), isFalse);
    });

    test('failed recovery retries only after its backoff', () {
      final now = DateTime(2026, 1, 1, 12);
      expect(
        _reconnect(
          failed: true,
          retryAt: now.add(const Duration(seconds: 3)),
          now: now,
        ),
        isFalse,
      );
      expect(_reconnect(failed: true, retryAt: now, now: now), isTrue);
      expect(
        _reconnect(
          failed: true,
          retryAt: now.subtract(const Duration(seconds: 1)),
          now: now,
        ),
        isTrue,
      );
      expect(_reconnect(failed: true, now: now), isTrue);
    });

    test('an IP change ignores the pending backoff', () {
      final now = DateTime(2026, 1, 1, 12);
      expect(
        _reconnect(
          address: '192.168.1.20',
          failed: true,
          retryAt: now.add(const Duration(minutes: 1)),
          now: now,
        ),
        isTrue,
      );
    });
  });

  group('networkReconnectRetryDelay', () {
    test('backs off 5 s, 15 s, then 60 s', () {
      expect(networkReconnectRetryDelay(1), const Duration(seconds: 5));
      expect(networkReconnectRetryDelay(2), const Duration(seconds: 15));
      expect(networkReconnectRetryDelay(3), const Duration(seconds: 60));
      expect(networkReconnectRetryDelay(10), const Duration(seconds: 60));
    });
  });

  group('initRetryDelay', () {
    test('backs off 5/15/30 s then stays at 60 s', () {
      expect(initRetryDelay(0), const Duration(seconds: 5));
      expect(initRetryDelay(1), const Duration(seconds: 15));
      expect(initRetryDelay(2), const Duration(seconds: 30));
      expect(initRetryDelay(3), const Duration(seconds: 60));
      expect(initRetryDelay(50), const Duration(seconds: 60));
      expect(initRetryDelay(-1), const Duration(seconds: 5));
    });
  });

  group('isRetryableInitError', () {
    test('permission errors are not retried', () {
      expect(
        isRetryableInitError(
          PlatformException(
            code: 'GetUserMediaFailed',
            message: 'Permission denied',
          ),
        ),
        isFalse,
      );
      expect(
        isRetryableInitError(Exception('getUserMedia(): NotAllowedError')),
        isFalse,
      );
      expect(
        isRetryableInitError(
          StationException.fromCode(StationErrorCode.permissionDenied),
        ),
        isFalse,
      );
    });

    test('transient failures are retried', () {
      expect(isRetryableInitError(Exception('Camera busy')), isTrue);
      expect(
        isRetryableInitError(
          StationException.fromCode(StationErrorCode.operationTimeout),
        ),
        isTrue,
      );
      expect(isRetryableInitError(StateError('server bind failed')), isTrue);
    });
  });

  group('initializeEntryAction', () {
    InitializeEntryAction action({
      bool restart = false,
      bool serverRunning = true,
      bool initCompleted = true,
      bool sameIdentity = true,
    }) => initializeEntryAction(
      restart: restart,
      serverRunning: serverRunning,
      initCompleted: initCompleted,
      sameIdentity: sameIdentity,
    );

    test('skips only a fully initialized runtime for the same station', () {
      expect(action(), InitializeEntryAction.skip);
    });

    test('server running after a timed-out init is not treated as ready', () {
      expect(
        action(initCompleted: false),
        InitializeEntryAction.stopThenInitialize,
      );
      expect(
        action(initCompleted: false, sameIdentity: false),
        InitializeEntryAction.stopThenInitialize,
      );
    });

    test('restart always cleans up first', () {
      expect(action(restart: true), InitializeEntryAction.stopThenInitialize);
      expect(
        action(restart: true, serverRunning: false, initCompleted: false),
        InitializeEntryAction.stopThenInitialize,
      );
    });

    test('initializes when the server is down or the station changed', () {
      expect(action(serverRunning: false), InitializeEntryAction.initialize);
      expect(
        action(serverRunning: false, initCompleted: false),
        InitializeEntryAction.initialize,
      );
      expect(action(sameIdentity: false), InitializeEntryAction.initialize);
    });
  });

  group('shouldExitCriticalDegrade', () {
    test('needs consecutive non-critical readings', () {
      expect(
        shouldExitCriticalDegrade(degraded: true, nonCriticalStreak: 1),
        isFalse,
      );
      expect(
        shouldExitCriticalDegrade(degraded: true, nonCriticalStreak: 2),
        isFalse,
      );
      expect(
        shouldExitCriticalDegrade(
          degraded: true,
          nonCriticalStreak: thermalConfirmationReadings,
        ),
        isTrue,
      );
    });

    test('nothing to exit when not degraded', () {
      expect(
        shouldExitCriticalDegrade(degraded: false, nonCriticalStreak: 10),
        isFalse,
      );
    });
  });

  group('cameraOpenBlockReason', () {
    test('allows opening when nothing holds the camera', () {
      expect(
        cameraOpenBlockReason(
          thermalSuspended: false,
          iosSuspended: false,
          scannerActive: false,
        ),
        isNull,
      );
    });

    test('thermal emergency takes priority', () {
      expect(
        cameraOpenBlockReason(
          thermalSuspended: true,
          iosSuspended: true,
          scannerActive: true,
        ),
        StationErrorCode.thermalSuspended,
      );
    });

    test('iOS background and QR scanner block opening', () {
      expect(
        cameraOpenBlockReason(
          thermalSuspended: false,
          iosSuspended: true,
          scannerActive: true,
        ),
        StationErrorCode.iosSuspended,
      );
      expect(
        cameraOpenBlockReason(
          thermalSuspended: false,
          iosSuspended: false,
          scannerActive: true,
        ),
        StationErrorCode.scannerActive,
      );
    });
  });

  group('resolveSupportedResolutionProfile', () {
    final supported = [
      CameraResolutionProfile.hd720,
      CameraResolutionProfile.fullHd1080,
      CameraResolutionProfile.fullHd1080.withFps(60),
    ];

    test('matches preset and FPS exactly', () {
      final selected = resolveSupportedResolutionProfile(
        supported,
        CameraResolutionProfile.fullHd1080.withFps(60),
      );
      expect(selected?.preset, CameraResolutionPreset.fullHd1080);
      expect(selected?.fps, 60);
    });

    test('falls back to the same preset with a capped FPS', () {
      final selected = resolveSupportedResolutionProfile(
        supported,
        CameraResolutionProfile.hd720.withFps(60),
      );
      expect(selected?.preset, CameraResolutionPreset.hd720);
      expect(selected?.fps, 30);
    });

    test('rejects an unsupported preset', () {
      expect(
        resolveSupportedResolutionProfile(
          supported,
          CameraResolutionProfile.ultraHd4k,
        ),
        isNull,
      );
    });

    test('load compares pixels and FPS', () {
      expect(
        resolutionProfileLoad(CameraResolutionProfile.fullHd1080) >
            resolutionProfileLoad(CameraResolutionProfile.hd720),
        isTrue,
      );
      expect(
        resolutionProfileLoad(CameraResolutionProfile.hd720.withFps(60)) >
            resolutionProfileLoad(CameraResolutionProfile.hd720),
        isTrue,
      );
    });
  });

  group('StationException', () {
    test('toString keeps the Vietnamese message', () {
      final error = StationException.fromCode(
        StationErrorCode.resolutionLocked,
      );
      expect(error.toString(), 'Chế độ phân giải đang bị khóa.');
      expect(
        stationErrorMessage(error, english: true),
        'The resolution setting is locked.',
      );
    });

    test('every code has both messages', () {
      for (final code in StationErrorCode.values) {
        final error = StationException.fromCode(code);
        expect(error.messageVi, isNotEmpty, reason: code.name);
        expect(error.messageEn, isNotEmpty, reason: code.name);
      }
    });

    test('raw permission errors map to the permission message', () {
      expect(
        stationErrorMessage(
          Exception('Permission denied by user'),
          english: true,
        ),
        StationException.fromCode(
          StationErrorCode.permissionDenied,
        ).messageEn,
      );
    });

    test('other errors drop the Dart prefix', () {
      expect(
        stationErrorMessage(StateError('Máy chủ lỗi'), english: false),
        'Máy chủ lỗi',
      );
      expect(
        stationErrorMessage(Exception('Server failed'), english: true),
        'Server failed',
      );
    });
  });
}
