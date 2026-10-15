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
    // iOS reports the actual per-camera ceiling and the runtime steps down
    // adaptively when a device cannot sustain this rate under recording load.
    fps: 30,
    bitrate: 10000000,
  );

  /// Các cấu hình được phép chọn. 2K và 4K đã bỏ: cùng bitrate ghi hình nên
  /// không nét hơn 1080p với cảnh chuyển động nhanh, nhưng làm máy nóng hơn
  /// nhiều. Enum vẫn giữ để đọc cấu hình cũ và các nhánh iOS.
  static const values = [hd720, fullHd1080];

  /// Id đã từng lưu nhưng không còn hỗ trợ; tự chuyển về 1080p.
  static const retiredIds = {'qhd2k', 'ultraHd4k'};

  static bool isSelectableId(String? id) =>
      values.any((profile) => profile.id == id);

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

  String get compactLabel => '$shortLabel${fps > 30 ? ' $fps' : ''}';
  String get labelWithFps => '$shortLabel $fps FPS';

  /// RTSP/TCP has no WebRTC-style congestion controller. Keep enough bitrate
  /// for sports motion while leaving headroom for Wi-Fi retransmissions and
  /// protocol overhead so latency does not grow without bound on a weak LAN.
  int get rtspBitrate => switch (preset) {
    CameraResolutionPreset.hd720 => 3000000,
    CameraResolutionPreset.fullHd1080 => 5000000,
    CameraResolutionPreset.qhd2k => 7000000,
    CameraResolutionPreset.ultraHd4k => 8000000,
  };

  /// Bitrate chuẩn (30 FPS) của preset. withFps luôn tính từ mức này để gọi
  /// nhiều lần (60 → 30 → 60) không bị nhân dồn hoặc giữ nhầm mức 60 FPS.
  int get baseBitrate => switch (preset) {
    CameraResolutionPreset.hd720 => hd720.bitrate,
    CameraResolutionPreset.fullHd1080 => fullHd1080.bitrate,
    CameraResolutionPreset.qhd2k => qhd2k.bitrate,
    CameraResolutionPreset.ultraHd4k => ultraHd4k.bitrate,
  };

  CameraResolutionProfile withFps(int supportedFps) {
    final clampedFps = supportedFps.clamp(1, 60);
    final base = baseBitrate;
    final adjustedBitrate = clampedFps >= 50
        ? (base * 1.25).toInt()
        : (clampedFps <= 15 ? (base * 0.6).toInt() : base);
    return CameraResolutionProfile(
      preset: preset,
      width: width,
      height: height,
      fps: clampedFps,
      bitrate: adjustedBitrate,
    );
  }

  static CameraResolutionProfile? fromId(String? id) {
    // Máy từng lưu 2K/4K: tự chuyển về 1080p an toàn.
    if (retiredIds.contains(id)) {
      return fullHd1080;
    }
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

String profileLabel(CameraResolutionProfile p) => p.compactLabel;
