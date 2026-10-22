import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffmpeg_kit_flutter_new_video/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/ffprobe_session.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:path_provider/path_provider.dart';

import 'scoreboard_frame_renderer.dart';
import 'scoreboard_service.dart';

/// Chữ chạy do FFmpeg vẽ (drawtext) theo từng khung hình của livestream.
class LivestreamTicker {
  /// File chữ (UTF-8, một dòng). FFmpeg đọc lại mỗi khung hình.
  final String textPath;
  final String fontPath;

  /// Font thường (không đậm): FFmpeg tô viền cùng màu để chữ dày hơn.
  final bool fakeBold;
  final int fontSize;
  final int textY;
  final int speedPxPerSecond;

  const LivestreamTicker({
    required this.textPath,
    required this.fontPath,
    required this.fakeBold,
    required this.fontSize,
    required this.textY,
    required this.speedPxPerSecond,
  });
}

/// Một ảnh PNG overlay chồng tại (`x`, `y`) pixel video, kích thước
/// `width`×`height` (Android: mỗi vùng bảng tỉ số là một input FFmpeg).
class LivestreamOverlayRegion {
  final String imagePath;
  final int x;
  final int y;
  final int width;
  final int height;

  const LivestreamOverlayRegion({
    required this.imagePath,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });
}

/// Ảnh overlay đã sẵn sàng cho một phiên livestream.
class LivestreamOverlay {
  /// Ảnh đầu tiên (iOS / cả khung: ảnh PNG toàn khung duy nhất — C5).
  final String imagePath;

  /// Kích thước khung video.
  final int width;
  final int height;

  /// null: chữ chạy (nếu có) nằm đứng yên trong ảnh overlay.
  final LivestreamTicker? ticker;

  /// Vị trí (pixel video) đặt ảnh overlay: dùng cho `overlay=x:y` của FFmpeg
  /// (xem [livestreamOverlayVideoArgs]). 0:0 khi ảnh phủ cả khung.
  final int x;
  final int y;

  /// Kích thước ảnh PNG (bằng khung video trừ khi chỉ vẽ vùng có nội dung).
  final int imageWidth;
  final int imageHeight;

  final List<LivestreamOverlayRegion>? _regions;

  const LivestreamOverlay({
    required this.imagePath,
    required this.width,
    required this.height,
    this.ticker,
    this.x = 0,
    this.y = 0,
    int? imageWidth,
    int? imageHeight,
    List<LivestreamOverlayRegion>? regions,
  }) : imageWidth = imageWidth ?? width,
       imageHeight = imageHeight ?? height,
       // ignore: prefer_initializing_formals
       _regions = regions;

  /// Các ảnh cần chồng (theo thứ tự input FFmpeg 1, 2, ...). Không truyền
  /// `regions`: một ảnh [imagePath] tại [x]:[y].
  List<LivestreamOverlayRegion> get regions {
    final regions = _regions;
    if (regions != null && regions.isNotEmpty) return regions;
    return [
      LivestreamOverlayRegion(
        imagePath: imagePath,
        x: x,
        y: y,
        width: imageWidth,
        height: imageHeight,
      ),
    ];
  }
}

/// Hai cờ của overlay bảng tỉ số quyết định có in vào livestream không.
typedef LivestreamOverlayFlags = ({bool burnIn, bool visible});

/// Đọc (`overlay.burnIn`, `overlay.visible`) từ JSON trạng thái bảng tỉ số
/// (cùng quy ước với trang `/overlay`: thiếu khoá = bật).
LivestreamOverlayFlags livestreamOverlayFlags(Map<String, dynamic> state) {
  final overlay = state['overlay'];
  if (overlay is! Map) return (burnIn: false, visible: false);
  return (
    burnIn: overlay['burnIn'] != false,
    visible: overlay['visible'] != false,
  );
}

/// Phiên phát cần chồng bảng tỉ số (giải mã + mã hoá lại hình). Bảng đang
/// ẩn: copy nguyên luồng (Android) / không mở luồng overlay native (iOS).
bool livestreamOverlayNeeded(LivestreamOverlayFlags flags) =>
    flags.burnIn && flags.visible;

