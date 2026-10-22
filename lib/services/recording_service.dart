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
import 'package:ffmpeg_kit_flutter_new_video/session.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_cleanup.dart';
import 'station_errors.dart';
import 'station_platform_events.dart';
import 'video_storage_service.dart';

bool isPublishableVideoProbe({
  required bool hasVideo,
  required double? durationSeconds,
}) => hasVideo && durationSeconds != null && durationSeconds >= 1.0;

bool isDecodableVideoProbe({
  required bool hasVideo,
  required double? durationSeconds,
}) => hasVideo && durationSeconds != null && durationSeconds > 0.05;

/// Tính toán góc xoay hiệu dụng cần áp dụng cho video.
/// Khi quay camera selfie trước (cả trên iOS lẫn Android khi ghi raw buffer từ WebRTC),
/// cảm biến quang học có hướng quét ngược 180° so với camera sau, làm video bị lật ngược chân.
/// Do đó cần bù 180° kết hợp góc xoay từ UI (quarterTurns).
int calculateEffectiveVideoRotation({
  required bool isIos,
  required String facingMode,
  required int quarterTurns,
}) {
  var degrees = 0;
  if (facingMode.trim().toLowerCase() == 'user') {
    degrees += 180;
  }
  degrees += (quarterTurns % 4) * 90;
  return (degrees % 360 + 360) % 360;
}

/// Returns the real recorder boundary used by file names and API metadata.
///
/// Camera/WebRTC timestamps can jump after an interruption, camera switch or
/// foreground resume. FFprobe then reports a media duration much longer than
/// the time for which this recorder was actually open. The probe duration is
/// still useful for validating the file, but it must not move the wall-clock
/// end of a segment.
DateTime segmentBoundaryEndedAt({
  required DateTime startedAt,
  required DateTime recorderStoppedAt,
}) {
  if (recorderStoppedAt.isBefore(startedAt)) return startedAt;
  return recorderStoppedAt;
}

Future<bool> waitForRecordingFileToSettle(
  File file, {
  Duration timeout = const Duration(seconds: 5),
  Duration pollInterval = const Duration(milliseconds: 100),
  int requiredStableSamples = 5,
}) async {
  if (requiredStableSamples < 1) {
    throw ArgumentError.value(requiredStableSamples, 'requiredStableSamples');
  }
  final deadline = DateTime.now().add(timeout);
  int? previousSize;
  var stableSamples = 0;
  while (DateTime.now().isBefore(deadline)) {
    try {
      final size = (await file.stat()).size;
      if (size > 0 && size == previousSize) {
        stableSamples++;
        if (stableSamples >= requiredStableSamples) return true;
      } else {
        stableSamples = 0;
      }
      previousSize = size;
    } on FileSystemException {
      stableSamples = 0;
      previousSize = null;
    }
    await Future<void>.delayed(pollInterval);
  }
  return false;
}

Duration nextSegmentRotationDelay({
  required DateTime startedAt,
  required DateTime now,
  required Duration segmentDuration,
}) {
  final remaining = segmentDuration - now.difference(startedAt);
  return remaining > Duration.zero
      ? remaining
      : const Duration(milliseconds: 100);
}

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

/// Mốc in/out (giây, theo dấu thời gian tuyệt đối của từng file) cho concat
/// demuxer khi ghép phần cuối [precedingMs] của segment trước với segment
/// hiện tại. `inpoint`/`outpoint` của concat demuxer tính theo dấu thời gian
/// trong file (gồm `start_time`, với TS thường ~0,5–1,4 s), còn nhánh một
/// file dùng `-ss` tương đối từ đầu file: phải cộng `start_time` thật để hai
/// nhánh cắt cùng một mốc. Thiếu/không hợp lệ `start_time` của một trong hai
/// file → null (caller dùng `-ss`/`-t` tương đối trên đầu vào concat).
({double inpoint, double outpoint})? concatTrimPoints({
  required double? precedingStartTimeSeconds,
  required double? currentStartTimeSeconds,
  required int precedingMs,
  required int effectiveStartMs,
  required int endMs,
}) {
  final previousStart = precedingStartTimeSeconds;
  final currentStart = currentStartTimeSeconds;
  if (previousStart == null ||
      currentStart == null ||
      !previousStart.isFinite ||
      !currentStart.isFinite ||
      previousStart < 0 ||
      currentStart < 0) {
    return null;
  }
  final inOffsetMs = (precedingMs + effectiveStartMs).clamp(0, precedingMs);
  return (
    inpoint: previousStart + inOffsetMs / 1000,
    outpoint: currentStart + endMs / 1000,
  );
}

/// `start_time` (giây) đọc từ FFprobe; null khi thiếu hoặc không phải số.
double? parseProbeStartTime(String? value) {
  final parsed = double.tryParse(value?.trim() ?? '');
  if (parsed == null || !parsed.isFinite || parsed < 0) return null;
  return parsed;
}

/// Thư mục con chứa file tạm khi ghi (MP4/WAV staging, journal).
const String recordingStagingFolderName = 'vnvar_recording';

/// Thư mục staging chính: trong Application Support (Android/iOS không tự
/// xoá như cache). Không lấy được Application Support thì dùng cache như
/// trước. Trả null nếu không có thư mục nào.
String? recordingStagingDirectoryPath({
  required String? supportPath,
  required String? temporaryPath,
  String separator = '/',
}) {
  final base = (supportPath != null && supportPath.trim().isNotEmpty)
      ? supportPath
      : temporaryPath;
  if (base == null || base.trim().isEmpty) return null;
  return '$base$separator$recordingStagingFolderName';
}

/// Các thư mục staging cần quét khi dọn/khôi phục: thư mục chính và thư mục
/// cũ trong cache (bản cũ ghi ở đó), không trùng lặp, thư mục chính trước.
List<String> recordingStagingScanPaths({
  required String? supportPath,
  required String? temporaryPath,
  String separator = '/',
}) {
  final result = <String>[];
  String normalized(String path) => path.replaceAll('\\', '/').toLowerCase();
  void add(String? path) {
    if (path == null) return;
    if (result.any((item) => normalized(item) == normalized(path))) return;
    result.add(path);
  }

  add(
    recordingStagingDirectoryPath(
      supportPath: supportPath,
      temporaryPath: temporaryPath,
      separator: separator,
    ),
  );
  if (temporaryPath != null && temporaryPath.trim().isNotEmpty) {
    add('$temporaryPath$separator$recordingStagingFolderName');
  }
  return result;
}

/// File staging vừa được sửa gần đây có thể đang được recorder/FFmpeg ghi
/// (segment vừa mở sau khi lượt dọn bắt đầu): không khôi phục/xoá.
const Duration recentStagingFileProtection = Duration(seconds: 30);

bool isRecentlyModifiedStagingFile({
  required DateTime modified,
  required DateTime now,
  Duration protection = recentStagingFileProtection,
}) => now.difference(modified) < protection;

/// Cách xử lý dung lượng trước khi mở segment mới.
enum NewSegmentStorageAction {
  /// Đủ chỗ: mở recorder.
  open,

  /// Dưới mức cảnh báo nhưng vẫn trên mức chặn: mở recorder NGAY, dọn dung
  /// lượng chạy nền (không tạo khoảng trống không ghi).
  openThenCleanup,

  /// Thư mục video dưới mức chặn: dọn trước (bắt buộc) rồi xét lại.
  cleanupFirst,

  /// Ổ chứa file tạm (khác ổ video) dưới mức chặn: xoá video không giúp gì,
  /// treo ghi.
  suspendStaging,
}

NewSegmentStorageAction newSegmentStorageAction({
  required int? videoAvailableBytes,
  required int? stagingAvailableBytes,
  required int warningBytes,
  required int minimumBytes,
}) {
  final video = videoAvailableBytes;
  if (video != null && video < minimumBytes) {
    return NewSegmentStorageAction.cleanupFirst;
  }
  final staging = stagingAvailableBytes;
  if (staging != null && staging < minimumBytes) {
    return NewSegmentStorageAction.suspendStaging;
  }
  if (video != null && video < warningBytes) {
    return NewSegmentStorageAction.openThenCleanup;
  }
  return NewSegmentStorageAction.open;
}

/// Sau mỗi segment: có cần quét toàn bộ cây thư mục lưu (giới hạn 20 GB,
/// dọn theo ngày) hay chỉ cộng dồn ước lượng. Quét đầy đủ khi chưa có ước
/// lượng, gần chạm giới hạn (≥ 90%), đang thiếu dung lượng, sang ngày mới
/// (dọn thư mục ngày hết hạn) hoặc lần quét đầy đủ gần nhất đã quá
/// [maximumInterval].
bool shouldRunFullStorageScanAfterSegment({
  required int? estimatedManagedBytes,
  required int storageLimitBytes,
  required bool lowStorage,
  required DateTime? lastFullScanAt,
  required DateTime now,
  Duration maximumInterval = const Duration(minutes: 10),
}) {
  final estimate = estimatedManagedBytes;
  if (estimate == null || lastFullScanAt == null || lowStorage) return true;
  if (estimate >= storageLimitBytes * 0.9) return true;
  if (lastFullScanAt.year != now.year ||
      lastFullScanAt.month != now.month ||
      lastFullScanAt.day != now.day) {
    return true;
  }
  return now.difference(lastFullScanAt) >= maximumInterval ||
      now.isBefore(lastFullScanAt);
}

