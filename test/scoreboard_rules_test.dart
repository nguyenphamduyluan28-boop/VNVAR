import 'dart:convert';

import 'package:camera_station/models/scoreboard_state.dart';
import 'package:camera_station/services/scoreboard_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

ScoreboardState newState(String sport) {
  final state = ScoreboardState.initial(nowMs: 1000, sport: sport);
  return state;
}

void act(ScoreboardState state, Map<String, dynamic> action) {
  applyScoreboardAction(state, action, nowMs: 2000);
}

void rally(ScoreboardState state, String team, [int times = 1]) {
  for (var i = 0; i < times; i++) {
    act(state, {'action': 'point', 'team': team});
  }
}

Matcher throwsStatus(int status) => throwsA(
  isA<ScoreboardException>().having((e) => e.statusCode, 'status', status),
);

void main() {
  group('pickleball doubles (side-out)', () {
    test('starts at 0-0-2 with team A serving', () {
      final state = newState('pickleball');
      expect(state.core.serving, 'A');
      expect(state.core.serverNumber, 2);
      expect(state.core.display()['callout'], '0-0-2');
    });

    test('only the serving team scores; receiving win rotates server', () {
      final state = newState('pickleball');
      rally(state, 'A');
      expect(state.core.pointsA, 1);
      expect(state.core.display()['callout'], '1-0-2');

      // Server 2 loses the rally: side out to B, server 1.
      rally(state, 'B');
      expect(state.core.pointsB, 0);
      expect(state.core.serving, 'B');
      expect(state.core.serverNumber, 1);
      expect(state.core.display()['callout'], '0-1-1');

      // B server 1 loses: B keeps serve with server 2.
      rally(state, 'A');
      expect(state.core.serving, 'B');
      expect(state.core.serverNumber, 2);
      expect(state.core.pointsA, 1);

      // B server 2 loses: side out back to A server 1.
      rally(state, 'A');
      expect(state.core.serving, 'A');
      expect(state.core.serverNumber, 1);
    });

    test('game needs a 2-point lead and next set starts with the other team', () {
      final state = newState('pickleball');
      act(state, {'action': 'setScore', 'scoreA': 10, 'scoreB': 10});
      rally(state, 'A');
      expect(state.core.sets, isEmpty);
      expect(state.core.pointsA, 11);
      rally(state, 'A');
      expect(state.core.sets.length, 1);
      expect(state.core.sets.first.a, 12);
      expect(state.core.sets.first.b, 10);
      expect(state.core.setsWonA, 1);
      expect(state.core.pointsA, 0);
      expect(state.core.serving, 'B');
      expect(state.core.serverNumber, 2);
      expect(state.core.currentSetNumber(), 2);
    });

    test('switching serve at 0-0 keeps "0-0-2" and decides the next set', () {
      final state = newState('pickleball');
      act(state, {'action': 'swapServe'});
      expect(state.core.serving, 'B');
      expect(state.core.display()['callout'], '0-0-2');
      act(state, {'action': 'setScore', 'scoreB': 10});
      rally(state, 'B');
      expect(state.core.setsWonB, 1);
      // B served first in set 1, so A serves first in set 2.
      expect(state.core.serving, 'A');
    });

    test('best of 3 finishes the match and blocks further points', () {
      final state = newState('pickleball');
      act(state, {'action': 'setScore', 'scoreA': 10, 'scoreB': 0});
      rally(state, 'A');
      expect(state.core.setsWonA, 1);
      // Set 2: B serves first. Give A the serve, then win to 11.
      act(state, {'action': 'setServe', 'team': 'A', 'serverNumber': 1});
      act(state, {'action': 'setScore', 'scoreA': 10, 'scoreB': 3});
      rally(state, 'A');
      expect(state.core.finished, isTrue);
      expect(state.core.winner, 'A');
      expect(
        () => rally(state, 'B'),
        throwsA(
          isA<ScoreboardException>().having((e) => e.statusCode, 'status', 409),
        ),
      );
    });
  });

  group('badminton (rally)', () {
    test('rally winner scores and serves', () {
      final state = newState('badminton');
      rally(state, 'B');
      expect(state.core.pointsB, 1);
      expect(state.core.serving, 'B');
      expect(state.core.display()['callout'], '0-1');
    });

    test('cap at 30 ends the game 30-29', () {
      final state = newState('badminton');
      act(state, {'action': 'setScore', 'scoreA': 29, 'scoreB': 29});
      rally(state, 'A');
      expect(state.core.sets.single.a, 30);
      expect(state.core.sets.single.b, 29);
      expect(state.core.serving, 'A');
    });

    test('21-20 is not enough, 22-20 wins', () {
      final state = newState('badminton');
      act(state, {'action': 'setScore', 'scoreA': 20, 'scoreB': 20});
      rally(state, 'B');
      expect(state.core.sets, isEmpty);
      rally(state, 'B');
      expect(state.core.setsWonB, 1);
    });
  });

  group('tennis', () {
    test('game points, deuce and advantage', () {
      final state = newState('tennis');
      rally(state, 'A', 3);
      rally(state, 'B', 3);
      expect(state.core.display()['callout'], 'DEUCE');
      rally(state, 'A');
      expect(state.core.display()['a'], 'AD');
      expect(state.core.display()['b'], '40');
      rally(state, 'B');
      expect(state.core.display()['callout'], 'DEUCE');
      expect(state.core.pointsA, 3);
      expect(state.core.pointsB, 3);
      rally(state, 'A', 2);
      expect(state.core.gamesA, 1);
      expect(state.core.pointsA, 0);
      // Serve alternates after each game.
      expect(state.core.serving, 'B');
    });

    test('6-6 goes to tie-break and 7-0 wins the set 7-6', () {
      final state = newState('tennis');
      act(state, {'action': 'setScore', 'gamesA': 6, 'gamesB': 5});
      rally(state, 'B', 4);
      expect(state.core.gamesB, 6);
      expect(state.core.tiebreak, isTrue);
      expect(state.core.tiebreakFirstServer, 'B');
      rally(state, 'A', 7);
      expect(state.core.setsWonA, 1);
      final set = state.core.sets.single;
      expect(set.a, 7);
      expect(set.b, 6);
      expect(set.tbA, 7);
      expect(set.tbB, 0);
      expect(state.core.tiebreak, isFalse);
      // The player who received first in the tie-break serves next set.
      expect(state.core.serving, 'A');
    });

    test('removing a point from the opponent never leaves an impossible AD', () {
      final state = newState('tennis');
      rally(state, 'A', 3);
      rally(state, 'B', 3);
      rally(state, 'A');
      act(state, {'action': 'adjust', 'team': 'B', 'delta': -1});
      expect(state.core.display()['a'], '40');
      expect(state.core.display()['b'], '30');
    });

    test('tie-break serve changes after point 1 then every 2 points', () {
      final state = newState('tennis');
      act(state, {'action': 'setScore', 'gamesA': 6, 'gamesB': 5});
      rally(state, 'B', 4);
      expect(state.core.serving, 'B');
      rally(state, 'A');
      expect(state.core.serving, 'A');
      rally(state, 'A');
      expect(state.core.serving, 'A');
      rally(state, 'A');
      expect(state.core.serving, 'B');
    });
  });

  group('validation', () {
    test('config is rejected mid-match unless reset is requested', () {
      final state = newState('pickleball');
      rally(state, 'A');
      expect(
        () => act(state, {'action': 'config', 'sport': 'badminton'}),
        throwsA(isA<ScoreboardException>()),
      );
      act(state, {'action': 'config', 'sport': 'badminton', 'reset': true});
      expect(state.core.sport, 'badminton');
      expect(state.core.rules.pointsToWin, 21);
      expect(state.core.pointsA, 0);
    });

    test('invalid overlay values are rejected', () {
      final state = newState('pickleball');
      expect(
        () => act(state, {'action': 'overlay', 'scene': 'nope'}),
        throwsA(isA<ScoreboardException>()),
      );
      act(state, {
        'action': 'overlay',
        'scene': 'full',
        'scale': 1.25,
        'show': {'timer': true},
      });
      expect(state.overlay.scene, 'full');
      expect(state.overlay.scale, 1.25);
      expect(state.overlay.showTimer, isTrue);
    });

    test('ending a tied set is rejected', () {
      final state = newState('badminton');
      expect(
        () => act(state, {'action': 'endSet'}),
        throwsA(isA<ScoreboardException>()),
      );
    });

    test('image types are detected from magic bytes', () {
      expect(detectScoreboardImageExtension([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0]), 'png');
      expect(detectScoreboardImageExtension([0xFF, 0xD8, 0xFF, 0xE0]), 'jpg');
      expect(detectScoreboardImageExtension([1, 2, 3]), isNull);
      expect(isValidScoreboardLogoId('A_123.png'), isTrue);
      expect(isValidScoreboardLogoId('../x.png'), isFalse);
    });
  });

  group('ScoreboardService', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('undo restores the previous score and duplicate ids are ignored', () async {
      final service = ScoreboardService(storageKey: 'test_state', controlKeyStorageKey: 'test_key');
      await service.load();
      final first = service.apply({'id': 'x1', 'action': 'point', 'team': 'A'});
      expect((first['points'] as Map)['a'], 1);
      final again = service.apply({'id': 'x1', 'action': 'point', 'team': 'A'});
      expect((again['points'] as Map)['a'], 1);
      expect(again['rev'], first['rev']);
      final undone = service.apply({'action': 'undo'});
      expect((undone['points'] as Map)['a'], 0);
      expect(service.canUndo, isFalse);
    });

    test('a failed action leaves the state untouched', () async {
      final service = ScoreboardService(storageKey: 'test_state2', controlKeyStorageKey: 'test_key2');
      await service.load();
      final before = service.snapshot();
      expect(
        () => service.apply({
          'action': 'setTeams',
          'teamA': {'name': 'Hà Nội'},
          'teamB': {'color': 'red'},
        }),
        throwsA(isA<ScoreboardException>()),
      );
      final after = service.snapshot();
      expect((after['teamA'] as Map)['name'], (before['teamA'] as Map)['name']);
      expect(after['rev'], before['rev']);
    });

    test('control key is 6 characters and verified case-insensitively', () async {
      final service = ScoreboardService(storageKey: 'test_state3', controlKeyStorageKey: 'test_key3');
      await service.load();
      final key = service.controlKey;
      expect(key.length, 6);
      expect(service.verifyKey(key.toLowerCase()), isTrue);
      expect(service.verifyKey('ZZZZZZ' == key ? 'YYYYYY' : 'ZZZZZZ'), isFalse);
      final next = await service.regenerateKey();
      expect(service.verifyKey(key) && key != next, isFalse);
    });

    test('state survives a reload from storage', () async {
      final service = ScoreboardService(storageKey: 'test_state4', controlKeyStorageKey: 'test_key4');
      await service.load();
      service.apply({'action': 'setTeam', 'team': 'A', 'name': 'Sài Gòn'});
      service.apply({'action': 'point', 'team': 'A'});
      await service.flush();
      final reloaded = ScoreboardService(storageKey: 'test_state4', controlKeyStorageKey: 'test_key4');
      await reloaded.load();
      final json = reloaded.snapshot();
      expect((json['teamA'] as Map)['name'], 'Sài Gòn');
      expect((json['points'] as Map)['a'], 1);
      expect(reloaded.controlKey, service.controlKey);
    });
  });

  group('reopen', () {
    test('a match decided 2-0 cannot be reopened', () {
      final state = newState('badminton');
      act(state, {'action': 'setScore', 'scoreA': 20, 'scoreB': 0});
      rally(state, 'A');
      act(state, {'action': 'setScore', 'scoreA': 20, 'scoreB': 0});
      rally(state, 'A');
      expect(state.core.finished, isTrue);
      expect(state.core.winner, 'A');
      expect(() => act(state, {'action': 'reopen'}), throwsStatus(409));
      expect(state.core.finished, isTrue);
      expect(state.core.winner, 'A');
    });

    test('a match finished early can be reopened', () {
      final state = newState('badminton');
      act(state, {'action': 'setScore', 'scoreA': 20, 'scoreB': 0});
      rally(state, 'A');
      act(state, {'action': 'finish'});
      expect(state.core.finished, isTrue);
      expect(state.core.winner, 'A');
      act(state, {'action': 'reopen'});
      expect(state.core.finished, isFalse);
      expect(state.core.winner, isNull);
      rally(state, 'B');
      expect(state.core.pointsB, 1);
    });
  });

  group('tennis tie-break serve', () {
    test('server order is first, then two each', () {
      final order = [
        for (var n = 0; n < 9; n++) scoreboardTiebreakServer('B', n),
      ];
      expect(order, ['B', 'A', 'A', 'B', 'B', 'A', 'A', 'B', 'B']);
    });

    test('adjust keeps the tie-break server in sync', () {
      final state = newState('tennis');
      act(state, {'action': 'setScore', 'gamesA': 6, 'gamesB': 5});
      rally(state, 'B', 4);
      expect(state.core.tiebreak, isTrue);
      expect(state.core.tiebreakFirstServer, 'B');
      // 3 điểm: B, A, A đã giao → điểm thứ 4 do B giao.
      act(state, {'action': 'adjust', 'team': 'A', 'delta': 3});
      expect(state.core.pointsA, 3);
      expect(state.core.serving, 'B');
      act(state, {'action': 'adjust', 'team': 'B', 'delta': 1});
      expect(state.core.serving, 'B');
      act(state, {'action': 'adjust', 'team': 'B', 'delta': 1});
      expect(state.core.serving, 'A');
      // Bớt điểm: tính lại người giao theo tổng điểm.
      act(state, {'action': 'adjust', 'team': 'A', 'delta': -1});
      expect(state.core.serving, 'B');
      // Điểm thường tiếp tục đúng thứ tự.
      rally(state, 'A');
      expect(state.core.serving, 'A');
    });

    test('correcting the server mid tie-break continues from the correction', () {
      final state = newState('tennis');
      act(state, {'action': 'setScore', 'gamesA': 6, 'gamesB': 5});
      rally(state, 'B', 4);
      rally(state, 'A');
      expect(state.core.serving, 'A');
      act(state, {'action': 'setServe', 'team': 'B'});
      expect(state.core.tiebreakFirstServer, 'A');
      rally(state, 'A');
      expect(state.core.serving, 'B');
      rally(state, 'A');
      expect(state.core.serving, 'A');
    });
  });

  group('setScore keeps the set list consistent', () {
    test('setsA = 1 moves to set 2 with a placeholder set', () {
      final state = newState('pickleball');
      act(state, {'action': 'setScore', 'setsA': 1});
      expect(state.core.setsWonA, 1);
      expect(state.core.sets.length, 1);
      expect(state.core.sets.single.synthetic, isTrue);
      expect(state.core.currentSetNumber(), 2);
      final json = state.toJson(nowMs: 0);
      expect(json['currentSet'], 2);
      expect((json['sets'] as List).single, containsPair('synthetic', true));
      // Lưu/khôi phục giữ nguyên.
      final restored = ScoreboardState.fromJson(json, nowMs: 0);
      expect(restored.core.sets.length, 1);
      expect(restored.core.sets.single.synthetic, isTrue);
      expect(restored.core.currentSetNumber(), 2);

      act(state, {'action': 'setScore', 'setsB': 1});
      expect(state.core.sets.length, 2);
      expect(state.core.currentSetNumber(), 3);
      act(state, {'action': 'setScore', 'setsA': 0, 'setsB': 0});
      expect(state.core.sets, isEmpty);
      expect(state.core.currentSetNumber(), 1);
    });

    test('lowering setsA removes placeholders before real sets', () {
      final state = newState('badminton');
      act(state, {'action': 'setScore', 'scoreA': 20, 'scoreB': 5});
      rally(state, 'A');
      act(state, {'action': 'setScore', 'setsA': 1, 'setsB': 1});
      expect(state.core.sets.length, 2);
      expect(state.core.sets.first.synthetic, isFalse);
      act(state, {'action': 'setScore', 'setsB': 0});
      expect(state.core.sets.single.a, 21);
    });

    test('enough sets won finishes the match', () {
      final state = newState('pickleball');
      act(state, {'action': 'setScore', 'setsA': 2});
      expect(state.core.finished, isTrue);
      expect(state.core.winner, 'A');
    });
  });

  group('serve at 0-0', () {
    test('setServe after a side-out keeps the first server of the set', () {
      final state = newState('pickleball');
      expect(state.core.setFirstServer, 'A');
      // A (người giao 2) thua pha bóng: side-out, tỉ số vẫn 0-0.
      rally(state, 'B');
      expect(state.core.serving, 'B');
      expect(state.core.pointsA + state.core.pointsB, 0);
      act(state, {'action': 'setServe', 'team': 'B', 'serverNumber': 2});
      expect(state.core.setFirstServer, 'A');
      act(state, {'action': 'swapServe'});
      expect(state.core.setFirstServer, 'A');
      // Giữa set: đổi giao không còn là "0-0-2" đầu set.
      expect(state.core.serverNumber, 1);
      // Số pha bóng trong set sống qua lưu/khôi phục.
      final restored = ScoreboardState.fromJson(state.toJson(nowMs: 0), nowMs: 0);
      expect(restored.core.setRallies, 1);
    });
  });

  group('numbers', () {
    test('1e999 is rejected with 422 instead of crashing', () {
      final state = newState('pickleball');
      final action =
          jsonDecode('{"action":"setScore","scoreA":1e999}') as Map<String, dynamic>;
      expect(() => act(state, action), throwsStatus(422));
      expect(
        () => act(state, {'action': 'adjust', 'team': 'A', 'delta': double.infinity}),
        throwsStatus(422),
      );
      expect(
        () => act(state, {
          'action': 'config',
          'rules': {'pointsToWin': double.nan},
        }),
        throwsStatus(422),
      );
      expect(state.core.pointsA, 0);
    });

    test('non-finite stored numbers fall back to defaults', () {
      final json = newState('pickleball').toJson(nowMs: 0);
      json['points'] = {'a': double.infinity, 'b': double.nan};
      final restored = ScoreboardState.fromJson(json, nowMs: 0);
      expect(restored.core.pointsA, 0);
      expect(restored.core.pointsB, 0);
    });
  });

  group('rules', () {
    test('tie-break must be at games per set or one less', () {
      final state = newState('tennis');
      expect(
        () => act(state, {
          'action': 'config',
          'rules': {'tiebreakAt': 4},
        }),
        throwsStatus(422),
      );
      act(state, {
        'action': 'config',
        'rules': {'tiebreakAt': 5},
      });
      expect(state.core.rules.tiebreakAt, 5);
      // Fast4: 4 game/set, tie-break ở 3-3.
      act(state, {
        'action': 'config',
        'rules': {'gamesPerSet': 4, 'tiebreakAt': 3},
      });
      expect(state.core.rules.gamesPerSet, 4);
      expect(state.core.rules.tiebreakAt, 3);
    });
  });

  group('fromJson', () {
    test('normalizes inconsistent saved state field by field', () {
      final json = newState('badminton').toJson(nowMs: 0);
      json.remove('v');
      json['setsWon'] = {'a': 2, 'b': 0};
      json['status'] = 'playing';
      json['winner'] = null;
      json['serverNumber'] = 2;
      json['setRallies'] = 5;
      json['rules'] = {
        ...(json['rules'] as Map<String, dynamic>),
        'bestOf': 4,
        'pointsToWin': 15,
      };
      json['overlay'] = {'scene': 'nope', 'theme': 'light', 'scale': 1.5};
      final restored = ScoreboardState.fromJson(json, nowMs: 0);
      expect(restored.core.finished, isTrue);
      expect(restored.core.winner, 'A');
      expect(restored.core.serverNumber, 1);
      expect(restored.core.sets.length, 2);
      // v1 chưa có số pha bóng trong set.
      expect(restored.core.setRallies, 0);
      // Một trường luật sai không làm mất các trường khác.
      expect(restored.core.rules.bestOf, 3);
      expect(restored.core.rules.pointsToWin, 15);
      // Một trường overlay sai không đưa cả overlay về mặc định.
      expect(restored.overlay.scene, 'scorebar');
      expect(restored.overlay.theme, 'light');
      expect(restored.overlay.scale, 1.5);
    });

    test('a valid state is unchanged by a save/load round trip', () {
      final state = newState('tennis');
      rally(state, 'A', 5);
      final json = state.toJson(nowMs: 0);
      expect(json['v'], scoreboardStateVersion);
      final again = ScoreboardState.fromJson(json, nowMs: 0).toJson(nowMs: 0);
      expect(jsonEncode(again), jsonEncode(json));
    });
  });

  group('ScoreboardService undo across matches', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('undo after newMatch does not bring back the old match', () async {
      final service = ScoreboardService(storageKey: 'test_state5', controlKeyStorageKey: 'test_key5');
      await service.load();
      service.apply({'action': 'point', 'team': 'A'});
      service.apply({'action': 'point', 'team': 'A'});
      final fresh = service.apply({'action': 'newMatch', 'resetTeams': true});
      expect(service.canUndo, isFalse);
      expect(() => service.apply({'action': 'undo'}), throwsStatus(409));
      final now = service.snapshot();
      expect((now['points'] as Map)['a'], 0);
      expect(now['matchId'], fresh['matchId']);
    });

    test('undo after config reset does not bring back the old match', () async {
      final service = ScoreboardService(storageKey: 'test_state6', controlKeyStorageKey: 'test_key6');
      await service.load();
      service.apply({'action': 'point', 'team': 'A'});
      service.apply({'action': 'config', 'sport': 'badminton', 'reset': true});
      expect(service.canUndo, isFalse);
    });

    test('undo of setScore also restores team names', () async {
      final service = ScoreboardService(storageKey: 'test_state7', controlKeyStorageKey: 'test_key7');
      await service.load();
      service.apply({'action': 'setScore', 'scoreA': 5, 'teamA': 'Hà Nội'});
      final undone = service.apply({'action': 'undo'});
      expect((undone['teamA'] as Map)['name'], 'Đội A');
      expect((undone['points'] as Map)['a'], 0);

      // Tên đã sửa tiếp bằng lệnh khác thì giữ nguyên.
      service.apply({'action': 'setScore', 'scoreA': 5, 'teamA': 'Hà Nội'});
      service.apply({'action': 'setTeam', 'team': 'A', 'name': 'Hải Phòng'});
      final kept = service.apply({'action': 'undo'});
      expect((kept['teamA'] as Map)['name'], 'Hải Phòng');
    });
  });
}
