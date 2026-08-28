enum CameraResolutionPreset { hd720, fullHd1080, qhd2k, ultraHd4k }

class CameraResolutionProfile {
  final CameraResolutionPreset preset;
  final int width;
  final int height;
  final int fps;
  final int bitrate;

  const CameraResolutionProfile({
    required this.preset,
    required this.width,
    required this.height,
    required this.fps,
    required this.bitrate,
  });

  static const hd720 = CameraResolutionProfile(
    preset: CameraResolutionPreset.hd720,
    width: 1280,
    height: 720,
    fps: 30,
    bitrate: 4000000,
  );
  static const fullHd1080 = CameraResolutionProfile(
    preset: CameraResolutionPreset.fullHd1080,
    width: 1920,
    height: 1080,
    fps: 30,
    bitrate: 8000000,
  );
  static const qhd2k = CameraResolutionProfile(
    preset: CameraResolutionPreset.qhd2k,
    width: 2560,
    height: 1440,
    fps: 30,
    bitrate: 8000000,
  );
  static const ultraHd4k = CameraResolutionProfile(
    preset: CameraResolutionPreset.ultraHd4k,
    width: 3840,
    height: 2160,
    fps: 30,
    bitrate: 12000000,
  );

  static const values = [hd720, fullHd1080, qhd2k, ultraHd4k];

  String get id => preset.name;
  String get shortLabel => switch (preset) {
    CameraResolutionPreset.hd720 => '720p',
    CameraResolutionPreset.fullHd1080 => '1080p',
    CameraResolutionPreset.qhd2k => '2K',
    CameraResolutionPreset.ultraHd4k => '4K',
  };
  String get title => switch (preset) {
    CameraResolutionPreset.hd720 => '720p HD',
    CameraResolutionPreset.fullHd1080 => '1080p Full HD',
    CameraResolutionPreset.qhd2k => '2K QHD',
    CameraResolutionPreset.ultraHd4k => '4K Ultra HD',
  };
  CameraResolutionProfile withFps(int supportedFps) {
    return CameraResolutionProfile(
      preset: preset,
      width: width,
      height: height,
      fps: supportedFps.clamp(1, fps),
      bitrate: bitrate,
    );
  }

  static CameraResolutionProfile? fromId(String? id) {
    for (final profile in values) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is CameraResolutionProfile &&
      other.preset == preset &&
      other.fps == fps;

  @override
  int get hashCode => Object.hash(preset, fps);
}
