import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/return_code.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'station_errors.dart';
import 'station_platform_events.dart';

/// Gọi một method native trên kênh `vnvar/camera_station_service`.
typedef VideoExportNativeInvoker =
    Future<Object?> Function(String method, Map<String, Object?> arguments);

/// Chạy FFmpeg với danh sách tham số; trả `true` khi thành công.
typedef VideoExportRemuxer = Future<bool> Function(List<String> arguments);

/// Tên ứng dụng ảnh của máy để hiển thị: Android gọi là "Bộ sưu tập"
/// (Gallery), iPhone là "Ảnh" (Photos).
String galleryNameVi() => Platform.isIOS ? 'Ảnh' : 'Bộ sưu tập';
String galleryNameEn() => Platform.isIOS ? 'Photos' : 'Gallery';

/// Phân loại lỗi khi lưu bản sao video vào Thư viện ảnh.
enum VideoExportErrorCode {
  /// Người dùng chưa cấp / đã từ chối quyền lưu vào Thư viện ảnh.
  permissionDenied,

  /// File nguồn không còn tồn tại.
  notFound,

  /// Không chuyển được video sang MP4.
  convertFailed,

  /// Hệ thống từ chối lưu (hết dung lượng, lỗi MediaStore/Photos...).
  saveFailed,

  /// Nền tảng không hỗ trợ (desktop, test).
  unsupported,
}

/// Lỗi lưu video vào Thư viện ảnh, có sẵn thông báo hai ngôn ngữ.
class VideoExportException implements Exception, BilingualMessage {
  const VideoExportException(
    this.code, {
    required this.messageVi,
    required this.messageEn,
    this.cause,
  });

  factory VideoExportException.fromCode(
    VideoExportErrorCode code, {
    Object? cause,
  }) {
    final (vi, en) = switch (code) {
      VideoExportErrorCode.permissionDenied => (
        'Chưa có quyền lưu vào ${galleryNameVi()}.',
        'No permission to save to ${galleryNameEn()}.',
      ),
      VideoExportErrorCode.notFound => (
        'Video không còn tồn tại.',
        'The video no longer exists.',
      ),
      VideoExportErrorCode.convertFailed => (
        'Không chuyển được video sang MP4.',
        "Couldn't convert the video to MP4.",
      ),
      VideoExportErrorCode.saveFailed => (
        'Không lưu được video vào máy.',
        "Couldn't save the video to this device.",
      ),
      VideoExportErrorCode.unsupported => (
        'Thiết bị này không hỗ trợ lưu video.',
        'Saving videos is not supported on this device.',
      ),
    };
    return VideoExportException(
      code,
      messageVi: vi,
      messageEn: en,
      cause: cause,
    );
  }

  final VideoExportErrorCode code;

  @override
  final String messageVi;

  @override
  final String messageEn;

  /// Lỗi gốc (PlatformException, FileSystemException...) để ghi log.
  final Object? cause;

  bool get isPermissionDenied => code == VideoExportErrorCode.permissionDenied;

  @override
  String toString() => messageVi;
}

/// Lưu MỘT BẢN SAO video vào Thư viện ảnh / Bộ sưu tập của máy (album
/// [albumName]) để người dùng xem/chia sẻ bằng app khác (C9).
///
/// Bản gốc vẫn nằm trong thư mục riêng của app (.nomedia, xoá theo ngày) và
/// không bị đổi. File MPEG-TS được remux sang MP4 tạm (Photos iOS và nhiều
/// trình xem ảnh không phát được .ts); file tạm luôn bị xoá sau khi lưu.
class VideoExportService {
  VideoExportService({
    VideoExportNativeInvoker? invokeNative,
    VideoExportRemuxer? remux,
    Future<Directory> Function()? temporaryDirectory,
  }) : _invokeNative = invokeNative ?? _defaultInvokeNative,
       _remux = remux ?? _defaultRemux,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  static final VideoExportService instance = VideoExportService();

  /// Tên album trong Thư viện ảnh (iOS) / thư mục `Movies/<album>` (Android).
  static const String albumName = 'SportO Cam';

