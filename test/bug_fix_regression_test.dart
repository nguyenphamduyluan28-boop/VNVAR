import 'package:camera_station/models/camera_resolution_profile.dart';
import 'package:camera_station/services/camera_server.dart';
import 'package:camera_station/services/camera_station_runtime.dart';
import 'package:camera_station/services/cellular_uplink_service.dart';
import 'package:camera_station/services/recording_service.dart';
import 'package:camera_station/services/rtsp_publisher_service.dart';
import 'package:camera_station/utils/stream_url_parser.dart';
import 'package:camera_station/widgets/qr_stream_scanner_dialog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FFmpeg failure classification', () {
    test('progress lines with 401/404 numbers are not server rejections', () {
      const output =
          'frame= 4010 fps= 30 q=-1.0 size=   14012kB time=00:02:13.66 '
          'bitrate= 401.0kbits/s speed=1.0x\n'
          'Connection timed out';
      expect(isRouteRelatedRelayFailure(output), isTrue);
      expect(ffmpegServerRejectionCode(ffmpegDiagnosticText(output)), isNull);
    });

    test('real server rejections are still detected', () {
      expect(
        ffmpegServerRejectionCode('Server returned 401 Unauthorized'),
        401,
      );
      expect(ffmpegServerRejectionCode('HTTP error 404 Not Found'), 404);
      expect(isRouteRelatedRelayFailure('Server returned 403 Forbidden'), isFalse);
    });

    test('stream keys are masked in logs', () {
      expect(
        maskStreamUrlForLog('rtmp://a.rtmp.youtube.com/live2/abcd-1234-efgh'),
        'rtmp://a.rtmp.youtube.com/live2/abcd…',
      );
      expect(
        maskStreamUrlForLog('rtmps://live-api-s.facebook.com:443/rtmp/FB-KEY?s=1'),
        'rtmps://live-api-s.facebook.com:443/rtmp/FB-K…',
      );
      expect(maskStreamUrlForLog(null), '');
    });
  });

  group('QR auto-start destinations', () {
    test('public platforms need confirmation; partner and local servers start automatically', () {
      expect(
        isTrustedAutoStartDestination('rtmp://a.rtmp.youtube.com/live2/k'),
        isFalse,
      );
      expect(
        isTrustedAutoStartDestination('rtmps://live-api-s.facebook.com:443/rtmp/k'),
        isFalse,
      );
      expect(
        isTrustedAutoStartDestination('rtmp://push-rtmp-l11.tiktokcdn.com/game/k'),
        isFalse,
      );
      expect(
        isTrustedAutoStartDestination('rtmp://media.aqvision.net:11935/live/cam1'),
        isTrue,
      );
      expect(
        isTrustedAutoStartDestination('http://192.168.1.20:8889/cam/whip'),
        isTrue,
      );
    });

    test('unknown or look-alike servers need confirmation', () {
      expect(isTrustedAutoStartDestination('rtmp://evil.example/live/k'), isFalse);
      expect(
        isTrustedAutoStartDestination('rtmp://evilyoutube.com/live/k'),
        isFalse,
      );
      expect(isTrustedAutoStartDestination('rtmp://8.8.8.8/live/k'), isFalse);
    });
  });

  group('/start during camera transitions', () {
    test('transitional capture states defer recorder start', () {
      expect(captureStateBlocksRecorderStart('profile_switching'), isTrue);
      expect(captureStateBlocksRecorderStart('recovering'), isTrue);
      expect(captureStateBlocksRecorderStart('lifecycle_suspended'), isTrue);
      expect(captureStateBlocksRecorderStart('thermal_suspended'), isTrue);
      expect(captureStateBlocksRecorderStart('ready'), isFalse);
      expect(captureStateBlocksRecorderStart('recording'), isFalse);
      expect(captureStateBlocksRecorderStart(null), isFalse);
    });
  });

  group('resolution profiles', () {
    test('startup keeps the saved FPS (1080p60 stays 1080p60)', () {
      final supported = [
        CameraResolutionProfile.hd720.withFps(30),
        CameraResolutionProfile.fullHd1080.withFps(30),
        CameraResolutionProfile.fullHd1080.withFps(60),
      ];
      final picked = selectStartupResolutionProfile(
        supported,
        CameraResolutionProfile.fullHd1080.withFps(60),
      );
      expect(picked.preset, CameraResolutionPreset.fullHd1080);
      expect(picked.fps, 60);
      expect(
        selectStartupResolutionProfile(supported, null).preset,
        CameraResolutionPreset.fullHd1080,
      );
    });

    test('withFps does not compound bitrate adjustments', () {
      final sixty = CameraResolutionProfile.fullHd1080.withFps(60);
      expect(sixty.bitrate, 10000000);
      expect(sixty.withFps(30).bitrate, 8000000);
      expect(sixty.withFps(60).bitrate, 10000000);
    });
  });

  test('source-change rotation is a no-op when not recording', () async {
    final recording = RecordingService(cameraId: 'CAM-01');
    var called = false;
    final segment = await recording.rotateSegmentForSourceChange(
      onRecorderStopped: () async => called = true,
    );
    // Runtime dựa vào điều này để đổi camera trực tiếp khi không có đoạn nào.
    expect(segment, isNull);
    expect(called, isFalse);
  });

  test('FFmpeg error lines shown on screen hide the stream key', () {
    expect(
      maskStreamUrlsInText(
        'rtmp://a.rtmp.youtube.com/live2/abcd-1234-efgh: I/O error',
      ),
      'rtmp://a.rtmp.youtube.com/live2/abcd…: I/O error',
    );
    expect(maskStreamUrlsInText('Connection timed out'), 'Connection timed out');
  });

  test('QR shorthand only applies to "name?key=value", not full URLs', () {
    expect(
      QrStreamParseResult.parse('court1_cam?key=pk_1')?.streamUrl,
      'rtmp://media.aqvision.net:11935/live/court1_cam?key=pk_1',
    );
    expect(QrStreamParseResult.parse('https://example.com/x?key=1'), isNull);
  });

  test('4G relay keeps URL credentials', () {
    final target = buildCellularRelayTarget(
      'rtsp://user:secret@relay.example.com:8554/live/cam1',
      40125,
    );
    expect(target.url, 'rtsp://user:secret@127.0.0.1:40125/live/cam1');
  });
}
