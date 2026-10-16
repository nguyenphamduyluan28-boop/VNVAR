import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ffmpeg_kit_flutter_new_video/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/ffprobe_session.dart';
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

/// Ảnh overlay đã sẵn sàng cho một phiên livestream.
class LivestreamOverlay {
  final String imagePath;
  final int width;
  final int height;

  /// null: chữ chạy (nếu có) nằm đứng yên trong ảnh overlay.
  final LivestreamTicker? ticker;

  const LivestreamOverlay({
    required this.imagePath,
    required this.width,
    required this.height,
    this.ticker,
  });
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

/// Giữ file PNG overlay luôn khớp với trạng thái bảng tỉ số trong lúc
/// livestream. FFmpeg đọc lại file này nhiều lần mỗi giây.
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
  String? _path;
  String? _tickerPath;
  bool _scrollingTicker = false;
  String? _writtenTickerText;
  Future<void>? _inFlight;
  bool _dirty = false;
  bool _active = false;
  final Map<String, ui.Image> _logos = {};

  bool get active => _active;

  /// Bảng tỉ số có bật "in vào livestream" không.
  Future<bool> enabled() async {
    await _service.load();
    final overlay = _service.snapshot()['overlay'];
    return overlay is Map && overlay['burnIn'] != false;
  }

  /// Vẽ ảnh đầu tiên (bắt buộc có file trước khi FFmpeg chạy) và bắt đầu
  /// cập nhật theo bảng tỉ số.
  ///
  /// [scrollingTicker]: để FFmpeg vẽ chữ chạy theo từng khung hình (cần font
  /// hệ thống); nếu không, chữ chạy đứng yên trong ảnh.
  Future<LivestreamOverlay> start(
    int width,
    int height, {
    bool scrollingTicker = false,
  }) async {
    await _service.load();
    _width = width;
    _height = height;
    if (_path == null) {
      final temp = await getTemporaryDirectory();
      final directory = Directory(
        '${temp.path}${Platform.pathSeparator}scoreboard_burnin',
      );
      if (!await directory.exists()) await directory.create(recursive: true);
      _path = '${directory.path}${Platform.pathSeparator}overlay.png';
      _tickerPath = '${directory.path}${Platform.pathSeparator}ticker.txt';
    }
    final tickerPath = _tickerPath!;
    final font = scrollingTicker && isSafeFilterPath(tickerPath)
        ? findLivestreamTickerFont()
        : null;
    _scrollingTicker = font != null;
    // Phiên FFmpeg mới: luôn ghi lại file chữ.
    _writtenTickerText = null;
    _active = true;
    await _render();
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
    return LivestreamOverlay(
      imagePath: _path!,
      width: width,
      height: height,
      ticker: ticker,
    );
  }

  void stop() {
    _active = false;
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
  Future<void> _render() {
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

  Future<void> _renderLoop() async {
    final path = _path;
    if (path == null || _width <= 0 || _height <= 0) return;
    try {
      do {
        _dirty = false;
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
        await _loadLogos(state);
        final bytes = await _renderer
            .renderPng(
              state,
              width: _width,
              height: _height,
              nowMs: _service.nowMs,
              logos: _logos,
              tickerText: !scrolling,
            )
            .timeout(const Duration(seconds: 3));
        // Ghi file tạm rồi đổi tên: FFmpeg không bao giờ đọc phải ảnh ghi dở.
        final temp = File('$path.tmp');
        await temp.writeAsBytes(bytes, flush: true);
        await temp.rename(path);
      } while (_dirty && _active);
    } catch (error, stackTrace) {
      developer.log(
        '[SCOREBOARD] Unable to render livestream overlay',
        error: error,
        stackTrace: stackTrace,
        name: 'ScoreboardBurnIn',
      );
    }
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

  Future<void> _loadLogos(Map<String, dynamic> state) async {
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
        final codec = await ui.instantiateImageCodec(await file.readAsBytes());
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

List<String> livestreamOverlayVideoArgs({
  required int bitrateBps,
  required int fps,
  LivestreamTicker? ticker,
}) => [
  '-filter_complex',
  livestreamOverlayFilter(ticker),
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
/// phải sang trái như trang /overlay).
String livestreamOverlayFilter(LivestreamTicker? ticker) {
  final buffer = StringBuffer(
    '[1:v]format=rgba,setpts=PTS-STARTPTS[ovr];'
    '[0:v][ovr]overlay=0:0:eof_action=repeat:format=auto',
  );
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
