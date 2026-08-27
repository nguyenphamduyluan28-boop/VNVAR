import 'dart:developer' as developer;
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/station_identity.dart';
import '../models/camera_resolution_profile.dart';

class StationConfigService {
  static const String _courtKey = 'courtId';
  static const String _cameraKey = 'cameraId';
  static const String _deviceKey = 'deviceId';
  static const String _cameraNameKey = 'cameraName';
  static const String _cameraPositionKey = 'cameraPosition';
  static const String _courtCountKey = 'courtCount';
  static const String _resolutionProfileKey = 'camera_resolution_profile';

  // ConfigService cũ đã lưu Camera ID bằng key này.
  static const String _legacyCameraKey = 'camera_id';

  Future<void> saveIdentity(StationIdentity identity) async {
    final normalized = _normalizeAndValidate(identity);
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(_courtKey, normalized.courtId);
    await prefs.setString(_cameraKey, normalized.cameraId);
    await prefs.setString(_deviceKey, normalized.deviceId);
    await prefs.setString(_cameraNameKey, normalized.cameraName);
    await prefs.setString(_cameraPositionKey, normalized.cameraPosition);

    // Giữ key cũ đồng bộ trong giai đoạn main.dart chưa migrate hoàn toàn.
    await prefs.setString(_legacyCameraKey, normalized.cameraId);

    developer.log(
      '[CONFIG] Identity saved: ${normalized.namespace}',
      name: 'StationConfigService',
    );
  }

  Future<StationIdentity?> loadIdentity() async {
    final prefs = await SharedPreferences.getInstance();

    final currentCameraId = _readTrimmed(prefs, _cameraKey);
    final legacyCameraId = _readTrimmed(prefs, _legacyCameraKey);
    final cameraId = currentCameraId ?? legacyCameraId;

    // Không có cả key mới lẫn key legacy nghĩa là cài đặt mới.
    if (cameraId == null) return null;

    final courtId = _readTrimmed(prefs, _courtKey) ?? 'COURT-01';
    final existingDeviceId = _readTrimmed(prefs, _deviceKey);
    final deviceId = existingDeviceId ?? _generateDeviceId();
    final cameraName = _readTrimmed(prefs, _cameraNameKey) ?? cameraId;
    final cameraPosition =
        _readTrimmed(prefs, _cameraPositionKey) ?? 'Chưa cấu hình';

    final identity = StationIdentity(
      courtId: courtId,
      cameraId: cameraId,
      deviceId: deviceId,
      cameraName: cameraName,
      cameraPosition: cameraPosition,
    );

    final needsMigration =
        currentCameraId == null ||
        existingDeviceId == null ||
        _readTrimmed(prefs, _courtKey) == null ||
        _readTrimmed(prefs, _cameraNameKey) == null ||
        _readTrimmed(prefs, _cameraPositionKey) == null;

    if (needsMigration) await saveIdentity(identity);

    developer.log(
      '[CONFIG] Identity loaded: ${identity.namespace}',
      name: 'StationConfigService',
    );
    return identity;
  }

  Future<bool> hasIdentity() async => await loadIdentity() != null;

  Future<void> saveCourtCount(int count) async {
    if (count <= 0 || count > 99) {
      throw ArgumentError('Số lượng sân phải từ 1 đến 99.');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_courtCountKey, count);
  }

  Future<int?> loadCourtCount() async {
    final prefs = await SharedPreferences.getInstance();
    final count = prefs.getInt(_courtCountKey);
    return count != null && count > 0 ? count : null;
  }

  Future<void> saveResolutionProfile(CameraResolutionProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_resolutionProfileKey, profile.id);
  }

  Future<CameraResolutionProfile?> loadResolutionProfile() async {
    final prefs = await SharedPreferences.getInstance();
    return CameraResolutionProfile.fromId(
      prefs.getString(_resolutionProfileKey),
    );
  }

  Future<void> clearIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_courtKey);
    await prefs.remove(_cameraKey);
    await prefs.remove(_deviceKey);
    await prefs.remove(_cameraNameKey);
    await prefs.remove(_cameraPositionKey);
    await prefs.remove(_legacyCameraKey);

    developer.log('[CONFIG] Identity cleared', name: 'StationConfigService');
  }

  StationIdentity _normalizeAndValidate(StationIdentity identity) {
    final normalized = StationIdentity(
      courtId: identity.courtId.trim(),
      cameraId: identity.cameraId.trim(),
      deviceId: identity.deviceId.trim(),
      cameraName: identity.cameraName.trim(),
      cameraPosition: identity.cameraPosition.trim(),
    );

    if (normalized.courtId.isEmpty ||
        normalized.cameraId.isEmpty ||
        normalized.deviceId.isEmpty ||
        normalized.cameraName.isEmpty ||
        normalized.cameraPosition.isEmpty) {
      throw ArgumentError('Station identity fields must not be empty.');
    }

    return normalized;
  }

  String? _readTrimmed(SharedPreferences prefs, String key) {
    final value = prefs.getString(key)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  String _generateDeviceId() {
    final random = Random.secure();
    final suffix = List.generate(
      6,
      (_) => random.nextInt(16).toRadixString(16),
    ).join().toUpperCase();
    return 'PHONE-$suffix';
  }
}
