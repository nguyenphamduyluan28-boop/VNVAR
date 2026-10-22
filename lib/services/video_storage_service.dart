import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Đường dẫn lưu đã chọn không mở được lúc khởi động: chỉ bỏ hẳn lựa chọn khi
/// đường dẫn đó giờ là một file (không thể là thư mục nữa). Không tồn tại
/// (thẻ nhớ chưa mount) hoặc là thư mục nhưng chưa ghi được (quyền chưa sẵn
/// sàng) thì giữ lựa chọn để thử lại.
bool shouldForgetSavedStoragePath(FileSystemEntityType type) =>
    type == FileSystemEntityType.file;

/// Nhịp thử lại thư mục lưu đã chọn khi nó chưa sẵn sàng.
const Duration pendingStorageRetryInterval = Duration(seconds: 30);

/// Platform-independent access to VNVAR's permanent video storage.
///
/// Android-only capabilities (folder picker and native free-space query) are
/// guarded here so callers never invoke an unavailable MethodChannel on iOS.
class VideoStorageService {
  static const _storagePathKey = 'camera_video_storage_path';
  static const _fallbackPathKey = 'camera_video_fallback_path';
  static const MethodChannel _androidChannel = MethodChannel(
    'vnvar/camera_station_service',
  );

  String? _selectedPath;
  // Thư mục đã chọn (vẫn lưu trong cài đặt) nhưng chưa dùng được; trong lúc
  // chờ, video ghi vào thư mục mặc định.
  String? _pendingSelectedPath;
  DateTime? _nextPendingRetryAt;
  String? _androidPublicPath;
  bool _supportsFolderPicker = Platform.isAndroid;
  // Thư mục dự phòng (Documents/VNVAR) đã từng được dùng khi thư mục chính
  // tạm lỗi. Được nhớ lại để video ghi vào đó vẫn được index, dọn và giới hạn
  // dung lượng sau khi thư mục chính hoạt động lại.
  String? _fallbackPath;
  bool _fallbackActive = false;
  final Set<String> _noMediaEnsuredPaths = <String>{};

