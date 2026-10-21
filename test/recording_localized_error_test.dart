import 'package:camera_station/services/recording_service.dart';
import 'package:camera_station/services/station_errors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('localizedUserFacingError', () {
    test('uses the matching language of a bilingual error', () {
      final error = BilingualStateError(
        'Không thể chuẩn bị video để phát: 1',
        'Cannot prepare video for playback: 1',
      );
      expect(
        localizedUserFacingError(error, english: true),
        'Cannot prepare video for playback: 1',
      );
      expect(
        localizedUserFacingError(error, english: false),
        'Không thể chuẩn bị video để phát: 1',
      );
      // API cho tablet giữ nguyên tiếng Việt.
      expect(userFacingError(error), 'Không thể chuẩn bị video để phát: 1');
    });

    test('keeps other errors and translates the empty fallback', () {
      expect(
        localizedUserFacingError(StateError('disk full'), english: true),
        'disk full',
      );
      expect(
        localizedUserFacingError(Exception(), english: true),
        isNotEmpty,
      );
      expect(
        localizedUserFacingError('', english: true),
        'An unknown error occurred.',
      );
      expect(
        localizedUserFacingError('', english: false),
        'Đã xảy ra lỗi không xác định.',
      );
    });

    test('StorageSafetyException exposes both languages', () {
      const error = StorageSafetyException('Hết chỗ.', 'Out of space.');
      expect(error.toString(), 'Hết chỗ.');
      expect(localizedUserFacingError(error, english: true), 'Out of space.');
      const legacy = StorageSafetyException('Hết chỗ.');
      expect(legacy.messageEn, 'Hết chỗ.');
    });
  });
}
