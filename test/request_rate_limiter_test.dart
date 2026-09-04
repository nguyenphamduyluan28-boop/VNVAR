import 'package:camera_station/services/request_rate_limiter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('limits one client within a sliding time window', () {
    final limiter = RequestRateLimiter();
    final now = DateTime(2026, 9, 4, 10);

    expect(
      limiter.allow(
        'client:offer',
        maximumRequests: 2,
        window: const Duration(minutes: 1),
        now: now,
      ),
      isTrue,
    );
    expect(
      limiter.allow(
        'client:offer',
        maximumRequests: 2,
        window: const Duration(minutes: 1),
        now: now.add(const Duration(seconds: 1)),
      ),
      isTrue,
    );
    expect(
      limiter.allow(
        'client:offer',
        maximumRequests: 2,
        window: const Duration(minutes: 1),
        now: now.add(const Duration(seconds: 2)),
      ),
      isFalse,
    );
    expect(
      limiter.allow(
        'client:offer',
        maximumRequests: 2,
        window: const Duration(minutes: 1),
        now: now.add(const Duration(seconds: 61)),
      ),
      isTrue,
    );
  });

  test('keeps independent clients in independent buckets', () {
    final limiter = RequestRateLimiter();
    final now = DateTime(2026, 9, 4, 10);

    expect(
      limiter.allow(
        'client-a:control',
        maximumRequests: 1,
        window: const Duration(minutes: 1),
        now: now,
      ),
      isTrue,
    );
    expect(
      limiter.allow(
        'client-b:control',
        maximumRequests: 1,
        window: const Duration(minutes: 1),
        now: now,
      ),
      isTrue,
    );
  });
}
