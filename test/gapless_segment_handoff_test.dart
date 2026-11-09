import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:camera_station/services/recording_service.dart';

/// Chuyển segment không gián đoạn: recorder mới mở trước khi recorder cũ
/// dừng, phần ghi chồng ở cuối đoạn cũ được cắt khi đóng gói TS.
void main() {
  final nextStartedAt = DateTime(2026, 11, 6, 15, 3, 0);

  group('gaplessHandoffOutputDurationSeconds', () {
    test('cuts only the overlap (minus the safety margin) from the end', () {
      final keep = gaplessHandoffOutputDurationSeconds(
        mediaDurationSeconds: 180.9,
        nextStartedAt: nextStartedAt,
        recorderStoppedAt: nextStartedAt.add(
          const Duration(milliseconds: 900),
        ),
      );
      // Chồng 900 ms, giữ thêm 120 ms -> cắt 780 ms.
      expect(keep, closeTo(180.12, 1e-9));
    });

    test('counts back from the end when the media timeline jumped', () {
      final keep = gaplessHandoffOutputDurationSeconds(
        mediaDurationSeconds: 185.9, // timeline dài hơn wall-clock 5 s
        nextStartedAt: nextStartedAt,
        recorderStoppedAt: nextStartedAt.add(
          const Duration(milliseconds: 900),
        ),
      );
      expect(keep, closeTo(185.12, 1e-9));
    });

    test('does not cut a tiny overlap', () {
      expect(
        gaplessHandoffOutputDurationSeconds(
          mediaDurationSeconds: 180,
          nextStartedAt: nextStartedAt,
          recorderStoppedAt: nextStartedAt.add(
            const Duration(milliseconds: 150),
          ),
        ),
        isNull,
      );
      expect(
        gaplessHandoffOutputDurationSeconds(
          mediaDurationSeconds: 180,
          nextStartedAt: nextStartedAt,
          recorderStoppedAt: nextStartedAt.subtract(
            const Duration(milliseconds: 10),
          ),
        ),
        isNull,
      );
    });

    test('never cuts a file down to less than one second', () {
      expect(
        gaplessHandoffOutputDurationSeconds(
          mediaDurationSeconds: 1.5,
          nextStartedAt: nextStartedAt,
          recorderStoppedAt: nextStartedAt.add(const Duration(seconds: 1)),
        ),
        isNull,
      );
    });
  });

  group('waitForRecorderOutput', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('gapless_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('true as soon as the recorder wrote data', () async {
      final file = File('${dir.path}/next.mp4');
      final writer = Future<void>.delayed(
        const Duration(milliseconds: 60),
        () => file.writeAsBytesSync([0, 0, 0, 24]),
      );
      final ready = await waitForRecorderOutput(
        file,
        timeout: const Duration(seconds: 2),
        pollInterval: const Duration(milliseconds: 10),
      );
      await writer;
      expect(ready, isTrue);
    });

    test('false when the file stays empty', () async {
      final file = File('${dir.path}/empty.mp4')..writeAsBytesSync(const []);
      final ready = await waitForRecorderOutput(
        file,
        timeout: const Duration(milliseconds: 120),
        pollInterval: const Duration(milliseconds: 10),
      );
      expect(ready, isFalse);
    });
  });

  test('previousAudioResultFromRotate reads the old WAV result', () {
    final previous = {'path': '/a.wav', 'firstSampleEpochMs': 1234.5};
    expect(
      previousAudioResultFromRotate({'path': '/b.wav', 'previous': previous}),
      previous,
    );
    expect(previousAudioResultFromRotate(null), isNull);
    expect(
      firstSampleEpochMsFromStopResult(
        previousAudioResultFromRotate({'previous': previous}),
      ),
      1234.5,
    );
  });
}
