import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Vẽ bảng tỉ số thành một khung PNG trong suốt đúng kích thước video, để
/// FFmpeg chồng (overlay) lên luồng livestream. Bố cục giống trang
/// `/overlay` (thiết kế theo khung 1920×1080 rồi co giãn theo video thật).
class ScoreboardFrameRenderer {
  const ScoreboardFrameRenderer();

  static const double designWidth = 1920;
  static const double designHeight = 1080;

  /// Thanh chữ chạy (đơn vị khung thiết kế 1920×1080, không theo "Kích thước"
  /// của overlay — giống trang `/overlay`).
  static const double tickerBarHeight = 64;
  static const double tickerFontSize = 30;

  /// Tốc độ chữ chạy (px thiết kế/giây) cho mức 1..3, giống trang `/overlay`.
  static const List<double> tickerSpeeds = [90, 150, 230];

  /// Màu nền thanh chữ chạy khi FFmpeg vẽ chữ (chữ trắng) trên livestream.
  static const Color liveTickerBarColor = Color(0xEB0A101C);

  /// Tỉ lệ từ khung thiết kế sang video [width]×[height].
  static double baseScale(int width, int height) =>
      math.min(width / designWidth, height / designHeight);

  /// Chữ chạy đang hiện (rỗng nếu overlay đang ẩn, cảnh "hidden" hoặc tắt).
  static String visibleTickerText(Map<String, dynamic> state) {
    final view = _ScoreView(state, nowMs: 0, logos: const {});
    if (!view.visible || view.scene == 'hidden') return '';
    return view.tickerText();
  }

  /// Mức tốc độ chữ chạy (1..3).
  static int tickerSpeedLevel(Map<String, dynamic> state) {
    final ticker = _map(_map(state['overlay'])['ticker']);
    return _int(ticker['speed']).clamp(1, 3);
  }

  Future<Uint8List> renderPng(
    Map<String, dynamic> state, {
    required int width,
    required int height,
    required int nowMs,
    Map<String, ui.Image> logos = const {},
    bool tickerText = true,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );
    paint(
      canvas,
      Size(width.toDouble(), height.toDouble()),
      state,
      nowMs: nowMs,
      logos: logos,
      tickerText: tickerText,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw StateError('Không tạo được ảnh bảng tỉ số.');
      }
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image.dispose();
    }
  }

  /// Vẽ lên [canvas] có kích thước [size] (pixel video).
  ///
  /// [tickerText] = false: chỉ vẽ nền thanh chữ chạy, chữ do FFmpeg vẽ và cho
  /// chạy theo từng khung hình.
  void paint(
    Canvas canvas,
    Size size,
    Map<String, dynamic> state, {
    required int nowMs,
    Map<String, ui.Image> logos = const {},
    bool tickerText = true,
  }) {
    final view = _ScoreView(state, nowMs: nowMs, logos: logos);
    if (!view.visible || view.scene == 'hidden' || size.isEmpty) return;
    final base = math.min(size.width / designWidth, size.height / designHeight);
    if (base <= 0) return;
    // Lề, vị trí và thanh chữ chạy giữ nguyên khi đổi "Kích thước"; chỉ bảng
    // tỉ số/thông báo to nhỏ theo (giống trang /overlay).
    final k = base * view.scale;
    final painter = _Painter(canvas, view, unit: 1 / view.scale);
    canvas.save();
    canvas.scale(base);
    painter.ticker(
      Size(size.width / base, size.height / base),
      drawText: tickerText,
    );
    canvas.restore();
    canvas.save();
    canvas.scale(k);
    final virtual = Size(size.width / k, size.height / k);
    switch (view.scene) {
      case 'full':
        painter.full(virtual);
      case 'intro':
        painter.intro(virtual);
      case 'result':
        painter.result(virtual);
      default:
        painter.scorebar(virtual);
    }
    painter.banner(virtual);
    canvas.restore();
  }
}

// ============================================================
// DỮ LIỆU ĐÃ ĐỌC TỪ JSON
// ============================================================

class _Team {
  final String name;
  final String short;
  final Color color;
  final List<String> players;
  final ui.Image? logo;

