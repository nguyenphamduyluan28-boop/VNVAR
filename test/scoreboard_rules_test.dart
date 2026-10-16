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
}
