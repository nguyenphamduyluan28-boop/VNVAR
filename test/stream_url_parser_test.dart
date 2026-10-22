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

    test('parses SportO live RTMP url', () {
      const input = 'rtmp://live.sporto.vn/live/match-999';
      final parsed = parseStreamUrl(input);

      expect(parsed.platform, equals(StreamPlatform.sporto));
      expect(parsed.server, equals('rtmp://live.sporto.vn/live'));
      expect(parsed.key, equals('match-999'));
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

  group('platform detection uses domain suffixes', () {
    test('look-alike hosts are not treated as platforms', () {
      expect(
        parseStreamUrl('rtmp://evilyoutube.com/live2/k').platform,
        StreamPlatform.custom,
      );
      expect(
        parseStreamUrl('rtmp://youtube.com.evil.example/live2/k').platform,
        StreamPlatform.custom,
      );
      expect(
        parseStreamUrl('rtmp://notsporto.vn/live/k').platform,
        StreamPlatform.custom,
      );
    });

    test('regional TikTok CDNs are detected', () {
      expect(
        parseStreamUrl('rtmp://push.tiktokcdn-us.com/game/k').platform,
        StreamPlatform.tiktok,
      );
    });

    test('toString does not leak the stream key', () {
      final parsed = parseStreamUrl(
        'rtmp://a.rtmp.youtube.com/live2/abcd-efgh-ijkl-mnop',
      );
      expect(parsed.toString(), isNot(contains('efgh-ijkl')));
      expect(parsed.toString(), contains('abcd'));
    });
  });

  group('classifyStreamDestination', () {
    test('partner servers', () {
      expect(
        classifyStreamDestination('rtmp://live.sporto.vn/live/match-1'),
        StreamDestinationKind.partner,
      );
      expect(
        classifyStreamDestination('rtmp://media.aqvision.net:11935/live/cam1'),
        StreamDestinationKind.partner,
      );
    });

    test('local network servers', () {
      for (final url in [
        'http://192.168.1.20:8889/cam/whip',
        'rtsp://10.0.0.5:8554/live',
        'rtmp://172.16.4.2/live/k',
        'rtmp://127.0.0.1/live/k',
        'rtmp://localhost/live/k',
        'http://mediamtx.local:8889/cam/whip',
        'rtmp://[fd00::1]/live/k',
      ]) {
        expect(
          classifyStreamDestination(url),
          StreamDestinationKind.local,
          reason: url,
        );
      }
    });

    test('public platforms always need confirmation', () {
      for (final url in [
        'rtmp://a.rtmp.youtube.com/live2/k',
        'rtmps://live-api-s.facebook.com:443/rtmp/k',
        'rtmp://push-rtmp-l11.tiktokcdn.com/game/k',
        'rtmps://edge.fbcdn.net/rtmp/k',
      ]) {
        expect(
          classifyStreamDestination(url),
          StreamDestinationKind.publicPlatform,
          reason: url,
        );
        expect(isTrustedAutoStartDestination(url), isFalse, reason: url);
      }
    });

    test('unknown and malformed hosts', () {
      expect(
        classifyStreamDestination('rtmp://evil.example/live/k'),
        StreamDestinationKind.unknown,
      );
      expect(
        classifyStreamDestination('rtmp://evilyoutube.com/live/k'),
        StreamDestinationKind.unknown,
      );
      expect(
        classifyStreamDestination('rtmp://8.8.8.8/live/k'),
        StreamDestinationKind.unknown,
      );
      // Octet > 255 không phải IPv4 nội bộ.
      expect(
        classifyStreamDestination('rtmp://192.168.1.300/live/k'),
        StreamDestinationKind.unknown,
      );
      expect(classifyStreamDestination(''), StreamDestinationKind.unknown);
    });

    test('only partner and local destinations auto-start', () {
      expect(
        isTrustedAutoStartDestination('rtmp://media.aqvision.net/live/cam1'),
        isTrue,
      );
      expect(
        isTrustedAutoStartDestination('http://192.168.1.20:8889/cam/whip'),
        isTrue,
      );
      expect(
        isTrustedAutoStartDestination('rtmp://a.rtmp.youtube.com/live2/k'),
        isFalse,
      );
      expect(
        isTrustedAutoStartDestination('rtmp://evil.example/live/k'),
        isFalse,
      );
    });
  });

  group('stream key masking', () {
    test('keeps at most the first 4 characters', () {
      expect(maskStreamSecret('abcd-efgh-ijkl'), 'abcd••••');
      // Khoá ngắn: chỉ lộ nửa đầu.
      expect(maskStreamSecret('abcdef'), 'abc••••');
      expect(maskStreamSecret(''), '');
    });

    test('masks the key part of a stream URL', () {
      expect(
        maskedStreamKeyOf('rtmp://a.rtmp.youtube.com/live2/abcd-efgh-ijkl'),
        'abcd••••',
      );
      expect(maskedStreamKeyOf('rtmp://a.rtmp.youtube.com/live2'), '');
      expect(
        streamDestinationLabel('rtmp://a.rtmp.youtube.com/live2/k'),
        'YouTube',
      );
      expect(streamDestinationLabel('rtmp://evil.example/live/k'), '');
    });
  });

  group('mergeStreamUrlWithKey with short tokens', () {
    test('a short token matching a digit elsewhere is still appended', () {
      expect(
        mergeStreamUrlWithKey('rtmp://10.0.0.1:1935/live', '1'),
        'rtmp://10.0.0.1:1935/live/1',
      );
    });

    test('token present as query value is not duplicated', () {
      expect(
        mergeStreamUrlWithKey('rtmp://h/live?key=1', '1'),
        'rtmp://h/live?key=1',
      );
    });
  });

  group('SportO server & protocol', () {
    test('default SportO server is AQVision RTMP', () {
      expect(
        kDefaultServers[StreamPlatform.sporto],
        'rtmp://media.aqvision.net:11935/live',
      );
    });

    test('AQVision RTMP/RTSP urls are detected as SportO', () {
      final rtmp = parseStreamUrl('rtmp://media.aqvision.net:11935/live/m1');
      expect(rtmp.platform, StreamPlatform.sporto);
      expect(rtmp.server, 'rtmp://media.aqvision.net:11935/live');
      expect(rtmp.key, 'm1');

      const rtspUrl = 'rtsp://media.aqvision.net:18554/live/match_99?key=s1';
      final rtsp = parseStreamUrl(rtspUrl);
      expect(rtsp.platform, StreamPlatform.sporto);
      expect(rtsp.server, 'rtsp://media.aqvision.net:18554/live');
      expect(buildStreamUrl(rtsp.server, rtsp.key), rtspUrl);
    });

    test('streamProtocolOf', () {
      expect(streamProtocolOf('rtsp://h/live'), StreamProtocol.rtsp);
      expect(streamProtocolOf('RTSPS://h/live'), StreamProtocol.rtsp);
      expect(streamProtocolOf('rtmps://h:443/rtmp'), StreamProtocol.rtmp);
      expect(streamProtocolOf(''), StreamProtocol.rtmp);
    });

    test('switching protocol uses platform defaults', () {
      expect(
        serverForProtocol(
          StreamPlatform.sporto,
          'rtmp://media.aqvision.net:11935/live',
          StreamProtocol.rtsp,
        ),
        'rtsp://media.aqvision.net:18554/live',
      );
      expect(
        serverForProtocol(
          StreamPlatform.sporto,
          'rtsp://media.aqvision.net:18554/live',
          StreamProtocol.rtmp,
        ),
        'rtmp://media.aqvision.net:11935/live',
      );
      expect(
        serverForProtocol(
          StreamPlatform.youtube,
          'rtmp://a.rtmp.youtube.com/live2',
          StreamProtocol.rtsp,
        ),
        'rtsp://a.rtmp.youtube.com/live2',
      );
    });

    test('custom server keeps host/path and drops port', () {
      expect(
        serverForProtocol(
          StreamPlatform.facebook,
          'rtmps://my.server.vn:1935/app',
          StreamProtocol.rtsp,
        ),
        'rtsp://my.server.vn/app',
      );
    });

    test('defaults match after normalising case and trailing slash', () {
      expect(
        serverForProtocol(
          StreamPlatform.sporto,
          '  RTMP://Media.AQVision.net:11935/live/ ',
          StreamProtocol.rtsp,
        ),
        'rtsp://media.aqvision.net:18554/live',
      );
      expect(
        serverForProtocol(
          StreamPlatform.youtube,
          'rtmp://A.RTMP.YouTube.com/live2/',
          StreamProtocol.rtsp,
        ),
        'rtsp://a.rtmp.youtube.com/live2',
      );
      expect(
        normalizeStreamServer(' RTSP://Host.VN:554/Live/ '),
        'rtsp://host.vn:554/Live',
      );
    });

    test('known partner host keeps the right port for each protocol', () {
      expect(
        convertServerScheme(
          'rtmp://media.aqvision.net:11935/live2',
          StreamProtocol.rtsp,
        ),
        'rtsp://media.aqvision.net:18554/live2',
      );
      expect(
        convertServerScheme(
          'rtsp://media.aqvision.net:18554/live2',
          StreamProtocol.rtmp,
        ),
        'rtmp://media.aqvision.net:11935/live2',
      );
      expect(
        convertServerScheme(
          'rtmp://MEDIA.aqvision.net/live',
          StreamProtocol.rtsp,
        ),
        'rtsp://MEDIA.aqvision.net:18554/live',
      );
    });

    test('default ports are dropped, unusual ports are kept', () {
      expect(
        convertServerScheme('rtmp://my.server.vn:1935/app', StreamProtocol.rtsp),
        'rtsp://my.server.vn/app',
      );
      expect(
        convertServerScheme('rtsp://my.server.vn:8554/app', StreamProtocol.rtmp),
        'rtmp://my.server.vn/app',
      );
      expect(
        convertServerScheme('rtsp://my.server.vn:554/app', StreamProtocol.rtmp),
        'rtmp://my.server.vn/app',
      );
      expect(
        convertServerScheme('rtmp://my.server.vn:2935/app', StreamProtocol.rtsp),
        'rtsp://my.server.vn:2935/app',
      );
      expect(
        convertServerScheme('rtmp://my.server.vn/app', StreamProtocol.rtsp),
        'rtsp://my.server.vn/app',
      );
      // Cùng giao thức: giữ nguyên.
      expect(
        convertServerScheme('rtmp://my.server.vn:2935/app', StreamProtocol.rtmp),
        'rtmp://my.server.vn:2935/app',
      );
    });

    test('protocolDowngradesEncryption', () {
      expect(
        protocolDowngradesEncryption(
          'rtmps://live-api-s.facebook.com:443/rtmp',
          StreamProtocol.rtsp,
        ),
        isTrue,
      );
      expect(
        protocolDowngradesEncryption('RTSPS://h/live', StreamProtocol.rtmp),
        isTrue,
      );
      expect(
        protocolDowngradesEncryption(
          'rtmps://live-api-s.facebook.com:443/rtmp',
          StreamProtocol.rtmp,
        ),
        isFalse,
      );
      expect(
        protocolDowngradesEncryption('rtmp://h/live', StreamProtocol.rtsp),
        isFalse,
      );
      expect(protocolDowngradesEncryption('', StreamProtocol.rtsp), isFalse);
    });
  });
}
