import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/return_code.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ============================================================
// RECORDED SEGMENT
// ============================================================

class RecordedSegment {
  final String id;

  final String cameraId;

  final String path;

  final DateTime startedAt;

  final DateTime endedAt;

  final String type;

  bool downloaded;

  RecordedSegment({
    required this.id,
    required this.cameraId,
    required this.path,
    required this.startedAt,
    required this.endedAt,
    this.type = 'RECORDING',
    this.downloaded = false,
  });

  // ============================================================
  // FILE NAME
  // ============================================================

  String get fileName {
    return path.split(Platform.pathSeparator).last;
  }

  // ============================================================
  // DURATION
  // ============================================================

  Duration get duration {
    return endedAt.difference(startedAt);
  }

  int get durationMs {
    return duration.inMilliseconds;
  }

  // ============================================================
  // JSON
  // ============================================================

  Map<String, dynamic> toJson() {
    return {
      'id': id,

      'cameraId': cameraId,

      'fileName': fileName,

      'startTime': startedAt.toIso8601String(),

      'endTime': endedAt.toIso8601String(),

      'durationMs': durationMs,

      'type': type,

      'downloaded': downloaded,
    };
  }
}

// ============================================================
// RECORDING SERVICE
// ============================================================

class RecordingService {
  final String cameraId;

  static const int storageLimitBytes = 20 * 1024 * 1024 * 1024;

  RecordingService({required this.cameraId});

  // ============================================================
  // CONFIG
  // ============================================================

  static const _storagePathKey = 'camera_video_storage_path';
  static const _segmentMinutesKey = 'camera_video_segment_minutes';
  Duration _segmentDuration = const Duration(minutes: 3);
  String? _selectedStoragePath;

