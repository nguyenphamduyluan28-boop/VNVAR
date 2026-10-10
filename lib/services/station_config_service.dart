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
  static const String _resolutionFpsKey = 'camera_resolution_fps';
  static const String _resolutionLockedKey = 'camera_resolution_locked';
  static const String _apiPortKey = 'camera_api_port';
  static const String _cameraQuarterTurnsKey = 'camera_quarter_turns';
  static const String _cameraLensUltraWideKey = 'camera_lens_ultra_wide';
  static const String _cameraLensZoomKey = 'camera_lens_zoom';
  static const String _cameraLensDeviceIdKey = 'camera_lens_device_id';

  static const String _screenOrientationKey = 'station_screen_orientation';
  static const String _whipEndpointKey = 'whip_endpoint_url';
  static const String _whipAuthTokenKey = 'whip_auth_token';
  static const String _rtspPushUrlKey = 'rtsp_push_url';
  static const String _streamProtocolKey = 'live_stream_protocol';

  // ConfigService cũ đã lưu Camera ID bằng key này.
  static const String _legacyCameraKey = 'camera_id';

  Future<void> saveRtspPushConfig({required String targetUrl}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_rtspPushUrlKey, targetUrl.trim());
  }

  Future<String?> loadRtspPushUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return _readTrimmed(prefs, _rtspPushUrlKey);
  }

  Future<void> saveStreamProtocol(String protocol) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_streamProtocolKey, protocol.trim().toLowerCase());
  }

  Future<String> loadStreamProtocol() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_streamProtocolKey) ?? 'rtsp';
  }

  Future<void> saveWhipConfig({
    required String endpointUrl,
    String? token,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_whipEndpointKey, endpointUrl.trim());
    if (token != null && token.trim().isNotEmpty) {
      await prefs.setString(_whipAuthTokenKey, token.trim());
    } else {
      await prefs.remove(_whipAuthTokenKey);
    }
  }

  Future<String?> loadWhipEndpointUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return _readTrimmed(prefs, _whipEndpointKey);
  }

  Future<String?> loadWhipAuthToken() async {
    final prefs = await SharedPreferences.getInstance();
    return _readTrimmed(prefs, _whipAuthTokenKey);
  }

  Future<void> saveScreenOrientation(String orientation) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_screenOrientationKey, orientation);
  }

  Future<String> loadScreenOrientation() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_screenOrientationKey) ?? 'landscape';
  }

  Future<void> saveCameraQuarterTurns(int quarterTurns) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_cameraQuarterTurnsKey, (quarterTurns % 4 + 4) % 4);
  }

  Future<int> loadCameraQuarterTurns() async {
    final prefs = await SharedPreferences.getInstance();
    return ((prefs.getInt(_cameraQuarterTurnsKey) ?? 0) % 4 + 4) % 4;
  }

  /// Lưu trạng thái lens camera (ultra-wide, zoom level, device ID).
  /// Được gọi khi user chủ động chuyển lens hoặc zoom để có thể
  /// restore sau khi đổi resolution hoặc khởi động lại app.
  Future<void> saveCameraLensState({
    required bool isUltraWide,
    required double zoom,
    String? deviceId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_cameraLensUltraWideKey, isUltraWide);
    await prefs.setDouble(_cameraLensZoomKey, zoom.clamp(0.1, 10.0));
    if (deviceId != null && deviceId.isNotEmpty) {
      await prefs.setString(_cameraLensDeviceIdKey, deviceId);
    } else {
      await prefs.remove(_cameraLensDeviceIdKey);
    }
  }

  Future<({bool isUltraWide, double zoom, String? deviceId})>
  loadCameraLensState() async {
    final prefs = await SharedPreferences.getInstance();
    final isUltraWide = prefs.getBool(_cameraLensUltraWideKey) ?? false;
    final zoom = prefs.getDouble(_cameraLensZoomKey) ?? 1.0;
    final deviceId = _readTrimmed(prefs, _cameraLensDeviceIdKey);
    return (isUltraWide: isUltraWide, zoom: zoom.clamp(0.1, 10.0), deviceId: deviceId);
  }

  Future<void> clearCameraLensState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cameraLensUltraWideKey);
    await prefs.remove(_cameraLensZoomKey);
    await prefs.remove(_cameraLensDeviceIdKey);
  }

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
    await prefs.setInt(_resolutionFpsKey, profile.fps);
  }

  Future<CameraResolutionProfile?> loadResolutionProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final profile = CameraResolutionProfile.fromId(
      prefs.getString(_resolutionProfileKey),
    );
    if (profile == null) return null;
    final savedFps = prefs.getInt(_resolutionFpsKey);
    if (savedFps != null && savedFps > 0) {
      return profile.withFps(savedFps);
    }
    return profile;
  }

  static const _rtspTabletAudioKey = 'rtsp_tablet_audio_enabled';
  static const _exposureBiasKey = 'camera_exposure_bias_ev';

  /// Độ sáng người dùng chọn (EV, −2…+2; 0 = tự động).
  Future<void> saveExposureBias(double ev) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_exposureBiasKey, ev.clamp(-2.0, 2.0).toDouble());
  }

  Future<double> loadExposureBias() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getDouble(_exposureBiasKey) ?? 0).clamp(-2.0, 2.0).toDouble();
  }

  /// Tablet xem RTSP có nhận tiếng không (mặc định tắt: tiết kiệm ~0,77 Mbps
  /// sóng Wi-Fi mỗi Tablet; file ghi và livestream vẫn có tiếng).
  Future<void> saveRtspTabletAudio(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_rtspTabletAudioKey, enabled);
  }

  Future<bool> loadRtspTabletAudio() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_rtspTabletAudioKey) ?? false;
  }

  Future<void> saveResolutionLocked(bool locked) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_resolutionLockedKey, locked);
  }

  Future<bool> loadResolutionLocked() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_resolutionLockedKey) ?? false;
  }

  Future<int> loadApiPort() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(_apiPortKey);
    return value != null && value > 0 && value <= 65535 ? value : 8080;
  }

  Future<void> saveApiPort(int port) async {
    if (port <= 0 || port > 65535) {
      throw ArgumentError.value(
        port,
        'port',
        'Port must be between 1 and 65535',
      );
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_apiPortKey, port);
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
