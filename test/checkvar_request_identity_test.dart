import 'package:camera_station/services/camera_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps a safe client request id for idempotent retries', () {
    final receivedAt = DateTime(2026, 9, 7, 10);

    expect(
      normalizeCheckVarRequestId('match-01:event 42', receivedAt),
      'match-01_event_42',
    );
    expect(normalizeCheckVarRequestId('', receivedAt), startsWith('checkvar_'));
  });

  test('uses the original event time for a recent network retry', () {
    final receivedAt = DateTime(2026, 9, 7, 10, 0, 30);
    final eventAt = receivedAt.subtract(const Duration(seconds: 20));

    expect(
      checkVarEventTime(eventAt.millisecondsSinceEpoch.toString(), receivedAt),
      eventAt,
    );
  });

  test('rejects stale or implausible client event clocks', () {
    final receivedAt = DateTime(2026, 9, 7, 10);

    expect(
      checkVarEventTime(
        receivedAt
            .subtract(const Duration(minutes: 11))
            .millisecondsSinceEpoch
            .toString(),
        receivedAt,
      ),
      receivedAt,
    );
    expect(
      checkVarEventTime(
        receivedAt
            .add(const Duration(seconds: 6))
            .millisecondsSinceEpoch
            .toString(),
        receivedAt,
      ),
      receivedAt,
    );
  });
}
