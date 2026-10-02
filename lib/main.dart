import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/station_identity.dart';
import 'screens/setup_screen.dart';
import 'screens/station_screen.dart';
import 'screens/station_splash_screen.dart';
import 'services/app_language_service.dart';
import 'services/camera_station_foreground_service.dart';
import 'services/camera_station_runtime.dart';
import 'services/station_config_service.dart';

void lockPortraitForSetup() {
  SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  if (Platform.isAndroid) {
    const MethodChannel('vn.vnvar.cameraStation/channel')
        .invokeMethod('setScreenOrientation', {'mode': 'portrait'});
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  StationIdentity? savedIdentity;
  await AppLanguageService.instance.load();
  try {
    savedIdentity = await StationConfigService().loadIdentity();
  } catch (error, stackTrace) {
    debugPrint('[BOOT] Không thể đọc cấu hình đã lưu: $error');
    debugPrintStack(stackTrace: stackTrace);
  }

  // Khởi tạo hướng màn hình dọc (portrait) cho các bước khởi tạo & thiết lập
  if (savedIdentity == null) {
    lockPortraitForSetup();
  }

  runApp(VnvarCameraStationApp(savedIdentity: savedIdentity));
}

enum _StartupStep { splash, cameraSetup, station }

class VnvarCameraStationApp extends StatefulWidget {
  final StationIdentity? savedIdentity;

  const VnvarCameraStationApp({super.key, this.savedIdentity});

  @override
  State<VnvarCameraStationApp> createState() => _VnvarCameraStationAppState();
}

class _VnvarCameraStationAppState extends State<VnvarCameraStationApp> {
  late StationIdentity? _identity;
  _StartupStep _step = _StartupStep.splash;

  @override
  void initState() {
    super.initState();
    _identity = widget.savedIdentity;
  }

  void _onSplashFinished() {
    if (!mounted) return;
    if (_identity != null) {
      setState(() => _step = _StartupStep.station);
    } else {
      _showCameraSetup();
    }
  }

  void _showCameraSetup() {
    if (!mounted) return;
    lockPortraitForSetup();
    setState(() {
      _step = _StartupStep.cameraSetup;
    });
  }

  void _startStation(StationIdentity identity) {
    if (!mounted) return;
    setState(() {
      _identity = identity;
      _step = _StartupStep.station;
    });
  }

  void _updateStationIdentity(StationIdentity identity) {
    if (!mounted) return;
    setState(() => _identity = identity);
  }

  Future<void> _handleSystemBack(bool didPop) async {
    if (didPop || !mounted) return;
    switch (_step) {
      case _StartupStep.station:
        await CameraStationRuntime.instance.stop();
        await CameraStationForegroundService.stop();
        if (!mounted) return;
        lockPortraitForSetup();
        setState(() => _step = _StartupStep.cameraSetup);
        return;
      case _StartupStep.cameraSetup:
      case _StartupStep.splash:
        break;
    }
  }

  Widget _buildCurrentScreen() {
    switch (_step) {
      case _StartupStep.splash:
        return StationSplashScreen(onFinished: _onSplashFinished);
      case _StartupStep.cameraSetup:
        return SetupScreen(
          initialIdentity: _identity,
          onConfigured: _startStation,
          onBack: null,
        );
      case _StartupStep.station:
        final identity = _identity;
        if (identity == null) {
          return SetupScreen(
            initialIdentity: null,
            onConfigured: _startStation,
            onBack: null,
          );
        }
        return StationScreen(
          identity: identity,
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
          canPop:
              _step == _StartupStep.splash || _step == _StartupStep.cameraSetup,
          onPopInvokedWithResult: (didPop, _) => _handleSystemBack(didPop),
          child: _buildCurrentScreen(),
        ),
      ),
    );
  }
}
