import 'dart:io';

import 'package:camera_station/services/recording_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hàng đợi cắt clip: job Check VAR (ưu tiên) chen trước các lệnh /trim thủ
/// công đang chờ và không bị giới hạn số job thủ công. Các segment không tồn
/// tại nên mỗi job kết thúc ngay bằng lỗi; thứ tự hoàn tất phản ánh thứ tự
/// chạy (worker chạy từng job một).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory sandbox;
  late RecordingService recording;
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sandbox = await Directory.systemTemp.createTemp('vnvar-trim-priority-');
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

  Future<void> track(
    Future<RecordedSegment> operation,
    String label,
    List<String> order,
  ) => operation.then<void>(
    (_) => order.add('$label:ok'),
    onError: (Object error) => order.add(label),
  );

  test('job ưu tiên chạy trước các job thủ công đang chờ', () async {
    final order = <String>[];
    final running = track(
      recording.trimSegment(segmentId: 'manual-1', startMs: 0, endMs: 5000),
      'manual-1',
      order,
    );
    final waiting = track(
      recording.trimSegment(segmentId: 'manual-2', startMs: 0, endMs: 5000),
      'manual-2',
      order,
    );
    final checkVar = track(
      recording.trimSegment(
        segmentId: 'checkvar',
        startMs: 0,
        endMs: 5000,
        priority: true,
      ),
      'checkvar',
      order,
    );
    await Future.wait([running, waiting, checkVar]);
    await recording.waitForTrimIdle();

    expect(order, ['manual-1', 'checkvar', 'manual-2']);
  });

  test('job ưu tiên không bị giới hạn số job thủ công đang chờ', () async {
    final pending = <Future<void>>[];
    for (var index = 0; index < RecordingService.maxPendingTrims; index++) {
      pending.add(
        recording
            .trimSegment(segmentId: 'manual-$index', startMs: 0, endMs: 5000)
            .then<void>((_) {}, onError: (Object _) {}),
      );
    }

    // Cả hai yêu cầu được gửi khi 4 job thủ công vẫn đang chờ/chạy.
    final rejected = recording.trimSegment(
      segmentId: 'manual-x',
      startMs: 0,
      endMs: 5000,
    );
    final prioritized = recording.trimSegment(
      segmentId: 'checkvar',
      startMs: 0,
      endMs: 5000,
      priority: true,
    );
    await expectLater(rejected, throwsA(isA<TrimInProgressException>()));
    await expectLater(
      prioritized,
      throwsA(isA<TrimSegmentNotFoundException>()),
    );
    await Future.wait(pending);
    await recording.waitForTrimIdle();
  });
}
