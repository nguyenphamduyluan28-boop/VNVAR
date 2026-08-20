import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/station_identity.dart';
import '../services/camera_station_foreground_service.dart';
import '../services/camera_station_runtime.dart';
import '../services/station_config_service.dart';
import 'setup_screen.dart';
import 'video_storage_screen.dart';

// ============================================================
// STATION SCREEN
// ============================================================

class StationScreen extends StatefulWidget {
  final StationIdentity identity;
  final ValueChanged<StationIdentity> onIdentityChanged;

  const StationScreen({
    super.key,
    required this.identity,
    required this.onIdentityChanged,
  });

  @override
  State<StationScreen> createState() => _StationScreenState();
}

// ============================================================
// STATE
// ============================================================

class _StationScreenState extends State<StationScreen> {
  final CameraStationRuntime _runtime = CameraStationRuntime.instance;

  StreamSubscription<void>? _runtimeSubscription;

  bool _loading = true;
  String? _error;
  int _cameraQuarterTurns = 0;
  bool _cameraSwitching = false;
  bool _lensSwitching = false;
  String _viewerAddress = 'Đang kiểm tra mạng...';

  bool get _recording => _runtime.recordingService?.recording ?? false;

  bool get _cameraReady =>
      _runtime.cameraEnabled &&
      (_runtime.webRtcService?.cameraInitialized ?? false);

  Future<void> _toggleCamera() async {
    if (_cameraSwitching) return;
    setState(() => _cameraSwitching = true);
    final enableCamera = !_runtime.cameraEnabled;
    try {
      if (enableCamera) {
        // Foreground service is required before Android allows camera capture
        // to continue while the app is in background.
        await CameraStationForegroundService.start(
          cameraId: widget.identity.cameraId,
          courtId: widget.identity.courtId,
        );
      }

      await _runtime.setCameraEnabled(enableCamera);

      if (!enableCamera) {
        // The camera track has been released; remove the persistent
        // "camera active" notification as well.
        await CameraStationForegroundService.stop();
      }
    } catch (error) {
      if (enableCamera && !_runtime.cameraEnabled) {
        // Do not leave a misleading foreground notification when opening the
        // camera failed.
        try {
          await CameraStationForegroundService.stop();
        } catch (_) {}
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không thể đổi trạng thái camera: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _cameraSwitching = false);
    }
  }

  Future<void> _switchCameraLens() async {
    if (_lensSwitching || !_cameraReady) return;
    setState(() => _lensSwitching = true);
    try {
      await _runtime.switchCamera();
    } catch (error) {
      // Một số điện thoại chỉ cung cấp một camera cho WebRTC. Không hiển thị
      // cảnh báo trong trường hợp này vì đây là giới hạn thiết bị, không phải
      // lỗi vận hành của Station.
      debugPrint('[CAMERA] Bỏ qua yêu cầu đổi camera: $error');
    } finally {
      if (mounted) setState(() => _lensSwitching = false);
    }
  }

  // ============================================================
  // INIT
  // ============================================================

  @override
  void initState() {
    super.initState();

    _runtimeSubscription = _runtime.stateChanges.listen((_) {
      if (!mounted) {
        return;
      }

      setState(() {});
    });

    _initialize();
    _loadViewerAddress();
  }

