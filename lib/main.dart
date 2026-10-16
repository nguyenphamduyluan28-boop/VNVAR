import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/station_identity.dart';
import 'screens/station_screen.dart';
import 'screens/station_splash_screen.dart';
import 'services/app_language_service.dart';
import 'services/station_config_service.dart';

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
      confirmed = await showDialog<bool>(
        context: dialogContext,
        builder: (context) => AlertDialog(
          title: Text(appText(context, 'Thoát Camera Station?', 'Exit Camera Station?')),
          content: Text(
            appText(
              context,
              'Camera sẽ ngừng ghi hình và ngừng phát cho Tablet.',
              'The camera will stop recording and streaming to tablets.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(appText(context, 'Ở LẠI', 'STAY')),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.pop(context, true),
              child: Text(appText(context, 'THOÁT', 'EXIT')),
            ),
          ],
        ),
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
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
          useMaterial3: true,
        ),
        home: PopScope(
          canPop: _step == _StartupStep.splash,
          onPopInvokedWithResult: (didPop, _) => _handleSystemBack(didPop),
          child: _buildCurrentScreen(),
        ),
      ),
    );
  }
}
