import 'package:camera_station/services/recording_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ghép clip qua 2 segment: so khớp luồng video', () {
    test('đọc codec, kích thước và góc xoay từ thuộc tính FFprobe', () {
      final signature = videoStreamSignatureFromProperties({
        'codec_type': 'video',
        'codec_name': 'H264',
        'width': 1920,
        'height': '1080',
        'tags': {'rotate': '90'},
      });
      expect(signature, isNotNull);
      expect(signature!.codec, 'h264');
      expect(signature.width, 1920);
      expect(signature.height, 1080);
      expect(signature.rotation, 90);
    });

    test('đọc góc xoay từ side data display matrix (âm → chuẩn hoá)', () {
      final signature = videoStreamSignatureFromProperties({
        'codec_name': 'hevc',
        'width': 1280,
        'height': 720,
        'side_data_list': [
          {'side_data_type': 'Display Matrix', 'rotation': -90},
        ],
      });
      expect(signature!.rotation, 270);
    });

    test('bỏ qua stream không phải video và thuộc tính null', () {
      expect(
        videoStreamSignatureFromProperties({'codec_type': 'audio'}),
        isNull,
      );
      expect(videoStreamSignatureFromProperties(null), isNull);
    });

    test('chỉ nối khi cùng codec, kích thước và góc xoay', () {
      const base = VideoStreamSignature(
        codec: 'h264',
        width: 1920,
        height: 1080,
      );
      expect(
        canJoinVideoStreams(
          base,
          const VideoStreamSignature(codec: 'h264', width: 1920, height: 1080),
        ),
        isTrue,
      );
      expect(
        canJoinVideoStreams(
          base,
          const VideoStreamSignature(codec: 'mpeg4', width: 1920, height: 1080),
        ),
        isFalse,
      );
      expect(
        canJoinVideoStreams(
          base,
          const VideoStreamSignature(codec: 'h264', width: 1080, height: 1920),
        ),
        isFalse,
      );
      expect(
        canJoinVideoStreams(
          base,
          const VideoStreamSignature(
            codec: 'h264',
            width: 1920,
            height: 1080,
            rotation: 180,
          ),
        ),
        isFalse,
      );
    });

    test('thiếu thông tin (probe lỗi) thì không nối', () {
      const unknown = VideoStreamSignature(
        codec: null,
        width: null,
        height: null,
      );
      expect(canJoinVideoStreams(null, unknown), isFalse);
      expect(canJoinVideoStreams(unknown, unknown), isFalse);
    });
  });

  group('đồng bộ A/V (C2)', () {
    test('độ lệch = mẫu âm đầu tiên - lúc bắt đầu hình', () {
      expect(
        audioSyncOffsetMs(
          firstSampleEpochMs: 1000150.4,
          videoStartEpochMs: 1000000,
        ),
        150,
      );
      expect(
        audioSyncOffsetMs(firstSampleEpochMs: null, videoStartEpochMs: 1),
        isNull,
      );
      expect(
        audioSyncOffsetMs(firstSampleEpochMs: 1, videoStartEpochMs: null),
        isNull,
      );
    });

    test('tiếng muộn hơn hình → -itsoffset; sớm hơn → -ss', () {
      expect(audioOffsetInputArguments(150), ['-itsoffset', '0.150']);
      expect(audioOffsetInputArguments(-1234), ['-ss', '1.234']);
    });

    test('chỉ áp dụng khi 20 < |offset| < 3000 ms', () {
      expect(audioOffsetInputArguments(null), isEmpty);
      expect(audioOffsetInputArguments(0), isEmpty);
      expect(audioOffsetInputArguments(20), isEmpty);
      expect(audioOffsetInputArguments(-20), isEmpty);
      expect(audioOffsetInputArguments(21), ['-itsoffset', '0.021']);
      expect(audioOffsetInputArguments(2999), ['-itsoffset', '2.999']);
      expect(audioOffsetInputArguments(3000), isEmpty);
      expect(audioOffsetInputArguments(-3000), isEmpty);
    });

    test('đọc firstSampleEpochMs từ kết quả stopNativeAudioSegment', () {
      expect(
        firstSampleEpochMsFromStopResult({'firstSampleEpochMs': 1700000000123}),
        1700000000123,
      );
      expect(
        firstSampleEpochMsFromStopResult({'firstSampleEpochMs': 17.5e11}),
        17.5e11,
      );
      expect(firstSampleEpochMsFromStopResult(null), isNull);
      expect(firstSampleEpochMsFromStopResult(true), isNull);
      expect(firstSampleEpochMsFromStopResult({'status': 'stopped'}), isNull);
      expect(
        firstSampleEpochMsFromStopResult({'firstSampleEpochMs': 'x'}),
        isNull,
      );
    });
  });

  group('treo ghi khi không mở được segment mới', () {
    final now = DateTime(2026, 10, 20, 12);

    test('thiếu dung lượng: chờ tới mốc thử lại dung lượng', () {
      expect(
        suspendedRecorderRetryDelay(
          storageSuspended: true,
          nextStorageRetryAt: now.add(const Duration(minutes: 2)),
          now: now,
        ),
        const Duration(minutes: 2),
      );
      expect(
        suspendedRecorderRetryDelay(
          storageSuspended: true,
          nextStorageRetryAt: now.subtract(const Duration(seconds: 5)),
          now: now,
        ),
        const Duration(seconds: 1),
      );
      expect(
        suspendedRecorderRetryDelay(
          storageSuspended: true,
          nextStorageRetryAt: null,
          now: now,
        ),
        const Duration(minutes: 2),
      );
    });

    test('lỗi khác: thử lại sau 30 giây (không chờ cả segment)', () {
      expect(
        suspendedRecorderRetryDelay(
          storageSuspended: false,
          nextStorageRetryAt: null,
          now: now,
        ),
        const Duration(seconds: 30),
      );
    });

    test('service mới không ở trạng thái treo ghi', () {
      final service = RecordingService(cameraId: 'CAM1');
      expect(service.isRecordingSuspended, isFalse);
      expect(service.recordingSuspendedReason, isNull);
    });
  });

  test('tên segment trùng thêm hậu tố _1, _2 thay vì ghi đè', () {
    expect(segmentBaseNameCandidate('10-00-00_10-03-00', 0), '10-00-00_10-03-00');
    expect(
      segmentBaseNameCandidate('10-00-00_10-03-00', 1),
      '10-00-00_10-03-00_1',
    );
    expect(
      segmentBaseNameCandidate('10-00-00_10-03-00', 2),
      '10-00-00_10-03-00_2',
    );
  });

  group('clip xuất tạm theo phiên tablet', () {
    final now = DateTime(2026, 10, 20, 12);
    final fresh = now.subtract(const Duration(minutes: 1));
    final stale = now.subtract(exportClipTtl);

    test('đóng phiên chỉ xoá clip của đúng phiên đó', () {
      expect(
        shouldRemoveExportClip(
          clipOwner: 'ip:10.0.0.2',
          createdAt: fresh,
          now: now,
          closingOwner: 'ip:10.0.0.2',
        ),
        isTrue,
      );
      expect(
        shouldRemoveExportClip(
          clipOwner: 'ip:10.0.0.3',
          createdAt: fresh,
          now: now,
          closingOwner: 'ip:10.0.0.2',
        ),
        isFalse,
      );
      expect(
        shouldRemoveExportClip(
          clipOwner: null,
          createdAt: fresh,
          now: now,
          closingOwner: 'ip:10.0.0.2',
        ),
        isFalse,
      );
    });

    test('clip mồ côi quá 30 phút bị dọn, khởi động dọn tất cả', () {
      expect(
        shouldRemoveExportClip(clipOwner: 'peer:a', createdAt: stale, now: now),
        isTrue,
      );
      expect(
        shouldRemoveExportClip(clipOwner: 'peer:a', createdAt: fresh, now: now),
        isFalse,
      );
      expect(
        shouldRemoveExportClip(
          clipOwner: 'peer:a',
          createdAt: fresh,
          now: now,
          removeAll: true,
        ),
        isTrue,
      );
    });

    test('TTL tính từ lần đọc cuối: tablet tải muộn không bị dọn', () {
      final created = now.subtract(const Duration(minutes: 45));
      expect(
        shouldRemoveExportClip(
          clipOwner: 'peer:a',
          createdAt: created,
          lastAccessedAt: now.subtract(const Duration(minutes: 10)),
          now: now,
        ),
        isFalse,
      );
      expect(
        shouldRemoveExportClip(
          clipOwner: 'peer:a',
          createdAt: created,
          lastAccessedAt: now.subtract(exportClipTtl),
          now: now,
        ),
        isTrue,
      );
      // Lần đọc cũ hơn lúc tạo không làm rút ngắn TTL.
      expect(
        shouldRemoveExportClip(
          clipOwner: 'peer:a',
          createdAt: fresh,
          lastAccessedAt: now.subtract(const Duration(hours: 2)),
          now: now,
        ),
        isFalse,
      );
      // Đóng phiên/khởi động vẫn xoá bất kể lần đọc cuối.
      expect(
        shouldRemoveExportClip(
          clipOwner: 'peer:a',
          createdAt: created,
          lastAccessedAt: now,
          now: now,
          closingOwner: 'peer:a',
        ),
        isTrue,
      );
      expect(
        shouldRemoveExportClip(
          clipOwner: 'peer:a',
          createdAt: created,
          lastAccessedAt: now,
          now: now,
          removeAll: true,
        ),
        isTrue,
      );
    });
  });

  group('thay bản dự phòng bằng kết quả ghép lại', () {
    test('ghép lỗi: bỏ file tạm, bản cũ giữ nguyên', () {
      expect(
        fallbackReplacementAction(tempValid: false, previousLeased: false),
        FallbackReplacementAction.discardTemp,
      );
      expect(
        fallbackReplacementAction(tempValid: false, previousLeased: true),
        FallbackReplacementAction.discardTemp,
      );
    });

    test('bản cũ đang được đọc: hoãn, không thay', () {
      expect(
        fallbackReplacementAction(tempValid: true, previousLeased: true),
        FallbackReplacementAction.defer,
      );
    });

    test('ghép được và không ai đọc: thay', () {
      expect(
        fallbackReplacementAction(tempValid: true, previousLeased: false),
        FallbackReplacementAction.install,
      );
    });

    test('file tạm không bị chỉ mục/dọn dung lượng nhận là video', () {
      const root = '/storage/emulated/0/VNVAR';
      const previous = '$root/20-10-2026/AUTOMODE/CAM1/10-00-00_10-03-00.mp4';
      const ts = '$root/20-10-2026/AUTOMODE/CAM1/10-00-00_10-03-00.ts';
      for (final target in [previous, ts]) {
        final temp = fallbackRetryTempPath(target);
        expect(temp.startsWith(target), isTrue);
        expect(isAppManagedVideoPath(temp), isFalse);
        expect(isAppManagedVideoPath(temp, storageRoot: root), isFalse);
        expect(temp.toLowerCase().endsWith('.ts'), isFalse);
        expect(temp.toLowerCase().endsWith('.mp4'), isFalse);
        // Sót lại sau crash thì được dọn như file phụ trợ mồ côi.
        expect(isOrphanAuxiliaryFile(temp), isTrue);
      }
    });
  });

  group('bản MP4 dự phòng khi ghép tiếng lỗi', () {
    const maxAge = Duration(hours: 24);

    test('thử lại tối đa 3 lần rồi giữ bản dự phòng', () {
      for (var attempts = 1; attempts < maximumFallbackMuxAttempts; attempts++) {
        expect(
          preservedFallbackAction(
            attempts: attempts,
            finalExists: true,
            finalLeased: false,
            age: Duration.zero,
            maxAge: maxAge,
          ),
          PreservedFallbackAction.retry,
        );
      }
      expect(
        preservedFallbackAction(
          attempts: maximumFallbackMuxAttempts,
          finalExists: true,
          finalLeased: false,
          age: const Duration(hours: 1),
          maxAge: maxAge,
        ),
        PreservedFallbackAction.keep,
      );
      expect(
        preservedFallbackAction(
          attempts: maximumFallbackMuxAttempts,
          finalExists: true,
          finalLeased: false,
          age: maxAge,
          maxAge: maxAge,
        ),
        PreservedFallbackAction.discardSources,
      );
    });

    test('không thử lại khi tablet đang tải bản dự phòng', () {
      expect(
        preservedFallbackAction(
          attempts: 1,
          finalExists: true,
          finalLeased: true,
          age: Duration.zero,
          maxAge: maxAge,
        ),
        PreservedFallbackAction.keep,
      );
    });

    test('bản dự phòng đã bị xoá: không dựng lại, dọn nguồn sau hạn', () {
      expect(
        preservedFallbackAction(
          attempts: 1,
          finalExists: false,
          finalLeased: false,
          age: const Duration(hours: 1),
          maxAge: maxAge,
        ),
        PreservedFallbackAction.keep,
      );
      expect(
        preservedFallbackAction(
          attempts: 1,
          finalExists: false,
          finalLeased: false,
          age: maxAge,
          maxAge: maxAge,
        ),
        PreservedFallbackAction.discardSources,
      );
    });
  });
}
