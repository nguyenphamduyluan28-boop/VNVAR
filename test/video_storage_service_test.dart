import 'dart:io';

import 'package:camera_station/services/video_storage_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('vnvar/camera_station_service');
  late Directory sandbox;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sandbox = await Directory.systemTemp.createTemp('vnvar-storage-test-');
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('persists and restores a writable custom storage directory', () async {
    final custom = Directory('${sandbox.path}${Platform.pathSeparator}videos');
    await custom.create(recursive: true);
    final existingUserFile = File(
      '${custom.path}${Platform.pathSeparator}.write_test',
    );
    await existingUserFile.writeAsString('KEEP_ME');
    final service = VideoStorageService();

    await service.setStoragePath(custom.path);

    expect(service.selectedPath, custom.path);
    expect((await service.rootDirectory()).path, custom.path);
    expect(await custom.exists(), isTrue);
    expect(await existingUserFile.readAsString(), 'KEEP_ME');
    expect(
      await custom
          .list()
          .where(
            (entity) =>
                entity.uri.pathSegments.last.startsWith('.vnvar_write_'),
          )
          .isEmpty,
      isTrue,
    );
    expect(
      (await SharedPreferences.getInstance()).getString(
        'camera_video_storage_path',
      ),
      custom.path,
    );

    final restored = VideoStorageService();
    await restored.load();
    expect(restored.selectedPath, custom.path);
  });

  test('non-Android capabilities do not invoke the Android channel', () async {
    if (Platform.isAndroid) return;
    var nativeCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          nativeCalls++;
          return sandbox.path;
        });

    final service = VideoStorageService();

    expect(service.supportsFolderPicker, isFalse);
    expect(await service.selectFolder(), isNull);
    expect(await service.availableBytes(), isNull);
    expect(nativeCalls, 0);
  });

  test('discards a saved custom path that is no longer a directory', () async {
    final invalidPath = File(
      '${sandbox.path}${Platform.pathSeparator}not-a-directory',
    );
    await invalidPath.writeAsString('occupied');
    SharedPreferences.setMockInitialValues({
      'camera_video_storage_path': invalidPath.path,
    });

    final service = VideoStorageService();
    await service.load();

    expect(service.selectedPath, isNull);
    expect(
      (await SharedPreferences.getInstance()).containsKey(
        'camera_video_storage_path',
      ),
      isFalse,
    );
  });

  test('trims and normalizes a custom path before persisting it', () async {
    final service = VideoStorageService();

    await service.setStoragePath('  ${sandbox.path}  ');

    expect(service.selectedPath, sandbox.absolute.path);
    expect(
      (await SharedPreferences.getInstance()).getString(
        'camera_video_storage_path',
      ),
      sandbox.absolute.path,
    );
  });
}
