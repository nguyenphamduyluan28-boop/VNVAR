import 'package:camera_station/services/rtsp_publisher_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stream keys are masked and debug lines skipped', () {
    final sampler = FfmpegLogcatSampler(
      secrets: {'rtmp://media.aqvision.net:11935/live/SECRETKEY'},
    );
    final now = DateTime(2026);
    expect(
      sampler.lineFor(
        "Output #0, flv, to 'rtmp://media.aqvision.net:11935/live/SECRETKEY':",
        32,
        now,
      ),
      "Output #0, flv, to '<stream-url>':",
    );
    expect(sampler.lineFor('[h264 @ 0x1] nal_unit_type: 5', 48, now), isNull);
    expect(sampler.lineFor('   ', 16, now), isNull);
  });

  test('progress lines are sampled and normal lines are capped', () {
    final sampler = FfmpegLogcatSampler(maxLines: 2);
    final t0 = DateTime(2026);
    const progress = 'frame=  30 fps= 30 q=-0.0 size=1kB time=00:00:01 bitrate=1kbits/s speed=1x';
    expect(sampler.lineFor(progress, 32, t0), isNotNull);
    expect(sampler.lineFor(progress, 32, t0.add(const Duration(seconds: 3))), isNull);
    expect(sampler.lineFor(progress, 32, t0.add(const Duration(seconds: 11))), isNotNull);
    expect(sampler.lineFor('a', 24, t0), 'a');
    expect(sampler.lineFor('b', 16, t0), 'b');
    expect(sampler.lineFor('c', 16, t0), isNull);
  });
}