  Future<void> _loadViewerAddress() async {
    var result = 'Chưa kết nối Wi-Fi/LAN';
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final addresses = interfaces
          .expand((interface) => interface.addresses)
          .where((address) => !address.isLoopback && !address.isLinkLocal)
          .toList();
      if (addresses.isNotEmpty) {
        final localAddresses = addresses.where(
          (address) =>
              address.address.startsWith('192.168.') ||
              address.address.startsWith('10.') ||
              address.address.startsWith('172.'),
        );
        final address =
            (localAddresses.isNotEmpty ? localAddresses.first : addresses.first)
                .address;
        result = 'http://$address:8080/viewer';
      }
    } catch (_) {
      result = 'Không đọc được địa chỉ IP';
    }
    if (mounted) {
      setState(() {
        _viewerAddress = result;
      });
    }
  }

  // ============================================================
  // INITIALIZE
  // ============================================================

  Future<void> _initialize() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      debugPrint(
        '[STATION] INITIALIZE '
        '${widget.identity.courtId}/'
        '${widget.identity.cameraId}',
      );

      await CameraStationForegroundService.start(
        cameraId: widget.identity.cameraId,
        courtId: widget.identity.courtId,
      );

      if (!mounted) {
        await _shutdownStation();
        return;
      }

      await _runtime.initialize(
        courtId: widget.identity.courtId,
        cameraId: widget.identity.cameraId,
        deviceId: widget.identity.deviceId,
      );

      if (!mounted) {
        await _shutdownStation();
        return;
      }

      setState(() {
        _loading = false;
        _error = null;
      });
    } catch (error, stackTrace) {
      debugPrint('[STATION] INIT ERROR: $error');

      debugPrintStack(stackTrace: stackTrace);

      if (!mounted) {
        return;
      }

      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  // ============================================================
  // RETRY
  // ============================================================

  Future<void> _retry() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      await _runtime.restart(
        cameraId: widget.identity.cameraId,
        courtId: widget.identity.courtId,
        deviceId: widget.identity.deviceId,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _loading = false;
        _error = null;
      });
    } catch (error, stackTrace) {
      debugPrint('[STATION] RETRY ERROR: $error');

      debugPrintStack(stackTrace: stackTrace);

      if (!mounted) {
        return;
      }

      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  // ============================================================
  // SETTINGS
  // ============================================================

  Future<void> _openSettings() async {
    final updated = await Navigator.of(context).push<StationIdentity>(
      MaterialPageRoute(
        builder: (setupContext) {
          return SetupScreen(
            initialIdentity: widget.identity,
            persistOnSave: false,
            onConfigured: (identity) {
              Navigator.of(setupContext).pop(identity);
            },
          );
        },
      ),
    );

    if (updated == null || !mounted) {
      return;
    }
    final newIdentity = updated;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          icon: const Icon(
            Icons.settings_rounded,
            color: Color(0xFF1565C0),
            size: 42,
          ),
          title: const Text(
            'ÁP DỤNG CẤU HÌNH MỚI?',
            textAlign: TextAlign.center,
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Camera Station sẽ khởi động lại '
                'dịch vụ với cấu hình mới.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF4F6F9),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  children: [
                    _ConfigLine(title: 'Tên', value: newIdentity.cameraName),
                    _ConfigLine(title: 'Camera', value: newIdentity.cameraId),
                    _ConfigLine(
                      title: 'Sân',
                      value: _courtLabel(newIdentity.courtId),
                    ),
                    _ConfigLine(
                      title: 'Vị trí',
                      value: newIdentity.cameraPosition,
                    ),
                  ],
                ),
              ),
            ],
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            OutlinedButton(
              onPressed: () {
                Navigator.pop(dialogContext, false);
              },
              child: const Text('HỦY'),
            ),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(dialogContext, true);
              },
              icon: const Icon(Icons.check_rounded),
              label: const Text('ÁP DỤNG'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      debugPrint(
        '[CONFIG] APPLY '
        '${newIdentity.courtId}/'
        '${newIdentity.cameraId}',
      );

      await _runtime.stop();

      await StationConfigService().saveIdentity(newIdentity);

      await CameraStationForegroundService.start(
        cameraId: newIdentity.cameraId,
        courtId: newIdentity.courtId,
      );

      await _runtime.initialize(
        cameraId: newIdentity.cameraId,
        courtId: newIdentity.courtId,
        deviceId: newIdentity.deviceId,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _loading = false;
        _error = null;
      });

      widget.onIdentityChanged(newIdentity);
    } catch (error, stackTrace) {
      debugPrint(
        '[CONFIG] APPLY ERROR: '
        '$error',
      );

      debugPrintStack(stackTrace: stackTrace);

      if (!mounted) {
        return;
      }

      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _openVideoStorage() async {
    final recording = _runtime.recordingService;
    if (recording == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => VideoStorageScreen(
          recordingService: recording,
          viewerAddress: _viewerAddress,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  // ============================================================
  // COURT LABEL
  // ============================================================

  String _courtLabel(String courtId) {
    final match = RegExp(r'(\d+)$').firstMatch(courtId);

    if (match == null) {
      return courtId;
    }

    final number = int.tryParse(match.group(1) ?? '');

    if (number == null) {
      return courtId;
    }

    return 'SÂN $number';
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  Future<void> _shutdownStation() async {
    try {
      await _runtime.stop();
    } catch (error, stackTrace) {
      debugPrint('[STATION] Không thể dừng camera runtime: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      try {
        await CameraStationForegroundService.stop();
      } catch (error, stackTrace) {
        debugPrint('[STATION] Không thể dừng foreground service: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
  }

  @override
  void dispose() {
    _runtimeSubscription?.cancel();
    unawaited(_shutdownStation());

    super.dispose();
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return _buildLoading();
    }

    if (_error != null) {
      return _buildError();
    }

    return _buildStation();
  }

  // ============================================================
  // LOADING
  // ============================================================

  Widget _buildLoading() {
    return Scaffold(
      backgroundColor: const Color(0xFF05070A),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/vnvar_logo.png',
                width: 150,
                height: 70,
                fit: BoxFit.contain,
              ),
              const SizedBox(height: 28),
              const CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2.6,
              ),
              const SizedBox(height: 18),
              const Text(
                'ĐANG KHỞI ĐỘNG CAMERA STATION...',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // ERROR
  // ============================================================

  Widget _buildError() {
    return Scaffold(
      backgroundColor: const Color(0xFF05070A),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxWidth: 460),
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: const Color(0xFF11161D),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.videocam_off_rounded,
                      color: Colors.redAccent,
                      size: 48,
                    ),
                  ),
                  const SizedBox(height: 22),
                  const Text(
                    'CAMERA STATION ERROR',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _error ?? '',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 26),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: _retry,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text(
                        'THỬ LẠI',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // STATION
  // ============================================================

  Widget _buildStation() {
    final renderer = _runtime.webRtcService?.localRenderer;

    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          // ----------------------------------------------------
          // RESPONSIVE BREAKPOINTS
          // Scale paddings / icon sizes down on small phones and
          // short (landscape) viewports so nothing overflows.
          // ----------------------------------------------------
          final narrow = constraints.maxWidth < 380;
          final short = constraints.maxHeight < 560;
          final compact = narrow || short;

          // Scrim height scales with the viewport instead of being a
          // fixed 180px — on short screens a fixed height made the
          // top + bottom scrims overlap and blanket the whole preview
          // in black. Capped so it never exceeds ~22% of the height
          // and top+bottom together leave the middle clear.
          return Stack(
            fit: StackFit.expand,
            children: [
              // ==============================================
              // CAMERA PREVIEW
              // ==============================================
              if (renderer != null && _cameraReady)
                RotatedBox(
                  quarterTurns: _cameraQuarterTurns,
                  child: RTCVideoView(
                    renderer,
                    mirror: false,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                )
              else
                const ColoredBox(
                  color: Colors.black,
                  child: Center(
                    child: Icon(
                      Icons.videocam_off_rounded,
                      color: Colors.white24,
                      size: 80,
                    ),
                  ),
                ),

              // ==============================================
              // TOP BAR (identity + primary actions)
              // ==============================================
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      compact ? 10 : 14,
                      compact ? 8 : 12,
                      compact ? 10 : 14,
                      0,
                    ),
                    child: _StationHeader(
                      identity: widget.identity,
                      courtLabel: _courtLabel(widget.identity.courtId),
                      recording: _recording,
                      compact: compact,
                      onVideoStorage: _openVideoStorage,
                      onSettings: _openSettings,
                    ),
                  ),
                ),
              ),

              // ==============================================
              // RIGHT-SIDE CAMERA CONTROLS
              // ==============================================
              Positioned(
                right: compact ? 8 : 14,
                top: 0,
                bottom: 0,
                child: SafeArea(
                  child: Center(
                    child: _CameraControlDock(
                      compact: compact,
                      cameraReady: _cameraReady,
                      cameraEnabled: _runtime.cameraEnabled,
                      cameraSwitching: _cameraSwitching,
                      lensSwitching: _lensSwitching,
                      onRotate: _cameraReady
                          ? () {
                              setState(() {
                                _cameraQuarterTurns =
                                    (_cameraQuarterTurns + 1) % 4;
                              });
                            }
                          : null,
                      onSwitchLens: _cameraReady && !_lensSwitching
                          ? _switchCameraLens
                          : null,
                      onToggleCamera: _cameraSwitching ? null : _toggleCamera,
                    ),
                  ),
                ),
              ),

              // ==============================================
              // BOTTOM STATUS
              // ==============================================
              Positioned(
                left: compact ? 8 : 14,
                right: compact ? 8 : 14,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  minimum: EdgeInsets.only(bottom: compact ? 10 : 14),
                  child: _BottomStatusBar(
                    compact: compact,
                    cameraReady: _cameraReady,
                    recording: _recording,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ============================================================
// HEADER
// ============================================================

class _StationHeader extends StatelessWidget {
  final StationIdentity identity;
  final String courtLabel;
  final bool recording;
  final bool compact;
  final VoidCallback onVideoStorage;
  final VoidCallback onSettings;

  const _StationHeader({
    required this.identity,
    required this.courtLabel,
    required this.recording,
    required this.compact,
    required this.onVideoStorage,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    final logoSize = compact ? 34.0 : 42.0;
    final actionSize = compact ? 34.0 : 38.0;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 10 : 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.64),
        borderRadius: BorderRadius.circular(compact ? 14 : 18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // -------------------------------------------------
          // ROW 1 — camera info (left) + settings cluster
          // (right), all on one line. Name shrinks via Expanded
          // so the trailing cluster never gets pushed off.
          // -------------------------------------------------
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: Container(
                  width: logoSize,
                  height: logoSize * 0.8,
                  padding: const EdgeInsets.all(4),
                  color: Colors.white.withValues(alpha: 0.08),
                  child: Image.asset(
                    'assets/images/vnvar_logo.png',
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  identity.cameraName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: compact ? 14 : 16,
                    fontWeight: FontWeight.w900,
                    height: 1.0,
                  ),
                ),
              ),
              SizedBox(width: compact ? 6 : 8),
              _RecordingChip(recording: recording, compact: compact),
              SizedBox(width: compact ? 6 : 8),
              _HeaderIconButton(
                icon: Icons.video_settings_rounded,
                tooltip: 'Kho video',
                size: actionSize,
                onTap: onVideoStorage,
              ),
              SizedBox(width: compact ? 4 : 6),
              _HeaderIconButton(
                icon: Icons.settings_rounded,
                tooltip: 'Cấu hình Camera Station',
                size: actionSize,
                onTap: onSettings,
              ),
            ],
          ),

          SizedBox(height: compact ? 8 : 10),
          Divider(
            height: 1,
            thickness: 1,
            color: Colors.white.withValues(alpha: 0.08),
          ),
          SizedBox(height: compact ? 8 : 10),

          // -------------------------------------------------
          // ROW 3 — identifiers only (camera / court / position)
          // -------------------------------------------------
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _HeaderTag(icon: Icons.videocam_rounded, text: identity.cameraId),
              _HeaderTag(icon: Icons.stadium_rounded, text: courtLabel),
              _HeaderTag(
                icon: Icons.location_on_rounded,
                text: identity.cameraPosition,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================
// RECORDING CHIP
// ============================================================

class _RecordingChip extends StatelessWidget {
  final bool recording;
  final bool compact;

  const _RecordingChip({required this.recording, required this.compact});

  @override
  Widget build(BuildContext context) {
    final color = recording ? Colors.redAccent : Colors.greenAccent;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 9,
        vertical: compact ? 5 : 6,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            recording ? 'REC' : 'READY',
            style: TextStyle(
              color: color,
              fontSize: compact ? 9 : 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// HEADER ICON BUTTON
// ============================================================

class _HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final double size;
  final VoidCallback onTap;

  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.size,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.12),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, color: Colors.white, size: size * 0.53),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// HEADER TAG
// ============================================================

class _HeaderTag extends StatelessWidget {
  final IconData icon;
  final String text;

  const _HeaderTag({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 160),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: Colors.white70),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// CAMERA CONTROL DOCK (rotate / switch lens / toggle camera)
// ============================================================

class _CameraControlDock extends StatelessWidget {
  final bool compact;
  final bool cameraReady;
  final bool cameraEnabled;
  final bool cameraSwitching;
  final bool lensSwitching;
  final VoidCallback? onRotate;
  final VoidCallback? onSwitchLens;
  final VoidCallback? onToggleCamera;

  const _CameraControlDock({
    required this.compact,
    required this.cameraReady,
    required this.cameraEnabled,
    required this.cameraSwitching,
    required this.lensSwitching,
    required this.onRotate,
    required this.onSwitchLens,
    required this.onToggleCamera,
  });

  @override
  Widget build(BuildContext context) {
    final gap = compact ? 8.0 : 12.0;
    final buttonSize = compact ? 38.0 : 44.0;

    return Container(
      padding: EdgeInsets.symmetric(vertical: compact ? 8 : 10, horizontal: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _DockButton(
            icon: Icons.rotate_90_degrees_cw_rounded,
            tooltip: 'Xoay hình camera 90°',
            size: buttonSize,
            onPressed: onRotate,
          ),
          SizedBox(height: gap),
          _DockButton(
            icon: Icons.cameraswitch_rounded,
            tooltip: 'Đổi camera trước/sau',
            size: buttonSize,
            onPressed: onSwitchLens,
            loading: lensSwitching,
          ),
          SizedBox(height: gap),
          _DockButton(
            icon: cameraEnabled
                ? Icons.videocam_off_rounded
                : Icons.videocam_rounded,
            tooltip: cameraEnabled ? 'Tắt camera' : 'Bật camera',
            size: buttonSize,
            onPressed: onToggleCamera,
            loading: cameraSwitching,
            background: cameraEnabled
                ? Colors.red.withValues(alpha: 0.75)
                : Colors.green.withValues(alpha: 0.75),
          ),
        ],
      ),
    );
  }
}

class _DockButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final double size;
  final VoidCallback? onPressed;
  final bool loading;
  final Color? background;

  const _DockButton({
    required this.icon,
    required this.tooltip,
    required this.size,
    required this.onPressed,
    this.loading = false,
    this.background,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background ?? Colors.white.withValues(alpha: 0.10),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: loading
                  ? SizedBox(
                      width: size * 0.4,
                      height: size * 0.4,
                      child: const CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      icon,
                      size: size * 0.5,
                      color: onPressed == null ? Colors.white30 : Colors.white,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// BOTTOM STATUS BAR
// ============================================================

class _BottomStatusBar extends StatelessWidget {
  final bool compact;
  final bool cameraReady;
  final bool recording;

  const _BottomStatusBar({
    required this.compact,
    required this.cameraReady,
    required this.recording,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 9 : 11,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(compact ? 14 : 16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _CompactStatus(
              icon: Icons.videocam_rounded,
              text: cameraReady ? 'CAMERA READY' : 'CAMERA OFF',
              color: cameraReady ? Colors.greenAccent : Colors.orangeAccent,
              compact: compact,
            ),
          ),
          Container(
            width: 1,
            height: 22,
            color: Colors.white.withValues(alpha: 0.10),
          ),
          Expanded(
            child: _CompactStatus(
              icon: Icons.fiber_manual_record_rounded,
              text: recording ? 'RECORDING' : 'READY',
              color: recording ? Colors.redAccent : Colors.greenAccent,
              compact: compact,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// COMPACT STATUS
// ============================================================

class _CompactStatus extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  final bool compact;

  const _CompactStatus({
    required this.icon,
    required this.text,
    required this.color,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: compact ? 12 : 13),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: compact ? 8 : 9,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================
// GRADIENT
// ============================================================

// ============================================================
// CONFIG LINE
// ============================================================

class _ConfigLine extends StatelessWidget {
  final String title;
  final String value;

  const _ConfigLine({required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.black54,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: Color(0xFF112341),
                fontSize: 12,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
