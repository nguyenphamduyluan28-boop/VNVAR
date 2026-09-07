import 'dart:io';

import 'package:camera_station/services/recording_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rotation delay corrects drift after a delayed callback', () {
    final startedAt = DateTime(2026, 9, 7, 10);
    expect(
      nextSegmentRotationDelay(
        startedAt: startedAt,
        now: startedAt.add(const Duration(minutes: 2, seconds: 30)),
        segmentDuration: const Duration(minutes: 3),
      ),
      const Duration(seconds: 30),
    );
    expect(
      nextSegmentRotationDelay(
        startedAt: startedAt,
        now: startedAt.add(const Duration(minutes: 3, seconds: 5)),
        segmentDuration: const Duration(minutes: 3),
      ),
      const Duration(milliseconds: 100),
    );
  });

  test('waits for a recorder file to stop growing', () async {
    final directory = await Directory.systemTemp.createTemp('vnvar_settle_');
    final file = File('${directory.path}${Platform.pathSeparator}segment.mp4');
    try {
      await file.writeAsBytes([1, 2, 3], flush: true);
      final settled = await waitForRecordingFileToSettle(
        file,
        timeout: const Duration(milliseconds: 200),
        pollInterval: const Duration(milliseconds: 5),
        requiredStableSamples: 2,
      );
      expect(settled, isTrue);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('file stability wait has a bounded timeout', () async {
    final missing = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'vnvar_missing_${DateTime.now().microsecondsSinceEpoch}.mp4',
    );
    final settled = await waitForRecordingFileToSettle(
      missing,
      timeout: const Duration(milliseconds: 30),
      pollInterval: const Duration(milliseconds: 5),
    );
    expect(settled, isFalse);
  });

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

  test('segment name uses the real recorder stop boundary', () {
    final startedAt = DateTime(2026, 9, 4, 17, 21, 17);
    final stoppedAt = startedAt.add(const Duration(minutes: 3));

    expect(
      segmentBoundaryEndedAt(
        startedAt: startedAt,
        recorderStoppedAt: stoppedAt,
      ),
      DateTime(2026, 9, 4, 17, 24, 17),
    );
  });

  test('segment boundary preserves the real wall-clock stop time', () {
    final startedAt = DateTime(2026, 9, 4, 17, 21, 17);

    expect(
      segmentBoundaryEndedAt(
        startedAt: startedAt,
        recorderStoppedAt: startedAt.add(const Duration(minutes: 34)),
      ),
      DateTime(2026, 9, 4, 17, 55, 17),
    );
  });

  test('segment boundary never ends before it starts', () {
    final startedAt = DateTime(2026, 9, 4, 17, 21, 17);

    expect(
      segmentBoundaryEndedAt(
        startedAt: startedAt,
        recorderStoppedAt: startedAt.subtract(const Duration(seconds: 1)),
      ),
      startedAt,
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

  test(
    'Check VAR clip ends at the press and keeps the configured lookback',
    () {
      final startedAt = DateTime(2026, 9, 4, 10);
      final range = checkVarClipRange(
        segmentStartedAt: startedAt,
        segmentEndedAt: startedAt.add(const Duration(seconds: 40)),
        requestedAt: startedAt.add(const Duration(seconds: 32)),
        lookback: const Duration(seconds: 15),
        keyframeSafetyMargin: const Duration(seconds: 5),
      );

      expect(range.startMs, 12000);
      expect(range.endMs, 32000);
    },
  );

  test(
    'Check VAR uses the source end when the previous segment is selected',
    () {
      final startedAt = DateTime(2026, 9, 4, 10);
      final range = checkVarClipRange(
        segmentStartedAt: startedAt,
        segmentEndedAt: startedAt.add(const Duration(seconds: 20)),
        requestedAt: startedAt.add(const Duration(seconds: 21)),
        lookback: const Duration(seconds: 10),
      );

      expect(range.startMs, 10000);
      expect(range.endMs, 20000);
    },
  );

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
