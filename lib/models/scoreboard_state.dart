import 'dart:math' as math;

/// Lỗi khi một lệnh bảng tỉ số không hợp lệ. [statusCode] là mã HTTP trả về
/// cho client (409 = xung đột trạng thái, 422 = dữ liệu không hợp lệ).
class ScoreboardException implements Exception {
  final int statusCode;
  final String code;
  final String message;

  const ScoreboardException(this.statusCode, this.code, this.message);

  @override
  String toString() => 'ScoreboardException($code): $message';
}

/// Các môn hỗ trợ.
const List<String> scoreboardSports = [
  'pickleball',
  'badminton',
  'tennis',
  'custom',
];

/// Các cảnh overlay.
const List<String> scoreboardScenes = [
  'scorebar',
  'full',
  'intro',
  'result',
  'hidden',
];

const List<String> scoreboardThemes = ['dark', 'light', 'glass'];
const List<String> scoreboardPositions = ['tl', 'tr', 'bl', 'br', 'tc', 'bc'];

String scoreboardOtherTeam(String team) => team == 'A' ? 'B' : 'A';

final RegExp _colorPattern = RegExp(r'^#[0-9a-fA-F]{6}$');

String _cleanText(Object? value, {required int maxLength, String fallback = ''}) {
  if (value == null) return fallback;
  final text = value
      .toString()
      .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ')
      .trim();
  if (text.length <= maxLength) return text;
  return text.substring(0, maxLength);
}

String _cleanColor(Object? value, String fallback) {
  final text = value?.toString().trim() ?? '';
  return _colorPattern.hasMatch(text) ? text.toUpperCase() : fallback;
}

int _readInt(Object? value, int fallback) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? fallback;
  return fallback;
}

int? _readNullableInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

bool _readBool(Object? value, bool fallback) {
  if (value is bool) return value;
  if (value is String) {
    final lower = value.toLowerCase();
    if (lower == 'true' || lower == '1') return true;
    if (lower == 'false' || lower == '0') return false;
  }
  if (value is num) return value != 0;
  return fallback;
}

Map<String, dynamic> _readMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  return <String, dynamic>{};
}

String _readTeam(Object? value, {bool allowNone = false}) {
  final text = value?.toString().trim().toUpperCase() ?? '';
  if (text == 'A' || text == 'B') return text;
  if (allowNone && (text == 'NONE' || text.isEmpty)) return 'none';
  throw ScoreboardException(422, 'invalid_team', 'Đội phải là "A" hoặc "B".');
}

// ============================================================
// RULES
// ============================================================

class ScoreRules {
  /// Số điểm để thắng một set (không dùng cho tennis).
  final int pointsToWin;

  /// Phải thắng cách bao nhiêu điểm.
  final int winBy;

  /// Điểm trần: chạm mức này là thắng set dù chưa cách 2 (cầu lông = 30).
  final int? cap;

  /// Số set tối đa (1, 3, 5, 7). Thắng khi đạt quá nửa.
  final int bestOf;

  /// 'sideout' (chỉ đội giao được điểm) hoặc 'rally' (pha nào cũng có điểm).
  final String scoring;

  /// Đánh đôi: pickleball side-out có người giao 1/2.
  final bool doubles;

  /// Tennis: số game để thắng set.
  final int gamesPerSet;

  /// Tennis: tie-break khi hai bên cùng đạt số game này.
  final int tiebreakAt;

  /// Tennis: số điểm để thắng tie-break (cách 2).
  final int tiebreakPoints;

  const ScoreRules({
    required this.pointsToWin,
    required this.winBy,
    required this.cap,
    required this.bestOf,
    required this.scoring,
    required this.doubles,
    required this.gamesPerSet,
    required this.tiebreakAt,
    required this.tiebreakPoints,
  });

  factory ScoreRules.preset(String sport) {
    switch (sport) {
      case 'pickleball':
        return const ScoreRules(
          pointsToWin: 11,
          winBy: 2,
          cap: null,
          bestOf: 3,
          scoring: 'sideout',
          doubles: true,
          gamesPerSet: 6,
          tiebreakAt: 6,
          tiebreakPoints: 7,
        );
      case 'badminton':
        return const ScoreRules(
          pointsToWin: 21,
          winBy: 2,
          cap: 30,
          bestOf: 3,
          scoring: 'rally',
          doubles: false,
          gamesPerSet: 6,
          tiebreakAt: 6,
          tiebreakPoints: 7,
        );
      case 'tennis':
        return const ScoreRules(
          pointsToWin: 4,
          winBy: 2,
          cap: null,
          bestOf: 3,
          scoring: 'rally',
          doubles: false,
          gamesPerSet: 6,
          tiebreakAt: 6,
          tiebreakPoints: 7,
        );
      default:
        return const ScoreRules(
          pointsToWin: 25,
          winBy: 2,
          cap: null,
          bestOf: 3,
          scoring: 'rally',
          doubles: false,
          gamesPerSet: 6,
          tiebreakAt: 6,
          tiebreakPoints: 7,
        );
    }
  }