/// Đổi cờ overlay khi đang phát có cần khởi động lại phiên phát không.
///
/// [sessionHasOverlay]: phiên hiện tại đang chồng bảng tỉ số.
/// - Phiên chưa chồng bảng: chỉ phát lại khi "cần overlay" vừa đổi
///   false → true (bấm Hiện, hoặc bật in khi đang hiện).
/// - Phiên đang chồng bảng: ẩn/hiện chỉ đổi ảnh (trong suốt khi ẩn), không
///   phát lại; chỉ phát lại khi bảng sắp hiện mà "in vào livestream" đã tắt
///   (tắt in khi đang hiện, hoặc bấm Hiện sau khi đã tắt in) để về copy.
/// Đổi điểm số, tên, cảnh... không làm đổi hai cờ nên không phát lại.
bool livestreamOverlayRestartNeeded({
  required LivestreamOverlayFlags? previous,
  required LivestreamOverlayFlags next,
  required bool sessionHasOverlay,
}) {
  if (previous == null) return false;
  if (sessionHasOverlay) {
    final wasShownWithoutBurnIn = previous.visible && !previous.burnIn;
    final shownWithoutBurnIn = next.visible && !next.burnIn;
    return shownWithoutBurnIn && !wasShownWithoutBurnIn;
  }
  return livestreamOverlayNeeded(next) && !livestreamOverlayNeeded(previous);
}

/// [inner] nằm trọn trong [outer].
bool livestreamRegionContains(ui.Rect outer, ui.Rect inner) =>
    inner.left >= outer.left &&
    inner.top >= outer.top &&
    inner.right <= outer.right &&
    inner.bottom <= outer.bottom;

/// Kích thước giải mã logo ảnh gốc [width]×[height]: giữ tỉ lệ, cạnh dài
/// không quá [maxSide], không phóng to (null = giữ kích thước gốc).
({int? width, int? height}) livestreamLogoDecodeSize(
  int width,
  int height,
  int maxSide,
) {
  if (width <= maxSide && height <= maxSide) return (width: null, height: null);
  // Chỉ đặt một cạnh: bộ giải mã tự giữ tỉ lệ cho cạnh còn lại.
  return width >= height
      ? (width: maxSide, height: null)
      : (width: null, height: maxSide);
}

/// Font hệ thống Android có đủ dấu tiếng Việt cho chữ chạy (đậm trước).
const List<String> livestreamTickerFontCandidates = [
  '/system/fonts/Roboto-Bold.ttf',
  '/system/fonts/RobotoStatic-Bold.ttf',
  '/system/fonts/NotoSans-Bold.ttf',
  '/system/fonts/DroidSans-Bold.ttf',
  '/system/fonts/Roboto-Regular.ttf',
  '/system/fonts/RobotoStatic-Regular.ttf',
  '/system/fonts/NotoSans-Regular.ttf',
  '/system/fonts/DroidSans.ttf',
];

/// Font đầu tiên đọc được trong [candidates]; null nếu không có.
String? findLivestreamTickerFont({
  List<String> candidates = livestreamTickerFontCandidates,
  bool Function(String path)? exists,
}) {
  final check = exists ?? (String path) {
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  };
  for (final path in candidates) {
    // Đường dẫn có ký tự đặc biệt của bộ lọc FFmpeg thì bỏ qua.
    if (!isSafeFilterPath(path)) continue;
    if (check(path)) return path;
  }
  return null;
}

/// Có để FFmpeg vẽ chữ chạy (drawtext) không. iOS: KHÔNG — FFmpeg chỉ copy
/// luồng overlay native (không có bộ lọc), chữ chạy vẽ đứng yên trong ảnh PNG.
bool useScrollingLivestreamTicker({
  required bool requested,
  required bool isIos,
}) => requested && !isIos;

/// Đường dẫn dùng được trong tham số bộ lọc FFmpeg khi đặt trong nháy đơn.
bool isSafeFilterPath(String path) =>
    path.isNotEmpty && !path.contains("'") && !path.contains('\\');

