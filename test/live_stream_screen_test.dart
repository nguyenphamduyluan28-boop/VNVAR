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

Future<void> _pumpScreen(WidgetTester tester, StationConfigService config) {
  return tester.pumpWidget(
    MaterialApp(
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
}
