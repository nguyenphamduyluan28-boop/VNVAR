import 'dart:io';

import 'package:camera_station/services/station_errors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BilingualMessage errors', () {
    test('BilingualStateError keeps StateError text and type', () {
      final error = BilingualStateError('Camera chưa sẵn sàng.', 'Not ready.');
      expect(error, isA<StateError>());
      expect(error.message, 'Camera chưa sẵn sàng.');
      expect(error.toString(), 'Bad state: Camera chưa sẵn sàng.');
      expect(
        stationErrorMessage(error, english: false),
        'Camera chưa sẵn sàng.',
      );
      expect(stationErrorMessage(error, english: true), 'Not ready.');
    });

    test('BilingualException keeps Exception text', () {
      const error = BilingualException('Lỗi máy chủ.', 'Server error.');
      expect(error.toString(), 'Exception: Lỗi máy chủ.');
      expect(error.localized(english: true), 'Server error.');
      expect(stationErrorMessage(error, english: false), 'Lỗi máy chủ.');
    });

    test('BilingualFileSystemException keeps FileSystemException text', () {
      const error = BilingualFileSystemException(
        'Video không còn tồn tại.',
        'The video no longer exists.',
        '/tmp/a.mp4',
      );
      expect(error, isA<FileSystemException>());
      expect(error.message, 'Video không còn tồn tại.');
      expect(error.path, '/tmp/a.mp4');
      expect(
        stationErrorMessage(error, english: true),
        'The video no longer exists.',
      );
    });

    test('StationException is a BilingualMessage', () {
      final BilingualMessage error = StationException.fromCode(
        StationErrorCode.cameraBusy,
      );
      expect(error.localized(english: true), error.messageEn);
      expect(error.localized(english: false), error.messageVi);
    });

    test('permission text still wins over the bilingual message', () {
      final error = BilingualStateError(
        'Microphone bắt buộc nhưng không thể bắt đầu: Permission denied',
        'Microphone is required but failed to start: Permission denied',
      );
      expect(
        stationErrorMessage(error, english: true),
        StationException.fromCode(
          StationErrorCode.permissionDenied,
        ).messageEn,
      );
    });
  });
}