  const _Team(this.name, this.short, this.color, this.players, this.logo);
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.map((k, v) => MapEntry(k.toString(), v));
  return const <String, dynamic>{};
}

int _int(Object? value) => value is num ? value.toInt() : int.tryParse('$value') ?? 0;

Color _color(Object? value, Color fallback) {
  final text = value?.toString() ?? '';
  if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(text)) return fallback;
  return Color(int.parse('FF${text.substring(1)}', radix: 16));
}

class _ScoreView {
  _ScoreView(Map<String, dynamic> s, {required this.nowMs, required Map<String, ui.Image> logos})
    : sport = s['sport']?.toString() ?? 'pickleball',
      overlay = _map(s['overlay']),
      match = _map(s['match']),
      display = _map(s['display']),
      points = _map(s['points']),
      games = _map(s['games']),
      setsWon = _map(s['setsWon']),
      sets = (s['sets'] is List ? s['sets'] as List : const []).map(_map).toList(),
      serving = s['serving']?.toString() ?? 'none',
      status = s['status']?.toString() ?? 'playing',
      winner = s['winner']?.toString(),
      swapped = s['sidesSwapped'] == true,
      currentSet = _int(s['currentSet']),
      bestOf = _int(_map(s['rules'])['bestOf']),
      doubles = _map(s['rules'])['doubles'] == true,
      sideout = _map(s['rules'])['scoring'] == 'sideout',
      timer = _map(s['timer']),
      teamA = _team(_map(s['teamA']), 'A', logos),
      teamB = _team(_map(s['teamB']), 'B', logos);

  static _Team _team(Map<String, dynamic> json, String id, Map<String, ui.Image> logos) {
    final players = json['players'] is List
        ? (json['players'] as List).map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
        : <String>[];
    final logoId = json['logoId']?.toString();
    return _Team(
      json['name']?.toString() ?? 'Đội $id',
      json['short']?.toString() ?? id,
      _color(json['color'], id == 'A' ? const Color(0xFF1565C0) : const Color(0xFFC62828)),
      players,
      logoId == null ? null : logos[logoId],
    );
  }

  final int nowMs;
  final String sport;
  final Map<String, dynamic> overlay;
  final Map<String, dynamic> match;
  final Map<String, dynamic> display;
  final Map<String, dynamic> points;
  final Map<String, dynamic> games;
  final Map<String, dynamic> setsWon;
  final List<Map<String, dynamic>> sets;
  final String serving;
  final String status;
  final String? winner;
  final bool swapped;
  final int currentSet;
  final int bestOf;
  final bool doubles;
  final bool sideout;
  final Map<String, dynamic> timer;
  final _Team teamA;
  final _Team teamB;

  bool get tennis => sport == 'tennis';
  bool get finished => status == 'finished';
  String get scene => overlay['scene']?.toString() ?? 'scorebar';
  String get theme => overlay['theme']?.toString() ?? 'dark';
  String get position => overlay['position']?.toString() ?? 'tl';
  bool get visible => overlay['visible'] != false;
  double get scale {
    final value = overlay['scale'];
    final parsed = value is num ? value.toDouble() : 1.0;
    return parsed.clamp(0.5, 2.0).toDouble();
  }

  Color get accent => _color(overlay['accent'], const Color(0xFFFFC107));
  Map<String, dynamic> get show => _map(overlay['show']);
  bool showFlag(String key) => show[key] != false && (key != 'timer' || show[key] == true);

  _Team team(String id) => id == 'A' ? teamA : teamB;
  List<String> get order => swapped ? const ['B', 'A'] : const ['A', 'B'];

  String title() => match['tournament']?.toString() ?? '';
  String subtitle() => [match['round'], match['court']]
      .map((e) => e?.toString() ?? '')
      .where((e) => e.isNotEmpty)
      .join(' · ');

  String pointsText(String id) {
    final low = id.toLowerCase();
    if (finished) return '${_int(setsWon[low])}';
    return display[low]?.toString() ?? '${_int(points[low])}';
  }