/// Nội dung file chữ chạy: một dòng, không rỗng (FFmpeg cũ báo lỗi khi đọc
/// file rỗng nên dùng một dấu cách khi không có chữ).
String livestreamTickerFileText(String text) {
  final line = text.replaceAll(RegExp(r'[\r\n\t\u0000-\u001F\u007F]+'), ' ').trim();
  return line.isEmpty ? ' ' : line;
}

/// Đọc kích thước "1920x1080" từ output của ffprobe.
({int width, int height})? parseProbedVideoSize(String? output) {
  if (output == null) return null;
  final match = RegExp(r'(\d{2,5})x(\d{2,5})').firstMatch(output);
  if (match == null) return null;
  final width = int.parse(match.group(1)!);
  final height = int.parse(match.group(2)!);
  if (width < 16 || height < 16 || width > 8192 || height > 8192) return null;
  return (width: width, height: height);
}

/// Kích thước khung hình thật của luồng RTSP cục bộ (null nếu không đọc được
/// trong thời gian cho phép).
Future<({int width, int height})?> probeRtspVideoSize(
  String url, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final completer = Completer<FFprobeSession>();
  FFprobeSession? session;
  try {
    session = await FFprobeKit.executeWithArgumentsAsync(
      [
        '-v',
        'error',
        '-rtsp_transport',
        'tcp',
        '-timeout',
        '5000000',
        '-select_streams',
        'v:0',
        '-show_entries',
        'stream=width,height',
        '-of',
        'csv=s=x:p=0',
        url,
      ],
      (completed) {
        if (!completer.isCompleted) completer.complete(completed);
      },
    );
    final done = await completer.future.timeout(timeout);
    return parseProbedVideoSize(await done.getOutput());
  } on TimeoutException {
    try {
      await session?.cancel();
    } catch (_) {}
    return null;
  } catch (error) {
    developer.log(
      '[SCOREBOARD] Unable to probe livestream size: $error',
      name: 'ScoreboardBurnIn',
    );
    return null;
  }
}

/// Giữ (các) file PNG overlay luôn khớp với trạng thái bảng tỉ số trong lúc
/// livestream. FFmpeg đọc lại các file này nhiều lần mỗi giây.
class ScoreboardBurnIn {
  ScoreboardBurnIn({
    ScoreboardService? service,
    this._renderer = const ScoreboardFrameRenderer(),
  }) : _service = service ?? ScoreboardService.instance;

  final ScoreboardService _service;
  final ScoreboardFrameRenderer _renderer;

  StreamSubscription<Map<String, dynamic>>? _subscription;
  Timer? _ticker;
  int _width = 0;
  int _height = 0;

  /// Các vùng ảnh overlay (pixel video) khi chồng từng vùng; null = một ảnh
  /// cả khung.
  List<ui.Rect>? _regions;

  /// File PNG của từng vùng (cùng thứ tự [_regions]); cả khung: một file.
  List<String> _paths = const [];
  String? _directory;
  String? _tickerPath;
  bool _scrollingTicker = false;
  String? _writtenTickerText;

  /// Khoá (kích thước khung + các vùng) của bộ file PNG đang có trên đĩa;
  /// null nếu chưa có bộ file dùng được.
  String? _writtenKey;

  /// Nội dung PNG đã ghi của từng file (bỏ qua ghi lại vùng không đổi).
  List<Uint8List?> _writtenBytes = const [];
  Future<bool>? _inFlight;
  bool _dirty = false;
  bool _active = false;
  bool _regionOutgrownReported = false;

  /// Đã dùng cảnh bảng lớn trong lần phát này: các phiên FFmpeg sau (kết nối
  /// lại) giữ sẵn vùng giữa màn hình. Xoá khi [stop].
  bool _reserveScenes = false;
  int _logoDecodeSize = 0;
  final Map<String, ui.Image> _logos = {};

  /// Chế độ chồng từng vùng ([start] với `cropToRegions`): gọi một lần khi
  /// nội dung mới (đổi vị trí, "Kích thước", số set, lần đầu dùng cảnh lớn)
  /// cần vùng lớn hơn các vùng đã khoá cho phiên FFmpeg. Phần thừa bị cắt cho
  /// tới khi phiên đẩy luồng được khởi động lại (runtime khởi động lại khi
  /// nhận được). Không gọi khi bảng tỉ số đang ẩn.
  void Function()? onRegionOutgrown;

