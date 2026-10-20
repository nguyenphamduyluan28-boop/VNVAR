import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/scoreboard_state.dart';

/// Kết quả lưu logo.
class ScoreboardLogo {
  final String id;
  final String contentType;

  const ScoreboardLogo(this.id, this.contentType);
}

/// Nhận dạng ảnh logo từ vài byte đầu. Trả về phần mở rộng hoặc null.
String? detectScoreboardImageExtension(List<int> bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'png';
  }
  if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return 'jpg';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'webp';
  }
  return null;
}

String scoreboardContentTypeForLogo(String id) {
  if (id.endsWith('.png')) return 'image/png';
  if (id.endsWith('.webp')) return 'image/webp';
  return 'image/jpeg';
}

/// Sinh mã điều khiển 6 ký tự, bỏ các ký tự dễ nhầm (0/O, 1/I/L).
String generateScoreboardKey([math.Random? random]) {
  const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  final source = random ?? math.Random.secure();
  return List.generate(6, (_) => alphabet[source.nextInt(alphabet.length)]).join();
}

/// Một bước hoàn tác: phần điểm/luật trước lệnh, và tên hai đội nếu lệnh
/// (`setScore` kèm `teamA`/`teamB`) đã đổi tên.
class _UndoStep {
  const _UndoStep(this.core, {this.namesBefore, this.namesAfter});

  final ScoreCore core;
  final ({String a, String b})? namesBefore;
  final ({String a, String b})? namesAfter;
}

