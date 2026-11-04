import 'package:flutter_test/flutter_test.dart';

import '../tool/sync_flutter_webrtc_darwin.dart' as darwin_sync;

/// iOS/macOS build bản sao của plugin flutter_webrtc trong
/// `packages/flutter_webrtc/<ios|macos>/flutter_webrtc/Sources/`, không phải
/// `common/darwin/Classes/`. Test này báo lỗi khi hai nơi lệch nhau (sửa
/// `common/` mà quên đồng bộ thì app không nhận bản sửa).
void main() {
  test('flutter_webrtc iOS/macOS sources match common/darwin/Classes', () {
    final report = darwin_sync.compareDarwinCopies(
      darwin_sync.flutterWebrtcPluginDir,
    );
    expect(
      report.describe(),
      isEmpty,
      reason:
          'Chỉ sửa packages/flutter_webrtc/common/darwin/Classes/, rồi chạy: '
          'dart run tool/sync_flutter_webrtc_darwin.dart',
    );
  });
}