  /// Gọi sau mỗi lần ghi xong (đổi tên nguyên tử) một ảnh PNG mới tại [path].
  /// iOS: publisher báo native nạp lại ảnh (`updateOverlayImage`).
  void Function(String path)? onImageWritten;

  bool get active => _active;

  /// Bảng tỉ số có bật "in vào livestream" không.
  Future<bool> enabled() async {
    await _service.load();
    final overlay = _service.snapshot()['overlay'];
    return overlay is Map && overlay['burnIn'] != false;
  }

  /// Cờ "in vào livestream" và "Hiện" hiện tại của bảng tỉ số.
  Future<LivestreamOverlayFlags> overlayFlags() async {
    await _service.load();
    return livestreamOverlayFlags(_service.snapshot());
  }

  /// Vẽ ảnh đầu tiên (bắt buộc có file trước khi FFmpeg chạy) và bắt đầu
  /// cập nhật theo bảng tỉ số.
  ///
  /// [scrollingTicker]: để FFmpeg vẽ chữ chạy theo từng khung hình (cần font
  /// hệ thống); nếu không, chữ chạy đứng yên trong ảnh.
  ///
  /// [cropToRegions] (Android): chỉ vẽ các vùng cố định của phiên
  /// ([ScoreboardFrameRenderer.sessionRegions]), mỗi vùng một PNG; FFmpeg
  /// PHẢI chồng từng ảnh tại vị trí của nó ([LivestreamOverlay.regions] →
  /// [livestreamOverlayInputArgs] + [livestreamOverlayVideoArgs]). false
  /// (iOS, C5): một PNG toàn khung.
  ///
  /// Ném lỗi nếu chưa vẽ được ảnh đúng kích thước (FFmpeg không được chạy với
  /// ảnh thiếu hoặc ảnh cũ sai kích thước).
  Future<LivestreamOverlay> start(
    int width,
    int height, {
    bool scrollingTicker = false,
    bool cropToRegions = false,
  }) async {
    await _service.load();
    final state = _service.snapshot();
    if (cropToRegions && ScoreboardFrameRenderer.sessionNeedsScenes(state)) {
      _reserveScenes = true;
    }
    final regions = cropToRegions
        ? ScoreboardFrameRenderer.sessionRegions(
            state,
            width: width,
            height: height,
            reserveScenes: _reserveScenes,
          )
        : null;
    final key = _fileKey(width, height, regions);
    if (_directory == null) {
      final temp = await getTemporaryDirectory();
      final directory = Directory(
        '${temp.path}${Platform.pathSeparator}scoreboard_burnin',
      );
      if (!await directory.exists()) await directory.create(recursive: true);
      _directory = directory.path;
      _tickerPath = '${directory.path}${Platform.pathSeparator}ticker.txt';
    }
    final directory = _directory!;
    final paths = regions == null
        ? ['$directory${Platform.pathSeparator}overlay.png']
        : [
            for (var i = 0; i < regions.length; i++)
              '$directory${Platform.pathSeparator}overlay_$i.png',
          ];
    final oldPaths = _paths;
    _width = width;
    _height = height;
    _regions = regions;
    _paths = paths;
    _regionOutgrownReported = false;
    // Phiên FFmpeg mới: ghi lại mọi file (không bỏ qua vùng "không đổi").
    _writtenBytes = const [];
    final tickerPath = _tickerPath!;
    if (_writtenKey != key) {
      // Đổi kích thước/vùng: bỏ ảnh cũ để FFmpeg không bao giờ đọc ảnh sai
      // kích thước nếu lần vẽ đầu lỗi.
      _writtenKey = null;
      for (final path in {...oldPaths, ...paths}) {
        await _deleteQuietly(path);
      }
    }
    // iOS luôn dùng chữ chạy đứng yên trong ảnh (đường "không có font").
    final scroll = useScrollingLivestreamTicker(
      requested: scrollingTicker,
      isIos: Platform.isIOS,
    );
    final font = scroll && isSafeFilterPath(tickerPath)
        ? findLivestreamTickerFont()
        : null;
    _scrollingTicker = font != null;
    // Phiên FFmpeg mới: luôn ghi lại file chữ.
    _writtenTickerText = null;
    _active = true;
    var rendered = await _render();
    if (!rendered || _writtenKey != key) {
      // Vòng vẽ của phiên trước (kích thước cũ) có thể vừa chạy xong thay cho
      // lần vẽ này: vẽ lại một lần.
      rendered = await _render();
    }
    if (!rendered || _writtenKey != key) {
      // Không có ảnh dùng được: dừng vẽ lại theo thay đổi (người gọi phát
      // không có bảng tỉ số và gọi stop()).
      _active = false;
      throw StateError('Không vẽ được ảnh bảng tỉ số ${width}x$height.');
    }
    // Vòng vẽ của phiên trước có thể vừa kết thúc mà chưa ghi file chữ cho
    // phiên này: ghi trực tiếp. FFmpeg cần file chữ có sẵn khi khởi động.
    if (_scrollingTicker && _writtenTickerText == null) {
      try {
        await _writeTicker(_service.snapshot());
      } catch (error) {
        developer.log(
          '[SCOREBOARD] Unable to write livestream ticker: $error',
          name: 'ScoreboardBurnIn',
        );
        _scrollingTicker = false;
        // Ảnh cần có chữ chạy đứng yên thay thế.
        await _render();
      }
    }
    _subscription ??= _service.changes.listen((_) => _schedule());
    // Đồng hồ trận và thông báo có hạn giờ cần vẽ lại theo thời gian.
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (_needsClockRefresh()) _schedule();
    });
    LivestreamTicker? ticker;
    if (font != null && _scrollingTicker) {
      final base = ScoreboardFrameRenderer.baseScale(width, height);
      final barHeight = ScoreboardFrameRenderer.tickerBarHeight * base;
      final fontSize = math.max(
        8,
        (ScoreboardFrameRenderer.tickerFontSize * base).round(),
      );
      final level = ScoreboardFrameRenderer.tickerSpeedLevel(
        _service.snapshot(),
      );
      ticker = LivestreamTicker(
        textPath: tickerPath,
        fontPath: font,
        fakeBold: !font.contains('Bold'),
        fontSize: fontSize,
        textY: (height - barHeight + (barHeight - fontSize * 1.15) / 2).round(),
        speedPxPerSecond: math.max(
          1,
          (ScoreboardFrameRenderer.tickerSpeeds[level - 1] * base).round(),
        ),
      );
    }
    final first = regions?.first;
    return LivestreamOverlay(
      imagePath: paths.first,
      width: width,
      height: height,
      ticker: ticker,
      x: first?.left.round() ?? 0,
      y: first?.top.round() ?? 0,
      imageWidth: first?.width.round() ?? width,
      imageHeight: first?.height.round() ?? height,
      regions: regions == null
          ? null
          : [
              for (var i = 0; i < regions.length; i++)
                LivestreamOverlayRegion(
                  imagePath: paths[i],
                  x: regions[i].left.round(),
                  y: regions[i].top.round(),
                  width: regions[i].width.round(),
                  height: regions[i].height.round(),
                ),
            ],
    );
  }

  static String _fileKey(int width, int height, List<ui.Rect>? regions) {
    final buffer = StringBuffer('${width}x$height');
    for (final region in regions ?? const <ui.Rect>[]) {
      buffer.write(
        '@${region.left.round()},${region.top.round()},'
        '${region.width.round()}x${region.height.round()}',
      );
    }
    return buffer.toString();
  }

  static Future<void> _deleteQuietly(String path) async {
    for (final candidate in [path, '$path.tmp']) {
      try {
        final file = File(candidate);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  void stop() {
    _active = false;
    _reserveScenes = false;
    _subscription?.cancel();
    _subscription = null;
    _ticker?.cancel();
    _ticker = null;
    for (final image in _logos.values) {
      image.dispose();
    }
    _logos.clear();
  }

  bool _needsClockRefresh() {
    final state = _service.snapshot();
    final overlay = state['overlay'];
    final timer = state['timer'];
    if (overlay is! Map) return false;
    final show = overlay['show'];
    final timerShown = show is Map && show['timer'] == true;
    // Thông báo có hạn giờ tự ẩn qua sự kiện "changes" của ScoreboardService,
    // nên chỉ đồng hồ đang chạy mới cần vẽ lại mỗi giây.
    return timerShown && timer is Map && timer['running'] == true;
  }

  void _schedule() {
    if (!_active) return;
    unawaited(_render());
  }

  /// Chỉ một lần vẽ chạy tại một thời điểm; yêu cầu trong lúc đang vẽ được
  /// gộp thành một lần vẽ lại ngay sau đó (với kích thước/trạng thái mới).
  /// Kết quả: lần vẽ cuối của vòng đang chạy có ghi được file không (vòng đó
  /// có thể đã bắt đầu với kích thước cũ: so [_writtenKey] để chắc chắn).
  Future<bool> _render() {
    final running = _inFlight;
    if (running != null) {
      _dirty = true;
      return running;
    }
    final future = _renderLoop();
    _inFlight = future;
    return future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
      // Yêu cầu đến đúng lúc vòng vẽ vừa kết thúc: vẽ thêm một lần.
      if (_dirty && _active) unawaited(_render());
    });
  }

  Future<bool> _renderLoop() async {
    if (_paths.isEmpty || _width <= 0 || _height <= 0) return false;
    var ok = false;
    try {
      do {
        _dirty = false;
        ok = false;
        final width = _width;
        final height = _height;
        final regions = _regions;
        final paths = _paths;
        final key = _fileKey(width, height, regions);
        final state = _service.snapshot();
        final scrolling = _scrollingTicker;
        if (scrolling) {
          // Lỗi ghi file chữ không được làm mất ảnh bảng tỉ số.
          try {
            await _writeTicker(state);
          } catch (error) {
            developer.log(
              '[SCOREBOARD] Unable to write livestream ticker: $error',
              name: 'ScoreboardBurnIn',
            );
          }
        }
        await _loadLogos(state, width, height);
        final images = await _renderer
            .renderRegionsPng(
              state,
              width: width,
              height: height,
              nowMs: _service.nowMs,
              logos: _logos,
              tickerText: !scrolling,
              regions:
                  regions ??
                  [
                    ui.Rect.fromLTWH(
                      0,
                      0,
                      width.toDouble(),
                      height.toDouble(),
                    ),
                  ],
            )
            .timeout(const Duration(seconds: 3));
        if (images.length != paths.length) {
          throw StateError('Số ảnh vùng không khớp số file overlay.');
        }
        // Cùng bộ file với lần ghi trước: chỉ ghi lại vùng đổi nội dung.
        var written = _writtenBytes;
        if (_writtenKey != key || written.length != paths.length) {
          written = List<Uint8List?>.filled(paths.length, null);
          _writtenBytes = written;
        }
        for (var i = 0; i < paths.length; i++) {
          final bytes = images[i];
          final previous = written[i];
          if (previous != null && listEquals(previous, bytes)) continue;
          // Ghi file tạm rồi đổi tên: FFmpeg không bao giờ đọc phải ảnh ghi dở.
          final path = paths[i];
          final temp = File('$path.tmp');
          await temp.writeAsBytes(bytes, flush: true);
          await temp.rename(path);
          written[i] = bytes;
          _notifyImageWritten(path);
        }
        _writtenKey = key;
        ok = true;
        if (regions != null) _checkRegions(state, width, height, regions);
      } while (_dirty && _active);
    } catch (error, stackTrace) {
      developer.log(
        '[SCOREBOARD] Unable to render livestream overlay',
        error: error,
        stackTrace: stackTrace,
        name: 'ScoreboardBurnIn',
      );
      return false;
    }
    return ok;
  }

  /// Lỗi của bên nhận không được làm hỏng vòng vẽ.
  void _notifyImageWritten(String path) {
    final callback = onImageWritten;
    if (callback == null) return;
    try {
      callback(path);
    } catch (error) {
      developer.log(
        '[SCOREBOARD] Overlay image listener failed: $error',
        name: 'ScoreboardBurnIn',
      );
    }
  }

  /// Chế độ vùng: báo khi nội dung có thể hiện cần vùng lớn hơn các vùng đã
  /// khoá. Bảng đang ẩn thì chưa báo (không phát lại khi đang ẩn); kiểm lại
  /// ở lần vẽ sau khi bảng hiện.
  void _checkRegions(
    Map<String, dynamic> state,
    int width,
    int height,
    List<ui.Rect> regions,
  ) {
    if (_regionOutgrownReported) return;
    if (!ScoreboardFrameRenderer.isShown(state)) return;
    if (ScoreboardFrameRenderer.sessionNeedsScenes(state)) {
      _reserveScenes = true;
    }
    final needed = ScoreboardFrameRenderer.sessionParts(
      state,
      width: width,
      height: height,
      scenes: _reserveScenes,
    );
    if (ScoreboardFrameRenderer.overlayRegionsCover(regions, needed)) return;
    _regionOutgrownReported = true;
    developer.log(
      '[SCOREBOARD] Overlay regions $regions are too small for the '
      'scoreboard; livestream needs a restart',
      name: 'ScoreboardBurnIn',
    );
    onRegionOutgrown?.call();
  }

  /// Ghi file chữ chạy cho FFmpeg (tạm rồi đổi tên) khi nội dung đổi.
  Future<void> _writeTicker(Map<String, dynamic> state) async {
    final path = _tickerPath;
    if (path == null) return;
    final text = livestreamTickerFileText(
      ScoreboardFrameRenderer.visibleTickerText(state),
    );
    if (text == _writtenTickerText) return;
    final temp = File('$path.tmp');
    await temp.writeAsString(text, flush: true);
    await temp.rename(path);
    _writtenTickerText = text;
  }

  Future<void> _loadLogos(
    Map<String, dynamic> state,
    int width,
    int height,
  ) async {
    // Giải mã logo vừa đủ kích thước vẽ lớn nhất của khung này (ảnh gốc có
    // thể rất lớn). Chạy trong vòng vẽ nên không có lần vẽ nào đang dùng ảnh.
    final decodeSize = ScoreboardFrameRenderer.logoDecodeSize(width, height);
    if (decodeSize != _logoDecodeSize) {
      for (final image in _logos.values) {
        image.dispose();
      }
      _logos.clear();
      _logoDecodeSize = decodeSize;
    }
    final wanted = <String>{};
    for (final key in const ['teamA', 'teamB']) {
      final team = state[key];
      final id = team is Map ? team['logoId']?.toString() : null;
      if (id != null && id.isNotEmpty) wanted.add(id);
    }
    for (final id in _logos.keys.toList()) {
      if (!wanted.contains(id)) _logos.remove(id)?.dispose();
    }
    for (final id in wanted) {
      if (_logos.containsKey(id)) continue;
      try {
        final file = await _service.logoFile(id);
        if (file == null) continue;
        final buffer = await ui.ImmutableBuffer.fromUint8List(
          await file.readAsBytes(),
        );
        // instantiateImageCodecWithSize tự giải phóng [buffer].
        final codec = await ui.instantiateImageCodecWithSize(
          buffer,
          getTargetSize: (intrinsicWidth, intrinsicHeight) {
            final target = livestreamLogoDecodeSize(
              intrinsicWidth,
              intrinsicHeight,
              decodeSize,
            );
            return ui.TargetImageSize(
              width: target.width,
              height: target.height,
            );
          },
        );
        final frame = await codec.getNextFrame();
        codec.dispose();
        if (!_active || _logos.containsKey(id)) {
          // stop() đã chạy trong lúc tải (hoặc đã có ảnh): không giữ lại ảnh.
          frame.image.dispose();
          continue;
        }
        _logos[id] = frame.image;
      } catch (error) {
        developer.log(
          '[SCOREBOARD] Unable to load logo $id: $error',
          name: 'ScoreboardBurnIn',
        );
      }
    }
  }
}