/// Segment ghi liền ngay trước [current] (cùng camera, file `.ts`, khoảng hở
/// ≤ [maxGap]). Dùng để clip Check VAR lấy đủ thời gian trước sự kiện khi
/// trọng tài bấm ngay sau lúc chuyển segment.
RecordedSegment? selectPrecedingSegment(
  Iterable<RecordedSegment> segments,
  RecordedSegment current, {
  Duration maxGap = const Duration(seconds: 3),
}) {
  RecordedSegment? best;
  for (final candidate in segments) {
    if (identical(candidate, current) ||
        candidate.id == current.id ||
        candidate.type != 'RECORDING' ||
        candidate.cameraId != current.cameraId ||
        !candidate.path.toLowerCase().endsWith('.ts')) {
      continue;
    }
    final gap = current.startedAt.difference(candidate.endedAt);
    if (gap.isNegative && gap.abs() > const Duration(seconds: 1)) continue;
    if (gap > maxGap) continue;
    if (best == null || candidate.endedAt.isAfter(best.endedAt)) {
      best = candidate;
    }
  }
  return best;
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

bool isManagedStorageFilePath(String path, {String? storageRoot}) {
  final normalized = path.replaceAll('\\', '/').toLowerCase();
  if (isAppManagedVideoPath(path, storageRoot: storageRoot)) return true;
  if (!normalized.endsWith('.wav') && !normalized.endsWith('.json')) {
    return false;
  }
  // Âm thanh/metadata của mảnh ngắn chỉ nằm trong
  // `<dd-mm-yyyy>/AUTOMODE/.../FRAGMENTS/`.
  return normalized.contains('/fragments/') &&
      RegExp(r'/\d{2}-\d{2}-\d{4}/automode/').hasMatch(normalized) &&
      (storageRoot == null ||
          normalized.startsWith('${_normalizedRootPrefix(storageRoot)}/'));
}

/// Tên file kiểu cũ của VNVAR (lưu ngay ở gốc thư mục lưu), ví dụ
/// `VNVAR_CAM-01_1756000000000.ts`, `CLIP_CAM1_1756000000000.mp4`,
/// `CAM1_1756000000000.mp4`. Neo cả hai đầu, chỉ chấp nhận số camera và mốc
/// thời gian epoch (giây hoặc mili-giây).
final RegExp _legacyVideoNamePattern = RegExp(
  r'^(VNVAR_|CLIP_)?CAM[-_]?\d{1,3}_\d{10,13}\.(TS|MP4)$',
);

/// Clip xuất tạm do API trim/Check VAR tạo trong `<gốc>/download/`
/// (xem [buildTrimmedClipFileName]).
final RegExp _exportClipNamePattern = RegExp(r'^[a-z0-9_-]+_trim_\d{10,}\.mp4$');

/// Gốc lưu đã chuẩn hoá: dấu `/`, chữ thường, không có `/` ở cuối (gốc `/`
/// trở thành chuỗi rỗng).
String _normalizedRootPrefix(String storageRoot) {
  var root = storageRoot.replaceAll('\\', '/').toLowerCase();
  while (root.endsWith('/')) {
    root = root.substring(0, root.length - 1);
  }
  return root;
}

/// Video do chính app tạo ra:
/// - đoạn ghi trong `<dd-mm-yyyy>/AUTOMODE/...` (gồm FRAGMENTS và bản dự
///   phòng .mp4);
/// - clip xuất tạm `<camera>_trim_<epoch>.mp4` trong thư mục `download`;
/// - file kiểu cũ của VNVAR nằm ngay ở gốc lưu, tên khớp regex chặt.
/// Người dùng có thể chọn thư mục lưu dùng chung (ví dụ DCIM), nên mọi thao
/// tác dọn dẹp/giới hạn dung lượng chỉ được đụng tới các file này. Khi biết
/// [storageRoot], thư mục ngày phải là con trực tiếp của gốc và file kiểu cũ
/// phải nằm ngay trong gốc (không nhận file trùng tên ở thư mục con khác).
bool isAppManagedVideoPath(String path, {String? storageRoot}) {
  final normalized = path.replaceAll('\\', '/');
  final lower = normalized.toLowerCase();
  if (!lower.endsWith('.ts') && !lower.endsWith('.mp4')) return false;
  final slash = normalized.lastIndexOf('/');
  final name = normalized.substring(slash + 1);
  final parentLower = slash < 0 ? '' : lower.substring(0, slash);

  if (storageRoot == null) {
    if (RegExp(r'/\d{2}-\d{2}-\d{4}/automode/').hasMatch(lower)) return true;
    if (parentLower.endsWith('/download') &&
        _exportClipNamePattern.hasMatch(name.toLowerCase())) {
      return true;
    }
    return _legacyVideoNamePattern.hasMatch(name.toUpperCase());
  }

  final root = _normalizedRootPrefix(storageRoot);
  if (!lower.startsWith('$root/')) return false;
  final relative = lower.substring(root.length);
  if (RegExp(r'^/\d{2}-\d{2}-\d{4}/automode/').hasMatch(relative)) return true;
  if (parentLower == '$root/download') {
    return _exportClipNamePattern.hasMatch(name.toLowerCase());
  }
  if (parentLower == root) {
    return _legacyVideoNamePattern.hasMatch(name.toUpperCase());
  }
  return false;
}

/// Thông số luồng video dùng để quyết định có nối hai segment bằng concat
/// demuxer (stream copy) được hay không.
class VideoStreamSignature {
  final String? codec;
  final int? width;
  final int? height;

  /// Góc xoay (0/90/180/270) đọc từ tag `rotate` hoặc side data display
  /// matrix; 0 khi không có.
  final int rotation;

  const VideoStreamSignature({
    required this.codec,
    required this.width,
    required this.height,
    this.rotation = 0,
  });

  @override
  String toString() => '${codec ?? '?'} ${width ?? '?'}x${height ?? '?'} '
      'rotate=$rotation';
}

int? _propertyAsInt(Object? value) {
  if (value is num) return value.isFinite ? value.round() : null;
  if (value is String) {
    final trimmed = value.trim();
    final integer = int.tryParse(trimmed);
    if (integer != null) return integer;
    final decimal = double.tryParse(trimmed);
    return decimal != null && decimal.isFinite ? decimal.round() : null;
  }
  return null;
}

int _normalizeRotation(int degrees) => (degrees % 360 + 360) % 360;

/// Đọc [VideoStreamSignature] từ thuộc tính một stream của FFprobe
/// (`codec_name`, `width`, `height`, `tags.rotate`, `side_data_list[].rotation`).
VideoStreamSignature? videoStreamSignatureFromProperties(
  Map<dynamic, dynamic>? properties,
) {
  if (properties == null) return null;
  final codecType = properties['codec_type'];
  if (codecType is String && codecType != 'video') return null;
  final codecValue = properties['codec_name'];
  var rotation = 0;
  final tags = properties['tags'];
  if (tags is Map) {
    final rotate = _propertyAsInt(tags['rotate']);
    if (rotate != null) rotation = rotate;
  }
  final sideData = properties['side_data_list'];
  if (rotation == 0 && sideData is List) {
    for (final item in sideData) {
      if (item is! Map) continue;
      final value = _propertyAsInt(item['rotation']);
      if (value != null && value != 0) {
        rotation = value;
        break;
      }
    }
  }
  return VideoStreamSignature(
    codec: codecValue is String && codecValue.trim().isNotEmpty
        ? codecValue.trim().toLowerCase()
        : null,
    width: _propertyAsInt(properties['width']),
    height: _propertyAsInt(properties['height']),
    rotation: _normalizeRotation(rotation),
  );
}

/// Hai file chỉ được nối bằng stream copy khi cùng codec, cùng kích thước và
/// cùng góc xoay. Thiếu thông tin (probe lỗi) coi như không khớp.
bool canJoinVideoStreams(
  VideoStreamSignature? first,
  VideoStreamSignature? second,
) {
  if (first == null || second == null) return false;
  return first.codec != null &&
      first.codec == second.codec &&
      first.width != null &&
      first.width == second.width &&
      first.height != null &&
      first.height == second.height &&
      first.rotation == second.rotation;
}

/// Độ lệch (ms) giữa mẫu âm đầu tiên và lúc MediaRecorder bắt đầu ghi
/// (`firstSampleEpochMs - videoStartEpochMs`). null khi thiếu dữ liệu.
int? audioSyncOffsetMs({
  required num? firstSampleEpochMs,
  required num? videoStartEpochMs,
}) {
  if (firstSampleEpochMs == null || videoStartEpochMs == null) return null;
  final difference = firstSampleEpochMs - videoStartEpochMs;
  if (!difference.isFinite) return null;
  return difference.round();
}

/// Ngưỡng áp dụng bù lệch A/V: chỉ khi 20 ms < |offset| < 3000 ms.
const int minimumAudioSyncOffsetMs = 20;
const int maximumAudioSyncOffsetMs = 3000;

/// Đối số FFmpeg đặt NGAY TRƯỚC `-i <wav>` để căn tiếng theo hình:
/// offset > 0 (tiếng bắt đầu muộn hơn hình) → `-itsoffset` làm trễ tiếng;
/// offset < 0 (tiếng bắt đầu sớm hơn) → `-ss` cắt bỏ phần đầu của tiếng.
List<String> audioOffsetInputArguments(int? offsetMs) {
  if (offsetMs == null) return const <String>[];
  final magnitude = offsetMs.abs();
  if (magnitude <= minimumAudioSyncOffsetMs ||
      magnitude >= maximumAudioSyncOffsetMs) {
    return const <String>[];
  }
  final seconds = (magnitude / 1000).toStringAsFixed(3);
  return offsetMs > 0
      ? <String>['-itsoffset', seconds]
      : <String>['-ss', seconds];
}

/// Đọc `firstSampleEpochMs` từ kết quả `stopNativeAudioSegment`. Native cũ
/// có thể trả null/bool thay vì map: khi đó không biết mốc mẫu đầu tiên.
num? firstSampleEpochMsFromStopResult(Object? result) {
  if (result is! Map) return null;
  final value = result['firstSampleEpochMs'];
  if (value is num && value.isFinite && value > 0) return value;
  return null;
}

/// Nhịp thử mở lại recorder khi phiên ghi đang bị treo vì không mở được
/// segment mới: theo lịch thử lại dung lượng (2 phút) khi thiếu dung lượng,
/// 30 giây cho các lỗi khác.
Duration suspendedRecorderRetryDelay({
  required bool storageSuspended,
  required DateTime? nextStorageRetryAt,
  required DateTime now,
}) {
  if (storageSuspended) {
    if (nextStorageRetryAt == null) return const Duration(minutes: 2);
    final remaining = nextStorageRetryAt.difference(now);
    return remaining > const Duration(seconds: 1)
        ? remaining
        : const Duration(seconds: 1);
  }
  return const Duration(seconds: 30);
}

/// Tên cơ sở cho segment: lần đầu dùng nguyên [baseName], trùng thì thêm hậu
/// tố `_1`, `_2`... thay vì ghi đè file cũ.
String segmentBaseNameCandidate(String baseName, int attempt) =>
    attempt <= 0 ? baseName : '${baseName}_$attempt';

/// Thời gian sống tối đa của clip xuất tạm không có ai đóng phiên, tính từ
/// lần dùng gần nhất (tạo hoặc đọc qua HTTP).
const Duration exportClipTtl = Duration(minutes: 30);

/// Có được xoá clip xuất tạm hay không (chưa xét lease đọc HTTP):
/// [removeAll] khi khởi động/dispose; [closingOwner] khi một tablet đóng
/// phiên tải — chỉ xoá clip của chính phiên đó; ngoài ra clip không được
/// dùng trong [ttl] (tính từ max([createdAt], [lastAccessedAt])) được coi là
/// mồ côi.
bool shouldRemoveExportClip({
  required String? clipOwner,
  required DateTime createdAt,
  required DateTime now,
  DateTime? lastAccessedAt,
  String? closingOwner,
  bool removeAll = false,
  Duration ttl = exportClipTtl,
}) {
  if (removeAll) return true;
  if (closingOwner != null && clipOwner == closingOwner) return true;
  final lastUsed = lastAccessedAt != null && lastAccessedAt.isAfter(createdAt)
      ? lastAccessedAt
      : createdAt;
  return now.difference(lastUsed) >= ttl;
}

/// Hậu tố file tạm khi thử ghép lại tiếng cho bản MP4 dự phòng. Không kết
/// thúc bằng `.ts`/`.mp4` nên chỉ mục video và [isAppManagedVideoPath] không
/// nhận nhầm; `.tmp` được dọn như file phụ trợ mồ côi ([isOrphanAuxiliaryFile]).
const String fallbackRetryTempSuffix = '.retry.tmp';

/// Đường dẫn file tạm (cùng thư mục) cho file đích [targetPath].
String fallbackRetryTempPath(String targetPath) =>
    '$targetPath$fallbackRetryTempSuffix';

/// Bản ghi clip xuất tạm: phiên sở hữu, lúc tạo và lần đọc HTTP gần nhất.
typedef _ExportClipRecord = ({
  String? owner,
  DateTime createdAt,
  DateTime? lastAccessedAt,
});

/// Một yêu cầu cắt clip trong hàng đợi của [RecordingService].
class _TrimJob {
  _TrimJob({required this.priority, required this.run});

  final bool priority;
  final Future<RecordedSegment> Function() run;
  final Completer<RecordedSegment> completer = Completer<RecordedSegment>();
}

enum FallbackReplacementAction {
  /// Đưa file tạm vào chỗ (rename đè/copy), rồi bỏ bản dự phòng cũ.
  install,

  /// Bản dự phòng cũ đang được đọc: bỏ file tạm, giữ nguồn staging, thử lại
  /// ở lần dọn sau (không tính là một lần thử thất bại).
  defer,

  /// File tạm không hợp lệ (ghép lỗi): bỏ file tạm, bản cũ giữ nguyên.
  discardTemp,
}

/// Quyết định ngay trước khi thay bản dự phòng cũ bằng kết quả ghép lại.
/// [previousLeased] phải được đọc NGAY trước thao tác xoá/đè.
FallbackReplacementAction fallbackReplacementAction({
  required bool tempValid,
  required bool previousLeased,
}) {
  if (!tempValid) return FallbackReplacementAction.discardTemp;
  if (previousLeased) return FallbackReplacementAction.defer;
  return FallbackReplacementAction.install;
}

/// Khoá journal ghi đường dẫn bản MP4 dự phòng sắp bị thay bằng TS: ghi
/// TRƯỚC khi đưa TS vào chỗ, gỡ sau khi xoá xong bản MP4. Crash ở giữa thì
/// lần khôi phục sau dùng khoá này để bỏ bản MP4 trùng.
const String fallbackPendingDeleteJournalKey = 'pendingDelete';

/// Đường dẫn TS thay thế cho bản MP4 dự phòng [mp4Path] (cùng thư mục, cùng
/// tên cơ sở — như `_convertRecordingToTs` dựng khi thử lại). Không phải
/// `.mp4` thì trả null.
String? supersedingTsPathForFallback(String mp4Path) {
  if (!mp4Path.toLowerCase().endsWith('.mp4')) return null;
  return '${mp4Path.substring(0, mp4Path.length - 4)}.ts';
}

enum PendingFallbackDeleteAction {
  /// Journal không có khoá xoá dở: xử lý như bình thường.
  none,

  /// Khoá không còn hiệu lực (TS chưa vào chỗ / không khớp bản dự phòng):
  /// gỡ khoá rồi xử lý như bình thường.
  clearStale,

  /// TS dở dang (không đọc được): bỏ TS dở, gỡ khoá, giữ bản MP4.
  discardBrokenTs,

  /// TS đã vào chỗ nhưng bản MP4 đang được đọc: giữ nguyên, xét lại sau.
  waitForLease,

  /// TS đã vào chỗ: xoá bản MP4 trùng và chốt lượt thử như thành công.
  deleteSuperseded,
}

/// Quyết định khi khôi phục một journal `preserved_fallback` còn khoá
/// [fallbackPendingDeleteJournalKey] (crash giữa lúc đưa TS vào chỗ và lúc
/// xoá bản MP4 cũ). [pendingDelete] chỉ có hiệu lực khi trùng [finalPath] và
/// là `.mp4`. [tsPlayable] chỉ được xét khi [tsExists].
PendingFallbackDeleteAction pendingFallbackDeleteAction({
  required Object? pendingDelete,
  required String? finalPath,
  required bool tsExists,
  required bool tsPlayable,
  required bool mp4Leased,
}) {
  if (pendingDelete == null) return PendingFallbackDeleteAction.none;
  if (pendingDelete is! String ||
      pendingDelete != finalPath ||
      supersedingTsPathForFallback(pendingDelete) == null ||
      !tsExists) {
    return PendingFallbackDeleteAction.clearStale;
  }
  if (!tsPlayable) return PendingFallbackDeleteAction.discardBrokenTs;
  if (mp4Leased) return PendingFallbackDeleteAction.waitForLease;
  return PendingFallbackDeleteAction.deleteSuperseded;
}

/// Cặp `X.ts` + `X.mp4` cùng thư mục, cùng tên cơ sở (phân biệt hoa thường,
/// đuôi so không phân biệt) và đều do app quản lý ([isAppManagedVideoPath]):
/// bản `.mp4` là bản dự phòng đã (hoặc đang) được thay bằng `.ts`.
/// Trả về map đường dẫn `.mp4` -> đường dẫn `.ts`; chỉ mục chỉ liệt kê một
/// bản ([preferFallbackMp4OverTs]), không xoá file. File khác tên cơ sở không
/// bao giờ bị ghép cặp.
Map<String, String> supersededFallbackVideoPairs(
  Iterable<String> videoPaths, {
  String? storageRoot,
}) {
  final tsByBase = <String, String>{};
  final mp4ByBase = <String, String>{};
  for (final path in videoPaths) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.ts')) {
      tsByBase.putIfAbsent(path.substring(0, path.length - 3), () => path);
    } else if (lower.endsWith('.mp4')) {
      mp4ByBase.putIfAbsent(path.substring(0, path.length - 4), () => path);
    }
  }
  final result = <String, String>{};
  for (final entry in mp4ByBase.entries) {
    final mp4Path = entry.value;
    final tsPath = tsByBase[entry.key];
    if (tsPath == null) continue;
    if (!isAppManagedVideoPath(mp4Path, storageRoot: storageRoot) ||
        !isAppManagedVideoPath(tsPath, storageRoot: storageRoot)) {
      continue;
    }
    result[mp4Path] = tsPath;
  }
  return result;
}

/// Với một cặp từ [supersededFallbackVideoPairs]: chỉ mục giữ bản `.mp4` (ẩn
/// `.ts`) khi journal còn khoá [fallbackPendingDeleteJournalKey] trỏ tới bản
/// `.mp4` đó — lượt thay chưa hoàn tất, `.ts` có thể dở dang — hoặc khi bản
/// `.ts` không còn (lượt thay vừa hoãn và gỡ `.ts`), miễn bản `.mp4` vẫn còn
/// trên đĩa. Ngược lại (thay thế đã hoàn tất) ưu tiên `.ts`.
bool preferFallbackMp4OverTs({
  required bool pendingDelete,
  required bool mp4Exists,
  bool tsExists = true,
}) => mp4Exists && (pendingDelete || !tsExists);

/// File tạm `*.retry.tmp` sót lại sau crash được coi là cũ sau khoảng này.
const Duration staleFallbackRetryTempAge = Duration(minutes: 10);

/// File tạm thử ghép lại ([fallbackRetryTempSuffix]) được phép dọn khi thư
/// mục vẫn còn video: chỉ khi không có lượt thử nào đang chạy và file đã cũ
/// hơn [staleAge]. Không bao giờ nhận file khác.
bool isStaleFallbackRetryTemp({
  required String path,
  required DateTime modified,
  required DateTime now,
  required bool retryInFlight,
  Duration staleAge = staleFallbackRetryTempAge,
}) {
  if (retryInFlight) return false;
  final name = path.replaceAll('\\', '/').split('/').last.toLowerCase();
  if (!name.endsWith(fallbackRetryTempSuffix) ||
      name.length == fallbackRetryTempSuffix.length) {
    return false;
  }
  return now.difference(modified) >= staleAge;
}

/// Số lần tối đa thử ghép lại tiếng cho bản MP4 dự phòng.
const int maximumFallbackMuxAttempts = 3;

enum PreservedFallbackAction {
  /// Thử ghép tiếng lại từ MP4/WAV staging, ghi đè đúng bản dự phòng.
  retry,

  /// Giữ nguyên nguồn staging, xét lại ở lần dọn sau.
  keep,

  /// Bỏ nguồn staging (MP4/WAV/journal); bản dự phòng (nếu còn) được giữ.
  discardSources,
}

/// Quyết định cho cặp MP4/WAV staging đã có bản MP4 dự phòng
/// (journal `state: preserved_fallback`).
PreservedFallbackAction preservedFallbackAction({
  required int attempts,
  required bool finalExists,
  required bool finalLeased,
  required Duration age,
  required Duration maxAge,
}) {
  if (!finalExists) {
    // Bản dự phòng đã bị xoá (người dùng xoá/thư mục ngày hết hạn): không
    // dựng lại, chỉ dọn nguồn khi quá hạn.
    return age >= maxAge
        ? PreservedFallbackAction.discardSources
        : PreservedFallbackAction.keep;
  }
  if (finalLeased) return PreservedFallbackAction.keep;
  if (attempts < maximumFallbackMuxAttempts) {
    return PreservedFallbackAction.retry;
  }
  return age >= maxAge
      ? PreservedFallbackAction.discardSources
      : PreservedFallbackAction.keep;
}

/// File phụ trợ mồ côi được phép xoá khi dọn thư mục ngày: âm thanh/metadata
/// tạm của app và file ẩn của hệ điều hành. Không bao giờ xoá file khác.
bool isOrphanAuxiliaryFile(String path) {
  final name = path.replaceAll('\\', '/').split('/').last.toLowerCase();
  return name.startsWith('.') ||
      name.endsWith('.wav') ||
      name.endsWith('.json') ||
      name.endsWith('.tmp');
}

const String _unknownUserFacingErrorVi = 'Đã xảy ra lỗi không xác định.';
const String _unknownUserFacingErrorEn = 'An unknown error occurred.';

/// Converts native/FFmpeg failures into a bounded string safe for a Flutter
/// Text widget. Full command output remains available in debug logs.
/// Luôn tiếng Việt (dùng cả cho JSON trả tablet); UI dùng
/// [localizedUserFacingError].
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
  return message.isEmpty ? _unknownUserFacingErrorVi : message;
}