  String timerText() {
    final running = timer['running'] == true;
    final elapsed = _int(timer['accumulatedMs']) +
        (running ? math.max(0, nowMs - _int(timer['startedAtMs'])) : 0);
    final total = elapsed ~/ 1000;
    String two(int v) => v.toString().padLeft(2, '0');
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final sec = total % 60;
    return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
  }

  String footer() {
    if (finished) {
      if (winner == 'A') return '${teamA.short} THẮNG';
      if (winner == 'B') return '${teamB.short} THẮNG';
      return 'KẾT THÚC';
    }
    final kind = display['kind']?.toString();
    if (kind == 'deuce') return 'DEUCE';
    if (kind == 'advantage') {
      final adv = display['advantage']?.toString();
      if (adv == 'A') return 'LỢI THẾ ${teamA.short}';
      if (adv == 'B') return 'LỢI THẾ ${teamB.short}';
      return 'LỢI THẾ';
    }
    if (kind == 'tiebreak') return 'TIE-BREAK';
    if (kind == 'sideout' && doubles) return display['callout']?.toString() ?? '';
    return '';
  }

  String bannerText() {
    final banner = _map(overlay['banner']);
    final text = banner['text']?.toString() ?? '';
    final until = _int(banner['untilMs']);
    if (text.isEmpty) return '';
    if (until > 0 && nowMs >= until) return '';
    return text;
  }

  String tickerText() {
    final ticker = _map(overlay['ticker']);
    if (ticker['enabled'] != true) return '';
    return ticker['text']?.toString() ?? '';
  }
}

// ============================================================
// VẼ
// ============================================================

class _Palette {
  final Color bg;
  final Color bg2;
  final Color fg;
  final Color muted;

  const _Palette(this.bg, this.bg2, this.fg, this.muted);

  factory _Palette.of(String theme) {
    switch (theme) {
      case 'light':
        return const _Palette(
          Color(0xF2FFFFFF),
          Color(0x120A1428),
          Color(0xFF0E1726),
          Color(0xA60E1726),
        );
      case 'glass':
        return const _Palette(
          Color(0x8C141C2D),
          Color(0x1FFFFFFF),
          Color(0xFFFFFFFF),
          Color(0xBFFFFFFF),
        );
      default:
        return const _Palette(
          Color(0xEB0A101C),
          Color(0x14FFFFFF),
          Color(0xFFFFFFFF),
          Color(0xB3FFFFFF),
        );
    }
  }
}

class _Painter {
  _Painter(this.canvas, this.view, {this.unit = 1})
    : palette = _Palette.of(view.theme);

  final Canvas canvas;
  final _ScoreView view;
  final _Palette palette;

  /// 1 px khung thiết kế tính theo toạ độ đang vẽ (đã nhân "Kích thước").
  final double unit;
  static const double margin = 48;

