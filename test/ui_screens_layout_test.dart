import 'package:camera_station/screens/setup_screen.dart';
import 'package:camera_station/services/scoreboard_service.dart';
import 'package:camera_station/widgets/brand_widgets.dart';
import 'package:camera_station/widgets/scoreboard_hub_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Kiểm tra bố cục (không tràn, không lỗi ParentData) của các màn dựng được
/// mà không cần camera/plugin native, ở 3 kích thước chuẩn với chữ 1.3×.
///
/// Không gồm: StationScreen (camera, foreground service), VideoStorageScreen
/// và SavedVideosScreen (cần RecordingService + path_provider/thư mục thật).
/// LiveStreamScreen đã có test riêng (test/live_stream_screen_test.dart).
const _sizes = [Size(360, 640), Size(640, 360), Size(1280, 800)];

Widget _app(Widget home) {
  return MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: const TextScaler.linear(1.3),
      ),
      child: child ?? const SizedBox.shrink(),
    ),
    home: home,
  );
}

void _setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final size in _sizes) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('SetupScreen fits $label with 1.3x text', (tester) async {
      _setSize(tester, size);
      // SetupScreen gọi SystemChrome.setPreferredOrientations khi mở.
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      {
        await tester.pumpWidget(_app(SetupScreen(onConfigured: (_) {})));
        await tester.pump();
        await tester.pump();

        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.text('Court ID'), findsOneWidget);
        expect(find.text('Camera ID'), findsOneWidget);
        expect(find.byType(BrandTile), findsNWidgets(2));
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('Scoreboard hub fits $label with 1.3x text', (tester) async {
      _setSize(tester, size);
      final service = ScoreboardService(
        storageKey: 'ui_layout_scoreboard_state',
        controlKeyStorageKey: 'ui_layout_scoreboard_key',
      );

      await tester.pumpWidget(
        _app(
          Scaffold(
            body: SafeArea(
              child: ScoreboardHubSheet(
                lanAddress: () => '192.168.1.20',
                port: 8080,
                service: service,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);

      // Bật overlay để hiện mã QR + các dòng link (BrandTile có phần đuôi).
      if (find.byType(QrImageView).evaluate().isEmpty) {
        await tester.tap(find.text('Hiện'));
        await tester.pump();
      }
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.text('Đổi mã'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Trả lại trạng thái và chờ hẹn giờ lưu (400 ms) chạy xong.
      await tester.tap(find.text('Ẩn'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
    });
  }
}
