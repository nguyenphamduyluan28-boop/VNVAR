import 'package:flutter_test/flutter_test.dart';
import 'package:camera_station/widgets/qr_stream_scanner_dialog.dart';

void main() {
  group('QrStreamParseResult tests', () {
    test('parses JSON formatted match data', () {
      const jsonStr = '''
      {
        "stream_url": "rtsp://media.aqvision.net:18554/live/match_99?key=sec123",
        "match_id": "match_99",
        "match_title": "Chung kết Vô địch Pickleball",
        "protocol": "rtsp",
        "auto_start": true
      }
      ''';

      final result = QrStreamParseResult.parse(jsonStr);
      expect(result, isNotNull);
      expect(result!.streamUrl, 'rtsp://media.aqvision.net:18554/live/match_99?key=sec123');
      expect(result.matchId, 'match_99');
      expect(result.matchTitle, 'Chung kết Vô địch Pickleball');
      expect(result.protocol, 'rtsp');
      expect(result.autoStart, isTrue);
    });

    test('parses direct RTSP and RTMP URLs', () {
      const rtspUrl = 'rtsp://media.aqvision.net:18554/live/match_68?key=tok1';
      final rtspResult = QrStreamParseResult.parse(rtspUrl);
      expect(rtspResult, isNotNull);
      expect(rtspResult!.streamUrl, rtspUrl);
      expect(rtspResult.protocol, 'rtsp');
      expect(rtspResult.autoStart, isTrue);

      const rtmpUrl = 'rtmp://media.aqvision.net:11935/live/match_68?key=tok1';
      final rtmpResult = QrStreamParseResult.parse(rtmpUrl);
      expect(rtmpResult, isNotNull);
      expect(rtmpResult!.streamUrl, rtmpUrl);
      expect(rtmpResult.protocol, 'rtsp');
    });

    test('parses WHIP endpoint URLs', () {
      const whipUrl = 'https://media.aqvision.net:8889/live/whip';
      final result = QrStreamParseResult.parse(whipUrl);
      expect(result, isNotNull);
      expect(result!.streamUrl, whipUrl);
      expect(result.protocol, 'whip');
    });

    test('parses shorthand camera key format', () {
      const shorthand = 'court1_cam?key=pk_secret_123';
      final result = QrStreamParseResult.parse(shorthand);
      expect(result, isNotNull);
      expect(
        result!.streamUrl,
        'rtmp://media.aqvision.net:11935/live/court1_cam?key=pk_secret_123',
      );
      expect(result.protocol, 'rtsp');
    });

    test('returns null for empty or invalid strings', () {
      expect(QrStreamParseResult.parse(''), isNull);
      expect(QrStreamParseResult.parse('   '), isNull);
      expect(QrStreamParseResult.parse('just_a_random_word'), isNull);
    });
  });

  group('QR auto_start defaults', () {
    test('JSON without auto_start does not auto-start', () {
      final result = QrStreamParseResult.parse(
        '{"stream_url": "rtmp://a.rtmp.youtube.com/live2/abcd"}',
      );
      expect(result, isNotNull);
      expect(result!.autoStart, isFalse);
    });

    test('only an explicit true enables auto-start', () {
      expect(
        QrStreamParseResult.parse(
          '{"stream_url": "rtmp://h/live/k", "auto_start": "yes"}',
        )!.autoStart,
        isFalse,
      );
      expect(
        QrStreamParseResult.parse(
          '{"stream_url": "rtmp://h/live/k", "auto_start": false}',
        )!.autoStart,
        isFalse,
      );
      expect(
        QrStreamParseResult.parse(
          '{"stream_url": "rtmp://h/live/k", "auto_start": true}',
        )!.autoStart,
        isTrue,
      );
    });

    test('constructor defaults to no auto-start', () {
      const result = QrStreamParseResult(streamUrl: 'rtmp://h/live/k');
      expect(result.autoStart, isFalse);
    });
  });
}
