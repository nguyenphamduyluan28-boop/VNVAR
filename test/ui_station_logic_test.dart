import 'dart:async';

import 'package:camera_station/models/station_identity.dart';
import 'package:camera_station/screens/station/station_ui_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const current = StationIdentity(
    courtId: 'COURT-01',
    cameraId: 'CAM-01',
    deviceId: 'PHONE-ABC123',
    cameraName: 'Camera 01',
  );

  group('classifyStationConfigChange', () {
    test('không đổi gì thì không khởi động lại', () {
      expect(
        classifyStationConfigChange(
          current: current,
          next: current.copyWith(),
          stationRunning: true,
        ),
        StationConfigChange.none,
      );
    });

    test('bỏ qua khoảng trắng thừa', () {
      expect(
        classifyStationConfigChange(
          current: current,
          next: current.copyWith(courtId: ' COURT-01 '),
          stationRunning: true,
        ),
        StationConfigChange.none,
      );
    });

    test('chỉ đổi tên/vị trí camera thì chỉ lưu', () {
      expect(
        classifyStationConfigChange(
          current: current,
          next: current.copyWith(cameraName: 'Camera trái'),
          stationRunning: true,
        ),
        StationConfigChange.metadataOnly,
      );
      expect(
        classifyStationConfigChange(
          current: current,
          next: current.copyWith(cameraPosition: 'left'),
          stationRunning: true,
        ),
        StationConfigChange.metadataOnly,
      );
    });

    test('đổi sân/camera/thiết bị thì phải khởi động lại', () {
      for (final next in [
        current.copyWith(courtId: 'COURT-02'),
        current.copyWith(cameraId: 'CAM-02'),
        current.copyWith(deviceId: 'PHONE-XYZ999'),
        current.copyWith(courtId: 'COURT-02', cameraName: 'Camera 02'),
      ]) {
        expect(
          classifyStationConfigChange(
            current: current,
            next: next,
            stationRunning: true,
          ),
          StationConfigChange.restartRequired,
        );
      }
    });

    test('trạm đang không chạy thì luôn khởi động lại', () {
      expect(
        classifyStationConfigChange(
          current: current,
          next: current,
          stationRunning: false,
        ),
        StationConfigChange.restartRequired,
      );
    });
  });

  group('secondsUntil', () {
    final now = DateTime(2026, 1, 1, 12);

    test('null khi không có mốc', () {
      expect(secondsUntil(null, now), isNull);
    });

    test('làm tròn lên và không âm', () {
      expect(secondsUntil(now.add(const Duration(seconds: 5)), now), 5);
      expect(
        secondsUntil(now.add(const Duration(milliseconds: 4100)), now),
        5,
      );
      expect(
        secondsUntil(now.add(const Duration(milliseconds: 1)), now),
        1,
      );
      expect(secondsUntil(now, now), 0);
      expect(secondsUntil(now.subtract(const Duration(seconds: 3)), now), 0);
    });
  });

  group('formatLiveDuration', () {
    test('mm:ss dưới 1 giờ', () {
      expect(formatLiveDuration(Duration.zero), '00:00');
      expect(formatLiveDuration(const Duration(seconds: 65)), '01:05');
      expect(formatLiveDuration(const Duration(minutes: 59, seconds: 59)),
          '59:59');
    });

    test('h:mm:ss từ 1 giờ', () {
      expect(
        formatLiveDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03',
      );
    });
  });

  group('compactErrorText', () {
    test('chỉ lấy dòng đầu có nội dung', () {
      expect(compactErrorText('\n  Lỗi camera  \nchi tiết'), 'Lỗi camera');
    });

    test('cắt ngắn thông báo quá dài', () {
      final text = compactErrorText('a' * 300);
      expect(text.length, 240);
      expect(text.endsWith('...'), isTrue);
    });
  });

  group('LatestWinsRunner', () {
    test('chỉ áp dụng yêu cầu mới nhất sau thao tác đang chạy', () async {
      final applied = <double>[];
      final gates = <Completer<void>>[];
      final runner = LatestWinsRunner<double>((value) {
        applied.add(value);
        final gate = Completer<void>();
        gates.add(gate);
        return gate.future;
      });

      final done = runner.submit(1.0);
      expect(runner.busy, isTrue);
      unawaited(runner.submit(2.0));
      unawaited(runner.submit(5.0));
      await Future<void>.delayed(Duration.zero);
      expect(applied, [1.0]);

      gates[0].complete();
      await Future<void>.delayed(Duration.zero);
      expect(applied, [1.0, 5.0]);

      gates[1].complete();
      await done;
      expect(applied, [1.0, 5.0]);
      expect(runner.busy, isFalse);
    });

    test('bỏ yêu cầu chờ trùng với yêu cầu vừa chạy', () async {
      final applied = <int>[];
      final gate = Completer<void>();
      final runner = LatestWinsRunner<int>((value) {
        applied.add(value);
        return value == 1 ? gate.future : Future<void>.value();
      });

      final done = runner.submit(1);
      unawaited(runner.submit(2));
      unawaited(runner.submit(1));
      gate.complete();
      await done;
      expect(applied, [1]);
    });

    test('lỗi không dừng hàng đợi và được báo qua onError', () async {
      final applied = <int>[];
      final errors = <Object>[];
      var idleCalls = 0;
      final gate = Completer<void>();
      final runner = LatestWinsRunner<int>(
        (value) async {
          applied.add(value);
          if (value == 1) {
            await gate.future;
            throw StateError('lens busy');
          }
        },
        onError: (error, _) => errors.add(error),
        onIdle: () => idleCalls++,
      );

      final done = runner.submit(1);
      unawaited(runner.submit(2));
      gate.complete();
      await done;
      expect(applied, [1, 2]);
      expect(errors, hasLength(1));
      expect(idleCalls, 1);
      expect(runner.busy, isFalse);
    });

    test('hasPending báo có yêu cầu mới chờ sau thao tác đang chạy', () async {
      final gates = <Completer<void>>[];
      final pendingDuringRun = <bool>[];
      late final LatestWinsRunner<int> runner;
      runner = LatestWinsRunner<int>((value) async {
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
        pendingDuringRun.add(runner.hasPending);
      });

      expect(runner.hasPending, isFalse);
      final done = runner.submit(1);
      // Yêu cầu đầu được lấy ra chạy ngay: không còn yêu cầu chờ.
      await Future<void>.delayed(Duration.zero);
      expect(runner.hasPending, isFalse);

      unawaited(runner.submit(2));
      expect(runner.hasPending, isTrue);
      gates[0].complete();
      await Future<void>.delayed(Duration.zero);
      // Yêu cầu 2 đang chạy, không còn gì chờ.
      expect(runner.hasPending, isFalse);

      gates[1].complete();
      await done;
      // Lúc thao tác 1 xong vẫn còn yêu cầu 2 chờ; lúc thao tác 2 xong thì không.
      expect(pendingDuringRun, [true, false]);
      expect(runner.hasPending, isFalse);
    });

    test('hasPending là false sau dispose', () async {
      final gate = Completer<void>();
      final runner = LatestWinsRunner<int>((_) => gate.future);
      final done = runner.submit(1);
      unawaited(runner.submit(2));
      expect(runner.hasPending, isTrue);
      runner.dispose();
      expect(runner.hasPending, isFalse);
      gate.complete();
      await done;
    });

    test('dispose bỏ yêu cầu đang chờ', () async {
      final applied = <int>[];
      final gate = Completer<void>();
      final runner = LatestWinsRunner<int>((value) {
        applied.add(value);
        return gate.future;
      });

      final done = runner.submit(1);
      unawaited(runner.submit(2));
      runner.dispose();
      gate.complete();
      await done;
      expect(applied, [1]);
      await runner.submit(3);
      expect(applied, [1]);
    });
  });
}