  /// Ghép các trường trong [json] lên [base], kiểm tra giới hạn. Ném
  /// [ScoreboardException] nếu giá trị không hợp lệ.
  factory ScoreRules.merge(ScoreRules base, Map<String, dynamic> json) {
    final pointsToWin = _readInt(json['pointsToWin'], base.pointsToWin);
    final winBy = _readInt(json['winBy'], base.winBy);
    final cap = json.containsKey('cap')
        ? _readNullableInt(json['cap'])
        : base.cap;
    final bestOf = _readInt(json['bestOf'], base.bestOf);
    final scoring = json['scoring']?.toString() ?? base.scoring;
    final doubles = _readBool(json['doubles'], base.doubles);
    final gamesPerSet = _readInt(json['gamesPerSet'], base.gamesPerSet);
    final tiebreakAt = _readInt(json['tiebreakAt'], base.tiebreakAt);
    final tiebreakPoints = _readInt(json['tiebreakPoints'], base.tiebreakPoints);

    void check(bool ok, String message) {
      if (!ok) throw ScoreboardException(422, 'invalid_rules', message);
    }

    check(pointsToWin >= 1 && pointsToWin <= 99, 'Điểm thắng set phải từ 1 đến 99.');
    check(winBy >= 1 && winBy <= 5, 'Cách biệt phải từ 1 đến 5.');
    check(
      cap == null || (cap >= pointsToWin && cap <= 199),
      'Điểm trần phải lớn hơn hoặc bằng điểm thắng set.',
    );
    check(const [1, 3, 5, 7].contains(bestOf), 'Số set phải là 1, 3, 5 hoặc 7.');
    check(scoring == 'sideout' || scoring == 'rally', 'Cách tính điểm không hợp lệ.');
    check(gamesPerSet >= 1 && gamesPerSet <= 10, 'Số game mỗi set phải từ 1 đến 10.');
    check(
      tiebreakAt >= 1 && tiebreakAt <= gamesPerSet,
      'Mốc tie-break phải từ 1 đến số game mỗi set.',
    );
    check(tiebreakPoints >= 1 && tiebreakPoints <= 20, 'Điểm tie-break phải từ 1 đến 20.');

    return ScoreRules(
      pointsToWin: pointsToWin,
      winBy: winBy,
      cap: cap,
      bestOf: bestOf,
      scoring: scoring,
      doubles: doubles,
      gamesPerSet: gamesPerSet,
      tiebreakAt: tiebreakAt,
      tiebreakPoints: tiebreakPoints,
    );
  }

  int get setsToWin => bestOf ~/ 2 + 1;

  Map<String, dynamic> toJson() => {
    'pointsToWin': pointsToWin,
    'winBy': winBy,
    'cap': cap,
    'bestOf': bestOf,
    'scoring': scoring,
    'doubles': doubles,
    'gamesPerSet': gamesPerSet,
    'tiebreakAt': tiebreakAt,
    'tiebreakPoints': tiebreakPoints,
  };
}

// ============================================================
// TEAM / MATCH / OVERLAY / TIMER
// ============================================================

class ScoreTeam {
  String name;
  String short;
  String color;
  List<String> players;
  String? logoId;

  ScoreTeam({
    required this.name,
    required this.short,
    required this.color,
    List<String>? players,
    this.logoId,
  }) : players = players ?? <String>[];

  factory ScoreTeam.initial(String team) => team == 'A'
      ? ScoreTeam(name: 'Đội A', short: 'A', color: '#1565C0')
      : ScoreTeam(name: 'Đội B', short: 'B', color: '#C62828');

  factory ScoreTeam.fromJson(Object? value, String team) {
    final base = ScoreTeam.initial(team);
    final json = _readMap(value);
    final players = json['players'];
    final logo = json['logoId']?.toString();
    return ScoreTeam(
      name: _cleanText(json['name'], maxLength: 40, fallback: base.name),
      short: _cleanText(json['short'], maxLength: 6, fallback: base.short),
      color: _cleanColor(json['color'], base.color),
      players: players is List
          ? players
                .map((item) => _cleanText(item, maxLength: 40))
                .where((item) => item.isNotEmpty)
                .take(2)
                .toList()
          : <String>[],
      logoId: logo != null && isValidScoreboardLogoId(logo) ? logo : null,
    );
  }

  /// Áp các trường có trong [json]; trường vắng mặt giữ nguyên.
  void patch(Map<String, dynamic> json) {
    if (json.containsKey('name')) {
      final value = _cleanText(json['name'], maxLength: 40);
      if (value.isEmpty) {
        throw const ScoreboardException(422, 'invalid_name', 'Tên đội không được để trống.');
      }
      name = value;
    }
    if (json.containsKey('short')) {
      final value = _cleanText(json['short'], maxLength: 6);
      short = value.isEmpty ? (name.isEmpty ? '?' : name.substring(0, 1)) : value;
    }
    if (json.containsKey('color')) {
      final value = json['color']?.toString().trim() ?? '';
      if (!_colorPattern.hasMatch(value)) {
        throw const ScoreboardException(422, 'invalid_color', 'Màu phải có dạng #RRGGBB.');
      }
      color = value.toUpperCase();
    }
    if (json.containsKey('players')) {
      final value = json['players'];
      if (value is! List) {
        throw const ScoreboardException(422, 'invalid_players', 'Danh sách VĐV không hợp lệ.');
      }
      players = value
          .map((item) => _cleanText(item, maxLength: 40))
          .where((item) => item.isNotEmpty)
          .take(2)
          .toList();
    }
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'short': short,
    'color': color,
    'players': List<String>.from(players),
    'logoId': logoId,
  };
}

bool isValidScoreboardLogoId(String id) =>
    RegExp(r'^[AB]_\d{1,16}\.(png|jpg|webp)$').hasMatch(id);

class ScoreMatchInfo {
  String tournament;
  String round;
  String court;

  ScoreMatchInfo({this.tournament = '', this.round = '', this.court = ''});

  factory ScoreMatchInfo.fromJson(Object? value) {
    final json = _readMap(value);
    return ScoreMatchInfo(
      tournament: _cleanText(json['tournament'], maxLength: 60),
      round: _cleanText(json['round'], maxLength: 40),
      court: _cleanText(json['court'], maxLength: 30),
    );
  }

  void patch(Map<String, dynamic> json) {
    if (json.containsKey('tournament')) {
      tournament = _cleanText(json['tournament'], maxLength: 60);
    }
    if (json.containsKey('round')) {
      round = _cleanText(json['round'], maxLength: 40);
    }
    if (json.containsKey('court')) {
      court = _cleanText(json['court'], maxLength: 30);
    }
  }

  Map<String, dynamic> toJson() => {
    'tournament': tournament,
    'round': round,
    'court': court,
  };
}

