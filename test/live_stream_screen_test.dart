import 'package:camera_station/screens/live_stream_screen.dart';
import 'package:camera_station/services/camera_station_runtime.dart';
import 'package:camera_station/services/station_config_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeConfig extends StationConfigService {
  _FakeConfig({
    this.failRtsp = false,
    this.failWhipUrl = false,
    this.failWhipToken = false,
  });

  final bool failRtsp;
  final bool failWhipUrl;
  final bool failWhipToken;

  @override
  Future<String?> loadRtspPushUrl() async {
    if (failRtsp) throw Exception('prefs');
    return 'rtmp://a.rtmp.youtube.com/live2/saved-key';
  }

  @override
  Future<String?> loadWhipEndpointUrl() async {
    if (failWhipUrl) throw Exception('prefs');
    return 'https://mediamtx.local/cam/whip';
  }

  @override
  Future<String?> loadWhipAuthToken() async {
    if (failWhipToken) throw Exception('prefs');
    return 'token';
  }
}

Future<void> _pumpScreen(
  WidgetTester tester,
  StationConfigService config, {
  double textScale = 1.0,
}) {
  return tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child ?? const SizedBox.shrink(),
      ),
      home: LiveStreamScreen(
        runtime: CameraStationRuntime.instance,
        configService: config,
      ),
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('every config load failing still clears spinner and warns',
      (tester) async {
    await _pumpScreen(
      tester,
      _FakeConfig(failRtsp: true, failWhipUrl: true, failWhipToken: true),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one failing field does not block the others', (tester) async {
    await _pumpScreen(tester, _FakeConfig(failWhipToken: true));
    await tester.pump();
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
    final keyField = tester.widgetList<EditableText>(find.byType(EditableText))
        .map((e) => e.controller.text);
    expect(keyField, contains('saved-key'));
  });

  testWidgets('healthy config loads without warning', (tester) async {
    await _pumpScreen(tester, _FakeConfig());
    await tester.pump();
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('idle screen does not overflow at 320x640 with large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpScreen(tester, _FakeConfig(), textScale: 1.3);
    await tester.pump();
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);

    // Nút chính dài nhất khi chưa phát: "Sao chép link" (OBS).
    await tester.tap(find.text('OBS'));
    await tester.pump();
    expect(find.text('Sao chép link'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Nền tảng có ô Server URL riêng (TikTok).
    await tester.tap(find.text('TikTok'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('idle main button keeps its go-live label', (tester) async {
    await _pumpScreen(tester, _FakeConfig());
    await tester.pump();
    await tester.pump();

    expect(find.text('Bắt đầu phát'), findsOneWidget);
    expect(find.text('Dừng'), findsNothing);
    expect(find.text('Đang kết nối · Hủy'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // Dọc điện thoại, ngang điện thoại (1 cột) và máy tính bảng (2 cột).
  for (final size in const [Size(360, 640), Size(640, 360), Size(1280, 800)]) {
    testWidgets(
        'idle layout fits ${size.width.toInt()}x${size.height.toInt()} '
        'with large text', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _pumpScreen(tester, _FakeConfig(), textScale: 1.3);
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Bắt đầu phát'), findsOneWidget);
    });
  }

  testWidgets('advanced section expands to show WHIP fields', (tester) async {
    await _pumpScreen(tester, _FakeConfig());
    await tester.pump();
    await tester.pump();

    Iterable<String> fieldTexts() => tester
        .widgetList<EditableText>(find.byType(EditableText))
        .map((e) => e.controller.text);

    expect(fieldTexts(), isNot(contains('https://mediamtx.local/cam/whip')));

    await tester.ensureVisible(find.text('Nâng cao'));
    await tester.tap(find.text('Nâng cao'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(fieldTexts(), contains('https://mediamtx.local/cam/whip'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('scoreboard tile toggles overlay visibility', (tester) async {
    await _pumpScreen(tester, _FakeConfig());
    await tester.pump();
    await tester.pump();

    expect(find.text('Ẩn'), findsOneWidget);
    expect(find.text('Hiện'), findsOneWidget);

    await tester.ensureVisible(find.text('Hiện'));
    await tester.tap(find.text('Hiện'));
    await tester.pump();
    expect(find.text('Hiện trên video'), findsOneWidget);

    // Trả lại trạng thái mặc định (ScoreboardService dùng chung giữa các test)
    // và chờ hẹn giờ lưu chạy xong.
    await tester.tap(find.text('Ẩn'));
    await tester.pump();
    expect(find.text('Chọn Hiện để in vào video'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
  });
}
