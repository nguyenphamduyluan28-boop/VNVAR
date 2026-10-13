import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_language_service.dart';
import '../services/camera_station_runtime.dart';
import '../services/station_config_service.dart';
import '../services/whip_publisher_service.dart';
import '../services/rtsp_publisher_service.dart';
import '../widgets/qr_stream_scanner_dialog.dart';

enum StreamPlatform { youtube, facebook, tiktok, custom }

class LiveStreamScreen extends StatefulWidget {
  final CameraStationRuntime runtime;
  final StationConfigService configService;

  const LiveStreamScreen({
    super.key,
    required this.runtime,
    required this.configService,
  });

  @override
  State<LiveStreamScreen> createState() => _LiveStreamScreenState();
}

class _LiveStreamScreenState extends State<LiveStreamScreen> {
  StreamPlatform _platform = StreamPlatform.youtube;

  // Controllers
  final TextEditingController _streamKeyController = TextEditingController();
  final TextEditingController _customUrlController = TextEditingController();
  final TextEditingController _tiktokServerController = TextEditingController(
    text: 'rtmp://live-push.tiktok.com/live',
  );

  // WHIP (Advanced)
  final TextEditingController _whipUrlController = TextEditingController();
  final TextEditingController _whipTokenController = TextEditingController();

  bool _obscureKey = true;
  bool _showAdvanced = false;
  bool _isLoading = true;

  StreamSubscription<WhipPublishState>? _whipSubscription;
  StreamSubscription<RtspPublishState>? _rtspSubscription;

  WhipPublisherService get _whipService => widget.runtime.whipPublisherService;
  RtspPublisherService get _rtspService => widget.runtime.rtspPublisherService;

  bool get _isLive => _rtspService.isLive || _whipService.isLive;
  bool get _isBusy =>
      _rtspService.state == RtspPublishState.connecting ||
      _whipService.state == WhipPublishState.connecting;

  @override
  void initState() {
    super.initState();
    _loadInitialConfig();

    _whipSubscription = _whipService.onStateChanged.listen((_) {
      if (mounted) setState(() {});
    });

    _rtspSubscription = _rtspService.onStateChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadInitialConfig() async {
    final rtspUrl = await widget.configService.loadRtspPushUrl();
    final whipUrl = await widget.configService.loadWhipEndpointUrl();
    final whipToken = await widget.configService.loadWhipAuthToken();

    if (mounted) {
      setState(() {
        _whipUrlController.text = whipUrl ?? '';
        _whipTokenController.text = whipToken ?? '';

        if (rtspUrl != null && rtspUrl.isNotEmpty) {
          _detectPlatformAndParse(rtspUrl);
        } else {
          _platform = StreamPlatform.youtube;
        }
        _isLoading = false;
      });
    }
  }

  void _detectPlatformAndParse(String url) {
    _customUrlController.text = url;
    final lower = url.toLowerCase();

    if (lower.contains('youtube.com')) {
      _platform = StreamPlatform.youtube;
      const prefix = 'rtmp://a.rtmp.youtube.com/live2/';
      if (lower.startsWith(prefix.toLowerCase())) {
        _streamKeyController.text = url.substring(prefix.length);
      }
    } else if (lower.contains('facebook.com')) {
      _platform = StreamPlatform.facebook;
      const prefix = 'rtmps://live-api-s.facebook.com:443/rtmp/';
      if (lower.startsWith(prefix.toLowerCase())) {
        _streamKeyController.text = url.substring(prefix.length);
      }
    } else if (lower.contains('tiktok')) {
      _platform = StreamPlatform.tiktok;
      final uri = Uri.tryParse(url);
      if (uri != null && uri.pathSegments.isNotEmpty) {
        _streamKeyController.text = uri.pathSegments.last;
      }
    } else {
      _platform = StreamPlatform.custom;
    }
  }

  @override
  void dispose() {
    _whipSubscription?.cancel();
    _rtspSubscription?.cancel();
    _streamKeyController.dispose();
    _customUrlController.dispose();
    _tiktokServerController.dispose();
    _whipUrlController.dispose();
    _whipTokenController.dispose();
    super.dispose();
  }

  String _buildEffectiveUrl() {
    switch (_platform) {
      case StreamPlatform.youtube:
        final key = _streamKeyController.text.trim();
        return 'rtmp://a.rtmp.youtube.com/live2/$key';
      case StreamPlatform.facebook:
        final key = _streamKeyController.text.trim();
        return 'rtmps://live-api-s.facebook.com:443/rtmp/$key';
      case StreamPlatform.tiktok:
        final server = _tiktokServerController.text.trim();
        final key = _streamKeyController.text.trim();
        if (key.isEmpty) return server;
        return server.endsWith('/') ? '$server$key' : '$server/$key';
      case StreamPlatform.custom:
        return _customUrlController.text.trim();
    }
  }

  Future<void> _handleStartLive() async {
    final url = _buildEffectiveUrl();
    if (url.isEmpty || (_platform != StreamPlatform.custom && _streamKeyController.text.trim().isEmpty)) {
      _showToast(
        appText(
          context,
          'Vui lòng nhập Khóa luồng (Stream Key).',
          'Please enter your Stream Key.',
        ),
        isError: true,
      );
      return;
    }

    final webRtc = widget.runtime.webRtcService;
    if (webRtc == null || !webRtc.cameraInitialized) {
      _showToast(
        appText(
          context,
          'Camera đang khởi động, vui lòng chờ giây lát.',
          'Camera is starting up, please wait a moment.',
        ),
        isError: true,
      );
      return;
    }

    await widget.configService.saveRtspPushConfig(targetUrl: url);
    await widget.configService.saveStreamProtocol('rtsp');

    setState(() {});
    await _rtspService.startPublish(targetUrl: url);
    if (mounted) setState(() {});
  }

  Future<void> _handleStopLive() async {
    if (_rtspService.isLive) {
      await _rtspService.stopPublish();
    }
    if (_whipService.isLive) {
      await _whipService.stopPublish();
    }
    if (mounted) setState(() {});
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      _showToast(
        appText(
          context,
          'Bộ nhớ tạm trống.',
          'Clipboard is empty.',
        ),
      );
      return;
    }

    setState(() {
      if (_platform == StreamPlatform.custom) {
        _customUrlController.text = text;
      } else {
        // Nếu user dán cả link rtmp
        if (text.startsWith('rtmp://') || text.startsWith('rtmps://')) {
          _detectPlatformAndParse(text);
        } else {
          _streamKeyController.text = text;
        }
      }
    });

    _showToast(
      appText(context, 'Đã dán thành công.', 'Pasted successfully.'),
    );
  }