  /// Thư mục công khai cũ `Movies/VNVAR` (trước khi chuyển sang thư mục riêng
  /// của ứng dụng). Chỉ khớp chính xác thư mục này, không khớp các thư mục
  /// người dùng tự chọn có tên bắt đầu bằng `VNVAR` như `VNVAR_backup`.
  static bool isLegacyPublicStoragePath(String path) {
    final normalized = path
        .replaceAll(r'\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    return RegExp(r'/Movies/VNVAR$').hasMatch(normalized);
  }

  String? get selectedPath => _selectedPath;

  /// Thư mục lưu do người dùng tự chọn (có thể là thư mục dùng chung).
  bool get usesCustomRoot => _selectedPath != null;
  bool get supportsFolderPicker => _supportsFolderPicker;

  /// Lần lấy thư mục gần nhất phải dùng thư mục dự phòng vì thư mục chính lỗi.
  bool get fallbackActive => _fallbackActive;

  Future<void> load() async {
    if (Platform.isAndroid) {
      try {
        _supportsFolderPicker =
            await _androidChannel.invokeMethod<bool>(
              'supportsVideoFolderSelection',
            ) ??
            false;
      } on MissingPluginException {
        _supportsFolderPicker = false;
      }
    } else {
      _supportsFolderPicker = false;
    }
    if (Platform.isAndroid) {
      try {
        final path = await _androidChannel.invokeMethod<String>(
          'ensurePublicVideoStorage',
        );
        if (path != null && path.trim().isNotEmpty) {
          final dir = Directory(path);
          await _verifyWritableDirectory(dir);
          _androidPublicPath = dir.absolute.path;
          developer.log(
            '[STORAGE] Android video storage path resolved to: $_androidPublicPath',
            name: 'VideoStorageService',
          );
        }
      } catch (error, stackTrace) {
        developer.log(
          '[STORAGE] Android video storage path was not writable or listable; '
          'using application Documents.',
          error: error,
          stackTrace: stackTrace,
          name: 'VideoStorageService',
        );
        _androidPublicPath = null;
      }
    }
    final prefs = await SharedPreferences.getInstance();
    final savedFallback = prefs.getString(_fallbackPathKey)?.trim();
    _fallbackPath = savedFallback == null || savedFallback.isEmpty
        ? null
        : savedFallback;
    final savedPath = prefs.getString(_storagePathKey)?.trim();
    if (savedPath == null ||
        savedPath.isEmpty ||
        isLegacyPublicStoragePath(savedPath)) {
      _selectedPath = null;
      _pendingSelectedPath = null;
      _nextPendingRetryAt = null;
      if (savedPath != null) await prefs.remove(_storagePathKey);
      return;
    }
    final path = Directory(savedPath).absolute.path;

    _pendingSelectedPath = null;
    _nextPendingRetryAt = null;
    try {
      await _verifyWritableDirectory(Directory(path));
      _selectedPath = path;
      if (path != savedPath) await prefs.setString(_storagePathKey, path);
    } catch (error, stackTrace) {
      _selectedPath = null;
      final entityType = await _entityType(path);
      if (shouldForgetSavedStoragePath(entityType)) {
        // Đường dẫn giờ là một file (không bao giờ là thư mục được nữa).
        await prefs.remove(_storagePathKey);
        developer.log(
          '[STORAGE] Saved custom directory is no longer a directory; '
          'falling back to application Documents.',
          error: error,
          stackTrace: stackTrace,
          name: 'VideoStorageService',
        );
      } else {
        // Thẻ nhớ/thư mục chưa sẵn sàng lúc khởi động (chưa mount, quyền
        // chưa cấp lại...): giữ lựa chọn trong cài đặt, tạm ghi vào thư mục
        // mặc định và thử lại sau.
        _pendingSelectedPath = path;
        _nextPendingRetryAt = DateTime.now().add(pendingStorageRetryInterval);
        developer.log(
          '[STORAGE] Saved custom directory is not ready; keeping the choice '
          'and using the default directory until it becomes available.',
          error: error,
          stackTrace: stackTrace,
          name: 'VideoStorageService',
        );
      }
    }
  }

  static Future<FileSystemEntityType> _entityType(String path) async {
    try {
      return await FileSystemEntity.type(path);
    } catch (_) {
      return FileSystemEntityType.notFound;
    }
  }

  /// Thư mục người dùng chọn nhưng chưa dùng được lúc khởi động (null nếu
  /// không có). Lựa chọn vẫn được giữ trong cài đặt.
  String? get pendingSelectedPath => _pendingSelectedPath;

  /// Chỉ dùng trong test: bỏ nhịp chờ để lần lấy thư mục kế tiếp thử lại
  /// ngay thư mục đã chọn đang chờ.
  @visibleForTesting
  void debugAllowPendingRetryNow() => _nextPendingRetryAt = null;

  /// Thử lại thư mục đã chọn đang chờ (nhịp tối đa [pendingStorageRetryInterval]).
  /// Dùng được thì chuyển sang ghi vào đó.
  Future<void> _retryPendingSelectedPath() async {
    final pending = _pendingSelectedPath;
    if (pending == null || _selectedPath != null) return;
    final now = DateTime.now();
    final nextRetry = _nextPendingRetryAt;
    if (nextRetry != null && now.isBefore(nextRetry)) return;
    _nextPendingRetryAt = now.add(pendingStorageRetryInterval);
    try {
      await _verifyWritableDirectory(Directory(pending));
    } catch (_) {
      return;
    }
    // Người dùng có thể đã chọn thư mục khác trong lúc chờ.
    if (_pendingSelectedPath != pending || _selectedPath != null) {
      return;
    }
    _selectedPath = pending;
    _pendingSelectedPath = null;
    _nextPendingRetryAt = null;
    developer.log(
      '[STORAGE] Saved custom directory is available again: $pending',
      name: 'VideoStorageService',
    );
  }

  Future<Directory> rootDirectory() async {
    await _retryPendingSelectedPath();
    if (_selectedPath == null && _pendingSelectedPath != null) {
      // Thư mục đã chọn chưa sẵn sàng: ghi tạm vào thư mục dự phòng (được
      // nhớ lại để video ghi trong lúc này vẫn được index/dọn sau khi thư
      // mục đã chọn dùng lại được).
      return _useFallbackRoot();
    }
    final selectedPath = _selectedPath;
    final String rootPath;
    if (selectedPath != null) {
      rootPath = selectedPath;
    } else if (Platform.isAndroid && _androidPublicPath != null) {
      rootPath = _androidPublicPath!;
    } else {
      final defaultRoot = await getApplicationDocumentsDirectory();
      rootPath = '${defaultRoot.path}${Platform.pathSeparator}VNVAR';
    }
    final directory = Directory(rootPath);
    try {
      if (!await directory.exists()) await directory.create(recursive: true);
      // Thư mục gốc riêng của app: đặt .nomedia để thư viện ảnh Android
      // (Gallery) không hiển thị hàng loạt clip camera. Thư mục người dùng tự
      // chọn (có thể là DCIM) thì KHÔNG đặt ở gốc vì sẽ ẩn cả ảnh của họ; khi
      // đó RecordingService ẩn riêng từng thư mục ngày (hideFromGallery).
      if (selectedPath == null) {
        await hideFromGallery(directory);
      }
      await directory.list().take(1).drain();
      _fallbackActive = false;
      return directory;
    } catch (error, stackTrace) {
      developer.log(
        '[STORAGE] Directory $rootPath is not listable/writable; falling back to app documents.',
        error: error,
        stackTrace: stackTrace,
        name: 'VideoStorageService',
      );
      return _useFallbackRoot();
    }
  }

  Future<Directory> _useFallbackRoot() async {
    final defaultRoot = await getApplicationDocumentsDirectory();
    final fallbackDir =
        Directory('${defaultRoot.path}${Platform.pathSeparator}VNVAR');
    if (!await fallbackDir.exists()) await fallbackDir.create(recursive: true);
    _fallbackActive = true;
    await _rememberFallback(fallbackDir.absolute.path);
    return fallbackDir;
  }

  Future<void> _rememberFallback(String path) async {
    if (_fallbackPath == path) return;
    _fallbackPath = path;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_fallbackPathKey, path);
    } catch (_) {}
  }

  static String _normalizeRoot(String path) => path
      .replaceAll('\\', '/')
      .replaceAll(RegExp(r'/+$'), '')
      .toLowerCase();

  /// Các thư mục gốc phụ còn chứa video của app (thư mục dự phòng đã dùng khi
  /// thư mục chính lỗi), khác với [primary]. Video trong đó vẫn phải được
  /// index, dọn theo ngày và tính vào giới hạn dung lượng.
  Future<List<Directory>> secondaryRoots(Directory primary) async {
    final path = _fallbackPath;
    if (path == null) return const [];
    if (_normalizeRoot(Directory(path).absolute.path) ==
        _normalizeRoot(primary.absolute.path)) {
      return const [];
    }
    final directory = Directory(path);
    try {
      if (await directory.exists()) return [directory];
    } catch (_) {}
    // Thư mục dự phòng không còn: quên nó đi.
    _fallbackPath = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_fallbackPathKey);
    } catch (_) {}
    return const [];
  }

  Future<void> setStoragePath(String? path) async {
    final trimmed = path?.trim();
    final normalized = trimmed == null || trimmed.isEmpty
        ? null
        : Directory(trimmed).absolute.path;
    if (normalized != null) {
      final directory = Directory(normalized);
      await _verifyWritableDirectory(directory);
    }

    final prefs = await SharedPreferences.getInstance();
    // Lựa chọn mới thay cho thư mục đang chờ (nếu có).
    _pendingSelectedPath = null;
    _nextPendingRetryAt = null;
    if (normalized == null) {
      await prefs.remove(_storagePathKey);
      _selectedPath = null;
    } else {
      await prefs.setString(_storagePathKey, normalized);
      _selectedPath = normalized;
    }
  }

  Future<void> _verifyWritableDirectory(Directory directory) async {
    await directory.create(recursive: true);
    final uniqueSuffix =
        '${DateTime.now().microsecondsSinceEpoch}_${identityHashCode(this)}';
    final probe = File(
      '${directory.path}${Platform.pathSeparator}vnvar_write_$uniqueSuffix.mp4',
    );
    try {
      await probe.writeAsString('VNVAR', flush: true);
      // Verify that directory listing is also allowed by OS (Scoped Storage check)
      await directory.list().take(1).drain();
    } finally {
      try {
        if (await probe.exists()) await probe.delete();
      } catch (_) {}
    }
  }

  Future<String?> selectFolder() async {
    if (!supportsFolderPicker) return null;
    try {
      return await _androidChannel.invokeMethod<String>('selectVideoFolder');
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error, stackTrace) {
      developer.log(
        '[STORAGE] Android folder picker failed.',
        error: error,
        stackTrace: stackTrace,
        name: 'VideoStorageService',
      );
      return null;
    }
  }

  Future<void> scanMediaFile(String path) async {
    if (!Platform.isAndroid) return;
    try {
      await _androidChannel.invokeMethod('scanMediaFile', {'path': path});
    } catch (error) {
      developer.log(
        '[STORAGE] scanMediaFile failed: $error',
        name: 'VideoStorageService',
      );
    }
  }

  /// Đặt .nomedia trong [directory] (một lần mỗi đường dẫn) để Gallery bỏ qua.
  Future<void> hideFromGallery(Directory directory) async {
    final nomediaFile = File('${directory.path}${Platform.pathSeparator}.nomedia');
    try {
      if (!await nomediaFile.exists()) await nomediaFile.create(recursive: true);
    } catch (_) {}
    if (Platform.isAndroid && _noMediaEnsuredPaths.add(directory.path)) {
      unawaited(ensureNoMedia(directory.path));
    }
  }

  Future<void> ensureNoMedia(String directoryPath) async {
    if (!Platform.isAndroid) return;
    try {
      await _androidChannel.invokeMethod('ensureNoMedia', {'path': directoryPath});
    } catch (error) {
      developer.log(
        '[STORAGE] ensureNoMedia failed: $error',
        name: 'VideoStorageService',
      );
    }
  }

  Future<bool> deleteDirectoryRecursively(String directoryPath) async {
    if (!Platform.isAndroid) return false;
    try {
      final success = await _androidChannel.invokeMethod<bool>(
        'deleteDirectoryRecursively',
        {'path': directoryPath},
      );
      return success ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<int?> availableBytes() async {
    if (!Platform.isAndroid && !Platform.isIOS) return null;
    try {
      final root = await rootDirectory();
      return await availableBytesAt(root.path);
    } catch (error, stackTrace) {
      developer.log(
        '[STORAGE] Unable to resolve the video root for free-space query.',
        error: error,
        stackTrace: stackTrace,
        name: 'VideoStorageService',
      );
      return null;
    }
  }

  /// Dung lượng trống của ổ chứa [path] (ví dụ thư mục file tạm khi ghi).
  Future<int?> availableBytesAt(String path) async {
    if (!Platform.isAndroid && !Platform.isIOS) return null;
    try {
      return await _androidChannel.invokeMethod<int>(
        'getAvailableStorageBytes',
        {'path': path},
      );
    } on MissingPluginException {
      return null;
    } catch (error, stackTrace) {
      developer.log(
        '[STORAGE] Unable to read available storage on ${Platform.operatingSystem}.',
        error: error,
        stackTrace: stackTrace,
        name: 'VideoStorageService',
      );
      return null;
    }
  }
}