class ScoreOverlayConfig {
  String scene;
  String theme;
  String accent;
  String position;
  double scale;
  bool showSets;
  bool showServe;
  bool showTournament;
  bool showTimer;

  /// In bảng tỉ số thẳng vào video livestream RTMP/RTSP (Android).
  bool burnIn;

  /// Hiện/ẩn toàn bộ overlay (bảng tỉ số, thông báo, chữ chạy) mà vẫn giữ
  /// nguyên cảnh và cấu hình. Ẩn không làm gián đoạn livestream. Mặc định
  /// ẩn: người vận hành bật trong Hub (khi đó mới hiện mã QR điều khiển).
  bool visible;
  bool tickerEnabled;
  String tickerText;
  int tickerSpeed;
  String bannerText;

  /// 0 = hiện tới khi xoá; >0 = thời điểm (ms, giờ server) tự ẩn.
  int bannerUntilMs;

  ScoreOverlayConfig({
    this.scene = 'scorebar',
    this.theme = 'dark',
    this.accent = '#FFC107',
    this.position = 'tl',
    this.scale = 1.0,
    this.showSets = true,
    this.showServe = true,
    this.showTournament = true,
    this.showTimer = false,
    this.burnIn = true,
    this.visible = false,
    this.tickerEnabled = false,
    this.tickerText = '',
    this.tickerSpeed = 2,
    this.bannerText = '',
    this.bannerUntilMs = 0,
  });

  factory ScoreOverlayConfig.fromJson(Object? value) {
    final json = _readMap(value);
    final config = ScoreOverlayConfig();
    try {
      config.patch(json);
    } on ScoreboardException {
      // Dữ liệu lưu cũ/hỏng: dùng mặc định.
      return ScoreOverlayConfig();
    }
    final banner = _readMap(json['banner']);
    config.bannerText = _cleanText(banner['text'], maxLength: 80);
    config.bannerUntilMs = math.max(0, _readInt(banner['untilMs'], 0));
    return config;
  }

  void patch(Map<String, dynamic> json) {
    void fail(String message) =>
        throw ScoreboardException(422, 'invalid_overlay', message);

    if (json.containsKey('scene')) {
      final value = json['scene']?.toString() ?? '';
      if (!scoreboardScenes.contains(value)) fail('Cảnh overlay không hợp lệ.');
      scene = value;
    }
    if (json.containsKey('theme')) {
      final value = json['theme']?.toString() ?? '';
      if (!scoreboardThemes.contains(value)) fail('Giao diện không hợp lệ.');
      theme = value;
    }
    if (json.containsKey('accent')) {
      final value = json['accent']?.toString().trim() ?? '';
      if (!_colorPattern.hasMatch(value)) fail('Màu nhấn phải có dạng #RRGGBB.');
      accent = value.toUpperCase();
    }
    if (json.containsKey('position')) {
      final value = json['position']?.toString() ?? '';
      if (!scoreboardPositions.contains(value)) fail('Vị trí không hợp lệ.');
      position = value;
    }
    if (json.containsKey('scale')) {
      final raw = json['scale'];
      final value = raw is num ? raw.toDouble() : double.tryParse('$raw');
      if (value == null || value.isNaN || value < 0.5 || value > 2.0) {
        fail('Kích thước phải từ 0.5 đến 2.');
      }
      scale = (value! * 100).roundToDouble() / 100;
    }
    final show = json['show'];
    if (show != null) {
      final map = _readMap(show);
      showSets = _readBool(map['sets'], showSets);
      showServe = _readBool(map['serve'], showServe);
      showTournament = _readBool(map['tournament'], showTournament);
      showTimer = _readBool(map['timer'], showTimer);
    }
    if (json.containsKey('burnIn')) {
      burnIn = _readBool(json['burnIn'], burnIn);
    }
    if (json.containsKey('visible')) {
      visible = _readBool(json['visible'], visible);
    }
    final ticker = json['ticker'];
    if (ticker != null) {
      final map = _readMap(ticker);
      tickerEnabled = _readBool(map['enabled'], tickerEnabled);
      if (map.containsKey('text')) {
        tickerText = _cleanText(map['text'], maxLength: 200);
      }
      if (map.containsKey('speed')) {
        tickerSpeed = _readInt(map['speed'], tickerSpeed).clamp(1, 3);
      }
    }
  }

  Map<String, dynamic> toJson() => {
    'scene': scene,
    'theme': theme,
    'accent': accent,
    'position': position,
    'scale': scale,
    'burnIn': burnIn,
    'visible': visible,
    'show': {
      'sets': showSets,
      'serve': showServe,
      'tournament': showTournament,
      'timer': showTimer,
    },
    'ticker': {
      'enabled': tickerEnabled,
      'text': tickerText,
      'speed': tickerSpeed,
    },
    'banner': {'text': bannerText, 'untilMs': bannerUntilMs},
  };
}

class ScoreMatchTimer {
  bool running;
  int startedAtMs;
  int accumulatedMs;

  ScoreMatchTimer({
    this.running = false,
    this.startedAtMs = 0,
    this.accumulatedMs = 0,
  });

  factory ScoreMatchTimer.fromJson(Object? value) {
    final json = _readMap(value);
    return ScoreMatchTimer(
      running: _readBool(json['running'], false),
      startedAtMs: math.max(0, _readInt(json['startedAtMs'], 0)),
      accumulatedMs: math.max(0, _readInt(json['accumulatedMs'], 0)),
    );
  }

  int elapsedMs(int nowMs) =>
      accumulatedMs + (running ? math.max(0, nowMs - startedAtMs) : 0);

  void start(int nowMs) {
    if (running) return;
    running = true;
    startedAtMs = nowMs;
  }

  void pause(int nowMs) {
    if (!running) return;
    accumulatedMs = elapsedMs(nowMs);
    running = false;
    startedAtMs = 0;
  }

