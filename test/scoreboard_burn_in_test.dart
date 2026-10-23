import 'dart:typed_data';
import 'dart:ui' show Rect, Size;

import 'package:camera_station/models/scoreboard_state.dart';
import 'package:camera_station/services/rtsp_publisher_service.dart';
import 'package:camera_station/services/scoreboard_burn_in.dart';
import 'package:camera_station/services/scoreboard_frame_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

({int width, int height}) pngSize(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  return (width: data.getUint32(16), height: data.getUint32(20));
}

Map<String, dynamic> sampleState({
  String sport = 'pickleball',
  Map<String, dynamic> overlay = const {},
}) {
  final state = ScoreboardState.initial(nowMs: 1000, sport: sport);
  applyScoreboardAction(state, {
    'action': 'setTeams',
    'teamA': {'name': 'Hà Nội', 'players': ['Minh', 'Huy']},
    'teamB': {'name': 'Sài Gòn'},
  }, nowMs: 1000);
  applyScoreboardAction(state, {
    'action': 'setMatchInfo',
    'tournament': 'Giải Mở rộng',
    'round': 'Bán kết',
    'court': 'Sân 2',
  }, nowMs: 1000);
  applyScoreboardAction(state, {'action': 'point', 'team': 'A'}, nowMs: 1000);
  // Overlay mặc định ẩn: bật để bài test thật sự vẽ bảng tỉ số.
  applyScoreboardAction(state, {'action': 'overlay', 'visible': true}, nowMs: 1000);
  if (overlay.isNotEmpty) {
    applyScoreboardAction(state, {'action': 'overlay', ...overlay}, nowMs: 1000);
  }
  return state.toJson(nowMs: 2000);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('probe output is parsed into a video size', () {
    expect(parseProbedVideoSize('1920x1080\n'), (width: 1920, height: 1080));
    expect(parseProbedVideoSize('720x1280'), (width: 720, height: 1280));
    expect(parseProbedVideoSize(''), isNull);
    expect(parseProbedVideoSize(null), isNull);
    expect(parseProbedVideoSize('0x0'), isNull);
  });

  test('overlay FFmpeg arguments re-read the image and re-encode on Android', () {
    final input = livestreamOverlayInputArgs('/tmp/overlay.png');
    expect(input, containsAllInOrder(['-stream_loop', '-1', '-i', '/tmp/overlay.png']));
    final video = livestreamOverlayVideoArgs(bitrateBps: 4000000, fps: 30);
    expect(video, contains('h264_mediacodec'));
    expect(video, containsAllInOrder(['-b:v', '4000000', '-g', '60']));
    expect(video[1], contains('overlay=0:0'));
  });

  test('Android overlay arguments are exactly the MediaCodec re-encode', () {
    expect(livestreamOverlayVideoArgs(bitrateBps: 4000000, fps: 30), [
      '-filter_complex',
      livestreamOverlayFilter(null),
      '-map',
      '[vout]',
      '-c:v',
      'h264_mediacodec',
      '-b:v',
      '4000000',
      '-g',
      '60',
    ]);
  });

  test('only encoder/filter errors disable the scoreboard overlay', () {
    const banner = 'configuration: --enable-mediacodec --enable-jni';
    expect(isLivestreamOverlayFailure('$banner\nConnection refused'), isFalse);
    expect(
      isLivestreamOverlayFailure('$banner\nError while opening encoder for output stream #0:0'),
      isTrue,
    );
    expect(
      isLivestreamOverlayFailure('[h264_mediacodec @ 0x1] Failed to configure codec'),
      isTrue,
    );
    expect(isLivestreamOverlayFailure(null), isFalse);
  });

  test('scrolling ticker is drawn by FFmpeg drawtext', () {
    const ticker = LivestreamTicker(
      textPath: '/data/cache/scoreboard_burnin/ticker.txt',
      fontPath: '/system/fonts/Roboto-Regular.ttf',
      fakeBold: true,
      fontSize: 30,
      textY: 1031,
      speedPxPerSecond: 150,
    );
    final filter = livestreamOverlayFilter(ticker);
    expect(filter, contains("textfile='/data/cache/scoreboard_burnin/ticker.txt'"));
    expect(filter, contains("fontfile='/system/fonts/Roboto-Regular.ttf'"));
    expect(filter, contains('reload=1:expansion=none'));
    expect(filter, contains("x='w-mod(t*150,w+tw)'"));
    expect(filter, contains('borderw=1'));
    expect(filter, endsWith('format=yuv420p[vout]'));
    expect(livestreamOverlayFilter(null), isNot(contains('drawtext')));
    final video = livestreamOverlayVideoArgs(bitrateBps: 3000000, fps: 30, ticker: ticker);
    expect(video[1], filter);
  });

  test('ticker text file is a single non-empty line', () {
    expect(livestreamTickerFileText(''), ' ');
    expect(livestreamTickerFileText('  '), ' ');
    expect(livestreamTickerFileText('Dòng 1\nDòng 2\tA'), 'Dòng 1 Dòng 2 A');
  });

  test('ticker font lookup skips missing and unsafe paths', () {
    expect(
      findLivestreamTickerFont(
        candidates: ["/x/it's.ttf", '/a.ttf', '/b.ttf'],
        exists: (path) => path != '/a.ttf',
      ),
      '/b.ttf',
    );
    expect(findLivestreamTickerFont(candidates: ['/a.ttf'], exists: (_) => false), isNull);
  });

  test('iOS always draws a static ticker into the PNG (no drawtext)', () {
    // iOS: FFmpeg chỉ copy luồng overlay native, không có bộ lọc drawtext.
    expect(useScrollingLivestreamTicker(requested: true, isIos: true), isFalse);
    expect(useScrollingLivestreamTicker(requested: false, isIos: true), isFalse);
    // Android giữ nguyên: chữ chạy do FFmpeg vẽ khi được yêu cầu.
    expect(useScrollingLivestreamTicker(requested: true, isIos: false), isTrue);
    expect(
      useScrollingLivestreamTicker(requested: false, isIos: false),
      isFalse,
    );
  });

  test('only drawtext errors switch to a static ticker', () {
    const missingFile =
        "[Parsed_drawtext_2 @ 0x1] The text file '/c/ticker.txt' could not be read or is empty\n"
        '[AVFilterGraph @ 0x2] Error initializing filters';
    expect(isLivestreamTickerFailure(missingFile), isTrue);
    expect(isLivestreamTickerFailure("[AVFilterGraph @ 0x1] No such filter: 'drawtext'"), isTrue);
    expect(isLivestreamTickerFailure('configuration: --enable-libfreetype drawtext'), isFalse);
    expect(isLivestreamTickerFailure('Error while opening encoder for output stream #0:0'), isFalse);
    expect(isLivestreamTickerFailure(null), isFalse);
  });

  test('overlay can be hidden without losing its configuration', () {
    final state = ScoreboardState.initial(nowMs: 0);
    // Mặc định ẩn cho tới khi người vận hành bật trong Hub.
    expect(state.overlay.visible, isFalse);
    applyScoreboardAction(state, {
      'action': 'overlay',
      'visible': false,
      'ticker': {'enabled': true, 'text': 'Tài trợ'},
    }, nowMs: 0);
    expect(state.overlay.visible, isFalse);
    expect(state.overlay.scene, 'scorebar');
    final json = state.toJson(nowMs: 0);
    expect((json['overlay'] as Map)['visible'], isFalse);
    expect(ScoreboardFrameRenderer.visibleTickerText(json), '');
    applyScoreboardAction(state, {'action': 'overlay', 'visible': true}, nowMs: 0);
    expect(ScoreboardFrameRenderer.visibleTickerText(state.toJson(nowMs: 0)), 'Tài trợ');
    // Lưu/khôi phục giữ nguyên trạng thái ẩn.
    applyScoreboardAction(state, {'action': 'overlay', 'visible': false}, nowMs: 0);
    final restored = ScoreboardState.fromJson(state.toJson(nowMs: 0), nowMs: 0);
    expect(restored.overlay.visible, isFalse);
  });

  test('burnIn defaults to on and can be switched off', () {
    final state = ScoreboardState.initial(nowMs: 0);
    expect(state.overlay.burnIn, isTrue);
    applyScoreboardAction(state, {'action': 'overlay', 'burnIn': false}, nowMs: 0);
    expect(state.overlay.burnIn, isFalse);
    expect((state.toJson(nowMs: 0)['overlay'] as Map)['burnIn'], isFalse);
  });

  group('frame renderer', () {
    const renderer = ScoreboardFrameRenderer();

    Future<void> renderAndCheck(Map<String, dynamic> json, int w, int h) async {
      final bytes = await renderer.renderPng(json, width: w, height: h, nowMs: 5000);
      expect(bytes.sublist(1, 4), [0x50, 0x4E, 0x47]);
      expect(pngSize(bytes), (width: w, height: h));
    }

    test('renders every scene at landscape and portrait sizes', () async {
      for (final scene in scoreboardScenes) {
        await renderAndCheck(sampleState(overlay: {'scene': scene}), 1280, 720);
        await renderAndCheck(sampleState(overlay: {'scene': scene}), 720, 1280);
      }
    });

    test('renders hidden overlay, live ticker bar and every size', () async {
      await renderAndCheck(sampleState(overlay: {'visible': false}), 1280, 720);
      for (final scale in [0.5, 1.0, 1.5, 2.0]) {
        await renderAndCheck(
          sampleState(
            overlay: {
              'scale': scale,
              'position': 'br',
              'ticker': {'enabled': true, 'text': 'Chữ chạy'},
            },
          ),
          1920,
          1080,
        );
      }
      final bytes = await renderer.renderPng(
        sampleState(overlay: {'ticker': {'enabled': true, 'text': 'Chữ chạy'}}),
        width: 1280,
        height: 720,
        nowMs: 5000,
        tickerText: false,
      );
      expect(pngSize(bytes), (width: 1280, height: 720));
    });

    test('renders positions, banner, ticker, timer and tennis', () async {
      for (final position in scoreboardPositions) {
        await renderAndCheck(
          sampleState(
            overlay: {
              'position': position,
              'theme': 'light',
              'show': {'timer': true},
              'ticker': {'enabled': true, 'text': 'Tài trợ bởi VNVAR'},
            },
          ),
          1920,
          1080,
        );
      }
      final tennis = sampleState(sport: 'tennis', overlay: {'scale': 1.5});
      await renderAndCheck(tennis, 1920, 1080);
      final banner = sampleState();
      (banner['overlay'] as Map)['banner'] = {'text': 'KIỂM TRA VAR', 'untilMs': 0};
      await renderAndCheck(banner, 854, 480);
    });
  });

  test('overlay can be placed at an offset; old call keeps 0:0', () {
    expect(livestreamOverlayFilter(null, x: 12, y: 34), contains('overlay=12:34:'));
    final video = livestreamOverlayVideoArgs(
      bitrateBps: 3000000,
      fps: 30,
      overlayX: 100,
      overlayY: 40,
    );
    expect(video[1], contains('overlay=100:40:'));
    const overlay = LivestreamOverlay(imagePath: '/tmp/o.png', width: 1280, height: 720);
    expect(overlay.x, 0);
    expect(overlay.y, 0);
    expect(overlay.imageWidth, 1280);
    expect(overlay.imageHeight, 720);
  });

  test('logos are decoded no larger than needed, keeping aspect ratio', () {
    expect(ScoreboardFrameRenderer.logoDecodeSize(1920, 1080), 360);
    expect(ScoreboardFrameRenderer.logoDecodeSize(1280, 720), 240);
    expect(livestreamLogoDecodeSize(4000, 2000, 360), (width: 360, height: null));
    expect(livestreamLogoDecodeSize(1000, 3000, 360), (width: null, height: 360));
    expect(livestreamLogoDecodeSize(200, 100, 360), (width: null, height: null));
  });

  test('region containment', () {
    const outer = Rect.fromLTWH(0, 0, 100, 100);
    expect(livestreamRegionContains(outer, const Rect.fromLTWH(10, 10, 50, 50)), isTrue);
    expect(livestreamRegionContains(outer, const Rect.fromLTWH(60, 10, 50, 50)), isFalse);
  });

  group('frame layout', () {
    test('large panels are scaled down to fit the frame', () {
      const frame = Size(1920, 1080);
      expect(ScoreboardFrameRenderer.fitScale(2, frame, null), 2);
      expect(
        ScoreboardFrameRenderer.fitScale(2, frame, const Size(1500, 500)),
        closeTo(0.95 * 1920 / 1500, 1e-9),
      );
      expect(
        ScoreboardFrameRenderer.fitScale(2, const Size(720, 1280), const Size(500, 1000)),
        closeTo(0.95 * 1280 / 1000, 1e-9),
      );
      expect(ScoreboardFrameRenderer.fitScale(0.5, frame, const Size(500, 500)), 0.5);
    });

    test('content bounds come from the layout', () {
      final bounds = ScoreboardFrameRenderer.contentBounds(
        sampleState(),
        width: 1920,
        height: 1080,
        nowMs: 0,
      );
      // Thanh tỉ số góc trên trái: lề 48, rộng tối đa 820, cao tối đa 194,
      // cộng bóng đổ 48 (dưới thêm 12).
      expect(bounds, const Rect.fromLTRB(0, 0, 916, 302));
      expect(
        ScoreboardFrameRenderer.contentBounds(
          sampleState(overlay: {'visible': false}),
          width: 1920,
          height: 1080,
          nowMs: 0,
        ),
        isNull,
      );
    });

    test('session region contains every scene and position', () {
      for (final size in const [(1920, 1080), (720, 1280)]) {
        for (final position in scoreboardPositions) {
          for (final scale in const [0.5, 1.0, 2.0]) {
            final base = {'position': position, 'scale': scale};
            final region = ScoreboardFrameRenderer.sessionRegion(
              sampleState(overlay: base),
              width: size.$1,
              height: size.$2,
            );
            expect(region.left, greaterThanOrEqualTo(0));
            expect(region.right, lessThanOrEqualTo(size.$1));
            for (final scene in scoreboardScenes) {
              final state = sampleState(
                overlay: {
                  ...base,
                  'scene': scene,
                  'ticker': {'enabled': true, 'text': 'Tài trợ'},
                },
              );
              (state['overlay'] as Map)['banner'] = {'text': 'KIỂM TRA VAR', 'untilMs': 0};
              final bounds = ScoreboardFrameRenderer.contentBounds(
                state,
                width: size.$1,
                height: size.$2,
                nowMs: 0,
              );
              if (bounds == null) continue;
              expect(
                livestreamRegionContains(region, bounds),
                isTrue,
                reason: '$scene $position $scale $size',
              );
            }
          }
        }
      }
    });

    test('renders only the requested region and placeholder sets', () async {
      const renderer = ScoreboardFrameRenderer();
      final state = ScoreboardState.initial(nowMs: 0);
      applyScoreboardAction(state, {'action': 'overlay', 'visible': true, 'scene': 'full'}, nowMs: 0);
      applyScoreboardAction(state, {'action': 'setScore', 'setsA': 1}, nowMs: 0);
      final bytes = await renderer.renderPng(
        state.toJson(nowMs: 0),
        width: 1920,
        height: 1080,
        nowMs: 0,
        region: const Rect.fromLTWH(10, 20, 300, 200),
      );
      expect(pngSize(bytes), (width: 300, height: 200));
      for (final scene in ['scorebar', 'result']) {
        applyScoreboardAction(state, {'action': 'overlay', 'scene': scene}, nowMs: 0);
        final full = await renderer.renderPng(
          state.toJson(nowMs: 0),
          width: 1280,
          height: 720,
          nowMs: 0,
        );
        expect(pngSize(full), (width: 1280, height: 720));
      }
    });
  });

  test('only changed overlay regions are rewritten', () {
    final a = Uint8List.fromList([1, 2, 3]);
    final b = Uint8List.fromList([4, 5]);
    final c = Uint8List.fromList([6]);
    // Chưa ghi gì: ghi mọi vùng.
    expect(livestreamChangedRegionIndices(const [], [a, b, c]), [0, 1, 2]);
    expect(livestreamChangedRegionIndices([null, null, null], [a, b, c]), [0, 1, 2]);
    // Cùng nội dung (khác đối tượng): bỏ qua.
    expect(
      livestreamChangedRegionIndices(
        [Uint8List.fromList([1, 2, 3]), b, c],
        [a, b, c],
      ),
      isEmpty,
    );
    // Một vùng đổi, một vùng chưa ghi.
    expect(
      livestreamChangedRegionIndices([a, b, null], [a, Uint8List.fromList([4, 6]), c]),
      [1, 2],
    );
    // Danh sách cũ ngắn hơn.
    expect(livestreamChangedRegionIndices([a], [a, b]), [1]);
  });

  test('a launched session without overlay restarts once when overlay is wanted', () {
    // Bấm Hiện trong lúc phiên chuẩn bị (đã đọc cờ Ẩn): phát lại một lần.
    expect(
      livestreamOverlayLaunchRestartNeeded(
        sessionHasOverlay: false,
        overlayWanted: true,
        overlayUnavailable: false,
        alreadyRestarted: false,
      ),
      isTrue,
    );
    // Đã phát lại một lần mà vẫn không in được: không lặp.
    expect(
      livestreamOverlayLaunchRestartNeeded(
        sessionHasOverlay: false,
        overlayWanted: true,
        overlayUnavailable: false,
        alreadyRestarted: true,
      ),
      isFalse,
    );
    // Máy đã báo không in được bảng tỉ số.
    expect(
      livestreamOverlayLaunchRestartNeeded(
        sessionHasOverlay: false,
        overlayWanted: true,
        overlayUnavailable: true,
        alreadyRestarted: false,
      ),
      isFalse,
    );
    // Phiên đã in bảng tỉ số / không cần overlay / chỉ lệch theo hướng tắt.
    for (final (hasOverlay, wanted) in [(true, true), (false, false), (true, false)]) {
      expect(
        livestreamOverlayLaunchRestartNeeded(
          sessionHasOverlay: hasOverlay,
          overlayWanted: wanted,
          overlayUnavailable: false,
          alreadyRestarted: false,
        ),
        isFalse,
      );
    }
  });
}
