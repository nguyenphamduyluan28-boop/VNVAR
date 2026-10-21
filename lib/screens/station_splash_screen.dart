import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_language_service.dart';
import '../theme/app_theme.dart';
import '../widgets/brand_widgets.dart';

class StationSplashScreen extends StatefulWidget {
  final VoidCallback onFinished;

  const StationSplashScreen({super.key, required this.onFinished});

  @override
  State<StationSplashScreen> createState() => _StationSplashScreenState();
}

class _StationSplashScreenState extends State<StationSplashScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 2), widget.onFinished);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrandColors.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.all(BrandSpace.xl),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: (constraints.maxHeight - 2 * BrandSpace.xl).clamp(
                  0,
                  double.infinity,
                ),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Image(
                      image: AssetImage('assets/images/vnvar_logo.png'),
                      width: 240,
                      height: 58,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(height: BrandSpace.xl),
                    const SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: BrandColors.primaryBright,
                      ),
                    ),
                    const SizedBox(height: BrandSpace.lg),
                    Text(
                      appText(
                        context,
                        'Đang khởi tạo camera...',
                        'Starting camera...',
                      ),
                      textAlign: TextAlign.center,
                      style: BrandText.body,
                    ),
                    const SizedBox(height: BrandSpace.xs),
                    const Text(
                      'VNVAR Camera Station',
                      textAlign: TextAlign.center,
                      style: BrandText.caption,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