/// Giữ trạng thái bảng tỉ số cho toàn app (sống qua các lần khởi động lại
/// server camera), áp lệnh, lưu vào máy và phát thay đổi cho SSE/UI.
class ScoreboardService {
  ScoreboardService({
    this.storageKey = 'scoreboard_state_v1',
    this.controlKeyStorageKey = 'scoreboard_control_key',
    this._logoDirectoryProvider,
    int Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// Dùng chung cho server và Hub trong app.
  static final ScoreboardService instance = ScoreboardService();

  static const int maximumUndoSteps = 100;
  static const int maximumRememberedActions = 200;
  static const int maximumLogoBytes = 512 * 1024;

  final String storageKey;
  final String controlKeyStorageKey;
  final Future<Directory> Function()? _logoDirectoryProvider;
  final int Function() _clock;

  /// Đổi mỗi lần service được tạo: client nhận ra app đã khởi động lại và
  /// chấp nhận trạng thái mới kể cả khi `rev` nhỏ hơn.
  final String epoch = generateScoreboardKey();

  late ScoreboardState _state = ScoreboardState.initial(nowMs: _clock());
  String _controlKey = '';
  final List<_UndoStep> _undo = <_UndoStep>[];
  final LinkedHashMap<String, bool> _recentActionIds =
      LinkedHashMap<String, bool>();
  final StreamController<Map<String, dynamic>> _changes =
      StreamController<Map<String, dynamic>>.broadcast();

  Future<void>? _loading;
  Timer? _saveTimer;
  Timer? _bannerTimer;
  Future<void> _logoTail = Future<void>.value();

  int get nowMs => _clock();
  String get controlKey => _controlKey;
  int get rev => _state.rev;
  bool get canUndo => _undo.isNotEmpty;

  /// Phát JSON trạng thái mới mỗi khi có thay đổi.
  Stream<Map<String, dynamic>> get changes => _changes.stream;

  /// Đọc trạng thái và mã điều khiển đã lưu (gọi nhiều lần vẫn an toàn).
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = prefs.getString(controlKeyStorageKey)?.trim() ?? '';
      if (RegExp(r'^[A-Z0-9]{6}$').hasMatch(key)) {
        _controlKey = key;
      } else {
        _controlKey = generateScoreboardKey();
        await prefs.setString(controlKeyStorageKey, _controlKey);
      }
      final raw = prefs.getString(storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          _state = ScoreboardState.fromJson(decoded, nowMs: nowMs);
        }
      }
    } catch (error, stackTrace) {
      developer.log(
        '[SCOREBOARD] Unable to load saved scoreboard; using defaults',
        error: error,
        stackTrace: stackTrace,
        name: 'ScoreboardService',
      );
      if (_controlKey.isEmpty) _controlKey = generateScoreboardKey();
    }
    _scheduleBannerExpiry();
  }

  /// Trạng thái hiện tại dạng JSON (gửi cho client).
  Map<String, dynamic> snapshot() =>
      _state.toJson(nowMs: nowMs, epoch: epoch);

  /// So khớp mã điều khiển (không phân biệt hoa thường, bỏ khoảng trắng).
  bool verifyKey(String? candidate) {
    if (_controlKey.isEmpty || candidate == null) return false;
    final normalized = candidate.trim().toUpperCase();
    if (normalized.length != _controlKey.length) return false;
    var diff = 0;
    for (var i = 0; i < normalized.length; i++) {
      diff |= normalized.codeUnitAt(i) ^ _controlKey.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Tạo mã mới: mọi link/QR cũ hết quyền điều khiển.
  Future<String> regenerateKey() async {
    await load();
    _controlKey = generateScoreboardKey();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(controlKeyStorageKey, _controlKey);
    } catch (error) {
      developer.log(
        '[SCOREBOARD] Unable to save control key: $error',
        name: 'ScoreboardService',
      );
    }
    return _controlKey;
  }

  /// Áp một lệnh. Trả về trạng thái mới. Ném [ScoreboardException] nếu lệnh
  /// không hợp lệ; khi đó trạng thái giữ nguyên.
  Map<String, dynamic> apply(Map<String, dynamic> action) {
    final id = action['id']?.toString().trim() ?? '';
    if (id.isNotEmpty && _recentActionIds.containsKey(id)) {
      // Client gửi lại lệnh đã xử lý (mạng chập chờn): không áp lần hai.
      return snapshot();
    }
    final name = action['action']?.toString() ?? '';
    final now = nowMs;

    if (name == 'undo') {
      if (_undo.isEmpty) {
        throw const ScoreboardException(409, 'nothing_to_undo', 'Không còn thao tác để hoàn tác.');
      }
      final step = _undo.removeLast();
      _state.core = step.core;
      // Lệnh được hoàn tác đã đổi tên đội: trả lại tên cũ, trừ khi tên đã
      // được sửa tiếp bằng lệnh khác sau đó.
      final namesBefore = step.namesBefore;
      final namesAfter = step.namesAfter;
      if (namesBefore != null && namesAfter != null) {
        if (_state.teamA.name == namesAfter.a) {
          _state.teamA.name = namesBefore.a;
        }
        if (_state.teamB.name == namesAfter.b) {
          _state.teamB.name = namesBefore.b;
        }
      }
    } else {
      // Áp lên bản sao: lệnh lỗi giữa chừng không làm hỏng trạng thái thật.
      final working = ScoreboardState.fromJson(
        _state.toJson(nowMs: now),
        nowMs: now,
      );
      final before = _state.core.copy();
      final namesBefore = (a: _state.teamA.name, b: _state.teamB.name);
      final logosBefore = {_state.teamA.logoId, _state.teamB.logoId};
      final change = applyScoreboardAction(working, action, nowMs: now);
      _state = working;
      // Logo không còn đội nào dùng (gỡ logo / trận mới đặt lại đội): xoá file.
      final logosAfter = {_state.teamA.logoId, _state.teamB.logoId};
      for (final id in logosBefore) {
        if (id != null && !logosAfter.contains(id)) unawaited(_deleteLogo(id));
      }
      if (change == ScoreboardChange.newMatch) {
        // Trận mới (mã trận mới, có thể đổi đội): các bước hoàn tác thuộc trận
        // cũ, giữ lại thì "undo" sẽ đưa điểm trận cũ về dưới trận mới.
        _undo.clear();
      } else if (change == ScoreboardChange.score) {
        final namesAfter = (a: _state.teamA.name, b: _state.teamB.name);
        final renamed = namesAfter != namesBefore;
        _undo.add(
          _UndoStep(
            before,
            namesBefore: renamed ? namesBefore : null,
            namesAfter: renamed ? namesAfter : null,
          ),
        );
        if (_undo.length > maximumUndoSteps) _undo.removeAt(0);
      }
      if (name == 'banner') _scheduleBannerExpiry();
    }

    if (id.isNotEmpty) {
      _recentActionIds[id] = true;
      while (_recentActionIds.length > maximumRememberedActions) {
        _recentActionIds.remove(_recentActionIds.keys.first);
      }
    }
    return _commit(now);
  }

  Map<String, dynamic> _commit(int now) {
    _state.rev += 1;
    _state.updatedAtMs = now;
    _scheduleSave();
    final json = snapshot();
    if (!_changes.isClosed) _changes.add(json);
    return json;
  }

  void _scheduleBannerExpiry() {
    _bannerTimer?.cancel();
    _bannerTimer = null;
    final until = _state.overlay.bannerUntilMs;
    if (until <= 0 || _state.overlay.bannerText.isEmpty) return;
    final delay = until - nowMs;
    if (delay <= 0) {
      _state.overlay.bannerText = '';
      _state.overlay.bannerUntilMs = 0;
      return;
    }
    _bannerTimer = Timer(Duration(milliseconds: delay), () {
      _bannerTimer = null;
      if (_state.overlay.bannerUntilMs != until) return;
      _state.overlay.bannerText = '';
      _state.overlay.bannerUntilMs = 0;
      _commit(nowMs);
    });
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      _saveTimer = null;
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, jsonEncode(_state.toJson(nowMs: nowMs)));
    } catch (error) {
      developer.log(
        '[SCOREBOARD] Unable to save scoreboard: $error',
        name: 'ScoreboardService',
      );
    }
  }

  /// Ghi ngay (dùng khi app sắp dừng).
  Future<void> flush() async {
    if (_saveTimer == null) return;
    _saveTimer?.cancel();
    _saveTimer = null;
    await _save();
  }

  // ============================================================
  // LOGO
  // ============================================================

  Future<Directory> _logoDirectory() async {
    final provider = _logoDirectoryProvider;
    final Directory base;
    if (provider != null) {
      base = await provider();
    } else {
      final support = await getApplicationSupportDirectory();
      base = Directory('${support.path}${Platform.pathSeparator}scoreboard_logos');
    }
    if (!await base.exists()) await base.create(recursive: true);
    return base;
  }

  /// Lưu logo cho [team] ('A' | 'B') và gắn vào đội. Ảnh nên được thu nhỏ
  /// ở trình duyệt trước khi gửi (tối đa [maximumLogoBytes]).
  Future<Map<String, dynamic>> saveLogo(String team, List<int> bytes) {
    final completer = Completer<Map<String, dynamic>>();
    _logoTail = _logoTail.then((_) async {
      try {
        completer.complete(await _saveLogoInternal(team, bytes));
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<Map<String, dynamic>> _saveLogoInternal(
    String team,
    List<int> bytes,
  ) async {
    if (team != 'A' && team != 'B') {
      throw const ScoreboardException(422, 'invalid_team', 'Đội phải là "A" hoặc "B".');
    }
    if (bytes.isEmpty || bytes.length > maximumLogoBytes) {
      throw const ScoreboardException(
        422,
        'invalid_logo_size',
        'Logo phải nhỏ hơn 512 KB.',
      );
    }
    final extension = detectScoreboardImageExtension(bytes);
    if (extension == null) {
      throw const ScoreboardException(
        422,
        'invalid_logo_type',
        'Logo phải là ảnh PNG, JPG hoặc WebP.',
      );
    }
    await load();
    final directory = await _logoDirectory();
    final id = '${team}_$nowMs.$extension';
    final file = File('${directory.path}${Platform.pathSeparator}$id');
    await file.writeAsBytes(bytes, flush: true);

    final previous = _state.team(team).logoId;
    _state.team(team).logoId = id;
    final json = _commit(nowMs);
    if (previous != null && previous != id) {
      unawaited(_deleteLogo(previous));
    }
    return json;
  }

  Future<void> _deleteLogo(String id) async {
    if (!isValidScoreboardLogoId(id)) return;
    try {
      final directory = await _logoDirectory();
      final file = File('${directory.path}${Platform.pathSeparator}$id');
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// File logo theo [id] (đã kiểm tra tên, không cho đi ra ngoài thư mục).
  Future<File?> logoFile(String id) async {
    if (!isValidScoreboardLogoId(id)) return null;
    final directory = await _logoDirectory();
    final file = File('${directory.path}${Platform.pathSeparator}$id');
    return await file.exists() ? file : null;
  }
}
