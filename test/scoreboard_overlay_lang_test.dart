import 'package:camera_station/models/scoreboard_state.dart';
import 'package:camera_station/services/scoreboard_frame_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _state({String? lang, bool renameTeams = true}) {
  final state = ScoreboardState.initial(nowMs: 1000, sport: 'pickleball');
  if (renameTeams) {
    applyScoreboardAction(state, {
      'action': 'setTeams',
      'teamA': {'name': 'Hà Nội', 'short': 'HN'},
      'teamB': {'name': 'Sài Gòn', 'short': 'SG'},
    }, nowMs: 1000);
  }
  if (lang != null) {
    applyScoreboardAction(state, {'action': 'overlay', 'lang': lang}, nowMs: 1000);
  }
  return state.toJson(nowMs: 2000);
}

void main() {
  group('overlay language setting', () {
    test('defaults to Vietnamese and is saved in the state JSON', () {
      expect(ScoreOverlayConfig().lang, 'vi');
      expect(_overlay(_state())['lang'], 'vi');
      expect(_overlay(_state(lang: 'en'))['lang'], 'en');
    });

    test('rejects unknown languages', () {
      expect(
        () => ScoreOverlayConfig().patch({'lang': 'fr'}),
        throwsA(isA<ScoreboardException>().having((e) => e.code, 'code', 'invalid_overlay')),
      );
    });

    test('old or broken saved data falls back to Vietnamese', () {
      expect(ScoreOverlayConfig.fromJson({'theme': 'light'}).lang, 'vi');
      expect(ScoreOverlayConfig.fromJson({'lang': 'xx', 'theme': 'light'}).lang, 'vi');
      expect(ScoreOverlayConfig.fromJson({'lang': 'en'}).lang, 'en');
    });
  });

  group('burned-in scoreboard labels', () {
    Map<String, dynamic> finished(String? lang, {String? winner = 'A'}) {
      final json = _state(lang: lang);
      json['status'] = 'finished';
      json['winner'] = winner;
      return json;
    }

    Map<String, dynamic> advantage(String? lang) {
      final json = _state(lang: lang);
      json['display'] = {...(json['display'] as Map<String, dynamic>), 'kind': 'advantage', 'advantage': 'B'};
      return json;
    }

    test('Vietnamese by default', () {
      expect(ScoreboardFrameRenderer.footerText(finished(null)), 'HN THẮNG');
      expect(ScoreboardFrameRenderer.footerText(finished(null, winner: null)), 'KẾT THÚC');
      expect(ScoreboardFrameRenderer.footerText(advantage(null)), 'LỢI THẾ SG');
    });

    test('English when the overlay language is en', () {
      expect(ScoreboardFrameRenderer.footerText(finished('en')), 'HN WINS');
      expect(ScoreboardFrameRenderer.footerText(finished('en', winner: null)), 'FINAL');
      expect(ScoreboardFrameRenderer.footerText(advantage('en')), 'ADVANTAGE SG');
    });

    test('only the default team names are translated', () {
      final defaults = _state(lang: 'en', renameTeams: false);
      expect(ScoreboardFrameRenderer.teamName(defaults, 'A'), 'Team A');
      expect(ScoreboardFrameRenderer.teamName(defaults, 'B'), 'Team B');
      final named = _state(lang: 'en');
      expect(ScoreboardFrameRenderer.teamName(named, 'A'), 'Hà Nội');
      final vietnamese = _state(renameTeams: false);
      expect(ScoreboardFrameRenderer.teamName(vietnamese, 'A'), 'Đội A');
    });
  });
}

Map<String, dynamic> _overlay(Map<String, dynamic> state) => state['overlay'] as Map<String, dynamic>;
