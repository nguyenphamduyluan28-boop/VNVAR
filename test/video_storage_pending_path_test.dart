import 'dart:io';

import 'package:camera_station/services/video_storage_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Thư mục lưu người dùng chọn chưa sẵn sàng lúc khởi động (thẻ nhớ chưa
/// mount...): không xoá lựa chọn, ghi tạm vào thư mục dự phòng, thử lại sau.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  const storageKey = 'camera_video_storage_path';
  final sep = Platform.pathSeparator;
  late Directory sandbox;
  late String documentsPath;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('vnvar-pending-storage-');
    documentsPath = '${sandbox.path}${sep}documents';
    await Directory(documentsPath).create(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return documentsPath;
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('chỉ bỏ lựa chọn khi đường dẫn giờ là một file', () {
    expect(shouldForgetSavedStoragePath(FileSystemEntityType.file), isTrue);
    expect(
      shouldForgetSavedStoragePath(FileSystemEntityType.notFound),
      isFalse,
    );
    expect(
      shouldForgetSavedStoragePath(FileSystemEntityType.directory),
      isFalse,
    );
  });

  test('thư mục chưa sẵn sàng: giữ cài đặt, dùng tạm thư mục dự phòng, '
      'thử lại được', () async {
    // "Thẻ nhớ chưa mount": cha của thư mục đã chọn đang là một file nên
    // không tạo được thư mục.
    final mountPoint = File('${sandbox.path}${sep}sdcard');
    await mountPoint.writeAsString('not mounted');
    final chosen = '${mountPoint.path}${sep}VNVAR';
    SharedPreferences.setMockInitialValues({storageKey: chosen});

    final service = VideoStorageService();
    await service.load();

    expect(service.selectedPath, isNull);
    expect(service.pendingSelectedPath, chosen);
    expect(
      (await SharedPreferences.getInstance()).getString(storageKey),
      chosen,
    );
    final temporaryRoot = await service.rootDirectory();
    expect(temporaryRoot.path, '$documentsPath${sep}VNVAR');
    expect(service.fallbackActive, isTrue);

    // Thẻ nhớ được mount: lần lấy thư mục kế tiếp chuyển về thư mục đã chọn.
    await mountPoint.delete();
    await Directory(mountPoint.path).create();
    service.debugAllowPendingRetryNow();
    final root = await service.rootDirectory();

    expect(root.path, chosen);
    expect(service.selectedPath, chosen);
    expect(service.pendingSelectedPath, isNull);
    expect(service.fallbackActive, isFalse);
    // Video ghi tạm vào thư mục dự phòng vẫn được index/dọn sau đó.
    expect(
      (await service.secondaryRoots(root)).map((dir) => dir.path),
      ['$documentsPath${sep}VNVAR'],
    );
  });
}
