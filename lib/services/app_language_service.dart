import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLanguage {
  vietnamese('vi', 'VI', '🇻🇳'),
  english('en', 'EN', '🇬🇧');

  const AppLanguage(this.code, this.shortLabel, this.flag);

  final String code;
  final String shortLabel;
  final String flag;
}

class AppLanguageService extends ChangeNotifier {
  AppLanguageService._();

  static final AppLanguageService instance = AppLanguageService._();
  static const _preferenceKey = 'camera_station_language';

  AppLanguage _language = AppLanguage.vietnamese;

  AppLanguage get language => _language;
  Locale get locale => Locale(_language.code);
  bool get isEnglish => _language == AppLanguage.english;

  Future<void> load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final code = preferences.getString(_preferenceKey);
      _language = AppLanguage.values.firstWhere(
        (value) => value.code == code,
        orElse: () => AppLanguage.vietnamese,
      );
    } catch (error, stackTrace) {
      _language = AppLanguage.vietnamese;
      debugPrint('[LANGUAGE] Cannot load language preference: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> setLanguage(AppLanguage language) async {
    if (_language == language) return;
    _language = language;
    notifyListeners();
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_preferenceKey, language.code);
    } catch (error, stackTrace) {
      debugPrint('[LANGUAGE] Cannot save language preference: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }
}

class AppLanguageScope extends InheritedNotifier<AppLanguageService> {
  const AppLanguageScope({
    required AppLanguageService service,
    required super.child,
    super.key,
  }) : super(notifier: service);

  static AppLanguageService of(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<AppLanguageScope>()
            ?.notifier ??
        AppLanguageService.instance;
  }
}

String appText(BuildContext context, String vietnamese, String english) {
  return AppLanguageScope.of(context).isEnglish ? english : vietnamese;
}

class AppLanguageButton extends StatelessWidget {
  const AppLanguageButton({super.key, this.foregroundColor, this.size = 48});

  final Color? foregroundColor;
  final double size;

  @override
  Widget build(BuildContext context) {
    final service = AppLanguageScope.of(context);
    return SizedBox(
      width: size + 22,
      height: size,
      child: PopupMenuButton<AppLanguage>(
        tooltip: appText(context, 'Ngôn ngữ', 'Language'),
        initialValue: service.language,
        padding: EdgeInsets.zero,
        onSelected: service.setLanguage,
        itemBuilder: (context) => AppLanguage.values
            .map(
              (language) => PopupMenuItem<AppLanguage>(
                value: language,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(language.flag, style: const TextStyle(fontSize: 21)),
                    const SizedBox(width: 8),
                    Text(
                      language.shortLabel,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
            )
            .toList(),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                service.language.flag,
                style: TextStyle(fontSize: size * 0.42),
              ),
              const SizedBox(width: 4),
              Text(
                service.language.shortLabel,
                style: TextStyle(
                  color: foregroundColor,
                  fontSize: size * 0.3,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
