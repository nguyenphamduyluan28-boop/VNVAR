import 'dart:io';

import 'package:camera_station/services/recording_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory sandbox;
  late RecordingService recording;
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sandbox = await Directory.systemTemp.createTemp('vnvar-cleanup-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getTemporaryDirectory') return sandbox.path;
          return null;
        });
    recording = RecordingService(cameraId: 'CAM-01');
    await recording.setStoragePath(sandbox.path);
  });

  tearDown(() async {
    await recording.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  Future<File> createSegment({
    required String day,
    required DateTime modified,
  }) async {
    final directory = Directory(
      '${sandbox.path}${Platform.pathSeparator}$day'
      '${Platform.pathSeparator}AUTOMODE',
    );
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}${Platform.pathSeparator}10-00-00_10-03-00.ts',
    );
    await file.writeAsBytes([1, 2, 3]);
    await file.setLastModified(modified);
    return file;
  }

  test('deletes an expired day when its videos are not recent', () async {
    final reference = DateTime(2026, 8, 25, 12);
    final file = await createSegment(
      day: '24-08-2026',
      modified: reference.subtract(const Duration(hours: 1)),
    );

    await recording.removeExpiredData(referenceTime: reference);

    expect(await file.exists(), isFalse);
    expect(await file.parent.parent.exists(), isFalse);
  });

  test(
    'protects a newly completed segment in an expired day for 5 minutes',
    () async {
      final reference = DateTime(2026, 8, 25, 0, 1);
      final file = await createSegment(
        day: '24-08-2026',
        modified: reference.subtract(const Duration(minutes: 1)),
      );

      await recording.removeExpiredData(referenceTime: reference);
      expect(await file.exists(), isTrue);

      await recording.removeExpiredData(
        referenceTime: reference.add(const Duration(minutes: 6)),
      );
      expect(await file.exists(), isFalse);
    },
  );

  test('never deletes the current day directory', () async {
    final reference = DateTime(2026, 8, 25, 12);
    final file = await createSegment(
      day: '25-08-2026',
      modified: reference.subtract(const Duration(hours: 3)),
    );

    await recording.removeExpiredData(referenceTime: reference);

    expect(await file.exists(), isTrue);
  });

  test('uses warning and emergency free-space safety thresholds', () {
    expect(RecordingService.normalFreeSpaceThresholdBytes, 1024 * 1024 * 1024);
    expect(RecordingService.minimumStartFreeSpaceBytes, 512 * 1024 * 1024);
    expect(
      RecordingService.minimumStartFreeSpaceBytes,
      lessThan(RecordingService.normalFreeSpaceThresholdBytes),
    );
  });

  test('does not index another camera from shared AUTOMODE storage', () async {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final day = '${two(now.day)}-${two(now.month)}-${now.year}';
    final cam2 = Directory(
      '${sandbox.path}${Platform.pathSeparator}$day'
      '${Platform.pathSeparator}AUTOMODE${Platform.pathSeparator}CAM2',
    );
    await cam2.create(recursive: true);
    final file = File(
      '${cam2.path}${Platform.pathSeparator}10-00-00_10-03-00.ts',
    );
    await file.writeAsBytes([1, 2, 3]);

    await recording.cleanupOldTempFiles();

    expect(recording.segments, isEmpty);
    expect(await file.exists(), isTrue);
  });
}
