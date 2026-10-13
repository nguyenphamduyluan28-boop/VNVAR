import 'dart:io';

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

class _VnvarCameraStationAppState extends State<VnvarCameraStationApp> {
  late StationIdentity _identity;
  _StartupStep _step = _StartupStep.splash;

  @override
  void initState() {
    super.initState();
    _identity = widget.savedIdentity ??
        const StationIdentity(
          courtId: 'COURT-01',
          cameraId: 'CAM-01',
          deviceId: 'PHONE-000000',
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
    if (_step == _StartupStep.station && Platform.isAndroid) {
      SystemNavigator.pop();
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
