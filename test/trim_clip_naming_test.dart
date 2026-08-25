import 'package:camera_station/services/recording_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses camera number and millisecond timestamp in MP4 clip name', () {
    expect(
      buildTrimmedClipFileName('CAM1', 1787624130000),
      'cam1_trim_1787624130000.mp4',
    );
    expect(
      buildTrimmedClipFileName('CAM-01', 1787624130000),
      'cam1_trim_1787624130000.mp4',
    );
  });

  test('sanitizes non-numbered camera IDs for safe file names', () {
    expect(
      buildTrimmedClipFileName('Camera Left/VAR', 1787624130000),
      'camera_left_var_trim_1787624130000.mp4',
    );
  });

  test('normalizes camera IDs consistently for folders and indexes', () {
    expect(normalizeCameraKey('CAM-01'), 'cam1');
    expect(normalizeCameraKey(' Camera Left/VAR '), 'camera_left_var');
    expect(normalizeCameraKey('///'), 'camera');
  });
}
