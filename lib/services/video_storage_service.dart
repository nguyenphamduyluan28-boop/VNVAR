import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Platform-independent access to VNVAR's permanent video storage.
///
/// Android-only capabilities (folder picker and native free-space query) are
/// guarded here so callers never invoke an unavailable MethodChannel on iOS.
class VideoStorageService {
  static const _storagePathKey = 'camera_video_storage_path';
  static const MethodChannel _androidChannel = MethodChannel(
    'vnvar/camera_station_service',
  );

  String? _selectedPath;

  String? get selectedPath => _selectedPath;
  bool get supportsFolderPicker => Platform.isAndroid;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPath = prefs.getString(_storagePathKey)?.trim();
    if (savedPath == null || savedPath.isEmpty) {
      _selectedPath = null;
      return;
    }
    final path = Directory(savedPath).absolute.path;

    try {
      await _verifyWritableDirectory(Directory(path));
      _selectedPath = path;
      if (path != savedPath) await prefs.setString(_storagePathKey, path);
    } catch (error, stackTrace) {
      _selectedPath = null;
      await prefs.remove(_storagePathKey);
      developer.log(
        '[STORAGE] Saved custom directory is no longer writable; '
        'falling back to application Documents.',
        error: error,
        stackTrace: stackTrace,
        name: 'VideoStorageService',
      );
    }
  }

  Future<Directory> rootDirectory() async {
    final selectedPath = _selectedPath;
    final String rootPath;
    if (selectedPath != null) {
      rootPath = selectedPath;
    } else {
      final defaultRoot = await getApplicationDocumentsDirectory();
      rootPath = '${defaultRoot.path}${Platform.pathSeparator}VNVAR';
    }
    final directory = Directory(rootPath);
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
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
      '${directory.path}${Platform.pathSeparator}.vnvar_write_$uniqueSuffix',
    );
    try {
      await probe.writeAsString('VNVAR', flush: true);
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

  Future<int?> availableBytes() async {
    if (!Platform.isAndroid) return null;
    try {
      final root = await rootDirectory();
      return await _androidChannel.invokeMethod<int>(
        'getAvailableStorageBytes',
        {'path': root.path},
      );
    } on MissingPluginException {
      return null;
    } catch (error, stackTrace) {
      developer.log(
        '[STORAGE] Unable to read available storage.',
        error: error,
        stackTrace: stackTrace,
        name: 'VideoStorageService',
      );
      return null;
    }
  }
}