  Future<void> _handleScanQrCode() async {
    if (_isLive) {
      _showToast(
        appText(
          context,
          'Vui lòng dừng phát trước khi quét mã mới.',
          'Please stop stream before scanning new QR code.',
        ),
        isError: true,
      );
      return;
    }

    try {
      await widget.runtime.pauseCameraForScanner();
      if (!mounted) return;
      final result = await QrStreamScannerDialog.show(context);
      if (result != null && mounted) {
        setState(() {
          _detectPlatformAndParse(result.streamUrl);
          if (result.token != null && result.token!.isNotEmpty) {
            _streamKeyController.text = result.token!;
          }
        });
        if (result.autoStart) {
          unawaited(_handleStartLive());
        }
      }
    } finally {
      await widget.runtime.resumeCameraAfterScanner();
    }
  }

  void _showToast(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.redAccent : const Color(0xFF1976D2),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final webRtc = widget.runtime.webRtcService;
    final resolution = webRtc?.resolutionProfile.shortLabel ?? '1080p';
    final fps = webRtc?.resolutionProfile.fps ?? 30;

    return Scaffold(
      backgroundColor: const Color(0xFF0F1218),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          appText(context, 'Phát trực tiếp', 'Live Streaming'),
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner_rounded, color: Colors.lightBlueAccent),
            tooltip: appText(context, 'Quét mã QR', 'Scan QR Code'),
            onPressed: _isLive ? null : _handleScanQrCode,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ========================================================
                    // 1. LIVE MONITOR (KHI ĐANG PHÁT)
                    // ========================================================
                    if (_isLive) ...[
                      _buildLiveMonitorCard(),
                      const SizedBox(height: 16),
                    ],

                    // ========================================================
                    // 2. CHỌN NỀN TẢNG (PLATFORM SELECTOR)
                    // ========================================================
                    if (!_isLive) ...[
                      _buildPlatformSelector(),
                      const SizedBox(height: 16),
                    ],

                    // ========================================================
                    // 3. KHUNG NHẬP THÔNG TIN (INPUT CARD)
                    // ========================================================
                    if (!_isLive) ...[
                      _buildInputCard(),
                      const SizedBox(height: 16),
                    ],

                    // ========================================================
                    // 4. NÚT ĐIỀU KHIỂN CHÍNH (ACTION BUTTON)
                    // ========================================================
                    _buildActionButton(),

                    const SizedBox(height: 16),

                    // ========================================================
                    // 5. THÔNG TIN NGUỒN CAMERA & CÀI ĐẶT NÂNG CAO
                    // ========================================================
                    Center(
                      child: Text(
                        '$resolution · ${fps}fps · H.264',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),

                    const SizedBox(height: 8),

                    Center(
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white60,
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () => setState(() => _showAdvanced = !_showAdvanced),
                        icon: Icon(
                          _showAdvanced ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                          size: 18,
                        ),
                        label: Text(
                          _showAdvanced
                              ? appText(context, 'Ẩn cài đặt nâng cao', 'Hide advanced')
                              : appText(context, 'Cài đặt nâng cao', 'Advanced settings'),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),

                    if (_showAdvanced) _buildAdvancedSection(),
                  ],
                ),
              ),
            ),
    );
  }

  // ============================================================
  // WIDGET: PLATFORM SELECTOR
  // ============================================================
  Widget _buildPlatformSelector() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          _buildPlatformItem(
            platform: StreamPlatform.youtube,
            title: 'YouTube',
            icon: Icons.play_arrow_rounded,
            color: const Color(0xFFFF0000),
          ),
          _buildPlatformItem(
            platform: StreamPlatform.facebook,
            title: 'Facebook',
            icon: Icons.facebook_rounded,
            color: const Color(0xFF1877F2),
          ),
          _buildPlatformItem(
            platform: StreamPlatform.tiktok,
            title: 'TikTok',
            icon: Icons.music_note_rounded,
            color: const Color(0xFFFE2C55),
          ),
          _buildPlatformItem(
            platform: StreamPlatform.custom,
            title: 'Tùy chỉnh',
            icon: Icons.tune_rounded,
            color: const Color(0xFF00E676),
          ),
        ],
      ),
    );
  }

  Widget _buildPlatformItem({
    required StreamPlatform platform,
    required String title,
    required IconData icon,
    required Color color,
  }) {
    final isSelected = _platform == platform;
    return Expanded(
      child: InkWell(
        onTap: _isLive
            ? null
            : () {
                setState(() => _platform = platform);
              },
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected ? color.withValues(alpha: 0.18) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? color.withValues(alpha: 0.7) : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 20,
                color: isSelected ? color : Colors.white60,
              ),
              const SizedBox(height: 4),
              Text(
                title,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.white60,
                  fontSize: 11,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // WIDGET: INPUT CARD
  // ============================================================
  Widget _buildInputCard() {
    String serverHint = '';
    String fieldLabel = appText(context, 'Khóa luồng (Stream Key)', 'Stream Key');

    switch (_platform) {
      case StreamPlatform.youtube:
        serverHint = 'rtmp://a.rtmp.youtube.com/live2';
        break;
      case StreamPlatform.facebook:
        serverHint = 'rtmps://live-api-s.facebook.com:443/rtmp/';
        break;
      case StreamPlatform.tiktok:
        serverHint = 'RTMP TikTok Live Studio';
        break;
      case StreamPlatform.custom:
        fieldLabel = appText(context, 'Đường dẫn RTMP / RTSP', 'RTMP / RTSP URL');
        break;
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (serverHint.isNotEmpty && _platform != StreamPlatform.custom) ...[
            Row(
              children: [
                Icon(Icons.dns_rounded, size: 14, color: Colors.white.withValues(alpha: 0.4)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    serverHint,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 11.5,
                      fontFamily: 'monospace',
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],

          if (_platform == StreamPlatform.tiktok) ...[
            Text(
              appText(context, 'Máy chủ (Server URL)', 'Server URL'),
              style: const TextStyle(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            TextFormField(
              controller: _tiktokServerController,
              enabled: !_isLive,
              style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'monospace'),
              decoration: _inputDecoration(hint: 'rtmp://live-push.tiktok.com/live'),
            ),
            const SizedBox(height: 12),
          ],

          Text(
            fieldLabel,
            style: const TextStyle(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),

          TextFormField(
            controller: _platform == StreamPlatform.custom ? _customUrlController : _streamKeyController,
            enabled: !_isLive,
            obscureText: _platform != StreamPlatform.custom && _obscureKey,
            style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'monospace'),
            decoration: _inputDecoration(
              hint: _platform == StreamPlatform.custom
                  ? 'rtmp://server.com/live/stream_key'
                  : 'xxxx-xxxx-xxxx-xxxx',
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_platform != StreamPlatform.custom)
                    IconButton(
                      icon: Icon(
                        _obscureKey ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                        size: 18,
                        color: Colors.white54,
                      ),
                      onPressed: () => setState(() => _obscureKey = !_obscureKey),
                    ),
                  IconButton(
                    icon: const Icon(Icons.content_paste_rounded, size: 18, color: Colors.amberAccent),
                    tooltip: appText(context, 'Dán', 'Paste'),
                    onPressed: _pasteFromClipboard,
                  ),
                  if (_platform == StreamPlatform.custom)
                    IconButton(
                      icon: const Icon(Icons.qr_code_scanner_rounded, size: 18, color: Colors.lightBlueAccent),
                      tooltip: appText(context, 'Quét QR', 'Scan QR'),
                      onPressed: _handleScanQrCode,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration({required String hint, Widget? suffixIcon}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.25), fontSize: 12),
      filled: true,
      fillColor: const Color(0xFF0F1218),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      suffixIcon: suffixIcon,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFF1976D2), width: 1.5),
      ),
    );
  }

  // ============================================================
  // WIDGET: LIVE MONITOR CARD (HIỂN THỊ KHI ĐANG PHÁT)
  // ============================================================
  Widget _buildLiveMonitorCard() {
    final duration = _rtspService.isLive ? _rtspService.liveDuration : _whipService.liveDuration;
    final fps = _rtspService.currentFps;
    final bitrate = _rtspService.currentBitrateKbps;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.6), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.red.withValues(alpha: 0.15),
            blurRadius: 16,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.redAccent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, color: Colors.white, size: 8),
                    SizedBox(width: 5),
                    Text(
                      'LIVE',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                _formatDuration(duration),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 22,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildMetricChip(
                label: 'FPS',
                value: fps > 0 ? fps.toStringAsFixed(0) : '30',
                color: Colors.lightBlueAccent,
              ),
              _buildMetricChip(
                label: 'Bitrate',
                value: bitrate > 0 ? '${(bitrate / 1000).toStringAsFixed(1)}M' : 'Auto',
                color: Colors.greenAccent,
              ),
              _buildMetricChip(
                label: 'Mạng',
                value: _rtspService.cellularFallbackActive ? '4G/5G' : 'Wi-Fi',
                color: Colors.amberAccent,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetricChip({required String label, required String value, required Color color}) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontSize: 14,
            fontFamily: 'monospace',
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.45),
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  // ============================================================
  // WIDGET: ACTION BUTTON
  // ============================================================
  Widget _buildActionButton() {
    if (_isLive || _rtspService.state == RtspPublishState.reconnecting) {
      return FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: Colors.redAccent.shade700,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onPressed: _handleStopLive,
        icon: const Icon(Icons.stop_circle_rounded, size: 20),
        label: Text(
          appText(context, 'DỪNG PHÁT TRỰC TIẾP', 'STOP STREAM'),
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 0.5),
        ),
      );
    }

    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      onPressed: _isBusy ? null : _handleStartLive,
      icon: _isBusy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            )
          : const Icon(Icons.cell_tower_rounded, size: 20),
      label: Text(
        _isBusy
            ? appText(context, 'ĐANG KẾT NỐI...', 'CONNECTING...')
            : appText(context, 'BẮT ĐẦU PHÁT TRỰC TIẾP', 'START LIVE STREAM'),
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 0.5),
      ),
    );
  }

  // ============================================================
  // WIDGET: ADVANCED SECTION
  // ============================================================
  Widget _buildAdvancedSection() {
    final lanIp = widget.runtime.lanAddress ?? '127.0.0.1';
    final localRtspUrl = 'rtsp://$lanIp:8554/camera';

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                appText(context, 'Link RTSP nội bộ (VLC / NVR):', 'Local RTSP Link:'),
                style: const TextStyle(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.bold),
              ),
              IconButton(
                icon: const Icon(Icons.copy_rounded, size: 16, color: Colors.lightBlueAccent),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: localRtspUrl));
                  _showToast(appText(context, 'Đã sao chép link RTSP!', 'Copied RTSP link!'));
                },
              ),
            ],
          ),
          SelectableText(
            localRtspUrl,
            style: const TextStyle(color: Color(0xFF81D4FA), fontSize: 11.5, fontFamily: 'monospace'),
          ),
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: widget.runtime.rtspTabletAudio,
            onChanged: (value) async {
              await widget.runtime.setRtspTabletAudio(value);
              if (mounted) setState(() {});
            },
            title: Text(
              appText(context, 'Âm thanh cho Tablet', 'Audio for Tablets'),
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