/// Như [userFacingError] nhưng theo ngôn ngữ giao diện: lỗi có sẵn hai ngôn
/// ngữ ([BilingualMessage]) dùng đúng bản; lỗi khác giữ nguyên nội dung gốc.
String localizedUserFacingError(Object error, {required bool english}) {
  final source = error is BilingualMessage
      ? error.localized(english: english)
      : error;
  final message = userFacingError(source);
  if (english && message == _unknownUserFacingErrorVi) {
    return _unknownUserFacingErrorEn;
  }
  return message;
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

class StorageSafetyException implements Exception, BilingualMessage {
  final String message;

  /// Bản tiếng Anh cho UI; mặc định dùng chung [message].
  final String? englishMessage;

  const StorageSafetyException(this.message, [this.englishMessage]);

  @override
  String get messageVi => message;

  @override
  String get messageEn => englishMessage ?? message;

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

/// Check VAR không có segment để chốt. [code]: `NO_SEGMENT` (không còn file
/// chứa thời điểm sự kiện) hoặc `NOT_RECORDING` (camera chưa/không ghi).
class CheckVarSegmentUnavailableException implements Exception {
  final String code;
  final String message;
  const CheckVarSegmentUnavailableException(this.code, this.message);

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

  /// Chỉ có ý nghĩa với clip: clip đã được nối thêm phần cuối của segment
  /// liền trước (Check VAR bấm ngay sau lúc chuyển segment).
  final bool joinedPrecedingSegment;

  RecordedSegment({
    required this.id,
    required this.cameraId,
    required this.path,
    required this.startedAt,
    required this.endedAt,
    this.type = 'RECORDING',
    this.downloaded = false,
    this.joinedPrecedingSegment = false,
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
    final ms = duration.inMilliseconds;
    return ms <= 0 ? 1 : ms;
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
  static const int autoCleanupMaxPasses = 50;
  static const int autoCleanupBatchSize = 10;
  static const int minimumStartFreeSpaceBytes = 512 * 1024 * 1024;
  static const Duration recentSegmentProtection = Duration(minutes: 5);

  static String? get _hardwareH264Encoder {
    if (Platform.isAndroid) return 'h264_mediacodec';
    // Bản FFmpeg đi kèm trên iOS không có VideoToolbox (xem
    // preparePlaybackFile); thử h264_videotoolbox chỉ thất bại rồi mới rơi về
    // mpeg4, làm chậm việc chốt segment và cắt clip.
    return null;
  }

  RecordingService({
    required this.cameraId,
    VideoStorageService? videoStorageService,
  }) : _videoStorage = videoStorageService ?? VideoStorageService() {
    if (Platform.isAndroid || Platform.isIOS) {
      // C3: iOS báo gián đoạn âm thanh (cuộc gọi, Siri...) kết thúc.
      StationPlatformEvents.instance.addListener(this, _handlePlatformEvent);
    }
  }

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

  String _facingMode = 'environment';
  int _quarterTurns = 0;
  String _currentSegmentFacingMode = 'environment';
  int _currentSegmentQuarterTurns = 0;

  String get facingMode => _facingMode;
  int get quarterTurns => _quarterTurns;

  void setFacingMode(String facing) {
    _facingMode = facing.trim().toLowerCase();
    _currentSegmentFacingMode = _facingMode;
  }

  void setQuarterTurns(int turns) {
    _quarterTurns = (turns % 4 + 4) % 4;
  }

  Timer? _segmentTimer;

  // ============================================================
  // CURRENT SEGMENT
  // ============================================================

  DateTime? _segmentStartedAt;

  String? _currentPath;
  String? _currentAudioPath;
  File? _currentJournal;
  bool _currentSegmentHasAudio = false;

  /// Số lượt thử ghép lại bản dự phòng đang chạy (cờ in-flight, dùng chung
  /// mọi camera vì có thể chung thư mục lưu): khác 0 thì không dọn
  /// `*.retry.tmp` vì file tạm có thể đang được FFmpeg ghi.
  static int _fallbackRetriesInFlight = 0;

  // ============================================================
  // STATE
  // ============================================================

  bool _recording = false;
  Future<RecordedSegment>? _trimOperation;

  /// Số yêu cầu cắt clip tối đa được xếp hàng (kể cả cái đang chạy).
  static const int maxPendingTrims = 4;

  // Các yêu cầu cắt clip chạy lần lượt (FFmpeg cắt từng clip một) thay vì
  // trả lỗi 409 khi đang bận. Yêu cầu trùng hệt (Tablet gửi lại khi chờ lâu)
  // dùng chung kết quả với yêu cầu đang chạy.
  final Map<String, Future<RecordedSegment>> _pendingTrims =
      <String, Future<RecordedSegment>>{};
  // Hàng đợi cắt clip: job ưu tiên (Check VAR) luôn chen trước các job cắt
  // thủ công đang chờ; job đang chạy không bị ngắt.
  final List<_TrimJob> _trimJobs = <_TrimJob>[];
  // Số job cắt thủ công (không ưu tiên) đang chờ hoặc đang chạy.
  int _normalPendingTrimCount = 0;
  // Khác null khi worker cắt clip đang chạy; hoàn tất khi hàng đợi trống.
  Completer<void>? _trimWorkerIdle;

  bool _rotating = false;
  bool _lowStorageWarning = false;
  DateTime? _lowStorageWarningSince;
  bool _storageSuspended = false;
  DateTime? _nextStorageRetryAt;

  bool _stopping = false;
  Future<RecordedSegment?>? _stopOperation;
  // Lần start() đang mở recorder đầu tiên; stop()/rotation phải chờ nó xong để
  // không bỏ lại recorder native mở muộn (rò rỉ, file staging phình mãi).
  Future<void>? _startOperation;
  // File staging đang được chốt/chuyển sang TS. _currentPath đã trỏ sang đoạn
  // mới nên dọn file tạm phải bỏ qua các file này để không convert hai lần.
  final Set<String> _finalizingPaths = <String>{};
  Future<RecordedSegment?>? _rotationOperation;
  Future<void>? _expiredCleanupOperation;
  Future<void>? _storageLimitOperation;
  Future<void>? _autoCleanupOperation;
  Future<void>? _exportCleanupOperation;
  Future<void>? _abandonedCleanupOperation;
  final Map<String, int> _activeFileReaders = <String, int>{};

  // Phiên ghi vẫn bật (_recording) nhưng không mở được recorder cho segment
  // mới (thiếu dung lượng, lỗi native...). Lúc này KHÔNG có file nào đang
  // được ghi; timer thử mở lại theo nhịp ngắn (suspendedRecorderRetryDelay).
  String? _suspendedReason;

  // Mốc wall-clock (ms) ngay sau khi MediaRecorder.start của segment hiện tại
  // hoàn tất (C2): dùng tính độ lệch với mẫu âm đầu tiên.
  int? _currentVideoStartEpochMs;

  // Chủ sở hữu (phiên tablet) và thời điểm tạo của từng clip xuất tạm, theo
  // đường dẫn tuyệt đối (_exportClipKey).
  // [lastAccessedAt]: lần gần nhất clip được phục vụ qua HTTP (/download,
  // /video); TTL dọn clip mồ côi tính từ max(createdAt, lastAccessedAt).
  final Map<String, _ExportClipRecord> _exportClipOwners =
      <String, _ExportClipRecord>{};

  /// Phiên ghi đang bật nhưng chưa ghi được (recorder chưa mở lại được).
  /// [recording] vẫn true trong trạng thái này (ý định ghi còn nguyên); UI và
  /// health monitor nên dựa vào getter này để không coi là "đang ghi".
  bool get isRecordingSuspended => _recording && _suspendedReason != null;

  /// Lý do treo ghi (thông điệp lỗi rút gọn), null nếu không treo.
  String? get recordingSuspendedReason =>
      isRecordingSuspended ? _suspendedReason : null;

  bool get recording => _recording;

  bool get rotating => _rotating;

  String _leaseKey(String path) =>
      File(path).absolute.path.replaceAll('\\', '/').toLowerCase();

  // Khoá theo đường dẫn tuyệt đối thật (không đổi chữ thường) vì còn dùng để
  // kiểm tra file còn tồn tại trên hệ thống file phân biệt hoa/thường.
  String _exportClipKey(String path) => File(path).absolute.path;

  /// Prevents retention cleanup from deleting a file while HTTP is reading it.
  void acquireFileRead(String path) {
    final key = _leaseKey(path);
    _activeFileReaders[key] = (_activeFileReaders[key] ?? 0) + 1;
    _touchExportClip(path);
  }

  void releaseFileRead(String path) {
    // Gia hạn TTL cả lúc tải xong: lượt tải dài không bị tính từ lúc bắt đầu.
    _touchExportClip(path);
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

  /// Clip xuất tạm có bản ghi chủ phiên: ghi nhận lần đọc gần nhất để TTL
  /// dọn clip mồ côi tính từ lần đọc cuối (tablet tải muộn không bị 404).
  void _touchExportClip(String path) {
    if (_exportClipOwners.isEmpty) return;
    final key = _exportClipKey(path);
    final record = _exportClipOwners[key];
    if (record == null) return;
    _exportClipOwners[key] = (
      owner: record.owner,
      createdAt: record.createdAt,
      lastAccessedAt: DateTime.now(),
    );
  }

  /// Chỉ dùng trong test: đăng ký bản ghi chủ phiên cho một clip xuất tạm
  /// (bình thường do [trimSegment] tạo).
  @visibleForTesting
  void debugRegisterExportClip(
    String path, {
    String? owner,
    required DateTime createdAt,
    DateTime? lastAccessedAt,
  }) {
    _exportClipOwners[_exportClipKey(path)] = (
      owner: owner,
      createdAt: createdAt,
      lastAccessedAt: lastAccessedAt,
    );
  }

  /// Có file nào nằm trong [directoryPath] đang được HTTP đọc hay không.
  bool _hasActiveReadUnder(String directoryPath) {
    if (_activeFileReaders.isEmpty) return false;
    var prefix = _leaseKey(directoryPath);
    if (!prefix.endsWith('/')) prefix = '$prefix/';
    return _activeFileReaders.keys.any((key) => key.startsWith(prefix));
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

  /// Segment liền trước [segment], nếu còn trên máy.
  RecordedSegment? precedingSegmentOf(RecordedSegment segment) =>
      selectPrecedingSegment(_segments, segment);

  /// Chờ mọi thao tác cắt clip đang chạy/xếp hàng xong.
  Future<void> waitForTrimIdle() async {
    // Hàng đợi có thể được nối thêm trong lúc chờ: chờ tới khi đứng yên.
    while (true) {
      final idle = _trimWorkerIdle;
      if (idle == null) return;
      await idle.future;
    }
  }

  /// Cắt clip từ [segmentId]. [startMs] âm nghĩa là bắt đầu trong
  /// [precedingSegmentId] (segment liền trước); hai file `.ts` được nối liền
  /// rồi cắt bằng stream copy. [owner] là khoá phiên tải của tablet yêu cầu:
  /// `cleanupExportDownloads(owner: ...)` chỉ xoá clip của đúng phiên đó.
  /// [priority] (Check VAR): chen trước mọi job cắt thủ công đang chờ và
  /// không bị giới hạn [maxPendingTrims] của job thủ công.
  Future<RecordedSegment> trimSegment({
    required String segmentId,
    required int startMs,
    required int endMs,
    bool streamCopy = false,
    int? minimumOutputDurationMs,
    String? precedingSegmentId,
    String? owner,
    bool priority = false,
  }) {
    final key = [
      segmentId,
      startMs,
      endMs,
      streamCopy,
      minimumOutputDurationMs,
      precedingSegmentId,
      owner,
    ].join('|');
    final duplicate = _pendingTrims[key];
    if (duplicate != null) return duplicate;
    if (!priority && _normalPendingTrimCount >= maxPendingTrims) {
      return Future<RecordedSegment>.error(
        const TrimInProgressException(
          'Camera Station đang xử lý nhiều video; vui lòng thử lại sau ít phút.',
        ),
      );
    }
    final job = _TrimJob(
      priority: priority,
      run: () => _trimSegmentInternal(
        segmentId: segmentId,
        startMs: startMs,
        endMs: endMs,
        streamCopy: streamCopy,
        minimumOutputDurationMs: minimumOutputDurationMs,
        precedingSegmentId: precedingSegmentId,
        owner: owner,
      ),
    );
    final operation = job.completer.future;
    if (!priority) _normalPendingTrimCount++;
    _pendingTrims[key] = operation;
    final settled = operation.then<void>((_) {}, onError: (Object _) {});
    unawaited(
      settled.whenComplete(() {
        if (!priority) _normalPendingTrimCount--;
        if (identical(_pendingTrims[key], operation)) _pendingTrims.remove(key);
      }),
    );
    _trimJobs.add(job);
    if (_pendingTrims.length > 1) {
      developer.log(
        '[TRIM] Queued ${priority ? 'priority ' : ''}trim request '
        '(${_pendingTrims.length} pending)',
        name: 'RecordingService',
      );
    }
    _startTrimWorker();
    return operation;
  }

  /// Job kế tiếp: job ưu tiên đầu tiên, nếu không có thì job cũ nhất.
  _TrimJob? _takeNextTrimJob() {
    if (_trimJobs.isEmpty) return null;
    final priorityIndex = _trimJobs.indexWhere((job) => job.priority);
    return _trimJobs.removeAt(priorityIndex < 0 ? 0 : priorityIndex);
  }

  void _startTrimWorker() {
    if (_trimWorkerIdle != null) return;
    final idle = Completer<void>();
    _trimWorkerIdle = idle;
    unawaited(() async {
      try {
        while (true) {
          // Không cắt trong lúc đang dọn thư mục tải về: clip mới có thể bị
          // xoá. Chờ trước khi chọn job để job ưu tiên đến trong lúc chờ
          // vẫn được chạy trước.
          while (true) {
            final cleanup = _exportCleanupOperation;
            if (cleanup == null) break;
            try {
              await cleanup;
            } catch (_) {
              // Lỗi dọn dẹp đã được trả cho caller của nó.
            }
          }
          // Không có await nào giữa lúc thấy hàng đợi trống và lúc đặt lại
          // _trimWorkerIdle (finally): job mới luôn khởi động worker mới.
          final job = _takeNextTrimJob();
          if (job == null) break;
          final run = job.run();
          _trimOperation = run;
          try {
            job.completer.complete(await run);
          } catch (error, stackTrace) {
            job.completer.completeError(error, stackTrace);
          } finally {
            if (identical(_trimOperation, run)) _trimOperation = null;
          }
        }
      } finally {
        if (identical(_trimWorkerIdle, idle)) _trimWorkerIdle = null;
        idle.complete();
      }
    }());
  }

  Future<RecordedSegment> _trimSegmentInternal({
    required String segmentId,
    required int startMs,
    required int endMs,
    required bool streamCopy,
    required int? minimumOutputDurationMs,
    String? precedingSegmentId,
    String? owner,
  }) async {
    if (endMs <= startMs ||
        endMs - startMs < 500 ||
        (startMs < 0 && precedingSegmentId == null)) {
      throw const InvalidTrimRangeException('Khoảng cắt video không hợp lệ.');
    }
    final source = findById(segmentId) ?? findByFileName(segmentId);
    if (source == null) {
      throw TrimSegmentNotFoundException(
        'Không tìm thấy video nguồn $segmentId.',
      );
    }
    // Giữ lease đọc cho file nguồn (và segment liền trước nếu dùng) suốt quá
    // trình FFmpeg đọc, để dọn dung lượng/xoá thủ công không xoá giữa chừng.
    final leasedPaths = <String>[source.path];
    acquireFileRead(source.path);
    try {
      if (!await File(source.path).exists()) {
        throw TrimSegmentNotFoundException(
          'Không tìm thấy video nguồn $segmentId.',
        );
      }
      return await _trimLeasedSource(
        source: source,
        startMs: startMs,
        endMs: endMs,
        streamCopy: streamCopy,
        minimumOutputDurationMs: minimumOutputDurationMs,
        precedingSegmentId: precedingSegmentId,
        owner: owner,
        leasedPaths: leasedPaths,
      );
    } finally {
      for (final path in leasedPaths) {
        releaseFileRead(path);
      }
    }
  }

  Future<RecordedSegment> _trimLeasedSource({
    required RecordedSegment source,
    required int startMs,
    required int endMs,
    required bool streamCopy,
    required int? minimumOutputDurationMs,
    required String? precedingSegmentId,
    required String? owner,
    required List<String> leasedPaths,
  }) async {
    if (endMs > source.duration.inMilliseconds + 1000) {
      throw const InvalidTrimRangeException(
        'Khoảng cắt vượt quá thời lượng video.',
      );
    }

    // Clip bắt đầu trong segment trước: dùng concat demuxer (danh sách file +
    // inpoint/outpoint) để nối phần cuối segment trước với segment hiện tại.
    // Không dùng giao thức `concat:` vì dấu thời gian của file TS thứ hai bắt
    // đầu lại từ đầu, FFmpeg sẽ bỏ mất phần sau (đã kiểm chứng). Thiếu segment
    // trước, không phải TS hoặc hai file khác codec/kích thước/góc xoay thì
    // cắt từ đầu segment hiện tại như trước.
    RecordedSegment? precedingSource;
    var precedingMs = 0;
    var effectiveStartMs = startMs;
    if (startMs < 0) {
      final preceding = precedingSegmentId == null
          ? null
          : findById(precedingSegmentId);
      if (preceding != null) {
        acquireFileRead(preceding.path);
        leasedPaths.add(preceding.path);
      }
      final precedingProbe = preceding == null ||
              !source.path.toLowerCase().endsWith('.ts') ||
              !await File(preceding.path).exists()
          ? null
          : await _probeVideo(File(preceding.path));
      precedingMs = ((precedingProbe?.durationSeconds ?? 0) * 1000).round();
      var compatible = false;
      if (preceding != null && precedingMs > 0) {
        final previousSignature = await _probeVideoSignature(
          File(preceding.path),
        );
        final currentSignature = await _probeVideoSignature(File(source.path));
        compatible = canJoinVideoStreams(previousSignature, currentSignature);
        if (!compatible) {
          developer.log(
            '[TRIM] Not joining ${preceding.fileName} + ${source.fileName}: '
            'stream mismatch ($previousSignature vs $currentSignature); '
            'using the current segment only.',
            name: 'RecordingService',
          );
        }
      }
      if (preceding != null && precedingMs > 0 && compatible) {
        precedingSource = preceding;
        effectiveStartMs = startMs < -precedingMs ? -precedingMs : startMs;
      } else {
        effectiveStartMs = 0;
      }
    }
    File? concatList;

    File? output;
    try {
      final now = DateTime.now();
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
      final durationMs = endMs - effectiveStartMs;
      final isTsInput = source.path.toLowerCase().endsWith('.ts');
      final crossSegment = precedingSource;
      // Mốc cắt tuyệt đối cho concat demuxer (null → cắt tương đối bằng
      // -ss/-t trên đầu vào concat, cùng cách nhánh một file).
      ({double inpoint, double outpoint})? concatPoints;
      if (crossSegment != null) {
        concatPoints = concatTrimPoints(
          precedingStartTimeSeconds: await _probeStartTimeSeconds(
            File(crossSegment.path),
          ),
          currentStartTimeSeconds: await _probeStartTimeSeconds(
            File(source.path),
          ),
          precedingMs: precedingMs,
          effectiveStartMs: effectiveStartMs,
          endMs: endMs,
        );
        // ffconcat: đường dẫn trong nháy đơn, nháy đơn bên trong viết '\''.
        String quote(String path) => "'${path.replaceAll("'", r"'\''")}'";
        final points = concatPoints;
        concatList = File('${target.path}.concat.txt');
        await concatList.writeAsString(
          points == null
              ? 'ffconcat version 1.0\n'
                    'file ${quote(crossSegment.path)}\n'
                    'file ${quote(source.path)}\n'
              : 'ffconcat version 1.0\n'
                    'file ${quote(crossSegment.path)}\n'
                    'inpoint ${points.inpoint.toStringAsFixed(3)}\n'
                    'file ${quote(source.path)}\n'
                    'outpoint ${points.outpoint.toStringAsFixed(3)}\n',
          flush: true,
        );
      }
      final relativeConcatStartSeconds =
          (precedingMs + effectiveStartMs) / 1000;
      final inputArguments = crossSegment != null
          ? <String>[
              '-fflags',
              '+genpts+discardcorrupt',
              '-f',
              'concat',
              '-safe',
              '0',
              if (concatPoints == null) ...[
                '-ss',
                relativeConcatStartSeconds.toStringAsFixed(3),
              ],
              '-i',
              concatList!.path,
              if (concatPoints == null) ...[
                '-t',
                (durationMs / 1000).toStringAsFixed(3),
              ],
            ]
          : <String>[
              if (isTsInput) ...[
                '-fflags',
                '+genpts+discardcorrupt',
                '-analyzeduration',
                '10000000',
                '-probesize',
                '10000000',
              ],
              '-ss',
              (effectiveStartMs / 1000).toStringAsFixed(3),
              '-i',
              source.path,
              '-t',
              (durationMs / 1000).toStringAsFixed(3),
            ];
      final commonArguments = <String>[
        '-y',
        ...inputArguments,
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
        // Neo theo điểm cuối (thời điểm sự kiện, cắt chính xác). Điểm đầu khi
        // stream copy luôn lùi về keyframe gần nhất nên sớm hơn [startedAt]
        // tới ~1 giây; tính ngược từ thời lượng thật để giờ của clip khớp hình.
        startedAt: source.startedAt
            .add(Duration(milliseconds: endMs))
            .subtract(actualDuration),
        endedAt: source.startedAt.add(Duration(milliseconds: endMs)),
        type: 'CLIP',
        joinedPrecedingSegment: crossSegment != null,
      );
      _exportSegments[clip.fileName] = clip;
      _exportClipOwners[_exportClipKey(clip.path)] = (
        owner: owner,
        createdAt: DateTime.now(),
        lastAccessedAt: null,
      );
      return clip;
    } catch (_) {
      // Dọn file dở dang nhưng không được che mất lỗi gốc (FFmpeg/trim).
      try {
        if (output != null && await output.exists()) await output.delete();
      } catch (_) {}
      rethrow;
    } finally {
      final list = concatList;
      if (list != null) {
        try {
          if (await list.exists()) await list.delete();
        } catch (_) {}
      }
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
    // Giữ lease đọc file nguồn suốt lúc FFmpeg chuyển TS→MP4: dọn theo dung
    // lượng/thư mục ngày không được xoá file đang đọc.
    acquireFileRead(source.path);
    try {
      return await _remuxForIosPlayback(segment, source);
    } finally {
      releaseFileRead(source.path);
    }
  }

  Future<File> _remuxForIosPlayback(
    RecordedSegment segment,
    File source,
  ) async {
    if (!await source.exists()) {
      throw BilingualFileSystemException(
        'Video không còn tồn tại.',
        'The video no longer exists.',
        source.path,
      );
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
    // Hậu tố duy nhất: hai trình phát mở cùng một segment không được dùng
    // chung (và xoá mất) file tạm của nhau. Trình phát xoá file này khi đóng.
    var uniqueSuffix = DateTime.now().microsecondsSinceEpoch;
    var target = File(
      '${directory.path}${Platform.pathSeparator}${safeId}_$uniqueSuffix.mp4',
    );
    while (await target.exists()) {
      uniqueSuffix++;
      target = File(
        '${directory.path}${Platform.pathSeparator}${safeId}_$uniqueSuffix.mp4',
      );
    }

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
      final detail = conciseOutput.isEmpty ? code : conciseOutput;
      throw BilingualStateError(
        'Không thể chuẩn bị video để phát: $detail',
        'Cannot prepare video for playback: $detail',
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

  // ============================================================
  // STAGING (FILE TẠM KHI GHI)
  // ============================================================

  static Future<String?> _applicationSupportPath() async {
    try {
      return (await getApplicationSupportDirectory()).path;
    } catch (error) {
      developer.log(
        'Application Support directory unavailable; using cache: $error',
        name: 'RecordingService',
      );
      return null;
    }
  }

  static Future<String?> _temporaryPath() async {
    try {
      return (await getTemporaryDirectory()).path;
    } catch (error) {
      developer.log(
        'Temporary directory unavailable: $error',
        name: 'RecordingService',
      );
      return null;
    }
  }

  /// Thư mục ghi MP4/WAV staging và journal. Đặt trong Application Support
  /// (Android không tự xoá như cache khi thiếu bộ nhớ); thiếu thì dùng cache.
  Future<Directory> _stagingDirectory() async {
    final path = recordingStagingDirectoryPath(
      supportPath: await _applicationSupportPath(),
      temporaryPath: await _temporaryPath(),
      separator: Platform.pathSeparator,
    );
    if (path == null) {
      throw BilingualStateError(
        'Không tìm thấy thư mục lưu file tạm khi ghi.',
        'No directory available for recording temp files.',
      );
    }
    return Directory(path);
  }

  /// Mọi thư mục staging cần quét khi dọn/khôi phục: thư mục hiện tại và
  /// thư mục cũ trong cache (file của bản cũ / lần chạy trước).
  Future<List<Directory>> _stagingScanDirectories() async {
    return recordingStagingScanPaths(
      supportPath: await _applicationSupportPath(),
      temporaryPath: await _temporaryPath(),
      separator: Platform.pathSeparator,
    ).map(Directory.new).toList();
  }

  /// Dung lượng trống của ổ chứa file tạm khi ghi (Android; iOS dùng chung
  /// một ổ với thư mục video nên không đo riêng). null nếu không đọc được.
  Future<int?> _stagingAvailableBytes() async {
    if (!Platform.isAndroid) return null;
    try {
      final directory = await _stagingDirectory();
      await directory.create(recursive: true);
      return await _videoStorage.availableBytesAt(directory.path);
    } catch (error) {
      developer.log(
        'Unable to read free space of the staging directory: $error',
        name: 'RecordingService',
      );
      return null;
    }
  }

  /// Thư mục chính + thư mục dự phòng từng được dùng khi thư mục chính lỗi.
  Future<List<Directory>> _allVideoRoots() async {
    final primary = await _videoRootDirectory();
    final secondary = await _videoStorage.secondaryRoots(primary);
    return [primary, ...secondary];
  }

  /// Đang phải ghi vào thư mục dự phòng vì thư mục lưu đã chọn bị lỗi.
  bool get storageFallbackActive => _videoStorage.fallbackActive;

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
    final List<Directory> roots;
    try {
      roots = await _allVideoRoots();
    } catch (e) {
      developer.log(
        '[RECORDING] Cannot get video root directory: $e',
        name: 'RecordingService',
      );
      return;
    }
    final now = referenceTime ?? DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final cutoff = today.subtract(Duration(days: storageDays - 1));

    for (final root in roots) {
    try {
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
        // Tablet đang tải một file trong thư mục này: để lần dọn sau xoá,
        // không cắt ngang lượt tải.
        if (_hasActiveReadUnder(entity.path)) {
          developer.log(
            '[STORAGE] Skip expired directory with active download: ${entity.path}',
            name: 'RecordingService',
          );
          continue;
        }

        try {
          final normalizedDirectory = entity.path.replaceAll('\\', '/');

          // 1. Thử xóa qua tầng Native Android trước (để giải quyết Scoped Storage)
          bool nativeDeleted = false;
          if (Platform.isAndroid) {
            nativeDeleted =
                await _videoStorage.deleteDirectoryRecursively(entity.path);
          }

          // 2. Nếu native chưa xóa được hoặc không phải Android, duyệt xóa sạch từng file con từ dưới lên trong Dart
          if (!nativeDeleted && await entity.exists()) {
            await _deepDeleteDirectory(entity);
          }

          // Chỉ bỏ khỏi chỉ mục những file đã thực sự bị xoá; file xoá lỗi vẫn
          // còn trên đĩa và vẫn tải/xoá được ở lần sau. Kiểm tra bất đồng bộ
          // (không chặn UI isolate) rồi mới gỡ khỏi chỉ mục.
          final removedPaths = <String>{};
          for (final segment in List<RecordedSegment>.of(_segments)) {
            final normalizedPath = segment.path.replaceAll('\\', '/');
            final inside =
                normalizedPath == normalizedDirectory ||
                normalizedPath.startsWith('$normalizedDirectory/');
            if (inside && !await File(segment.path).exists()) {
              removedPaths.add(segment.path);
            }
          }
          _segments.removeWhere(
            (segment) => removedPaths.contains(segment.path),
          );
          _notifyVideoChanges();
          developer.log(
            '[STORAGE] Removed past day directory: ${entity.path}',
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
    } catch (error, stackTrace) {
      developer.log(
        '[STORAGE] Error listing root directory for expired cleanup: $error',
        error: error,
        stackTrace: stackTrace,
        name: 'RecordingService',
      );
    }
    }
    await cleanupEmptyStorageDirectories(referenceTime: now);
  }

  Future<void> _deepDeleteDirectory(Directory dir) async {
    if (!await dir.exists()) return;
    try {
      final children = await dir.list(recursive: false).toList();
      for (final child in children) {
        if (child is Directory) {
          await _deepDeleteDirectory(child);
        } else if (child is File) {
          try {
            await child.delete();
          } catch (error) {
            developer.log(
              '[STORAGE] Unable to delete expired file ${child.path}: $error',
              name: 'RecordingService',
            );
          }
        }
      }
      try {
        await dir.delete();
      } catch (_) {
        if (Platform.isAndroid) {
          await _videoStorage.deleteDirectoryRecursively(dir.path);
        }
      }
    } catch (_) {}
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
    // Thư mục người dùng tự chọn không được đặt .nomedia ở gốc (sẽ ẩn ảnh của
    // họ); thay vào đó ẩn riêng thư mục ngày của app khỏi thư viện ảnh.
    if (_videoStorage.usesCustomRoot) {
      await _videoStorage.hideFromGallery(
        Directory('${root.path}${Platform.pathSeparator}$day'),
      );
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

  /// Chọn tên cơ sở chưa dùng (`HH-MM-SS_HH-MM-SS`, rồi `_1`, `_2`...) để
  /// hai segment trùng giây không ghi đè lên nhau.
  Future<String> _uniqueSegmentBaseName(
    Directory directory,
    String baseName,
  ) async {
    for (var attempt = 0; attempt < 1000; attempt++) {
      final candidate = segmentBaseNameCandidate(baseName, attempt);
      final prefix = '${directory.path}${Platform.pathSeparator}$candidate';
      if (!await File('$prefix.ts').exists() &&
          !await File('$prefix.mp4').exists()) {
        return candidate;
      }
    }
    return segmentBaseNameCandidate(
      baseName,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Chuyển MP4 staging sang TS (ghép WAV nếu có). [audioOffsetMs] là độ lệch
  /// A/V theo C2. [replaceFallbackPath]: thử lại cho bản MP4 dự phòng cũ —
  /// giữ đúng tên/thư mục của bản đó; FFmpeg ghi ra file tạm
  /// ([fallbackRetryTempPath]) và chỉ khi thành công mới thay bản cũ
  /// ([_installFallbackRetryOutput]); lỗi thì bản cũ còn nguyên.
  /// `preservedFallback` = true khi chỉ giữ được MP4 dự phòng và MP4/WAV
  /// staging được giữ lại để thử ghép tiếng lần sau. `deferred` = true khi
  /// ghép được nhưng bản cũ đang được đọc nên chưa thay (không tính là lần
  /// thử thất bại). [fallbackJournal]: journal của lượt thử lại, dùng để ghi
  /// khoá [fallbackPendingDeleteJournalKey] khi thay bản MP4 bằng TS.
  Future<({File file, bool preservedFallback, bool deferred})>
  _convertRecordingToTs(
    File source,
    DateTime startedAt,
    DateTime endedAt,
    File? nativeAudio, {
    String? facingMode,
    int? quarterTurns,
    int? audioOffsetMs,
    String? replaceFallbackPath,
    File? fallbackJournal,
  }) async {
    final effectiveRotation = calculateEffectiveVideoRotation(
      isIos: Platform.isIOS,
      facingMode: facingMode ?? _facingMode,
      quarterTurns: quarterTurns ?? _quarterTurns,
    );
    final filterArgs = switch (effectiveRotation) {
      180 => const ['-vf', 'hflip,vflip'],
      90 => const ['-vf', 'transpose=1'],
      270 => const ['-vf', 'transpose=2'],
      _ => const <String>[],
    };

    // Dùng ngày kết thúc để segment đi qua 0 giờ không bị lưu vào thư mục ngày
    // cũ rồi bị RemoveExpiredData xóa ngay.
    final Directory directory;
    final String baseName;
    if (replaceFallbackPath != null) {
      final previous = File(replaceFallbackPath);
      directory = previous.parent;
      final previousName = previous.uri.pathSegments.last;
      baseName = previousName.replaceFirst(
        RegExp(r'\.(mp4|ts)$', caseSensitive: false),
        '',
      );
    } else {
      directory = await _videoDirectory(date: endedAt);
      baseName = await _uniqueSegmentBaseName(
        directory,
        _videoFileName(startedAt: startedAt, endedAt: endedAt),
      );
    }
    final target = File(
      '${directory.path}${Platform.pathSeparator}$baseName.ts',
    );
    final isRetry = replaceFallbackPath != null;
    // Thử lại cho bản dự phòng: FFmpeg ghi ra file tạm cùng thư mục (không bị
    // chỉ mục nhận nhầm), chỉ thay bản cũ khi thành công và không ai đang đọc.
    final tsOutput = isRetry
        ? File(fallbackRetryTempPath(target.path))
        : target;
    final hasNativeAudio =
        nativeAudio != null &&
        await nativeAudio.exists() &&
        await nativeAudio.length() > 44;
    final audioOffsetArgs = hasNativeAudio
        ? audioOffsetInputArguments(audioOffsetMs)
        : const <String>[];
    if (audioOffsetArgs.isNotEmpty) {
      developer.log(
        'A/V sync: audio offset ${audioOffsetMs}ms -> $audioOffsetArgs',
        name: 'RecordingService',
      );
    }
    final audioInput = hasNativeAudio
        ? [...audioOffsetArgs, '-i', nativeAudio.path]
        : <String>[];
    final audioMap = hasNativeAudio ? '1:a:0?' : '0:a:0?';
    // Lọc gió, mưa và tạp âm cho file ghi trên cả Android và iOS (trước đây
    // Android chỉ có bộ lọc gió bậc 1, iOS chỉ có high-pass; không có khử ồn).
    final audioFilterArgs = hasNativeAudio
        ? const ['-af', outdoorAudioCleanupFilter]
        : const <String>[];

    ReturnCode? code;
    Session? session;
    final hardwareEncoder = _hardwareH264Encoder;

    // Stream copy chỉ dùng được khi video không cần xoay hoặc biến đổi khung hình.
    if (filterArgs.isEmpty) {
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
        'copy',
        ...audioFilterArgs,
        '-c:a',
        'aac',
        '-b:a',
        '128k',
        '-avoid_negative_ts',
        'make_zero',
        '-muxdelay',
        '0.5',
        '-muxpreload',
        '0.5',
        '-mpegts_flags',
        '+resend_headers+pat_pmt_at_frames',
        '-f',
        'mpegts',
        tsOutput.path,
      ]);
      code = await session.getReturnCode();
    }

    if (code == null || !ReturnCode.isSuccess(code)) {
      if (hardwareEncoder != null) {
        if (await tsOutput.exists()) await tsOutput.delete();
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
          ...filterArgs,
          '-threads',
          '1',
          '-c:v',
          hardwareEncoder,
          '-b:v',
          '8M',
          ...audioFilterArgs,
          '-c:a',
          'aac',
          '-b:a',
          '128k',
          '-avoid_negative_ts',
          'make_zero',
          '-muxdelay',
          '0.5',
          '-muxpreload',
          '0.5',
          '-mpegts_flags',
          '+resend_headers+pat_pmt_at_frames',
          '-f',
          'mpegts',
          tsOutput.path,
        ]);
        code = await session.getReturnCode();
      }
    }
    if (code == null || !ReturnCode.isSuccess(code)) {
      if (await tsOutput.exists()) await tsOutput.delete();
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
        ...filterArgs,
        '-threads',
        '1',
        '-c:v',
        'mpeg4',
        '-q:v',
        '4',
        ...audioFilterArgs,
        '-c:a',
        'aac',
        '-b:a',
        '128k',
        '-avoid_negative_ts',
        'make_zero',
        '-muxdelay',
        '0.5',
        '-muxpreload',
        '0.5',
        '-mpegts_flags',
        '+resend_headers+pat_pmt_at_frames',
        '-f',
        'mpegts',
        tsOutput.path,
      ]);
      code = await session.getReturnCode();
    }
    if (code == null ||
        !ReturnCode.isSuccess(code) ||
        !await tsOutput.exists() ||
        await tsOutput.length() <= 0) {
      final output = await session?.getOutput();
      if (await tsOutput.exists()) await tsOutput.delete();
      // Không được bỏ mất đoạn recorder đã ghi chỉ vì bước đóng gói TS lỗi.
      // Giữ nguyên MP4 trong thư mục video để segment vẫn xuất hiện và tải
      // được; lần ghi kế tiếp vẫn có thể tiếp tục bình thường.
      final fallback =
          replaceFallbackPath != null &&
              replaceFallbackPath.toLowerCase().endsWith('.mp4')
          ? File(replaceFallbackPath)
          : File('${directory.path}${Platform.pathSeparator}$baseName.mp4');
      // Thử lại: KHÔNG xoá bản dự phòng cũ trước khi ghép — ghép ra file tạm.
      final muxOutput = isRetry
          ? File(fallbackRetryTempPath(fallback.path))
          : fallback;
      if (await muxOutput.exists()) await muxOutput.delete();
      if (hasNativeAudio) {
        final muxSession = await FFmpegKit.executeWithArguments([
          '-y',
          '-i',
          source.path,
          ...audioOffsetArgs,
          '-i',
          nativeAudio.path,
          '-map',
          '0:v:0',
          '-map',
          '1:a:0',
          if (filterArgs.isNotEmpty) ...[
            ...filterArgs,
            '-c:v',
            'mpeg4',
            '-q:v',
            '4',
          ] else ...[
            '-c:v',
            'copy',
          ],
          ...audioFilterArgs,
          '-c:a',
          'aac',
          '-b:a',
          '128k',
          '-shortest',
          '-movflags',
          '+faststart',
          // File tạm không có đuôi .mp4: chỉ định định dạng rõ ràng.
          '-f',
          'mp4',
          muxOutput.path,
        ]);
        final muxCode = await muxSession.getReturnCode();
        final muxSucceeded =
            ReturnCode.isSuccess(muxCode) &&
            await muxOutput.exists() &&
            await muxOutput.length() > 0;
        if (muxSucceeded && replaceFallbackPath != null) {
          final outcome = await _installFallbackRetryOutput(
            temp: muxOutput,
            target: fallback,
            previous: File(replaceFallbackPath),
            journal: fallbackJournal,
          );
          if (outcome != FallbackReplacementAction.install) {
            // Hoãn (đang có người đọc) hoặc thay lỗi: bản cũ còn nguyên, giữ
            // nguồn staging để thử lại.
            return (
              file: File(replaceFallbackPath),
              preservedFallback: true,
              deferred: outcome == FallbackReplacementAction.defer,
            );
          }
        }
        if (muxSucceeded) {
          if (await source.exists()) await source.delete();
          if (await nativeAudio.exists()) await nativeAudio.delete();
          debugPrint('[VNVAR] MP4 WITH AUDIO FALLBACK SAVED: ${fallback.path}');
          return (file: fallback, preservedFallback: false, deferred: false);
        }
        if (await muxOutput.exists()) await muxOutput.delete();
      }
      if (replaceFallbackPath != null) {
        // Ghép lại vẫn lỗi: bản dự phòng cũ giữ nguyên, không chép đè.
        // Không có WAV thì nguồn staging không còn giúp được gì nữa.
        if (!hasNativeAudio) {
          if (await source.exists()) await source.delete();
        }
        developer.log(
          'Fallback audio mux retry failed; kept $replaceFallbackPath. '
          'FFmpeg: ${output ?? 'no error details'}',
          name: 'RecordingService',
        );
        return (
          file: File(replaceFallbackPath),
          preservedFallback: hasNativeAudio,
          deferred: false,
        );
      }
      // Copy lỗi (thường do đầy bộ nhớ) để lại file MP4 dở dang trong thư mục
      // video: xoá nó để chỉ mục không nhận một video hỏng. Nguồn staging +
      // journal vẫn còn để lần khôi phục sau thử lại.
      Future<void> discardPartialFallback() async {
        try {
          if (await fallback.exists()) await fallback.delete();
        } catch (_) {}
      }

      final File preserved;
      try {
        preserved = await source.copy(fallback.path);
      } catch (_) {
        await discardPartialFallback();
        rethrow;
      }
      if (!await preserved.exists() || await preserved.length() <= 0) {
        await discardPartialFallback();
        throw BilingualStateError(
          'Không thể lưu đoạn video cuối. '
              'FFmpeg: ${output ?? 'không có thông tin lỗi'}',
          'Unable to save the last video segment. '
              'FFmpeg: ${output ?? 'no error details'}',
        );
      }
      // Giữ lại cặp MP4/WAV staging khi mux audio thất bại. Lần dọn sau sẽ
      // thử ghép lại (tối đa maximumFallbackMuxAttempts lần, thay đúng bản
      // dự phòng này theo journal `preserved_fallback`) thay vì xóa WAV hợp
      // lệ và mất cơ hội ghép tiếng.
      if (!hasNativeAudio) {
        if (await source.exists()) await source.delete();
      }
      developer.log(
        'TS conversion failed; preserved original MP4: ${preserved.path}. '
        'FFmpeg: ${output ?? 'no error details'}',
        name: 'RecordingService',
      );
      debugPrint('[VNVAR] MP4 FALLBACK SAVED: ${preserved.path}');
      return (
        file: preserved,
        preservedFallback: hasNativeAudio,
        deferred: false,
      );
    }
    if (replaceFallbackPath != null) {
      // Lần thử lại thành công: đưa TS tạm vào chỗ rồi bỏ bản MP4 dự phòng
      // cũ (kiểm lease ngay trước khi xoá). Hoãn/lỗi thì bản cũ còn nguyên.
      final outcome = await _installFallbackRetryOutput(
        temp: tsOutput,
        target: target,
        previous: File(replaceFallbackPath),
        journal: fallbackJournal,
      );
      if (outcome != FallbackReplacementAction.install) {
        return (
          file: File(replaceFallbackPath),
          preservedFallback: true,
          deferred: outcome == FallbackReplacementAction.defer,
        );
      }
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
    return (file: target, preservedFallback: false, deferred: false);
  }

  /// Đưa kết quả ghép lại ([temp]) vào [target] và bỏ bản dự phòng cũ
  /// [previous] ([target] có thể trùng [previous] khi kết quả vẫn là MP4).
  /// Lease đọc của [previous] được kiểm NGAY trước khi đè/xoá: đang có người
  /// đọc thì hoãn (xoá file tạm, bản cũ giữ nguyên). Rename đè; rename lỗi
  /// (một số bộ nhớ Android) thì copy rồi xoá file tạm. File tạm luôn được
  /// dọn trước khi trả về. Khi [target] khác [previous] (MP4 -> TS), khoá
  /// [fallbackPendingDeleteJournalKey] được ghi vào [journal] TRƯỚC khi đưa
  /// TS vào chỗ và chỉ gỡ khi không còn cặp TS/MP4 trùng: crash ở giữa thì
  /// lần khôi phục sau ([_resolvePendingFallbackDelete]) bỏ bản MP4.
  Future<FallbackReplacementAction> _installFallbackRetryOutput({
    required File temp,
    required File target,
    required File previous,
    File? journal,
  }) async {
    var tempValid = false;
    try {
      tempValid = await temp.exists() && await temp.length() > 0;
    } catch (_) {}
    final overwritesPrevious = target.absolute.path == previous.absolute.path;
    final pendingJournal = tempValid && !overwritesPrevious ? journal : null;
    // Ghi khoá trước lần kiểm lease để giữa kiểm lease và rename không có
    // await nào.
    if (pendingJournal != null) {
      await _setJournalPendingDelete(pendingJournal, previous.path);
    }
    // true khi có thể còn cặp TS/MP4 trùng trên đĩa: giữ khoá cho lần khôi
    // phục sau xử lý.
    var keepPendingDelete = false;
    var action = fallbackReplacementAction(
      tempValid: tempValid,
      previousLeased: isFileReadActive(previous.path),
    );
    if (action == FallbackReplacementAction.install) {
      try {
        // Không có await nào giữa lần kiểm lease ở trên và lệnh rename.
        await temp.rename(target.path);
      } on FileSystemException catch (error) {
        developer.log(
          'Rename ${temp.path} -> ${target.path} failed, copying: $error',
          name: 'RecordingService',
        );
        action = fallbackReplacementAction(
          tempValid: true,
          previousLeased: overwritesPrevious && isFileReadActive(previous.path),
        );
        if (action == FallbackReplacementAction.install) {
          try {
            await temp.copy(target.path);
          } catch (copyError) {
            developer.log(
              'Unable to install fallback retry output ${target.path}: '
              '$copyError',
              name: 'RecordingService',
            );
            action = FallbackReplacementAction.discardTemp;
            if (!overwritesPrevious) {
              // Copy dở để lại TS cụt cạnh bản MP4: bỏ đi để chỉ mục không
              // ưu tiên nhầm bản TS hỏng.
              try {
                if (await target.exists()) await target.delete();
              } catch (_) {
                keepPendingDelete = true;
              }
            }
          }
        }
      }
    }
    if (action == FallbackReplacementAction.install && !overwritesPrevious) {
      // TS mới đã vào chỗ (chỉ mục chưa trỏ tới). Kiểm lease ngay trước khi
      // xoá bản MP4 cũ; có người vừa mở thì gỡ TS mới và hoãn.
      if (isFileReadActive(previous.path)) {
        try {
          await target.delete();
        } on PathNotFoundException {
          // Không còn TS nào cạnh bản MP4.
        } catch (_) {
          keepPendingDelete = true;
        }
        action = FallbackReplacementAction.defer;
        // Một lượt dựng chỉ mục có thể đã chen vào và trỏ sang TS.
        _replaceIndexedSegmentPath(target.path, previous.path);
      } else {
        try {
          await previous.delete();
        } on PathNotFoundException {
          // Đã bị xoá ở nơi khác: không còn gì để thay.
        } catch (error) {
          keepPendingDelete = true;
          developer.log(
            'Unable to remove superseded fallback ${previous.path}: $error',
            name: 'RecordingService',
          );
        }
      }
    }
    if (pendingJournal != null && !keepPendingDelete) {
      await _setJournalPendingDelete(pendingJournal, null);
    }
    try {
      if (await temp.exists()) await temp.delete();
    } catch (_) {}
    return action;
  }

  /// Ghi ([path] khác null) hoặc gỡ khoá [fallbackPendingDeleteJournalKey]
  /// trong [journal], giữ nguyên các trường khác (kể cả `state`). Journal
  /// không tồn tại/hỏng thì bỏ qua: chỉ mục vẫn không liệt kê trùng
  /// ([supersededFallbackVideoPairs]).
  Future<void> _setJournalPendingDelete(File journal, String? path) async {
    try {
      if (!await journal.exists()) return;
      final decoded = jsonDecode(await journal.readAsString());
      if (decoded is! Map<String, dynamic>) return;
      if (path == null) {
        if (!decoded.containsKey(fallbackPendingDeleteJournalKey)) return;
        decoded.remove(fallbackPendingDeleteJournalKey);
      } else {
        decoded[fallbackPendingDeleteJournalKey] = path;
      }
      decoded['updatedAtMs'] = DateTime.now().millisecondsSinceEpoch;
      await journal.writeAsString(jsonEncode(decoded), flush: true);
    } catch (error, stackTrace) {
      developer.log(
        'Unable to update pending fallback delete in ${journal.path}',
        error: error,
        stackTrace: stackTrace,
        name: 'RecordingService',
      );
    }
  }

  /// Chỉ dùng trong test (không có FFprobe): thay kết quả kiểm video đọc
  /// được. Null (mặc định) thì dùng FFprobe như bình thường.
  @visibleForTesting
  Future<bool> Function(File file)? debugPlayableVideoOverride;

  /// Chỉ dùng trong test: gọi [_installFallbackRetryOutput] với file giả lập
  /// đầu ra FFmpeg. Không đổi hành vi.
  @visibleForTesting
  Future<FallbackReplacementAction> debugInstallFallbackRetryOutput({
    required File temp,
    required File target,
    required File previous,
    File? journal,
  }) => _installFallbackRetryOutput(
    temp: temp,
    target: target,
    previous: previous,
    journal: journal,
  );

  Future<bool> _isPlayableVideo(File file) async {
    final override = debugPlayableVideoOverride;
    if (override != null) return override(file);
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

  /// Codec/kích thước/góc xoay của luồng video đầu tiên (null nếu probe lỗi).
  Future<VideoStreamSignature?> _probeVideoSignature(File file) async {
    try {
      if (!await file.exists()) return null;
      final session = await FFprobeKit.getMediaInformation(file.path);
      final information = session.getMediaInformation();
      if (information == null) return null;
      for (final stream in information.getStreams()) {
        if (stream.getType() != 'video') continue;
        return videoStreamSignatureFromProperties(stream.getAllProperties());
      }
      return null;
    } catch (error, stackTrace) {
      developer.log(
        'FFprobe stream signature failed: ${file.path}',
        error: error,
        stackTrace: stackTrace,
        name: 'RecordingService',
      );
      return null;
    }
  }

  /// `start_time` (giây) của file theo FFprobe; null nếu không đọc được.
  Future<double?> _probeStartTimeSeconds(File file) async {
    try {
      if (!await file.exists()) return null;
      final session = await FFprobeKit.getMediaInformation(file.path);
      return parseProbeStartTime(session.getMediaInformation()?.getStartTime());
    } catch (error, stackTrace) {
      developer.log(
        'FFprobe start_time failed: ${file.path}',
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
    Map<String, Object?>? extra,
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
      if (extra != null) values.addAll(extra);
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
    String? facingMode,
    int? quarterTurns,
    bool Function()? isCancelled,
  }) async {
    final stopping = _stopOperation;
    if (stopping != null) await stopping;
    // Yêu cầu dừng (ví dụ Tablet gọi /stop) đến trong lúc chờ lần dừng trước:
    // không được mở lại recorder sau lệnh dừng đó.
    if (isCancelled?.call() ?? false) return;

    if (facingMode != null) setFacingMode(facingMode);
    if (quarterTurns != null) setQuarterTurns(quarterTurns);

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
    _suspendedReason = null;
    final startCompleter = Completer<void>();
    _startOperation = startCompleter.future;

    try {
      // ========================================================
      // FIRST SEGMENT
      // ========================================================

      await _startNewSegment();

      // ========================================================
      // AUTO ROTATE BY THE CONFIGURED DURATION
      // ========================================================

      _segmentTimer?.cancel();
      _segmentTimer = null;
      if (_recording && !_stopping) {
        _segmentTimer = Timer(_segmentDuration, () {
          _rotateSegment();
        });
      }

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
    } finally {
      startCompleter.complete();
      if (identical(_startOperation, startCompleter.future)) {
        _startOperation = null;
      }
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
      throw BilingualStateError(
        'Không có video track để ghi.',
        'No video track to record.',
      );
    }

    await _ensureFreeSpaceForNewSegment();

    final now = DateTime.now();
    final timestamp = now.millisecondsSinceEpoch;
    final stagingDirectory = await _stagingDirectory();
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

    // The segment begins only after the native recorder has opened
    // successfully. Using the timestamp captured before recorder.start() made
    // the displayed/file-name start earlier than the first writable frame.
    final recorderStartedAt = DateTime.now();

    _recorder = recorder;
    // C2: mốc bắt đầu hình của segment, ghi ngay sau khi recorder.start xong.
    _currentVideoStartEpochMs = recorderStartedAt.millisecondsSinceEpoch;
    _setRecordingSuspended(null);

    _currentSegmentFacingMode = _facingMode;
    _currentSegmentQuarterTurns = _quarterTurns;

    _currentPath = path;
    _currentJournal = File('$path.json');
    try {
      await _currentJournal!.writeAsString(
        jsonEncode({
          'cameraId': cameraId,
          'startedAtMs': recorderStartedAt.millisecondsSinceEpoch,
          'videoStartEpochMs': recorderStartedAt.millisecondsSinceEpoch,
          'videoPath': path,
          'facingMode': _currentSegmentFacingMode,
          'quarterTurns': _currentSegmentQuarterTurns,
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

    _segmentStartedAt = recorderStartedAt;
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
        if (Platform.isIOS || _rotating) {
          // Calls, route changes and another audio app can temporarily own the
          // iOS audio session. Keep the court video instead of tearing down the
          // complete capture pipeline; the next segment retries microphone.
          // Android: lần mở mic đầu tiên vẫn bắt buộc (báo lỗi cho người vận
          // hành), nhưng khi chuyển segment giữa phiên mà mic bị app khác giữ
          // tạm thời thì ghi tiếp không tiếng thay vì dừng hẳn việc ghi sân.
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
        _currentVideoStartEpochMs = null;
        final journal = _currentJournal;
        _currentJournal = null;
        try {
          // Kết quả (map trạng thái) không cần ở đây; nhận mọi kiểu trả về.
          await _platformChannel.invokeMethod<Object?>(
            'stopNativeAudioSegment',
          );
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
        throw BilingualStateError(
          'Microphone bắt buộc nhưng không thể bắt đầu: $error',
          'Microphone is required but failed to start: $error',
        );
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
    final stagingAvailable = await _stagingAvailableBytes();
    switch (newSegmentStorageAction(
      videoAvailableBytes: available,
      stagingAvailableBytes: stagingAvailable,
      warningBytes: normalFreeSpaceThresholdBytes,
      minimumBytes: minimumStartFreeSpaceBytes,
    )) {
      case NewSegmentStorageAction.open:
        _setStorageSuspended(false);
        return;
      case NewSegmentStorageAction.openThenCleanup:
        // Vẫn trên mức chặn: mở recorder ngay, dọn dung lượng chạy nền để
        // việc chuyển segment không tạo khoảng trống không ghi.
        _setStorageSuspended(false);
        unawaited(
          enforceStorageLimit().catchError((
            Object error,
            StackTrace stackTrace,
          ) {
            developer.log(
              'Background storage cleanup before new segment failed',
              error: error,
              stackTrace: stackTrace,
              name: 'RecordingService',
            );
          }),
        );
        return;
      case NewSegmentStorageAction.suspendStaging:
        // Ổ chứa file tạm (khác ổ lưu video) gần đầy: xoá video không giải
        // phóng được chỗ ở ổ này.
        _setStorageSuspended(true);
        final freeMb = ((stagingAvailable ?? 0) / (1024 * 1024))
            .toStringAsFixed(0);
        throw StorageSafetyException(
          'Bộ nhớ trong (file tạm khi ghi) không đủ chỗ để bắt đầu segment '
          'mới ($freeMb MB còn trống).',
          'Not enough internal storage for recording temp files '
              '($freeMb MB left).',
        );
      case NewSegmentStorageAction.cleanupFirst:
        break;
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
      final freeMb = (available / (1024 * 1024)).toStringAsFixed(0);
      throw StorageSafetyException(
        'Không đủ dung lượng an toàn để bắt đầu segment mới '
        '($freeMb MB còn trống).',
        'Not enough free storage for a new segment ($freeMb MB left).',
      );
    }
    _setStorageSuspended(false);
  }

  /// Đặt/xoá trạng thái treo ghi (recorder không mở lại được). [reason]
  /// null = đã ghi lại bình thường.
  void _setRecordingSuspended(String? reason) {
    if (_suspendedReason == reason) return;
    final wasSuspended = _suspendedReason != null;
    _suspendedReason = reason;
    if (wasSuspended != (reason != null)) {
      debugPrint(
        '[VNVAR] RECORDING ${reason == null ? 'RESUMED' : 'SUSPENDED: $reason'}',
      );
    }
    _notifyVideoChanges();
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
      throw const CheckVarSegmentUnavailableException(
        'NOT_RECORDING',
        'Camera chưa bắt đầu ghi video.',
      );
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
      // Đang treo ghi (không có recorder) thì camera sẽ tự ghi lại: lỗi tạm
      // thời. Ngược lại đoạn vừa chốt không dùng được.
      throw CheckVarSegmentUnavailableException(
        currentStartedAt == null ? 'NOT_RECORDING' : 'NO_SEGMENT',
        'Không có file đang quay để chốt Check VAR.',
      );
    }
    return segment;
  }

  /// Chốt đoạn hiện tại và mở đoạn mới quanh một lần đổi nguồn tại chỗ (ví dụ
  /// đổi camera iOS mà không mở lại track), để mỗi đoạn chỉ có một hướng
  /// camera. [onRecorderStopped] chạy giữa hai đoạn.
  Future<RecordedSegment?> rotateSegmentForSourceChange({
    required Future<void> Function() onRecorderStopped,
  }) async {
    // Đang có lần chuyển segment khác (hết 3 phút/Check VAR): nếu nhập vào
    // lần đó thì việc đổi nguồn xảy ra GIỮA đoạn mới (đoạn có 2 hướng camera).
    // Chờ nó xong rồi tự cắt một ranh giới riêng cho lần đổi nguồn này.
    var current = _rotationOperation;
    while (current != null) {
      try {
        await current;
      } catch (_) {}
      if (identical(_rotationOperation, current)) break;
      current = _rotationOperation;
    }
    return _requestSegmentRotation(onRecorderStopped: onRecorderStopped);
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
    final starting = _startOperation;
    if (starting != null) await starting;
    if (!_recording) return null;

    _rotating = true;
    _segmentTimer?.cancel();
    _segmentTimer = null;
    // Lượt này chỉ là thử mở lại recorder khi đang treo ghi (không có file
    // nào để chốt): không thử thêm lần thứ hai ngay lập tức.
    final retryingSuspended = _recorder == null;
    // Lỗi mở recorder mới tại điểm bàn giao (null = chưa thử hoặc thành công).
    Object? openError;
    var openAttempted = false;
    Future<void> tryOpenNextSegment() async {
      if (!_recording || _stopping || _recorder != null) return;
      openAttempted = true;
      try {
        await _startNewSegment();
        openError = null;
      } catch (error, stackTrace) {
        openError = error;
        developer.log(
          'Unable to open the next recorder segment.',
          error: error,
          stackTrace: stackTrace,
          name: 'RecordingService',
        );
      }
    }

    try {
      final segment = await _finishCurrentSegment(
        onRecorderStopped: () async {
          if (onRecorderStopped != null) await onRecorderStopped();
          await tryOpenNextSegment();
        },
      );
      // Fallback khi hand-off chưa thử mở (onRecorderStopped của caller lỗi)
      // hoặc lỗi tạm thời không phải do dung lượng: thử thêm đúng một lần sau
      // khi file cũ đã được chốt. Thiếu dung lượng thì chờ nhịp thử lại.
      if (!openAttempted ||
          (!retryingSuspended && openError is! StorageSafetyException)) {
        if (_recorder == null) await tryOpenNextSegment();
      }
      // Không mở được recorder: không ném lỗi (segment cũ đã chốt xong, Check
      // VAR vẫn dùng được); chuyển sang trạng thái treo ghi + thử lại theo
      // nhịp ngắn ở finally.
      return segment;
    } catch (_) {
      // Chốt file cũ lỗi. Nếu recorder mới chưa được thử mở thì thử một lần
      // trước khi chuyển lỗi về caller của Check VAR.
      if (!openAttempted) await tryOpenNextSegment();
      rethrow;
    } finally {
      _rotating = false;
      if (_recording && !_stopping) {
        if (_recorder == null) {
          final error = openError;
          _setRecordingSuspended(
            error == null
                ? 'Không mở được segment ghi mới.'
                : userFacingError(error),
          );
        }
        _scheduleNextRotation();
      }
    }
  }

  /// Đặt timer cho lần xoay kế tiếp: hết thời lượng segment khi đang ghi,
  /// hoặc nhịp thử lại ngắn khi đang treo ghi (không có recorder).
  void _scheduleNextRotation() {
    _segmentTimer?.cancel();
    final startedAt = _segmentStartedAt;
    final Duration delay;
    if (_recorder == null || startedAt == null) {
      delay = suspendedRecorderRetryDelay(
        storageSuspended: _storageSuspended,
        nextStorageRetryAt: _nextStorageRetryAt,
        now: DateTime.now(),
      );
      developer.log(
        'Recorder suspended; retrying in ${delay.inSeconds}s '
        '(${_suspendedReason ?? 'unknown'})',
        name: 'RecordingService',
      );
    } else {
      delay = nextSegmentRotationDelay(
        startedAt: startedAt,
        now: DateTime.now(),
        segmentDuration: _segmentDuration,
      );
    }
    _segmentTimer = Timer(delay, _rotateSegment);
  }

  /// C3: gián đoạn âm thanh iOS kết thúc trong lúc đang ghi → xoay segment
  /// sớm để segment mới đồng bộ tiếng/hình lại từ đầu.
  Future<void> _handlePlatformEvent(MethodCall call) async {
    if (call.method != 'onNativeAudioInterruption') return;
    final arguments = call.arguments;
    final state = arguments is Map ? arguments['state'] : null;
    developer.log(
      'Native audio interruption: $arguments',
      name: 'RecordingService',
    );
    if (state != 'ended') return;
    // Không chồng thao tác: đang dừng/khởi động/xoay thì segment mới sắp mở
    // đã tự đồng bộ lại; đang treo ghi thì timer thử lại sẽ mở segment mới.
    if (!_recording ||
        _stopping ||
        _rotating ||
        _startOperation != null ||
        _rotationOperation != null ||
        _recorder == null) {
      return;
    }
    debugPrint('[VNVAR] AUDIO INTERRUPTION ENDED: ROTATING SEGMENT');
    // Không chờ: việc chốt segment (FFmpeg) mất vài giây, không được giữ
    // lời gọi native và các listener khác của kênh.
    unawaited(_rotateSegment());
  }

  // ============================================================
  // FINISH CURRENT SEGMENT
  // ============================================================

  Future<RecordedSegment?> _finishCurrentSegment({
    Future<void> Function()? onRecorderStopped,
  }) async {
    // Chụp hướng của chính đoạn này trước khi onRecorderStopped mở đoạn mới
    // (đoạn mới ghi đè _currentSegment*), nếu không đoạn cũ bị xuất theo
    // hướng mới khi người dùng xoay/đổi camera giữa chừng.
    final path = _currentPath;
    final segmentFacingMode = _currentSegmentFacingMode;
    final segmentQuarterTurns = _currentSegmentQuarterTurns;
    if (path != null) _finalizingPaths.add(path);
    try {
      return await _finishSegment(
        onRecorderStopped: onRecorderStopped,
        segmentFacingMode: segmentFacingMode,
        segmentQuarterTurns: segmentQuarterTurns,
      );
    } finally {
      if (path != null) _finalizingPaths.remove(path);
    }
  }

  Future<RecordedSegment?> _finishSegment({
    Future<void> Function()? onRecorderStopped,
    required String segmentFacingMode,
    required int segmentQuarterTurns,
  }) async {
    final recorder = _recorder;

    final path = _currentPath;

    final startedAt = _segmentStartedAt;
    final audioPath = _currentAudioPath;
    final journal = _currentJournal;
    final videoStartEpochMs = _currentVideoStartEpochMs;

    // Clear trước để tránh stop gọi hai lần.
    _recorder = null;

    _currentPath = null;

    _segmentStartedAt = null;
    _currentAudioPath = null;
    _currentJournal = null;
    _currentSegmentHasAudio = false;
    _currentVideoStartEpochMs = null;
    _notifyVideoChanges();

    if (recorder == null || path == null || startedAt == null) {
      // Không có recorder (đang treo ghi): vẫn LUÔN gọi onRecorderStopped để
      // việc bàn giao (mở lại recorder khi xoay, đổi camera, dispose camera
      // khi dừng) không bị bỏ qua.
      if (onRecorderStopped != null) {
        try {
          await onRecorderStopped();
        } catch (error, stackTrace) {
          developer.log(
            'Recorder hand-off failed while no recorder was open.',
            error: error,
            stackTrace: stackTrace,
            name: 'RecordingService',
          );
        }
      }
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
    num? firstSampleEpochMs;
    final audioStopFuture = Future<void>.sync(() async {
      if (!(Platform.isAndroid || Platform.isIOS) || audioPath == null) return;
      try {
        // C2: native trả map (có `firstSampleEpochMs`); bản native cũ có thể
        // trả null/kiểu khác nên không ép kiểu Map ở tầng kênh.
        final result = await _platformChannel.invokeMethod<Object?>(
          'stopNativeAudioSegment',
        );
        firstSampleEpochMs = firstSampleEpochMsFromStopResult(result);
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

    final audioOffsetMs = audioSyncOffsetMs(
      firstSampleEpochMs: firstSampleEpochMs,
      videoStartEpochMs: videoStartEpochMs,
    );
    if (audioOffsetMs != null) {
      // Lưu để khôi phục sau crash (bước chốt chưa xong) vẫn căn được tiếng.
      await _writeJournalState(
        journal,
        'finalizing',
        extra: {
          'firstSampleEpochMs': firstSampleEpochMs,
          'audioOffsetMs': audioOffsetMs,
        },
      );
    }

    // ==========================================================
    // STOP RECORDER
    // ==========================================================

    Object? recorderStopError = capturedRecorderStopError;
    StackTrace? recorderStopStack = capturedRecorderStopStack;
    if (capturedRecorderStopError != null) {
      final settled = await waitForRecordingFileToSettle(File(path));
      developer.log(
        'Recorder recovery file stability: ${settled ? 'stable' : 'timeout'}',
        name: 'RecordingService',
      );
      debugPrint(
        '[VNVAR] RECORDER RECOVERY FILE: ${settled ? 'STABLE' : 'TIMEOUT'}',
      );
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
    // File names and API metadata describe the actual recorder boundary.
    // Do not derive this value from the encoded timeline: iOS/WebRTC may leave
    // a large timestamp gap after an interruption, which previously produced
    // names such as 17-21-17_17-55-24 for a short segment.
    final mediaDuration = Duration(
      milliseconds: (videoProbe.durationSeconds! * 1000).round(),
    );
    final recorderStoppedAt = endedAt;
    final wallDuration = recorderStoppedAt.difference(startedAt);
    endedAt = segmentBoundaryEndedAt(
      startedAt: startedAt,
      recorderStoppedAt: recorderStoppedAt,
    );
    if ((mediaDuration - wallDuration).abs() > const Duration(seconds: 2)) {
      developer.log(
        'MEDIA TIMELINE MISMATCH: wall=${wallDuration.inMilliseconds}ms, '
        'media=${mediaDuration.inMilliseconds}ms, path=$path',
        name: 'RecordingService',
      );
      debugPrint(
        '[VNVAR] MEDIA TIMELINE MISMATCH: '
        'wall=${wallDuration.inMilliseconds}ms, '
        'media=${mediaDuration.inMilliseconds}ms',
      );
    }

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

    final converted = await _convertRecordingToTs(
      file,
      startedAt,
      endedAt,
      audioPath == null ? null : File(audioPath),
      facingMode: segmentFacingMode,
      quarterTurns: segmentQuarterTurns,
      audioOffsetMs: audioOffsetMs,
    );
    file = converted.file;

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
    // Quét/dọn dung lượng chạy nền: Check VAR và việc mở đoạn kế tiếp không
    // phải chờ duyệt toàn bộ thư mục lưu (có thể vài giây với 20 GB). Chỉ
    // quét toàn bộ cây khi cần (xem shouldRunFullStorageScanAfterSegment).
    unawaited(
      _enforceStorageLimitAfterSegment(
        savedSize,
      ).catchError((Object error, StackTrace stackTrace) {
        developer.log(
          'Background storage limit enforcement failed',
          error: error,
          stackTrace: stackTrace,
          name: 'RecordingService',
        );
      }),
    );
    // Dọn clip xuất tạm mồ côi (quá exportClipTtl) theo nhịp xoay segment.
    unawaited(
      cleanupExpiredExportDownloads().catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        developer.log(
          'Background export clip TTL cleanup failed',
          error: error,
          stackTrace: stackTrace,
          name: 'RecordingService',
        );
      }),
    );

    try {
      if (converted.preservedFallback) {
        // Giữ journal + MP4/WAV staging để lần dọn sau thử ghép tiếng lại,
        // ghi đè đúng bản dự phòng này (không tạo bản trùng tên khác).
        await _writeJournalState(
          journal,
          'preserved_fallback',
          finalPath: file.path,
          extra: {
            'startedAtMs': startedAt.millisecondsSinceEpoch,
            'endedAtMs': endedAt.millisecondsSinceEpoch,
            'muxAttempts': 1,
          },
        );
      } else {
        await _writeJournalState(journal, 'completed', finalPath: file.path);
        if (journal != null && await journal.exists()) await journal.delete();
      }
    } catch (error) {
      developer.log(
        'Unable to close recording journal ${journal?.path}: $error',
        name: 'RecordingService',
      );
    }

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

  /// Finds the finalized source that contains a wall-clock event. This lets a
  /// CheckVAR retry after a temporary network outage use the original event
  /// time without rotating or cutting the current recorder at the retry time.
  RecordedSegment? findByTime(DateTime eventTime) {
    for (final segment in _segments.reversed) {
      final startsBeforeOrAt = !eventTime.isBefore(segment.startedAt);
      final endsAfterOrAt = !eventTime.isAfter(segment.endedAt);
      if (startsBeforeOrAt && endsAfterOrAt) return segment;
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

  /// Dọn clip xuất tạm trong thư mục `download`.
  /// - [owner] null: xoá TOÀN BỘ clip (khởi động server, dispose).
  /// - [owner] khác null: một tablet đóng phiên tải — chỉ xoá clip của đúng
  ///   phiên đó, kèm các clip mồ côi quá [exportClipTtl].
  /// Clip đang có lease đọc HTTP không bao giờ bị xoá.
  Future<void> cleanupExportDownloads({String? owner}) {
    return _queueExportCleanup(owner: owner, removeAll: owner == null);
  }

  /// Chỉ dọn clip xuất tạm mồ côi (quá [exportClipTtl]) của mọi phiên.
  Future<void> cleanupExpiredExportDownloads() {
    return _queueExportCleanup(owner: null, removeAll: false);
  }

  /// Các lần dọn chạy nối tiếp (mỗi lần có phạm vi riêng), không gộp chung
  /// một future như trước: lần dọn theo phiên không được bị "nuốt" bởi một
  /// lần dọn TTL đang chạy.
  Future<void> _queueExportCleanup({
    required String? owner,
    required bool removeAll,
  }) {
    final previous = _exportCleanupOperation;
    final operation = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          // Lỗi lần trước đã được trả cho caller của nó.
        }
      }
      await _cleanupExportDownloadsInternal(
        owner: owner,
        removeAll: removeAll,
      );
    }();
    _exportCleanupOperation = operation;
    return operation.whenComplete(() {
      if (identical(_exportCleanupOperation, operation)) {
        _exportCleanupOperation = null;
      }
    });
  }

  Future<void> _cleanupExportDownloadsInternal({
    required String? owner,
    required bool removeAll,
  }) async {
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
    final now = DateTime.now();
    try {
      if (await directory.exists()) {
        await for (final entity in directory.list(recursive: true)) {
          if (entity is! File || isFileReadActive(entity.path)) continue;
          final record = _exportClipOwners[_exportClipKey(entity.path)];
          DateTime createdAt;
          DateTime? lastAccessedAt;
          if (record != null) {
            createdAt = record.createdAt;
            lastAccessedAt = record.lastAccessedAt;
          } else {
            try {
              createdAt = (await entity.stat()).modified;
            } catch (_) {
              createdAt = now;
            }
          }
          if (!shouldRemoveExportClip(
            clipOwner: record?.owner,
            createdAt: createdAt,
            lastAccessedAt: lastAccessedAt,
            now: now,
            closingOwner: owner,
            removeAll: removeAll,
          )) {
            continue;
          }
          try {
            await entity.delete();
          } catch (error) {
            developer.log(
              '[STORAGE] Unable to delete export clip ${entity.path}: $error',
              name: 'RecordingService',
            );
          }
        }
        await _deleteDirectoryTreeIfEmpty(directory);
      }
      // Đồng bộ chỉ mục với các file thực sự còn trên đĩa (kiểm tra bất đồng
      // bộ, không chặn UI isolate).
      final missingExportNames = <String>{};
      for (final entry in Map<String, RecordedSegment>.of(
        _exportSegments,
      ).entries) {
        if (!await File(entry.value.path).exists()) {
          missingExportNames.add(entry.key);
        }
      }
      final missingOwnerKeys = <String>{};
      for (final key in List<String>.of(_exportClipOwners.keys)) {
        if (!await File(key).exists()) missingOwnerKeys.add(key);
      }
      _exportSegments.removeWhere(
        (name, _) => missingExportNames.contains(name),
      );
      _exportClipOwners.removeWhere(
        (key, _) => missingOwnerKeys.contains(key),
      );
      developer.log(
        '[STORAGE] Temporary download clips cleaned '
        '(${removeAll ? 'all' : owner == null ? 'expired' : 'session'}).',
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

  /// Tablet xác nhận đã tải: chỉ đánh dấu, video vẫn giữ trên điện thoại.
  Future<bool> acknowledgeDownloaded(String segmentId) async {
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

    // Tablet đang tải file này: không xoá giữa chừng.
    if (isFileReadActive(segment.path)) return false;

    try {
      final file = File(segment.path);

      if (await file.exists()) {
        await file.delete();
      }

      // Xoá cả file đi kèm (âm thanh/metadata của các mảnh ghi) nếu có.
      for (final companion in fragmentCompanionPaths(segment.path)) {
        try {
          final extra = File(companion);
          if (await extra.exists()) await extra.delete();
        } catch (_) {}
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
    bool includeExportDownloads = true,
  }) async {
    // Phiên QR cũ không được tồn tại qua lần khởi động tiếp theo. Khi station
    // đang chạy (ví dụ mở màn Video đã lưu) thì giữ clip export tablet đang dùng.
    if (includeExportDownloads) await cleanupExportDownloads();
    await _cleanupAbandonedRecordings(maxAge: maxAge);
    // Mở màn hình chính/khởi động server: dọn toàn bộ thư mục ngày hết hạn
    // trước khi dựng lại chỉ mục video.
    await removeExpiredData();
    final roots = await _allVideoRoots();
    // Giữ nguyên segment đã biết (ID có mili-giây từ lúc ghi). Dựng lại từ tên
    // file chỉ có độ chính xác tới giây nên ID sẽ đổi và tablet mất liên kết.
    final previousByPath = {
      for (final segment in _segments) segment.path: segment,
    };
    // Dựng chỉ mục mới vào danh sách riêng rồi mới thay một lần: trong lúc
    // duyệt thư mục (có thể vài giây) tablet vẫn tìm/trim/tải được video cũ.
    final rebuilt = <RecordedSegment>[];
    // Bản MP4 dự phòng đã có TS thay thế cùng tên (crash/lượt quét chen vào
    // giữa lúc đưa TS vào chỗ và lúc xoá MP4): chỉ mục liệt kê một bản (TS,
    // hoặc MP4 khi lượt thay chưa hoàn tất — [preferFallbackMp4OverTs]),
    // không liệt kê trùng. Không xoá file ở đây.
    final supersededFallbacks = <String, String>{};
    for (final directory in roots) {
    final scannedVideoPaths = <String>[];
    try {
      await for (final entity in directory.list(recursive: true)) {
        if (entity is! File) {
          continue;
        }

        final lowerPath = entity.path.toLowerCase();
        if (!lowerPath.endsWith('.ts') && !lowerPath.endsWith('.mp4')) {
          continue;
        }
        scannedVideoPaths.add(entity.path);
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
          // `.mp4` là bản dự phòng khi đóng gói TS thất bại
          // (_convertRecordingToTs); phải được index lại sau khi khởi động.
          // Hậu tố `_1`, `_2`... khi hai segment trùng tên (không ghi đè).
          final newNameMatch = RegExp(
            r'^(\d{2})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})(_\d{1,3})?\.(ts|mp4)$',
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
            final duplicateSuffix = newNameMatch.group(7) ?? '';
            rebuilt.add(
              previousByPath[entity.path] ??
              RecordedSegment(
                id: '${indexedCameraId}_$timestamp$duplicateSuffix',
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
          rebuilt.add(
            previousByPath[entity.path] ??
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
    } catch (error, stackTrace) {
      developer.log(
        'Unable to list stored video directory: ${directory.path}',
        error: error,
        stackTrace: stackTrace,
        name: 'RecordingService',
      );
    }
    supersededFallbacks.addAll(
      supersededFallbackVideoPairs(
        scannedVideoPaths,
        storageRoot: directory.path,
      ),
    );
    }
    // Khoá pendingDelete còn trong journal staging: lượt thay MP4 -> TS chưa
    // hoàn tất (TS có thể dở dang) nên chỉ mục giữ bản MP4 và ẩn TS.
    final pendingFallbackDeletes = supersededFallbacks.isEmpty
        ? const <String>{}
        : await _pendingFallbackDeletePaths();
    // Từ đây tới lúc thay chỉ mục không còn await nào: quyết định ưu tiên bản
    // nào và danh sách gộp dựa trên cùng một trạng thái.
    // Đường dẫn bị ẩn vì trùng cặp TS/MP4: không được thêm lại khi gộp.
    final hiddenPaths = <String>{};
    if (supersededFallbacks.isNotEmpty) {
      final rebuiltByPath = {
        for (final segment in rebuilt) segment.path: segment,
      };
      final previousSegments = [...previousByPath.values, ..._segments];
      for (final entry in supersededFallbacks.entries) {
        final mp4Path = entry.key;
        final tsPath = entry.value;
        final preferMp4 = preferFallbackMp4OverTs(
          pendingDelete: pendingFallbackDeletes.contains(
            _fallbackPathKey(mp4Path),
          ),
          // Kiểm đồng bộ để không có await chen giữa: bản MP4 đã bị xoá
          // (lượt thay vừa xong) thì ưu tiên TS; TS đã bị gỡ (lượt thay
          // hoãn) thì giữ MP4.
          mp4Exists: File(mp4Path).existsSync(),
          tsExists: File(tsPath).existsSync(),
        );
        final preferredPath = preferMp4 ? mp4Path : tsPath;
        final hiddenPath = preferMp4 ? tsPath : mp4Path;
        final preferredSegment = rebuiltByPath[preferredPath];
        if (preferredSegment == null) continue;
        hiddenPaths.add(hiddenPath);
        rebuilt.remove(rebuiltByPath[hiddenPath]);
        // Bản được giữ chưa có trong chỉ mục: giữ ID/trạng thái của bản bị ẩn
        // để tablet không mất liên kết (như _replaceIndexedSegmentPath).
        if (previousByPath.containsKey(preferredPath)) continue;
        RecordedSegment? previousHidden;
        for (final segment in previousSegments) {
          if (segment.path == hiddenPath) {
            previousHidden = segment;
            break;
          }
        }
        if (previousHidden == null) continue;
        final preferredIndex = rebuilt.indexOf(preferredSegment);
        if (preferredIndex < 0) continue;
        rebuilt[preferredIndex] = RecordedSegment(
          id: previousHidden.id,
          cameraId: previousHidden.cameraId,
          path: preferredPath,
          startedAt: previousHidden.startedAt,
          endedAt: previousHidden.endedAt,
          type: previousHidden.type,
          downloaded: previousHidden.downloaded,
          joinedPrecedingSegment: previousHidden.joinedPrecedingSegment,
        );
      }
    }

    // Giữ các đoạn vừa ghi xong trong lúc đang duyệt (chưa có trong lần quét).
    // Đoạn đã có trong chỉ mục hiện tại thì giữ nguyên object (ID chính xác
    // tới mili-giây, trạng thái downloaded) thay vì bản dựng lại từ tên file.
    // Bản trùng vừa bị ẩn ở trên không được thêm lại.
    final currentByPath = {
      for (final segment in _segments) segment.path: segment,
    };
    final merged = [
      for (final segment in rebuilt) currentByPath[segment.path] ?? segment,
    ];
    final rebuiltPaths = {for (final segment in rebuilt) segment.path};
    for (final segment in _segments) {
      if (!previousByPath.containsKey(segment.path) &&
          !rebuiltPaths.contains(segment.path) &&
          !hiddenPaths.contains(segment.path)) {
        merged.add(segment);
      }
    }
    _segments
      ..clear()
      ..addAll(merged);
    _segments.sort((a, b) => a.startedAt.compareTo(b.startedAt));
    _notifyVideoChanges();
    await enforceStorageLimit();
    developer.log(
      'Loaded ${_segments.length} stored video segment(s)',
      name: 'RecordingService',
    );
  }

  /// Khoá so khớp đường dẫn bản MP4 dự phòng giữa journal và lần quét.
  static String _fallbackPathKey(String path) =>
      File(path).absolute.path.replaceAll('\\', '/');

  /// Đường dẫn ([_fallbackPathKey]) các bản MP4 dự phòng còn khoá
  /// [fallbackPendingDeleteJournalKey] trong journal staging, tức lượt thay
  /// bằng TS chưa hoàn tất. Journal hỏng/không đọc được thì bỏ qua.
  Future<Set<String>> _pendingFallbackDeletePaths() async {
    final result = <String>{};
    try {
      for (final directory in await _stagingScanDirectories()) {
        if (!await directory.exists()) continue;
        await for (final entity in directory.list()) {
          if (entity is! File ||
              !entity.path.toLowerCase().endsWith('.json')) {
            continue;
          }
          try {
            final decoded = jsonDecode(await entity.readAsString());
            if (decoded is! Map<String, dynamic>) continue;
            final pending = decoded[fallbackPendingDeleteJournalKey];
            if (pending is String && pending.isNotEmpty) {
              result.add(_fallbackPathKey(pending));
            }
          } catch (_) {
            // Journal đang được ghi dở hoặc hỏng: không đủ căn cứ để ẩn TS.
          }
        }
      }
    } catch (error, stackTrace) {
      developer.log(
        'Unable to read pending fallback deletes',
        error: error,
        stackTrace: stackTrace,
        name: 'RecordingService',
      );
    }
    return result;
  }

  /// Cleans only recorder staging files. This is safe to call while the
  /// station is running and avoids rebuilding the permanent video index.
  Future<void> cleanupStagingFiles({
    Duration maxAge = const Duration(hours: 24),
  }) async {
    await _cleanupAbandonedRecordings(maxAge: maxAge);
    // Clip xuất tạm mồ côi (tablet không gọi /download/session/close).
    await cleanupExpiredExportDownloads();
  }

  static num? _journalNumber(Object? value) =>
      value is num && value.isFinite ? value : null;

  /// Thử ghép tiếng lại cho một bản MP4 dự phòng (journal
  /// `preserved_fallback`): tối đa [maximumFallbackMuxAttempts] lần, luôn ghi
  /// đè đúng bản dự phòng cũ; hết lượt thì giữ bản dự phòng và dọn nguồn
  /// staging sau [maxAge] như nhánh invalid.
  Future<void> _retryPreservedFallback({
    required File video,
    required File wav,
    required File journal,
    required Map<String, dynamic> values,
    required Duration age,
    required Duration maxAge,
    required String? facingMode,
    required int? quarterTurns,
    required int? audioOffsetMs,
  }) async {
    final finalPathValue = values['finalPath'];
    final finalPath = finalPathValue is String && finalPathValue.isNotEmpty
        ? finalPathValue
        : null;
    final attemptsValue = values['muxAttempts'];
    final attempts = attemptsValue is num && attemptsValue.isFinite
        ? attemptsValue.toInt()
        : maximumFallbackMuxAttempts;
    // Crash giữa lúc đưa TS vào chỗ và lúc xoá bản MP4 cũ: hoàn tất trước khi
    // xét thử lại (kể cả khi đã hết lượt thử).
    if (values.containsKey(fallbackPendingDeleteJournalKey)) {
      final handled = await _resolvePendingFallbackDelete(
        video: video,
        wav: wav,
        journal: journal,
        pendingDelete: values[fallbackPendingDeleteJournalKey],
        finalPath: finalPath,
      );
      if (handled) return;
    }
    final finalExists = finalPath != null && await File(finalPath).exists();
    final action = preservedFallbackAction(
      attempts: attempts,
      finalExists: finalExists,
      finalLeased: finalPath != null && isFileReadActive(finalPath),
      age: age,
      maxAge: maxAge,
    );
    if (action == PreservedFallbackAction.keep) return;
    if (action == PreservedFallbackAction.discardSources || finalPath == null) {
      for (final file in <File>[video, wav, journal]) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      developer.log(
        'Preserved fallback sources discarded after $attempts attempt(s): '
        '${finalPath ?? video.path}',
        name: 'RecordingService',
      );
      return;
    }

    // Tăng bộ đếm TRƯỚC khi chạy FFmpeg: crash giữa chừng vẫn tính một lượt.
    await _writeJournalState(
      journal,
      'preserved_fallback',
      extra: {'muxAttempts': attempts + 1},
    );
    final startedAtMs = _journalNumber(values['startedAtMs']);
    final endedAtMs = _journalNumber(values['endedAtMs']);
    final startedAt = DateTime.fromMillisecondsSinceEpoch(
      (startedAtMs ?? 0).toInt(),
    );
    final endedAt = endedAtMs == null
        ? startedAt
        : DateTime.fromMillisecondsSinceEpoch(endedAtMs.toInt());
    final ({File file, bool preservedFallback, bool deferred}) converted;
    _fallbackRetriesInFlight++;
    try {
      converted = await _convertRecordingToTs(
        video,
        startedAt,
        endedAt,
        await wav.exists() ? wav : null,
        facingMode: facingMode,
        quarterTurns: quarterTurns,
        audioOffsetMs: audioOffsetMs,
        replaceFallbackPath: finalPath,
        fallbackJournal: journal,
      );
    } finally {
      _fallbackRetriesInFlight--;
    }
    if (converted.deferred) {
      // Bản dự phòng đang được đọc ngay lúc thay: không tính là một lần thử
      // thất bại — trả lại bộ đếm, giữ nguồn staging cho lần dọn sau.
      await _writeJournalState(
        journal,
        'preserved_fallback',
        extra: {'muxAttempts': attempts},
      );
      developer.log(
        'Fallback replacement deferred (file being read): $finalPath',
        name: 'RecordingService',
      );
      return;
    }
    if (converted.preservedFallback) {
      await _writeJournalState(
        journal,
        'preserved_fallback',
        finalPath: converted.file.path,
      );
      return;
    }
    _replaceIndexedSegmentPath(finalPath, converted.file.path);
    await _writeJournalState(
      journal,
      'completed',
      finalPath: converted.file.path,
    );
    if (await journal.exists()) await journal.delete();
    debugPrint('[VNVAR] FALLBACK AUDIO MUX RECOVERED: ${converted.file.path}');
  }

  /// Khôi phục khoá [fallbackPendingDeleteJournalKey] còn sót trong journal
  /// `preserved_fallback`. Trả về true khi đã xử lý xong lượt này (đã chốt
  /// TS thay bản MP4, hoặc bản MP4 đang được đọc nên chờ lần dọn sau); false
  /// thì tiếp tục xét thử lại như bình thường.
  Future<bool> _resolvePendingFallbackDelete({
    required File video,
    required File wav,
    required File journal,
    required Object? pendingDelete,
    required String? finalPath,
  }) async {
    final pendingPath = pendingDelete is String ? pendingDelete : null;
    final tsPath = pendingPath == null
        ? null
        : supersedingTsPathForFallback(pendingPath);
    var tsExists = false;
    var tsPlayable = false;
    if (tsPath != null) {
      final candidate = File(tsPath);
      try {
        tsExists = await candidate.exists() && await candidate.length() > 0;
      } catch (_) {}
      if (tsExists) tsPlayable = await _isPlayableVideo(candidate);
    }
    // Kiểm lease bản MP4 ngay trước khi xoá (không có await ở giữa).
    final action = pendingFallbackDeleteAction(
      pendingDelete: pendingDelete,
      finalPath: finalPath,
      tsExists: tsExists,
      tsPlayable: tsPlayable,
      mp4Leased: pendingPath != null && isFileReadActive(pendingPath),
    );
    if (action == PendingFallbackDeleteAction.none) return false;
    if (pendingPath == null || tsPath == null) {
      await _setJournalPendingDelete(journal, null);
      return false;
    }
    final ts = File(tsPath);
    final mp4 = File(pendingPath);
    switch (action) {
      case PendingFallbackDeleteAction.none:
        return false;
      case PendingFallbackDeleteAction.clearStale:
        await _setJournalPendingDelete(journal, null);
        return false;
      case PendingFallbackDeleteAction.discardBrokenTs:
        // TS dở dang do lượt thay trước để lại (khoá chỉ được ghi cho đúng
        // lần thay này); bản MP4 vẫn là bản đọc được.
        try {
          if (!isFileReadActive(ts.path)) await ts.delete();
        } catch (_) {}
        if (!await ts.exists()) {
          await _setJournalPendingDelete(journal, null);
        }
        return false;
      case PendingFallbackDeleteAction.waitForLease:
        return true;
      case PendingFallbackDeleteAction.deleteSuperseded:
        try {
          await mp4.delete();
        } on PathNotFoundException {
          // Đã được xoá trước khi crash.
        } catch (error) {
          developer.log(
            'Unable to remove superseded fallback ${mp4.path}: $error',
            name: 'RecordingService',
          );
          return true;
        }
        _replaceIndexedSegmentPath(mp4.path, ts.path);
        for (final file in <File>[video, wav]) {
          try {
            if (await file.exists()) await file.delete();
          } catch (_) {}
        }
        await _writeJournalState(journal, 'completed', finalPath: ts.path);
        try {
          if (await journal.exists()) await journal.delete();
        } catch (_) {}
        debugPrint('[VNVAR] FALLBACK REPLACEMENT COMPLETED: ${ts.path}');
        return true;
    }
  }

  /// Bản dự phòng đã được thay bằng file mới (TS có tiếng): giữ nguyên ID để
  /// tablet không mất liên kết, chỉ đổi đường dẫn.
  void _replaceIndexedSegmentPath(String oldPath, String newPath) {
    if (oldPath == newPath) return;
    final index = _segments.indexWhere((segment) => segment.path == oldPath);
    if (index < 0) return;
    final previous = _segments[index];
    _segments[index] = RecordedSegment(
      id: previous.id,
      cameraId: previous.cameraId,
      path: newPath,
      startedAt: previous.startedAt,
      endedAt: previous.endedAt,
      type: previous.type,
      downloaded: previous.downloaded,
      joinedPrecedingSegment: previous.joinedPrecedingSegment,
    );
    _notifyVideoChanges();
  }

  /// Single-flight: được gọi từ khởi động, màn hình video và dọn định kỳ;
  /// hai lượt chạy song song có thể convert cùng một MP4 staging hai lần.
  Future<void> _cleanupAbandonedRecordings({required Duration maxAge}) {
    final current = _abandonedCleanupOperation;
    if (current != null) return current;

    // Một instance mới (server khởi động lại) có thể bắt đầu dọn khi lượt
    // khôi phục của instance cũ (chạy nền) chưa xong: nối tiếp theo camera để
    // hai lượt không cùng chuyển một MP4 staging.
    final key = normalizeCameraKey(cameraId);
    final previous = _abandonedCleanupByCamera[key];
    final operation = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          // Lỗi của lượt trước đã được trả cho caller của nó.
        }
      }
      await _cleanupAbandonedRecordingsInternal(maxAge: maxAge);
    }();
    _abandonedCleanupOperation = operation;
    _abandonedCleanupByCamera[key] = operation;
    return operation.whenComplete(() {
      if (identical(_abandonedCleanupOperation, operation)) {
        _abandonedCleanupOperation = null;
      }
      if (identical(_abandonedCleanupByCamera[key], operation)) {
        _abandonedCleanupByCamera.remove(key);
      }
    });
  }

  static final Map<String, Future<void>> _abandonedCleanupByCamera =
      <String, Future<void>>{};

  Future<void> _cleanupAbandonedRecordingsInternal({
    required Duration maxAge,
  }) async {
    final directories = await _stagingScanDirectories();
    for (var index = 0; index < directories.length; index++) {
      // Thư mục chính (index 0) là nơi recorder đang/sắp ghi: không xoá kể cả
      // khi rỗng (xoá đúng lúc recorder mở file mới làm mở segment lỗi).
      // Thư mục cũ trong cache thì xoá khi đã rỗng.
      await _cleanupAbandonedRecordingsIn(
        directories[index],
        maxAge: maxAge,
        deleteIfEmpty: index > 0,
      );
    }
  }

  Future<void> _cleanupAbandonedRecordingsIn(
    Directory directory, {
    required Duration maxAge,
    required bool deleteIfEmpty,
  }) async {
    if (!await directory.exists()) return;

    final now = DateTime.now();
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.mp4')) {
        continue;
      }
      // Đọc lại _currentPath cho từng file: recorder có thể đã mở segment
      // mới sau khi lượt dọn bắt đầu (dọn chạy nền lúc khởi động).
      final activePath = _currentPath;
      if (activePath != null && entity.path == activePath) continue;
      if (_finalizingPaths.contains(entity.path)) continue;
      try {
        final stat = await entity.stat();
        // File vừa được ghi gần đây có thể đang được recorder/FFmpeg dùng.
        if (isRecentlyModifiedStagingFile(
          modified: stat.modified,
          now: DateTime.now(),
        )) {
          continue;
        }
        // Kiểm tra lại sau await (stat): recorder có thể vừa nhận file này.
        if (entity.path == _currentPath ||
            _finalizingPaths.contains(entity.path)) {
          continue;
        }
        final fileName = entity.uri.pathSegments.last;
        final prefix = '${cameraId}_';
        final timestampText = fileName
            .replaceFirst(prefix, '')
            .replaceFirst(RegExp(r'\.mp4$', caseSensitive: false), '');
        final timestamp = int.tryParse(timestampText);
        if (fileName.startsWith(prefix) && timestamp != null && stat.size > 0) {
          final journal = File('${entity.path}.json');
          final wav = File(
            entity.path.replaceFirst(
              RegExp(r'\.mp4$', caseSensitive: false),
              '.wav',
            ),
          );
          // Hướng lúc quay và độ lệch A/V được lưu trong journal; dùng lại khi
          // khôi phục sau crash thay vì hướng hiện tại của camera.
          String? journalFacingMode;
          int? journalQuarterTurns;
          int? journalAudioOffsetMs;
          Map<String, dynamic>? journalValues;
          if (await journal.exists()) {
            try {
              final decoded = jsonDecode(await journal.readAsString());
              if (decoded is Map<String, dynamic>) journalValues = decoded;
            } catch (_) {
              // A damaged journal does not prove the media is damaged; FFprobe
              // below remains the source of truth.
            }
          }
          if (journalValues != null) {
            final facing = journalValues['facingMode'];
            final turns = journalValues['quarterTurns'];
            if (facing is String) journalFacingMode = facing;
            if (turns is num) journalQuarterTurns = turns.toInt();
            final offset = journalValues['audioOffsetMs'];
            journalAudioOffsetMs = offset is num && offset.isFinite
                ? offset.round()
                : audioSyncOffsetMs(
                    firstSampleEpochMs: _journalNumber(
                      journalValues['firstSampleEpochMs'],
                    ),
                    videoStartEpochMs: _journalNumber(
                      journalValues['videoStartEpochMs'],
                    ),
                  );
            final state = journalValues['state'];
            if (state == 'invalid') {
              if (now.difference(stat.modified) >= maxAge) {
                await entity.delete();
                await journal.delete();
              }
              continue;
            }
            if (state == 'preserved_fallback') {
              await _retryPreservedFallback(
                video: entity,
                wav: wav,
                journal: journal,
                values: journalValues,
                age: now.difference(stat.modified),
                maxAge: maxAge,
                facingMode: journalFacingMode,
                quarterTurns: journalQuarterTurns,
                audioOffsetMs: journalAudioOffsetMs,
              );
              continue;
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
          final converted = await _convertRecordingToTs(
            entity,
            startedAt,
            endedAt,
            await wav.exists() ? wav : null,
            facingMode: journalFacingMode,
            quarterTurns: journalQuarterTurns,
            audioOffsetMs: journalAudioOffsetMs,
          );
          final recovered = converted.file;
          if (converted.preservedFallback) {
            // Lưu tên bản dự phòng + số lần thử: lần dọn sau ghép lại đúng
            // bản này thay vì tạo bản trùng với endedAt khác.
            await _writeJournalState(
              journal,
              'preserved_fallback',
              finalPath: recovered.path,
              extra: {
                'startedAtMs': startedAt.millisecondsSinceEpoch,
                'endedAtMs': endedAt.millisecondsSinceEpoch,
                'muxAttempts': 1,
              },
            );
          } else {
            await _writeJournalState(
              journal,
              'completed',
              finalPath: recovered.path,
            );
            if (await journal.exists()) await journal.delete();
          }
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
        // Journal còn MP4 staging đi kèm (ví dụ `preserved_fallback`) được
        // vòng MP4 phía trên quản lý; xoá ở đây sẽ làm MP4 bị khôi phục lại
        // như sau crash và sinh bản trùng.
        final companion = File(
          entity.path.replaceFirst(
            RegExp(r'\.json$', caseSensitive: false),
            '',
          ),
        );
        if (companion.path != entity.path && await companion.exists()) {
          continue;
        }
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
    if (deleteIfEmpty) await _deleteDirectoryIfEmpty(directory);
  }

  Future<int> storageSizeBytes() async {
    final root = await _videoRootDirectory();
    var total = 0;
    await for (final entity in root.list(recursive: true)) {
      if (entity is File &&
          isManagedStorageFilePath(entity.path, storageRoot: root.path)) {
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

  Future<void> performAutoCleanup() {
    final current = _autoCleanupOperation;
    if (current != null) return current;

    final operation = _performAutoCleanupInternal();
    _autoCleanupOperation = operation;
    return operation.whenComplete(() {
      if (identical(_autoCleanupOperation, operation)) {
        _autoCleanupOperation = null;
      }
    });
  }

  Future<void> _performAutoCleanupInternal() async {
    for (var pass = 0; pass < autoCleanupMaxPasses; pass++) {
      final available = await availableStorageBytes();
      if (available == null || available >= normalFreeSpaceThresholdBytes) {
        break;
      }

      final deleted = await _deleteOldestAutoModeBatch();
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
    if (deletedAny) {
      await cleanupEmptyStorageDirectories();
    }
    return deletedAny;
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

  /// Dọn sạch các thư mục cũ và thư mục rỗng trong thư mục lưu trữ video.
  ///
  /// - Thư mục ngày hiện tại (`today`) luôn được bảo vệ để không ảnh hưởng
  ///   phiên quay video đang hoạt động hoặc sắp bắt đầu; trong đó chỉ dọn
  ///   file tạm `*.retry.tmp` đã cũ ([isStaleFallbackRetryTemp]).
  /// - Thư mục `download` tạm thời không bị can thiệp ở đây (đã có luồng riêng).
  /// - Quét đệ quy từ nhánh con sâu nhất lên (post-order traversal). Nếu thư
  ///   mục không còn chứa file video nào, dọn các file rác mồ côi (.wav, .json, .tmp)
  ///   và xóa thư mục nếu rỗng.
  Future<void> cleanupEmptyStorageDirectories({DateTime? referenceTime}) async {
    final Directory root;
    try {
      root = await _videoRootDirectory();
      if (!await root.exists()) return;
    } catch (_) {
      return;
    }

    final now = referenceTime ?? DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final todayName = '${two(now.day)}-${two(now.month)}-${now.year}';

    try {
      final entities = await root.list().toList();
      for (final entity in entities.whereType<Directory>()) {
        final dirName = entity.uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last;

        if (dirName.toLowerCase() == 'download') continue;
        if (dirName == todayName) {
          // Thư mục hôm nay được bảo vệ: chỉ dọn file tạm thử ghép lại
          // (`*.retry.tmp`) đã cũ, không đụng file hay thư mục nào khác.
          await _cleanStaleRetryTempsRecursively(entity);
          continue;
        }
        // Chỉ dọn thư mục ngày do app tạo, không đụng thư mục của người dùng.
        if (!RegExp(r'^\d{2}-\d{2}-\d{4}$').hasMatch(dirName)) continue;

        await _cleanDirectoryRecursively(entity);
      }
    } catch (error, stackTrace) {
      developer.log(
        '[STORAGE] Error cleaning empty directories: $error',
        error: error,
        stackTrace: stackTrace,
        name: 'RecordingService',
      );
    }
  }

  Future<void> _cleanDirectoryRecursively(Directory directory) async {
    if (!await directory.exists()) return;

    final children = await directory.list().toList();
    for (final child in children.whereType<Directory>()) {
      await _cleanDirectoryRecursively(child);
    }

    final remaining = await directory.list().toList();
    final remainingFiles = remaining.whereType<File>().toList();
    final hasVideo = remainingFiles.any(_isVideoFile);

    // Nếu thư mục không còn bất kỳ video nào và không có thư mục con,
    // dọn các file phụ trợ mồ côi (.wav, .json, .tmp, file ẩn hệ điều hành)
    if (!hasVideo && remaining.whereType<Directory>().isEmpty) {
      for (final file in remainingFiles) {
        if (!isOrphanAuxiliaryFile(file.path)) continue;
        if (!isFileReadActive(file.path)) {
          try {
            await file.delete();
          } catch (error) {
            developer.log(
              '[STORAGE] Unable to delete orphan file ${file.path}: $error',
              name: 'RecordingService',
            );
          }
        }
      }
    } else {
      // Thư mục còn video (hoặc thư mục con): chỉ dọn file tạm thử ghép lại
      // (`*.retry.tmp`) sót sau crash — đã cũ và không có lượt thử nào đang
      // chạy. Không đụng file khác.
      await _deleteStaleRetryTemps(remainingFiles);
    }

    await _deleteDirectoryIfEmpty(directory);
  }

  /// Chỉ dọn `*.retry.tmp` đã cũ trong [directory] và thư mục con (dùng cho
  /// thư mục ngày hôm nay). Không xoá file hay thư mục nào khác.
  Future<void> _cleanStaleRetryTempsRecursively(Directory directory) async {
    final files = <File>[];
    try {
      await for (final entity in directory.list(recursive: true)) {
        if (entity is File &&
            entity.path.toLowerCase().endsWith(fallbackRetryTempSuffix)) {
          files.add(entity);
        }
      }
    } catch (error) {
      developer.log(
        '[STORAGE] Unable to list ${directory.path} for retry temps: $error',
        name: 'RecordingService',
      );
    }
    await _deleteStaleRetryTemps(files);
  }

  /// Xoá các file tạm thử ghép lại trong [files] khi đã cũ hơn
  /// [staleFallbackRetryTempAge], không có lượt thử nào đang chạy và không
  /// có lease đọc. File khác bị bỏ qua.
  Future<void> _deleteStaleRetryTemps(List<File> files) async {
    final now = DateTime.now();
    for (final file in files) {
      if (!file.path.toLowerCase().endsWith(fallbackRetryTempSuffix)) {
        continue;
      }
      try {
        final modified = (await file.stat()).modified;
        if (!isStaleFallbackRetryTemp(
              path: file.path,
              modified: modified,
              now: now,
              retryInFlight: _fallbackRetriesInFlight > 0,
            ) ||
            isFileReadActive(file.path)) {
          continue;
        }
        await file.delete();
      } catch (error) {
        developer.log(
          '[STORAGE] Unable to delete stale retry temp ${file.path}: $error',
          name: 'RecordingService',
        );
      }
    }
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

  DateTime? _lastStorageEnforcedAt;

  /// Lần quét dung lượng toàn bộ thư mục gần nhất.
  DateTime? get lastStorageEnforcedAt => _lastStorageEnforcedAt;

  // Ước lượng tổng dung lượng video do app quản lý (cập nhật tăng dần sau mỗi
  // segment, đặt lại sau mỗi lần quét toàn bộ cây thư mục).
  int? _estimatedManagedBytes;
  DateTime? _lastFullStorageScanAt;

  /// Sau khi chốt một segment ([addedBytes]): cộng dồn ước lượng dung lượng;
  /// chỉ quét toàn bộ thư mục lưu khi cần thay vì sau mỗi segment.
  Future<void> _enforceStorageLimitAfterSegment(int addedBytes) async {
    final estimate = _estimatedManagedBytes;
    if (estimate != null) _estimatedManagedBytes = estimate + addedBytes;
    final available = await availableStorageBytes();
    final lowStorage =
        _lowStorageWarning ||
        _storageSuspended ||
        (available != null && available < normalFreeSpaceThresholdBytes);
    if (!shouldRunFullStorageScanAfterSegment(
      estimatedManagedBytes: _estimatedManagedBytes,
      storageLimitBytes: storageLimitBytes,
      lowStorage: lowStorage,
      lastFullScanAt: _lastFullStorageScanAt,
      now: DateTime.now(),
    )) {
      return;
    }
    await enforceStorageLimit();
  }

  Future<void> _enforceStorageLimitInternal() async {
    _lastStorageEnforcedAt = DateTime.now();
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
    final roots = await _allVideoRoots();
    final files = <({File file, FileStat stat, String day})>[];
    var total = 0;
    for (final root in roots) {
    await for (final entity in root.list(recursive: true)) {
      if (entity is! File) continue;
      final normalizedPath = entity.path.replaceAll('\\', '/').toLowerCase();
      if (normalizedPath.contains('/download/')) continue;
      try {
        final stat = await entity.stat();
        if (isManagedStorageFilePath(entity.path, storageRoot: root.path)) {
          total += stat.size;
        }
        // Chỉ xoá video do app tạo; file của người dùng trong thư mục dùng
        // chung (DCIM...) không bao giờ bị đưa vào danh sách xoá.
        if (!isAppManagedVideoPath(entity.path, storageRoot: root.path)) {
          continue;
        }
        final normalized = entity.path.replaceAll('\\', '/');
        final match = RegExp(
          r'/([0-9]{2}-[0-9]{2}-[0-9]{4})/',
        ).firstMatch(normalized);
        files.add((file: entity, stat: stat, day: match?.group(1) ?? ''));
      } catch (_) {}
    }
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
    // Mốc cho việc cộng dồn sau mỗi segment. Dọn tiếp theo (thiếu dung lượng,
    // thư mục ngày hết hạn) chỉ làm tổng thật nhỏ hơn ước lượng này.
    _estimatedManagedBytes = total;
    _lastFullStorageScanAt = DateTime.now();

    // PerformAutoCleanup: nếu bộ nhớ trống dưới 1 GB, xóa AUTOMODE theo từng
    // lô 10 mốc thời gian, tối đa 50 lượt.
    await performAutoCleanup();

    // Sau mỗi chu kỳ dọn dung lượng, xóa đệ quy toàn bộ thư mục ngày hết hạn,
    // bao gồm các trận đấu và thư mục AUTOMODE.
    await removeExpiredData();
    await cleanupEmptyStorageDirectories();
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

  Future<RecordedSegment?> stop({Future<void> Function()? onRecorderStopped}) {
    final current = _stopOperation;
    if (current != null) return current;

    final operation = _stopInternal(onRecorderStopped: onRecorderStopped);
    _stopOperation = operation;
    return operation.whenComplete(() {
      if (identical(_stopOperation, operation)) _stopOperation = null;
    });
  }

  Future<RecordedSegment?> _stopInternal({
    Future<void> Function()? onRecorderStopped,
  }) async {
    _stopping = true;
    RecordedSegment? rotatedSegment;

    try {
      // ========================================================
      // STOP TIMER FIRST
      // ========================================================

      // Chờ start() đang chạy xong rồi mới huỷ timer: start() có thể vừa tạo
      // timer mới, huỷ trước thì timer đó sống sót và cắt sớm lần ghi sau.
      final starting = _startOperation;
      if (starting != null) await starting;

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

      final finalSegment = await _finishCurrentSegment(
        onRecorderStopped: onRecorderStopped,
      );

      developer.log('Recording stopped', name: 'RecordingService');
      return finalSegment ?? rotatedSegment;
    } finally {
      _recording = false;
      _suspendedReason = null;
      _videoTrack = null;
      _recordAudio = false;
      _stopping = false;
    }
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  Future<void> dispose({Future<void> Function()? onRecorderStopped}) async {
    StationPlatformEvents.instance.removeListener(this);
    _segmentTimer?.cancel();

    _segmentTimer = null;

    try {
      final stopping = _stopOperation;
      if (stopping != null) {
        await stopping;
      } else if (_recording || _recorder != null) {
        await stop(onRecorderStopped: onRecorderStopped);
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