/// Tham số FFmpeg để chồng ảnh overlay [imagePath] (input số 1) lên video
/// RTSP (input số 0) rồi mã hoá lại H.264 bằng phần cứng Android.
List<String> livestreamOverlayInputArgs(String imagePath) => [
  // -re: đọc ảnh theo thời gian thực. -stream_loop -1: đọc lại file mỗi
  // vòng nên ảnh mới (đổi tên đè) được dùng ngay.
  '-re',
  '-f',
  'image2',
  '-framerate',
  '2',
  '-stream_loop',
  '-1',
  '-i',
  imagePath,
];

/// [overlayX]/[overlayY]: vị trí ảnh overlay ([LivestreamOverlay.x]/`y`);
/// mặc định 0:0 (ảnh phủ cả khung). [regions]: chồng nhiều ảnh (input 1..N,
/// mỗi ảnh một [livestreamOverlayInputArgs] theo đúng thứ tự); khi có thì
/// bỏ qua [overlayX]/[overlayY].
List<String> livestreamOverlayVideoArgs({
  required int bitrateBps,
  required int fps,
  LivestreamTicker? ticker,
  int overlayX = 0,
  int overlayY = 0,
  List<LivestreamOverlayRegion>? regions,
}) => [
  '-filter_complex',
  livestreamOverlayFilter(
    ticker,
    x: overlayX,
    y: overlayY,
    positions: regions == null
        ? null
        : [for (final region in regions) (x: region.x, y: region.y)],
  ),
  '-map',
  '[vout]',
  '-c:v',
  'h264_mediacodec',
  '-b:v',
  '$bitrateBps',
  '-g',
  '${(fps.clamp(1, 60)) * 2}',
];