  void reset() {
    running = false;
    startedAtMs = 0;
    accumulatedMs = 0;
  }

  Map<String, dynamic> toJson() => {
    'running': running,
    'startedAtMs': startedAtMs,
    'accumulatedMs': accumulatedMs,
  };
}

// ============================================================
// SCORE CORE (phần được hoàn tác)
// ============================================================

class SetScore {
  final int a;
  final int b;

  /// Điểm tie-break (tennis), null nếu set không có tie-break.
  final int? tbA;
  final int? tbB;

  const SetScore(this.a, this.b, {this.tbA, this.tbB});

  factory SetScore.fromJson(Object? value) {
    final json = _readMap(value);
    return SetScore(
      math.max(0, _readInt(json['a'], 0)),
      math.max(0, _readInt(json['b'], 0)),
      tbA: _readNullableInt(json['tbA']),
      tbB: _readNullableInt(json['tbB']),
    );
  }

  Map<String, dynamic> toJson() => {
    'a': a,
    'b': b,
    if (tbA != null) 'tbA': tbA,
    if (tbB != null) 'tbB': tbB,
  };
}

class ScoreCore {
  String sport;
  ScoreRules rules;
  int pointsA;
  int pointsB;
  int gamesA;
  int gamesB;
  List<SetScore> sets;
  int setsWonA;
  int setsWonB;

  /// 'A' | 'B' | 'none'
  String serving;

  /// Pickleball đánh đôi side-out: người giao 1 hoặc 2.
  int serverNumber;

  /// Đội giao đầu set hiện tại (để xác định đội giao đầu set sau).
  String setFirstServer;
  bool tiebreak;
  String? tiebreakFirstServer;
  bool sidesSwapped;

  /// 'playing' | 'finished'
  String status;
  String? winner;

  ScoreCore({
    required this.sport,
    required this.rules,
    this.pointsA = 0,
    this.pointsB = 0,
    this.gamesA = 0,
    this.gamesB = 0,
    List<SetScore>? sets,
    this.setsWonA = 0,
    this.setsWonB = 0,
    this.serving = 'A',
    this.serverNumber = 1,
    this.setFirstServer = 'A',
    this.tiebreak = false,
    this.tiebreakFirstServer,
    this.sidesSwapped = false,
    this.status = 'playing',
    this.winner,
  }) : sets = sets ?? <SetScore>[];

  factory ScoreCore.initial(String sport, ScoreRules rules) {
    return ScoreCore(
      sport: sport,
      rules: rules,
      serving: 'A',
      setFirstServer: 'A',
      serverNumber: _startingServerNumber(sport, rules),
    );
  }

  static int _startingServerNumber(String sport, ScoreRules rules) =>
      rules.scoring == 'sideout' && rules.doubles && sport != 'tennis' ? 2 : 1;

  factory ScoreCore.fromJson(Map<String, dynamic> json) {
    final sportValue = json['sport']?.toString() ?? 'pickleball';
    final sport = scoreboardSports.contains(sportValue) ? sportValue : 'pickleball';
    ScoreRules rules;
    try {
      rules = ScoreRules.merge(ScoreRules.preset(sport), _readMap(json['rules']));
    } on ScoreboardException {
      rules = ScoreRules.preset(sport);
    }
    final points = _readMap(json['points']);
    final games = _readMap(json['games']);
    final setsWon = _readMap(json['setsWon']);
    final setsJson = json['sets'];
    String team(Object? value, String fallback) {
      final text = value?.toString() ?? '';
      return text == 'A' || text == 'B' || text == 'none' ? text : fallback;
    }

    final winnerValue = json['winner']?.toString();
    final tbFirst = json['tiebreakFirstServer']?.toString();
    return ScoreCore(
      sport: sport,
      rules: rules,
      pointsA: math.max(0, _readInt(points['a'], 0)),
      pointsB: math.max(0, _readInt(points['b'], 0)),
      gamesA: math.max(0, _readInt(games['a'], 0)),
      gamesB: math.max(0, _readInt(games['b'], 0)),
      sets: setsJson is List
          ? setsJson.take(9).map(SetScore.fromJson).toList()
          : <SetScore>[],
      setsWonA: math.max(0, _readInt(setsWon['a'], 0)),
      setsWonB: math.max(0, _readInt(setsWon['b'], 0)),
      serving: team(json['serving'], 'A'),
      serverNumber: _readInt(json['serverNumber'], 1) == 2 ? 2 : 1,
      setFirstServer: team(json['setFirstServer'], 'A'),
      tiebreak: _readBool(json['tiebreak'], false),
      tiebreakFirstServer: tbFirst == 'A' || tbFirst == 'B' ? tbFirst : null,
      sidesSwapped: _readBool(json['sidesSwapped'], false),
      status: json['status'] == 'finished' ? 'finished' : 'playing',
      winner: winnerValue == 'A' || winnerValue == 'B' ? winnerValue : null,
    );
  }

  ScoreCore copy() => ScoreCore(
    sport: sport,
    rules: rules,
    pointsA: pointsA,
    pointsB: pointsB,
    gamesA: gamesA,
    gamesB: gamesB,
    sets: List<SetScore>.from(sets),
    setsWonA: setsWonA,
    setsWonB: setsWonB,
    serving: serving,
    serverNumber: serverNumber,
    setFirstServer: setFirstServer,
    tiebreak: tiebreak,
    tiebreakFirstServer: tiebreakFirstServer,
    sidesSwapped: sidesSwapped,
    status: status,
    winner: winner,
  );

  bool get isTennis => sport == 'tennis';
  bool get finished => status == 'finished';

  /// Chưa có điểm nào trong trận.
  bool get isPristine =>
      pointsA == 0 &&
      pointsB == 0 &&
      gamesA == 0 &&
      gamesB == 0 &&
      sets.isEmpty &&
      setsWonA == 0 &&
      setsWonB == 0 &&
      status == 'playing';