  Duration get segmentDuration => _segmentDuration;
  int get segmentMinutes => _segmentDuration.inMinutes;
  String? get selectedStoragePath => _selectedStoragePath;

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final minutes = prefs.getInt(_segmentMinutesKey) ?? 3;
    _segmentDuration = Duration(minutes: minutes.clamp(1, 30));
    final path = prefs.getString(_storagePathKey)?.trim();
    _selectedStoragePath = path == null || path.isEmpty ? null : path;
  }

  Future<void> setSegmentMinutes(int minutes) async {
    if (minutes < 1 || minutes > 30) {
      throw ArgumentError('Thời lượng phải từ 1 đến 30 phút.');
    }
    _segmentDuration = Duration(minutes: minutes);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_segmentMinutesKey, minutes);
  }

  Future<void> setStoragePath(String? path) async {
    final normalized = path?.trim();
    if (normalized != null && normalized.isNotEmpty) {
      final testDirectory = Directory(normalized);
      await testDirectory.create(recursive: true);
      final test = File(
        '${testDirectory.path}${Platform.pathSeparator}.write_test',
      );
      await test.writeAsString('VNVAR');
      await test.delete();
      _selectedStoragePath = normalized;
    } else {
      _selectedStoragePath = null;
    }
    final prefs = await SharedPreferences.getInstance();
    if (_selectedStoragePath == null) {
      await prefs.remove(_storagePathKey);
    } else {
      await prefs.setString(_storagePathKey, _selectedStoragePath!);
    }
  }

  // ============================================================
  // RECORDER
  // ============================================================

  MediaRecorder? _recorder;

  MediaStreamTrack? _videoTrack;

  Timer? _segmentTimer;

  // ============================================================
  // CURRENT SEGMENT
  // ============================================================

  DateTime? _segmentStartedAt;

  String? _currentPath;

  // ============================================================
  // STATE
  // ============================================================

  bool _recording = false;
  bool _processing = false;

  bool _rotating = false;

  bool _stopping = false;
  Future<void>? _stopOperation;

  bool get recording => _recording;

  bool get rotating => _rotating;

  // ============================================================
  // COMPLETED SEGMENTS
  // ============================================================

  final List<RecordedSegment> _segments = [];

  List<RecordedSegment> get segments {
    final result = List<RecordedSegment>.from(_segments);

    // Mới nhất lên đầu.
    result.sort((a, b) => b.startedAt.compareTo(a.startedAt));

    return List.unmodifiable(result);
  }

  Future<RecordedSegment> trimSegment({
    required String segmentId,
    required int startMs,
    required int endMs,
  }) async {
    if (_processing) {
      throw StateError('Camera Station đang xử lý một video khác.');
    }
    if (startMs < 0 || endMs <= startMs || endMs - startMs < 500) {
      throw ArgumentError('Khoảng cắt video không hợp lệ.');
    }
    final source = findById(segmentId);
    if (source == null || !await File(source.path).exists()) {
      throw StateError('Không tìm thấy video nguồn $segmentId.');
    }
    if (endMs > source.duration.inMilliseconds + 1000) {
      throw ArgumentError('Khoảng cắt vượt quá thời lượng video.');
    }

    _processing = true;
    File? output;
    try {
      final now = DateTime.now();
      final startedAt = source.startedAt.add(Duration(milliseconds: startMs));
      final endedAt = startedAt.add(Duration(milliseconds: endMs - startMs));
      final directory = await _videoDirectory(date: startedAt);
      final id = 'CLIP_${cameraId}_${now.millisecondsSinceEpoch}';
      output = File(
        '${directory.path}${Platform.pathSeparator}'
        '${_videoFileName(startedAt: startedAt, endedAt: endedAt)}.ts',
      );
      final durationMs = endMs - startMs;
      final session = await FFmpegKit.executeWithArguments([
        '-y',
        '-ss',
        (startMs / 1000).toStringAsFixed(3),
        '-i',
        source.path,
        '-t',
        (durationMs / 1000).toStringAsFixed(3),
        '-an',
        '-threads',
        '1',
        '-c:v',
        'mpeg4',
        '-q:v',
        '4',
        '-f',
        'mpegts',
        output.path,
      ]);
      final returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode) ||
          !await output.exists() ||
          await output.length() <= 0) {
        final details = await session.getOutput();
        throw StateError('FFmpeg xử lý thất bại: ${details ?? returnCode}');
      }
      final clip = RecordedSegment(
        id: id,
        cameraId: cameraId,
        path: output.path,
        startedAt: startedAt,
        endedAt: endedAt,
        type: 'CLIP',
      );
      _segments.add(clip);
      _segments.sort((a, b) => a.startedAt.compareTo(b.startedAt));
      await enforceStorageLimit();
      return clip;
    } catch (_) {
      if (output != null && await output.exists()) await output.delete();
      rethrow;
    } finally {
      _processing = false;
    }
  }

  // ============================================================
  // CURRENT SEGMENT INFO
  // ============================================================

  DateTime? get currentSegmentStartedAt {
    return _segmentStartedAt;
  }

  String? get currentPath {
    return _currentPath;
  }

  // ============================================================
  // PERMANENT VIDEO DIRECTORY ON THE CAMERA PHONE
  // ============================================================

  Future<Directory> _videoRootDirectory() async {
    final defaultRoot = await getApplicationDocumentsDirectory();
    final rootPath =
        _selectedStoragePath ??
        '${defaultRoot.path}${Platform.pathSeparator}VNVAR';
    final directory = Directory(rootPath);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<String> getStoragePath() async {
    return (await _videoRootDirectory()).path;
  }

  Future<Directory> _videoDirectory({DateTime? date}) async {
    final root = await _videoRootDirectory();
    final value = date ?? DateTime.now();
    String two(int number) => number.toString().padLeft(2, '0');
    final day = '${two(value.day)}-${two(value.month)}-${value.year}';
    final autoModePath =
        '${root.path}${Platform.pathSeparator}$day'
        '${Platform.pathSeparator}AUTOMODE';
    final directory = Directory(
      // Existing VNVAR storage contract: CAM1 owns the AUTOMODE root while
      // CAM2+ use separate CAMn subfolders. Unknown/non-numbered camera IDs
      // also get their own folder to prevent filename collisions.
      _cameraNumber == 1
          ? autoModePath
          : '$autoModePath${Platform.pathSeparator}$_cameraFolderName',
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  int? get _cameraNumber {
    final match = RegExp(r'(\d+)$').firstMatch(cameraId.trim());
    return int.tryParse(match?.group(1) ?? '');
  }

  String get _cameraFolderName =>
      _cameraNumber == null ? cameraId.toUpperCase() : 'CAM$_cameraNumber';

  String _videoFileName({
    required DateTime startedAt,
    required DateTime endedAt,
  }) {
    String two(int value) => value.toString().padLeft(2, '0');
    String clock(DateTime value) =>
        '${two(value.hour)}-${two(value.minute)}-${two(value.second)}';
    return '${clock(startedAt)}_${clock(endedAt)}';
  }

  Future<File> _convertRecordingToTs(
    File source,
    DateTime startedAt,
    DateTime endedAt,
  ) async {
    final directory = await _videoDirectory(date: startedAt);
    final target = File(
      '${directory.path}${Platform.pathSeparator}'
      '${_videoFileName(startedAt: startedAt, endedAt: endedAt)}.ts',
    );
    var session = await FFmpegKit.executeWithArguments([
      '-y',
      '-i',
      source.path,
      '-map',
      '0:v:0',
      '-an',
      '-c:v',
      'copy',
      '-f',
      'mpegts',
      target.path,
    ]);
    var code = await session.getReturnCode();
    if (!ReturnCode.isSuccess(code)) {
      session = await FFmpegKit.executeWithArguments([
        '-y',
        '-i',
        source.path,
        '-map',
        '0:v:0',
        '-an',
        '-threads',
        '1',
        '-c:v',
        'mpeg4',
        '-q:v',
        '4',
        '-f',
        'mpegts',
        target.path,
      ]);
      code = await session.getReturnCode();
    }
    if (!ReturnCode.isSuccess(code) ||
        !await target.exists() ||
        await target.length() <= 0) {
      final output = await session.getOutput();
      if (await target.exists()) await target.delete();
      throw StateError(
        'Không thể tạo file MPEG-TS từ đoạn vừa ghi. '
        'FFmpeg: ${output ?? 'không có thông tin lỗi'}',
      );
    }
    if (await source.exists()) await source.delete();
    developer.log(
      'TS SAVED: ${target.path} | ${await target.length()} bytes',
      name: 'RecordingService',
    );
    debugPrint('[VNVAR] TS SAVED: ${target.path}');
    return target;
  }

  // ============================================================
  // START RECORDING
  // ============================================================

  Future<void> start({required MediaStreamTrack videoTrack}) async {
    final stopping = _stopOperation;
    if (stopping != null) await stopping;

    if (_recording) {
      developer.log('Recording already running', name: 'RecordingService');

      return;
    }

    if (_stopping) {
      throw StateError('RecordingService is stopping.');
    }

    _videoTrack = videoTrack;

    _recording = true;

    try {
      // ========================================================
      // FIRST SEGMENT
      // ========================================================

      await _startNewSegment();

      // ========================================================
      // AUTO ROTATE BY THE CONFIGURED DURATION
      // ========================================================

      _segmentTimer = Timer(_segmentDuration, () {
        _rotateSegment();
      });

      developer.log(
        'Recording started. '
        'Segment duration: '
        '${_segmentDuration.inMinutes} minutes.',
        name: 'RecordingService',
      );
    } catch (error, stackTrace) {
      _recording = false;

      _videoTrack = null;

      _segmentTimer?.cancel();

      _segmentTimer = null;

      developer.log(
        'Failed to start recording',
        error: error,
        stackTrace: stackTrace,
        name: 'RecordingService',
      );

      rethrow;
    }
  }

  // ============================================================
  // START NEW SEGMENT
  // ============================================================

  Future<void> _startNewSegment() async {
    if (!_recording) {
      return;
    }

    final videoTrack = _videoTrack;

    if (videoTrack == null) {
      throw StateError('Không có video track để ghi.');
    }

    final now = DateTime.now();
    final timestamp = now.millisecondsSinceEpoch;
    final stagingRoot = await getTemporaryDirectory();
    final stagingDirectory = Directory(
      '${stagingRoot.path}${Platform.pathSeparator}vnvar_recording',
    );
    await stagingDirectory.create(recursive: true);
    final fileName = '${cameraId}_$timestamp.mp4';

    final path =
        '${stagingDirectory.path}'
        '${Platform.pathSeparator}'
        '$fileName';

    final recorder = MediaRecorder();

    developer.log(
      'Starting new 3-minute segment: '
      '$fileName',
      name: 'RecordingService',
    );

    // ==========================================================
    // START MEDIA RECORDER
    // ==========================================================

    await recorder.start(path, videoTrack: videoTrack);

    _recorder = recorder;

    _currentPath = path;

    _segmentStartedAt = now;
  }

  // ============================================================
  // ROTATE SEGMENT
  //
  // 3 phút:
  //
  // segment A
  //     ↓ stop
  // add completed list
  //     ↓
  // segment B
  // ============================================================

  Future<void> _rotateSegment() async {
    if (!_recording) {
      return;
    }

    if (_rotating) {
      developer.log(
        'Rotate ignored because previous rotation '
        'is still running.',
        name: 'RecordingService',
      );

      return;
    }

    _rotating = true;

    try {
      await _finishCurrentSegment();

      if (_recording && !_stopping) {
        await _startNewSegment();
      }
    } catch (error, stackTrace) {
      developer.log(
        'Segment rotation failed',
        error: error,
        stackTrace: stackTrace,
        name: 'RecordingService',
      );

      // Nếu segment cũ đã đóng nhưng segment mới
      // chưa mở được thì thử mở lại.
      if (_recording && _recorder == null && !_stopping) {
        try {
          await _startNewSegment();
        } catch (restartError, restartStack) {
          developer.log(
            'Failed to restart recorder after '
            'rotation failure.',
            error: restartError,
            stackTrace: restartStack,
            name: 'RecordingService',
          );
        }
      }
    } finally {
      _rotating = false;
      if (_recording && !_stopping) {
        _segmentTimer?.cancel();
        _segmentTimer = Timer(_segmentDuration, _rotateSegment);
      }
    }
  }

  // ============================================================
  // FINISH CURRENT SEGMENT
  // ============================================================

  Future<RecordedSegment?> _finishCurrentSegment() async {
    final recorder = _recorder;

    final path = _currentPath;

    final startedAt = _segmentStartedAt;

    // Clear trước để tránh stop gọi hai lần.
    _recorder = null;

    _currentPath = null;

    _segmentStartedAt = null;

    if (recorder == null || path == null || startedAt == null) {
      return null;
    }

    developer.log('Finishing segment: $path', name: 'RecordingService');

    // ==========================================================
    // STOP RECORDER
    // ==========================================================

    await recorder.stop();

    final endedAt = DateTime.now();
    var file = File(path);

    // ==========================================================
    // VALIDATE FILE
    // ==========================================================

    if (!await file.exists()) {
      developer.log(
        'Recorded segment file does not exist: '
        '$path',
        name: 'RecordingService',
      );

      return null;
    }

    final int fileSize = await file.length();

    if (fileSize <= 0) {
      developer.log(
        'Recorded segment is empty: $path',
        name: 'RecordingService',
      );

      try {
        await file.delete();
      } catch (_) {}

      return null;
    }

    file = await _convertRecordingToTs(file, startedAt, endedAt);

    // ==========================================================
    // CREATE SEGMENT METADATA
    // ==========================================================

    final segment = RecordedSegment(
      id: '${cameraId}_${startedAt.millisecondsSinceEpoch}',

      cameraId: cameraId,

      path: file.path,

      startedAt: startedAt,

      endedAt: endedAt,

      downloaded: false,
    );

    _segments.add(segment);
    await enforceStorageLimit();

    final savedSize = await file.length();
    developer.log(
      'SEGMENT READY: '
      '${segment.fileName} | '
      '${segment.duration.inSeconds}s | '
      '$savedSize bytes | '
      '${segment.path}',
      name: 'RecordingService',
    );
    debugPrint('[VNVAR] SEGMENT READY: ${segment.path}');

    return segment;
  }

  // ============================================================
  // FIND SEGMENT BY ID
  // ============================================================

  RecordedSegment? findById(String segmentId) {
    for (final segment in _segments) {
      if (segment.id == segmentId) {
        return segment;
      }
    }

    return null;
  }

  // ============================================================
  // FIND SEGMENT BY FILE NAME
  // ============================================================

  RecordedSegment? findByFileName(String fileName) {
    for (final segment in _segments) {
      if (segment.fileName == fileName) {
        return segment;
      }
    }

    return null;
  }

  // ============================================================
  // MARK DOWNLOADED
  //
  // Tablet đã download MP4 thành công.
  // ============================================================

  Future<bool> markDownloaded(String segmentId) async {
    final segment = findById(segmentId);

    if (segment == null) {
      return false;
    }

    segment.downloaded = true;

    developer.log(
      'Segment marked downloaded: '
      '${segment.fileName}',
      name: 'RecordingService',
    );

    return true;
  }

  // ============================================================
  // MARK DOWNLOADED BUT KEEP THE PHONE AS THE ORIGINAL VIDEO STORE
  // ============================================================

  Future<bool> markDownloadedAndDelete(String segmentId) async {
    return markDownloaded(segmentId);
  }

  // ============================================================
  // DELETE SEGMENT MANUALLY
  // ============================================================

  Future<bool> deleteSegment(String segmentId) async {
    final segment = findById(segmentId);

    if (segment == null) {
      return false;
    }

    try {
      final file = File(segment.path);

      if (await file.exists()) {
        await file.delete();
      }

      _segments.removeWhere((item) => item.id == segmentId);

      return true;
    } catch (error, stackTrace) {
      developer.log(
        'Delete segment error',
        error: error,
        stackTrace: stackTrace,
        name: 'RecordingService',
      );

      return false;
    }
  }

  // ============================================================
  // REBUILD THE VIDEO INDEX FROM PERMANENT PHONE STORAGE
  // ============================================================

  Future<void> cleanupOldTempFiles({
    Duration maxAge = const Duration(hours: 24),
  }) async {
    final directory = await _videoRootDirectory();
    _segments.clear();
    await for (final entity in directory.list(recursive: true)) {
      if (entity is! File) {
        continue;
      }

      final lowerPath = entity.path.toLowerCase();
      if (!lowerPath.endsWith('.ts') && !lowerPath.endsWith('.mp4')) {
        continue;
      }
      try {
        final stat = await entity.stat();
        final fileName = entity.uri.pathSegments.last;
        final normalizedPath = entity.path.replaceAll('\\', '/');
        final parentPath = entity.parent.path.replaceAll('\\', '/');
        final belongsToCamera = _cameraNumber == 1
            ? parentPath.toUpperCase().endsWith('/AUTOMODE')
            : parentPath.toUpperCase().endsWith(
                '/AUTOMODE/${_cameraFolderName.toUpperCase()}',
              );
        final newNameMatch = RegExp(
          r'^(\d{2})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})\.ts$',
          caseSensitive: false,
        ).firstMatch(fileName);
        final dateMatch = RegExp(
          r'/(\d{2})-(\d{2})-(\d{4})/AUTOMODE/',
          caseSensitive: false,
        ).firstMatch(normalizedPath);
        if (newNameMatch != null && dateMatch != null && belongsToCamera) {
          final year = int.parse(dateMatch.group(3)!);
          final month = int.parse(dateMatch.group(2)!);
          final day = int.parse(dateMatch.group(1)!);
          final startedAt = DateTime(
            year,
            month,
            day,
            int.parse(newNameMatch.group(1)!),
            int.parse(newNameMatch.group(2)!),
            int.parse(newNameMatch.group(3)!),
          );
          var endedAt = DateTime(
            year,
            month,
            day,
            int.parse(newNameMatch.group(4)!),
            int.parse(newNameMatch.group(5)!),
            int.parse(newNameMatch.group(6)!),
          );
          if (endedAt.isBefore(startedAt)) {
            endedAt = endedAt.add(const Duration(days: 1));
          }
          final timestamp = startedAt.millisecondsSinceEpoch;
          _segments.add(
            RecordedSegment(
              id: '${cameraId}_$timestamp',
              cameraId: cameraId,
              path: entity.path,
              startedAt: startedAt,
              endedAt: endedAt,
            ),
          );
          continue;
        }

        // Hỗ trợ các tên file cũ đã lưu trước khi đổi cấu trúc.
        final timestampText = fileName
            .replaceAll(RegExp(r'\.(mp4|ts)$', caseSensitive: false), '')
            .split('_')
            .last;
        final timestamp = int.tryParse(timestampText);
        final isNewName = fileName.startsWith('VNVAR_${cameraId}_');
        final isClip =
            fileName.contains('_CLIP_') ||
            fileName.startsWith('CLIP_${cameraId}_');
        final isRecording = isNewName || fileName.startsWith('${cameraId}_');
        if (timestamp == null || (!isRecording && !isClip)) continue;
        final startedAt = DateTime.fromMillisecondsSinceEpoch(timestamp);
        _segments.add(
          RecordedSegment(
            id: isClip
                ? 'CLIP_${cameraId}_$timestamp'
                : '${cameraId}_$timestamp',
            cameraId: cameraId,
            path: entity.path,
            startedAt: startedAt,
            endedAt: stat.modified.isAfter(startedAt)
                ? stat.modified
                : startedAt,
            type: isClip ? 'CLIP' : 'RECORDING',
          ),
        );
      } catch (error, stackTrace) {
        developer.log(
          'Unable to index stored video',
          error: error,
          stackTrace: stackTrace,
          name: 'RecordingService',
        );
      }
    }

    _segments.sort((a, b) => a.startedAt.compareTo(b.startedAt));
    await enforceStorageLimit();
    developer.log(
      'Loaded ${_segments.length} stored video segment(s)',
      name: 'RecordingService',
    );
  }

  Future<int> storageSizeBytes() async {
    final root = await _videoRootDirectory();
    var total = 0;
    await for (final entity in root.list(recursive: true)) {
      if (entity is File &&
          (entity.path.toLowerCase().endsWith('.ts') ||
              entity.path.toLowerCase().endsWith('.mp4'))) {
        try {
          total += await entity.length();
        } catch (_) {}
      }
    }
    return total;
  }

  Future<void> enforceStorageLimit() async {
    final root = await _videoRootDirectory();
    final files = <({File file, FileStat stat, String day})>[];
    var total = 0;
    await for (final entity in root.list(recursive: true)) {
      if (entity is! File) continue;
      final lower = entity.path.toLowerCase();
      if (!lower.endsWith('.ts') && !lower.endsWith('.mp4')) continue;
      try {
        final stat = await entity.stat();
        final normalized = entity.path.replaceAll('\\', '/');
        final match = RegExp(
          r'/([0-9]{2}-[0-9]{2}-[0-9]{4})/',
        ).firstMatch(normalized);
        files.add((file: entity, stat: stat, day: match?.group(1) ?? ''));
        total += stat.size;
      } catch (_) {}
    }
    if (total <= storageLimitBytes) return;

    DateTime dayValue(String value) {
      final parts = value.split('-');
      if (parts.length != 3) return DateTime.fromMillisecondsSinceEpoch(0);
      return DateTime(
        int.tryParse(parts[2]) ?? 1970,
        int.tryParse(parts[1]) ?? 1,
        int.tryParse(parts[0]) ?? 1,
      );
    }

    files.sort((a, b) {
      final byDay = dayValue(a.day).compareTo(dayValue(b.day));
      return byDay != 0 ? byDay : a.stat.modified.compareTo(b.stat.modified);
    });
    final days = files.map((item) => item.day).toSet();
    for (final item in files) {
      if (total <= storageLimitBytes) break;
      // Khi có nhiều ngày, xóa trọn ngày cũ nhất. Nếu chỉ còn
      // một ngày thì xóa từng video cũ theo kiểu cuốn chiếu.
      try {
        await item.file.delete();
        total -= item.stat.size;
        _segments.removeWhere((segment) => segment.path == item.file.path);
      } catch (_) {}
      if (!files.any(
        (other) =>
            other.day == item.day &&
            other.file.path != item.file.path &&
            other.file.existsSync(),
      )) {
        days.remove(item.day);
      }
    }
    debugPrint(
      '[VNVAR] STORAGE CLEANUP: ${(total / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB / 20 GB',
    );
  }

  // ============================================================
  // STOP RECORDING
  // ============================================================

  Future<void> stop() {
    final current = _stopOperation;
    if (current != null) return current;

    final operation = _stopInternal();
    _stopOperation = operation;
    return operation.whenComplete(() {
      if (identical(_stopOperation, operation)) _stopOperation = null;
    });
  }

  Future<void> _stopInternal() async {
    _stopping = true;

    try {
      // ========================================================
      // STOP TIMER FIRST
      // ========================================================

      _segmentTimer?.cancel();

      _segmentTimer = null;

      if (!_recording) {
        return;
      }

      _recording = false;

      // Nếu rotation đang xảy ra,
      // chờ một chút cho nó kết thúc.
      final rotationDeadline = DateTime.now().add(const Duration(seconds: 10));
      while (_rotating && DateTime.now().isBefore(rotationDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      if (_rotating) {
        developer.log(
          'Timed out waiting 10 seconds for segment rotation to finish. '
          'The rotation will finish asynchronously.',
          name: 'RecordingService',
        );
        _videoTrack = null;
        return;
      }

      // ========================================================
      // SAVE LAST PARTIAL SEGMENT
      //
      // Ví dụ camera dừng sau 01:42
      // thì vẫn lưu đoạn 1 phút 42 giây cuối.
      // ========================================================

      await _finishCurrentSegment();

      _videoTrack = null;

      developer.log('Recording stopped', name: 'RecordingService');
    } finally {
      _stopping = false;
    }
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  Future<void> dispose() async {
    _segmentTimer?.cancel();

    _segmentTimer = null;

    try {
      final stopping = _stopOperation;
      if (stopping != null) {
        await stopping;
      } else if (_recording || _recorder != null) {
        await stop();
      }
    } finally {
      _stopOperation = null;
    }

    _videoTrack = null;

    developer.log('RecordingService disposed', name: 'RecordingService');
  }
}
