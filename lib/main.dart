import 'package:flutter/material.dart';

import 'models/station_identity.dart';
import 'screens/court_count_screen.dart';
import 'screens/setup_screen.dart';
import 'screens/station_screen.dart';
import 'screens/station_splash_screen.dart';
import 'services/app_language_service.dart';
import 'services/camera_station_foreground_service.dart';
import 'services/camera_station_runtime.dart';
import 'services/station_config_service.dart';

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

  runApp(VnvarCameraStationApp(savedIdentity: savedIdentity));
}

enum _StartupStep { splash, courtSetup, cameraSetup, station }

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
      _showCourtSetup();
    }
  }

  void _showCourtSetup() {
    if (!mounted) return;
    setState(() => _step = _StartupStep.courtSetup);
  }

  void _showCameraSetup(int _) {
    if (!mounted) return;
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
        setState(() => _step = _StartupStep.cameraSetup);
        return;
      case _StartupStep.cameraSetup:
        setState(() => _step = _StartupStep.courtSetup);
        return;
      case _StartupStep.splash:
      case _StartupStep.courtSetup:
        break;
    }
  }

  Widget _buildCurrentScreen() {
    switch (_step) {
      case _StartupStep.splash:
        return StationSplashScreen(onFinished: _onSplashFinished);
      case _StartupStep.courtSetup:
        return CourtCountScreen(onSaved: _showCameraSetup);
      case _StartupStep.cameraSetup:
        return SetupScreen(
          initialIdentity: _identity,
          onConfigured: _startStation,
          onBack: _showCourtSetup,
        );
      case _StartupStep.station:
        final identity = _identity;
        if (identity == null) {
          // Bảo vệ trạng thái không hợp lệ; bình thường không thể xảy ra vì
          // SetupScreen chỉ chuyển bước sau khi đã tạo StationIdentity.
          return CourtCountScreen(onSaved: _showCameraSetup);
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
              _step == _StartupStep.splash || _step == _StartupStep.courtSetup,
          onPopInvokedWithResult: (didPop, _) => _handleSystemBack(didPop),
          child: _buildCurrentScreen(),
        ),
      ),
    );
  }
}
