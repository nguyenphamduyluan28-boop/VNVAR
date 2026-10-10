import 'package:camera_station/services/recording_service.dart';
import 'package:flutter_test/flutter_test.dart';

RecordedSegment _segment(
  String id,
  DateTime start,
  DateTime end, {
  String camera = 'CAM1',
  String path = '/v/a.ts',
  String type = 'RECORDING',
}) => RecordedSegment(
  id: id,
  cameraId: camera,
  path: path,
  startedAt: start,
  endedAt: end,
  type: type,
);

void main() {
  final t0 = DateTime(2026, 10, 9, 20);
  final previous = _segment('prev', t0, t0.add(const Duration(minutes: 3)));
  final current = _segment(
    'cur',
    t0.add(const Duration(minutes: 3, milliseconds: 400)),
    t0.add(const Duration(minutes: 4)),
  );

  test('finds the segment recorded right before the current one', () {
    expect(selectPrecedingSegment([previous, current], current), previous);
  });

  test('ignores gaps, other cameras, clips and MP4 fallbacks', () {
    final old = _segment(
      'old',
      t0.subtract(const Duration(minutes: 10)),
      t0.subtract(const Duration(minutes: 7)),
    );
    final otherCamera = _segment(
      'cam2',
      t0,
      t0.add(const Duration(minutes: 3)),
      camera: 'CAM2',
    );
    final clip = _segment(
      'clip',
      t0,
      t0.add(const Duration(minutes: 3)),
      type: 'CLIP',
    );
    final mp4 = _segment(
      'mp4',
      t0,
      t0.add(const Duration(minutes: 3)),
      path: '/v/a.mp4',
    );
    expect(
      selectPrecedingSegment([old, otherCamera, clip, mp4, current], current),
      isNull,
    );
  });
}