  TextPainter _text(
    String text,
    double size,
    Color color, {
    FontWeight weight = FontWeight.w800,
    double maxWidth = double.infinity,
    TextAlign align = TextAlign.left,
    double letterSpacing = 0,
  }) {
    return TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: size,
          color: color,
          fontWeight: weight,
          letterSpacing: letterSpacing,
          fontFeatures: const [ui.FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: align,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
  }

  void _drawText(TextPainter painter, Offset offset) {
    painter.paint(canvas, offset);
    painter.dispose();
  }

  /// Vẽ chữ căn giữa trong [rect].
  void _centerText(String text, Rect rect, double size, Color color,
      {FontWeight weight = FontWeight.w800}) {
    final p = _text(text, size, color, weight: weight, maxWidth: rect.width);
    _drawText(
      p,
      Offset(
        rect.left + (rect.width - p.width) / 2,
        rect.top + (rect.height - p.height) / 2,
      ),
    );
  }

  void _shadowedPanel(RRect rrect) {
    canvas.drawRRect(
      rrect.shift(const Offset(0, 10)),
      Paint()
        ..color = const Color(0x55000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 15),
    );
    canvas.drawRRect(rrect, Paint()..color = palette.bg);
  }

  void _logo(ui.Image image, Rect target) {
    final src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final scale = math.min(target.width / src.width, target.height / src.height);
    final w = src.width * scale;
    final h = src.height * scale;
    final dst = Rect.fromLTWH(
      target.left + (target.width - w) / 2,
      target.top + (target.height - h) / 2,
      w,
      h,
    );
    canvas.drawImageRect(image, src, dst, Paint()..filterQuality = FilterQuality.medium);
  }

  // ---------------- SCOREBAR ----------------
  void scorebar(Size size) {
    final v = view;
    const rowH = 62.0;
    final showSets = v.showFlag('sets');
    final showServe = v.showFlag('serve');
    final showTimer = v.showFlag('timer');
    final title = v.showFlag('tournament')
        ? [v.title(), v.subtitle()].where((e) => e.isNotEmpty).join(' · ')
        : '';
    final headH = (title.isNotEmpty || showTimer) ? 36.0 : 0.0;
    final foot = v.footer();
    final footH = foot.isEmpty ? 0.0 : 30.0;
    final hasLogo = v.teamA.logo != null || v.teamB.logo != null;

    var nameW = 150.0;
    for (final id in v.order) {
      final p = _text(v.team(id).name, 30, palette.fg);
      nameW = math.max(nameW, p.width);
      p.dispose();
    }
    nameW = math.min(nameW, 420.0) + 28;
    var ptsW = 84.0;
    for (final id in v.order) {
      final p = _text(v.pointsText(id), 38, const Color(0xFF111111), weight: FontWeight.w900);
      ptsW = math.max(ptsW, p.width + 20);
      p.dispose();
    }
    final setsW = showSets ? v.sets.length * 40.0 : 0.0;
    final gamesW = v.tennis ? 52.0 : 0.0;
    final serveW = showServe ? 26.0 : 0.0;
    final logoW = hasLogo ? 56.0 : 0.0;
    final width = math.min(
      820.0,
      math.max(560.0, 10 + logoW + nameW + serveW + setsW + gamesW + ptsW),
    );
    final height = headH + rowH * 2 + footH + 4;

    final pos = v.position;
    final m = margin * unit;
    final left = pos.endsWith('l')
        ? m
        : pos.endsWith('r')
        ? size.width - m - width
        : (size.width - width) / 2;
    final tickerOn = v.tickerText().isNotEmpty;
    // Chừa chỗ cho thanh chữ chạy (không co giãn theo "Kích thước").
    final top = pos.startsWith('b')
        ? size.height - m - height - (tickerOn ? 72 * unit : 0)
        : m;
    final box = Rect.fromLTWH(left, top, width, height);
    final rrect = RRect.fromRectAndRadius(box, const Radius.circular(14));
    _shadowedPanel(rrect);
    canvas.save();
    canvas.clipRRect(rrect);
    // Viền nhấn phía dưới.
    canvas.drawRect(
      Rect.fromLTWH(left, box.bottom - 4, width, 4),
      Paint()..color = v.accent,
    );

    var y = top;
    if (headH > 0) {
      canvas.drawRect(Rect.fromLTWH(left, y, width, headH), Paint()..color = palette.bg2);
      var clockW = 0.0;
      if (showTimer) {
        final clock = _text(v.timerText(), 19, palette.fg);
        clockW = clock.width + 16;
        _drawText(clock, Offset(left + width - clockW, y + (headH - clock.height) / 2));
      }
      if (title.isNotEmpty) {
        final t = _text(
          title,
          19,
          palette.muted,
          weight: FontWeight.w700,
          maxWidth: math.max(0.0, width - 32 - clockW),
        );
        _drawText(t, Offset(left + 16, y + (headH - t.height) / 2));
      }
      y += headH;
    }

    for (var i = 0; i < 2; i++) {
      final id = v.order[i];
      final team = v.team(id);
      final low = id.toLowerCase();
      final other = low == 'a' ? 'b' : 'a';
      if (i == 1) {
        canvas.drawRect(Rect.fromLTWH(left, y, width, 1), Paint()..color = palette.bg2);
      }
      var x = left;
      canvas.drawRect(Rect.fromLTWH(x, y, 10, rowH), Paint()..color = team.color);
      x += 10;
      if (hasLogo) {
        final logo = team.logo;
        if (logo != null) _logo(logo, Rect.fromLTWH(x + 10, y + 8, 46, 46));
        x += logoW;
      }
      // Phần bên phải: điểm, game, set, giao.
      var right = left + width;
      canvas.drawRect(
        Rect.fromLTWH(right - ptsW, y, ptsW, rowH),
        Paint()..color = v.accent,
      );
      _centerText(
        v.pointsText(id),
        Rect.fromLTWH(right - ptsW, y, ptsW, rowH),
        38,
        const Color(0xFF111111),
        weight: FontWeight.w900,
      );
      right -= ptsW;
      if (v.tennis) {
        canvas.drawRect(
          Rect.fromLTWH(right - gamesW, y, gamesW, rowH),
          Paint()..color = palette.bg2,
        );
        _centerText(
          '${_int(v.games[low])}',
          Rect.fromLTWH(right - gamesW, y, gamesW, rowH),
          28,
          palette.fg,
        );
        right -= gamesW;
      }
      if (showSets && v.sets.isNotEmpty) {
        var sx = right - setsW;
        for (final set in v.sets) {
          final mine = _int(set[low]);
          final theirs = _int(set[other]);
          _centerText(
            '$mine',
            Rect.fromLTWH(sx, y, 40, rowH),
            24,
            mine > theirs ? palette.fg : palette.muted,
            weight: FontWeight.w700,
          );
          sx += 40;
        }
        right -= setsW;
      }
      if (showServe) {
        if (v.serving == id && !v.finished) {
          canvas.drawCircle(
            Offset(right - serveW / 2, y + rowH / 2),
            7,
            Paint()..color = v.accent,
          );
        }
        right -= serveW;
      }
      final name = _text(
        team.name,
        30,
        palette.fg,
        maxWidth: math.max(0.0, right - x - 28),
      );
      _drawText(name, Offset(x + 14, y + (rowH - name.height) / 2));
      y += rowH;
    }

    if (footH > 0) {
      canvas.drawRect(Rect.fromLTWH(left, y, width, footH), Paint()..color = palette.bg2);
      _centerText(
        foot,
        Rect.fromLTWH(left, y, width, footH),
        18,
        view.theme == 'light' ? palette.fg : v.accent,
      );
    }
    canvas.restore();
  }

  // ---------------- PANEL HEADER ----------------
  double _panelHeader(Rect panel, String title, String subtitle) {
    const headH = 96.0;
    canvas.drawRect(
      Rect.fromLTWH(panel.left, panel.top, panel.width, headH),
      Paint()..color = palette.bg2,
    );
    final t = _text(title, 32, palette.fg, maxWidth: panel.width - 40);
    _drawText(t, Offset(panel.left + (panel.width - t.width) / 2, panel.top + 14));
    if (subtitle.isNotEmpty) {
      final s = _text(
        subtitle,
        22,
        palette.muted,
        weight: FontWeight.w500,
        maxWidth: panel.width - 40,
      );
      _drawText(s, Offset(panel.left + (panel.width - s.width) / 2, panel.top + 58));
    }
    return panel.top + headH;
  }

  RRect _panel(Size size, double width, double height) {
    final rect = Rect.fromLTWH(
      (size.width - width) / 2,
      (size.height - height) / 2,
      width,
      height,
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(22));
    _shadowedPanel(rrect);
    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawRect(
      Rect.fromLTWH(rect.left, rect.bottom - 6, rect.width, 6),
      Paint()..color = view.accent,
    );
    return rrect;
  }

  // ---------------- FULL ----------------
  void full(Size size) {
    final v = view;
    final cols = math.max(v.bestOf, v.sets.length);
    const rowH = 92.0;
    const colW = 108.0;
    const nameW = 560.0;
    const ptsW = 140.0;
    final width = 36 + nameW + cols * colW + ptsW;
    final height = 96 + 44 + rowH * 2 + 8;
    final rrect = _panel(size, width, height);
    final panel = rrect.outerRect;
    final sub = [
      v.subtitle(),
      v.finished ? 'Hết trận' : 'Set ${v.currentSet}',
    ].where((e) => e.isNotEmpty).join(' · ');
    var y = _panelHeader(panel, v.title().isEmpty ? 'BẢNG TỈ SỐ' : v.title(), sub);
    final colStart = panel.left + 18 + nameW;
    for (var i = 0; i < cols; i++) {
      _centerText(
        'SET ${i + 1}',
        Rect.fromLTWH(colStart + i * colW, y, colW, 44),
        20,
        palette.muted,
        weight: FontWeight.w700,
      );
    }
    _centerText(
      'ĐIỂM',
      Rect.fromLTWH(panel.right - ptsW, y, ptsW, 44),
      20,
      palette.muted,
      weight: FontWeight.w700,
    );
    y += 44;
    for (var r = 0; r < 2; r++) {
      final id = v.order[r];
      final team = v.team(id);
      final low = id.toLowerCase();
      final other = low == 'a' ? 'b' : 'a';
      if (r == 1) {
        canvas.drawRect(Rect.fromLTWH(panel.left, y, panel.width, 1), Paint()..color = palette.bg2);
      }
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(panel.left + 18, y + 24, 14, 44),
          const Radius.circular(4),
        ),
        Paint()..color = team.color,
      );
      final hasPlayers = team.players.isNotEmpty;
      final name = _text(team.name, 40, palette.fg, maxWidth: nameW - 70);
      final nameTop = hasPlayers ? y + 10 : y + (rowH - name.height) / 2;
      final nameWidth = name.width;
      _drawText(name, Offset(panel.left + 48, nameTop));
      if (v.serving == id && !v.finished) {
        canvas.drawCircle(
          Offset(panel.left + 48 + nameWidth + 22, nameTop + 28),
          8,
          Paint()..color = v.accent,
        );
      }
      if (hasPlayers) {
        final pl = _text(
          team.players.join(' · '),
          22,
          palette.muted,
          weight: FontWeight.w600,
          maxWidth: nameW - 70,
        );
        _drawText(pl, Offset(panel.left + 48, y + 60));
      }
      for (var i = 0; i < cols; i++) {
        var text = '–';
        var color = palette.muted;
        if (i < v.sets.length) {
          final mine = _int(v.sets[i][low]);
          final theirs = _int(v.sets[i][other]);
          text = '$mine';
          if (mine > theirs) color = palette.fg;
        } else if (i == v.sets.length && !v.finished && v.tennis) {
          text = '${_int(v.games[low])}';
          color = palette.fg;
        }
        _centerText(text, Rect.fromLTWH(colStart + i * colW, y, colW, rowH), 40, color);
      }
      canvas.drawRect(
        Rect.fromLTWH(panel.right - ptsW, y, ptsW, rowH),
        Paint()..color = v.accent,
      );
      _centerText(
        v.pointsText(id),
        Rect.fromLTWH(panel.right - ptsW, y, ptsW, rowH),
        40,
        const Color(0xFF111111),
      );
      y += rowH;
    }
    canvas.restore();
  }

  // ---------------- INTRO ----------------
  void intro(Size size) {
    final v = view;
    final hasLogo = v.teamA.logo != null || v.teamB.logo != null;
    const teamW = 560.0;
    final bodyH = (hasLogo ? 194.0 : 0.0) + 90 + 54;
    final width = teamW * 2 + 160 + 96;
    final height = 96 + 36 + bodyH + 36;
    final rrect = _panel(size, width, height);
    final panel = rrect.outerRect;
    final top = _panelHeader(
      panel,
      v.title().isEmpty ? 'TRẬN ĐẤU' : v.title(),
      v.subtitle(),
    ) + 36;
    final vs = _text('VS', 64, v.accent, weight: FontWeight.w900);
    _drawText(
      vs,
      Offset(panel.left + (panel.width - vs.width) / 2, top + (bodyH - vs.height) / 2),
    );
    for (var i = 0; i < 2; i++) {
      final team = v.team(i == 0 ? 'A' : 'B');
      final x = i == 0 ? panel.left + 48 : panel.right - 48 - teamW;
      var y = top;
      if (hasLogo) {
        final logo = team.logo;
        if (logo != null) _logo(logo, Rect.fromLTWH(x + (teamW - 180) / 2, y, 180, 180));
        y += 194;
      }
      final name = _text(team.name, 52, palette.fg, weight: FontWeight.w900, maxWidth: teamW);
      _drawText(name, Offset(x + (teamW - name.width) / 2, y));
      y += 72;
      canvas.drawRect(Rect.fromLTWH(x, y, teamW, 8), Paint()..color = team.color);
      y += 18;
      if (team.players.isNotEmpty) {
        final pl = _text(
          team.players.join(' · '),
          28,
          palette.muted,
          weight: FontWeight.w600,
          maxWidth: teamW,
        );
        _drawText(pl, Offset(x + (teamW - pl.width) / 2, y));
      }
    }
    canvas.restore();
  }

  // ---------------- RESULT ----------------
  void result(Size size) {
    final v = view;
    const width = 960.0;
    const height = 96.0 + 250;
    final rrect = _panel(size, width, height);
    final panel = rrect.outerRect;
    final y = _panelHeader(
      panel,
      v.title().isEmpty ? 'KẾT QUẢ TRẬN ĐẤU' : v.title(),
      v.subtitle(),
    );
    final setsA = _int(v.setsWon['a']);
    final setsB = _int(v.setsWon['b']);
    final String? leader = v.winner == 'A' || v.winner == 'B'
        ? v.winner
        : (setsA == setsB ? null : (setsA > setsB ? 'A' : 'B'));
    _centerText(
      v.finished ? 'CHIẾN THẮNG' : 'TỈ SỐ HIỆN TẠI',
      Rect.fromLTWH(panel.left, y + 24, width, 34),
      26,
      palette.muted,
    );
    _centerText(
      leader == null ? '${v.teamA.short} – ${v.teamB.short}' : v.team(leader).name,
      Rect.fromLTWH(panel.left + 30, y + 64, width - 60, 92),
      72,
      palette.fg,
      weight: FontWeight.w900,
    );
    final detail = v.sets.isEmpty
        ? '$setsA – $setsB'
        : '$setsA – $setsB   (${v.sets.map((s) => '${_int(s['a'])}-${_int(s['b'])}').join(', ')})';
    _centerText(detail, Rect.fromLTWH(panel.left + 30, y + 164, width - 60, 50), 36, palette.muted);
    canvas.restore();
  }

  // ---------------- BANNER / TICKER ----------------
  void banner(Size size) {
    final text = view.bannerText();
    if (text.isEmpty) return;
    final p = _text(
      text,
      46,
      const Color(0xFF111111),
      weight: FontWeight.w900,
      maxWidth: size.width - 200,
      letterSpacing: 2,
    );
    final w = p.width + 92;
    final h = p.height + 32;
    final atBottom = view.scene == 'scorebar' && view.position == 'tc';
    final top = atBottom ? size.height - 150 * unit - h : 150 * unit;
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH((size.width - w) / 2, top, w, h),
      const Radius.circular(16),
    );
    canvas.drawRRect(
      rect.shift(const Offset(0, 12)),
      Paint()
        ..color = const Color(0x73000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 15),
    );
    canvas.drawRRect(rect, Paint()..color = view.accent);
    _drawText(p, Offset(rect.left + 46, rect.top + 16));
  }

  /// [size] theo khung thiết kế (không nhân "Kích thước").
  void ticker(Size size, {bool drawText = true}) {
    final text = view.tickerText();
    if (text.isEmpty) return;
    const h = ScoreboardFrameRenderer.tickerBarHeight;
    final top = size.height - h;
    canvas.drawRect(Rect.fromLTWH(0, top - 4, size.width, 4), Paint()..color = view.accent);
    canvas.drawRect(
      Rect.fromLTWH(0, top, size.width, h),
      Paint()
        ..color = drawText
            ? palette.bg
            : ScoreboardFrameRenderer.liveTickerBarColor,
    );
    // Chữ chạy do FFmpeg vẽ theo từng khung hình.
    if (!drawText) return;
    // Máy không vẽ được chữ chạy bằng FFmpeg: chữ đứng yên, căn giữa.
    final p = _text(
      text,
      ScoreboardFrameRenderer.tickerFontSize,
      palette.fg,
      weight: FontWeight.w700,
      maxWidth: size.width - 80,
    );
    _drawText(p, Offset((size.width - p.width) / 2, top + (h - p.height) / 2));
  }
}
