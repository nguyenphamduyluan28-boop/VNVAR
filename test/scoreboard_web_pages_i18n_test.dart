import 'dart:convert';

import 'package:camera_station/models/scoreboard_state.dart';
import 'package:camera_station/services/scoreboard_web_pages.dart';
import 'package:flutter_test/flutter_test.dart';

/// Có dấu tiếng Việt (chữ cần bản tiếng Anh).
final _vietnamese = RegExp(
  r'[ăâđêôơưáàảãạấầẩẫậắằẳẵặéèẻẽẹếềểễệíìỉĩịóòỏõọốồổỗộớờởỡợúùủũụứừửữựýỳỷỹỵ]',
  caseSensitive: false,
);

/// Đọc từ điển `var <name>={...};` (JSON) trong trang.
Map<String, String> _dictionary(String page, String name) {
  final marker = 'var $name=';
  final start = page.indexOf(marker);
  if (start < 0) {
    throw StateError('missing $marker');
  }
  final from = start + marker.length;
  final end = page.indexOf('\n};', from);
  if (end < 0) {
    throw StateError('unterminated $marker');
  }
  final decoded = jsonDecode(page.substring(from, end + 2)) as Map<String, dynamic>;
  return decoded.map((key, value) => MapEntry(key, value as String));
}

/// Các câu tiếng Việt truyền vào T('...') trong JavaScript.
Iterable<String> _translatedLiterals(String page) => RegExp(r"T\('((?:[^'\\]|\\.)*)'")
    .allMatches(page)
    .map((m) => m.group(1)!)
    .where(_vietnamese.hasMatch);

String _normalize(String text) =>
    text.replaceAll('&amp;', '&').split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');

void main() {
  group('scoreboard control page (/control)', () {
    final en = _dictionary(scoreboardControlPageHtml, 'EN');
    final errors = _dictionary(scoreboardControlPageHtml, 'ERR_EN');

    test('every Vietnamese text in the HTML has an English entry', () {
      final body = scoreboardControlPageHtml
          .substring(
            scoreboardControlPageHtml.indexOf('<body'),
            scoreboardControlPageHtml.indexOf('<script>'),
          )
          .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
      final missing = <String>[];
      for (final m in RegExp(r'>([^<>]+)<').allMatches(body)) {
        final text = _normalize(m.group(1)!);
        if (_vietnamese.hasMatch(text) && !en.containsKey(text)) missing.add(text);
      }
      for (final m in RegExp(r'\b(?:title|aria-label|placeholder|data-banner)="([^"]*)"').allMatches(body)) {
        final text = _normalize(m.group(1)!);
        if (_vietnamese.hasMatch(text) && !en.containsKey(text)) missing.add(text);
      }
      expect(missing, isEmpty);
    });

    test('every T(...) text has an English entry', () {
      final missing = _translatedLiterals(scoreboardControlPageHtml).where((t) => !en.containsKey(t)).toList();
      expect(missing, isEmpty);
    });

    test('English placeholders match the Vietnamese ones', () {
      final placeholder = RegExp(r'\{\d+\}');
      for (final entry in en.entries) {
        final vi = placeholder.allMatches(entry.key).map((m) => m.group(0)).toSet();
        final english = placeholder.allMatches(entry.value).map((m) => m.group(0)).toSet();
        expect(english, vi, reason: entry.key);
        expect(_vietnamese.hasMatch(entry.value), isFalse, reason: entry.key);
      }
    });

    test('API error codes translate the same way as the app', () {
      for (final entry in scoreboardErrorMessagesEn.entries) {
        expect(errors[entry.key], entry.value, reason: entry.key);
      }
      for (final code in ['invalid_key', 'invalid_json', 'logo_too_large', 'logo_not_found', 'too_many_streams']) {
        expect(errors.containsKey(code), isTrue, reason: code);
      }
    });

    test('has a page language switch and an overlay language setting', () {
      expect(scoreboardControlPageHtml, contains('id="langBtn"'));
      expect(scoreboardControlPageHtml, contains('data-olang="vi"'));
      expect(scoreboardControlPageHtml, contains('data-olang="en"'));
      expect(scoreboardControlPageHtml, contains("send({action:'overlay',lang:b.dataset.olang})"));
    });
  });

  group('scoreboard overlay page (/overlay)', () {
    final en = _dictionary(scoreboardOverlayPageHtml, 'EN');

    test('every T(...) text has an English entry', () {
      final missing = _translatedLiterals(scoreboardOverlayPageHtml).where((t) => !en.containsKey(t)).toList();
      expect(missing, isEmpty);
    });

    test('follows the saved overlay language unless ?lang= forces one', () {
      expect(scoreboardOverlayPageHtml, contains("lang=forcedLang||(o.lang==='en'?'en':'vi');"));
      expect(scoreboardOverlayPageHtml, contains("if(forcedLang!=='vi'&&forcedLang!=='en')forcedLang='';"));
    });
  });
}