  int currentSetNumber() {
    if (finished) return math.max(1, sets.length);
    return math.min(sets.length + 1, rules.bestOf);
  }

  int _points(String team) => team == 'A' ? pointsA : pointsB;

  void _setPoints(String team, int value) {
    if (team == 'A') {
      pointsA = value;
    } else {
      pointsB = value;
    }
  }

  int _games(String team) => team == 'A' ? gamesA : gamesB;

  void _setGames(String team, int value) {
    if (team == 'A') {
      gamesA = value;
    } else {
      gamesB = value;
    }
  }

  void _ensurePlaying() {
    if (finished) {
      throw const ScoreboardException(
        409,
        'match_finished',
        'Trận đã kết thúc. Bấm "Trận mới" để bắt đầu lại.',
      );
    }
  }

  // ----------------------------------------------------------
  // POINT: [team] thắng pha bóng.
  // ----------------------------------------------------------

  void winRally(String team) {
    _ensurePlaying();
    if (isTennis) {
      _tennisPoint(team, switchServeInTiebreak: true);
      return;
    }
    if (rules.scoring == 'sideout' && serving != 'none') {
      if (team == serving) {
        _setPoints(team, _points(team) + 1);
        _checkSetEnd();
      } else if (rules.doubles && serverNumber == 1) {
        serverNumber = 2;
      } else {
        serving = team;
        serverNumber = 1;
      }
      return;
    }
    // Rally scoring (hoặc side-out khi chưa xác định đội giao).
    _setPoints(team, _points(team) + 1);
    if (serving != 'none' || rules.scoring == 'rally') {
      serving = team;
      serverNumber = 1;
    }
    _checkSetEnd();
  }

  /// Sửa điểm thủ công. Cộng điểm vẫn kiểm tra hết set/game; trừ điểm thì
  /// không bao giờ làm đổi set.
  void adjust(String team, int delta) {
    if (delta == 0 || delta.abs() > 5) {
      throw const ScoreboardException(422, 'invalid_delta', 'Số điểm sửa phải từ -5 đến 5.');
    }
    if (delta > 0) {
      _ensurePlaying();
      for (var i = 0; i < delta && !finished; i++) {
        final setsBefore = sets.length;
        if (isTennis) {
          _tennisPoint(team, switchServeInTiebreak: false);
        } else {
          _setPoints(team, _points(team) + 1);
          _checkSetEnd();
        }
        if (sets.length != setsBefore) break;
      }
      return;
    }
    _setPoints(team, math.max(0, _points(team) + delta));
    if (isTennis && !tiebreak) {
      // Giữ tỉ số game hợp lệ: bỏ lợi thế khi đối thủ không còn ở 40.
      if (pointsA >= 4 && pointsB <= 2) pointsA = 3;
      if (pointsB >= 4 && pointsA <= 2) pointsB = 3;
    }
  }

  /// Ghi đè điểm/set trực tiếp (tích hợp tablet). Không áp luật.
  void overwrite(Map<String, dynamic> json) {
    int? value(String key) {
      if (!json.containsKey(key)) return null;
      final parsed = _readNullableInt(json[key]);
      if (parsed == null || parsed < 0 || parsed > 999) {
        throw ScoreboardException(422, 'invalid_score', 'Giá trị "$key" không hợp lệ.');
      }
      return parsed;
    }

    final scoreA = value('scoreA');
    final scoreB = value('scoreB');
    final setsA = value('setsA');
    final setsB = value('setsB');
    final gamesAValue = value('gamesA');
    final gamesBValue = value('gamesB');
    if (scoreA != null) pointsA = scoreA;
    if (scoreB != null) pointsB = scoreB;
    if (gamesAValue != null) gamesA = gamesAValue;
    if (gamesBValue != null) gamesB = gamesBValue;
    if (setsA != null) setsWonA = math.min(setsA, 9);
    if (setsB != null) setsWonB = math.min(setsB, 9);
    if (json.containsKey('serving')) {
      serving = _readTeam(json['serving'], allowNone: true);
    }
    if (isTennis) {
      final atTiebreak =
          gamesA == rules.tiebreakAt && gamesB == rules.tiebreakAt;
      if (atTiebreak && !tiebreak) {
        tiebreakFirstServer = serving == 'none' ? null : serving;
      }
      tiebreak = atTiebreak;
      if (!atTiebreak) tiebreakFirstServer = null;
    }
    if (json.containsKey('matchFinished')) {
      final done = _readBool(json['matchFinished'], false);
      if (done) {
        status = 'finished';
        winner = setsWonA == setsWonB ? null : (setsWonA > setsWonB ? 'A' : 'B');
      } else {
        status = 'playing';
        winner = null;
      }
    }
  }

  void setServe(String team, int? number) {
    final changedTeam = team != serving;
    serving = team;
    if (team == 'none') {
      serverNumber = 1;
    } else if (number != null) {
      if (number != 1 && number != 2) {
        throw const ScoreboardException(422, 'invalid_server', 'Người giao phải là 1 hoặc 2.');
      }
      serverNumber = number;
    } else if (changedTeam) {
      serverNumber = 1;
    }
    if (pointsA == 0 && pointsB == 0 && gamesA == 0 && gamesB == 0 && team != 'none') {
      setFirstServer = team;
    }
    if (tiebreak && pointsA == 0 && pointsB == 0 && team != 'none') {
      tiebreakFirstServer = team;
    }
  }

