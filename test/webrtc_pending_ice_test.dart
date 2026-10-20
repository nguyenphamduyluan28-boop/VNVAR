import 'package:camera_station/services/webrtc_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PendingIceCandidateQueues', () {
    test('evicts the oldest queue instead of rejecting a new peer', () {
      var now = DateTime(2026, 10, 20, 9);
      final queues = PendingIceCandidateQueues<String>(
        maxQueues: 2,
        clock: () => now,
      );
      expect(queues.add('a', 'a1'), isNull);
      now = now.add(const Duration(seconds: 1));
      expect(queues.add('b', 'b1'), isNull);
      now = now.add(const Duration(seconds: 1));

      // Đầy: peer mới vẫn được nhận, hàng đợi cũ nhất ("a") bị loại.
      expect(queues.add('c', 'c1'), 'a');
      expect(queues.containsKey('a'), isFalse);
      expect(queues.take('b'), ['b1']);
      expect(queues.take('c'), ['c1']);
      expect(queues.length, 0);
    });

    test('queues expire after the TTL', () {
      var now = DateTime(2026, 10, 20, 9);
      final queues = PendingIceCandidateQueues<String>(
        ttl: const Duration(seconds: 30),
        clock: () => now,
      );
      queues.add('a', 'a1');
      now = now.add(const Duration(seconds: 29));
      queues.add('a', 'a2');
      expect(queues.length, 1);

      // Tính từ lúc tạo hàng đợi, không gia hạn khi thêm candidate.
      now = now.add(const Duration(seconds: 2));
      expect(queues.length, 0);
      expect(queues.take('a'), isEmpty);
    });

    test('expired queues free their slot for new peers', () {
      var now = DateTime(2026, 10, 20, 9);
      final queues = PendingIceCandidateQueues<String>(
        maxQueues: 1,
        clock: () => now,
      );
      queues.add('old', 'x');
      now = now.add(const Duration(seconds: 31));
      expect(queues.add('new', 'y'), isNull);
      expect(queues.take('new'), ['y']);
    });

    test('keeps only the newest candidates per peer', () {
      final queues = PendingIceCandidateQueues<int>(maxPerQueue: 3);
      for (var i = 0; i < 5; i++) {
        queues.add('a', i);
      }
      expect(queues.take('a'), [2, 3, 4]);
    });

    test('remove drops a queue unconditionally', () {
      final queues = PendingIceCandidateQueues<String>();
      queues.add('a', 'a1');
      queues.remove('a');
      queues.remove('missing');
      expect(queues.take('a'), isEmpty);
    });
  });
}
