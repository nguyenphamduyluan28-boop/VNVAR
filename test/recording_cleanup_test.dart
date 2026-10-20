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
    'deletes a past day immediately even if its videos are recent',
    () async {
      final reference = DateTime(2026, 8, 25, 0, 1);
      final file = await createSegment(
        day: '24-08-2026',
        modified: reference.subtract(const Duration(minutes: 1)),
      );

      await recording.removeExpiredData(referenceTime: reference);
      expect(await file.exists(), isFalse);
      expect(await file.parent.parent.exists(), isFalse);
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

  test('cleans empty directories and orphaned companion files for past days', () async {
    final reference = DateTime(2026, 8, 25, 12);
    final pastDayDir = Directory(
      '${sandbox.path}${Platform.pathSeparator}24-08-2026'
      '${Platform.pathSeparator}AUTOMODE${Platform.pathSeparator}CAM2',
    );
    await pastDayDir.create(recursive: true);

    // Tạo file mồ côi (.json, .wav) không có video đi kèm
    final orphanedJson = File(
      '${pastDayDir.path}${Platform.pathSeparator}session.json',
    );
    await orphanedJson.writeAsString('{"test": true}');

    await recording.cleanupEmptyStorageDirectories(referenceTime: reference);

    expect(await pastDayDir.exists(), isFalse);
    expect(await Directory('${sandbox.path}${Platform.pathSeparator}24-08-2026').exists(), isFalse);
  });

  test('preserves empty directory for today', () async {
    final reference = DateTime(2026, 8, 25, 12);
    final todayDir = Directory(
      '${sandbox.path}${Platform.pathSeparator}25-08-2026'
      '${Platform.pathSeparator}AUTOMODE',
    );
    await todayDir.create(recursive: true);

    await recording.cleanupEmptyStorageDirectories(referenceTime: reference);

    expect(await todayDir.exists(), isTrue);
  });

  test('never touches user folders inside a shared storage root', () async {
    final reference = DateTime(2026, 8, 25, 12);
    final screenshots = Directory(
      '${sandbox.path}${Platform.pathSeparator}Screenshots',
    );
    await screenshots.create(recursive: true);
    final photo = File('${screenshots.path}${Platform.pathSeparator}a.png');
    final note = File('${screenshots.path}${Platform.pathSeparator}b.json');
    await photo.writeAsBytes([1]);
    await note.writeAsString('{}');

    await recording.cleanupEmptyStorageDirectories(referenceTime: reference);

    expect(await photo.exists(), isTrue);
    expect(await note.exists(), isTrue);
  });

  test('keeps non-auxiliary files inside an app day folder', () async {
    final reference = DateTime(2026, 8, 25, 12);
    final pastDay = Directory(
      '${sandbox.path}${Platform.pathSeparator}24-08-2026',
    );
    await pastDay.create(recursive: true);
    final photo = File('${pastDay.path}${Platform.pathSeparator}photo.jpg');
    final orphan = File('${pastDay.path}${Platform.pathSeparator}x.json');
    await photo.writeAsBytes([1]);
    await orphan.writeAsString('{}');

    await recording.cleanupEmptyStorageDirectories(referenceTime: reference);

    expect(await photo.exists(), isTrue);
    expect(await orphan.exists(), isFalse);
  });

  test('a custom storage root does not get a root .nomedia', () async {
    await recording.getStoragePath();

    expect(
      await File('${sandbox.path}${Platform.pathSeparator}.nomedia').exists(),
      isFalse,
    );
  });

  test('only app-made videos count as managed storage', () {
    expect(
      isAppManagedVideoPath('/DCIM/24-08-2026/AUTOMODE/10-00-00_10-03-00.ts'),
      isTrue,
    );
    expect(
      isAppManagedVideoPath('/DCIM/24-08-2026/AUTOMODE/CAM2/FRAGMENTS/F.mp4'),
      isTrue,
    );
    expect(isAppManagedVideoPath('/VNVAR/VNVAR_CAM-01_1756000000000.ts'), isTrue);
    expect(isAppManagedVideoPath('/VNVAR/CLIP_CAM1_1756000000000.mp4'), isTrue);
    expect(isAppManagedVideoPath('/DCIM/Camera/VID_20260824_100000.mp4'), isFalse);
    expect(isAppManagedVideoPath('/DCIM/holiday.mp4'), isFalse);
    expect(isManagedStorageFilePath('/DCIM/holiday.mp4'), isFalse);
    // Luật cũ `_CLIP_` ở bất kỳ đâu trong tên đã bị bỏ: file người dùng có
    // tên chứa `_CLIP_` không còn bị coi là của app.
    expect(isAppManagedVideoPath('/DCIM/MY_CLIP_HOLIDAY.mp4'), isFalse);
    expect(isAppManagedVideoPath('/DCIM/VNVAR_CAM1_CLIP_1756000000000.mp4'), isFalse);
    // Regex tên cũ được neo chặt: không nhận tiền tố/hậu tố lạ.
    expect(isAppManagedVideoPath('/VNVAR/MYCAM1_1756000000000.mp4'), isFalse);
    expect(isAppManagedVideoPath('/VNVAR/CAMERA_1756000000000.mp4'), isFalse);
    expect(isAppManagedVideoPath('/VNVAR/CAM1_1756000000000.mp4.bak'), isFalse);
    // Clip trim/Check VAR do app xuất vẫn được nhận diện.
    expect(
      isAppManagedVideoPath('/VNVAR/download/cam1_trim_1787624130000.mp4'),
      isTrue,
    );
    expect(isOrphanAuxiliaryFile('/x/24-08-2026/a.wav'), isTrue);
    expect(isOrphanAuxiliaryFile('/x/24-08-2026/photo.jpg'), isFalse);
  });

  test('with a known storage root, only recognises app layouts under it', () {
    const root = '/storage/emulated/0/DCIM';
    expect(
      isAppManagedVideoPath(
        '$root/24-08-2026/AUTOMODE/10-00-00_10-03-00.ts',
        storageRoot: root,
      ),
      isTrue,
    );
    expect(
      isAppManagedVideoPath(
        '$root/24-08-2026/AUTOMODE/CAM2/10-00-00_10-03-00_1.ts',
        storageRoot: '$root/',
      ),
      isTrue,
    );
    // Thư mục ngày lồng trong thư mục khác của người dùng: không phải của app.
    expect(
      isAppManagedVideoPath(
        '$root/Trips/24-08-2026/AUTOMODE/a.mp4',
        storageRoot: root,
      ),
      isFalse,
    );
    // Tên kiểu cũ chỉ được nhận khi nằm ngay ở gốc lưu.
    expect(
      isAppManagedVideoPath(
        '$root/VNVAR_CAM-01_1756000000000.ts',
        storageRoot: root,
      ),
      isTrue,
    );
    expect(
      isAppManagedVideoPath(
        '$root/Camera/CAM1_1756000000000.mp4',
        storageRoot: root,
      ),
      isFalse,
    );
    expect(
      isAppManagedVideoPath(
        '$root/download/cam1_trim_1787624130000.mp4',
        storageRoot: root,
      ),
      isTrue,
    );
    expect(
      isAppManagedVideoPath(
        '$root/download/holiday.mp4',
        storageRoot: root,
      ),
      isFalse,
    );
    // Ngoài gốc lưu: không bao giờ.
    expect(
      isAppManagedVideoPath(
        '/sdcard/Movies/24-08-2026/AUTOMODE/a.ts',
        storageRoot: root,
      ),
      isFalse,
    );
    expect(
      isManagedStorageFilePath(
        '$root/24-08-2026/AUTOMODE/FRAGMENTS/F1.wav',
        storageRoot: root,
      ),
      isTrue,
    );
    expect(
      isManagedStorageFilePath('$root/notes/fragments/a.json', storageRoot: root),
      isFalse,
    );
  });
}
