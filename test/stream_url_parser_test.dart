import 'package:flutter_test/flutter_test.dart';
import 'package:camera_station/utils/stream_url_parser.dart';

void main() {
  group('StreamUrlParser Tests', () {
    test('parses YouTube standard RTMP url', () {
      const input = 'rtmp://a.rtmp.youtube.com/live2/abcd-efgh';
      final parsed = parseStreamUrl(input);

      expect(parsed.platform, equals(StreamPlatform.youtube));
      expect(parsed.server, equals('rtmp://a.rtmp.youtube.com/live2'));
      expect(parsed.key, equals('abcd-efgh'));
      expect(buildStreamUrl(parsed.server, parsed.key), equals(input));
    });

    test('parses YouTube RTMPS with port 443', () {
      const input = 'rtmps://a.rtmps.youtube.com:443/live2/abcd';
      final parsed = parseStreamUrl(input);

      expect(parsed.platform, equals(StreamPlatform.youtube));
      expect(parsed.server, equals('rtmps://a.rtmps.youtube.com:443/live2'));
      expect(parsed.key, equals('abcd'));
      expect(buildStreamUrl(parsed.server, parsed.key), equals(input));
    });

    test('parses Facebook RTMPS url', () {
      const input = 'rtmps://live-api-s.facebook.com:443/rtmp/FB-123-0-Ab';
      final parsed = parseStreamUrl(input);

      expect(parsed.platform, equals(StreamPlatform.facebook));
      expect(
        parsed.server,
        equals('rtmps://live-api-s.facebook.com:443/rtmp'),
      );
      expect(parsed.key, equals('FB-123-0-Ab'));
      expect(buildStreamUrl(parsed.server, parsed.key), equals(input));
    });

    test('parses TikTok live studio url with query preserved', () {
      const input =
          'rtmp://push-rtmp-l11-va01.tiktokcdn.com/game/stream-1?expire=17&sign=ab';
      final parsed = parseStreamUrl(input);

      expect(parsed.platform, equals(StreamPlatform.tiktok));
      expect(
        parsed.server,
        equals('rtmp://push-rtmp-l11-va01.tiktokcdn.com/game'),
      );
      expect(parsed.key, equals('stream-1?expire=17&sign=ab'));
      expect(buildStreamUrl(parsed.server, parsed.key), equals(input));
    });

    test('parses custom local RTMP url', () {
      const input = 'rtmp://192.168.1.10/live/cam1';
      final parsed = parseStreamUrl(input);

      expect(parsed.platform, equals(StreamPlatform.custom));
      expect(parsed.server, equals(''));
      expect(parsed.key, equals(input));
      expect(buildStreamUrl(parsed.server, parsed.key), equals(input));
    });

    test('handles leading/trailing whitespaces correctly', () {
      const input = '  rtmp://a.rtmp.youtube.com/live2/k  ';
      final parsed = parseStreamUrl(input);

      expect(parsed.platform, equals(StreamPlatform.youtube));
      expect(parsed.server, equals('rtmp://a.rtmp.youtube.com/live2'));
      expect(parsed.key, equals('k'));
      expect(
        buildStreamUrl(parsed.server, parsed.key),
        equals('rtmp://a.rtmp.youtube.com/live2/k'),
      );
    });
  });
  group('mergeStreamUrlWithKey', () {
    test('appends key to server-only platform URL', () {
      expect(
        mergeStreamUrlWithKey('rtmp://a.rtmp.youtube.com/live2', 'abcd'),
        'rtmp://a.rtmp.youtube.com/live2/abcd',
      );
    });

    test('does not duplicate key already in URL', () {
      expect(
        mergeStreamUrlWithKey('rtmp://host/live/KEY', 'KEY'),
        'rtmp://host/live/KEY',
      );
      expect(
        mergeStreamUrlWithKey(
          'rtsp://media.aqvision.net:18554/live/match_99?key=sec123',
          'sec123',
        ),
        'rtsp://media.aqvision.net:18554/live/match_99?key=sec123',
      );
    });

    test('replaces existing key on platform URL with token', () {
      expect(
        mergeStreamUrlWithKey('rtmp://a.rtmp.youtube.com/live2/old', 'new'),
        'rtmp://a.rtmp.youtube.com/live2/new',
      );
    });

    test('keeps custom URL that already has app/stream', () {
      expect(
        mergeStreamUrlWithKey('rtmp://192.168.1.10/live/cam1', 'pk_1'),
        'rtmp://192.168.1.10/live/cam1',
      );
    });

    test('returns URL unchanged when key is null or blank', () {
      expect(mergeStreamUrlWithKey(' rtmp://h/live ', null), 'rtmp://h/live');
      expect(mergeStreamUrlWithKey('rtmp://h/live', '  '), 'rtmp://h/live');
    });
  });
}
