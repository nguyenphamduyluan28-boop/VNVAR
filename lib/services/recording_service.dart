import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/return_code.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'video_storage_service.dart';

bool isPublishableVideoProbe({
  required bool hasVideo,
  required double? durationSeconds,
}) => hasVideo && durationSeconds != null && durationSeconds >= 1.0;

bool isDecodableVideoProbe({
  required bool hasVideo,
  required double? durationSeconds,
}) => hasVideo && durationSeconds != null && durationSeconds > 0.05;

bool shouldUsePreviousCheckpointSegment({
  required DateTime? currentStartedAt,
  required DateTime requestedAt,
}) {
  if (currentStartedAt == null || requestedAt.isBefore(currentStartedAt)) {
    return false;
  }
  // Allow for recorder start-up/FFprobe timestamp rounding around the exact
  // one-second publication threshold.
  return requestedAt.difference(currentStartedAt) < const Duration(seconds: 2);
}

({int startMs, int endMs}) checkVarClipRange({
  required DateTime segmentStartedAt,
  required DateTime segmentEndedAt,
  required DateTime requestedAt,
  required Duration lookback,
  Duration keyframeSafetyMargin = Duration.zero,
}) {
  final durationMs = segmentEndedAt
      .difference(segmentStartedAt)
      .inMilliseconds
      .clamp(0, 1 << 31)
      .toInt();
  final requestedOffsetMs = requestedAt
      .difference(segmentStartedAt)
      .inMilliseconds
      .clamp(0, durationMs)
      .toInt();
  final endMs = requestedOffsetMs;
  final requestedWindowMs =
      lookback.inMilliseconds + keyframeSafetyMargin.inMilliseconds;
  final startMs = (endMs - requestedWindowMs).clamp(0, endMs).toInt();
  return (startMs: startMs, endMs: endMs);
}

List<String> fragmentCompanionPaths(String videoPath) {
  final normalized = videoPath.replaceAll('\\', '/');
  if (!normalized.toUpperCase().contains('/FRAGMENTS/') ||
      !normalized.toLowerCase().endsWith('.mp4')) {
    return [videoPath];
  }
  final base = videoPath.substring(0, videoPath.length - 4);
  return [videoPath, '$base.wav', '$base.json'];
}

bool isManagedStorageFilePath(String path) {
  final normalized = path.replaceAll('\\', '/').toLowerCase();
  return normalized.endsWith('.ts') ||
      normalized.endsWith('.mp4') ||
      (normalized.contains('/fragments/') &&
          (normalized.endsWith('.wav') || normalized.endsWith('.json')));
}

/// Converts native/FFmpeg failures into a bounded string safe for a Flutter
/// Text widget. Full command output remains available in debug logs.
String userFacingError(Object error) {
  var message = error.toString().trim();
  message = message.replaceFirst(RegExp(r'^Bad state:\s*'), '');
  final lines = message
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .where((line) => !line.startsWith('ffmpeg version'))
      .where((line) => !line.startsWith('built with '))
      .where((line) => !line.startsWith('configuration:'))
      .toList();
  message = lines.isEmpty ? message : lines.first;
  if (message.length > 240) message = '${message.substring(0, 237)}...';
  return message.isEmpty ? 'Đã xảy ra lỗi không xác định.' : message;
}

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

class TrimInProgressException implements Exception {
  final String message;
  const TrimInProgressException(this.message);

  @override
  String toString() => message;
}

class StorageSafetyException implements Exception {
  final String message;
  const StorageSafetyException(this.message);

  @override
  String toString() => message;
}

class TrimSegmentNotFoundException implements Exception {
  final String message;
  const TrimSegmentNotFoundException(this.message);

  @override
  String toString() => message;
}

class InvalidTrimRangeException implements Exception {
  final String message;
  const InvalidTrimRangeException(this.message);

  @override
  String toString() => message;
}

class TrimProcessingException implements Exception {
  final String message;
  const TrimProcessingException(this.message);

  @override
  String toString() => message;
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
  static const MethodChannel _platformChannel = MethodChannel(
    'vnvar/camera_station_service',
  );
  final String cameraId;

  static const int storageLimitBytes = 20 * 1024 * 1024 * 1024;
  static const int storageDays = 1;
  static const int normalFreeSpaceThresholdBytes = 1 * 1024 * 1024 * 1024;
  static const int matchFreeSpaceThresholdBytes = 1 * 1024 * 1024 * 1024;
  static const int autoCleanupMaxPasses = 50;
  static const int autoCleanupBatchSize = 10;
  static const int hlsEmergencyThresholdBytes = 1 * 1024 * 1024 * 1024;
  static const int minimumStartFreeSpaceBytes = 512 * 1024 * 1024;
  static const Duration recentSegmentProtection = Duration(minutes: 5);

  static String? get _hardwareH264Encoder {
    if (Platform.isAndroid) return 'h264_mediacodec';
    if (Platform.isIOS) return 'h264_videotoolbox';
    return null;
  }

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
  bool _recordAudio = false;

  Timer? _segmentTimer;

  // ============================================================
  // CURRENT SEGMENT
  // ============================================================

  DateTime? _segmentStartedAt;

  String? _currentPath;
  String? _currentAudioPath;
  File? _currentJournal;
  bool _currentSegmentHasAudio = false;

  // ============================================================
  // STATE
  // ============================================================

  bool _recording = false;
  Future<RecordedSegment>? _trimOperation;

  bool _rotating = false;
  bool _lowStorageWarning = false;
  DateTime? _lowStorageWarningSince;
  bool _storageSuspended = false;
  DateTime? _nextStorageRetryAt;

  bool _stopping = false;
  Future<RecordedSegment?>? _stopOperation;
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
  final Map<String, int> _activeFileReaders = <String, int>{};

  bool get recording => _recording;

  bool get rotating => _rotating;

  String _leaseKey(String path) =>
      File(path).absolute.path.replaceAll('\\', '/').toLowerCase();

  /// Prevents retention cleanup from deleting a file while HTTP is reading it.
  void acquireFileRead(String path) {
    final key = _leaseKey(path);
    _activeFileReaders[key] = (_activeFileReaders[key] ?? 0) + 1;
  }

  void releaseFileRead(String path) {
    final key = _leaseKey(path);
    final count = _activeFileReaders[key];
    if (count == null || count <= 1) {
      _activeFileReaders.remove(key);
    } else {
      _activeFileReaders[key] = count - 1;
    }
  }

  bool isFileReadActive(String path) =>
      (_activeFileReaders[_leaseKey(path)] ?? 0) > 0;

