import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:camera_station/models/scoreboard_state.dart';
import 'package:camera_station/services/scoreboard_burn_in.dart';
import 'package:camera_station/services/scoreboard_frame_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

({int width, int height}) pngSize(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  return (width: data.getUint32(16), height: data.getUint32(20));
}

Map<String, dynamic> sampleState({Map<String, dynamic> overlay = const {}}) {
  final state = ScoreboardState.initial(nowMs: 1000);
  applyScoreboardAction(state, {
    'action': 'setTeams',
    'teamA': {'name': 'Hà Nội'},
    'teamB': {'name': 'Sài Gòn'},
  }, nowMs: 1000);
  applyScoreboardAction(state, {
    'action': 'overlay',
    'visible': true,
    ...overlay,
  }, nowMs: 1000);
  return state.toJson(nowMs: 2000);
}

bool isEven(double value) => value.round().isEven;

void expectValidRegions(List<Rect> regions, int width, int height) {
  expect(regions, isNotEmpty);
  for (final region in regions) {
    expect(region.left, greaterThanOrEqualTo(0));
    expect(region.top, greaterThanOrEqualTo(0));
    expect(region.right, lessThanOrEqualTo(width));
    expect(region.bottom, lessThanOrEqualTo(height));
    expect(region.width, greaterThan(0));
    expect(region.height, greaterThan(0));
    expect(isEven(region.left) && isEven(region.top), isTrue, reason: '$region');
    expect(isEven(region.width) && isEven(region.height), isTrue, reason: '$region');
  }
  for (var i = 0; i < regions.length; i++) {
    for (var j = i + 1; j < regions.length; j++) {
      expect(regions[i].overlaps(regions[j]), isFalse, reason: '$regions');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('merging overlay regions', () {
    test('rounds outwards to even pixels and clamps to the frame', () {
      expect(
        ScoreboardFrameRenderer.mergeOverlayRegions(
          const [Rect.fromLTRB(3.2, 5.7, 101.1, 99)],
          width: 1920,
          height: 1080,
          gap: 0,
        ),
        const [Rect.fromLTRB(2, 4, 102, 100)],
      );
      expect(
        ScoreboardFrameRenderer.mergeOverlayRegions(
          const [Rect.fromLTRB(-10, -10, 1925, 1085)],
          width: 1920,
          height: 1080,
          gap: 0,
        ),
        const [Rect.fromLTRB(0, 0, 1920, 1080)],
      );
    });

    test('top-left scorebar and bottom ticker stay two regions', () {
      final regions = ScoreboardFrameRenderer.mergeOverlayRegions(
        const [
          Rect.fromLTRB(0, 1012, 1920, 1080),
          Rect.fromLTRB(0, 0, 916, 302),
        ],
        width: 1920,
        height: 1080,
        gap: 64,
      );
      // Xếp theo top: thanh tỉ số trước, chữ chạy sau.
      expect(regions, const [
        Rect.fromLTRB(0, 0, 916, 302),
        Rect.fromLTRB(0, 1012, 1920, 1080),
      ]);
    });

    test('overlapping or close parts are merged, far parts are not', () {
      expect(
        ScoreboardFrameRenderer.mergeOverlayRegions(
          const [Rect.fromLTRB(0, 0, 100, 100), Rect.fromLTRB(130, 0, 200, 100)],
          width: 1920,
          height: 1080,
          gap: 64,
        ),
        const [Rect.fromLTRB(0, 0, 200, 100)],
      );
      expect(
        ScoreboardFrameRenderer.mergeOverlayRegions(
          const [Rect.fromLTRB(0, 0, 100, 100), Rect.fromLTRB(300, 0, 400, 100)],
          width: 1920,
          height: 1080,
          gap: 64,
        ),
        hasLength(2),
      );
      // Gộp dây chuyền: A gần B, B gần C → một vùng.
      expect(
        ScoreboardFrameRenderer.mergeOverlayRegions(
          const [
            Rect.fromLTRB(0, 0, 100, 100),
            Rect.fromLTRB(400, 0, 500, 100),
            Rect.fromLTRB(90, 50, 420, 80),
          ],
          width: 1920,
          height: 1080,
          gap: 0,
        ),
        const [Rect.fromLTRB(0, 0, 500, 100)],
      );
    });

    test('budget: at most 3 regions and 60 % of the frame', () {
      const small = [
        Rect.fromLTRB(0, 0, 100, 100),
        Rect.fromLTRB(0, 1000, 1920, 1080),
      ];
      expect(
        ScoreboardFrameRenderer.overlayRegionsWithinBudget(small, width: 1920, height: 1080),
        isTrue,
      );
      expect(
        ScoreboardFrameRenderer.overlayRegionsWithinBudget(
          const [
            Rect.fromLTRB(0, 0, 10, 10),
            Rect.fromLTRB(100, 0, 110, 10),
            Rect.fromLTRB(200, 0, 210, 10),
            Rect.fromLTRB(300, 0, 310, 10),
          ],
          width: 1920,
          height: 1080,
        ),
        isFalse,
      );
      expect(
        ScoreboardFrameRenderer.overlayRegionsWithinBudget(
          const [Rect.fromLTRB(0, 0, 1920, 700)],
          width: 1920,
          height: 1080,
        ),
        isFalse,
      );
    });

    test('coverage check', () {
      const regions = [Rect.fromLTRB(0, 0, 916, 320), Rect.fromLTRB(0, 1012, 1920, 1080)];
      expect(
        ScoreboardFrameRenderer.overlayRegionsCover(regions, const [
          Rect.fromLTRB(0, 0, 916, 302),
          Rect.fromLTRB(0, 1012, 1920, 1080),
        ]),
        isTrue,
      );
      expect(
        ScoreboardFrameRenderer.overlayRegionsCover(regions, const [
          Rect.fromLTRB(1000, 0, 1916, 302),
        ]),
        isFalse,
      );
    });
  });

  group('session regions', () {
    test('top-left scorebar with ticker: two regions (top, bottom band)', () {
      final state = sampleState(
        overlay: {
          'ticker': {'enabled': true, 'text': 'Tài trợ'},
        },
      );
      final regions = ScoreboardFrameRenderer.sessionRegions(state, width: 1920, height: 1080);
      expectValidRegions(regions, 1920, 1080);
      expect(regions, hasLength(2));
      // Thanh tỉ số góc trên trái (rộng tối đa 916 kể cả bóng) gộp với vùng
      // thông báo phía trên; chữ chạy là dải riêng ở đáy.
      expect(regions.first.left, 0);
      expect(regions.first.top, 0);
      expect(regions.first.right, greaterThanOrEqualTo(916));
      expect(regions.first.bottom, lessThan(540));
      expect(regions.last, const Rect.fromLTRB(0, 1012, 1920, 1080));
      expect(
        ScoreboardFrameRenderer.overlayRegionsCover(
          regions,
          ScoreboardFrameRenderer.sessionParts(
            state,
            width: 1920,
            height: 1080,
            scenes: false,
          ),
        ),
        isTrue,
      );
    });

    test('large scenes at full size use one bounding region', () {
      final regions = ScoreboardFrameRenderer.sessionRegions(
        sampleState(overlay: {'scene': 'intro'}),
        width: 1920,
        height: 1080,
      );
      expect(regions, hasLength(1));
      expectValidRegions(regions, 1920, 1080);
    });

    test('regions always cover what the session can draw', () {
      for (final size in const [(1920, 1080), (1280, 720), (720, 1280)]) {
        for (final position in scoreboardPositions) {
          for (final scale in const [0.5, 1.0, 2.0]) {
            for (final scene in scoreboardScenes) {
              final state = sampleState(
                overlay: {'position': position, 'scale': scale, 'scene': scene},
              );
              for (final reserve in const [false, true]) {
                final regions = ScoreboardFrameRenderer.sessionRegions(
                  state,
                  width: size.$1,
                  height: size.$2,
                  reserveScenes: reserve,
                );
                final reason = '$size $position $scale $scene $reserve';
                expectValidRegions(regions, size.$1, size.$2);
                expect(regions.length, lessThanOrEqualTo(3), reason: reason);
                final scenes = reserve || ScoreboardFrameRenderer.sessionNeedsScenes(state);
                expect(
                  ScoreboardFrameRenderer.overlayRegionsCover(
                    regions,
                    ScoreboardFrameRenderer.sessionParts(
                      state,
                      width: size.$1,
                      height: size.$2,
                      scenes: scenes,
                    ),
                  ),
                  isTrue,
                  reason: reason,
                );
              }
            }
          }
        }
      }
    });

    test('moving the scorebar outgrows the locked regions', () {
      final regions = ScoreboardFrameRenderer.sessionRegions(
        sampleState(),
        width: 1920,
        height: 1080,
      );
      final moved = sampleState(overlay: {'position': 'br'});
      expect(
        ScoreboardFrameRenderer.overlayRegionsCover(
          regions,
          ScoreboardFrameRenderer.sessionParts(moved, width: 1920, height: 1080, scenes: false),
        ),
        isFalse,
      );
      // Đổi điểm số / tên không đổi các phần cần vẽ.
      final scored = ScoreboardState.fromJson(sampleState(), nowMs: 2000);
      applyScoreboardAction(scored, {'action': 'point', 'team': 'B'}, nowMs: 2000);
      expect(
        ScoreboardFrameRenderer.overlayRegionsCover(
          regions,
          ScoreboardFrameRenderer.sessionParts(
            scored.toJson(nowMs: 2000),
            width: 1920,
            height: 1080,
            scenes: false,
          ),
        ),
        isTrue,
      );
    });

    test('each region is rendered into its own PNG', () async {
      const renderer = ScoreboardFrameRenderer();
      final images = await renderer.renderRegionsPng(
        sampleState(
          overlay: {
            'ticker': {'enabled': true, 'text': 'Tài trợ'},
          },
        ),
        width: 1920,
        height: 1080,
        nowMs: 0,
        regions: const [Rect.fromLTRB(0, 0, 916, 320), Rect.fromLTRB(0, 1012, 1920, 1080)],
      );
      expect(images, hasLength(2));
      expect(pngSize(images[0]), (width: 916, height: 320));
      expect(pngSize(images[1]), (width: 1920, height: 68));
    });
  });

  group('FFmpeg filter with several regions', () {
    test('chains one overlay per region, then ticker and yuv420p', () {
      final filter = livestreamOverlayFilter(
        null,
        positions: const [(x: 0, y: 0), (x: 0, y: 1012)],
      );
      expect(
        filter,
        '[1:v]format=rgba,setpts=PTS-STARTPTS[ovr1];'
        '[2:v]format=rgba,setpts=PTS-STARTPTS[ovr2];'
        '[0:v][ovr1]overlay=0:0:eof_action=repeat:format=auto[ov1];'
        '[ov1][ovr2]overlay=0:1012:eof_action=repeat:format=auto'
        ',format=yuv420p[vout]',
      );
      const ticker = LivestreamTicker(
        textPath: '/c/ticker.txt',
        fontPath: '/system/fonts/Roboto-Bold.ttf',
        fakeBold: false,
        fontSize: 30,
        textY: 1031,
        speedPxPerSecond: 150,
      );
      final withTicker = livestreamOverlayFilter(
        ticker,
        positions: const [(x: 0, y: 0), (x: 100, y: 200), (x: 0, y: 1012)],
      );
      expect(withTicker, contains('[3:v]format=rgba,setpts=PTS-STARTPTS[ovr3];'));
      expect(withTicker, contains('[ov2][ovr3]overlay=0:1012:eof_action=repeat:format=auto,drawtext='));
      expect(withTicker, endsWith('format=yuv420p[vout]'));
    });

    test('a single region keeps the legacy filter', () {
      expect(
        livestreamOverlayFilter(null, positions: const [(x: 12, y: 34)]),
        livestreamOverlayFilter(null, x: 12, y: 34),
      );
      expect(
        livestreamOverlayFilter(null, positions: const []),
        livestreamOverlayFilter(null),
      );
    });

    test('video args use the region positions', () {
      const regions = [
        LivestreamOverlayRegion(imagePath: '/c/overlay_0.png', x: 0, y: 0, width: 916, height: 320),
        LivestreamOverlayRegion(imagePath: '/c/overlay_1.png', x: 0, y: 1012, width: 1920, height: 68),
      ];
      final video = livestreamOverlayVideoArgs(bitrateBps: 4000000, fps: 30, regions: regions);
      expect(
        video[1],
        livestreamOverlayFilter(null, positions: const [(x: 0, y: 0), (x: 0, y: 1012)]),
      );
      expect(video, containsAllInOrder(['-map', '[vout]', '-c:v', 'h264_mediacodec']));
      const overlay = LivestreamOverlay(
        imagePath: '/c/overlay_0.png',
        width: 1920,
        height: 1080,
        regions: regions,
      );
      expect(overlay.regions, hasLength(2));
      const single = LivestreamOverlay(imagePath: '/c/overlay.png', width: 1280, height: 720);
      expect(single.regions, hasLength(1));
      expect(single.regions.single.imagePath, '/c/overlay.png');
      expect(single.regions.single.width, 1280);
      expect(single.regions.single.x, 0);
    });
  });

  group('restart on overlay flag changes', () {
    const hidden = (burnIn: true, visible: false);
    const shown = (burnIn: true, visible: true);
    const offShown = (burnIn: false, visible: true);
    const offHidden = (burnIn: false, visible: false);

    test('flags are read from the scoreboard JSON', () {
      expect(livestreamOverlayFlags(const {}), (burnIn: false, visible: false));
      expect(livestreamOverlayFlags(sampleState()), shown);
      expect(livestreamOverlayFlags(sampleState(overlay: {'visible': false})), hidden);
      expect(livestreamOverlayNeeded(shown), isTrue);
      expect(livestreamOverlayNeeded(hidden), isFalse);
      expect(livestreamOverlayNeeded(offShown), isFalse);
    });

    test('hidden → shown restarts a copy session', () {
      expect(
        livestreamOverlayRestartNeeded(previous: hidden, next: shown, sessionHasOverlay: false),
        isTrue,
      );
      // Bật lại in khi đang hiện: phát lại như trước.
      expect(
        livestreamOverlayRestartNeeded(previous: offShown, next: shown, sessionHasOverlay: false),
        isTrue,
      );
    });

    test('shown → hidden never restarts', () {
      for (final session in const [false, true]) {
        expect(
          livestreamOverlayRestartNeeded(previous: shown, next: hidden, sessionHasOverlay: session),
          isFalse,
        );
      }
    });

    test('score/name/scene changes keep the flags and do not restart', () {
      for (final flags in const [hidden, shown, offShown, offHidden]) {
        for (final session in const [false, true]) {
          expect(
            livestreamOverlayRestartNeeded(previous: flags, next: flags, sessionHasOverlay: session),
            isFalse,
          );
        }
      }
      expect(
        livestreamOverlayRestartNeeded(previous: null, next: shown, sessionHasOverlay: false),
        isFalse,
      );
    });

    test('burn-in toggles only restart when the overlay is really affected', () {
      // Tắt in khi đang hiện và đang in: về copy.
      expect(
        livestreamOverlayRestartNeeded(previous: shown, next: offShown, sessionHasOverlay: true),
        isTrue,
      );
      // Đang Ẩn: bật/tắt in không phát lại.
      expect(
        livestreamOverlayRestartNeeded(previous: hidden, next: offHidden, sessionHasOverlay: false),
        isFalse,
      );
      expect(
        livestreamOverlayRestartNeeded(previous: offHidden, next: hidden, sessionHasOverlay: false),
        isFalse,
      );
      // Phiên vẫn đang in (đã ẩn giữa chừng): bấm Hiện chỉ đổi ảnh...
      expect(
        livestreamOverlayRestartNeeded(previous: hidden, next: shown, sessionHasOverlay: true),
        isFalse,
      );
      // ...trừ khi in đã bị tắt trong lúc ẩn.
      expect(
        livestreamOverlayRestartNeeded(previous: offHidden, next: offShown, sessionHasOverlay: true),
        isTrue,
      );
    });
  });
}
