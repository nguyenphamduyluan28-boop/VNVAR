import 'package:shared_preferences/shared_preferences.dart';

class ConfigService {
  static const _keyCameraId = 'camera_id';

  Future<String?> getCameraId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyCameraId);
  }

  Future<void> setCameraId(String cameraId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCameraId, cameraId);
  }
}
