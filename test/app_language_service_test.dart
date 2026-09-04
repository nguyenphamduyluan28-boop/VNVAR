import 'package:camera_station/services/app_language_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('persists and restores the selected UI language', () async {
    SharedPreferences.setMockInitialValues({});
    final service = AppLanguageService.instance;

    await service.setLanguage(AppLanguage.english);
    expect(service.language, AppLanguage.english);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('camera_station_language'), 'en');

    await service.setLanguage(AppLanguage.vietnamese);
    expect(service.language, AppLanguage.vietnamese);
    expect(preferences.getString('camera_station_language'), 'vi');
  });

  testWidgets('updates visible text without restarting the app', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final service = AppLanguageService.instance;
    await service.setLanguage(AppLanguage.vietnamese);

    await tester.pumpWidget(
      AppLanguageScope(
        service: service,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Text(appText(context, 'Máy quay', 'Camera')),
          ),
        ),
      ),
    );
    expect(find.text('Máy quay'), findsOneWidget);

    await service.setLanguage(AppLanguage.english);
    await tester.pump();
    expect(find.text('Camera'), findsOneWidget);
  });
}
