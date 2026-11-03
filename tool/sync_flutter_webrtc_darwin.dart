// Đồng bộ code Objective-C của plugin flutter_webrtc (đã vá) cho iOS/macOS.
//
// Nguồn DUY NHẤT được sửa: packages/flutter_webrtc/common/darwin/Classes/.
// iOS và macOS build bản sao trong <ios|macos>/flutter_webrtc/Sources/
// flutter_webrtc/ (theo podspec và Package.swift). Ở plugin gốc các bản sao
// này là symlink tới common/, nhưng trong repo này là file thật (Git trên
// Windows tắt symlink), nên sửa common/ mà không chép sang thì app KHÔNG
// nhận bản sửa.
//
// Cách dùng (từ thư mục gốc dự án):
//   dart run tool/sync_flutter_webrtc_darwin.dart          # chép common/ sang bản sao
//   dart run tool/sync_flutter_webrtc_darwin.dart --check  # chỉ kiểm tra, lệch thì exit 1
//
// test/flutter_webrtc_darwin_sync_test.dart chạy bước kiểm tra trong
// `flutter test`, nên quên đồng bộ là test báo lỗi.

import 'dart:io';

/// Thư mục plugin, tính từ thư mục gốc dự án.
const String flutterWebrtcPluginDir = 'packages/flutter_webrtc';

/// Một bản sao cần giữ giống common/.
class DarwinCopy {
  const DarwinCopy({
    required this.platform,
    required this.requireAllCommonFiles,
    this.platformOnlyFiles = const {},
  });

  final String platform;

  /// iOS: mọi file của common/ phải có trong bản sao. macOS: plugin gốc chỉ
  /// dùng một phần (không có trình ghi video, audio sink...), nên chỉ đồng bộ
  /// các file bản sao đang có.
  final bool requireAllCommonFiles;

  /// File riêng của nền tảng, không có trong common/ (đường dẫn tương đối
  /// trong Sources/flutter_webrtc/).
  final Set<String> platformOnlyFiles;

  String sourcesDir(String pluginRoot) =>
      '$pluginRoot/$platform/flutter_webrtc/Sources/flutter_webrtc';
}

const List<DarwinCopy> darwinCopies = [
  DarwinCopy(
    platform: 'ios',
    requireAllCommonFiles: true,
    platformOnlyFiles: {
      'Broadcast/FlutterBroadcastScreenCapturer.m',
      'Broadcast/FlutterSocketConnection.m',
      'Broadcast/FlutterSocketConnectionFrameReader.m',
      'include/flutter_webrtc/FlutterBroadcastScreenCapturer.h',
      'include/flutter_webrtc/FlutterSocketConnection.h',
      'include/flutter_webrtc/FlutterSocketConnectionFrameReader.h',
    },
  ),
  DarwinCopy(
    platform: 'macos',
    requireAllCommonFiles: false,
    platformOnlyFiles: {
      'FlutterScreenCaptureKitCapturer.m',
      'include/flutter_webrtc/FlutterScreenCaptureKitCapturer.h',
    },
  ),
];

/// Vị trí của một file common/ trong bản sao: header (.h) nằm ở
/// include/flutter_webrtc/, còn lại nằm ngay trong Sources/flutter_webrtc/.
String copyPathFor(String commonFileName) => commonFileName.endsWith('.h')
    ? 'include/flutter_webrtc/$commonFileName'
    : commonFileName;

String commonDir(String pluginRoot) => '$pluginRoot/common/darwin/Classes';

List<String> _listRelative(String dir) {
  final root = Directory(dir);
  if (!root.existsSync()) return const [];
  final prefix = root.absolute.path.length + 1;
  return root
      .listSync(recursive: true)
      .whereType<File>()
      .map((f) => f.absolute.path.substring(prefix).replaceAll('\\', '/'))
      .where((p) => !p.split('/').last.startsWith('.'))
      .toList()
    ..sort();
}

/// So nội dung, bỏ qua khác biệt CRLF/LF (Git trên Windows có thể đổi đuôi
/// dòng khi checkout; trình biên dịch không quan tâm).
bool _sameContent(File a, File b) {
  String norm(File f) => f.readAsStringSync().replaceAll('\r\n', '\n');
  return norm(a) == norm(b);
}

