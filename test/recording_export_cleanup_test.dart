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
    sandbox = await Directory.systemTemp.createTemp('vnvar-export-test-');
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

  Future<File> createExportClip(String name, DateTime modified) async {
    final directory = Directory(
      '${sandbox.path}${Platform.pathSeparator}download',
    );
    await directory.create(recursive: true);
    final file = File('${directory.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes([1, 2, 3]);
    await file.setLastModified(modified);
    return file;
  }

  test('TTL cleanup removes only orphaned export clips', () async {
    final now = DateTime.now();
    final stale = await createExportClip(
      'cam1_trim_1700000000000.mp4',
      now.subtract(const Duration(minutes: 31)),
    );
    final fresh = await createExportClip(
      'cam1_trim_1700000000001.mp4',
      now.subtract(const Duration(minutes: 2)),
    );

    await recording.cleanupExpiredExportDownloads();

    expect(await stale.exists(), isFalse);
    expect(await fresh.exists(), isTrue);
  });

  test('closing one session keeps clips that are not its own', () async {
    final fresh = await createExportClip(
      'cam1_trim_1700000000002.mp4',
      DateTime.now().subtract(const Duration(minutes: 1)),
    );

    await recording.cleanupExportDownloads(owner: 'ip:10.0.0.9');

    expect(await fresh.exists(), isTrue);
  });

  test('expired clips being downloaded are kept', () async {
    final stale = await createExportClip(
      'cam1_trim_1700000000003.mp4',
      DateTime.now().subtract(const Duration(hours: 1)),
    );
    recording.acquireFileRead(stale.path);
    try {
      await recording.cleanupExpiredExportDownloads();
      expect(await stale.exists(), isTrue);
    } finally {
      recording.releaseFileRead(stale.path);
    }
  });

  test('reading a session clip extends its TTL from the last read', () async {
    final now = DateTime.now();
    final clip = await createExportClip(
      'cam1_trim_1700000000005.mp4',
      now.subtract(const Duration(minutes: 45)),
    );
    recording.debugRegisterExportClip(
      clip.path,
      owner: 'ip:10.0.0.9',
      createdAt: now.subtract(const Duration(minutes: 45)),
    );
    // Tablet tải clip sau 45 phút (/download): lần đọc làm mới TTL.
    recording.acquireFileRead(clip.path);
    recording.releaseFileRead(clip.path);

    await recording.cleanupExpiredExportDownloads();

    expect(await clip.exists(), isTrue);
  });

  test('session clip unread for longer than the TTL is removed', () async {
    final now = DateTime.now();
    final clip = await createExportClip(
      'cam1_trim_1700000000006.mp4',
      now.subtract(const Duration(minutes: 45)),
    );
    recording.debugRegisterExportClip(
      clip.path,
      owner: 'ip:10.0.0.9',
      createdAt: now.subtract(const Duration(minutes: 45)),
      lastAccessedAt: now.subtract(const Duration(minutes: 31)),
    );

    await recording.cleanupExpiredExportDownloads();

    expect(await clip.exists(), isFalse);
  });

  test('startup cleanup (no owner) removes every export clip', () async {
    final fresh = await createExportClip(
      'cam1_trim_1700000000004.mp4',
      DateTime.now(),
    );

    await recording.cleanupExportDownloads();

    expect(await fresh.exists(), isFalse);
  });
}
