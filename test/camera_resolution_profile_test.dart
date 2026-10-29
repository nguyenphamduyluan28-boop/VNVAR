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
    expect(CameraResolutionProfile.ultraHd4k.fps, 30);
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

  test('allows up to 60 FPS when hardware supports it', () {
    final profile = CameraResolutionProfile.fullHd1080.withFps(60);
    expect(profile.fps, 60);
    expect(profile.width, 1920);
    expect(profile.bitrate, 10000000);
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
    await config.saveResolutionProfile(CameraResolutionProfile.hd720);

    final restored = await config.loadResolutionProfile();

    expect(restored?.preset, CameraResolutionPreset.hd720);
    expect(restored?.fps, 30);
  });

  test('only 720p and 1080p are selectable; 2K and 4K are retired', () {
    expect(CameraResolutionProfile.values, [
      CameraResolutionProfile.hd720,
      CameraResolutionProfile.fullHd1080,
    ]);
    expect(CameraResolutionProfile.isSelectableId('hd720'), isTrue);
    expect(CameraResolutionProfile.isSelectableId('fullHd1080'), isTrue);
    expect(CameraResolutionProfile.isSelectableId('qhd2k'), isFalse);
    expect(CameraResolutionProfile.isSelectableId('ultraHd4k'), isFalse);
  });

  test('a saved 2K or 4K selection migrates to 1080p keeping its FPS', () async {
    final config = StationConfigService();
    await config.saveResolutionProfile(
      CameraResolutionProfile.qhd2k.withFps(60),
    );

    final restored = await config.loadResolutionProfile();

    expect(restored?.preset, CameraResolutionPreset.fullHd1080);
    expect(restored?.fps, 60);

    await config.saveResolutionProfile(CameraResolutionProfile.ultraHd4k);
    expect(
      (await config.loadResolutionProfile())?.preset,
      CameraResolutionPreset.fullHd1080,
    );
  });

  test('persists and restores the selected resolution with custom FPS', () async {
    final config = StationConfigService();
    final profile60 = CameraResolutionProfile.fullHd1080.withFps(60);
    await config.saveResolutionProfile(profile60);

    final restored = await config.loadResolutionProfile();

    expect(restored?.preset, CameraResolutionPreset.fullHd1080);
    expect(restored?.fps, 60);
  });

  test('persists and restores resolution locked state', () async {
    final config = StationConfigService();
    expect(await config.loadResolutionLocked(), isFalse);

    await config.saveResolutionLocked(true);
    expect(await config.loadResolutionLocked(), isTrue);

    await config.saveResolutionLocked(false);
    expect(await config.loadResolutionLocked(), isFalse);
  });

  test('sports mode raises RTSP bitrate to the recording bitrate', () {
    expect(CameraResolutionProfile.hd720.sportsRtspBitrate, 4000000);
    expect(CameraResolutionProfile.fullHd1080.sportsRtspBitrate, 8000000);
    // 60 FPS không nhân bitrate RTSP thể thao (dùng mức chuẩn 30 FPS).
    expect(
      CameraResolutionProfile.fullHd1080.withFps(60).sportsRtspBitrate,
      8000000,
    );
    expect(
      CameraResolutionProfile.fullHd1080.rtspBitrateFor(sportsMode: false),
      5000000,
    );
    expect(
      CameraResolutionProfile.fullHd1080.rtspBitrateFor(sportsMode: true),
      8000000,
    );
  });

  test('sports shutter defaults off, persists and migrates', () async {
    final config = StationConfigService();
    expect(await config.loadSportsShutter(), 0);
    await config.saveSportsShutter(250);
    expect(await config.loadSportsShutter(), 250);
    await config.saveSportsShutter(500);
    expect(await config.loadSportsShutter(), 500);
    await config.saveSportsShutter(0);
    expect(await config.loadSportsShutter(), 0);

    // Bản trước lưu bật/tắt: bật = 1/500 s.
    SharedPreferences.setMockInitialValues({'camera_sports_mode': true});
    expect(await StationConfigService().loadSportsShutter(), 500);
  });

  test('sports shutter values snap to supported levels', () {
    expect(StationConfigService.normalizeSportsShutter(-1), 0);
    expect(StationConfigService.normalizeSportsShutter(0), 0);
    expect(StationConfigService.normalizeSportsShutter(200), 250);
    expect(StationConfigService.normalizeSportsShutter(250), 250);
    expect(StationConfigService.normalizeSportsShutter(1000), 500);
    expect(StationConfigService.sportsShutterOptions, [0, 250, 500]);
  });
}
