import 'package:camera_station/models/scoreboard_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ScoreboardException.localizedMessage', () {
    test('keeps Vietnamese message and adds English by code', () {
      const error = ScoreboardException(
        422,
        'invalid_overlay',
        'Vị trí không hợp lệ.',
      );
      expect(error.message, 'Vị trí không hợp lệ.');
      expect(
        error.localizedMessage(english: false),
        'Vị trí không hợp lệ.',
      );
      expect(
        error.localizedMessage(english: true),
        'Invalid overlay setting.',
      );
    });

    test('falls back to the original message for unknown codes', () {
      const error = ScoreboardException(422, 'brand_new', 'Lỗi mới.');
      expect(error.localizedMessage(english: true), 'Lỗi mới.');
    });

    test('English messages are short', () {
      for (final entry in scoreboardErrorMessagesEn.entries) {
        expect(entry.value.length, lessThanOrEqualTo(60), reason: entry.key);
      }
    });
  });
}
