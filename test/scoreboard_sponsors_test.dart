import 'dart:io';
import 'dart:ui' show Rect, Size;

import 'package:camera_station/models/scoreboard_state.dart';
import 'package:camera_station/services/scoreboard_frame_renderer.dart';
import 'package:camera_station/services/scoreboard_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// PNG 1×1 hợp lệ (chỉ cần chữ ký PNG để service nhận dạng).
final List<int> tinyPng = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0, 0, 0, 0,
];

ScoreboardState stateWithSponsors(Map<String, dynamic> sponsors) {
  final state = ScoreboardState.initial(nowMs: 1000);
  state.sponsors = ScoreSponsors.fromJson({
    'items': ['S_1.png', 'S_2.png', 'S_3.png'],
    ...sponsors,
  });
  state.overlay.visible = true;
  return state;
}

Matcher throwsStatus(int status) => throwsA(
  isA<ScoreboardException>().having((e) => e.statusCode, 'status', status),
);

void main() {
  group('sponsor model', () {
    test('defaults are off, rotate, top-right and empty', () {
      final sponsors = ScoreboardState.initial(nowMs: 1).sponsors;
      expect(sponsors.enabled, isFalse);
      expect(sponsors.mode, 'rotate');
      expect(sponsors.position, 'tr');
      // Không nền: logo PNG trong suốt hiện đúng như file gốc.
      expect(sponsors.plate, 'none');
      expect(sponsors.items, isEmpty);
    });

    test('sponsors action patches settings and validates values', () {
      final state = stateWithSponsors({});
      applyScoreboardAction(state, {
        'action': 'sponsors',
        'enabled': true,
        'mode': 'strip',
        'position': 'bc',
        'scale': 1.5,
        'interval': 10,
        'offsetX': -40,
        'offsetY': 20,
        'plate': 'dark',
      }, nowMs: 2000);
      final json = state.toJson(nowMs: 2000)['sponsors'] as Map;
      expect(json['enabled'], isTrue);
      expect(json['mode'], 'strip');
      expect(json['position'], 'bc');
      expect(json['scale'], 1.5);
      expect(json['interval'], 10);
      expect(json['offsetX'], -40);
      expect(json['plate'], 'dark');

      for (final bad in [
        {'mode': 'grid'},
        {'position': 'mid'},
        {'scale': 3},
        {'interval': 1},
        {'offsetX': 5000},
        {'plate': 'blue'},
      ]) {
        expect(
          () => applyScoreboardAction(state, {'action': 'sponsors', ...bad}, nowMs: 3000),
          throwsStatus(422),
          reason: '$bad',
        );
      }
      // Lệnh lỗi không đổi các trường khác.
      expect(state.sponsors.mode, 'strip');
    });

    test('order must be a permutation of the current logos', () {
      final state = stateWithSponsors({});
      applyScoreboardAction(state, {
        'action': 'sponsors',
        'order': ['S_3.png', 'S_1.png', 'S_2.png'],
      }, nowMs: 2000);
      expect(state.sponsors.items, ['S_3.png', 'S_1.png', 'S_2.png']);
      expect(
        () => applyScoreboardAction(state, {
          'action': 'sponsors',
          'order': ['S_3.png', 'S_1.png'],
        }, nowMs: 2000),
        throwsStatus(422),
      );
    });

    test('removeSponsor removes one logo or reports 404', () {
      final state = stateWithSponsors({});
      applyScoreboardAction(state, {'action': 'removeSponsor', 'logo': 'S_2.png'}, nowMs: 2000);
      expect(state.sponsors.items, ['S_1.png', 'S_3.png']);
      expect(
        () => applyScoreboardAction(state, {'action': 'removeSponsor', 'logo': 'S_9.png'}, nowMs: 2000),
        throwsStatus(404),
      );
    });

    test('saved state keeps only valid sponsor ids and team logos keep their prefix', () {
      final state = ScoreboardState.fromJson({
        'teamA': {'logoId': 'S_1.png'},
        'teamB': {'logoId': 'B_5.png'},
        'sponsors': {
          'items': ['S_1.png', 'A_2.png', '../x.png', 'S_1.png', 'S_4.webp'],
        },
      }, nowMs: 1);
      expect(state.teamA.logoId, isNull);
      expect(state.teamB.logoId, 'B_5.png');
      expect(state.sponsors.items, ['S_1.png', 'S_4.webp']);
      expect(isValidScoreboardLogoId('S_1.png'), isTrue);
      expect(isValidSponsorLogoId('A_1.png'), isFalse);
    });
  });

  group('sponsor uploads', () {
    late Directory dir;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      dir = await Directory.systemTemp.createTemp('sponsors');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('uploads append up to 8 logos and removal deletes the file', () async {
      const clock = 5000;
      final service = ScoreboardService(
        storageKey: 'sp_state',
        controlKeyStorageKey: 'sp_key',
        logoDirectoryProvider: () async => dir,
        clock: () => clock,
      );
      await service.load();
      for (var i = 0; i < 8; i++) {
        await service.saveLogo('S', tinyPng);
      }
      final items = (service.snapshot()['sponsors'] as Map)['items'] as List;
      expect(items, hasLength(8));
      // Cùng mili giây: id vẫn khác nhau, không ghi đè.
      expect(items.toSet(), hasLength(8));
      await expectLater(
        service.saveLogo('S', tinyPng),
        throwsA(isA<ScoreboardException>().having((e) => e.code, 'code', 'too_many_sponsors')),
      );

      final first = items.first as String;
      expect(File('${dir.path}/$first').existsSync(), isTrue);
      service.apply({'action': 'removeSponsor', 'logo': first});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(File('${dir.path}/$first').existsSync(), isFalse);
    });
  });

  group('sponsor layout', () {
    const design = Size(1920, 1080);

    test('rotate box sits in the chosen corner within the margin', () {
      final state = stateWithSponsors({'enabled': true, 'position': 'br'});
      state.overlay.position = 'tl';
      final box = ScoreboardFrameRenderer.sponsorBox(state.toJson(nowMs: 1), design)!;
      expect(box.right, closeTo(1920 - 48, 0.01));
      expect(box.bottom, closeTo(1080 - 48, 0.01));
      // Không nền (mặc định plate: none): đúng kích thước ô xoay 240.
      expect(box.width, closeTo(240, 0.01));
    });

    test('strip box grows with the number of logos', () {
      final state = stateWithSponsors({'enabled': true, 'mode': 'strip', 'position': 'bc'});
      final box = ScoreboardFrameRenderer.sponsorBox(state.toJson(nowMs: 1), design)!;
      // Không nền (plate: none): 3 ô × 200 + 2 khoảng cách × 14 = 628.
      expect(box.width, closeTo(3 * 200 + 2 * 14, 0.01));
      expect(box.center.dx, closeTo(960, 0.01));
    });

    test('sharing the scoreboard corner stacks the logos below the scorebar', () {
      final state = stateWithSponsors({'enabled': true, 'position': 'tl'});
      state.overlay.position = 'tl';
      final box = ScoreboardFrameRenderer.sponsorBox(state.toJson(nowMs: 1), design)!;
      expect(box.top, greaterThan(48 + 194 * ScoreOverlayConfig.defaultScale));
    });

    test('offsets move the box but never outside the frame', () {
      final state = stateWithSponsors({'enabled': true, 'position': 'tr', 'offsetX': 900});
      final box = ScoreboardFrameRenderer.sponsorBox(state.toJson(nowMs: 1), design)!;
      expect(box.right, lessThanOrEqualTo(1920));
      expect(box.left, greaterThanOrEqualTo(0));
    });

    test('session parts include the sponsor box only when enabled', () {
      Rect? sponsorPart(bool enabled) {
        final state = stateWithSponsors({'enabled': enabled, 'position': 'br'});
        final parts = ScoreboardFrameRenderer.sessionParts(
          state.toJson(nowMs: 1),
          width: 1920,
          height: 1080,
          scenes: false,
        );
        for (final part in parts) {
          if (part.right > 1800 && part.bottom > 900 && part.width < 900) return part;
        }
        return null;
      }

      expect(sponsorPart(true), isNotNull);
      expect(sponsorPart(false), isNull);
    });

    test('rotation slot advances with the interval', () {
      final state = stateWithSponsors({'enabled': true, 'interval': 5}).toJson(nowMs: 1);
      expect(ScoreboardFrameRenderer.sponsorSlot(state, 0), 0);
      expect(ScoreboardFrameRenderer.sponsorSlot(state, 5000), 1);
      expect(ScoreboardFrameRenderer.sponsorSlot(state, 15000), 0);
      final strip = stateWithSponsors({'enabled': true, 'mode': 'strip'}).toJson(nowMs: 1);
      expect(ScoreboardFrameRenderer.sponsorSlot(strip, 5000), -1);
    });
  });
}
