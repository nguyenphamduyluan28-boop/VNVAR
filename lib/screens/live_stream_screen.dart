import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_language_service.dart';
import '../services/camera_station_runtime.dart';
import '../services/station_config_service.dart';
import '../services/whip_publisher_service.dart';
import '../services/rtsp_publisher_service.dart';
import '../services/scoreboard_service.dart';
import '../utils/stream_url_parser.dart';
import '../widgets/qr_stream_scanner_dialog.dart';

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
  final TextEditingController _serverController = TextEditingController();

  // WHIP (Advanced)
  final TextEditingController _whipUrlController = TextEditingController();
  final TextEditingController _whipTokenController = TextEditingController();

  bool _obscureKey = true;
  bool _obscureWhipToken = true;
  bool _showAdvanced = false;
  bool _isLoading = true;
  bool _editServer = false;
  bool _actionInFlight = false;

  StreamSubscription<WhipPublishState>? _whipSubscription;
  StreamSubscription<RtspPublishState>? _rtspSubscription;

  WhipPublisherService get _whipService => widget.runtime.whipPublisherService;
  RtspPublisherService get _rtspService => widget.runtime.rtspPublisherService;

  bool get _isLive => _rtspService.isLive || _whipService.isLive;

  // "Active" gồm cả connecting/reconnecting — dùng cho loại trừ RTMP/WHIP,
  // vì publisher đang tự kết nối lại vẫn sẽ phát tiếp khi mạng về.
  bool get _isRtspActive =>
      _rtspService.state != RtspPublishState.idle &&
      _rtspService.state != RtspPublishState.error;
  bool get _isWhipActive =>
      _whipService.wantsPublishing ||
      (_whipService.state != WhipPublishState.idle &&
          _whipService.state != WhipPublishState.error);
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
    String? rtspUrl;
    String? whipUrl;
    String? whipToken;
    var partialFailure = false;

    try {
      try {
        rtspUrl = await widget.configService.loadRtspPushUrl();
      } catch (e) {
        debugPrint('[LIVESTREAM] Failed to load RTSP push URL: $e');
        partialFailure = true;
      }
      try {
        whipUrl = await widget.configService.loadWhipEndpointUrl();
      } catch (e) {
        debugPrint('[LIVESTREAM] Failed to load WHIP endpoint: $e');
        partialFailure = true;
      }
      try {
        whipToken = await widget.configService.loadWhipAuthToken();
      } catch (e) {
        debugPrint('[LIVESTREAM] Failed to load WHIP token: $e');
        partialFailure = true;
      }

      if (mounted) {
        setState(() {
          _whipUrlController.text = whipUrl ?? '';
          _whipTokenController.text = whipToken ?? '';

          if (rtspUrl != null && rtspUrl.isNotEmpty) {
            _detectPlatformAndParse(rtspUrl);
          } else {
            _platform = StreamPlatform.youtube;
            _serverController.text =
                kDefaultServers[StreamPlatform.youtube] ?? '';
          }
        });
        if (partialFailure) {
          _showToast(
            appText(
              context,
              'Không nạp được một phần cấu hình livestream.',
              'Some stream settings could not be loaded.',
            ),
            isError: true,
          );
        }
      }
    } catch (e, st) {
      debugPrint('[LIVESTREAM] Initial config load error: $e\n$st');
      if (mounted) {
        _showToast(
          appText(
            context,
            'Lỗi nạp cấu hình livestream.',
            'Failed to load stream config.',
          ),
          isError: true,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _detectPlatformAndParse(String url) {
    _customUrlController.text = url;
    final parsed = parseStreamUrl(url);
    _platform = parsed.platform;
    _serverController.text = parsed.server.isNotEmpty
        ? parsed.server
        : (kDefaultServers[parsed.platform] ?? '');
    if (parsed.platform == StreamPlatform.custom) {
      _streamKeyController.clear();
    } else {
      _streamKeyController.text = parsed.key;
    }
  }

  @override
  void dispose() {
    _whipSubscription?.cancel();
    _rtspSubscription?.cancel();
    _streamKeyController.dispose();
    _customUrlController.dispose();
    _serverController.dispose();
    _whipUrlController.dispose();
    _whipTokenController.dispose();
    super.dispose();
  }

  String _buildEffectiveUrl() {
    if (_platform == StreamPlatform.custom) {
      return _customUrlController.text.trim();
    }
    return buildStreamUrl(_serverController.text, _streamKeyController.text);
  }

  Future<void> _handleStartLive() async {
    if (_actionInFlight || _isBusy) return;

    if (_isWhipActive) {
      _showToast(
        appText(
          context,
          'Đang phát trực tiếp qua WHIP. Vui lòng dừng WHIP trước.',
          'Currently live via WHIP. Please stop WHIP first.',
        ),
        isError: true,
      );
      return;
    }

    if (_platform == StreamPlatform.tiktok &&
        _serverController.text.trim().isEmpty) {
      _showToast(
        appText(
          context,
          'Vui lòng nhập Server URL của TikTok.',
          'Please enter TikTok Server URL.',
        ),
        isError: true,
      );
      return;
    }

    final url = _buildEffectiveUrl();
    if (url.isEmpty ||
        (_platform != StreamPlatform.custom &&
            _streamKeyController.text.trim().isEmpty)) {
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

    final lowerUrl = url.toLowerCase();
    if (!lowerUrl.startsWith('rtmp://') &&
        !lowerUrl.startsWith('rtmps://') &&
        !lowerUrl.startsWith('rtsp://')) {
      _showToast(
        appText(
          context,
          'URL phải bắt đầu bằng rtmp://, rtmps:// hoặc rtsp://.',
          'URL must start with rtmp://, rtmps:// or rtsp://.',
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

    _actionInFlight = true;
    setState(() {});
    try {
      await widget.configService.saveRtspPushConfig(targetUrl: url);
      await widget.configService.saveStreamProtocol('rtsp');
      await _rtspService.startPublish(targetUrl: url);
    } catch (e) {
      if (mounted) {
        _showToast(
          appText(context, 'Lỗi bắt đầu phát: $e', 'Failed to start stream: $e'),
          isError: true,
        );
      }
    } finally {
      _actionInFlight = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _handleStopLive() async {
    if (_actionInFlight) return;
    _actionInFlight = true;
    setState(() {});
    try {
      if (_rtspService.state != RtspPublishState.idle &&
          _rtspService.state != RtspPublishState.error) {
        await _rtspService.stopPublish();
      }
      if (_whipService.wantsPublishing ||
          (_whipService.state != WhipPublishState.idle &&
              _whipService.state != WhipPublishState.error)) {
        await _whipService.stopPublish();
      }
    } catch (e) {
      if (mounted) {
        _showToast(
          appText(context, 'Lỗi dừng phát: $e', 'Stop publish error: $e'),
          isError: true,
        );
      }
    } finally {
      _actionInFlight = false;
      if (mounted) setState(() {});
    }
  }

  // ============================================================
  // START / STOP WHIP
  // ============================================================

  Future<void> _handleStartWhip() async {
    if (_actionInFlight || _isBusy) return;

    if (_isRtspActive) {
      _showToast(
        appText(
          context,
          'Đang phát trực tiếp qua RTMP/RTSP. Vui lòng dừng phát trước.',
          'Currently live via RTMP/RTSP. Please stop streaming first.',
        ),
        isError: true,
      );
      return;
    }

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

    _actionInFlight = true;
    setState(() {});
    try {
      await widget.configService.saveWhipConfig(endpointUrl: url, token: token);
      await widget.configService.saveStreamProtocol('whip');

      await _whipService.startPublish(
        endpointUrl: url,
        webRtcService: webRtc,
        bearerToken: token,
      );
    } catch (e) {
      if (mounted) {
        _showToast(
          appText(context, 'Lỗi phát WHIP: $e', 'WHIP publish error: $e'),
          isError: true,
        );
      }
    } finally {
      _actionInFlight = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _handleStopWhip() async {
    if (_actionInFlight) return;
    _actionInFlight = true;
    setState(() {});
    try {
      await _whipService.stopPublish();
    } catch (e) {
      if (mounted) {
        _showToast(
          appText(context, 'Lỗi dừng WHIP: $e', 'Stop WHIP error: $e'),
          isError: true,
        );
      }
    } finally {
      _actionInFlight = false;
      if (mounted) setState(() {});
    }
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
        if (text.startsWith('rtmp://') ||
            text.startsWith('rtmps://') ||
            text.startsWith('rtsp://')) {
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
    if (_actionInFlight) return;
    if (_isRtspActive || _isWhipActive) {
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

    _actionInFlight = true;
    bool shouldAutoStart = false;
    bool isWhip = false;
    String? destination;
    try {
      await widget.runtime.pauseCameraForScanner();
      if (!mounted) return;
      final result = await QrStreamScannerDialog.show(context);
      if (result != null && mounted) {
        isWhip = result.protocol == 'whip';
        shouldAutoStart = result.autoStart;
        destination = isWhip
            ? result.streamUrl
            : mergeStreamUrlWithKey(result.streamUrl, result.token);
        setState(() {
          if (isWhip) {
            _whipUrlController.text = result.streamUrl;
            if (result.token != null && result.token!.isNotEmpty) {
              _whipTokenController.text = result.token!;
            }
            _showAdvanced = true;
          } else {
            _detectPlatformAndParse(
              mergeStreamUrlWithKey(result.streamUrl, result.token),
            );
          }
        });
      }
    } catch (e) {
      if (mounted) {
        _showToast(
          appText(context, 'Lỗi quét QR: $e', 'QR scan error: $e'),
          isError: true,
        );
      }
    } finally {
      await widget.runtime.resumeCameraAfterScanner();
      _actionInFlight = false;
      if (mounted) setState(() {});
    }

    // Tự phát ngay với nền tảng quen thuộc/máy chủ nội bộ như trước; máy chủ lạ
    // phải được xác nhận để QR lạ không âm thầm phát camera + mic ra ngoài.
    final target = destination;
    if (shouldAutoStart &&
        mounted &&
        target != null &&
        !isTrustedAutoStartDestination(target)) {
      shouldAutoStart = await _confirmUnknownDestination(target);
    }

    if (shouldAutoStart && mounted) {
      if (isWhip) {
        await _handleStartWhip();
      } else {
        await _handleStartLive();
      }
    }
  }

  Future<bool> _confirmUnknownDestination(String url) async {
    final host = Uri.tryParse(url.trim())?.host ?? '';
    final shown = host.isEmpty ? url : host;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          appText(dialogContext, 'Phát tới máy chủ lạ?', 'Stream to an unknown server?'),
        ),
        content: Text(
          appText(
            dialogContext,
            'Mã QR yêu cầu phát camera và micro tới "$shown". '
                'Chỉ tiếp tục nếu bạn tin tưởng máy chủ này.',
            'The QR code asks to stream the camera and microphone to "$shown". '
                'Continue only if you trust this server.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(appText(dialogContext, 'Hủy', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(appText(dialogContext, 'Phát', 'Stream')),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  void _showToast(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
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

    final statusBanner = _buildStatusBanner();

    return Scaffold(
      backgroundColor: const Color(0xFF0F1218),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: Colors.white,
            size: 20,
          ),
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
            icon: const Icon(
              Icons.qr_code_scanner_rounded,
              color: Colors.lightBlueAccent,
            ),
            tooltip: appText(context, 'Quét mã QR', 'Scan QR Code'),
            onPressed: (_isRtspActive || _isWhipActive || _actionInFlight)
                ? null
                : _handleScanQrCode,
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
                    // 4. BANNER TRẠNG THÁI / LỖI
                    // ========================================================
                    if (statusBanner != null) ...[
                      statusBanner,
                      const SizedBox(height: 8),
                    ],

                    // ========================================================
                    // 5. NÚT ĐIỀU KHIỂN CHÍNH (ACTION BUTTON)
                    // ========================================================
                    _buildActionButton(),

                    const SizedBox(height: 16),

                    // ========================================================
                    // 6. THÔNG TIN NGUỒN CAMERA & CÀI ĐẶT NÂNG CAO
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
                        onPressed: () =>
                            setState(() => _showAdvanced = !_showAdvanced),
                        icon: Icon(
                          _showAdvanced
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: 18,
                        ),
                        label: Text(
                          _showAdvanced
                              ? appText(
                                  context,
                                  'Ẩn cài đặt nâng cao',
                                  'Hide advanced',
                                )
                              : appText(
                                  context,
                                  'Cài đặt nâng cao',
                                  'Advanced settings',
                                ),
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
  // WIDGET: STATUS BANNER
  // ============================================================
  Widget? _buildStatusBanner() {
    final rtspError = _rtspService.state == RtspPublishState.error
        ? _rtspService.currentError
        : null;
    final whipError = _whipService.state == WhipPublishState.error
        ? _whipService.currentError
        : null;
    final err = rtspError ?? whipError;
    final isReconnecting =
        _rtspService.state == RtspPublishState.reconnecting ||
        _whipService.state == WhipPublishState.reconnecting;

    if (err != null && err.isNotEmpty) {
      return Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF3E1A1A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.redAccent.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: Colors.redAccent,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                err,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: (_isBusy || _actionInFlight)
                  ? null
                  : (_rtspService.state == RtspPublishState.error
                      ? _handleStartLive
                      : _handleStartWhip),
              child: Text(
                appText(context, 'Thử lại', 'Retry'),
                style: const TextStyle(
                  color: Colors.lightBlueAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (isReconnecting) {
      return Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF332A15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.amber,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                appText(
                  context,
                  'Mất kết nối, đang thử lại…',
                  'Connection lost, reconnecting…',
                ),
                style: const TextStyle(color: Colors.amberAccent, fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }

    return null;
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
            title: appText(context, 'Tùy chỉnh', 'Custom'),
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
        onTap: (_isLive || _actionInFlight)
            ? null
            : () {
                setState(() {
                  final oldDefault = kDefaultServers[_platform] ?? '';
                  final currentServer = _serverController.text.trim();
                  _platform = platform;
                  _editServer = false;
                  final newDefault = kDefaultServers[platform] ?? '';
                  if (currentServer.isEmpty || currentServer == oldDefault) {
                    _serverController.text = newDefault;
                  }
                });
              },
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected
                ? color.withValues(alpha: 0.18)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected
                  ? color.withValues(alpha: 0.7)
                  : Colors.transparent,
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
    String fieldLabel = appText(
      context,
      'Khóa luồng (Stream Key)',
      'Stream Key',
    );
    if (_platform == StreamPlatform.custom) {
      fieldLabel = appText(
        context,
        'Đường dẫn RTMP / RTSP',
        'RTMP / RTSP URL',
      );
    }

    final defaultServer = kDefaultServers[_platform] ?? '';
    final isCustomOrTiktok =
        _platform == StreamPlatform.tiktok ||
        _platform == StreamPlatform.custom;

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
          // TikTok Server Input
          if (_platform == StreamPlatform.tiktok) ...[
            Text(
              appText(context, 'Máy chủ (Server URL)', 'Server URL'),
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11.5,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            TextFormField(
              controller: _serverController,
              enabled: !_isLive,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontFamily: 'monospace',
              ),
              decoration: _inputDecoration(
                hint: appText(
                  context,
                  'Dán Server URL từ TikTok LIVE Studio',
                  'Paste Server URL from TikTok LIVE Studio',
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],

          // YouTube / Facebook Server display or edit
          if (!isCustomOrTiktok) ...[
            if (_editServer) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    appText(context, 'Máy chủ (Server URL)', 'Server URL'),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _serverController.text = defaultServer;
                        _editServer = false;
                      });
                    },
                    child: Text(
                      appText(context, 'Đặt lại mặc định', 'Reset default'),
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              TextFormField(
                controller: _serverController,
                enabled: !_isLive,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontFamily: 'monospace',
                ),
                decoration: _inputDecoration(hint: defaultServer),
              ),
              const SizedBox(height: 12),
            ] else ...[
              Row(
                children: [
                  Icon(
                    Icons.dns_rounded,
                    size: 14,
                    color: Colors.white.withValues(alpha: 0.4),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _serverController.text.isNotEmpty
                          ? _serverController.text
                          : defaultServer,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.edit_rounded,
                      size: 14,
                      color: Colors.white54,
                    ),
                    tooltip: appText(
                      context,
                      'Chỉnh sửa máy chủ',
                      'Edit server',
                    ),
                    onPressed: _isLive
                        ? null
                        : () => setState(() => _editServer = true),
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],
          ],

          Text(
            fieldLabel,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11.5,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),

          TextFormField(
            controller: _platform == StreamPlatform.custom
                ? _customUrlController
                : _streamKeyController,
            enabled: !_isLive,
            obscureText: _platform != StreamPlatform.custom && _obscureKey,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontFamily: 'monospace',
            ),
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
                        _obscureKey
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                        size: 18,
                        color: Colors.white54,
                      ),
                      onPressed: () =>
                          setState(() => _obscureKey = !_obscureKey),
                    ),
                  IconButton(
                    icon: const Icon(
                      Icons.content_paste_rounded,
                      size: 18,
                      color: Colors.amberAccent,
                    ),
                    tooltip: appText(context, 'Dán', 'Paste'),
                    onPressed: _pasteFromClipboard,
                  ),
                  if (_platform == StreamPlatform.custom)
                    IconButton(
                      icon: const Icon(
                        Icons.qr_code_scanner_rounded,
                        size: 18,
                        color: Colors.lightBlueAccent,
                      ),
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
      hintStyle: TextStyle(
        color: Colors.white.withValues(alpha: 0.25),
        fontSize: 12,
      ),
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
    final isWhip = _whipService.isLive;
    final duration =
        isWhip ? _whipService.liveDuration : _rtspService.liveDuration;
    final fps = isWhip ? 0.0 : _rtspService.currentFps;
    final bitrate = isWhip ? 0 : _rtspService.currentBitrateKbps;

    final fpsStr = fps > 0 ? fps.toStringAsFixed(0) : '—';
    final bitrateStr =
        bitrate > 0 ? '${(bitrate / 1000).toStringAsFixed(1)}M' : '—';
    final networkStr = isWhip
        ? 'WebRTC'
        : (_rtspService.cellularFallbackActive ? '4G/5G' : 'Wi-Fi');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Colors.redAccent.withValues(alpha: 0.6),
          width: 1.5,
        ),
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
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
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
                value: fpsStr,
                color: Colors.lightBlueAccent,
              ),
              _buildMetricChip(
                label: appText(context, 'Bitrate', 'Bitrate'),
                value: bitrateStr,
                color: Colors.greenAccent,
              ),
              _buildMetricChip(
                label: appText(context, 'Mạng', 'Network'),
                value: networkStr,
                color: Colors.amberAccent,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.scoreboard_rounded,
                size: 16,
                color: !isWhip && _rtspService.overlayActive
                    ? Colors.amberAccent
                    : Colors.white38,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  _scoreboardStatus(isWhip),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Trạng thái in bảng tỉ số vào video livestream.
  String _scoreboardStatus(bool isWhip) {
    if (isWhip) {
      return appText(
        context,
        'Phát WHIP không in được bảng tỉ số (dùng RTMP/RTSP hoặc OBS).',
        'WHIP cannot show the scoreboard (use RTMP/RTSP or OBS).',
      );
    }
    if (!Platform.isAndroid) {
      return appText(
        context,
        'iPhone chưa hỗ trợ in bảng tỉ số vào livestream (dùng OBS).',
        'iPhone cannot burn the scoreboard into the livestream yet (use OBS).',
      );
    }
    if (_rtspService.overlayIssue != null) {
      return appText(
        context,
        'Máy này không in được bảng tỉ số vào livestream; đang phát không có bảng tỉ số.',
        'This phone cannot burn the scoreboard into the livestream; streaming without it.',
      );
    }
    final overlay = ScoreboardService.instance.snapshot()['overlay'];
    if (_rtspService.overlayActive) {
      if (overlay is Map && overlay['visible'] == false) {
        return appText(
          context,
          'Overlay đang ẩn (bật lại trên trang điều khiển → Overlay)',
          'Overlay is hidden (show it again on the control page → Overlay)',
        );
      }
      return appText(
        context,
        'Bảng tỉ số đang hiện trên livestream',
        'Scoreboard is shown on the livestream',
      );
    }
    final enabled = overlay is Map && overlay['burnIn'] != false;
    if (enabled) {
      return appText(
        context,
        'Đang chuẩn bị bảng tỉ số cho livestream…',
        'Preparing the scoreboard for the livestream…',
      );
    }
    return appText(
      context,
      'Bảng tỉ số đang tắt trên livestream (bật trên trang điều khiển → Overlay)',
      'Scoreboard is off on the livestream (turn it on on the control page → Overlay)',
    );
  }

  Widget _buildMetricChip({
    required String label,
    required String value,
    required Color color,
  }) {
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
    if (_isRtspActive) {
      return FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: Colors.redAccent.shade700,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        onPressed: _actionInFlight ? null : _handleStopLive,
        icon: const Icon(Icons.stop_circle_rounded, size: 20),
        label: Text(
          appText(context, 'DỪNG PHÁT TRỰC TIẾP', 'STOP STREAM'),
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
      );
    }

    if (_isWhipActive) {
      return FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: Colors.white12,
          foregroundColor: Colors.white38,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        onPressed: null,
        icon: const Icon(Icons.block_rounded, size: 20),
        label: Text(
          appText(context, 'ĐANG PHÁT QUA WHIP', 'STREAMING VIA WHIP'),
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
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
      onPressed: (_isBusy || _actionInFlight) ? null : _handleStartLive,
      icon: (_isBusy || _actionInFlight)
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.cell_tower_rounded, size: 20),
      label: Text(
        (_isBusy || _actionInFlight)
            ? appText(context, 'ĐANG KẾT NỐI...', 'CONNECTING...')
            : appText(context, 'BẮT ĐẦU PHÁT TRỰC TIẾP', 'START LIVE STREAM'),
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  // ============================================================
  // WIDGET: ADVANCED SECTION
  // ============================================================
  Widget _buildAdvancedSection() {
    final lanIp = widget.runtime.lanAddress ?? '127.0.0.1';
    final localRtspUrl = 'rtsp://$lanIp:8554/camera';
    final isWhipActive = _isWhipActive;
    final isWhipBusy = _whipService.state == WhipPublishState.connecting;
    final canStartWhip = !_isRtspActive && !_isBusy && !_actionInFlight;

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
                appText(
                  context,
                  'Link RTSP nội bộ (VLC / NVR):',
                  'Local RTSP Link:',
                ),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.copy_rounded,
                  size: 16,
                  color: Colors.lightBlueAccent,
                ),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: localRtspUrl));
                  _showToast(
                    appText(
                      context,
                      'Đã sao chép link RTSP!',
                      'Copied RTSP link!',
                    ),
                  );
                },
              ),
            ],
          ),
          SelectableText(
            localRtspUrl,
            style: const TextStyle(
              color: Color(0xFF81D4FA),
              fontSize: 11.5,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: widget.runtime.rtspTabletAudio,
            onChanged: (value) async {
              try {
                await widget.runtime.setRtspTabletAudio(value);
              } catch (error) {
                if (!mounted) return;
                _showToast(
                  appText(
                    context,
                    'Không đổi được âm thanh cho Tablet: $error',
                    'Unable to change tablet audio: $error',
                  ),
                  isError: true,
                );
              }
              if (mounted) setState(() {});
            },
            title: Text(
              appText(context, 'Âm thanh cho Tablet', 'Audio for Tablets'),
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
          const Divider(color: Colors.white12, height: 20),

          // WHIP Section
          Text(
            appText(
              context,
              'WHIP (Máy chủ nội bộ MediaMTX):',
              'WHIP (Internal MediaMTX server):',
            ),
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11.5,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _whipUrlController,
            enabled: !isWhipActive,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12.5,
              fontFamily: 'monospace',
            ),
            decoration: _inputDecoration(
              hint: 'http://server:8889/live/whip',
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _whipTokenController,
            enabled: !isWhipActive,
            obscureText: _obscureWhipToken,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12.5,
              fontFamily: 'monospace',
            ),
            decoration: _inputDecoration(
              hint: appText(
                context,
                'Bearer Token (tùy chọn)',
                'Bearer Token (optional)',
              ),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureWhipToken
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                  size: 18,
                  color: Colors.white54,
                ),
                onPressed: () =>
                    setState(() => _obscureWhipToken = !_obscureWhipToken),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: isWhipActive
                    ? Colors.redAccent.shade700
                    : const Color(0xFF00897B),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 11),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: isWhipActive
                  ? (_actionInFlight ? null : _handleStopWhip)
                  : (canStartWhip ? _handleStartWhip : null),
              icon: isWhipBusy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      isWhipActive
                          ? Icons.stop_rounded
                          : Icons.podcasts_rounded,
                      size: 18,
                    ),
              label: Text(
                isWhipActive
                    ? appText(context, 'DỪNG WHIP', 'STOP WHIP')
                    : isWhipBusy
                        ? appText(
                            context,
                            'ĐANG KẾT NỐI WHIP...',
                            'CONNECTING WHIP...',
                          )
                        : appText(context, 'PHÁT WHIP', 'START WHIP'),
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
