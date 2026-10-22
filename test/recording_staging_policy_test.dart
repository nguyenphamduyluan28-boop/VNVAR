import 'package:camera_station/services/recording_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('thư mục file tạm khi ghi', () {
    test('ưu tiên Application Support, thiếu thì dùng cache', () {
      expect(
        recordingStagingDirectoryPath(
          supportPath: '/data/files',
          temporaryPath: '/data/cache',
        ),
        '/data/files/vnvar_recording',
      );
      expect(
        recordingStagingDirectoryPath(
          supportPath: null,
          temporaryPath: '/data/cache',
        ),
        '/data/cache/vnvar_recording',
      );
      expect(
        recordingStagingDirectoryPath(supportPath: '  ', temporaryPath: null),
        isNull,
      );
    });

    test('khi dọn/khôi phục quét cả thư mục cũ trong cache', () {
      expect(
        recordingStagingScanPaths(
          supportPath: '/data/files',
          temporaryPath: '/data/cache',
        ),
        ['/data/files/vnvar_recording', '/data/cache/vnvar_recording'],
      );
      // Không có Application Support: chỉ một thư mục, không trùng lặp.
      expect(
        recordingStagingScanPaths(
          supportPath: null,
          temporaryPath: '/data/cache',
        ),
        ['/data/cache/vnvar_recording'],
      );
      expect(
        recordingStagingScanPaths(supportPath: null, temporaryPath: null),
        isEmpty,
      );
    });

    test('bỏ qua file staging vừa sửa (< 30 giây)', () {
      final now = DateTime(2026, 10, 22, 12);
      expect(
        isRecentlyModifiedStagingFile(
          modified: now.subtract(const Duration(seconds: 5)),
          now: now,
        ),
        isTrue,
      );
      expect(
        isRecentlyModifiedStagingFile(
          modified: now.subtract(const Duration(minutes: 2)),
          now: now,
        ),
        isFalse,
      );
    });
  });

  group('dung lượng trước khi mở segment mới', () {
    const gb = 1024 * 1024 * 1024;
    NewSegmentStorageAction action(int? video, int? staging) =>
        newSegmentStorageAction(
          videoAvailableBytes: video,
          stagingAvailableBytes: staging,
          warningBytes: RecordingService.normalFreeSpaceThresholdBytes,
          minimumBytes: RecordingService.minimumStartFreeSpaceBytes,
        );

    test('đủ chỗ hoặc không đo được: mở ngay', () {
      expect(action(5 * gb, 5 * gb), NewSegmentStorageAction.open);
      expect(action(null, null), NewSegmentStorageAction.open);
    });

    test('dưới mức cảnh báo: mở recorder trước, dọn chạy nền', () {
      expect(
        action(RecordingService.minimumStartFreeSpaceBytes + 1, 5 * gb),
        NewSegmentStorageAction.openThenCleanup,
      );
    });

    test('thư mục video dưới mức chặn: dọn trước (giữ logic treo ghi)', () {
      expect(
        action(RecordingService.minimumStartFreeSpaceBytes - 1, 5 * gb),
        NewSegmentStorageAction.cleanupFirst,
      );
    });

    test('ổ file tạm (khác ổ video) dưới mức chặn: treo ghi', () {
      expect(
        action(5 * gb, RecordingService.minimumStartFreeSpaceBytes - 1),
        NewSegmentStorageAction.suspendStaging,
      );
    });
  });

  group('quét toàn bộ thư mục lưu sau mỗi segment', () {
    final now = DateTime(2026, 10, 22, 12, 30);
    const limit = RecordingService.storageLimitBytes;

    bool fullScan({
      int? estimate = 1000,
      bool low = false,
      DateTime? last,
    }) => shouldRunFullStorageScanAfterSegment(
      estimatedManagedBytes: estimate,
      storageLimitBytes: limit,
      lowStorage: low,
      lastFullScanAt: last ?? now.subtract(const Duration(minutes: 2)),
      now: now,
    );

    test('ước lượng còn xa giới hạn và vừa quét: chỉ cộng dồn', () {
      expect(fullScan(), isFalse);
    });

    test('chưa có ước lượng, gần giới hạn hoặc thiếu dung lượng: quét', () {
      expect(fullScan(estimate: null), isTrue);
      expect(fullScan(estimate: (limit * 0.95).round()), isTrue);
      expect(fullScan(low: true), isTrue);
    });

    test('quá 10 phút hoặc sang ngày mới (dọn thư mục ngày): quét', () {
      expect(
        fullScan(last: now.subtract(const Duration(minutes: 11))),
        isTrue,
      );
      final afterMidnight = DateTime(2026, 10, 23, 0, 1);
      expect(
        shouldRunFullStorageScanAfterSegment(
          estimatedManagedBytes: 1000,
          storageLimitBytes: limit,
          lowStorage: false,
          lastFullScanAt: DateTime(2026, 10, 22, 23, 58),
          now: afterMidnight,
        ),
        isTrue,
      );
    });
  });

  group('ghép clip qua 2 segment: mốc concat tuyệt đối', () {
    test('cộng start_time thật của từng file', () {
      final points = concatTrimPoints(
        precedingStartTimeSeconds: 1.4,
        currentStartTimeSeconds: 0.7,
        precedingMs: 180000,
        effectiveStartMs: -12000,
        endMs: 3000,
      );
      expect(points, isNotNull);
      expect(points!.inpoint, closeTo(1.4 + 168.0, 1e-9));
      expect(points.outpoint, closeTo(0.7 + 3.0, 1e-9));
    });

    test('không đọc được start_time: null (cắt tương đối bằng -ss/-t)', () {
      expect(
        concatTrimPoints(
          precedingStartTimeSeconds: null,
          currentStartTimeSeconds: 0.7,
          precedingMs: 1000,
          effectiveStartMs: -500,
          endMs: 1000,
        ),
        isNull,
      );
      expect(
        concatTrimPoints(
          precedingStartTimeSeconds: double.nan,
          currentStartTimeSeconds: 0.7,
          precedingMs: 1000,
          effectiveStartMs: -500,
          endMs: 1000,
        ),
        isNull,
      );
    });

    test('đọc start_time từ FFprobe', () {
      expect(parseProbeStartTime('1.400000'), closeTo(1.4, 1e-9));
      expect(parseProbeStartTime(null), isNull);
      expect(parseProbeStartTime('N/A'), isNull);
      expect(parseProbeStartTime('-0.5'), isNull);
    });
  });
}