  /// Kết thúc set hiện tại theo tỉ số đang có (đội cao điểm hơn thắng).
  void endSet() {
    _ensurePlaying();
    if (isTennis) {
      var winnerTeam = gamesA == gamesB
          ? null
          : (gamesA > gamesB ? 'A' : 'B');
      if (winnerTeam == null && tiebreak && pointsA != pointsB) {
        winnerTeam = pointsA > pointsB ? 'A' : 'B';
      }
      if (winnerTeam == null) {
        throw const ScoreboardException(
          422,
          'set_tied',
          'Hai đội đang hoà, chưa thể kết thúc set.',
        );
      }
      final usedTiebreak = tiebreak;
      if (usedTiebreak && gamesA == gamesB) {
        // Thắng tie-break = thắng thêm một game (ví dụ 7-6).
        _setGames(winnerTeam, _games(winnerTeam) + 1);
      }
      _completeSet(
        winnerTeam,
        SetScore(
          gamesA,
          gamesB,
          tbA: usedTiebreak ? pointsA : null,
          tbB: usedTiebreak ? pointsB : null,
        ),
        afterTiebreak: usedTiebreak,
      );
      return;
    }
    if (pointsA == pointsB) {
      throw const ScoreboardException(
        422,
        'set_tied',
        'Hai đội đang hoà, chưa thể kết thúc set.',
      );
    }
    _completeSet(pointsA > pointsB ? 'A' : 'B', SetScore(pointsA, pointsB));
  }

  void finishMatch() {
    status = 'finished';
    winner = setsWonA == setsWonB ? null : (setsWonA > setsWonB ? 'A' : 'B');
  }

  // ----------------------------------------------------------
  // INTERNAL
  // ----------------------------------------------------------

  void _checkSetEnd() {
    final target = rules.pointsToWin;
    String? winnerTeam;
    final cap = rules.cap;
    if (cap != null && (pointsA >= cap || pointsB >= cap) && pointsA != pointsB) {
      winnerTeam = pointsA > pointsB ? 'A' : 'B';
    } else if (pointsA >= target && pointsA - pointsB >= rules.winBy) {
      winnerTeam = 'A';
    } else if (pointsB >= target && pointsB - pointsA >= rules.winBy) {
      winnerTeam = 'B';
    }
    if (winnerTeam != null) {
      _completeSet(winnerTeam, SetScore(pointsA, pointsB));
    }
  }

  void _tennisPoint(String team, {required bool switchServeInTiebreak}) {
    final other = scoreboardOtherTeam(team);
    if (tiebreak) {
      _setPoints(team, _points(team) + 1);
      final mine = _points(team);
      final theirs = _points(other);
      if (mine >= rules.tiebreakPoints && mine - theirs >= 2) {
        _setGames(team, _games(team) + 1);
        _completeSet(
          team,
          SetScore(gamesA, gamesB, tbA: pointsA, tbB: pointsB),
          afterTiebreak: true,
        );
        return;
      }
      // Tie-break: đổi giao sau điểm 1, rồi mỗi 2 điểm (sau điểm 3, 5, ...).
      if (switchServeInTiebreak &&
          serving != 'none' &&
          (pointsA + pointsB).isOdd) {
        serving = scoreboardOtherTeam(serving);
      }
      return;
    }

    _setPoints(team, _points(team) + 1);
    final mine = _points(team);
    final theirs = _points(other);
    if (mine >= 4 && mine - theirs >= 2) {
      _winTennisGame(team);
      return;
    }
    // Deuce kéo dài: giữ giá trị nhỏ (40-40 = 3-3, AD = 4-3).
    if (pointsA >= 4 && pointsB >= 4) {
      pointsA -= 1;
      pointsB -= 1;
    }
  }

  void _winTennisGame(String team) {
    final other = scoreboardOtherTeam(team);
    _setGames(team, _games(team) + 1);
    pointsA = 0;
    pointsB = 0;
    if (serving != 'none') serving = scoreboardOtherTeam(serving);
    final mine = _games(team);
    final theirs = _games(other);
    if (mine >= rules.gamesPerSet && mine - theirs >= 2) {
      _completeSet(team, SetScore(gamesA, gamesB));
      return;
    }
    if (gamesA == rules.tiebreakAt && gamesB == rules.tiebreakAt) {
      tiebreak = true;
      tiebreakFirstServer = serving == 'none' ? null : serving;
    }
  }

  void _completeSet(
    String team,
    SetScore score, {
    bool afterTiebreak = false,
  }) {
    sets.add(score);
    if (team == 'A') {
      setsWonA += 1;
    } else {
      setsWonB += 1;
    }
    final tbFirst = tiebreakFirstServer;
    pointsA = 0;
    pointsB = 0;
    gamesA = 0;
    gamesB = 0;
    tiebreak = false;
    tiebreakFirstServer = null;

    final won = team == 'A' ? setsWonA : setsWonB;
    if (won >= rules.setsToWin) {
      status = 'finished';
      winner = team;
      return;
    }

    // Đội giao đầu set kế tiếp.
    if (isTennis) {
      if (afterTiebreak && tbFirst != null) {
        serving = scoreboardOtherTeam(tbFirst);
      }
      // Set thường: giao đã được luân phiên sau game cuối.
    } else if (rules.scoring == 'sideout') {
      // Pickleball: đổi đội giao đầu set.
      final previousFirst = setFirstServer == 'none' ? serving : setFirstServer;
      serving = previousFirst == 'none' ? team : scoreboardOtherTeam(previousFirst);
    } else {
      // Cầu lông / rally: đội thắng set giao trước ở set sau.
      serving = team;
    }
    serverNumber = _startingServerNumber(sport, rules);
    if (serving != 'none') setFirstServer = serving;
  }

  // ----------------------------------------------------------
  // DISPLAY
  // ----------------------------------------------------------

