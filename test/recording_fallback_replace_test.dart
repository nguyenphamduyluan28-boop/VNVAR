import 'dart:convert';
import 'dart:io';

import 'package:camera_station/services/recording_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Thay bản MP4 dự phòng qua file tạm, khôi phục khoá pendingDelete và dựng
/// chỉ mục với cặp .ts/.mp4 — trên file thật trong thư mục tạm. Không cần
/// FFmpeg: file đầu ra được giả lập, FFprobe được thay bằng
/// [RecordingService.debugPlayableVideoOverride].
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory sandbox;
  // Thư mục lưu video và thư mục tạm (staging) tách riêng như trên máy thật:
  // MP4 staging không bị chỉ mục quét nhầm.
  late String storagePath;
  late String tempPath;
  late RecordingService recording;
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  final sep = Platform.pathSeparator;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sandbox = await Directory.systemTemp.createTemp('vnvar-fallback-test-');
    storagePath = '${sandbox.path}${sep}storage';
    tempPath = '${sandbox.path}${sep}tmp';
    await Directory(tempPath).create(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getTemporaryDirectory') return tempPath;
          return null;
        });
    recording = RecordingService(cameraId: 'CAM-01');
    await recording.setStoragePath(storagePath);
  });

  tearDown(() async {
    await recording.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  String two(int value) => value.toString().padLeft(2, '0');

  Future<Directory> todayCameraDirectory() async {
    final now = DateTime.now();
    final day = '${two(now.day)}-${two(now.month)}-${now.year}';
    final directory = Directory(
      '$storagePath$sep$day${sep}AUTOMODE${sep}CAM1',
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<File> writeFile(String path, List<int> bytes) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<Map<String, dynamic>> readJournal(File journal) async =>
      jsonDecode(await journal.readAsString()) as Map<String, dynamic>;

  group('thay bản dự phòng qua file tạm', () {
    test('MP4 -> MP4: thành công thì thay nội dung, file tạm bị dọn', () async {
      final directory = await todayCameraDirectory();
      final previous = await writeFile(
        '${directory.path}${sep}10-00-00_10-03-00.mp4',
        [1, 1, 1],
      );
      final temp = await writeFile(fallbackRetryTempPath(previous.path), [
        2,
        2,
        2,
        2,
      ]);

      final action = await recording.debugInstallFallbackRetryOutput(
        temp: temp,
        target: previous,
        previous: previous,
      );

      expect(action, FallbackReplacementAction.install);
      expect(await previous.readAsBytes(), [2, 2, 2, 2]);
      expect(await temp.exists(), isFalse);
    });

    test('bản cũ đang được đọc: hoãn, bản cũ nguyên vẹn, file tạm bị xoá', () async {
      final directory = await todayCameraDirectory();
      final previous = await writeFile(
        '${directory.path}${sep}10-00-00_10-03-00.mp4',
        [1, 1, 1],
      );
      final target = File('${directory.path}${sep}10-00-00_10-03-00.ts');
      final journal = await writeFile('$tempPath${sep}j.json', utf8.encode(
        jsonEncode({'state': 'preserved_fallback', 'updatedAtMs': 0}),
      ));

      for (final installTarget in [previous, target]) {
        final temp = await writeFile(
          fallbackRetryTempPath(installTarget.path),
          [9, 9],
        );
        recording.acquireFileRead(previous.path);
        try {
          final action = await recording.debugInstallFallbackRetryOutput(
            temp: temp,
            target: installTarget,
            previous: previous,
            journal: journal,
          );
          expect(action, FallbackReplacementAction.defer);
        } finally {
          recording.releaseFileRead(previous.path);
        }
        expect(await previous.readAsBytes(), [1, 1, 1]);
        expect(await temp.exists(), isFalse);
        expect(await target.exists(), isFalse);
        expect(
          (await readJournal(journal)).containsKey(
            fallbackPendingDeleteJournalKey,
          ),
          isFalse,
        );
      }
    });

    test('file tạm rỗng: bỏ file tạm, bản cũ giữ nguyên', () async {
      final directory = await todayCameraDirectory();
      final previous = await writeFile(
        '${directory.path}${sep}10-00-00_10-03-00.mp4',
        [1, 1, 1],
      );
      final temp = await writeFile(fallbackRetryTempPath(previous.path), []);

      final action = await recording.debugInstallFallbackRetryOutput(
        temp: temp,
        target: previous,
        previous: previous,
      );

      expect(action, FallbackReplacementAction.discardTemp);
      expect(await previous.readAsBytes(), [1, 1, 1]);
      expect(await temp.exists(), isFalse);
    });

    test('MP4 -> TS: ghi rồi gỡ pendingDelete, xoá bản MP4 cũ', () async {
      final directory = await todayCameraDirectory();
      final previous = await writeFile(
        '${directory.path}${sep}10-00-00_10-03-00.mp4',
        [1, 1, 1],
      );
      final target = File('${directory.path}${sep}10-00-00_10-03-00.ts');
      final temp = await writeFile(fallbackRetryTempPath(target.path), [
        7,
        7,
        7,
        7,
      ]);
      final journal = await writeFile('$tempPath${sep}j.json', utf8.encode(
        jsonEncode({
          'state': 'preserved_fallback',
          'finalPath': previous.path,
          'updatedAtMs': 0,
        }),
      ));

      final action = await recording.debugInstallFallbackRetryOutput(
        temp: temp,
        target: target,
        previous: previous,
        journal: journal,
      );

      expect(action, FallbackReplacementAction.install);
      expect(await target.readAsBytes(), [7, 7, 7, 7]);
      expect(await previous.exists(), isFalse);
      expect(await temp.exists(), isFalse);
      final values = await readJournal(journal);
      // Khoá đã được gỡ; journal vẫn được ghi (khoá từng được đặt) và giữ
      // nguyên các trường khác.
      expect(values.containsKey(fallbackPendingDeleteJournalKey), isFalse);
      expect(values['updatedAtMs'], isNot(0));
      expect(values['state'], 'preserved_fallback');
      expect(values['finalPath'], previous.path);
    });
  });

  group('khởi động với pendingDelete còn sót', () {
    late Directory directory;
    late File mp4;
    late File ts;
    late File stagingVideo;
    late File journal;

    setUp(() async {
      directory = await todayCameraDirectory();
      mp4 = await writeFile(
        '${directory.path}${sep}10-00-00_10-03-00.mp4',
        [1, 1, 1],
      );
      ts = await writeFile('${directory.path}${sep}10-00-00_10-03-00.ts', [
        2,
        2,
        2,
      ]);
      final staging = '$tempPath${sep}vnvar_recording';
      stagingVideo = await writeFile('$staging${sep}CAM-01_1000.mp4', [5, 5]);
      final startedAt = DateTime.now().subtract(const Duration(minutes: 5));
      journal = await writeFile('${stagingVideo.path}.json', utf8.encode(
        jsonEncode({
          'state': 'preserved_fallback',
          'finalPath': mp4.path,
          fallbackPendingDeleteJournalKey: mp4.path,
          // Hết lượt thử và chưa quá hạn: không chạy FFmpeg trong test.
          'muxAttempts': maximumFallbackMuxAttempts,
          'startedAtMs': startedAt.millisecondsSinceEpoch,
          'endedAtMs': startedAt
              .add(const Duration(minutes: 3))
              .millisecondsSinceEpoch,
        }),
      ));
    });

    test('TS đọc được: xoá MP4, giữ TS, chỉ mục chỉ có TS', () async {
      recording.debugPlayableVideoOverride = (_) async => true;

      await recording.cleanupOldTempFiles();

      expect(await mp4.exists(), isFalse);
      expect(await ts.exists(), isTrue);
      expect(await journal.exists(), isFalse);
      expect(await stagingVideo.exists(), isFalse);
      expect(recording.segments.map((segment) => segment.path), [ts.path]);
    });

    test('TS hỏng và đang được đọc: còn khoá, chỉ mục ưu tiên MP4', () async {
      recording.debugPlayableVideoOverride = (_) async => false;
      recording.acquireFileRead(ts.path);
      try {
        await recording.cleanupOldTempFiles();
      } finally {
        recording.releaseFileRead(ts.path);
      }

      expect(await mp4.exists(), isTrue);
      expect(await ts.exists(), isTrue);
      expect(
        (await readJournal(journal))[fallbackPendingDeleteJournalKey],
        mp4.path,
      );
      expect(recording.segments.map((segment) => segment.path), [mp4.path]);
    });

    test('TS hỏng: bỏ TS, gỡ khoá, giữ MP4 trong chỉ mục', () async {
      recording.debugPlayableVideoOverride = (_) async => false;

      await recording.cleanupOldTempFiles();

      expect(await mp4.exists(), isTrue);
      expect(await ts.exists(), isFalse);
      expect(
        (await readJournal(journal)).containsKey(
          fallbackPendingDeleteJournalKey,
        ),
        isFalse,
      );
      expect(recording.segments.map((segment) => segment.path), [mp4.path]);
    });
  });

  test('cặp .ts/.mp4 không còn khoá: chỉ mục ưu tiên TS', () async {
    final directory = await todayCameraDirectory();
    await writeFile('${directory.path}${sep}10-00-00_10-03-00.mp4', [1]);
    final ts = await writeFile(
      '${directory.path}${sep}10-00-00_10-03-00.ts',
      [2],
    );

    await recording.cleanupOldTempFiles();

    expect(recording.segments.map((segment) => segment.path), [ts.path]);
  });

  group('dọn *.retry.tmp trong thư mục hôm nay', () {
    test('chỉ xoá file tạm thử lại đã cũ, không đụng file khác', () async {
      final directory = await todayCameraDirectory();
      final old = DateTime.now().subtract(const Duration(minutes: 30));
      final video = await writeFile(
        '${directory.path}${sep}10-00-00_10-03-00.ts',
        [1],
      );
      final staleTemp = await writeFile(
        fallbackRetryTempPath('${directory.path}${sep}10-03-00_10-06-00.ts'),
        [1],
      );
      final freshTemp = await writeFile(
        fallbackRetryTempPath('${directory.path}${sep}10-06-00_10-09-00.ts'),
        [1],
      );
      final leasedTemp = await writeFile(
        fallbackRetryTempPath('${directory.path}${sep}10-09-00_10-12-00.mp4'),
        [1],
      );
      final otherTemp = await writeFile('${directory.path}${sep}x.tmp', [1]);
      final wav = await writeFile('${directory.path}${sep}x.wav', [1]);
      for (final file in [video, staleTemp, leasedTemp, otherTemp, wav]) {
        await file.setLastModified(old);
      }

      recording.acquireFileRead(leasedTemp.path);
      try {
        await recording.cleanupEmptyStorageDirectories(
          referenceTime: DateTime.now(),
        );
      } finally {
        recording.releaseFileRead(leasedTemp.path);
      }

      expect(await staleTemp.exists(), isFalse);
      expect(await freshTemp.exists(), isTrue);
      expect(await leasedTemp.exists(), isTrue);
      expect(await video.exists(), isTrue);
      expect(await otherTemp.exists(), isTrue);
      expect(await wav.exists(), isTrue);
      expect(await directory.exists(), isTrue);
    });

    test('thư mục hôm nay chỉ có file tạm cũ: vẫn giữ thư mục', () async {
      final directory = await todayCameraDirectory();
      final staleTemp = await writeFile(
        fallbackRetryTempPath('${directory.path}${sep}10-03-00_10-06-00.ts'),
        [1],
      );
      await staleTemp.setLastModified(
        DateTime.now().subtract(const Duration(minutes: 30)),
      );

      await recording.cleanupEmptyStorageDirectories(
        referenceTime: DateTime.now(),
      );

      expect(await staleTemp.exists(), isFalse);
      expect(await directory.exists(), isTrue);
    });
  });
}
