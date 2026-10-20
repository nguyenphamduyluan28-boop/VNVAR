import 'dart:io';

import 'package:camera_station/services/camera_server.dart';
import 'package:camera_station/services/recording_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = '/storage/emulated/0/VNVAR';
  const dir = '$root/20-10-2026/AUTOMODE/CAM1';

  group('đường dẫn TS thay bản MP4 dự phòng', () {
    test('cùng thư mục, cùng tên cơ sở, đuôi .ts', () {
      expect(
        supersedingTsPathForFallback('$dir/10-00-00_10-03-00.mp4'),
        '$dir/10-00-00_10-03-00.ts',
      );
      expect(
        supersedingTsPathForFallback('$dir/10-00-00_10-03-00_1.MP4'),
        '$dir/10-00-00_10-03-00_1.ts',
      );
    });

    test('không phải .mp4 thì null', () {
      expect(supersedingTsPathForFallback('$dir/a.ts'), isNull);
      expect(supersedingTsPathForFallback('$dir/a.mp4.retry.tmp'), isNull);
    });
  });

  group('khôi phục khoá pendingDelete', () {
    const mp4 = '$dir/10-00-00_10-03-00.mp4';

    PendingFallbackDeleteAction decide({
      Object? pendingDelete = mp4,
      String? finalPath = mp4,
      bool tsExists = true,
      bool tsPlayable = true,
      bool mp4Leased = false,
    }) => pendingFallbackDeleteAction(
      pendingDelete: pendingDelete,
      finalPath: finalPath,
      tsExists: tsExists,
      tsPlayable: tsPlayable,
      mp4Leased: mp4Leased,
    );

    test('không có khoá: xử lý bình thường', () {
      expect(decide(pendingDelete: null), PendingFallbackDeleteAction.none);
    });

    test('TS đã vào chỗ, không ai đọc: xoá bản MP4 trùng', () {
      expect(decide(), PendingFallbackDeleteAction.deleteSuperseded);
    });

    test('bản MP4 đang được đọc: chờ, không xoá', () {
      expect(
        decide(mp4Leased: true),
        PendingFallbackDeleteAction.waitForLease,
      );
    });

    test('TS chưa vào chỗ: gỡ khoá, giữ MP4', () {
      expect(decide(tsExists: false), PendingFallbackDeleteAction.clearStale);
      expect(
        decide(tsExists: false, tsPlayable: false),
        PendingFallbackDeleteAction.clearStale,
      );
    });

    test('TS dở dang (không đọc được): bỏ TS, giữ MP4', () {
      expect(
        decide(tsPlayable: false),
        PendingFallbackDeleteAction.discardBrokenTs,
      );
    });

    test('khoá không khớp bản dự phòng hoặc sai kiểu: chỉ gỡ khoá', () {
      expect(
        decide(finalPath: '$dir/10-05-00_10-08-00.mp4'),
        PendingFallbackDeleteAction.clearStale,
      );
      expect(decide(finalPath: null), PendingFallbackDeleteAction.clearStale);
      expect(decide(pendingDelete: 42), PendingFallbackDeleteAction.clearStale);
      expect(
        decide(
          pendingDelete: '$dir/10-00-00_10-03-00.ts',
          finalPath: '$dir/10-00-00_10-03-00.ts',
        ),
        PendingFallbackDeleteAction.clearStale,
      );
    });
  });

  group('chỉ mục ưu tiên .ts khi có cặp .ts/.mp4 cùng tên', () {
    test('cặp cùng thư mục, cùng tên cơ sở: bỏ .mp4', () {
      final pairs = supersededFallbackVideoPairs([
        '$dir/10-00-00_10-03-00.mp4',
        '$dir/10-00-00_10-03-00.ts',
        '$dir/10-03-00_10-06-00.ts',
      ], storageRoot: root);
      expect(pairs, {
        '$dir/10-00-00_10-03-00.mp4': '$dir/10-00-00_10-03-00.ts',
      });
      // Thứ tự liệt kê không ảnh hưởng.
      expect(
        supersededFallbackVideoPairs([
          '$dir/10-00-00_10-03-00.ts',
          '$dir/10-00-00_10-03-00.mp4',
        ], storageRoot: root),
        pairs,
      );
    });

    test('không ghép file khác tên cơ sở (kể cả hậu tố _1, chữ hoa)', () {
      expect(
        supersededFallbackVideoPairs([
          '$dir/10-00-00_10-03-00.mp4',
          '$dir/10-00-00_10-03-00_1.ts',
          '$dir/10-03-00_10-06-00_1.mp4',
          '$dir/10-03-00_10-06-00.ts',
          '$dir/ABC.mp4',
          '$dir/abc.ts',
        ], storageRoot: root),
        isEmpty,
      );
    });

    test('không ghép file cùng tên ở thư mục khác', () {
      expect(
        supersededFallbackVideoPairs([
          '$dir/10-00-00_10-03-00.mp4',
          '$root/20-10-2026/AUTOMODE/CAM2/10-00-00_10-03-00.ts',
          '$root/21-10-2026/AUTOMODE/CAM1/10-00-00_10-03-00.ts',
        ], storageRoot: root),
        isEmpty,
      );
    });

    test('file không do app quản lý không bị ẩn', () {
      expect(
        supersededFallbackVideoPairs([
          '$root/Movies/holiday.mp4',
          '$root/Movies/holiday.ts',
        ], storageRoot: root),
        isEmpty,
      );
      // Nằm ngoài gốc lưu.
      expect(
        supersededFallbackVideoPairs([
          '/other/20-10-2026/AUTOMODE/CAM1/a.mp4',
          '/other/20-10-2026/AUTOMODE/CAM1/a.ts',
        ], storageRoot: root),
        isEmpty,
      );
    });

    test('đuôi viết hoa vẫn được nhận cặp', () {
      expect(
        supersededFallbackVideoPairs([
          '$dir/10-00-00_10-03-00.MP4',
          '$dir/10-00-00_10-03-00.TS',
        ], storageRoot: root),
        {'$dir/10-00-00_10-03-00.MP4': '$dir/10-00-00_10-03-00.TS'},
      );
    });

    test('file tạm .retry.tmp không tham gia ghép cặp', () {
      expect(
        supersededFallbackVideoPairs([
          '$dir/10-00-00_10-03-00.mp4',
          fallbackRetryTempPath('$dir/10-00-00_10-03-00.ts'),
        ], storageRoot: root),
        isEmpty,
      );
    });
  });

  group('cặp .ts/.mp4: lượt thay chưa hoàn tất thì giữ MP4', () {
    test('còn khoá pendingDelete và MP4 còn: ưu tiên MP4', () {
      expect(
        preferFallbackMp4OverTs(pendingDelete: true, mp4Exists: true),
        isTrue,
      );
    });

    test('không còn khoá hoặc MP4 đã bị xoá: ưu tiên TS', () {
      expect(
        preferFallbackMp4OverTs(pendingDelete: false, mp4Exists: true),
        isFalse,
      );
      expect(
        preferFallbackMp4OverTs(pendingDelete: true, mp4Exists: false),
        isFalse,
      );
      expect(
        preferFallbackMp4OverTs(
          pendingDelete: false,
          mp4Exists: false,
          tsExists: false,
        ),
        isFalse,
      );
    });

    test('TS đã bị gỡ (lượt thay hoãn): giữ MP4', () {
      expect(
        preferFallbackMp4OverTs(
          pendingDelete: false,
          mp4Exists: true,
          tsExists: false,
        ),
        isTrue,
      );
    });
  });

  group('dọn *.retry.tmp sót khi thư mục còn video', () {
    final now = DateTime(2026, 10, 20, 12);
    final temp = fallbackRetryTempPath('$dir/10-00-00_10-03-00.ts');

    test('cũ hơn 10 phút và không có lượt thử đang chạy: dọn', () {
      expect(
        isStaleFallbackRetryTemp(
          path: temp,
          modified: now.subtract(staleFallbackRetryTempAge),
          now: now,
          retryInFlight: false,
        ),
        isTrue,
      );
    });

    test('còn mới hoặc đang có lượt thử: giữ', () {
      expect(
        isStaleFallbackRetryTemp(
          path: temp,
          modified: now.subtract(const Duration(minutes: 9)),
          now: now,
          retryInFlight: false,
        ),
        isFalse,
      );
      expect(
        isStaleFallbackRetryTemp(
          path: temp,
          modified: now.subtract(const Duration(hours: 5)),
          now: now,
          retryInFlight: true,
        ),
        isFalse,
      );
    });

    test('không đụng file khác', () {
      final old = now.subtract(const Duration(days: 1));
      for (final path in [
        '$dir/10-00-00_10-03-00.ts',
        '$dir/10-00-00_10-03-00.mp4',
        '$dir/10-00-00_10-03-00.wav',
        '$dir/10-00-00_10-03-00.json',
        '$dir/other.tmp',
        '$dir/.retry.tmp',
      ]) {
        expect(
          isStaleFallbackRetryTemp(
            path: path,
            modified: old,
            now: now,
            retryInFlight: false,
          ),
          isFalse,
          reason: path,
        );
      }
    });
  });

  group('mở recorder khi mất video track', () {
    test('lỗi tạm thời (503), vẫn là StateError như trước', () {
      final error = CameraVideoTrackUnavailableError();
      expect(error, isA<StateError>());
      expect(error.message, 'Camera video track unavailable.');
      expect(isTransientRecorderStartError(error), isTrue);
      expect(transientRecorderStartRetryAfterSeconds, greaterThan(0));
      expect(HttpStatus.serviceUnavailable, 503);
    });

    test('nội dung 503: Service Unavailable + retryable, 500 giữ nguyên', () {
      expect(transientRequestErrorBody(transient: true), {
        'error': 'Service Unavailable',
        'message': 'Camera Station không thể xử lý yêu cầu.',
        'retryable': true,
      });
      expect(transientRequestErrorBody(transient: false), {
        'error': 'Internal Server Error',
        'message': 'Camera Station không thể xử lý yêu cầu.',
      });
    });

    test('lỗi khác vẫn là 500', () {
      expect(isTransientRecorderStartError(StateError('x')), isFalse);
      expect(
        isTransientRecorderStartError(const FormatException('x')),
        isFalse,
      );
    });
  });
}