  bool _hasActiveReaderUnder(String directoryPath) {
    final directory = _leaseKey(directoryPath);
    final prefix = directory.endsWith('/') ? directory : '$directory/';
    return _activeFileReaders.keys.any(
      (path) => path == directory || path.startsWith(prefix),
    );
  }

  // ============================================================
  // COMPLETED SEGMENTS
  // ============================================================

  final List<RecordedSegment> _segments = [];
  bool _lastCheckpointUsedPrevious = false;
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

  bool get lastCheckpointUsedPrevious => _lastCheckpointUsedPrevious;

  Future<RecordedSegment> trimSegment({
    required String segmentId,
    required int startMs,
    required int endMs,
    bool streamCopy = false,
    int? minimumOutputDurationMs,
  }) {
    if (_trimOperation != null || _exportCleanupOperation != null) {
      return Future<RecordedSegment>.error(
        const TrimInProgressException(
          'Camera Station đang xử lý một video khác.',
        ),
      );
    }
    final operation = _trimSegmentInternal(
      segmentId: segmentId,
      startMs: startMs,
      endMs: endMs,
      streamCopy: streamCopy,
      minimumOutputDurationMs: minimumOutputDurationMs,
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
    required bool streamCopy,
    required int? minimumOutputDurationMs,
  }) async {
    if (startMs < 0 || endMs <= startMs || endMs - startMs < 500) {
      throw const InvalidTrimRangeException('Khoảng cắt video không hợp lệ.');
    }
    final source = findById(segmentId) ?? findByFileName(segmentId);
    if (source == null || !await File(source.path).exists()) {
      throw TrimSegmentNotFoundException(
        'Không tìm thấy video nguồn $segmentId.',
      );
    }
    if (endMs > source.duration.inMilliseconds + 1000) {
      throw const InvalidTrimRangeException(
        'Khoảng cắt vượt quá thời lượng video.',
      );
    }

    File? output;
    try {
      final now = DateTime.now();
      final startedAt = source.startedAt.add(Duration(milliseconds: startMs));
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
      final isTsInput = source.path.toLowerCase().endsWith('.ts');
      final commonArguments = <String>[
        '-y',
        if (isTsInput) ...[
          '-fflags',
          '+genpts+discardcorrupt',
          '-analyzeduration',
          '10000000',
          '-probesize',
          '10000000',
        ],
        '-ss',
        (startMs / 1000).toStringAsFixed(3),
        '-i',
        source.path,
        '-t',
        (durationMs / 1000).toStringAsFixed(3),
        '-map',
        '0:v:0',
        '-map',
        '0:a:0?',
        '-threads',
        '1',
      ];
      final hardwareEncoder = _hardwareH264Encoder;
      var session = await FFmpegKit.executeWithArguments(
        streamCopy
            ? [
                ...commonArguments,
                '-c',
                'copy',
                '-avoid_negative_ts',
                'make_zero',
                '-movflags',
                '+faststart',
                '-f',
                'mp4',
                target.path,
              ]
            : [
                ...commonArguments,
                '-c:v',
                hardwareEncoder ?? 'mpeg4',
                if (hardwareEncoder != null) ...[
                  '-b:v',
                  '8M',
                ] else ...[
                  '-q:v',
                  '4',
                ],
                '-c:a',
                'aac',
                '-b:a',
                '128k',
                '-movflags',
                '+faststart',
                '-f',
                'mp4',
                target.path,
              ],
      );
      var returnCode = await session.getReturnCode();
      var outputProbe = await _probeVideo(target);

      // Nếu streamCopy thất bại hoặc clip xuất ra không thể giải mã/quá ngắn,
      // tự động fallback sang re-encode để không bao giờ làm mất clip Check VAR.
      if (streamCopy &&
          (!ReturnCode.isSuccess(returnCode) ||
              !await target.exists() ||
              await target.length() <= 0 ||
              outputProbe == null ||
              !outputProbe.hasVideo ||
              (outputProbe.durationSeconds ?? 0) < 0.5)) {
        if (await target.exists()) await target.delete();
        developer.log(
          '[FFMPEG] streamCopy trim failed; falling back to re-encode (mpeg4)',
          name: 'RecordingService',
        );
        session = await FFmpegKit.executeWithArguments([
          ...commonArguments,
          '-c:v',
          'mpeg4',
          '-q:v',
          '4',
          '-c:a',
          'aac',
          '-b:a',
          '128k',
          '-movflags',
          '+faststart',
          '-f',
          'mp4',
          target.path,
        ]);
        returnCode = await session.getReturnCode();
        outputProbe = await _probeVideo(target);
      } else if (!streamCopy &&
          hardwareEncoder != null &&
          !ReturnCode.isSuccess(returnCode)) {
        if (await target.exists()) await target.delete();
        developer.log(
          '[FFMPEG] $hardwareEncoder unavailable; falling back to MPEG-4',
          name: 'RecordingService',
        );
        session = await FFmpegKit.executeWithArguments([
          ...commonArguments,
          '-c:v',
          'mpeg4',
          '-q:v',
          '4',
          '-c:a',
          'aac',
          '-b:a',
          '128k',
          '-movflags',
          '+faststart',
          '-f',
          'mp4',
          target.path,
        ]);
        returnCode = await session.getReturnCode();
        outputProbe = await _probeVideo(target);
      }

      if (!ReturnCode.isSuccess(returnCode) ||
          !await target.exists() ||
          await target.length() <= 0) {
        final details = await session.getOutput();
        throw TrimProcessingException(
          'FFmpeg xử lý thất bại: ${details ?? returnCode}',
        );
      }
      final actualDurationSeconds = outputProbe?.durationSeconds;
      if (outputProbe == null ||
          !outputProbe.hasVideo ||
          actualDurationSeconds == null ||
          actualDurationSeconds < 0.5) {
        throw const TrimProcessingException(
          'Clip output has no playable video or valid duration.',
        );
      }
      // Stream-copy may align the beginning to a nearby H.264 keyframe. Use
      // the duration measured from the output instead of claiming that the
      // requested wall-clock range was produced exactly.
      final actualDuration = Duration(
        milliseconds: (actualDurationSeconds * 1000).round(),
      );
      if (minimumOutputDurationMs != null &&
          actualDuration.inMilliseconds + 500 < minimumOutputDurationMs) {
        throw TrimProcessingException(
          'Trimmed clip is shorter than required: '
          '${actualDuration.inMilliseconds}ms/$minimumOutputDurationMs ms.',
        );
      }
      final clip = RecordedSegment(
        id: id,
        cameraId: cameraId,
        path: target.path,
        startedAt: startedAt,
        endedAt: startedAt.add(actualDuration),
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

  Duration? get currentSegmentRemaining {
    final startedAt = _segmentStartedAt;
    if (!_recording || startedAt == null) return null;
    final remaining = _segmentDuration - DateTime.now().difference(startedAt);
    return remaining > Duration.zero ? remaining : Duration.zero;
  }

  String? get currentPath {
    return _currentPath;
  }

  bool get currentSegmentHasAudio => _currentSegmentHasAudio;
  bool get lowStorageWarning => _lowStorageWarning;
  bool get storageSuspended => _storageSuspended;
  bool get storageRetryDue =>
      !_storageSuspended ||
      !DateTime.now().isBefore(
        _nextStorageRetryAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      );

  Future<({String path, int bytes, DateTime startedAt})?>
  currentRecordingProgress() async {
    final path = _currentPath;
    final startedAt = _segmentStartedAt;
    if (!_recording || path == null || startedAt == null) return null;
    final file = File(path);
    try {
      final bytes = await file.exists() ? await file.length() : 0;
      return (path: path, bytes: bytes, startedAt: startedAt);
    } catch (_) {
      return (path: path, bytes: 0, startedAt: startedAt);
    }
  }

  Future<({String? path, int bytes, bool active})?>
  currentAudioProgress() async {
    if (!(Platform.isAndroid || Platform.isIOS) || !_currentSegmentHasAudio) {
      return null;
    }
    try {
      final raw = await _platformChannel.invokeMapMethod<String, dynamic>(
        'getNativeAudioSegmentStatus',
      );
      if (raw == null) return null;
      return (
        path: raw['path'] as String?,
        bytes: (raw['bytes'] as num?)?.toInt() ?? 0,
        active: raw['active'] == true,
      );
    } catch (error, stackTrace) {
      developer.log(
        'Unable to read native audio progress',
        error: error,
        stackTrace: stackTrace,
        name: 'RecordingService',
      );
      return null;
    }
  }

  /// AVPlayer does not reliably open a standalone MPEG-TS file. On iOS,
  /// remux the selected segment to a temporary MP4 without re-encoding. The
  /// permanent `.ts` recording remains unchanged.
  Future<File> preparePlaybackFile(RecordedSegment segment) async {
    final source = File(segment.path);
    if (!Platform.isIOS || !source.path.toLowerCase().endsWith('.ts')) {
      return source;
    }
    if (!await source.exists()) {
      throw FileSystemException('Video không còn tồn tại.', source.path);
    }
    final temporaryRoot = await getTemporaryDirectory();
    final directory = Directory(
      '${temporaryRoot.path}${Platform.pathSeparator}vnvar_playback',
    );
    await directory.create(recursive: true);
    final staleCutoff = DateTime.now().subtract(const Duration(hours: 24));
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      try {
        if ((await entity.stat()).modified.isBefore(staleCutoff)) {
          await entity.delete();
        }
      } catch (_) {}
    }
    final safeId = segment.id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final target = File(
      '${directory.path}${Platform.pathSeparator}$safeId.mp4',
    );
    if (await target.exists()) await target.delete();

    var session = await FFmpegKit.executeWithArguments([
      '-y',
      '-fflags',
      '+genpts+discardcorrupt',
      '-analyzeduration',
      '10000000',
      '-probesize',
      '10000000',
      '-i',
      source.path,
      '-map',
      '0:v:0',
      '-map',
      '0:a:0?',
      '-c',
      'copy',
      '-movflags',
      '+faststart',
      '-avoid_negative_ts',
      'make_zero',
      '-f',
      'mp4',
      target.path,
    ]);
    var code = await session.getReturnCode();
    if (!ReturnCode.isSuccess(code) ||
        !await target.exists() ||
        await target.length() <= 0 ||
        !await _isPlayableVideo(target)) {
      if (await target.exists()) await target.delete();
      // Rebuild timestamps for short iOS segments that AVPlayer cannot open
      // safely after a direct MPEG-TS stream copy. The bundled iOS FFmpeg is
      // built without VideoToolbox, so do not request h264_videotoolbox here.
      session = await FFmpegKit.executeWithArguments([
        '-y',
        '-fflags',
        '+genpts+discardcorrupt',
        '-analyzeduration',
        '10000000',
        '-probesize',
        '10000000',
        '-i',
        source.path,
        '-map',
        '0:v:0',
        '-map',
        '0:a:0?',
        '-c:v',
        'mpeg4',
        '-b:v',
        '8M',
        '-c:a',
        'aac',
        '-b:a',
        '128k',
        '-movflags',
        '+faststart',
        '-avoid_negative_ts',
        'make_zero',
        '-f',
        'mp4',
        target.path,
      ]);
      code = await session.getReturnCode();
    }
    if (!ReturnCode.isSuccess(code) ||
        !await target.exists() ||
        await target.length() <= 0 ||
        !await _isPlayableVideo(target)) {
      final output = await session.getOutput();
      try {
        if (await target.exists()) await target.delete();
      } catch (_) {}
      final conciseOutput = (output ?? code.toString())
          .split('\n')
          .where(
            (line) =>
                line.contains('Error') ||
                line.contains('Invalid') ||
                line.contains('failed') ||
                line.contains('not found'),
          )
          .take(6)
          .join('\n');
      throw StateError(
        'Không thể chuẩn bị video để phát: '
        '${conciseOutput.isEmpty ? code : conciseOutput}',
      );
    }
    return target;
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
      if (_hasActiveReaderUnder(entity.path)) continue;

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
    File? nativeAudio,
  ) async {
    // Dùng ngày kết thúc để segment đi qua 0 giờ không bị lưu vào thư mục ngày
    // cũ rồi bị RemoveExpiredData xóa ngay.
    final directory = await _videoDirectory(date: endedAt);
    final target = File(
      '${directory.path}${Platform.pathSeparator}'
      '${_videoFileName(startedAt: startedAt, endedAt: endedAt)}.ts',
    );
    final hasNativeAudio =
        nativeAudio != null &&
        await nativeAudio.exists() &&
        await nativeAudio.length() > 44;
    final audioInput = hasNativeAudio ? ['-i', nativeAudio.path] : <String>[];
    final audioMap = hasNativeAudio ? '1:a:0?' : '0:a:0?';
    var session = await FFmpegKit.executeWithArguments([
      '-y',
      '-fflags',
      '+genpts+discardcorrupt',
      '-i',
      source.path,
      ...audioInput,
      '-map',
      '0:v:0',
      '-map',
      audioMap,
      '-c:v',
      'copy',
      '-c:a',
      'aac',
      '-b:a',
      '128k',
      '-avoid_negative_ts',
      'make_zero',
      '-muxdelay',
      '0',
      '-muxpreload',
      '0',
      '-mpegts_flags',
      '+resend_headers',
      '-f',
      'mpegts',
      target.path,
    ]);
    var code = await session.getReturnCode();
    if (!ReturnCode.isSuccess(code)) {
      final hardwareEncoder = _hardwareH264Encoder;
      if (hardwareEncoder != null) {
        if (await target.exists()) await target.delete();
        session = await FFmpegKit.executeWithArguments([
          '-y',
          '-fflags',
          '+genpts+discardcorrupt',
          '-i',
          source.path,
          ...audioInput,
          '-map',
          '0:v:0',
          '-map',
          audioMap,
          '-threads',
          '1',
          '-c:v',
          hardwareEncoder,
          '-b:v',
          '8M',
          '-c:a',
          'aac',
          '-b:a',
          '128k',
          '-avoid_negative_ts',
          'make_zero',
          '-muxdelay',
          '0',
          '-muxpreload',
          '0',
          '-mpegts_flags',
          '+resend_headers',
          '-f',
          'mpegts',
          target.path,
        ]);
        code = await session.getReturnCode();
      }
    }
    if (!ReturnCode.isSuccess(code)) {
      if (await target.exists()) await target.delete();
      session = await FFmpegKit.executeWithArguments([
        '-y',
        '-fflags',
        '+genpts+discardcorrupt',
        '-i',
        source.path,
        ...audioInput,
        '-map',
        '0:v:0',
        '-map',
        audioMap,
        '-threads',
        '1',
        '-c:v',
        'mpeg4',
        '-q:v',
        '4',
        '-c:a',
        'aac',
        '-b:a',
        '128k',
        '-avoid_negative_ts',
        'make_zero',
        '-muxdelay',
        '0',
        '-muxpreload',
        '0',
        '-mpegts_flags',
        '+resend_headers',
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
      // Không được bỏ mất đoạn recorder đã ghi chỉ vì bước đóng gói TS lỗi.
      // Giữ nguyên MP4 trong thư mục video để segment vẫn xuất hiện và tải
      // được; lần ghi kế tiếp vẫn có thể tiếp tục bình thường.
      final fallback = File(
        '${directory.path}${Platform.pathSeparator}'
        '${_videoFileName(startedAt: startedAt, endedAt: endedAt)}.mp4',
      );
      if (await fallback.exists()) await fallback.delete();
      if (hasNativeAudio) {
        final muxSession = await FFmpegKit.executeWithArguments([
          '-y',
          '-i',
          source.path,
          '-i',
          nativeAudio.path,
          '-map',
          '0:v:0',
          '-map',
          '1:a:0',
          '-c:v',
          'copy',
          '-c:a',
          'aac',
          '-b:a',
          '128k',
          '-shortest',
          '-movflags',
          '+faststart',
          fallback.path,
        ]);
        final muxCode = await muxSession.getReturnCode();
        if (ReturnCode.isSuccess(muxCode) &&
            await fallback.exists() &&
            await fallback.length() > 0) {
          if (await source.exists()) await source.delete();
          if (await nativeAudio.exists()) await nativeAudio.delete();
          debugPrint('[VNVAR] MP4 WITH AUDIO FALLBACK SAVED: ${fallback.path}');
          return fallback;
        }
        if (await fallback.exists()) await fallback.delete();
      }
      final preserved = await source.copy(fallback.path);
      if (!await preserved.exists() || await preserved.length() <= 0) {
        throw StateError(
          'Không thể lưu đoạn video cuối. '
          'FFmpeg: ${output ?? 'không có thông tin lỗi'}',
        );
      }
      // Giữ lại cặp MP4/WAV staging khi mux audio thất bại. Lần khởi động
      // sau sẽ thử recover lại thay vì xóa WAV hợp lệ và mất cơ hội ghép tiếng.
      if (!hasNativeAudio) {
        if (await source.exists()) await source.delete();
      }
      developer.log(
        'TS conversion failed; preserved original MP4: ${preserved.path}. '
        'FFmpeg: ${output ?? 'no error details'}',
        name: 'RecordingService',
      );
      debugPrint('[VNVAR] MP4 FALLBACK SAVED: ${preserved.path}');
      return preserved;
    }
    if (await source.exists()) await source.delete();
    if (nativeAudio != null && await nativeAudio.exists()) {
      await nativeAudio.delete();
    }
    developer.log(
      'TS SAVED: ${target.path} | ${await target.length()} bytes',
      name: 'RecordingService',
    );
    debugPrint('[VNVAR] TS SAVED: ${target.path}');
    return target;
  }

  Future<bool> _isPlayableVideo(File file) async {
    final probe = await _probeVideo(file);
    return probe != null &&
        isDecodableVideoProbe(
          hasVideo: probe.hasVideo,
          durationSeconds: probe.durationSeconds,
        );
  }

  Future<({bool hasVideo, double? durationSeconds})?> _probeVideo(
    File file,
  ) async {
    try {
      if (!await file.exists() || await file.length() <= 0) return null;
      final session = await FFprobeKit.getMediaInformation(file.path);
      final information = session.getMediaInformation();
      if (information == null) return null;
      final duration = double.tryParse(information.getDuration() ?? '');
      final hasVideo = information.getStreams().any(
        (stream) => stream.getType() == 'video',
      );
      return (hasVideo: hasVideo, durationSeconds: duration);
    } catch (error, stackTrace) {
      developer.log(
        'FFprobe validation failed: ${file.path}',
        error: error,
        stackTrace: stackTrace,
        name: 'RecordingService',
      );
      return null;
    }
  }

  Future<File> _preserveShortFragment({
    required File video,
    required File? audio,
    required DateTime startedAt,
    required DateTime endedAt,
    required double durationSeconds,
  }) async {
    final videoDirectory = await _videoDirectory(date: endedAt);
    final fragmentDirectory = Directory(
      '${videoDirectory.path}${Platform.pathSeparator}FRAGMENTS',
    );
    await fragmentDirectory.create(recursive: true);
    final baseName =
        'FRAGMENT_${startedAt.millisecondsSinceEpoch}_${endedAt.millisecondsSinceEpoch}';
    final preservedVideo = File(
      '${fragmentDirectory.path}${Platform.pathSeparator}$baseName.mp4',
    );
    final temporaryVideo = File('${preservedVideo.path}.partial');
    if (await temporaryVideo.exists()) await temporaryVideo.delete();
    await video.copy(temporaryVideo.path);
    await temporaryVideo.rename(preservedVideo.path);

    String? preservedAudioPath;
    if (audio != null && await audio.exists() && await audio.length() > 44) {
      final preservedAudio = File(
        '${fragmentDirectory.path}${Platform.pathSeparator}$baseName.wav',
      );
      final temporaryAudio = File('${preservedAudio.path}.partial');
      if (await temporaryAudio.exists()) await temporaryAudio.delete();
      await audio.copy(temporaryAudio.path);
      await temporaryAudio.rename(preservedAudio.path);
      preservedAudioPath = preservedAudio.path;
    }

    final metadata = File(
      '${fragmentDirectory.path}${Platform.pathSeparator}$baseName.json',
    );
    await metadata.writeAsString(
      jsonEncode({
        'type': 'VNVAR_PRESERVED_FRAGMENT_V1',
        'cameraId': cameraId,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt.toIso8601String(),
        'durationSeconds': durationSeconds,
        'videoPath': preservedVideo.path,
        'audioPath': preservedAudioPath,
      }),
      flush: true,
    );
    if (await video.exists()) await video.delete();
    if (audio != null && await audio.exists()) await audio.delete();
    developer.log(
      'SHORT FRAGMENT PRESERVED: ${preservedVideo.path}',
      name: 'RecordingService',
    );
    debugPrint('[VNVAR] SHORT FRAGMENT PRESERVED: ${preservedVideo.path}');
    return preservedVideo;
  }

  Future<void> _writeJournalState(
    File? journal,
    String state, {
    String? finalPath,
    String? error,
  }) async {
    if (journal == null) return;
    try {
      var values = <String, dynamic>{};
      if (await journal.exists()) {
        final decoded = jsonDecode(await journal.readAsString());
        if (decoded is Map<String, dynamic>) values = decoded;
      }
      values['state'] = state;
      values['updatedAtMs'] = DateTime.now().millisecondsSinceEpoch;
      if (finalPath != null) values['finalPath'] = finalPath;
      if (error != null) values['error'] = error;
      await journal.writeAsString(jsonEncode(values), flush: true);
    } catch (journalError, stackTrace) {
      developer.log(
        'Unable to update recording journal: $state',
        error: journalError,
        stackTrace: stackTrace,
        name: 'RecordingService',
      );
    }
  }

  // ============================================================
  // START RECORDING
  // ============================================================

  Future<void> start({
    required MediaStreamTrack videoTrack,
    bool audioAvailable = true,
  }) async {
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
    // Both mobile platforms record microphone PCM beside the WebRTC video and
    // mux it while finalizing. iOS uses AVAudioRecorder because a local WebRTC
    // track does not expose microphone PCM through RTCAudioRenderer.
    _recordAudio = Platform.isAndroid || (Platform.isIOS && audioAvailable);

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
      _recordAudio = false;

      _segmentTimer?.cancel();

      _segmentTimer = null;

      debugPrint('[VNVAR] RECORDER START FAILED: $error');
      debugPrintStack(stackTrace: stackTrace);

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

    await _ensureFreeSpaceForNewSegment();

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

    try {
      await recorder.start(
        path,
        videoTrack: videoTrack,
        audioChannel: _recordAudio && !Platform.isAndroid && !Platform.isIOS
            ? RecorderAudioChannel.INPUT
            : null,
      );
    } catch (_) {
      // Dọn native recorder/file khởi tạo dở trước khi caller thử fallback.
      try {
        await recorder.stop();
      } catch (_) {}
      final partial = File(path);
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      rethrow;
    }

    _recorder = recorder;

    _currentPath = path;
    _currentJournal = File('$path.json');
    try {
      await _currentJournal!.writeAsString(
        jsonEncode({
          'cameraId': cameraId,
          'startedAtMs': now.millisecondsSinceEpoch,
          'videoPath': path,
          'audioPath': _recordAudio && (Platform.isAndroid || Platform.isIOS)
              ? path.replaceFirst(RegExp(r'\.mp4$'), '.wav')
              : null,
          'state': 'recording',
        }),
        flush: true,
      );
    } catch (error, stackTrace) {
      developer.log(
        'Unable to write recording journal',
        error: error,
        stackTrace: stackTrace,
        name: 'RecordingService',
      );
    }

    _segmentStartedAt = now;
    _currentSegmentHasAudio = false;
    if (_recordAudio && (Platform.isAndroid || Platform.isIOS)) {
      final audioPath = path.replaceFirst(RegExp(r'\.mp4$'), '.wav');
      try {
        await _platformChannel.invokeMethod<void>('startNativeAudioSegment', {
          'path': audioPath,
        });
        _currentAudioPath = audioPath;
        _currentSegmentHasAudio = true;
        debugPrint('[VNVAR] NATIVE AUDIO STARTED: $audioPath');
      } catch (error, stackTrace) {
        _currentAudioPath = null;
        _currentSegmentHasAudio = false;
        final microphonePermissionDenied =
            error is PlatformException &&
            error.code == 'MICROPHONE_PERMISSION_DENIED';
        if (microphonePermissionDenied) {
          developer.log(
            'Microphone permission denied; continuing with video-only segment.',
            name: 'RecordingService',
          );
          debugPrint('[VNVAR] MICROPHONE PERMISSION DENIED: VIDEO-ONLY');
          _notifyVideoChanges();
          debugPrint(
            '[VNVAR] RECORDER STARTED: $path | '
            'audio=off | microphoneRequested=on',
          );
          return;
        }
        if (Platform.isIOS) {
          // Calls, route changes and another audio app can temporarily own the
          // iOS audio session. Keep the court video instead of tearing down the
          // complete capture pipeline; the next segment retries microphone.
          try {
            final partialAudio = File(audioPath);
            if (await partialAudio.exists()) await partialAudio.delete();
          } catch (_) {}
          developer.log(
            'iOS microphone temporarily unavailable; continuing video-only.',
            error: error,
            stackTrace: stackTrace,
            name: 'RecordingService',
          );
          debugPrint('[VNVAR] IOS AUDIO UNAVAILABLE: VIDEO-ONLY');
          _notifyVideoChanges();
          return;
        }
        _recording = false;
        _recorder = null;
        _currentPath = null;
        _segmentStartedAt = null;
        final journal = _currentJournal;
        _currentJournal = null;
        try {
          await _platformChannel.invokeMethod<void>('stopNativeAudioSegment');
        } catch (_) {}
        try {
          await recorder.stop();
        } catch (_) {}
        for (final partial in <File>[File(path), File(audioPath), ?journal]) {
          try {
            if (await partial.exists()) await partial.delete();
          } catch (_) {}
        }
        developer.log(
          'Native microphone recording unavailable; rejecting video segment.',
          error: error,
          stackTrace: stackTrace,
          name: 'RecordingService',
        );
        debugPrint('[VNVAR] NATIVE AUDIO START FAILED: $error');
        _notifyVideoChanges();
        throw StateError('Microphone bắt buộc nhưng không thể bắt đầu: $error');
      }
    }
    _notifyVideoChanges();
    debugPrint(
      '[VNVAR] RECORDER STARTED: $path | '
      'audio=${_currentSegmentHasAudio ? 'on' : 'off'} | '
      'microphoneRequested=${_recordAudio ? 'on' : 'unsupported'}',
    );
  }

  Future<void> _ensureFreeSpaceForNewSegment() async {
    var available = await availableStorageBytes();
    if (available == null || available >= normalFreeSpaceThresholdBytes) {
      _setStorageSuspended(false);
      return;
    }

    // Publish the normal 1 GB warning first. Below 512 MB the grace period is
    // bypassed: starting another MP4 is more likely to produce a corrupt file
    // than to preserve useful footage.
    await enforceStorageLimit();
    available = await availableStorageBytes();
    if (available != null && available < minimumStartFreeSpaceBytes) {
      await performAutoCleanup();
      available = await availableStorageBytes();
    }
    if (available != null && available < minimumStartFreeSpaceBytes) {
      _setStorageSuspended(true);
      throw StorageSafetyException(
        'Không đủ dung lượng an toàn để bắt đầu segment mới '
        '(${(available / (1024 * 1024)).toStringAsFixed(0)} MB còn trống).',
      );
    }
    _setStorageSuspended(false);
  }

  void _setStorageSuspended(bool value) {
    if (value) {
      _nextStorageRetryAt = DateTime.now().add(const Duration(minutes: 2));
    } else {
      _nextStorageRetryAt = null;
    }
    if (_storageSuspended == value) return;
    _storageSuspended = value;
    debugPrint('[VNVAR] STORAGE RECORDING ${value ? 'SUSPENDED' : 'RESUMED'}');
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

  Future<RecordedSegment> checkpointCurrentSegment({
    Future<void> Function()? onRecorderStopped,
  }) async {
    if (!_recording) {
      throw StateError('Camera chưa bắt đầu ghi video.');
    }
    _lastCheckpointUsedPrevious = false;
    final checkpointRequestedAt = DateTime.now();
    final currentStartedAt = _segmentStartedAt;
    final previousSegment = _segments.isEmpty ? null : _segments.last;
    Object? handoffError;
    StackTrace? handoffStackTrace;
    final segment = await _requestSegmentRotation(
      onRecorderStopped: onRecorderStopped == null
          ? null
          : () async {
              try {
                await onRecorderStopped();
              } catch (error, stackTrace) {
                handoffError = error;
                handoffStackTrace = stackTrace;
                rethrow;
              }
            },
    );
    if (handoffError != null) {
      Error.throwWithStackTrace(handoffError!, handoffStackTrace!);
    }
    if (segment == null) {
      // A Check VAR press can land immediately after the periodic recorder
      // rotation. The new file may contain less than one publishable second,
      // while the relevant action is still at the end of the previous file.
      // Return that completed file instead of exposing the aborted fragment or
      // failing the request. Other rotation paths continue to reject it.
      final requestedDuringFreshSegment = shouldUsePreviousCheckpointSegment(
        currentStartedAt: currentStartedAt,
        requestedAt: checkpointRequestedAt,
      );
      if (requestedDuringFreshSegment &&
          previousSegment != null &&
          await File(previousSegment.path).exists()) {
        developer.log(
          'CHECK VAR landed on a sub-second segment; using previous segment: '
          '${previousSegment.fileName}',
          name: 'RecordingService',
        );
        _lastCheckpointUsedPrevious = true;
        return previousSegment;
      }
      throw StateError('Không có file đang quay để chốt Check VAR.');
    }
    return segment;
  }

  Future<RecordedSegment?> _requestSegmentRotation({
    Future<void> Function()? onRecorderStopped,
  }) async {
    final current = _rotationOperation;
    if (current != null) {
      final segment = await current;
      // The current rotation has already opened its next recorder, so the
      // caller can safely change the source on the same VideoTrack.
      if (onRecorderStopped != null) await onRecorderStopped();
      return segment;
    }

    final operation = _performSegmentRotation(
      onRecorderStopped: onRecorderStopped,
    );
    _rotationOperation = operation;
    return operation.whenComplete(() {
      if (identical(_rotationOperation, operation)) {
        _rotationOperation = null;
      }
    });
  }

  Future<RecordedSegment?> _performSegmentRotation({
    Future<void> Function()? onRecorderStopped,
  }) async {
    if (!_recording) return null;

    _rotating = true;
    _segmentTimer?.cancel();
    _segmentTimer = null;
    try {
      final segment = await _finishCurrentSegment(
        onRecorderStopped: () async {
          if (onRecorderStopped != null) await onRecorderStopped();
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
    final audioPath = _currentAudioPath;
    final journal = _currentJournal;

    // Clear trước để tránh stop gọi hai lần.
    _recorder = null;

    _currentPath = null;

    _segmentStartedAt = null;
    _currentAudioPath = null;
    _currentJournal = null;
    _currentSegmentHasAudio = false;
    _notifyVideoChanges();

    if (recorder == null || path == null || startedAt == null) {
      return null;
    }

    developer.log('Finishing segment: $path', name: 'RecordingService');
    // Capture the boundary and ask both recorders to stop before awaiting any
    // journal/filesystem work. Previously WAV finalization ran first, so the
    // video recorder kept accepting frames for several extra seconds and a
    // configured 3-minute file could become 3:05 or 3:06.
    var endedAt = DateTime.now();
    Object? capturedRecorderStopError;
    StackTrace? capturedRecorderStopStack;
    final videoStopFuture = Future<void>.sync(() async {
      try {
        await recorder.stop();
      } catch (error, stackTrace) {
        capturedRecorderStopError = error;
        capturedRecorderStopStack = stackTrace;
        developer.log(
          'MediaRecorder.stop failed; attempting to recover the recorded file.',
          error: error,
          stackTrace: stackTrace,
          name: 'RecordingService',
        );
        debugPrint('[VNVAR] RECORDER STOP ERROR, RECOVERING FILE: $error');
      }
    });
    final audioStopFuture = Future<void>.sync(() async {
      if (!(Platform.isAndroid || Platform.isIOS) || audioPath == null) return;
      try {
        await _platformChannel.invokeMethod<void>('stopNativeAudioSegment');
        debugPrint('[VNVAR] NATIVE AUDIO STOPPED: $audioPath');
      } catch (error, stackTrace) {
        developer.log(
          'Unable to stop native audio segment cleanly.',
          error: error,
          stackTrace: stackTrace,
          name: 'RecordingService',
        );
        debugPrint('[VNVAR] NATIVE AUDIO STOP FAILED: $error');
      }
    });

    try {
      await _writeJournalState(journal, 'finalizing');
    } catch (error, stackTrace) {
      developer.log(
        'Unable to mark the recording journal as finalizing.',
        error: error,
        stackTrace: stackTrace,
        name: 'RecordingService',
      );
    }

    await Future.wait<void>([videoStopFuture, audioStopFuture]);

    // ==========================================================
    // STOP RECORDER
    // ==========================================================

    Object? recorderStopError;
    StackTrace? recorderStopStack;
    try {
      await videoStopFuture;
    } catch (error, stackTrace) {
      // Một số codec Android/Unisoc ném lỗi khi drain buffer cuối dù container
      // MP4 đã được ghi ra đĩa. Không bỏ segment ngay tại đây; chờ filesystem
      // ổn định rồi xác thực file và tiếp tục lưu nếu dữ liệu vẫn hợp lệ.
      recorderStopError = error;
      recorderStopStack = stackTrace;
      developer.log(
        'MediaRecorder.stop failed; attempting to recover the recorded file.',
        error: error,
        stackTrace: stackTrace,
        name: 'RecordingService',
      );
      debugPrint('[VNVAR] RECORDER STOP ERROR, RECOVERING FILE: $error');
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    recorderStopError ??= capturedRecorderStopError;
    recorderStopStack ??= capturedRecorderStopStack;
    if (capturedRecorderStopError != null) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

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

      if (recorderStopError != null) {
        Error.throwWithStackTrace(recorderStopError, recorderStopStack!);
      }
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

      if (recorderStopError != null) {
        Error.throwWithStackTrace(recorderStopError, recorderStopStack!);
      }
      return null;
    }

    final videoProbe = await _probeVideo(file);
    if (videoProbe == null ||
        !isDecodableVideoProbe(
          hasVideo: videoProbe.hasVideo,
          durationSeconds: videoProbe.durationSeconds,
        )) {
      await _writeJournalState(
        journal,
        'invalid',
        error: 'FFprobe found no playable video stream',
      );
      developer.log(
        'Recorded segment is not playable and remains in staging for forensic recovery: $path',
        name: 'RecordingService',
      );
      return null;
    }
    // File names, API metadata and cleanup decisions must use the encoded
    // media timeline, not time spent draining the recorder or probing files.
    endedAt = startedAt.add(
      Duration(milliseconds: (videoProbe.durationSeconds! * 1000).round()),
    );

    if (!isPublishableVideoProbe(
      hasVideo: videoProbe.hasVideo,
      durationSeconds: videoProbe.durationSeconds,
    )) {
      final preserved = await _preserveShortFragment(
        video: file,
        audio: audioPath == null ? null : File(audioPath),
        startedAt: startedAt,
        endedAt: endedAt,
        durationSeconds: videoProbe.durationSeconds!,
      );
      await _writeJournalState(
        journal,
        'short_preserved',
        finalPath: preserved.path,
      );
      if (journal != null && await journal.exists()) await journal.delete();
      return null;
    }

    if (recorderStopError != null) {
      debugPrint('[VNVAR] RECORDER FILE RECOVERED: $path | $fileSize bytes');
    }

    file = await _convertRecordingToTs(
      file,
      startedAt,
      endedAt,
      audioPath == null ? null : File(audioPath),
    );

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

    try {
      await _writeJournalState(journal, 'completed', finalPath: file.path);
      if (journal != null && await journal.exists()) await journal.delete();
    } catch (_) {}

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
        await for (final entity in directory.list(recursive: true)) {
          if (entity is File && !isFileReadActive(entity.path)) {
            await entity.delete();
          }
        }
        await _deleteDirectoryTreeIfEmpty(directory);
      }
      _exportSegments.removeWhere(
        (_, segment) => !isFileReadActive(segment.path),
      );
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

  /// Cleans only recorder staging files. This is safe to call while the
  /// station is running and avoids rebuilding the permanent video index.
  Future<void> cleanupStagingFiles({
    Duration maxAge = const Duration(hours: 24),
  }) async {
    await _cleanupAbandonedRecordings(maxAge: maxAge);
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
        final fileName = entity.uri.pathSegments.last;
        final prefix = '${cameraId}_';
        final timestampText = fileName
            .replaceFirst(prefix, '')
            .replaceFirst(RegExp(r'\.mp4$', caseSensitive: false), '');
        final timestamp = int.tryParse(timestampText);
        if (fileName.startsWith(prefix) && timestamp != null && stat.size > 0) {
          final journal = File('${entity.path}.json');
          if (await journal.exists()) {
            try {
              final decoded = jsonDecode(await journal.readAsString());
              if (decoded is Map<String, dynamic> &&
                  decoded['state'] == 'invalid') {
                if (now.difference(stat.modified) >= maxAge) {
                  await entity.delete();
                  await journal.delete();
                }
                continue;
              }
            } catch (_) {
              // A damaged journal does not prove the media is damaged; FFprobe
              // below remains the source of truth.
            }
          }
          await _writeJournalState(journal, 'recovering');
          final recoveredProbe = await _probeVideo(entity);
          if (recoveredProbe == null ||
              !isDecodableVideoProbe(
                hasVideo: recoveredProbe.hasVideo,
                durationSeconds: recoveredProbe.durationSeconds,
              )) {
            await _writeJournalState(
              journal,
              'invalid',
              error: 'FFprobe found no playable video stream after crash',
            );
            if (now.difference(stat.modified) >= maxAge) {
              await entity.delete();
            }
            continue;
          }
          final startedAt = DateTime.fromMillisecondsSinceEpoch(timestamp);
          final endedAt = stat.modified.isAfter(startedAt)
              ? stat.modified
              : startedAt;
          final wav = File(
            entity.path.replaceFirst(
              RegExp(r'\.mp4$', caseSensitive: false),
              '.wav',
            ),
          );
          if (!isPublishableVideoProbe(
            hasVideo: recoveredProbe.hasVideo,
            durationSeconds: recoveredProbe.durationSeconds,
          )) {
            await _preserveShortFragment(
              video: entity,
              audio: await wav.exists() ? wav : null,
              startedAt: startedAt,
              endedAt: endedAt,
              durationSeconds: recoveredProbe.durationSeconds!,
            );
            if (await journal.exists()) await journal.delete();
            continue;
          }
          final recovered = await _convertRecordingToTs(
            entity,
            startedAt,
            endedAt,
            await wav.exists() ? wav : null,
          );
          await _writeJournalState(
            journal,
            'completed',
            finalPath: recovered.path,
          );
          if (await journal.exists()) await journal.delete();
          debugPrint(
            '[VNVAR] ABANDONED RECORDING RECOVERED: ${recovered.path}',
          );
          continue;
        }
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

    // WAV không còn MP4 cùng tên không thể mux; xóa sau maxAge để cache không
    // tăng vô hạn sau crash hoặc lỗi filesystem.
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.wav')) {
        continue;
      }
      if (_currentAudioPath == entity.path) continue;
      try {
        final mp4 = File(
          entity.path.replaceFirst(
            RegExp(r'\.wav$', caseSensitive: false),
            '.mp4',
          ),
        );
        final stat = await entity.stat();
        if (!await mp4.exists() && now.difference(stat.modified) >= maxAge) {
          await entity.delete();
        }
      } catch (error, stackTrace) {
        developer.log(
          '[STORAGE] Unable to remove abandoned audio: ${entity.path}',
          error: error,
          stackTrace: stackTrace,
          name: 'RecordingService',
        );
      }
    }
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.json')) {
        continue;
      }
      if (_currentJournal?.path == entity.path) continue;
      try {
        final stat = await entity.stat();
        if (now.difference(stat.modified) >= maxAge) await entity.delete();
      } catch (error, stackTrace) {
        developer.log(
          '[STORAGE] Unable to remove stale recording journal: ${entity.path}',
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
      if (entity is File && isManagedStorageFilePath(entity.path)) {
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
        if (_hasActiveReaderUnder(match.directory.path)) continue;
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
      if (isFileReadActive(file.path)) return false;
      if (!await file.exists()) return false;
      for (final path in fragmentCompanionPaths(file.path)) {
        final companion = File(path);
        if (await companion.exists()) await companion.delete();
      }
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

  Future<void> _deleteDirectoryTreeIfEmpty(Directory directory) async {
    if (!await directory.exists()) return;
    final children = await directory.list().toList();
    for (final child in children.whereType<Directory>()) {
      await _deleteDirectoryTreeIfEmpty(child);
    }
    await _deleteDirectoryIfEmpty(directory);
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
    final availableBefore = await availableStorageBytes();
    final lowStorage =
        availableBefore != null &&
        availableBefore < normalFreeSpaceThresholdBytes;
    if (availableBefore == null ||
        availableBefore >= minimumStartFreeSpaceBytes) {
      _setStorageSuspended(false);
    }
    if (lowStorage != _lowStorageWarning) {
      _lowStorageWarning = lowStorage;
      _lowStorageWarningSince = lowStorage ? DateTime.now() : null;
      debugPrint(
        '[VNVAR] STORAGE WARNING: ${lowStorage ? 'low space; cleanup may delete old videos' : 'space recovered'}',
      );
      _notifyVideoChanges();
    }
    // Give the operator one cleanup cycle to react to the warning before
    // deleting any old recording. Subsequent cycles enforce the limit.
    if (lowStorage &&
        DateTime.now().difference(_lowStorageWarningSince ?? DateTime.now()) <
            const Duration(minutes: 1)) {
      return;
    }
    final root = await _videoRootDirectory();
    final files = <({File file, FileStat stat, String day})>[];
    var total = 0;
    await for (final entity in root.list(recursive: true)) {
      if (entity is! File) continue;
      final lower = entity.path.toLowerCase();
      final normalizedPath = entity.path.replaceAll('\\', '/').toLowerCase();
      if (normalizedPath.contains('/download/')) continue;
      try {
        final stat = await entity.stat();
        if (isManagedStorageFilePath(entity.path)) total += stat.size;
        if (!lower.endsWith('.ts') && !lower.endsWith('.mp4')) continue;
        final normalized = entity.path.replaceAll('\\', '/');
        final match = RegExp(
          r'/([0-9]{2}-[0-9]{2}-[0-9]{4})/',
        ).firstMatch(normalized);
        files.add((file: entity, stat: stat, day: match?.group(1) ?? ''));
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
        if (isFileReadActive(item.file.path)) return;
        // Một dịch vụ camera khác có thể vừa xóa cùng file trong thư mục dùng
        // chung. Khi đó vẫn loại kích thước đã thống kê khỏi tổng hiện tại.
        var deletedBytes = 0;
        for (final path in fragmentCompanionPaths(item.file.path)) {
          final companion = File(path);
          if (!await companion.exists()) continue;
          deletedBytes += await companion.length();
          await companion.delete();
        }
        total -= deletedBytes;
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

    // PerformAutoCleanup: nếu bộ nhớ trống dưới 1 GB, xóa AUTOMODE theo từng
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

  Future<RecordedSegment?> stop() {
    final current = _stopOperation;
    if (current != null) return current;

    final operation = _stopInternal();
    _stopOperation = operation;
    return operation.whenComplete(() {
      if (identical(_stopOperation, operation)) _stopOperation = null;
    });
  }

  Future<RecordedSegment?> _stopInternal() async {
    _stopping = true;
    RecordedSegment? rotatedSegment;

    try {
      // ========================================================
      // STOP TIMER FIRST
      // ========================================================

      _segmentTimer?.cancel();

      _segmentTimer = null;

      if (!_recording && _rotationOperation == null && _recorder == null) {
        return null;
      }

      // Chờ đúng thao tác rotation/finalize đang chạy. Không dùng timeout vì
      // chuyển MP4 sang TS có thể mất hơn 10 giây trên thiết bị chậm. Trả về
      // sớm sẽ khiến runtime dispose camera khi segment cuối chưa hoàn tất.
      final rotation = _rotationOperation;
      if (rotation != null) {
        try {
          rotatedSegment = await rotation;
        } catch (error, stackTrace) {
          // Rotation có thể đã đóng recorder nhưng lỗi ở bước chuyển đổi. Vẫn
          // tiếp tục chốt recorder hiện tại (nếu có) và dọn trạng thái stop.
          developer.log(
            'Segment rotation failed while stopping recording.',
            error: error,
            stackTrace: stackTrace,
            name: 'RecordingService',
          );
        }
      }

      _recording = false;

      // ========================================================
      // SAVE LAST PARTIAL SEGMENT
      //
      // Ví dụ camera dừng sau 01:42
      // thì vẫn lưu đoạn 1 phút 42 giây cuối.
      // ========================================================

      final finalSegment = await _finishCurrentSegment();

      developer.log('Recording stopped', name: 'RecordingService');
      return finalSegment ?? rotatedSegment;
    } finally {
      _recording = false;
      _videoTrack = null;
      _recordAudio = false;
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
    _recordAudio = false;

    await cleanupExportDownloads();
    if (!_videoChanges.isClosed) await _videoChanges.close();

    developer.log('RecordingService disposed', name: 'RecordingService');
  }
}