  Map<String, dynamic> display() {
    if (isTennis) {
      if (tiebreak) {
        return {
          'a': '$pointsA',
          'b': '$pointsB',
          'callout': 'TIE-BREAK $pointsA-$pointsB',
          'kind': 'tiebreak',
        };
      }
      const labels = ['0', '15', '30', '40'];
      if (pointsA >= 3 && pointsB >= 3) {
        if (pointsA == pointsB) {
          return {'a': '40', 'b': '40', 'callout': 'DEUCE', 'kind': 'deuce'};
        }
        final ahead = pointsA > pointsB ? 'A' : 'B';
        return {
          'a': ahead == 'A' ? 'AD' : '40',
          'b': ahead == 'B' ? 'AD' : '40',
          'callout': 'AD $ahead',
          'kind': 'advantage',
          'advantage': ahead,
        };
      }
      final a = labels[math.min(pointsA, 3)];
      final b = labels[math.min(pointsB, 3)];
      return {'a': a, 'b': b, 'callout': '$a-$b', 'kind': 'game'};
    }
    if (rules.scoring == 'sideout' && serving != 'none') {
      final servingScore = serving == 'A' ? pointsA : pointsB;
      final receivingScore = serving == 'A' ? pointsB : pointsA;
      final callout = rules.doubles
          ? '$servingScore-$receivingScore-$serverNumber'
          : '$servingScore-$receivingScore';
      return {
        'a': '$pointsA',
        'b': '$pointsB',
        'callout': callout,
        'kind': 'sideout',
      };
    }
    return {
      'a': '$pointsA',
      'b': '$pointsB',
      'callout': '$pointsA-$pointsB',
      'kind': 'rally',
    };
  }
}

// ============================================================
// FULL STATE
// ============================================================

class ScoreboardState {
  int rev;
  String matchId;
  int updatedAtMs;
  ScoreCore core;
  ScoreTeam teamA;
  ScoreTeam teamB;
  ScoreMatchInfo match;
  ScoreOverlayConfig overlay;
  ScoreMatchTimer timer;

  ScoreboardState({
    required this.rev,
    required this.matchId,
    required this.updatedAtMs,
    required this.core,
    required this.teamA,
    required this.teamB,
    required this.match,
    required this.overlay,
    required this.timer,
  });

  factory ScoreboardState.initial({required int nowMs, String sport = 'pickleball'}) {
    return ScoreboardState(
      rev: 0,
      matchId: scoreboardMatchId(nowMs),
      updatedAtMs: nowMs,
      core: ScoreCore.initial(sport, ScoreRules.preset(sport)),
      teamA: ScoreTeam.initial('A'),
      teamB: ScoreTeam.initial('B'),
      match: ScoreMatchInfo(),
      overlay: ScoreOverlayConfig(),
      timer: ScoreMatchTimer(),
    );
  }

  factory ScoreboardState.fromJson(Map<String, dynamic> json, {required int nowMs}) {
    final matchIdValue = _cleanText(json['matchId'], maxLength: 40);
    return ScoreboardState(
      rev: math.max(0, _readInt(json['rev'], 0)),
      matchId: matchIdValue.isEmpty ? scoreboardMatchId(nowMs) : matchIdValue,
      updatedAtMs: math.max(0, _readInt(json['updatedAt'], nowMs)),
      core: ScoreCore.fromJson(json),
      teamA: ScoreTeam.fromJson(json['teamA'], 'A'),
      teamB: ScoreTeam.fromJson(json['teamB'], 'B'),
      match: ScoreMatchInfo.fromJson(json['match']),
      overlay: ScoreOverlayConfig.fromJson(json['overlay']),
      timer: ScoreMatchTimer.fromJson(json['timer']),
    );
  }

  ScoreTeam team(String id) => id == 'A' ? teamA : teamB;

  /// JSON đầy đủ gửi cho trang web/overlay/tablet và dùng để lưu.
  Map<String, dynamic> toJson({required int nowMs, String? epoch}) {
    final display = core.display();
    return {
      'v': 1,
      'rev': rev,
      'epoch': ?epoch,
      'matchId': matchId,
      'updatedAt': updatedAtMs,
      'serverNowMs': nowMs,
      'sport': core.sport,
      'rules': core.rules.toJson(),
      'teamA': teamA.toJson(),
      'teamB': teamB.toJson(),
      'match': match.toJson(),
      'points': {'a': core.pointsA, 'b': core.pointsB},
      'games': {'a': core.gamesA, 'b': core.gamesB},
      'sets': core.sets.map((set) => set.toJson()).toList(),
      'setsWon': {'a': core.setsWonA, 'b': core.setsWonB},
      'currentSet': core.currentSetNumber(),
      'serving': core.serving,
      'serverNumber': core.serverNumber,
      'setFirstServer': core.setFirstServer,
      'tiebreak': core.tiebreak,
      'tiebreakFirstServer': core.tiebreakFirstServer,
      'sidesSwapped': core.sidesSwapped,
      'status': core.status,
      'winner': core.winner,
      'overlay': overlay.toJson(),
      'timer': {...timer.toJson(), 'elapsedMs': timer.elapsedMs(nowMs)},
      'display': display,
      // Trường phẳng tương thích bản đặc tả đầu tiên / tablet CheckVAR.
      'teamAName': teamA.name,
      'teamBName': teamB.name,
      'scoreA': core.pointsA,
      'scoreB': core.pointsB,
      'setsA': core.setsWonA,
      'setsB': core.setsWonB,
      'matchFinished': core.finished,
    };
  }
}

String scoreboardMatchId(int nowMs) {
  final time = DateTime.fromMillisecondsSinceEpoch(nowMs);
  String two(int value) => value.toString().padLeft(2, '0');
  return 'M-${time.year}${two(time.month)}${two(time.day)}-'
      '${two(time.hour)}${two(time.minute)}${two(time.second)}';
}

/// Loại thay đổi do một lệnh gây ra.
enum ScoreboardChange {
  /// Thay đổi điểm/luật: được ghi vào lịch sử hoàn tác.
  score,

  /// Thay đổi tên, thông tin, overlay, đồng hồ: không hoàn tác.
  meta,
}

