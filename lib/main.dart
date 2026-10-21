import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/station_identity.dart';
import 'screens/station_screen.dart';
import 'screens/station_splash_screen.dart';
import 'services/app_language_service.dart';
import 'services/station_config_service.dart';
import 'theme/app_theme.dart';
import 'widgets/app_notice.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  StationIdentity? savedIdentity;
  await AppLanguageService.instance.load();
  try {
    savedIdentity = await StationConfigService().getOrCreateIdentity();
  } catch (error, stackTrace) {
    debugPrint('[BOOT] Không thể đọc hoặc tạo cấu hình mặc định: $error');
    debugPrintStack(stackTrace: stackTrace);
  }

  runApp(VnvarCameraStationApp(savedIdentity: savedIdentity));
}

enum _StartupStep { splash, station }

class VnvarCameraStationApp extends StatefulWidget {
  final StationIdentity? savedIdentity;

  const VnvarCameraStationApp({super.key, this.savedIdentity});

  @override
  State<VnvarCameraStationApp> createState() => _VnvarCameraStationAppState();
}

/// deviceId tạm khi không đọc/tạo được cấu hình: mỗi máy một mã ngẫu nhiên để
/// nhiều máy cùng lỗi không trùng nhau khi tablet dò tìm.
String _fallbackDeviceId() {
  final random = Random.secure();
  final suffix = List.generate(
    6,
    (_) => random.nextInt(16).toRadixString(16),
  ).join().toUpperCase();
  return 'PHONE-$suffix';
}

class _VnvarCameraStationAppState extends State<VnvarCameraStationApp> {
  late StationIdentity _identity;
  _StartupStep _step = _StartupStep.splash;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  bool _exitDialogOpen = false;

  @override
  void initState() {
    super.initState();
    final saved = widget.savedIdentity;
    if (saved == null) {
      debugPrint(
        '[BOOT] Dùng cấu hình tạm (chưa lưu). Hãy mở Cài đặt để chọn sân/camera.',
      );
    }
    _identity = saved ??
        StationIdentity(
          courtId: 'COURT-01',
          cameraId: 'CAM-01',
          deviceId: _fallbackDeviceId(),
          cameraName: 'Camera 01',
          cameraPosition: '',
        );
  }

  void _onSplashFinished() {
    if (!mounted) return;
    setState(() => _step = _StartupStep.station);
  }

  void _updateStationIdentity(StationIdentity identity) {
    if (!mounted) return;
    setState(() => _identity = identity);
  }

  Future<void> _handleSystemBack(bool didPop) async {
    if (didPop || !mounted) return;
    if (_step != _StartupStep.station || !Platform.isAndroid) return;
    // Chạm nhầm Back khi đang ghi sẽ huỷ engine Flutter và cắt ngang segment:
    // luôn hỏi lại trước khi thoát.
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null || _exitDialogOpen) return;
    _exitDialogOpen = true;
    bool? confirmed;
    try {
      confirmed = await showAppConfirm(
        dialogContext,
        icon: Icons.power_settings_new_rounded,
        titleVi: 'Thoát Camera Station?',
        titleEn: 'Exit Camera Station?',
        messageVi: 'Camera sẽ ngừng ghi và ngừng phát cho Tablet.',
        messageEn: 'Recording and tablet streaming will stop.',
        confirmVi: 'Thoát',
        confirmEn: 'Exit',
        cancelVi: 'Ở lại',
        cancelEn: 'Stay',
        destructive: true,
      );
    } finally {
      _exitDialogOpen = false;
    }
    if (confirmed == true && mounted) {
      await SystemNavigator.pop();
    }
  }

  Widget _buildCurrentScreen() {
    switch (_step) {
      case _StartupStep.splash:
        return StationSplashScreen(onFinished: _onSplashFinished);
      case _StartupStep.station:
        return StationScreen(
          identity: _identity,
          onIdentityChanged: _updateStationIdentity,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppLanguageScope(
      service: AppLanguageService.instance,
      child: MaterialApp(
        navigatorKey: _navigatorKey,
        title: 'VNVAR Camera Station',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        darkTheme: buildAppTheme(),
        themeMode: ThemeMode.dark,
        home: PopScope(
          canPop: _step == _StartupStep.splash,
          onPopInvokedWithResult: (didPop, _) => _handleSystemBack(didPop),
          child: _buildCurrentScreen(),
        ),
      ),
    );
  }
}
