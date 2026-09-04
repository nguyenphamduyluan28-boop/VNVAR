import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_language_service.dart';

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
      backgroundColor: Color(0xFFF3F6FA),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: (constraints.maxHeight - 48).clamp(
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
                      width: 260,
                      height: 150,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(height: 24),
                    const SizedBox(
                      width: 34,
                      height: 34,
                      child: CircularProgressIndicator(strokeWidth: 3),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      appText(
                        context,
                        'CAMERA ĐANG KHỞI TẠO...',
                        'INITIALIZING CAMERA...',
                      ),
                      style: const TextStyle(
                        color: Color(0xFF12223F),
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      appText(
                        context,
                        'VNVAR Camera Station đang chuẩn bị',
                        'VNVAR Camera Station is getting ready',
                      ),
                      style: const TextStyle(
                        color: Colors.black54,
                        fontSize: 13,
                      ),
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