  static const String _tempFolderName = 'vnvar_gallery_export';

  final VideoExportNativeInvoker _invokeNative;
  final VideoExportRemuxer _remux;
  final Future<Directory> Function() _temporaryDirectory;

  /// Các lượt lưu đang chạy theo đường dẫn: bấm lại cùng file khi đang lưu
  /// sẽ dùng chung lượt đang chạy, không lưu hai bản.
  final Map<String, Future<void>> _inFlight = <String, Future<void>>{};

  /// File cần remux sang MP4 trước khi lưu: mọi đuôi khác `.mp4` / `.mov`
  /// (chủ yếu `.ts` MPEG-TS của bản ghi).
  static bool needsRemux(String path) {
    final extension = _extensionOf(path);
    return extension != '.mp4' && extension != '.mov';
  }

  /// Tên file hiển thị trong Thư viện ảnh: giữ tên gốc, đuôi `.mp4`
  /// (giữ `.mov` nếu nguồn là `.mov` vì không remux). Ký tự không hợp lệ
  /// trong tên file được thay bằng `_`.
  static String galleryFileName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    final name = slash >= 0 ? normalized.substring(slash + 1) : normalized;
    final dot = name.lastIndexOf('.');
    var base = dot > 0 ? name.substring(0, dot) : name;
    base = base
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .trim()
        .replaceAll(RegExp(r'^\.+'), '');
    if (base.isEmpty) base = 'video';
    final extension = _extensionOf(path) == '.mov' ? '.mov' : '.mp4';
    return '$base$extension';
  }

  /// Khoá chống chạy trùng: cùng file (đường dẫn tuyệt đối, bỏ khác biệt
  /// `\`/`/`) cho cùng khoá.
  static String inFlightKey(String path) =>
      File(path).absolute.path.replaceAll('\\', '/');

  static String _extensionOf(String path) {
    final normalized = path.replaceAll('\\', '/');
    final name = normalized.substring(normalized.lastIndexOf('/') + 1);
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return '';
    return name.substring(dot).toLowerCase();
  }

  /// Đang lưu file [path]?
  bool isSaving(String path) => _inFlight.containsKey(inFlightKey(path));

  /// Lưu bản sao [path] vào Thư viện ảnh (album [albumName]).
  ///
  /// Ném [VideoExportException] khi lỗi ([VideoExportException.isPermissionDenied]
  /// khi thiếu quyền). Gọi lại cùng file khi lượt trước chưa xong sẽ chờ chính
  /// lượt đó thay vì lưu thêm một bản.
  Future<void> saveToGallery(String path) {
    final key = inFlightKey(path);
    final running = _inFlight[key];
    if (running != null) return running;
    final future = _save(path);
    _inFlight[key] = future;
    // Xoá khỏi danh sách khi xong (kể cả lỗi); lỗi vẫn trả về người gọi qua
    // [future], nhánh này chỉ bắt để không thành lỗi chưa xử lý.
    unawaited(
      future.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        if (identical(_inFlight[key], future)) _inFlight.remove(key);
      }),
    );
    return future;
  }

  Future<void> _save(String path) async {
    final source = File(path);
    if (!await source.exists()) {
      throw VideoExportException.fromCode(VideoExportErrorCode.notFound);
    }
    final displayName = galleryFileName(path);
    File? temporary;
    try {
      var savePath = source.path;
      if (needsRemux(path)) {
        temporary = await _remuxToMp4(source);
        savePath = temporary.path;
      }
      final saved = await _invokeSave(savePath, displayName);
      if (saved != true) {
        throw VideoExportException.fromCode(VideoExportErrorCode.saveFailed);
      }
    } finally {
      final file = temporary;
      if (file != null) await _deleteQuietly(file);
    }
  }

  Future<Object?> _invokeSave(String path, String displayName) async {
    try {
      return await _invokeNative('saveVideoToGallery', <String, Object?>{
        'path': path,
        'displayName': displayName,
        'album': albumName,
      });
    } on PlatformException catch (error) {
      throw VideoExportException.fromCode(
        error.code == 'PERMISSION_DENIED'
            ? VideoExportErrorCode.permissionDenied
            : VideoExportErrorCode.saveFailed,
        cause: error,
      );
    } on MissingPluginException catch (error) {
      throw VideoExportException.fromCode(
        VideoExportErrorCode.unsupported,
        cause: error,
      );
    }
  }

  Future<Directory> _exportDirectory() async {
    try {
      final root = await _temporaryDirectory();
      final directory = Directory(
        '${root.path}${Platform.pathSeparator}$_tempFolderName',
      );
      await directory.create(recursive: true);
      return directory;
    } catch (error) {
      throw VideoExportException.fromCode(
        VideoExportErrorCode.convertFailed,
        cause: error,
      );
    }
  }

  Future<File> _remuxToMp4(File source) async {
    final directory = await _exportDirectory();
    await _deleteStaleTemporaryFiles(directory);
    var suffix = DateTime.now().microsecondsSinceEpoch;
    var target = File(
      '${directory.path}${Platform.pathSeparator}export_$suffix.mp4',
    );
    while (await target.exists()) {
      suffix++;
      target = File(
        '${directory.path}${Platform.pathSeparator}export_$suffix.mp4',
      );
    }
    final attempts = <List<String>>[
      // 1) Chỉ đổi vỏ: nhanh, không mã hoá lại.
      <String>[
        '-y',
        '-fflags',
        '+genpts',
        '-i',
        source.path,
        '-map',
        '0',
        '-c',
        'copy',
        '-bsf:a',
        'aac_adtstoasc',
        '-movflags',
        '+faststart',
        '-f',
        'mp4',
        target.path,
      ],
      // 2) Luồng phụ/âm thanh không chép được sang MP4: giữ video, mã hoá lại
      //    âm thanh sang AAC.
      <String>[
        '-y',
        '-fflags',
        '+genpts',
        '-i',
        source.path,
        '-map',
        '0:v:0',
        '-map',
        '0:a:0?',
        '-c:v',
        'copy',
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
    ];
    Object? lastError;
    for (final arguments in attempts) {
      try {
        if (await _remux(arguments) &&
            await target.exists() &&
            await target.length() > 0) {
          return target;
        }
      } catch (error) {
        lastError = error;
      }
      await _deleteQuietly(target);
    }
    throw VideoExportException.fromCode(
      VideoExportErrorCode.convertFailed,
      cause: lastError,
    );
  }

  /// Dọn file tạm sót lại (app bị tắt giữa lúc lưu) cũ hơn 24 giờ.
  Future<void> _deleteStaleTemporaryFiles(Directory directory) async {
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    try {
      await for (final entity in directory.list()) {
        if (entity is! File) continue;
        try {
          if ((await entity.stat()).modified.isBefore(cutoff)) {
            await entity.delete();
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (error) {
      developer.log(
        '[EXPORT] Không xoá được file tạm ${file.path}',
        error: error,
        name: 'VideoExportService',
      );
    }
  }

  /// Mở trang Cài đặt của app (C1) để người dùng cấp quyền Thư viện ảnh.
  Future<bool> openAppSettings() async {
    try {
      final opened = await _invokeNative(
        'openAppSettings',
        const <String, Object?>{},
      );
      return opened == true;
    } catch (error) {
      developer.log(
        '[EXPORT] Không mở được Cài đặt',
        error: error,
        name: 'VideoExportService',
      );
      return false;
    }
  }

  static Future<Object?> _defaultInvokeNative(
    String method,
    Map<String, Object?> arguments,
  ) {
    return StationPlatformEvents.channel.invokeMethod<Object?>(
      method,
      arguments.isEmpty ? null : arguments,
    );
  }

  static Future<bool> _defaultRemux(List<String> arguments) async {
    final session = await FFmpegKit.executeWithArguments(arguments);
    final code = await session.getReturnCode();
    if (ReturnCode.isSuccess(code)) return true;
    developer.log(
      '[EXPORT] FFmpeg remux failed: $code',
      name: 'VideoExportService',
    );
    return false;
  }
}
