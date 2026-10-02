import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_language_service.dart';
import '../services/camera_station_runtime.dart';
import '../services/station_config_service.dart';
import '../services/whip_publisher_service.dart';
import '../services/rtsp_publisher_service.dart';

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
  // Protocol: 'rtsp' (RTSP / RTMP Push) or 'whip' (WebRTC WHIP)
  String _selectedProtocol = 'rtsp';

  // RTSP Push Form Controllers
  final TextEditingController _rtspUrlController = TextEditingController();
  final TextEditingController _rtspServerController =
      TextEditingController(text: 'media.aqvision.net:18554');
  final TextEditingController _rtspAppController =
      TextEditingController(text: 'live');
  final TextEditingController _rtspStreamNameController =
      TextEditingController(text: 'camera_demo');
  final TextEditingController _rtspKeyController = TextEditingController();
  bool _useDetailedRtspBuilder = false;
  bool _obscureRtspKey = true;

  // WHIP Form Controllers
  final TextEditingController _whipUrlController = TextEditingController();
  final TextEditingController _whipTokenController = TextEditingController();
  bool _obscureWhipToken = true;

  final ScrollController _scrollController = ScrollController();
  StreamSubscription<WhipPublishState>? _whipSubscription;
  StreamSubscription<RtspPublishState>? _rtspSubscription;

  bool _isLoading = true;
  String? _selectedPreset;

  String? get _effectivePreset {
    if (_selectedPreset != null) return _selectedPreset;
    final url = _rtspUrlController.text.trim();
    if (url.startsWith('rtmp://') || url.startsWith('rtmps://')) return 'rtmp';
    if (url.startsWith('rtsp://') && url.contains('.sdp')) return 'rtsp_sdp';
    if (url.startsWith('rtsp://')) return 'rtsp_standard';
    return null;
  }

  WhipPublisherService get _whipService => widget.runtime.whipPublisherService;
  RtspPublisherService get _rtspService => widget.runtime.rtspPublisherService;

  bool get _isAnyLive => _whipService.isLive || _rtspService.isLive;

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
    final protocol = await widget.configService.loadStreamProtocol();
    final rtspUrl = await widget.configService.loadRtspPushUrl();
    final whipUrl = await widget.configService.loadWhipEndpointUrl();
    final whipToken = await widget.configService.loadWhipAuthToken();

    if (mounted) {
      setState(() {
        _selectedProtocol = protocol;
        _rtspUrlController.text = (rtspUrl?.isNotEmpty ?? false)
            ? rtspUrl!
            : 'rtmp://media.aqvision.net:11935/live/camera_demo?key=pk_b3f7da9c66b1044eb2ce57c7f40a7761';
        _whipUrlController.text = whipUrl ?? '';
        _whipTokenController.text = whipToken ?? '';
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _whipSubscription?.cancel();
    _rtspSubscription?.cancel();
    _rtspUrlController.dispose();
    _rtspServerController.dispose();
    _rtspAppController.dispose();
    _rtspStreamNameController.dispose();
    _rtspKeyController.dispose();
    _whipUrlController.dispose();
    _whipTokenController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  void _syncRtspBuilderToUrl() {
    final server = _rtspServerController.text.trim();
    final app = _rtspAppController.text.trim();
    final stream = _rtspStreamNameController.text.trim();
    final key = _rtspKeyController.text.trim();

    if (server.isEmpty || stream.isEmpty) return;

    final keyParam = key.isNotEmpty ? '?key=$key' : '';
    final full = 'rtsp://$server/$app/$stream$keyParam';
    setState(() {
      _rtspUrlController.text = full;
    });
  }

  // ============================================================
  // START / STOP RTSP PUSH
  // ============================================================

  Future<void> _handleStartRtspPush() async {
    final url = _rtspUrlController.text.trim();
    if (url.isEmpty) {
      _showToast(
        appText(
          context,
          'Vui lòng nhập hoặc chọn định dạng phát trực tiếp.',
          'Please enter or select a live stream link.',
        ),
        isError: true,
      );
      return;
    }

    await widget.configService.saveRtspPushConfig(targetUrl: url);
    await widget.configService.saveStreamProtocol('rtsp');

    if (!mounted) return;

    final webRtc = widget.runtime.webRtcService;
    if (webRtc == null || !webRtc.cameraInitialized) {
      _showToast(
        appText(
          context,
          'Camera đang khởi động, vui lòng thử lại sau vài giây.',
          'Camera is starting up, please try again in a few seconds.',
        ),
        isError: true,
      );
      return;
    }

    setState(() {});
    await _rtspService.startPublish(targetUrl: url);
    if (mounted) setState(() {});
  }

  Future<void> _handleStopRtspPush() async {
    await _rtspService.stopPublish();
    if (mounted) setState(() {});
  }

  void _handleSmartPasteOrInput(String input) {
    var text = input.trim();
    if (text.isEmpty) return;

    // Pattern 1: User pasted "cam1?key=pk_92383b0a29ee97c843c81ef22d88487e"
    if (text.contains('?key=') &&
        !text.startsWith('rtmp://') &&
        !text.startsWith('rtmps://') &&
        !text.startsWith('rtsp://')) {
      final formattedUrl = 'rtmp://media.aqvision.net:11935/live/$text';
      setState(() {
        _selectedPreset = 'rtmp';
        _rtspUrlController.text = formattedUrl;
        final parts = text.split('?key=');
        if (parts.isNotEmpty) _rtspStreamNameController.text = parts[0];
        if (parts.length > 1) _rtspKeyController.text = parts[1];
      });
      _showToast(appText(
        context,
        'Đã nhận diện và thiết lập đường dẫn phát trực tiếp.',
        'Recognized and configured stream link.',
      ));
      return;
    }

    // Pattern 2: User pasted full RTMP or RTSP url
    if (text.startsWith('rtmp://') ||
        text.startsWith('rtmps://') ||
        text.startsWith('rtsp://')) {
      final nameMatch = RegExp(r'/live/([^/?&\s]+)').firstMatch(text);
      final keyMatch = RegExp(r'[?&]key=([^&\s]+)').firstMatch(text);
      setState(() {
        _selectedPreset = null;
        _rtspUrlController.text = text;
        if (nameMatch != null) {
          _rtspStreamNameController.text =
              nameMatch.group(1)?.replaceAll('.sdp', '') ?? '';
        }
        if (keyMatch != null) _rtspKeyController.text = keyMatch.group(1) ?? '';
      });
      _showToast(appText(
        context,
        'Đã điền đường dẫn phát trực tiếp thành công.',
        'Applied live stream link.',
      ));
      return;
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      _showToast(appText(
        context,
        'Chưa có nội dung nào trong bộ nhớ tạm để dán.',
        'Clipboard is empty.',
      ));
      return;
    }
    _handleSmartPasteOrInput(text);
  }

  void _applyPreset(String presetType) {
    String currentKey = _rtspKeyController.text.trim();
    if (currentKey.isEmpty) {
      final currentUrl = _rtspUrlController.text.trim();
      final keyMatch = RegExp(r'[?&]key=([^&\s]+)').firstMatch(currentUrl);
      if (keyMatch != null) {
        currentKey = keyMatch.group(1) ?? '';
        _rtspKeyController.text = currentKey;
      }
    }
    if (currentKey.isEmpty) {
      currentKey = 'pk_b3f7da9c66b1044eb2ce57c7f40a7761';
      _rtspKeyController.text = currentKey;
    }

    String streamName =
        _rtspStreamNameController.text.trim().replaceAll('.sdp', '');
    if (streamName.isEmpty || streamName.contains('http') || streamName.contains('rtsp') || streamName.contains('/')) {
      final currentUrl = _rtspUrlController.text.trim();
      final lastSlashMatch = RegExp(r'/live/([^/?&\s]+)').allMatches(currentUrl);
      if (lastSlashMatch.isNotEmpty) {
        final last = lastSlashMatch.last.group(1)?.replaceAll('.sdp', '') ?? '';
        streamName = last.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '');
      }
      if (streamName.isEmpty || streamName.contains('http') || streamName.contains('rtsp')) {
        streamName = 'cam1';
      }
      _rtspStreamNameController.text = streamName;
    }
    final String cleanStreamName =
        streamName.isEmpty ? 'cam1' : streamName;

    String newUrl = '';
    if (presetType == 'rtmp') {
      newUrl =
          'rtmp://media.aqvision.net:11935/live/$cleanStreamName?key=$currentKey';
    } else if (presetType == 'rtsp_sdp') {
      newUrl =
          'rtsp://media.aqvision.net:18554/live/$cleanStreamName.sdp?key=$currentKey';
    } else {
      newUrl =
          'rtsp://media.aqvision.net:18554/live/$cleanStreamName?key=$currentKey';
    }

    setState(() {
      _selectedPreset = presetType;
      _rtspUrlController.text = newUrl;
    });
  }

  // ============================================================
  // START / STOP WHIP
  // ============================================================

  Future<void> _handleStartWhip() async {
    final url = _whipUrlController.text.trim();
    if (url.isEmpty) {
      _showToast(
        appText(
          context,
          'Vui lòng nhập địa chỉ phát trực tiếp WHIP.',
          'Please enter WHIP stream link.',
        ),
        isError: true,
      );
      return;
    }

    final token = _whipTokenController.text.trim();
    await widget.configService.saveWhipConfig(
      endpointUrl: url,
      token: token,
    );
    await widget.configService.saveStreamProtocol('whip');

    if (!mounted) return;

    final webRtc = widget.runtime.webRtcService;
    if (webRtc == null || !webRtc.cameraInitialized) {
      _showToast(
        appText(
          context,
          'Camera đang khởi động, vui lòng thử lại sau vài giây.',
          'Camera is starting up, please try again in a few seconds.',
        ),
        isError: true,
      );
      return;
    }

    setState(() {});
    await _whipService.startPublish(
      endpointUrl: url,
      webRtcService: webRtc,
      bearerToken: token,
    );
    if (mounted) setState(() {});
  }

  Future<void> _handleStopWhip() async {
    await _whipService.stopPublish();
    if (mounted) setState(() {});
  }

  void _showToast(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        backgroundColor:
            isError ? const Color(0xFFC62828) : const Color(0xFF1565C0),
        content: Row(
          children: [
            Icon(
              isError
                  ? Icons.error_outline_rounded
                  : Icons.check_circle_outline_rounded,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _copyToClipboard(String text, String successMsg) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Text(successMsg),
          ],
        ),
        backgroundColor: const Color(0xFF1E88E5),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ============================================================
  // STATUS CHIP
  // ============================================================

  Widget _buildStatusChip() {
    Color bg;
    Color fg;
    String label;
    IconData icon;

    if (_selectedProtocol == 'rtsp') {
      final state = _rtspService.state;
      switch (state) {
        case RtspPublishState.publishing:
          bg = Colors.red.shade900.withValues(alpha: 0.35);
          fg = Colors.redAccent.shade100;
          label = '🔴 RTSP LIVE (${_formatDuration(_rtspService.liveDuration)})';
          icon = Icons.radio_button_checked_rounded;
          break;
        case RtspPublishState.connecting:
          bg = Colors.amber.shade900.withValues(alpha: 0.35);
          fg = Colors.amberAccent;
          label = appText(context, 'Đang kết nối...', 'Connecting...');
          icon = Icons.sync_rounded;
          break;
        case RtspPublishState.reconnecting:
          bg = Colors.orange.shade900.withValues(alpha: 0.35);
          fg = Colors.orangeAccent;
          label = appText(context, 'Đang thử lại...', 'Reconnecting...');
          icon = Icons.replay_rounded;
          break;
        case RtspPublishState.error:
          bg = Colors.red.shade900.withValues(alpha: 0.25);
          fg = Colors.red.shade300;
          label = appText(context, 'Lỗi kết nối', 'Connection Error');
          icon = Icons.error_outline_rounded;
          break;
        case RtspPublishState.idle:
          bg = Colors.white.withValues(alpha: 0.08);
          fg = Colors.white70;
          label = appText(context, 'Chưa phát', 'Idle');
          icon = Icons.cloud_off_rounded;
          break;
      }
    } else {
      final state = _whipService.state;
      switch (state) {
        case WhipPublishState.publishing:
          bg = Colors.red.shade900.withValues(alpha: 0.35);
          fg = Colors.redAccent.shade100;
          label = '🔴 WHIP LIVE (${_formatDuration(_whipService.liveDuration)})';
          icon = Icons.radio_button_checked_rounded;
          break;
        case WhipPublishState.connecting:
          bg = Colors.amber.shade900.withValues(alpha: 0.35);
          fg = Colors.amberAccent;
          label = appText(context, 'Đang kết nối...', 'Connecting...');
          icon = Icons.sync_rounded;
          break;
        case WhipPublishState.reconnecting:
          bg = Colors.orange.shade900.withValues(alpha: 0.35);
          fg = Colors.orangeAccent;
          label = appText(context, 'Đang thử lại...', 'Reconnecting...');
          icon = Icons.replay_rounded;
          break;
        case WhipPublishState.error:
          bg = Colors.red.shade900.withValues(alpha: 0.25);
          fg = Colors.red.shade300;
          label = appText(context, 'Lỗi kết nối', 'Connection Error');
          icon = Icons.error_outline_rounded;
          break;
        case WhipPublishState.idle:
          bg = Colors.white.withValues(alpha: 0.08);
          fg = Colors.white70;
          label = appText(context, 'Chưa phát', 'Idle');
          icon = Icons.cloud_off_rounded;
          break;
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: fg.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontWeight: FontWeight.bold,
              fontSize: 12,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final webRtc = widget.runtime.webRtcService;
    final resolution = webRtc?.resolutionProfile.shortLabel ?? '1080p';
    final fps = webRtc?.resolutionProfile.fps ?? 30;
    final lanIp = widget.runtime.lanAddress ?? '127.0.0.1';
    final localRtspUrl = 'rtsp://$lanIp:8554/camera';

    final isRtspActive = _rtspService.isLive;
    final isRtspBusy = _rtspService.state == RtspPublishState.connecting;
    final isWhipActive = _whipService.isLive;
    final isWhipBusy = _whipService.state == WhipPublishState.connecting;

    return Scaffold(
      backgroundColor: const Color(0xFF0F1218),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          appText(context, 'Phát Trực Tiếp Lên Server', 'Live Stream Publisher'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: Center(child: _buildStatusChip()),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Protocol Selector Tabs
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF161B22),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.1),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: _ProtocolTab(
                              title: 'RTSP / RTMP ĐẨY',
                              icon: Icons.cell_tower_rounded,
                              isSelected: _selectedProtocol == 'rtsp',
                              isLive: isRtspActive,
                              onTap: _isAnyLive
                                  ? null
                                  : () {
                                      setState(() => _selectedProtocol = 'rtsp');
                                      widget.configService
                                          .saveStreamProtocol('rtsp');
                                    },
                            ),
                          ),
                          Expanded(
                            child: _ProtocolTab(
                              title: 'WebRTC WHIP',
                              icon: Icons.podcasts_rounded,
                              isSelected: _selectedProtocol == 'whip',
                              isLive: isWhipActive,
                              onTap: _isAnyLive
                                  ? null
                                  : () {
                                      setState(() => _selectedProtocol = 'whip');
                                      widget.configService
                                          .saveStreamProtocol('whip');
                                    },
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Camera Source Banner
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A212D),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: _isAnyLive
                                  ? Colors.red.withValues(alpha: 0.15)
                                  : Colors.blue.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              _isAnyLive
                                  ? Icons.radio_button_checked_rounded
                                  : Icons.videocam_rounded,
                              color: _isAnyLive
                                  ? Colors.redAccent
                                  : Colors.lightBlueAccent,
                              size: 24,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  appText(
                                    context,
                                    'Nguồn Camera Station',
                                    'Camera Station Source',
                                  ),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  'H.264 phần cứng · $resolution @ ${fps}fps · Bitstream Copy',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.7),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // ========================================================
                    // PROTOCOL CONTENT
                    // ========================================================

                    if (_selectedProtocol == 'rtsp') ...[
                      // RTSP PUSH FORM
                      _buildRtspPushSection(isRtspActive, isRtspBusy),
                    ] else ...[
                      // WHIP FORM
                      _buildWhipSection(isWhipActive, isWhipBusy),
                    ],

                    const SizedBox(height: 20),

                    // Local Camera RTSP Information Card
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF161B22),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.wifi_tethering_rounded,
                                      size: 16,
                                      color: Colors.white70,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        appText(
                                          context,
                                          'LINK RTSP NỘI BỘ (PULL TỪ ĐIỆN THOẠI)',
                                          'LOCAL RTSP FEED (PULL FROM PHONE)',
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 11.5,
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.copy_rounded,
                                  size: 16,
                                  color: Colors.lightBlueAccent,
                                ),
                                tooltip: 'Sao chép link RTSP nội bộ',
                                onPressed: () => _copyToClipboard(
                                  localRtspUrl,
                                  'Đã sao chép link RTSP nội bộ!',
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0F1218),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: SelectableText(
                                    localRtspUrl,
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      color: Color(0xFF81D4FA),
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            appText(
                              context,
                              'Dùng link này để kiểm tra nhanh trong mạng Wi-Fi bằng VLC Player hoặc NVR nội bộ.',
                              'Use this link for local LAN testing with VLC or local NVR.',
                            ),
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  // ============================================================
  // RTSP PUSH WIDGETS
  // ============================================================

  Widget _buildRtspPushSection(bool isLive, bool isBusy) {
    final webRtc = widget.runtime.webRtcService;
    final fps = webRtc?.resolutionProfile.fps ?? 30;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF161B22),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      appText(
                        context,
                        'CẤU HÌNH RTSP PUSH',
                        'RTSP PUSH CONFIG',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.bold,
                        fontSize: 11.5,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: isLive
                        ? null
                        : () {
                            setState(() {
                              _useDetailedRtspBuilder =
                                  !_useDetailedRtspBuilder;
                            });
                          },
                    icon: Icon(
                      _useDetailedRtspBuilder
                          ? Icons.text_fields_rounded
                          : Icons.tune_rounded,
                      size: 14,
                    ),
                    label: Text(
                      _useDetailedRtspBuilder
                          ? 'Dán URL trực tiếp'
                          : 'Nhập từng trường',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Quick Presets Row
              if (!isLive) ...[
                Text(
                  appText(
                    context,
                    'Định dạng đẩy nhanh:',
                    'Quick Presets:',
                  ),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.65),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _PresetChip(
                        label: 'RTMP (OBS / FLV)',
                        badge: appText(context, 'Khuyên Dùng', 'Recommended'),
                        badgeColor: Colors.greenAccent,
                        icon: Icons.flash_on_rounded,
                        isSelected: _effectivePreset == 'rtmp',
                        onTap: () => _applyPreset('rtmp'),
                      ),
                      const SizedBox(width: 8),
                      _PresetChip(
                        label: 'RTSP (.sdp)',
                        badge: 'Camera IP',
                        badgeColor: Colors.blueAccent,
                        icon: Icons.videocam_rounded,
                        isSelected: _effectivePreset == 'rtsp_sdp',
                        onTap: () => _applyPreset('rtsp_sdp'),
                      ),
                      const SizedBox(width: 8),
                      _PresetChip(
                        label: appText(context, 'RTSP Chuẩn', 'Standard RTSP'),
                        icon: Icons.stream_rounded,
                        isSelected: _effectivePreset == 'rtsp_standard',
                        onTap: () => _applyPreset('rtsp_standard'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],

              if (!_useDetailedRtspBuilder) ...[
                // Direct URL input with Smart Quick Paste
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        appText(
                          context,
                          'Đường dẫn đẩy (RTMP / RTSP) *',
                          'Publish URL (RTMP / RTSP) *',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (!isLive)
                      InkWell(
                        onTap: _pasteFromClipboard,
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.amberAccent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: Colors.amberAccent.withValues(alpha: 0.35),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.content_paste_rounded,
                                size: 13,
                                color: Colors.amberAccent,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                appText(
                                  context,
                                  'Dán Link',
                                  'Paste Link',
                                ),
                                style: const TextStyle(
                                  color: Colors.amberAccent,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                TextFormField(
                  controller: _rtspUrlController,
                  enabled: !isLive,
                  onChanged: (val) {
                    if (val.contains('?key=') &&
                        !val.startsWith('rtmp://') &&
                        !val.startsWith('rtsp://')) {
                      _handleSmartPasteOrInput(val);
                    }
                  },
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontFamily: 'monospace',
                  ),
                  decoration: InputDecoration(
                    hintText:
                        'rtmp://media.server.com:11935/live/cam1?key=YOUR_KEY',
                    hintStyle: TextStyle(
                      color: Colors.white.withValues(alpha: 0.3),
                    ),
                    filled: true,
                    fillColor: const Color(0xFF0F1218),
                    prefixIcon: const Icon(
                      Icons.link_rounded,
                      color: Colors.white54,
                      size: 18,
                    ),
                    suffixIcon: !isLive
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: appText(
                                  context,
                                  'Dán từ bộ nhớ tạm',
                                  'Paste from clipboard',
                                ),
                                icon: const Icon(
                                  Icons.content_paste_rounded,
                                  size: 16,
                                  color: Colors.amberAccent,
                                ),
                                onPressed: _pasteFromClipboard,
                              ),
                              if (_rtspUrlController.text.isNotEmpty)
                                IconButton(
                                  tooltip: appText(
                                    context,
                                    'Xóa đường dẫn',
                                    'Clear URL',
                                  ),
                                  icon: const Icon(
                                    Icons.clear_rounded,
                                    size: 16,
                                    color: Colors.white54,
                                  ),
                                  onPressed: () {
                                    setState(() => _rtspUrlController.clear());
                                  },
                                ),
                            ],
                          )
                        : null,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                        color: Colors.white.withValues(alpha: 0.15),
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(
                        color: Color(0xFF1976D2),
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF161B22),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.greenAccent.withValues(alpha: 0.25),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.verified_rounded,
                        color: Colors.greenAccent,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          appText(
                            context,
                            'Khuyên dùng RTMP: 1080p @ 3.5 Mbps cho mạng 4G mượt mà nhất.',
                            'Recommended RTMP: 1080p @ 3.5 Mbps for smooth 4G streaming.',
                          ),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                // Structured builder
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Máy chủ & Port',
                            style: TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                          const SizedBox(height: 4),
                          TextFormField(
                            controller: _rtspServerController,
                            enabled: !isLive,
                            onChanged: (_) => _syncRtspBuilderToUrl(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                            decoration: _buildInputDecoration(
                              'media.server.com:18554',
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'App',
                            style: TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                          const SizedBox(height: 4),
                          TextFormField(
                            controller: _rtspAppController,
                            enabled: !isLive,
                            onChanged: (_) => _syncRtspBuilderToUrl(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                            decoration: _buildInputDecoration('live'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Tên luồng (Stream Name)',
                            style: TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                          const SizedBox(height: 4),
                          TextFormField(
                            controller: _rtspStreamNameController,
                            enabled: !isLive,
                            onChanged: (_) => _syncRtspBuilderToUrl(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                            decoration: _buildInputDecoration('camera_demo'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Stream Key',
                            style: TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                          const SizedBox(height: 4),
                          TextFormField(
                            controller: _rtspKeyController,
                            enabled: !isLive,
                            obscureText: _obscureRtspKey,
                            onChanged: (_) => _syncRtspBuilderToUrl(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                            decoration: InputDecoration(
                              hintText: appText(
                                context,
                                'Nhập Stream Key',
                                'Enter Stream Key',
                              ),
                              hintStyle: TextStyle(
                                color: Colors.white.withValues(alpha: 0.3),
                              ),
                              filled: true,
                              fillColor: const Color(0xFF0F1218),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscureRtspKey
                                      ? Icons.visibility_rounded
                                      : Icons.visibility_off_rounded,
                                  size: 16,
                                  color: Colors.white54,
                                ),
                                onPressed: () {
                                  setState(() =>
                                      _obscureRtspKey = !_obscureRtspKey);
                                },
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 10,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.15),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'URL tổng hợp: ${_rtspUrlController.text}',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: Colors.lightBlueAccent.shade100,
                  ),
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Error Banner
        if (_rtspService.currentError != null)
          _buildErrorBox(_rtspService.currentError!),

        // Success / Live Feedback Box
        if (isLive)
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF1B5E20).withValues(alpha: 0.35),
                  const Color(0xFF0F1218),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Colors.greenAccent.withValues(alpha: 0.3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: const BoxDecoration(
                            color: Colors.greenAccent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          appText(
                            context,
                            'TRẠNG THÁI TRUYỀN TẢI THỜI GIAN THỰC',
                            'REALTIME STREAM HEALTH',
                          ),
                          style: const TextStyle(
                            color: Colors.greenAccent,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      _formatDuration(_rtspService.liveDuration),
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: _MetricTile(
                        title: 'TỐC ĐỘ KHUNG HÌNH',
                        value: _rtspService.currentFps > 0
                            ? '${_rtspService.currentFps.toStringAsFixed(1)} FPS'
                            : '$fps FPS',
                        icon: Icons.speed_rounded,
                        color: Colors.lightBlueAccent,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _MetricTile(
                        title: 'BĂNG THÔNG ĐẨY',
                        value: _rtspService.currentBitrateKbps > 0
                            ? '${(_rtspService.currentBitrateKbps).toStringAsFixed(0)} Kbps'
                            : '${(webRtc?.resolutionProfile.rtspBitrate ?? 3000000) ~/ 1000} Kbps',
                        icon: Icons.network_check_rounded,
                        color: Colors.greenAccent,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _MetricTile(
                        title: 'GIAO THỨC ĐẨY',
                        value: _rtspUrlController.text.toLowerCase().startsWith('rtmp')
                            ? 'RTMP (FLV)'
                            : 'RTSP (TCP)',
                        icon: Icons.alt_route_rounded,
                        color: Colors.amberAccent,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _MetricTile(
                        title: 'ĐỘ TRỄ TRUYỀN DẪN',
                        value: 'Low-Latency',
                        icon: Icons.bolt_rounded,
                        color: Colors.purpleAccent,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

        // Action Button
        if (isLive || _rtspService.state == RtspPublishState.reconnecting)
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.redAccent.shade700,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: _handleStopRtspPush,
            icon: const Icon(Icons.stop_circle_rounded, size: 22),
            label: Text(
              appText(context, 'DỪNG PHÁT TRỰC TIẾP', 'STOP LIVE STREAM'),
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          )
        else
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF1976D2),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: isBusy ? null : _handleStartRtspPush,
            icon: isBusy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.cell_tower_rounded, size: 22),
            label: Text(
              isBusy
                  ? appText(context, 'ĐANG KẾT NỐI...', 'CONNECTING...')
                  : appText(
                      context,
                      'BẮT ĐẦU ĐẨY LUỒNG RTSP',
                      'START RTSP PUSH',
                    ),
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ),
      ],
    );
  }

  // ============================================================
  // WHIP WIDGETS
  // ============================================================

  Widget _buildWhipSection(bool isLive, bool isBusy) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF161B22),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                appText(
                  context,
                  'CẤU HÌNH WEBRTC WHIP (RFC 9450)',
                  'WEBRTC WHIP CONFIG (RFC 9450)',
                ),
                style: const TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 12),

              // Endpoint URL
              Text(
                appText(context, 'WHIP Endpoint URL *', 'WHIP Endpoint URL *'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 6),
              TextFormField(
                controller: _whipUrlController,
                enabled: !isLive,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontFamily: 'monospace',
                ),
                decoration: InputDecoration(
                  hintText: 'http://192.168.1.111:8889/live/whip',
                  hintStyle: TextStyle(
                    color: Colors.white.withValues(alpha: 0.3),
                  ),
                  filled: true,
                  fillColor: const Color(0xFF0F1218),
                  prefixIcon: const Icon(
                    Icons.link_rounded,
                    color: Colors.white54,
                    size: 18,
                  ),
                  suffixIcon: !isLive
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: appText(
                                context,
                                'Dán từ bộ nhớ tạm',
                                'Paste from clipboard',
                              ),
                              icon: const Icon(
                                Icons.content_paste_rounded,
                                size: 16,
                                color: Colors.amberAccent,
                              ),
                              onPressed: () async {
                                final data = await Clipboard.getData(
                                  Clipboard.kTextPlain,
                                );
                                final text = data?.text?.trim() ?? '';
                                if (text.isNotEmpty && mounted) {
                                  setState(() => _whipUrlController.text = text);
                                }
                              },
                            ),
                            if (_whipUrlController.text.isNotEmpty)
                              IconButton(
                                tooltip: appText(
                                  context,
                                  'Xóa đường dẫn',
                                  'Clear URL',
                                ),
                                icon: const Icon(
                                  Icons.clear_rounded,
                                  size: 16,
                                  color: Colors.white54,
                                ),
                                onPressed: () {
                                  setState(() => _whipUrlController.clear());
                                },
                              ),
                          ],
                        )
                      : null,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(
                      color: Colors.white.withValues(alpha: 0.15),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 14),

              // Bearer Token
              Text(
                appText(
                  context,
                  'Bearer Auth Token (Tùy chọn)',
                  'Bearer Auth Token (Optional)',
                ),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 6),
              TextFormField(
                controller: _whipTokenController,
                enabled: !isLive,
                obscureText: _obscureWhipToken,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontFamily: 'monospace',
                ),
                decoration: InputDecoration(
                  hintText: 'Token bảo mật (nếu có)',
                  hintStyle: TextStyle(
                    color: Colors.white.withValues(alpha: 0.3),
                  ),
                  filled: true,
                  fillColor: const Color(0xFF0F1218),
                  prefixIcon: const Icon(
                    Icons.key_rounded,
                    color: Colors.white54,
                    size: 18,
                  ),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureWhipToken
                          ? Icons.visibility_rounded
                          : Icons.visibility_off_rounded,
                      size: 18,
                      color: Colors.white54,
                    ),
                    onPressed: () {
                      setState(() =>
                          _obscureWhipToken = !_obscureWhipToken);
                    },
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(
                      color: Colors.white.withValues(alpha: 0.15),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        if (_whipService.currentError != null)
          _buildErrorBox(_whipService.currentError!),

        if (isLive)
          Container(
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: const Color(0xFF12221B),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Colors.greenAccent.withValues(alpha: 0.3),
              ),
            ),
            child: Text(
              'Luồng WHIP đang phát trực tiếp với độ trễ < 0.5s.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8),
                fontSize: 12,
              ),
            ),
          ),

        if (isLive || _whipService.state == WhipPublishState.reconnecting)
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.redAccent.shade700,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: _handleStopWhip,
            icon: const Icon(Icons.stop_circle_rounded, size: 22),
            label: Text(
              appText(context, 'DỪNG PHÁT TRỰC TIẾP', 'STOP LIVE STREAM'),
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          )
        else
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF1976D2),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: isBusy ? null : _handleStartWhip,
            icon: isBusy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.podcasts_rounded, size: 22),
            label: Text(
              isBusy
                  ? appText(context, 'ĐANG KẾT NỐI...', 'CONNECTING...')
                  : appText(
                      context,
                      'BẮT ĐẦU PHÁT WEBRTC WHIP',
                      'START WHIP PUBLISH',
                    ),
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ),
      ],
    );
  }

  String _translateToNaturalLanguageError(String rawError) {
    final lower = rawError.toLowerCase();

    if (lower.contains('connection refused') ||
        lower.contains('failed to connect') ||
        lower.contains('timeout') ||
        lower.contains('timed out') ||
        lower.contains('host is down') ||
        lower.contains('unreachable') ||
        lower.contains('socketexception') ||
        lower.contains('errno = 110') ||
        lower.contains('errno = 111')) {
      return appText(
        context,
        'Không thể kết nối đến máy chủ phát sóng. Vui lòng kiểm tra lại kết nối mạng Wi-Fi hoặc 4G của điện thoại.',
        'Cannot connect to streaming server. Please check your phone Wi-Fi or 4G connection.',
      );
    }

    if (lower.contains('401') ||
        lower.contains('unauthorized') ||
        lower.contains('forbidden') ||
        lower.contains('invalid stream key') ||
        lower.contains('key invalid')) {
      return appText(
        context,
        'Mã Stream Key không chính xác hoặc đã hết hạn. Vui lòng kiểm tra lại mã luồng phát sóng.',
        'Stream key is invalid or expired. Please check your stream credentials.',
      );
    }

    if (lower.contains('404') ||
        lower.contains('not found') ||
        lower.contains('no such stream')) {
      return appText(
        context,
        'Không tìm thấy kênh phát sóng trên máy chủ. Vui lòng kiểm tra lại đường dẫn phát.',
        'Stream channel not found on server. Please check the URL.',
      );
    }

    if (lower.contains('camera') || lower.contains('not initialized')) {
      return appText(
        context,
        'Camera đang bận hoặc chưa sẵn sàng. Vui lòng thử lại sau vài giây.',
        'Camera is busy or not ready. Please try again in a few seconds.',
      );
    }

    if (lower.contains('broken pipe') ||
        lower.contains('connection reset') ||
        lower.contains('disconnect') ||
        lower.contains('end of file') ||
        lower.contains('eof')) {
      return appText(
        context,
        'Đường truyền mạng bị gián đoạn. Hệ thống đang tự động kết nối lại...',
        'Network stream disconnected. Attempting to reconnect...',
      );
    }

    if (lower.contains('ffmpeg') || lower.contains('exit code')) {
      return appText(
        context,
        'Quá trình phát sóng bị dừng do tín hiệu mạng không ổn định. Vui lòng nhấn phát lại.',
        'Streaming stopped due to unstable network. Please try starting again.',
      );
    }

    return rawError;
  }

  Widget _buildErrorBox(String error) {
    final friendlyMessage = _translateToNaturalLanguageError(error);

    return Container(
      padding: const EdgeInsets.all(14),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.red.shade900.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.redAccent.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: Colors.redAccent,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  appText(context, 'Thông báo sự cố:', 'Notice:'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  friendlyMessage,
                  style: const TextStyle(
                    color: Color(0xFFFF8A80),
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _buildInputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(
        color: Colors.white.withValues(alpha: 0.3),
        fontSize: 12,
      ),
      filled: true,
      fillColor: const Color(0xFF0F1218),
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(
          color: Colors.white.withValues(alpha: 0.15),
        ),
      ),
    );
  }
}

class _ProtocolTab extends StatelessWidget {
  final String title;
  final IconData icon;
  final bool isSelected;
  final bool isLive;
  final VoidCallback? onTap;

  const _ProtocolTab({
    required this.title,
    required this.icon,
    required this.isSelected,
    required this.isLive,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF1976D2).withValues(alpha: 0.25)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: isSelected
              ? Border.all(color: const Color(0xFF1976D2).withValues(alpha: 0.8))
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 16,
              color: isLive
                  ? Colors.redAccent
                  : isSelected
                      ? const Color(0xFF64B5F6)
                      : Colors.white54,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.white60,
                  fontWeight:
                      isSelected ? FontWeight.bold : FontWeight.normal,
                  fontSize: 11.5,
                ),
              ),
            ),
            if (isLive) ...[
              const SizedBox(width: 4),
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: Colors.redAccent,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  final String label;
  final String? badge;
  final Color? badgeColor;
  final IconData icon;
  final VoidCallback onTap;
  final bool isSelected;

  const _PresetChip({
    required this.label,
    this.badge,
    this.badgeColor,
    required this.icon,
    required this.onTap,
    this.isSelected = false,
  });

  @override
  Widget build(BuildContext context) {
    const activeColor = Color(0xFF1565C0);
    const activeBorderColor = Color(0xFF64B5F6);

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? activeColor : const Color(0xFF1E2633),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected
                  ? activeBorderColor
                  : Colors.white.withValues(alpha: 0.12),
              width: isSelected ? 1.5 : 1,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: activeColor.withValues(alpha: 0.4),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isSelected ? Icons.check_circle_rounded : icon,
                size: 14,
                color: isSelected ? Colors.white : Colors.lightBlueAccent,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                  fontSize: 11.5,
                ),
              ),
              if (badge != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? Colors.white.withValues(alpha: 0.25)
                        : (badgeColor ?? Colors.blue).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isSelected
                          ? Colors.white.withValues(alpha: 0.5)
                          : (badgeColor ?? Colors.blue).withValues(alpha: 0.5),
                      width: 0.8,
                    ),
                  ),
                  child: Text(
                    badge!,
                    style: TextStyle(
                      color: isSelected
                          ? Colors.white
                          : (badgeColor ?? Colors.blueAccent),
                      fontSize: 9.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  const _MetricTile({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 12, color: color),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 12.5,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}
