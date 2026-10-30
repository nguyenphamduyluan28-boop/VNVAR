import 'dart:convert';

import 'package:camera_station/models/scoreboard_state.dart';
import 'package:camera_station/services/scoreboard_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('new scoreboards start at the smaller default size', () {
    expect(ScoreboardState.initial(nowMs: 1).overlay.scale, 0.7);
    expect(ScoreOverlayConfig.defaultScale, 0.7);
  });

  test('the old 100% default is migrated once, user choices are kept', () async {
    final old = ScoreboardState.initial(nowMs: 1)..overlay.scale = 1.0;
    SharedPreferences.setMockInitialValues({
      'scale_state': jsonEncode(old.toJson(nowMs: 1)),
    });
    final first = ScoreboardService(
      storageKey: 'scale_state',
      controlKeyStorageKey: 'scale_key',
      scaleMigrationKey: 'scale_migrated',
    );
    await first.load();
    expect((first.snapshot()['overlay'] as Map)['scale'], 0.7);

    // Sau khi đã chuyển, người dùng tự chọn lại 100% thì được giữ.
    first.apply({'action': 'overlay', 'scale': 1.0});
    await first.flush();
    final second = ScoreboardService(
      storageKey: 'scale_state',
      controlKeyStorageKey: 'scale_key',
      scaleMigrationKey: 'scale_migrated',
    );
    await second.load();
    expect((second.snapshot()['overlay'] as Map)['scale'], 1.0);
  });

  test('a user-chosen size other than 100% is never touched', () async {
    final chosen = ScoreboardState.initial(nowMs: 1)..overlay.scale = 1.3;
    SharedPreferences.setMockInitialValues({
      'scale_state2': jsonEncode(chosen.toJson(nowMs: 1)),
    });
    final service = ScoreboardService(
      storageKey: 'scale_state2',
      controlKeyStorageKey: 'scale_key2',
      scaleMigrationKey: 'scale_migrated2',
    );
    await service.load();
    expect((service.snapshot()['overlay'] as Map)['scale'], 1.3);
  });
}
