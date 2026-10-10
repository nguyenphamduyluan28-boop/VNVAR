import 'package:camera_station/services/audio_cleanup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('outdoor audio chain cuts wind, rain hiss and noise without boosting', () {
    final stages = outdoorAudioCleanupFilter.split(',');
    expect(stages.where((s) => s.startsWith('highpass=f=150')), hasLength(2));
    expect(stages, contains(startsWith('lowpass=')));
    expect(stages, contains(startsWith('afftdn=')));
    expect(stages.last, startsWith('alimiter='));
    // A gain stage before the limiter made wind gusts distort.
    expect(outdoorAudioCleanupFilter, isNot(contains('volume=')));
  });
}
