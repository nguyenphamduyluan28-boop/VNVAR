import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/return_code.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'video_storage_service.dart';

String normalizeCameraKey(String cameraId) {
  final cameraNumber = RegExp(r'(\d+)$').firstMatch(cameraId.trim())?.group(1);
  final normalized = cameraNumber == null
      ? cameraId
            .trim()
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9_-]+'), '_')
            .replaceAll(RegExp(r'^_+|_+$'), '')
      : 'cam${int.parse(cameraNumber)}';
  return normalized.isEmpty ? 'camera' : normalized;
}

/// Builds a cache-safe, unique name for a clip exported by the trim API.
String buildTrimmedClipFileName(String cameraId, int timestampMs) {
  return '${normalizeCameraKey(cameraId)}_trim_$timestampMs.mp4';
}

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
  static const int storageDays = 1;
  static const int normalFreeSpaceThresholdBytes = 5 * 1024 * 1024 * 1024;
  static const int matchFreeSpaceThresholdBytes = 1 * 1024 * 1024 * 1024;
  static const int autoCleanupMaxPasses = 50;
  static const int autoCleanupBatchSize = 10;
  static const int hlsEmergencyThresholdBytes = 1 * 1024 * 1024 * 1024;
  static const Duration recentSegmentProtection = Duration(minutes: 5);

  RecordingService({
    required this.cameraId,
    VideoStorageService? videoStorageService,
  }) : _videoStorage = videoStorageService ?? VideoStorageService();

  final VideoStorageService _videoStorage;

  // ============================================================
  // CONFIG
  // ============================================================

  static const _segmentMinutesKey = 'camera_video_segment_minutes';
  Duration _segmentDuration = const Duration(minutes: 3);

  Duration get segmentDuration => _segmentDuration;
  int get segmentMinutes => _segmentDuration.inMinutes;
  String? get selectedStoragePath => _videoStorage.selectedPath;
  bool get supportsStorageFolderSelection => _videoStorage.supportsFolderPicker;

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final minutes = prefs.getInt(_segmentMinutesKey) ?? 3;
    _segmentDuration = Duration(minutes: minutes.clamp(1, 30));
    await _videoStorage.load();
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
    await _videoStorage.setStoragePath(path);
  }

  Future<String?> selectStorageFolder() => _videoStorage.selectFolder();

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
  Future<RecordedSegment>? _trimOperation;

  bool _rotating = false;

  bool _stopping = false;
  Future<void>? _stopOperation;
  Future<RecordedSegment?>? _rotationOperation;
  Future<void>? _expiredCleanupOperation;
  Future<void>? _storageLimitOperation;
  Future<void>? _autoCleanupOperation;
  Future<void>? _hlsCleanupOperation;
  Future<void>? _exportCleanupOperation;
  bool _autoRecordingVideo = true;
  bool _duringMatch = false;
  String? _currentMatchDirectory;
  bool _hlsEnabled = false;
  int? _hlsMaxSegments;
  String? _hlsDirectoryPath;

  bool get recording => _recording;

  bool get rotating => _rotating;

  // ============================================================
  // COMPLETED SEGMENTS
  // ============================================================

  final List<RecordedSegment> _segments = [];
  final Map<String, RecordedSegment> _exportSegments = {};
  final StreamController<void> _videoChanges =
      StreamController<void>.broadcast();

  Stream<void> get videoChanges => _videoChanges.stream;

  void _notifyVideoChanges() {
    if (!_videoChanges.isClosed) _videoChanges.add(null);
  }

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
  }) {
    if (_trimOperation != null || _exportCleanupOperation != null) {
      return Future<RecordedSegment>.error(
        StateError('Camera Station đang xử lý một video khác.'),
      );
    }
    final operation = _trimSegmentInternal(
      segmentId: segmentId,
      startMs: startMs,
      endMs: endMs,
    );
    _trimOperation = operation;
    return operation.whenComplete(() {
      if (identical(_trimOperation, operation)) _trimOperation = null;
    });
  }

  Future<RecordedSegment> _trimSegmentInternal({
    required String segmentId,
    required int startMs,
    required int endMs,
  }) async {
    if (startMs < 0 || endMs <= startMs || endMs - startMs < 500) {
      throw ArgumentError('Khoảng cắt video không hợp lệ.');
    }
    final source = findById(segmentId) ?? findByFileName(segmentId);
    if (source == null || !await File(source.path).exists()) {
      throw StateError('Không tìm thấy video nguồn $segmentId.');
    }
    if (endMs > source.duration.inMilliseconds + 1000) {
      throw ArgumentError('Khoảng cắt vượt quá thời lượng video.');
    }

    File? output;
    try {
      final now = DateTime.now();
      final startedAt = source.startedAt.add(Duration(milliseconds: startMs));
      final endedAt = startedAt.add(Duration(milliseconds: endMs - startMs));
      final directory = await _exportDownloadDirectory();
      var timestampMs = now.millisecondsSinceEpoch;
      var fileName = buildTrimmedClipFileName(cameraId, timestampMs);
      output = File('${directory.path}${Platform.pathSeparator}$fileName');
      while (await output!.exists()) {
        fileName = buildTrimmedClipFileName(cameraId, ++timestampMs);
        output = File('${directory.path}${Platform.pathSeparator}$fileName');
      }
      final target = output;
      final id = 'CLIP_${cameraId}_$timestampMs';
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
        '-movflags',
        '+faststart',
        '-f',
        'mp4',
        target.path,
      ]);
      final returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode) ||
          !await target.exists() ||
          await target.length() <= 0) {
        final details = await session.getOutput();
        throw StateError('FFmpeg xử lý thất bại: ${details ?? returnCode}');
      }
      final clip = RecordedSegment(
        id: id,
        cameraId: cameraId,
        path: target.path,
        startedAt: startedAt,
        endedAt: endedAt,
        type: 'CLIP',
      );
      _exportSegments[clip.fileName] = clip;
      return clip;
    } catch (_) {
      if (output != null && await output.exists()) await output.delete();
      rethrow;
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
    return _videoStorage.rootDirectory();
  }

  Future<String> getStoragePath() async {
    return (await _videoRootDirectory()).path;
  }

  /// Xóa toàn bộ thư mục ngày đã hết hạn, tương đương
  /// `STORAGE.RemoveExpiredData` của ứng dụng cũ.
  Future<void> removeExpiredData({DateTime? referenceTime}) {
    final current = _expiredCleanupOperation;
    if (current != null) return current;

    final operation = _removeExpiredDataInternal(referenceTime: referenceTime);
    _expiredCleanupOperation = operation;
    return operation.whenComplete(() {
      if (identical(_expiredCleanupOperation, operation)) {
        _expiredCleanupOperation = null;
      }
    });
  }

  Future<void> _removeExpiredDataInternal({DateTime? referenceTime}) async {
    final root = await _videoRootDirectory();
    final now = referenceTime ?? DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final cutoff = today.subtract(Duration(days: storageDays - 1));

    await for (final entity in root.list()) {
      if (entity is! Directory) continue;

      final directoryName = entity.uri.pathSegments
          .where((part) => part.isNotEmpty)
          .last;
      final match = RegExp(
        r'^(\d{2})-(\d{2})-(\d{4})$',
      ).firstMatch(directoryName);
      if (match == null) continue;

      final day = int.parse(match.group(1)!);
      final month = int.parse(match.group(2)!);
      final year = int.parse(match.group(3)!);
      final directoryDate = DateTime(year, month, day);
      final isValidDate =
          directoryDate.day == day &&
          directoryDate.month == month &&
          directoryDate.year == year;
      if (!isValidDate || !directoryDate.isBefore(cutoff)) continue;

      // Segment bắt đầu trước 0 giờ có thể vừa được hoàn tất sau 0 giờ. Không
      // xóa cả thư mục ngày cũ khi bên trong vẫn có file mới được ghi gần đây.
      var containsRecentFile = false;
      await for (final child in entity.list(recursive: true)) {
        if (child is! File || !_isVideoFile(child)) continue;
        try {
          final modified = (await child.stat()).modified;
          if (now.difference(modified) < recentSegmentProtection) {
            containsRecentFile = true;
            break;
          }
        } catch (_) {}
      }
      if (containsRecentFile) continue;

      try {
        final normalizedDirectory = entity.path.replaceAll('\\', '/');
        await entity.delete(recursive: true);
        _segments.removeWhere((segment) {
          final normalizedPath = segment.path.replaceAll('\\', '/');
          return normalizedPath == normalizedDirectory ||
              normalizedPath.startsWith('$normalizedDirectory/');
        });
        _notifyVideoChanges();
        developer.log(
          '[STORAGE] Removed expired day directory: ${entity.path}',
          name: 'RecordingService',
        );
      } catch (error, stackTrace) {
        developer.log(
          '[STORAGE] Unable to remove expired directory: ${entity.path}',
          error: error,
          stackTrace: stackTrace,
          name: 'RecordingService',
        );
      }
    }
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

  String get _cameraFolderName => normalizeCameraKey(cameraId).toUpperCase();

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
    // Dùng ngày kết thúc để segment đi qua 0 giờ không bị lưu vào thư mục ngày
    // cũ rồi bị RemoveExpiredData xóa ngay.
    final directory = await _videoDirectory(date: endedAt);
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
    _notifyVideoChanges();
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
    try {
      await _requestSegmentRotation();
    } catch (error, stackTrace) {
      developer.log(
        'Segment rotation failed',
        error: error,
        stackTrace: stackTrace,
        name: 'RecordingService',
      );
    }
  }

  Future<RecordedSegment> checkpointCurrentSegment() async {
    if (!_recording) {
      throw StateError('Camera chưa bắt đầu ghi video.');
    }
    final segment = await _requestSegmentRotation();
    if (segment == null) {
      throw StateError('Không có file đang quay để chốt Check VAR.');
    }
    return segment;
  }

  Future<RecordedSegment?> _requestSegmentRotation() {
    final current = _rotationOperation;
    if (current != null) return current;

    final operation = _performSegmentRotation();
    _rotationOperation = operation;
    return operation.whenComplete(() {
      if (identical(_rotationOperation, operation)) {
        _rotationOperation = null;
      }
    });
  }

  Future<RecordedSegment?> _performSegmentRotation() async {
    if (!_recording) return null;

    _rotating = true;
    _segmentTimer?.cancel();
    _segmentTimer = null;
    try {
      final segment = await _finishCurrentSegment(
        onRecorderStopped: () async {
          if (_recording && !_stopping) await _startNewSegment();
        },
      );
      // Fallback if opening the next recorder failed at the hand-off point.
      // The completed file is still finalized and indexed before retrying.
      if (_recording && !_stopping && _recorder == null) {
        await _startNewSegment();
      }
      return segment;
    } catch (_) {
      // Nếu file cũ đã đóng nhưng file mới chưa mở được thì thử khôi phục ghi
      // hình trước khi chuyển lỗi về caller của Check VAR.
      if (_recording && _recorder == null && !_stopping) {
        try {
          await _startNewSegment();
        } catch (restartError, restartStack) {
          developer.log(
            'Failed to restart recorder after rotation failure.',
            error: restartError,
            stackTrace: restartStack,
            name: 'RecordingService',
          );
        }
      }
      rethrow;
    } finally {
      _rotating = false;
      if (_recording && !_stopping) {
        final startedAt = _segmentStartedAt;
        final elapsed = startedAt == null
            ? Duration.zero
            : DateTime.now().difference(startedAt);
        final remaining = _segmentDuration - elapsed;
        _segmentTimer = Timer(
          remaining > Duration.zero
              ? remaining
              : const Duration(milliseconds: 100),
          _rotateSegment,
        );
      }
    }
  }

  // ============================================================
  // FINISH CURRENT SEGMENT
  // ============================================================

  Future<RecordedSegment?> _finishCurrentSegment({
    Future<void> Function()? onRecorderStopped,
  }) async {
    final recorder = _recorder;

    final path = _currentPath;

    final startedAt = _segmentStartedAt;

    // Clear trước để tránh stop gọi hai lần.
    _recorder = null;

    _currentPath = null;

    _segmentStartedAt = null;
    _notifyVideoChanges();

    if (recorder == null || path == null || startedAt == null) {
      return null;
    }

    developer.log('Finishing segment: $path', name: 'RecordingService');

    // ==========================================================
    // STOP RECORDER
    // ==========================================================

    await recorder.stop();

    final endedAt = DateTime.now();
    if (onRecorderStopped != null) {
      try {
        await onRecorderStopped();
      } catch (error, stackTrace) {
        // Continue finalizing the stopped file. The rotation caller retries
        // opening the next recorder after this segment has been indexed.
        developer.log(
          'Unable to open the next recorder during segment hand-off.',
          error: error,
          stackTrace: stackTrace,
          name: 'RecordingService',
        );
      }
    }
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

    // Lấy kích thước trước cleanup. Một RecordingService khác dùng chung thư
    // mục hoặc chính cơ chế giới hạn 20 GB có thể xóa file trong lúc cleanup.
    // Không đọc file.length() lại sau cleanup vì sẽ tạo race condition.
    final int savedSize;
    try {
      savedSize = (await file.stat()).size;
    } on FileSystemException catch (error, stackTrace) {
      developer.log(
        'Completed TS disappeared before it could be indexed: ${file.path}',
        error: error,
        stackTrace: stackTrace,
        name: 'RecordingService',
      );
      return null;
    }

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
    _notifyVideoChanges();
    await enforceStorageLimit();

    if (!await file.exists()) {
      // Cleanup đã xóa file hợp lệ để đáp ứng giới hạn dung lượng. Đồng bộ lại
      // metadata của instance hiện tại và không biến việc dọn file thành lỗi
      // xoay recorder; segment kế tiếp vẫn đang ghi bình thường.
      _segments.removeWhere((item) => item.path == file.path);
      _notifyVideoChanges();
      developer.log(
        'SEGMENT REMOVED BY STORAGE CLEANUP: ${segment.path}',
        name: 'RecordingService',
      );
      return null;
    }

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

  RecordedSegment? findExportByFileName(String fileName) {
    return _exportSegments[fileName];
  }

  Future<Directory> _exportDownloadDirectory() async {
    final root = await _videoRootDirectory();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}download',
    );
    await directory.create(recursive: true);
    return directory;
  }

  /// Kết thúc phiên QR/download và xóa toàn bộ clip xuất tạm.
  Future<void> cleanupExportDownloads() {
    final current = _exportCleanupOperation;
    if (current != null) return current;

    final operation = _cleanupExportDownloadsInternal();
    _exportCleanupOperation = operation;
    return operation.whenComplete(() {
      if (identical(_exportCleanupOperation, operation)) {
        _exportCleanupOperation = null;
      }
    });
  }

  Future<void> _cleanupExportDownloadsInternal() async {
    final trimming = _trimOperation;
    if (trimming != null) {
      try {
        await trimming;
      } catch (_) {
        // A failed trim removes its partial output before completing.
      }
    }
    final root = await _videoRootDirectory();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}download',
    );
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
      _exportSegments.clear();
      developer.log(
        '[STORAGE] Temporary download session cleaned.',
        name: 'RecordingService',
      );
    } catch (error, stackTrace) {
      developer.log(
        '[STORAGE] Unable to clean temporary download directory.',
        error: error,
        stackTrace: stackTrace,
        name: 'RecordingService',
      );
      rethrow;
    }
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
      _notifyVideoChanges();

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
    // Phiên QR cũ không được tồn tại qua lần khởi động tiếp theo.
    await cleanupExportDownloads();
    await _cleanupAbandonedRecordings(maxAge: maxAge);
    // Mở màn hình chính/khởi động server: dọn toàn bộ thư mục ngày hết hạn
    // trước khi dựng lại chỉ mục video.
    await removeExpiredData();
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
        final upperParentPath = parentPath.toUpperCase();
        final cameraFolderMatch = RegExp(
          r'/AUTOMODE/CAM(\d+)$',
        ).firstMatch(upperParentPath);
        final indexedCameraId = cameraFolderMatch != null
            ? 'CAM${cameraFolderMatch.group(1)}'
            : upperParentPath.endsWith('/AUTOMODE')
            ? 'CAM1'
            : null;
        final newNameMatch = RegExp(
          r'^(\d{2})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})\.ts$',
          caseSensitive: false,
        ).firstMatch(fileName);
        final dateMatch = RegExp(
          r'/(\d{2})-(\d{2})-(\d{4})/AUTOMODE/',
          caseSensitive: false,
        ).firstMatch(normalizedPath);
        if (newNameMatch != null &&
            dateMatch != null &&
            indexedCameraId != null &&
            normalizeCameraKey(indexedCameraId) ==
                normalizeCameraKey(cameraId)) {
          final year = int.parse(dateMatch.group(3)!);
          final month = int.parse(dateMatch.group(2)!);
          final day = int.parse(dateMatch.group(1)!);
          var startedAt = DateTime(
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
            // The directory is selected from the segment end date. A range
            // such as 23:59-00:01 therefore started on the previous day.
            startedAt = startedAt.subtract(const Duration(days: 1));
          }
          final timestamp = startedAt.millisecondsSinceEpoch;
          _segments.add(
            RecordedSegment(
              id: '${indexedCameraId}_$timestamp',
              cameraId: indexedCameraId,
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
    _notifyVideoChanges();
    await enforceStorageLimit();
    developer.log(
      'Loaded ${_segments.length} stored video segment(s)',
      name: 'RecordingService',
    );
  }

  Future<void> _cleanupAbandonedRecordings({required Duration maxAge}) async {
    final stagingRoot = await getTemporaryDirectory();
    final directory = Directory(
      '${stagingRoot.path}${Platform.pathSeparator}vnvar_recording',
    );
    if (!await directory.exists()) return;

    final now = DateTime.now();
    final activePath = _currentPath;
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.mp4')) {
        continue;
      }
      if (activePath != null && entity.path == activePath) continue;
      try {
        final stat = await entity.stat();
        if (now.difference(stat.modified) >= maxAge) await entity.delete();
      } catch (error, stackTrace) {
        developer.log(
          '[STORAGE] Unable to remove abandoned recording: ${entity.path}',
          error: error,
          stackTrace: stackTrace,
          name: 'RecordingService',
        );
      }
    }
    await _deleteDirectoryIfEmpty(directory);
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

  Future<int?> availableStorageBytes() async {
    return _videoStorage.availableBytes();
  }

  void configureHlsRollingBuffer({
    required bool enabled,
    required int maxSegments,
  }) {
    if (maxSegments < 1) {
      throw ArgumentError.value(
        maxSegments,
        'maxSegments',
        'MAX_SEGMENTS phải lớn hơn 0.',
      );
    }
    _hlsEnabled = enabled;
    _hlsMaxSegments = maxSegments;
  }

  /// HLS service gọi hàm này ngay sau khi ghi xong một segment `.ts`.
  Future<void> onHlsSegmentCreated(String segmentPath) {
    if (!_hlsEnabled) return Future<void>.value();
    final maxSegments = _hlsMaxSegments;
    if (maxSegments == null) {
      return Future<void>.error(
        StateError('HLS đã bật nhưng chưa cấu hình MAX_SEGMENTS.'),
      );
    }

    final previous = _hlsCleanupOperation ?? Future<void>.value();
    final operation = previous
        .catchError((Object _, StackTrace _) {})
        .then(
          (_) => _handleHlsSegmentCreated(
            segmentPath: segmentPath,
            maxSegments: maxSegments,
          ),
        );
    _hlsCleanupOperation = operation;
    return operation.whenComplete(() {
      if (identical(_hlsCleanupOperation, operation)) {
        _hlsCleanupOperation = null;
      }
    });
  }

  Future<void> _handleHlsSegmentCreated({
    required String segmentPath,
    required int maxSegments,
  }) async {
    final segment = File(segmentPath);
    if (!segment.path.toLowerCase().endsWith('.ts')) {
      throw ArgumentError.value(segmentPath, 'segmentPath', 'Phải là file .ts');
    }
    _hlsDirectoryPath = segment.parent.path;
    await trimToMaxSegments(
      directoryPath: segment.parent.path,
      maxSegments: maxSegments,
    );
    await deleteOldSegmentsIfLowStorage(hlsDirectoryPath: segment.parent.path);
  }

  Future<int> trimToMaxSegments({
    required String directoryPath,
    required int maxSegments,
  }) async {
    if (maxSegments < 1) {
      throw ArgumentError.value(maxSegments, 'maxSegments');
    }
    final directory = Directory(directoryPath);
    if (!await directory.exists()) return 0;

    final segments = <({File file, FileStat stat})>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.ts')) {
        continue;
      }
      try {
        segments.add((file: entity, stat: await entity.stat()));
      } catch (_) {}
    }
    segments.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));

    var deleted = 0;
    final overflow = segments.length - maxSegments;
    if (overflow <= 0) return deleted;
    for (final item in segments.take(overflow)) {
      if (await _deleteCleanupFile(item.file)) deleted++;
    }
    return deleted;
  }

  Future<void> deleteOldSegmentsIfLowStorage({
    required String hlsDirectoryPath,
  }) async {
    final hlsDirectory = Directory(hlsDirectoryPath);
    for (var pass = 0; pass < autoCleanupMaxPasses; pass++) {
      final available = await availableStorageBytes();
      if (available == null || available >= hlsEmergencyThresholdBytes) break;

      // Ưu tiên dữ liệu trận cũ; tuyệt đối bỏ qua trận hiện tại nếu caller đã
      // cấu hình currentMatchDirectory.
      if (await _deleteOldestMatchData(
        currentMatchDirectory: _currentMatchDirectory,
      )) {
        continue;
      }

      if (!await hlsDirectory.exists()) break;
      final segments = <({File file, FileStat stat})>[];
      await for (final entity in hlsDirectory.list()) {
        if (entity is! File || !entity.path.toLowerCase().endsWith('.ts')) {
          continue;
        }
        try {
          segments.add((file: entity, stat: await entity.stat()));
        } catch (_) {}
      }
      segments.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));

      // Luôn giữ segment mới nhất để playlist đang phát không bị rỗng.
      if (segments.length <= 1) break;
      if (!await _deleteCleanupFile(segments.first.file)) break;
    }
  }

  void configureAutoCleanupMode({
    required bool autoRecordingVideo,
    required bool duringMatch,
    String? currentMatchDirectory,
  }) {
    _autoRecordingVideo = autoRecordingVideo;
    _duringMatch = duringMatch;
    _currentMatchDirectory = currentMatchDirectory;
  }

  Future<void> performAutoCleanup() {
    final current = _autoCleanupOperation;
    if (current != null) return current;

    final operation = _performAutoCleanupInternal(
      autoRecordingVideo: _autoRecordingVideo,
      duringMatch: _duringMatch,
      currentMatchDirectory: _currentMatchDirectory,
    );
    _autoCleanupOperation = operation;
    return operation.whenComplete(() {
      if (identical(_autoCleanupOperation, operation)) {
        _autoCleanupOperation = null;
      }
    });
  }

  Future<void> _performAutoCleanupInternal({
    required bool autoRecordingVideo,
    required bool duringMatch,
    required String? currentMatchDirectory,
  }) async {
    final hlsDirectoryPath = _hlsDirectoryPath;
    if (_hlsEnabled && hlsDirectoryPath != null) {
      await deleteOldSegmentsIfLowStorage(hlsDirectoryPath: hlsDirectoryPath);
    }

    final threshold = duringMatch
        ? matchFreeSpaceThresholdBytes
        : normalFreeSpaceThresholdBytes;

    for (var pass = 0; pass < autoCleanupMaxPasses; pass++) {
      final available = await availableStorageBytes();
      if (available == null || available >= threshold) break;

      final deleted = autoRecordingVideo
          ? await _deleteOldestAutoModeBatch()
          : await _deleteOldestMatchData(
              currentMatchDirectory: currentMatchDirectory,
            );
      if (!deleted) {
        developer.log(
          '[STORAGE] Cleanup stopped: no eligible data remains.',
          name: 'RecordingService',
        );
        break;
      }
    }
  }

  bool _isVideoFile(FileSystemEntity entity) {
    if (entity is! File) return false;
    final lower = entity.path.toLowerCase();
    return lower.endsWith('.ts') || lower.endsWith('.mp4');
  }

  Future<List<Directory>> _dayDirectories() async {
    final root = await _videoRootDirectory();
    final result = <({Directory directory, DateTime date})>[];
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final name = entity.uri.pathSegments
          .where((part) => part.isNotEmpty)
          .last;
      final match = RegExp(r'^(\d{2})-(\d{2})-(\d{4})$').firstMatch(name);
      if (match == null) continue;
      final day = int.parse(match.group(1)!);
      final month = int.parse(match.group(2)!);
      final year = int.parse(match.group(3)!);
      final date = DateTime(year, month, day);
      if (date.day == day && date.month == month && date.year == year) {
        result.add((directory: entity, date: date));
      }
    }
    result.sort((a, b) => a.date.compareTo(b.date));
    return result.map((item) => item.directory).toList();
  }

  Future<bool> _deleteOldestAutoModeBatch() async {
    final groups = <String, List<({File file, FileStat stat})>>{};
    for (final dayDirectory in await _dayDirectories()) {
      final autoMode = Directory(
        '${dayDirectory.path}${Platform.pathSeparator}AUTOMODE',
      );
      if (!await autoMode.exists()) continue;
      await for (final entity in autoMode.list(recursive: true)) {
        if (!_isVideoFile(entity)) continue;
        try {
          final file = entity as File;
          final fileName = file.uri.pathSegments.last.toLowerCase();
          final groupKey = '${dayDirectory.path}|$fileName';
          groups.putIfAbsent(groupKey, () => []).add((
            file: file,
            stat: await file.stat(),
          ));
        } catch (_) {}
      }
    }
    if (groups.isEmpty) return false;

    final now = DateTime.now();
    final candidates =
        groups.entries
            .map((entry) {
              final modified = entry.value
                  .map((item) => item.stat.modified)
                  .reduce((a, b) => a.isBefore(b) ? a : b);
              return (files: entry.value, modified: modified);
            })
            .where(
              (group) =>
                  now.difference(group.modified) >= recentSegmentProtection,
            )
            .toList()
          ..sort((a, b) => a.modified.compareTo(b.modified));

    // Luôn giữ lại ít nhất mốc video mới nhất của AUTOMODE. Điều này ngăn
    // cleanup xóa sạch lịch sử khi thiết bị đang thiếu dung lượng.
    if (candidates.length <= 1) return false;
    candidates.removeLast();

    var deletedAny = false;
    for (final group in candidates.take(autoCleanupBatchSize)) {
      // Một mốc thời gian được xóa đồng bộ cho CAM1, CAM2 và CAM3.
      for (final item in group.files) {
        deletedAny = await _deleteCleanupFile(item.file) || deletedAny;
        await _deleteDirectoryIfEmpty(item.file.parent);
      }
    }
    return deletedAny;
  }

  Future<bool> _deleteOldestMatchData({
    required String? currentMatchDirectory,
  }) async {
    final normalizedCurrent = currentMatchDirectory
        ?.replaceAll('\\', '/')
        .toLowerCase();
    final matches = <({Directory directory, FileStat stat})>[];

    for (final dayDirectory in await _dayDirectories()) {
      await for (final entity in dayDirectory.list()) {
        if (entity is! Directory) continue;
        final name = entity.uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last;
        if (name.toUpperCase() == 'AUTOMODE') continue;
        final normalized = entity.path.replaceAll('\\', '/').toLowerCase();
        if (normalizedCurrent != null && normalized == normalizedCurrent) {
          continue;
        }
        try {
          matches.add((directory: entity, stat: await entity.stat()));
        } catch (_) {}
      }
    }
    matches.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
    final recentCutoff = DateTime.now().subtract(recentSegmentProtection);
    matches.removeWhere((item) => item.stat.modified.isAfter(recentCutoff));
    if (matches.isEmpty) return false;

    if (matches.length > 3) {
      var deletedAny = false;
      for (final match in matches.take(3)) {
        try {
          final normalizedDirectory = match.directory.path
              .replaceAll('\\', '/')
              .toLowerCase();
          await match.directory.delete(recursive: true);
          _segments.removeWhere(
            (segment) => segment.path
                .replaceAll('\\', '/')
                .toLowerCase()
                .startsWith('$normalizedDirectory/'),
          );
          _notifyVideoChanges();
          deletedAny = true;
          await _deleteDirectoryIfEmpty(match.directory.parent);
        } catch (error, stackTrace) {
          developer.log(
            '[STORAGE] Unable to delete match: ${match.directory.path}',
            error: error,
            stackTrace: stackTrace,
            name: 'RecordingService',
          );
        }
      }
      return deletedAny;
    }

    final clips = <({File file, FileStat stat})>[];
    for (final match in matches) {
      await for (final entity in match.directory.list(recursive: true)) {
        if (!_isVideoFile(entity)) continue;
        final normalized = entity.path.replaceAll('\\', '/').toUpperCase();
        if (normalized.contains('/CAM2/') || normalized.contains('/CAM3/')) {
          continue;
        }
        try {
          clips.add((file: entity as File, stat: await entity.stat()));
        } catch (_) {}
      }
    }
    clips.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
    final cutoff = DateTime.now().subtract(recentSegmentProtection);
    clips.removeWhere((item) => item.stat.modified.isAfter(cutoff));
    // Bảo vệ clip mới nhất khi chỉ còn ít trận, tránh xóa sạch lịch sử.
    if (clips.length <= 1) return false;

    final cam1File = clips.first.file;
    final cam2File = File(
      '${cam1File.parent.path}${Platform.pathSeparator}CAM2'
      '${Platform.pathSeparator}${cam1File.uri.pathSegments.last}',
    );
    final deletedCam1 = await _deleteCleanupFile(cam1File);
    final deletedCam2 = await _deleteCleanupFile(cam2File);
    final cam3File = File(
      '${cam1File.parent.path}${Platform.pathSeparator}CAM3'
      '${Platform.pathSeparator}${cam1File.uri.pathSegments.last}',
    );
    final deletedCam3 = await _deleteCleanupFile(cam3File);
    await _deleteDirectoryIfEmpty(cam2File.parent);
    await _deleteDirectoryIfEmpty(cam3File.parent);
    return deletedCam1 || deletedCam2 || deletedCam3;
  }

  Future<bool> _deleteCleanupFile(File file) async {
    try {
      if (!await file.exists()) return false;
      await file.delete();
      _segments.removeWhere((segment) => segment.path == file.path);
      _notifyVideoChanges();
      return true;
    } catch (error, stackTrace) {
      developer.log(
        '[STORAGE] Unable to delete video: ${file.path}',
        error: error,
        stackTrace: stackTrace,
        name: 'RecordingService',
      );
      return false;
    }
  }

  Future<void> _deleteDirectoryIfEmpty(Directory directory) async {
    try {
      if (!await directory.exists()) return;
      if (!await directory.list().isEmpty) return;
      await directory.delete();
    } catch (_) {}
  }

  Future<void> enforceStorageLimit() {
    final current = _storageLimitOperation;
    if (current != null) return current;

    final operation = _enforceStorageLimitInternal();
    _storageLimitOperation = operation;
    return operation.whenComplete(() {
      if (identical(_storageLimitOperation, operation)) {
        _storageLimitOperation = null;
      }
    });
  }

  Future<void> _enforceStorageLimitInternal() async {
    final root = await _videoRootDirectory();
    final files = <({File file, FileStat stat, String day})>[];
    var total = 0;
    await for (final entity in root.list(recursive: true)) {
      if (entity is! File) continue;
      final lower = entity.path.toLowerCase();
      if (!lower.endsWith('.ts') && !lower.endsWith('.mp4')) continue;
      final normalizedPath = entity.path.replaceAll('\\', '/').toLowerCase();
      if (normalizedPath.contains('/download/')) continue;
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

    DateTime? dayValue(String value) {
      final parts = value.split('-');
      if (parts.length != 3) return null;
      final day = int.tryParse(parts[0]);
      final month = int.tryParse(parts[1]);
      final year = int.tryParse(parts[2]);
      if (day == null || month == null || year == null) return null;
      final result = DateTime(year, month, day);
      if (result.day != day || result.month != month || result.year != year) {
        return null;
      }
      return result;
    }

    files.sort((a, b) {
      final aDay = dayValue(a.day);
      final bDay = dayValue(b.day);
      final byDay = switch ((aDay, bDay)) {
        (final DateTime aValue, final DateTime bValue) => aValue.compareTo(
          bValue,
        ),
        (null, final DateTime _) => -1,
        (final DateTime _, null) => 1,
        _ => 0,
      };
      return byDay != 0 ? byDay : a.stat.modified.compareTo(b.stat.modified);
    });

    String cameraBucket(String path) {
      final normalized = path.replaceAll('\\', '/').toUpperCase();
      final autoCamera = RegExp(r'/AUTOMODE/CAM(\d+)/').firstMatch(normalized);
      if (autoCamera != null) return 'CAM${autoCamera.group(1)}';
      if (normalized.contains('/AUTOMODE/') &&
          !normalized.contains('/AUTOMODE/CAM')) {
        return 'CAM1';
      }
      final camera = RegExp(r'/CAM(\d+)/').firstMatch(normalized);
      if (camera != null) return 'CAM${camera.group(1)}';
      if (RegExp(r'/\d{2}-\d{2}-\d{4}/').hasMatch(normalized)) {
        return 'CAM1';
      }
      return 'DIR:${File(path).parent.path.toUpperCase()}';
    }

    final latestByCamera = <String, ({File file, FileStat stat, String day})>{};
    for (final item in files) {
      final key = cameraBucket(item.file.path);
      final current = latestByCamera[key];
      if (current == null ||
          item.stat.modified.isAfter(current.stat.modified)) {
        latestByCamera[key] = item;
      }
    }
    final protectedPaths = latestByCamera.values
        .map((item) => item.file.path)
        .toSet();
    final recentCutoff = DateTime.now().subtract(recentSegmentProtection);

    Future<void> deleteFile(
      ({File file, FileStat stat, String day}) item,
    ) async {
      try {
        // Một dịch vụ camera khác có thể vừa xóa cùng file trong thư mục dùng
        // chung. Khi đó vẫn loại kích thước đã thống kê khỏi tổng hiện tại.
        if (await item.file.exists()) await item.file.delete();
        total -= item.stat.size;
        if (total < 0) total = 0;
        _segments.removeWhere((segment) => segment.path == item.file.path);
        _notifyVideoChanges();
      } catch (error, stackTrace) {
        developer.log(
          'Unable to delete old video: ${item.file.path}',
          error: error,
          stackTrace: stackTrace,
          name: 'RecordingService',
        );
      }
    }

    // Khi vượt 20 GB, xóa cuốn chiếu từ video cũ nhất.
    for (final item in files) {
      if (total <= storageLimitBytes) break;
      if (protectedPaths.contains(item.file.path) ||
          item.stat.modified.isAfter(recentCutoff)) {
        continue;
      }
      await deleteFile(item);
    }

    // PerformAutoCleanup: nếu bộ nhớ trống dưới 5 GB, xóa AUTOMODE theo từng
    // lô 10 mốc thời gian, tối đa 50 lượt.
    await performAutoCleanup();

    // Sau mỗi chu kỳ dọn dung lượng, xóa đệ quy toàn bộ thư mục ngày hết hạn,
    // bao gồm các trận đấu và thư mục AUTOMODE.
    await removeExpiredData();
    final remainingTotal = await storageSizeBytes();
    final available = await availableStorageBytes();
    final availableText = available == null
        ? 'unknown'
        : '${(available / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    debugPrint(
      '[VNVAR] STORAGE CLEANUP: used='
      '${(remainingTotal / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB / '
      '20 GB, available=$availableText',
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

    await cleanupExportDownloads();
    if (!_videoChanges.isClosed) await _videoChanges.close();

    developer.log('RecordingService disposed', name: 'RecordingService');
  }
}