/// Bộ lọc: chồng ảnh overlay (input 1) lên video (input 0); có [ticker] thì
/// vẽ thêm chữ chạy bằng drawtext (đọc lại file chữ mỗi khung hình, chạy từ
/// phải sang trái như trang /overlay). [x]/[y]: vị trí ảnh overlay (pixel).
///
/// [positions] (nhiều hơn một): chồng lần lượt input 1..N tại các vị trí đó:
/// `[0:v][ovr1]overlay=x1:y1[ov1];[ov1][ovr2]overlay=x2:y2,...[vout]`.
String livestreamOverlayFilter(
  LivestreamTicker? ticker, {
  int x = 0,
  int y = 0,
  List<({int x, int y})>? positions,
}) {
  final points = positions == null || positions.isEmpty
      ? [(x: x, y: y)]
      : positions;
  final buffer = StringBuffer();
  if (points.length == 1) {
    // Một ảnh: giữ nguyên chuỗi bộ lọc cũ.
    final point = points.single;
    buffer.write(
      '[1:v]format=rgba,setpts=PTS-STARTPTS[ovr];'
      '[0:v][ovr]overlay=${point.x}:${point.y}:eof_action=repeat:format=auto',
    );
  } else {
    for (var i = 1; i <= points.length; i++) {
      buffer.write('[$i:v]format=rgba,setpts=PTS-STARTPTS[ovr$i];');
    }
    for (var i = 1; i <= points.length; i++) {
      final point = points[i - 1];
      final source = i == 1 ? '[0:v]' : '[ov${i - 1}]';
      buffer.write(
        '$source[ovr$i]overlay=${point.x}:${point.y}'
        ':eof_action=repeat:format=auto',
      );
      if (i < points.length) buffer.write('[ov$i];');
    }
  }
  if (ticker != null) {
    buffer
      ..write(',drawtext=fontfile=\'${ticker.fontPath}\'')
      ..write(':textfile=\'${ticker.textPath}\'')
      ..write(':reload=1:expansion=none')
      ..write(':fontsize=${ticker.fontSize}:fontcolor=white')
      ..write(
        ticker.fakeBold
            ? ':borderw=1:bordercolor=white'
            : ':shadowcolor=black@0.35:shadowx=1:shadowy=1',
      )
      ..write(":x='w-mod(t*${ticker.speedPxPerSecond},w+tw)'")
      ..write(':y=${ticker.textY}');
  }
  buffer.write(',format=yuv420p[vout]');
  return buffer.toString();
}