/// Áp một lệnh lên [state]. Trả về loại thay đổi để service quyết định có
/// lưu bản hoàn tác hay không. Lệnh "undo" do service xử lý.
ScoreboardChange applyScoreboardAction(
  ScoreboardState state,
  Map<String, dynamic> action, {
  required int nowMs,
}) {
  final name = action['action']?.toString() ?? '';
  final core = state.core;
  switch (name) {
    case 'point':
      core.winRally(_readTeam(action['team']));
      return ScoreboardChange.score;
    case 'adjust':
      core.adjust(_readTeam(action['team']), _readInt(action['delta'], 0));
      return ScoreboardChange.score;
    case 'setServe':
      core.setServe(
        _readTeam(action['team'], allowNone: true),
        _readNullableInt(action['serverNumber']),
      );
      return ScoreboardChange.score;
    case 'swapServe':
      // Đi qua setServe để cập nhật cả đội giao đầu set / tie-break.
      final nextServer = core.serving == 'none'
          ? 'A'
          : scoreboardOtherTeam(core.serving);
      final atSetStart =
          core.pointsA == 0 &&
          core.pointsB == 0 &&
          core.gamesA == 0 &&
          core.gamesB == 0;
      final doublesSideout =
          core.rules.scoring == 'sideout' &&
          core.rules.doubles &&
          !core.isTennis;
      core.setServe(nextServer, atSetStart && doublesSideout ? 2 : 1);
      return ScoreboardChange.score;
    case 'swapSides':
      core.sidesSwapped = !core.sidesSwapped;
      return ScoreboardChange.score;
    case 'endSet':
      core.endSet();
      return ScoreboardChange.score;
    case 'finish':
      core.finishMatch();
      return ScoreboardChange.score;
    case 'reopen':
      core.status = 'playing';
      core.winner = null;
      return ScoreboardChange.score;
    case 'setScore':
      core.overwrite(action);
      if (action.containsKey('teamA') && action['teamA'] is String) {
        state.teamA.patch({'name': action['teamA']});
      }
      if (action.containsKey('teamB') && action['teamB'] is String) {
        state.teamB.patch({'name': action['teamB']});
      }
      return ScoreboardChange.score;
    case 'newMatch':
      final keepSport = core.sport;
      final keepRules = core.rules;
      state.core = ScoreCore.initial(keepSport, keepRules);
      state.matchId = scoreboardMatchId(nowMs);
      state.timer.reset();
      if (_readBool(action['resetTeams'], false)) {
        state.teamA = ScoreTeam.initial('A');
        state.teamB = ScoreTeam.initial('B');
      }
      if (state.overlay.scene == 'result') state.overlay.scene = 'scorebar';
      return ScoreboardChange.score;
    case 'config':
      final sportValue = action['sport']?.toString() ?? core.sport;
      if (!scoreboardSports.contains(sportValue)) {
        throw const ScoreboardException(422, 'invalid_sport', 'Môn thi đấu không hợp lệ.');
      }
      final reset = _readBool(action['reset'], false);
      if (!core.isPristine && !reset) {
        throw const ScoreboardException(
          409,
          'match_in_progress',
          'Trận đang có điểm. Gửi kèm "reset": true để đổi luật và bắt đầu lại.',
        );
      }
      final base = sportValue == core.sport && !_readBool(action['preset'], false)
          ? core.rules
          : ScoreRules.preset(sportValue);
      final rules = ScoreRules.merge(base, _readMap(action['rules']));
      final swapped = core.sidesSwapped;
      state.core = ScoreCore.initial(sportValue, rules)..sidesSwapped = swapped;
      if (reset) {
        state.matchId = scoreboardMatchId(nowMs);
        state.timer.reset();
      }
      return ScoreboardChange.score;
    case 'setTeam':
      final team = state.team(_readTeam(action['team']));
      team.patch(action);
      return ScoreboardChange.meta;
    case 'setTeams':
      final a = _readMap(action['teamA']);
      final b = _readMap(action['teamB']);
      // Kiểm tra trên bản sao trước để không áp dở dang khi một đội lỗi.
      final copyA = ScoreTeam.fromJson(state.teamA.toJson(), 'A')..patch(a);
      final copyB = ScoreTeam.fromJson(state.teamB.toJson(), 'B')..patch(b);
      copyA.logoId = state.teamA.logoId;
      copyB.logoId = state.teamB.logoId;
      state.teamA = copyA;
      state.teamB = copyB;
      return ScoreboardChange.meta;
    case 'setMatchInfo':
      state.match.patch(action);
      return ScoreboardChange.meta;
    case 'overlay':
      final copy = ScoreOverlayConfig.fromJson(state.overlay.toJson());
      copy.patch(action);
      copy.bannerText = state.overlay.bannerText;
      copy.bannerUntilMs = state.overlay.bannerUntilMs;
      state.overlay = copy;
      return ScoreboardChange.meta;
    case 'banner':
      final text = _cleanText(action['text'], maxLength: 80);
      final seconds = _readInt(action['seconds'], 0);
      if (seconds < 0 || seconds > 3600) {
        throw const ScoreboardException(422, 'invalid_seconds', 'Thời gian hiển thị phải từ 0 đến 3600 giây.');
      }
      state.overlay.bannerText = text;
      state.overlay.bannerUntilMs = text.isEmpty || seconds == 0
          ? 0
          : nowMs + seconds * 1000;
      return ScoreboardChange.meta;
    case 'timer':
      final op = action['op']?.toString() ?? '';
      switch (op) {
        case 'start':
          state.timer.start(nowMs);
        case 'pause':
          state.timer.pause(nowMs);
        case 'reset':
          state.timer.reset();
        default:
          throw const ScoreboardException(422, 'invalid_timer_op', 'Lệnh đồng hồ phải là start, pause hoặc reset.');
      }
      return ScoreboardChange.meta;
    case 'removeLogo':
      state.team(_readTeam(action['team'])).logoId = null;
      return ScoreboardChange.meta;
    default:
      throw ScoreboardException(422, 'unknown_action', 'Lệnh "$name" không được hỗ trợ.');
  }
}
