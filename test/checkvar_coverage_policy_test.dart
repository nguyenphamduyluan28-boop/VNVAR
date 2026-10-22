import 'package:camera_station/services/camera_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 10, 22, 14);

  group('mốc cần có trong file nguồn', () {
    test('dùng thời điểm sự kiện, không muộn hơn lúc nhận request', () {
      final received = t0.add(const Duration(seconds: 10));
      expect(
        checkVarCoverageTarget(
          requestedAt: t0.add(const Duration(seconds: 8)),
          receivedAt: received,
        ),
        t0.add(const Duration(seconds: 8)),
      );
      // Đồng hồ tablet nhanh hơn 3 giây.
      expect(
        checkVarCoverageTarget(
          requestedAt: received.add(const Duration(seconds: 3)),
          receivedAt: received,
        ),
        received,
      );
    });
  });

  group('segment nguồn có chứa thời điểm sự kiện', () {
    test('segment kết thúc sau (hoặc sát) sự kiện → đủ', () {
      expect(
        checkVarSourceCoverage(
          sourceEndedAt: t0,
          target: t0.subtract(const Duration(seconds: 1)),
          activeStartedAt: t0.add(const Duration(milliseconds: 400)),
        ),
        CheckVarSourceCoverage.covered,
      );
      expect(
        checkVarSourceCoverage(
          sourceEndedAt: t0,
          target: t0.add(const Duration(milliseconds: 250)),
          activeStartedAt: null,
        ),
        CheckVarSourceCoverage.covered,
      );
    });

    test('nhập vào lượt xoay định kỳ: sự kiện ở segment đang ghi → chốt tiếp',
        () {
      // Lượt xoay chốt segment cũ lúc t0, mở segment mới lúc t0+0,5s; trọng
      // tài bấm lúc t0+4s khi FFmpeg còn đóng gói segment cũ.
      expect(
        checkVarSourceCoverage(
          sourceEndedAt: t0,
          target: t0.add(const Duration(seconds: 4)),
          activeStartedAt: t0.add(const Duration(milliseconds: 500)),
        ),
        CheckVarSourceCoverage.needsActiveSegment,
      );
    });

    test('sự kiện rơi vào khoảng hở ngắn giữa hai recorder → dùng segment cũ',
        () {
      expect(
        checkVarSourceCoverage(
          sourceEndedAt: t0,
          target: t0.add(const Duration(milliseconds: 600)),
          activeStartedAt: t0.add(const Duration(milliseconds: 900)),
        ),
        CheckVarSourceCoverage.unrecordedGap,
      );
    });

    test('không có recorder sau segment nguồn → thiếu dữ liệu', () {
      expect(
        checkVarSourceCoverage(
          sourceEndedAt: t0,
          target: t0.add(const Duration(seconds: 1)),
          activeStartedAt: null,
        ),
        CheckVarSourceCoverage.missing,
      );
      expect(
        checkVarSourceCoverage(
          sourceEndedAt: t0,
          target: t0.add(const Duration(seconds: 10)),
          activeStartedAt: t0.add(const Duration(seconds: 20)),
        ),
        CheckVarSourceCoverage.missing,
      );
    });
  });

  group('chờ segment đang ghi đủ dài trước khi chốt', () {
    test('segment vừa mở: chờ tới đủ tuổi tối thiểu', () {
      expect(
        checkVarActiveSegmentWait(
          activeStartedAt: t0,
          now: t0.add(const Duration(milliseconds: 500)),
        ),
        checkVarMinimumActiveSegmentAge - const Duration(milliseconds: 500),
      );
    });

    test('segment đã đủ tuổi: không chờ', () {
      expect(
        checkVarActiveSegmentWait(
          activeStartedAt: t0,
          now: t0.add(const Duration(seconds: 10)),
        ),
        Duration.zero,
      );
    });

    test('đồng hồ lùi (mốc bắt đầu ở tương lai): chờ đủ tuổi tối thiểu', () {
      expect(
        checkVarActiveSegmentWait(
          activeStartedAt: t0.add(const Duration(seconds: 1)),
          now: t0,
        ),
        checkVarMinimumActiveSegmentAge,
      );
    });

    test('timeout chốt segment kế: phần đã ghi (≤ 1 segment) + biên', () {
      const segment = Duration(minutes: 3);
      expect(
        checkVarFollowUpTimeout(
          activeAge: const Duration(seconds: 5),
          segmentDuration: segment,
        ),
        const Duration(seconds: 35) + checkVarMinimumActiveSegmentAge,
      );
      expect(
        checkVarFollowUpTimeout(
          activeAge: const Duration(minutes: 10),
          segmentDuration: segment,
        ),
        segment + const Duration(seconds: 30) + checkVarMinimumActiveSegmentAge,
      );
      expect(
        checkVarFollowUpTimeout(
          activeAge: const Duration(seconds: -2),
          segmentDuration: segment,
        ),
        const Duration(seconds: 30) + checkVarMinimumActiveSegmentAge,
      );
    });
  });

  group('/trim thủ công', () {
    test('tối đa 10 phút', () {
      expect(maximumManualTrimDurationMs, 10 * 60 * 1000);
      expect(isManualTrimDurationAllowed(startMs: 0, endMs: 600000), isTrue);
      expect(
        isManualTrimDurationAllowed(startMs: 1000, endMs: 601001),
        isFalse,
      );
      expect(
        isManualTrimDurationAllowed(startMs: 120000.5, endMs: 130000),
        isTrue,
      );
    });
  });

  group('requestId trong /checkvar/jobs/{requestId}', () {
    test('giải mã bình thường', () {
      expect(decodeCheckVarJobId('abc-123'), 'abc-123');
      expect(decodeCheckVarJobId('a%20b'), 'a b');
    });

    test('mã % hỏng → null (trả 400, không phải 500)', () {
      expect(decodeCheckVarJobId('%ff'), isNull);
      expect(decodeCheckVarJobId('%E0%A4'), isNull);
      expect(decodeCheckVarJobId('%zz'), isNull);
    });
  });
}
