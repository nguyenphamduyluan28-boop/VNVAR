import 'package:camera_station/services/recording_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('publishes only video probes lasting at least one second', () {
    expect(
      isPublishableVideoProbe(hasVideo: true, durationSeconds: 1.0),
      isTrue,
    );
    expect(
      isPublishableVideoProbe(hasVideo: true, durationSeconds: 0.67),
      isFalse,
    );
    expect(
      isPublishableVideoProbe(hasVideo: false, durationSeconds: 10),
      isFalse,
    );
  });

  test('preserves a decodable sub-second video without publishing it', () {
    expect(
      isDecodableVideoProbe(hasVideo: true, durationSeconds: 0.67),
      isTrue,
    );
    expect(
      isPublishableVideoProbe(hasVideo: true, durationSeconds: 0.67),
      isFalse,
    );
  });

  test('uses the previous segment only near a recorder boundary', () {
    final requestedAt = DateTime(2026, 9, 4, 10, 0, 1);

    expect(
      shouldUsePreviousCheckpointSegment(
        currentStartedAt: requestedAt.subtract(
          const Duration(milliseconds: 900),
        ),
        requestedAt: requestedAt,
      ),
      isTrue,
    );
    expect(
      shouldUsePreviousCheckpointSegment(
        currentStartedAt: requestedAt.subtract(const Duration(seconds: 10)),
        requestedAt: requestedAt,
      ),
      isFalse,
    );
  });

  test('fragment cleanup includes video, audio and metadata', () {
    expect(
      fragmentCompanionPaths('/VNVAR/04-09-2026/AUTOMODE/FRAGMENTS/F1.mp4'),
      [
        '/VNVAR/04-09-2026/AUTOMODE/FRAGMENTS/F1.mp4',
        '/VNVAR/04-09-2026/AUTOMODE/FRAGMENTS/F1.wav',
        '/VNVAR/04-09-2026/AUTOMODE/FRAGMENTS/F1.json',
      ],
    );
    expect(
      isManagedStorageFilePath('/VNVAR/04-09-2026/AUTOMODE/FRAGMENTS/F1.wav'),
      isTrue,
    );
  });

  test('starts with no active segment audio', () {
    final service = RecordingService(cameraId: 'CAM-01');

    expect(service.recording, isFalse);
    expect(service.rotating, isFalse);
    expect(service.currentSegmentHasAudio, isFalse);
    expect(service.segments, isEmpty);
    expect(service.segmentDuration, const Duration(minutes: 3));
    expect(service.segmentMinutes, 3);
  });

  test('stop is safe and idempotent when recording is not active', () async {
    final service = RecordingService(cameraId: 'CAM-01');

    expect(await service.stop(), isNull);
    expect(await service.stop(), isNull);
    expect(service.recording, isFalse);
    expect(service.currentSegmentHasAudio, isFalse);
  });
}
