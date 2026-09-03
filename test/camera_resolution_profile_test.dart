import 'package:camera_station/models/camera_resolution_profile.dart';
import 'package:camera_station/services/station_config_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defines the expected VAR resolution presets', () {
    expect(CameraResolutionProfile.hd720.shortLabel, '720p');
    expect(CameraResolutionProfile.hd720.fps, 30);
    expect(CameraResolutionProfile.fullHd1080.fps, 30);
    expect(CameraResolutionProfile.fullHd1080.bitrate, 8000000);
    expect(CameraResolutionProfile.hd720.rtspBitrate, 3000000);
    expect(CameraResolutionProfile.fullHd1080.rtspBitrate, 5000000);
    expect(CameraResolutionProfile.qhd2k.rtspBitrate, 7000000);
    expect(CameraResolutionProfile.ultraHd4k.fps, 20);
    expect(CameraResolutionProfile.ultraHd4k.bitrate, 10000000);
    expect(CameraResolutionProfile.ultraHd4k.rtspBitrate, 8000000);
    expect(CameraResolutionProfile.qhd2k.width, 2560);
    expect(CameraResolutionProfile.ultraHd4k.height, 2160);
  });

  test('limits requested FPS to hardware capability', () {
    final profile = CameraResolutionProfile.fullHd1080.withFps(30);
    expect(profile.fps, 30);
    expect(profile.width, 1920);
    expect(profile.bitrate, 8000000);
    expect(profile.rtspBitrate, 5000000);
  });

  test(
    'treats profiles with the same preset but different FPS as different',
    () {
      expect(
        CameraResolutionProfile.hd720.withFps(15),
        isNot(CameraResolutionProfile.hd720),
      );
    },
  );

  test('persists and restores the selected resolution preset', () async {
    final config = StationConfigService();
    await config.saveResolutionProfile(CameraResolutionProfile.qhd2k);

    final restored = await config.loadResolutionProfile();

    expect(restored?.preset, CameraResolutionPreset.qhd2k);
  });
}