/// Một việc đồng bộ: chép [from] đè lên [to].
class SyncItem {
  const SyncItem(this.from, this.to, {this.missing = false});
  final String from;
  final String to;

  /// Bản sao chưa có file này.
  final bool missing;
}

/// Kết quả so sánh common/ với các bản sao.
class DarwinSyncReport {
  final List<SyncItem> outdated = [];
  final List<String> problems = [];

  bool get inSync => outdated.isEmpty && problems.isEmpty;

  List<String> describe() => [
    for (final item in outdated)
      item.missing
          ? 'Thiếu: ${item.to} (có trong ${item.from})'
          : 'Lệch: ${item.to} (khác ${item.from})',
    ...problems,
  ];
}

DarwinSyncReport compareDarwinCopies(String pluginRoot) {
  final report = DarwinSyncReport();
  final common = commonDir(pluginRoot);
  final commonFiles = _listRelative(common);
  if (commonFiles.isEmpty) {
    report.problems.add('Không tìm thấy $common.');
    return report;
  }
  for (final copy in darwinCopies) {
    final sources = copy.sourcesDir(pluginRoot);
    final copyFiles = _listRelative(sources).toSet();
    if (copyFiles.isEmpty) {
      report.problems.add('Không tìm thấy $sources.');
      continue;
    }
    final mapped = <String>{};
    for (final name in commonFiles) {
      final target = copyPathFor(name);
      mapped.add(target);
      final targetFile = File('$sources/$target');
      if (!targetFile.existsSync()) {
        // File mới trong common/: iOS phải có (lệnh đồng bộ sẽ tạo).
        if (copy.requireAllCommonFiles) {
          report.outdated.add(
            SyncItem('$common/$name', targetFile.path, missing: true),
          );
        }
        continue;
      }
      if (!_sameContent(File('$common/$name'), targetFile)) {
        report.outdated.add(SyncItem('$common/$name', targetFile.path));
      }
    }
    for (final extra in copyFiles.difference(mapped)) {
      if (copy.platformOnlyFiles.contains(extra)) continue;
      report.problems.add(
        'File lạ trong bản sao ${copy.platform}: $sources/$extra '
        '(không có trong common/). Đưa nó vào common/ hoặc vào danh sách '
        'platformOnlyFiles của tool/sync_flutter_webrtc_darwin.dart.',
      );
    }
  }
  return report;
}

/// Chép common/ sang các bản sao. Trả về danh sách file đã ghi.
List<String> syncDarwinCopies(String pluginRoot) {
  final report = compareDarwinCopies(pluginRoot);
  final written = <String>[];
  for (final item in report.outdated) {
    final target = File(item.to);
    target.parent.createSync(recursive: true);
    target.writeAsBytesSync(File(item.from).readAsBytesSync(), flush: true);
    written.add(item.to);
  }
  return written;
}

void main(List<String> args) {
  final checkOnly = args.contains('--check');
  final pluginRoot = flutterWebrtcPluginDir;
  if (!Directory(pluginRoot).existsSync()) {
    stderr.writeln('Chạy lệnh này từ thư mục gốc dự án (không thấy $pluginRoot).');
    exitCode = 2;
    return;
  }
  if (checkOnly) {
    final report = compareDarwinCopies(pluginRoot);
    if (report.inSync) {
      stdout.writeln('flutter_webrtc: bản sao iOS/macOS khớp common/.');
      return;
    }
    report.describe().forEach(stderr.writeln);
    stderr.writeln(
      'Chạy: dart run tool/sync_flutter_webrtc_darwin.dart (sửa ở common/).',
    );
    exitCode = 1;
    return;
  }
  final written = syncDarwinCopies(pluginRoot);
  for (final path in written) {
    stdout.writeln('Đã chép: $path');
  }
  final after = compareDarwinCopies(pluginRoot);
  if (!after.inSync) {
    after.describe().forEach(stderr.writeln);
    exitCode = 1;
    return;
  }
  stdout.writeln(
    written.isEmpty
        ? 'flutter_webrtc: đã khớp sẵn, không có gì để chép.'
        : 'flutter_webrtc: đã đồng bộ ${written.length} file.',
  );
}
