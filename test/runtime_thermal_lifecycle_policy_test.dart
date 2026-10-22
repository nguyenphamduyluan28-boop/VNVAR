import 'package:camera_station/services/camera_station_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

ThermalDimAction _dim({
  bool dimmedByThermal = false,
  bool autoDimAllowed = true,
  bool planWantsDim = false,
  bool riseWantsDim = false,
  bool cooled = false,
}) => thermalScreenDimDecision(
  dimmedByThermal: dimmedByThermal,
  autoDimAllowed: autoDimAllowed,
  planWantsDim: planWantsDim,
  riseWantsDim: riseWantsDim,
  cooled: cooled,
);

bool _zoom({
  bool cameraEnabled = true,
  bool initialized = true,
  bool stopping = false,
  bool profileSwitching = false,
  bool lensSwitching = false,
  bool recovering = false,
  bool openBlocked = false,
  bool lifecycleBusy = false,
}) => cameraZoomAllowed(
  cameraEnabled: cameraEnabled,
  initialized: initialized,
  stopping: stopping,
  profileSwitching: profileSwitching,
  lensSwitching: lensSwitching,
  recovering: recovering,
  openBlocked: openBlocked,
  lifecycleBusy: lifecycleBusy,
);

void main() {
  group('thermalScreenDimDecision', () {
    test('does not undim while the load plan still wants a dim screen', () {
      // Trước đây: bật sáng ở đây rồi kế hoạch tải làm tối lại 10 s sau.
      expect(
        _dim(dimmedByThermal: true, cooled: true, planWantsDim: true),
        ThermalDimAction.none,
      );
    });

    test('undims once cooled and the plan no longer wants dim', () {
      expect(
        _dim(dimmedByThermal: true, cooled: true),
        ThermalDimAction.undim,
      );
    });

    test('keeps a thermal dim while not cooled', () {
      expect(_dim(dimmedByThermal: true), ThermalDimAction.none);
      expect(
        _dim(dimmedByThermal: true, riseWantsDim: true),
        ThermalDimAction.none,
      );
    });

    test('dims for the load plan or a fast temperature rise', () {
      expect(_dim(planWantsDim: true), ThermalDimAction.dim);
      expect(_dim(riseWantsDim: true), ThermalDimAction.dim);
    });

    test('respects the user brightness hold / user choice', () {
      expect(
        _dim(autoDimAllowed: false, planWantsDim: true, riseWantsDim: true),
        ThermalDimAction.none,
      );
    });

    test('does nothing when nothing asks for a dim screen', () {
      expect(_dim(), ThermalDimAction.none);
      expect(_dim(cooled: true), ThermalDimAction.none);
    });

    test('a fresh dim is never immediately undone (no flicker)', () {
      // Lần kiểm tra kế tiếp sau khi làm tối vì kế hoạch tải: chưa nguội
      // hoặc kế hoạch vẫn yêu cầu → giữ tối.
      for (final cooled in [false, true]) {
        expect(
          _dim(dimmedByThermal: true, planWantsDim: true, cooled: cooled),
          ThermalDimAction.none,
        );
      }
    });
  });

  group('startupThermalDegradeRequired', () {
    test('hot alone does not change the resolution at startup', () {
      expect(
        startupThermalDegradeRequired(critical: false, emergency: false),
        isFalse,
      );
    });

    test('critical or emergency degrades to the safe profile', () {
      expect(
        startupThermalDegradeRequired(critical: true, emergency: false),
        isTrue,
      );
      expect(
        startupThermalDegradeRequired(critical: true, emergency: true),
        isTrue,
      );
      expect(
        startupThermalDegradeRequired(critical: false, emergency: true),
        isTrue,
      );
    });
  });

  group('reportedThermalFpsCap', () {
    test('iOS never reports a cap (not applied in place)', () {
      expect(
        reportedThermalFpsCap(
          isAndroid: false,
          trackId: 't1',
          appliedKey: 't1|24',
        ),
        isNull,
      );
    });

    test('Android reports the cap applied to the current track', () {
      expect(
        reportedThermalFpsCap(
          isAndroid: true,
          trackId: 't1',
          appliedKey: 't1|24',
        ),
        24,
      );
    });

    test('no cap for a cleared cap, another track or nothing applied', () {
      expect(
        reportedThermalFpsCap(
          isAndroid: true,
          trackId: 't1',
          appliedKey: 't1|0',
        ),
        isNull,
      );
      expect(
        reportedThermalFpsCap(
          isAndroid: true,
          trackId: 't2',
          appliedKey: 't1|24',
        ),
        isNull,
      );
      expect(
        reportedThermalFpsCap(isAndroid: true, trackId: 't1', appliedKey: null),
        isNull,
      );
      expect(
        reportedThermalFpsCap(
          isAndroid: true,
          trackId: null,
          appliedKey: 't1|24',
        ),
        isNull,
      );
    });

    test('track id prefix must match exactly', () {
      expect(
        reportedThermalFpsCap(
          isAndroid: true,
          trackId: 't1',
          appliedKey: 't10|24',
        ),
        isNull,
      );
    });
  });

  group('reconfigurationShouldInterruptRecovery', () {
    test('interrupts only when the camera will really be reopened', () {
      expect(
        reconfigurationShouldInterruptRecovery(
          cameraEnabled: true,
          openBlocked: false,
          changesConfiguration: true,
        ),
        isTrue,
      );
    });

    test('same configuration keeps the running recovery', () {
      expect(
        reconfigurationShouldInterruptRecovery(
          cameraEnabled: true,
          openBlocked: false,
          changesConfiguration: false,
        ),
        isFalse,
      );
    });

    test('rejected operations (camera off / blocked) keep recovery', () {
      expect(
        reconfigurationShouldInterruptRecovery(
          cameraEnabled: false,
          openBlocked: false,
          changesConfiguration: true,
        ),
        isFalse,
      );
      expect(
        reconfigurationShouldInterruptRecovery(
          cameraEnabled: true,
          openBlocked: true,
          changesConfiguration: true,
        ),
        isFalse,
      );
    });
  });

  group('cameraZoomAllowed', () {
    test('allowed on an idle, ready camera', () {
      expect(_zoom(), isTrue);
    });

    test('blocked while the camera is being opened or reconfigured', () {
      expect(_zoom(cameraEnabled: false), isFalse);
      expect(_zoom(initialized: false), isFalse);
      expect(_zoom(stopping: true), isFalse);
      expect(_zoom(profileSwitching: true), isFalse);
      expect(_zoom(lensSwitching: true), isFalse);
      expect(_zoom(recovering: true), isFalse);
      expect(_zoom(openBlocked: true), isFalse);
      expect(_zoom(lifecycleBusy: true), isFalse);
    });
  });

  group('SharedTaskHold', () {
    test('begins once, ends once after the last release', () async {
      var begins = 0;
      var ends = 0;
      final hold = SharedTaskHold(
        onFirstAcquire: () {
          begins++;
        },
        onLastRelease: () async {
          ends++;
        },
      );
      final first = hold.acquire();
      // Bắt đầu đồng bộ ngay trong acquire.
      expect(begins, 1);
      final second = hold.acquire();
      expect(begins, 1);
      expect(hold.holds, 2);

      await first();
      expect(ends, 0);
      // Trả lại lần nữa (ví dụ whenComplete + finally) không có tác dụng.
      await first();
      expect(hold.holds, 1);
      expect(ends, 0);

      await second();
      expect(ends, 1);
      expect(hold.holds, 0);
      await second();
      expect(ends, 1);
    });

    test('a new hold after the last release begins again', () async {
      var begins = 0;
      var ends = 0;
      final hold = SharedTaskHold(
        onFirstAcquire: () {
          begins++;
        },
        onLastRelease: () async {
          ends++;
        },
      );
      await hold.acquire()();
      final again = hold.acquire();
      expect(begins, 2);
      await again();
      expect(ends, 2);
    });
  });
}
