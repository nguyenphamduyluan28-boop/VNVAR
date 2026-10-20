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

/// Cách quét mã QR: bằng camera (phải tạm dừng camera trạm) hoặc từ ảnh.
enum _QrScanSource { camera, gallery }

/// Logo và màu nhận diện của từng nền tảng (ảnh trong assets/images).
class _PlatformMeta {
  const _PlatformMeta({
    required this.name,
    required this.icon,
    required this.color,
    this.asset,
    this.fillLogo = false,
  });

  /// null = tên theo ngôn ngữ (ô "Tùy chỉnh").
  final String? name;
  final String? asset;
  final IconData icon;
  final Color color;

  /// Logo dạng ảnh vuông có nền (SportO): bo góc, phủ kín ô.
  final bool fillLogo;
}

const Map<StreamPlatform, _PlatformMeta> _platformMeta = {
  StreamPlatform.sporto: _PlatformMeta(
    name: 'SportO',
    asset: 'assets/images/sporto.jpg',
    icon: Icons.sports_tennis_rounded,
    color: Color(0xFFFF6D00),
    fillLogo: true,
  ),
  StreamPlatform.facebook: _PlatformMeta(
    name: 'Facebook',
    asset: 'assets/images/logo_facebook.png',
    icon: Icons.facebook_rounded,
    color: Color(0xFF1877F2),
  ),
  StreamPlatform.youtube: _PlatformMeta(
    name: 'YouTube',
    asset: 'assets/images/logo_youtube.png',
    icon: Icons.play_arrow_rounded,
    color: Color(0xFFFF0000),
  ),
  StreamPlatform.tiktok: _PlatformMeta(
    name: 'TikTok',
    asset: 'assets/images/logo_tiktok.png',
    icon: Icons.music_note_rounded,
    color: Color(0xFFFE2C55),
  ),
  StreamPlatform.obs: _PlatformMeta(
    name: 'OBS',
    asset: 'assets/images/logo_obs.png',
    icon: Icons.desktop_windows_rounded,
    color: Color(0xFF90CAF9),
  ),
  StreamPlatform.custom: _PlatformMeta(
    name: null,
    icon: Icons.tune_rounded,
    color: Color(0xFF00E676),
  ),
};

const List<StreamPlatform> _platformOrder = [
  StreamPlatform.sporto,
  StreamPlatform.facebook,
  StreamPlatform.youtube,
  StreamPlatform.tiktok,
  StreamPlatform.obs,
  StreamPlatform.custom,
];

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
  StreamPlatform _platform = StreamPlatform.sporto;

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
  bool _showObsGuide = false;
  bool _isLoading = true;
  bool _editServer = false;
  bool _actionInFlight = false;
  bool _stopInFlight = false;
  // Tăng mỗi lần bấm Dừng: lệnh phát đang chờ (vd WHIP đang kết nối, có thể
  // tới ~50 giây) biết mình đã bị huỷ, không khoá nút và không báo lỗi thừa.
  int _actionGeneration = 0;

  // Trạng thái đã dựng UI lần trước: sự kiện mỗi giây (thời lượng/số liệu)
  // không làm dựng lại cả màn hình, phần số liệu dùng ListenableBuilder.
  RtspPublishState? _seenRtspState;
  String? _seenRtspError;
  WhipPublishState? _seenWhipState;
  String? _seenWhipError;
  bool? _seenWhipWants;
  // WHIP đã từng phát trong lượt này: sau đó mọi trạng thái chưa phát
  // (kết nối lại / camera đổi cấu hình) hiện nút DỪNG giống RTMP, chỉ lần kết
  // nối đầu tiên mới hiện "ĐANG KẾT NỐI · HỦY".
  bool _whipWasLive = false;

  StreamSubscription<WhipPublishState>? _whipSubscription;
  StreamSubscription<RtspPublishState>? _rtspSubscription;

  WhipPublisherService get _whipService => widget.runtime.whipPublisherService;
  RtspPublisherService get _rtspService => widget.runtime.rtspPublisherService;

  bool get _isLive => _rtspService.isLive || _whipService.isLive;

  String get _localRtspUrl =>
      'rtsp://${widget.runtime.lanAddress ?? '127.0.0.1'}:8554/camera';

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

  /// Đang phát / đang kết nối / đang kết nối lại / đang xử lý lệnh: khoá việc
  /// đổi nền tảng, máy chủ, khoá luồng (vẫn hiện để người dùng thấy đang phát
  /// gì).
  bool get _streamActive => _isRtspActive || _isWhipActive || _actionInFlight;

  bool get _english => AppLanguageScope.of(context).isEnglish;

  @override
  void initState() {
    super.initState();
    _loadInitialConfig();
    _updateWhipWasLive();

    _whipSubscription = _whipService.onStateChanged.listen(
      (_) => _onPublisherChanged(),
    );

    _rtspSubscription = _rtspService.onStateChanged.listen(
      (_) => _onPublisherChanged(),
    );
  }

  void _updateWhipWasLive() {
    if (_whipService.isLive ||
        _whipService.state == WhipPublishState.reconnecting) {
      _whipWasLive = true;
    } else if (!_isWhipActive) {
      _whipWasLive = false;
    }
  }

  void _onPublisherChanged() {
    if (!mounted) return;
    // Cờ chỉ đổi cùng lúc với trạng thái WHIP nên lần dựng lại dưới đây
    // (do trạng thái đổi) sẽ phản ánh nó.
    _updateWhipWasLive();
    final changed = _seenRtspState != _rtspService.state ||
        _seenRtspError != _rtspService.currentError ||
        _seenWhipState != _whipService.state ||
        _seenWhipError != _whipService.currentError ||
        _seenWhipWants != _whipService.wantsPublishing;
    if (!changed) return;
    setState(() {
      _seenRtspState = _rtspService.state;
      _seenRtspError = _rtspService.currentError;
      _seenWhipState = _whipService.state;
      _seenWhipError = _whipService.currentError;
      _seenWhipWants = _whipService.wantsPublishing;
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
            _platform = StreamPlatform.sporto;
            _serverController.text =
                kDefaultServers[StreamPlatform.sporto] ?? '';
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

    if (_platform == StreamPlatform.obs) {
      Clipboard.setData(ClipboardData(text: _localRtspUrl));
      _showToast(
        appText(
          context,
          '📋 Đã sao chép link RTSP cho OBS!',
          '📋 Copied RTSP link for OBS!',
        ),
      );
      return;
    }

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

    final generation = ++_actionGeneration;
    _actionInFlight = true;
    setState(() {});
    try {
      await widget.configService.saveRtspPushConfig(targetUrl: url);
      await widget.configService.saveStreamProtocol('rtsp');
      // Người dùng đã bấm Dừng trong lúc lưu cấu hình: không phát nữa.
      if (generation != _actionGeneration) return;
      await _rtspService.startPublish(targetUrl: url);
    } catch (e) {
      if (mounted && generation == _actionGeneration) {
        _showToast(
          appText(context, 'Lỗi bắt đầu phát: $e', 'Failed to start stream: $e'),
          isError: true,
        );
      }
    } finally {
      if (generation == _actionGeneration) _actionInFlight = false;
      if (mounted) setState(() {});
    }
  }

  /// Huỷ lệnh phát đang chờ (nếu có). Nút Dừng luôn bấm được, kể cả khi
  /// publisher còn đang kết nối.
  void _cancelPendingStart() {
    _actionGeneration++;
    _actionInFlight = false;
  }

  Future<void> _handleStopLive() async {
    if (_stopInFlight) return;
    _stopInFlight = true;
    _cancelPendingStart();
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
      _stopInFlight = false;
      if (mounted) setState(() {});
    }
  }

  /// Nút Dừng: đang phát thật thì hỏi lại (tránh bấm nhầm cắt livestream);
  /// đang kết nối / kết nối lại thì dừng ngay.
  Future<void> _requestStop({required bool whip}) async {
    if (_stopInFlight) return;
    if (_isLive) {
      final confirmed = await _confirmStop();
      if (!confirmed || !mounted) return;
      // Luồng có thể đã tự dừng (lỗi / nơi khác dừng) trong lúc hộp thoại mở.
      if (whip ? !_isWhipActive : !_isRtspActive) return;
    }
    if (whip) {
      await _handleStopWhip();
    } else {
      await _handleStopLive();
    }
  }

  Future<bool> _confirmStop() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          appText(
            dialogContext,
            'Dừng phát trực tiếp?',
            'Stop the live stream?',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(appText(dialogContext, 'Hủy', 'Cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.redAccent.shade700,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(appText(dialogContext, 'Dừng', 'Stop')),
          ),
        ],
      ),
    );
    return confirmed == true;
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

    final generation = ++_actionGeneration;
    _actionInFlight = true;
    setState(() {});
    try {
      await widget.configService.saveWhipConfig(endpointUrl: url, token: token);
      await widget.configService.saveStreamProtocol('whip');
      // Người dùng đã bấm Dừng trong lúc lưu cấu hình: không phát nữa.
      if (generation != _actionGeneration) return;

      // WHIP có thể mất tới ~50 giây để kết nối (SDP + ICE). Nút Dừng vẫn
      // bấm được: stopPublish() tăng generation của publisher nên lần kết
      // nối đang chạy tự huỷ an toàn.
      await _whipService.startPublish(
        endpointUrl: url,
        webRtcService: webRtc,
        bearerToken: token,
      );
    } catch (e) {
      if (mounted && generation == _actionGeneration) {
        _showToast(
          appText(context, 'Lỗi phát WHIP: $e', 'WHIP publish error: $e'),
          isError: true,
        );
      }
    } finally {
      if (generation == _actionGeneration) _actionInFlight = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _handleStopWhip() async {
    if (_stopInFlight) return;
    _stopInFlight = true;
    _cancelPendingStart();
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
      _stopInFlight = false;
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

    final source = await _chooseQrScanSource();
    if (source == null || !mounted || _actionInFlight) return;

    _actionInFlight = true;
    setState(() {});
    final pauseStationCamera = source == _QrScanSource.camera;
    bool shouldAutoStart = false;
    bool isWhip = false;
    String? destination;
    String? whipToken;
    try {
      QrStreamParseResult? result;
      if (pauseStationCamera) {
        // Quét bằng camera: camera trạm phải nhường phần cứng cho máy quét.
        await widget.runtime.pauseCameraForScanner();
        if (!mounted) return;
        result = await QrStreamScannerDialog.show(context);
      } else {
        // Quét từ ảnh: không đụng tới camera trạm (vẫn ghi hình / phát Tablet).
        result = await QrStreamScannerDialog.scanFromGallery(context);
      }
      if (result != null && mounted) {
        final scanned = result;
        isWhip = scanned.protocol == 'whip';
        shouldAutoStart = scanned.autoStart;
        whipToken = scanned.token;
        destination = isWhip
            ? scanned.streamUrl
            : mergeStreamUrlWithKey(scanned.streamUrl, scanned.token);
        setState(() {
          if (isWhip) {
            _whipUrlController.text = scanned.streamUrl;
            final token = scanned.token;
            if (token != null && token.isNotEmpty) {
              _whipTokenController.text = token;
            }
            _showAdvanced = true;
          } else {
            _detectPlatformAndParse(
              mergeStreamUrlWithKey(scanned.streamUrl, scanned.token),
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
      if (pauseStationCamera) {
        await widget.runtime.resumeCameraAfterScanner();
      }
      _actionInFlight = false;
      if (mounted) setState(() {});
    }

    // Chỉ tự phát ngay với máy chủ đối tác/máy chủ nội bộ. Nền tảng công cộng
    // (YouTube/Facebook/TikTok…) và máy chủ lạ phải được xác nhận: QR dán đè
    // có thể chứa stream key kênh người khác, hoặc âm thầm phát camera + mic
    // ra ngoài.
    final target = destination;
    if (shouldAutoStart &&
        mounted &&
        target != null &&
        !isTrustedAutoStartDestination(target)) {
      shouldAutoStart = await _confirmStreamDestination(
        target,
        secret: isWhip ? whipToken : null,
      );
    }

    if (shouldAutoStart && mounted) {
      if (isWhip) {
        await _handleStartWhip();
      } else {
        await _handleStartLive();
      }
    }
  }

  /// Quét bằng camera phải tạm dừng camera trạm (cắt ghi hình, ngắt Tablet).
  /// Khi trạm đang ghi hoặc có Tablet đang xem thì hỏi trước, kèm lựa chọn
  /// quét từ ảnh không ảnh hưởng camera trạm. Trả về null nếu huỷ.
  Future<_QrScanSource?> _chooseQrScanSource() async {
    final recording = widget.runtime.recordingService?.recording == true;
    final peers = widget.runtime.webRtcService?.activePeerCount ?? 0;
    if (!recording && peers == 0) return _QrScanSource.camera;

    final busyVi = [
      if (recording) 'đang ghi hình',
      if (peers > 0) 'có $peers Tablet đang xem',
    ].join(' và ');
    final busyEn = [
      if (recording) 'recording',
      if (peers > 0) 'streaming to $peers tablet(s)',
    ].join(' and ');

    return showDialog<_QrScanSource>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          appText(
            dialogContext,
            'Quét QR sẽ tạm dừng camera trạm',
            'Scanning will pause the station camera',
          ),
        ),
        content: Text(
          appText(
            dialogContext,
            'Trạm $busyVi. Quét bằng camera sẽ CẮT TẠM việc ghi hình và '
                'ngắt kết nối Tablet cho tới khi quét xong.\n\n'
                'Chọn "Quét từ ảnh" (ảnh chụp mã QR) để camera trạm vẫn chạy '
                'bình thường.',
            'The station is $busyEn. Scanning with the camera will '
                'temporarily CUT the recording and disconnect tablets until '
                'scanning finishes.\n\n'
                'Choose "Scan from photo" (a picture of the QR code) to keep '
                'the station camera running.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(appText(dialogContext, 'Hủy', 'Cancel')),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _QrScanSource.gallery),
            child: Text(appText(dialogContext, 'Quét từ ảnh', 'Scan from photo')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, _QrScanSource.camera),
            child: Text(
              appText(dialogContext, 'Quét bằng camera', 'Scan with camera'),
            ),
          ),
        ],
      ),
    );
  }

  /// Hỏi người dùng trước khi tự phát tới [url] lấy từ mã QR. Hiển thị nền
  /// tảng, máy chủ và 4 ký tự đầu của khoá (phần còn lại bị che) để người
  /// dùng nhận ra kênh có phải của mình không.
  Future<bool> _confirmStreamDestination(String url, {String? secret}) async {
    final kind = classifyStreamDestination(url);
    final host = Uri.tryParse(url.trim())?.host ?? '';
    final label = streamDestinationLabel(url);
    final maskedKey = (secret != null && secret.trim().isNotEmpty)
        ? maskStreamSecret(secret)
        : maskedStreamKeyOf(url);
    final isPublic = kind == StreamDestinationKind.publicPlatform;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final shownHost =
            host.isEmpty ? appText(dialogContext, '(không rõ)', '(unknown)') : host;
        final details = <String>[
          if (label.isNotEmpty)
            appText(dialogContext, 'Nền tảng: $label', 'Platform: $label'),
          appText(dialogContext, 'Máy chủ: $shownHost', 'Server: $shownHost'),
          if (maskedKey.isNotEmpty)
            appText(dialogContext, 'Khóa luồng: $maskedKey', 'Stream key: $maskedKey'),
        ].join('\n');
        final intro = isPublic
            ? appText(
                dialogContext,
                'Mã QR yêu cầu phát camera và micro lên một kênh $label. '
                    'Kênh này có thể KHÔNG phải của bạn (mã QR có thể bị dán '
                    'đè) — hãy kiểm tra khóa luồng trước khi phát.',
                'The QR code asks to stream the camera and microphone to a '
                    '$label channel. It may NOT be your channel (the QR code '
                    'could have been replaced) — check the stream key first.',
              )
            : appText(
                dialogContext,
                'Mã QR yêu cầu phát camera và micro tới "$shownHost". '
                    'Chỉ tiếp tục nếu bạn tin tưởng máy chủ này.',
                'The QR code asks to stream the camera and microphone to '
                    '"$shownHost". Continue only if you trust this server.',
              );
        return AlertDialog(
          title: Text(
            isPublic
                ? appText(
                    dialogContext,
                    'Phát lên kênh $label?',
                    'Stream to this $label channel?',
                  )
                : appText(
                    dialogContext,
                    'Phát tới máy chủ lạ?',
                    'Stream to an unknown server?',
                  ),
          ),
          content: Text('$intro\n\n$details'),
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
        );
      },
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
          tooltip: appText(context, 'Quay lại', 'Back'),
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
            onPressed: _streamActive ? null : _handleScanQrCode,
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
                    // 1. Đang phát: chỉ thẻ số liệu dựng lại mỗi giây.
                    if (_isLive) ...[
                      ListenableBuilder(
                        listenable: Listenable.merge([
                          _rtspService.durationListenable,
                          _rtspService.metricsListenable,
                          _whipService.durationListenable,
                        ]),
                        builder: (context, _) => _buildLiveMonitorCard(),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // 2. Chọn nền tảng bằng logo + 3. nhập khoá / link OBS.
                    // Đang kết nối / kết nối lại: vẫn hiện (mờ, khoá) để
                    // người dùng thấy đang phát tới đâu.
                    if (!_isLive) ...[
                      AnimatedOpacity(
                        duration: const Duration(milliseconds: 150),
                        opacity: _streamActive ? 0.5 : 1.0,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildPlatformSelector(),
                            const SizedBox(height: 14),
                            if (_platform == StreamPlatform.obs)
                              _buildObsInteractionCard()
                            else
                              _buildInputCard(),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // 4. Trạng thái / lỗi.
                    if (statusBanner != null) ...[
                      statusBanner,
                      const SizedBox(height: 8),
                    ],

                    // 5. Nút chính.
                    _buildActionButton(),

                    const SizedBox(height: 14),

                    // 6. Nguồn camera + cài đặt nâng cao (thu gọn).
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.videocam_rounded,
                          size: 15,
                          color: Colors.white.withValues(alpha: 0.4),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '$resolution · ${fps}fps',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.45),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          tooltip: _showAdvanced
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
                          icon: Icon(
                            _showAdvanced
                                ? Icons.expand_less_rounded
                                : Icons.settings_rounded,
                            size: 20,
                            color: Colors.white54,
                          ),
                          onPressed: () =>
                              setState(() => _showAdvanced = !_showAdvanced),
                        ),
                      ],
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
    final english = _english;
    final rtspError = _rtspService.state == RtspPublishState.error
        ? _rtspService.localizedError(english: english)
        : null;
    final whipError = _whipService.state == WhipPublishState.error
        ? _whipService.localizedError(english: english)
        : null;
    final err = rtspError ?? whipError;
    final isReconnecting =
        _rtspService.state == RtspPublishState.reconnecting ||
        _whipService.state == WhipPublishState.reconnecting;
    // Lý do mất kết nối (vd sai mạng, server không phản hồi) hiển thị cả khi
    // đang tự kết nối lại, không chỉ khi đã dừng hẳn ở trạng thái lỗi.
    final reconnectReason = _rtspService.state == RtspPublishState.reconnecting
        ? _rtspService.localizedError(english: english)
        : (_whipService.state == WhipPublishState.reconnecting
            ? _whipService.localizedError(english: english)
            : null);

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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    appText(
                      context,
                      'Mất kết nối, đang thử lại…',
                      'Connection lost, reconnecting…',
                    ),
                    style: const TextStyle(
                      color: Colors.amberAccent,
                      fontSize: 12,
                    ),
                  ),
                  if (reconnectReason != null &&
                      reconnectReason.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      reconnectReason,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    }

    return null;
  }

  /// Logo nền tảng từ assets/images; thiếu ảnh thì dùng icon dự phòng.
  Widget _platformLogo(StreamPlatform platform, {required double size}) {
    final meta = _platformMeta[platform]!;
    final fallback = Icon(meta.icon, size: size * 0.8, color: meta.color);
    final asset = meta.asset;
    Widget logo = fallback;
    if (asset != null) {
      final image = Image.asset(
        asset,
        width: size,
        height: size,
        fit: meta.fillLogo ? BoxFit.cover : BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => fallback,
      );
      logo = meta.fillLogo
          ? ClipRRect(
              borderRadius: BorderRadius.circular(size * 0.22),
              child: image,
            )
          : image;
    }
    return SizedBox(width: size, height: size, child: Center(child: logo));
  }

  void _selectPlatform(StreamPlatform platform) {
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
  }

  // ============================================================
  // WIDGET: CHỌN NỀN TẢNG — lưới ô logo lớn (3 cột, máy rộng 6 cột)
  // ============================================================
  Widget _buildPlatformSelector() {
    final locked = _streamActive;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 560 ? 6 : 3;
        const spacing = 10.0;
        final tileWidth =
            ((constraints.maxWidth - spacing * (columns - 1)) / columns)
                .floorToDouble();
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final platform in _platformOrder)
              SizedBox(
                width: tileWidth,
                child: _buildPlatformTile(platform, locked: locked),
              ),
          ],
        );
      },
    );
  }

  Widget _buildPlatformTile(StreamPlatform platform, {required bool locked}) {
    final meta = _platformMeta[platform]!;
    final selected = _platform == platform;
    final name = meta.name ?? appText(context, 'Tùy chỉnh', 'Custom');
    return Semantics(
      button: true,
      selected: selected,
      enabled: !locked,
      child: Material(
        color: selected
            ? meta.color.withValues(alpha: 0.14)
            : const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: locked ? null : () => _selectPlatform(platform),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 92,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected
                    ? meta.color
                    : Colors.white.withValues(alpha: 0.08),
                width: selected ? 2 : 1,
              ),
            ),
            child: Stack(
              children: [
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _platformLogo(platform, size: 40),
                      const SizedBox(height: 8),
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? Colors.white : Colors.white60,
                          fontSize: 12,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                if (selected)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Icon(
                      Icons.check_circle_rounded,
                      size: 18,
                      color: meta.color,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // WIDGET: OBS — chỉ link RTSP; hướng dẫn thu gọn sau nút "?"
  // ============================================================
  Widget _buildObsInteractionCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFF90CAF9).withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _platformLogo(StreamPlatform.obs, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: SelectableText(
                  _localRtspUrl,
                  style: const TextStyle(
                    color: Color(0xFF81D4FA),
                    fontSize: 13.5,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: appText(context, 'Hướng dẫn', 'How to'),
                icon: Icon(
                  _showObsGuide
                      ? Icons.help_rounded
                      : Icons.help_outline_rounded,
                  color: Colors.white54,
                ),
                onPressed: () =>
                    setState(() => _showObsGuide = !_showObsGuide),
              ),
            ],
          ),
          if (_showObsGuide) ...[
            const SizedBox(height: 12),
            _buildObsStep('1', 'Sources → + → Media Source'),
            const SizedBox(height: 6),
            _buildObsStep(
              '2',
              appText(
                context,
                'Bỏ "Local File", dán link vào "Input"',
                'Uncheck "Local File", paste into "Input"',
              ),
            ),
            const SizedBox(height: 6),
            _buildObsStep('3', 'Network Buffering: 0–1 MB'),
          ],
        ],
      ),
    );
  }

  Widget _buildObsStep(String step, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: Colors.lightBlueAccent.withValues(alpha: 0.15),
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.lightBlueAccent.withValues(alpha: 0.4),
            ),
          ),
          child: Center(
            child: Text(
              step,
              style: const TextStyle(
                color: Colors.lightBlueAccent,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.75),
              fontSize: 11.5,
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }

  // ============================================================
  // WIDGET: NHẬP KHOÁ — một ô nhập + 2 nút lớn Dán / QR
  // ============================================================
  Widget _buildInputCard() {
    final isCustom = _platform == StreamPlatform.custom;
    final isTiktok = _platform == StreamPlatform.tiktok;
    final defaultServer = kDefaultServers[_platform] ?? '';
    final locked = _streamActive;
    const monoStyle = TextStyle(
      color: Colors.white,
      fontSize: 13,
      fontFamily: 'monospace',
    );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // TikTok bắt buộc nhập Server URL (mỗi phiên một server khác).
          if (isTiktok) ...[
            TextFormField(
              controller: _serverController,
              enabled: !locked,
              style: monoStyle,
              decoration: _inputDecoration(
                hint: 'Server URL',
                prefixIcon: Icons.dns_rounded,
              ),
            ),
            const SizedBox(height: 10),
          ] else if (!isCustom) ...[
            if (_editServer) ...[
              TextFormField(
                controller: _serverController,
                enabled: !locked,
                style: monoStyle.copyWith(fontSize: 12.5),
                decoration: _inputDecoration(
                  hint: defaultServer,
                  prefixIcon: Icons.dns_rounded,
                  suffixIcon: IconButton(
                    icon: const Icon(
                      Icons.restart_alt_rounded,
                      size: 18,
                      color: Colors.white54,
                    ),
                    tooltip: appText(
                      context,
                      'Đặt lại mặc định',
                      'Reset default',
                    ),
                    onPressed: locked
                        ? null
                        : () => setState(() {
                              _serverController.text = defaultServer;
                              _editServer = false;
                            }),
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ] else ...[
              // Server mặc định: chỉ hiện mờ, bấm bút để sửa.
              Row(
                children: [
                  Icon(
                    Icons.dns_rounded,
                    size: 14,
                    color: Colors.white.withValues(alpha: 0.35),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _serverController.text.isNotEmpty
                          ? _serverController.text
                          : defaultServer,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.edit_rounded,
                      size: 16,
                      color: Colors.white54,
                    ),
                    tooltip: appText(
                      context,
                      'Chỉnh sửa máy chủ',
                      'Edit server',
                    ),
                    onPressed: locked
                        ? null
                        : () => setState(() => _editServer = true),
                  ),
                ],
              ),
              const SizedBox(height: 4),
            ],
          ],

          TextFormField(
            controller: isCustom ? _customUrlController : _streamKeyController,
            enabled: !locked,
            // URL tùy chỉnh cũng chứa stream key: che như ô khóa luồng.
            obscureText: _obscureKey,
            style: monoStyle,
            decoration: _inputDecoration(
              hint: isCustom ? 'rtmp://server/live/key' : 'Stream Key',
              prefixIcon: isCustom ? Icons.link_rounded : Icons.key_rounded,
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureKey
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                  size: 18,
                  color: Colors.white54,
                ),
                tooltip: _obscureKey
                    ? appText(context, 'Hiện', 'Show')
                    : appText(context, 'Ẩn', 'Hide'),
                onPressed: () => setState(() => _obscureKey = !_obscureKey),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _buildQuickButton(
                  icon: Icons.content_paste_rounded,
                  label: appText(context, 'Dán', 'Paste'),
                  color: Colors.amberAccent,
                  onPressed: locked ? null : _pasteFromClipboard,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildQuickButton(
                  icon: Icons.qr_code_scanner_rounded,
                  label: 'QR',
                  color: Colors.lightBlueAccent,
                  onPressed: locked ? null : _handleScanQrCode,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQuickButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      height: 48,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: BorderSide(
            color: color.withValues(alpha: onPressed == null ? 0.15 : 0.45),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 20),
        label: Text(label),
      ),
    );
  }

  InputDecoration _inputDecoration({
    required String hint,
    Widget? suffixIcon,
    IconData? prefixIcon,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(
        color: Colors.white.withValues(alpha: 0.25),
        fontSize: 12.5,
      ),
      filled: true,
      fillColor: const Color(0xFF0F1218),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      prefixIcon: prefixIcon == null
          ? null
          : Icon(prefixIcon, size: 18, color: Colors.white38),
      suffixIcon: suffixIcon,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF1976D2), width: 1.5),
      ),
    );
  }

  // ============================================================
  // WIDGET: THẺ ĐANG PHÁT — logo, LIVE, đồng hồ lớn, số liệu bằng icon
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
    final cellular = !isWhip && _rtspService.cellularFallbackActive;
    final networkStr = isWhip ? 'WebRTC' : (cellular ? '4G/5G' : 'Wi-Fi');
    final networkIcon = isWhip
        ? Icons.podcasts_rounded
        : (cellular ? Icons.signal_cellular_alt_rounded : Icons.wifi_rounded);
    final scoreboard = _scoreboardShortStatus(isWhip);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(16),
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
              if (!isWhip) ...[
                _platformLogo(_platform, size: 32),
                const SizedBox(width: 12),
              ],
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
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
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Máy hẹp / chữ lớn: thu nhỏ đồng hồ thay vì tràn ngang.
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    _formatDuration(duration),
                    maxLines: 1,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 28,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 4 ô chia đều; ô quá chật (máy hẹp / chữ lớn) tự thu nhỏ.
          Row(
            children: [
              _metricCell(
                _buildMetricChip(
                  icon: Icons.speed_rounded,
                  value: fpsStr,
                  tooltip: 'FPS',
                  color: Colors.lightBlueAccent,
                ),
              ),
              _metricCell(
                _buildMetricChip(
                  icon: Icons.upload_rounded,
                  value: bitrateStr,
                  tooltip: 'Bitrate',
                  color: Colors.greenAccent,
                ),
              ),
              _metricCell(
                _buildMetricChip(
                  icon: networkIcon,
                  value: networkStr,
                  tooltip: appText(context, 'Mạng', 'Network'),
                  color: Colors.amberAccent,
                ),
              ),
              // Bảng tỉ số: hiện ngắn gọn; chạm để xem giải thích đầy đủ.
              _metricCell(
                _buildMetricChip(
                  icon: Icons.scoreboard_rounded,
                  value: scoreboard.$1,
                  tooltip: _scoreboardStatus(isWhip),
                  color: scoreboard.$2,
                  onTap: () => _showToast(_scoreboardStatus(isWhip)),
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
    if (!Platform.isAndroid && !Platform.isIOS) {
      return appText(
        context,
        'Thiết bị này chưa hỗ trợ in bảng tỉ số vào livestream (dùng OBS).',
        'This device cannot burn the scoreboard into the livestream yet (use OBS).',
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

  /// Trạng thái bảng tỉ số dạng một từ cho thẻ đang phát.
  (String, Color) _scoreboardShortStatus(bool isWhip) {
    if (isWhip ||
        (!Platform.isAndroid && !Platform.isIOS) ||
        _rtspService.overlayIssue != null) {
      return ('—', Colors.white38);
    }
    final overlay = ScoreboardService.instance.snapshot()['overlay'];
    if (_rtspService.overlayActive) {
      if (overlay is Map && overlay['visible'] == false) {
        return (appText(context, 'Ẩn', 'Hidden'), Colors.white54);
      }
      return (appText(context, 'Bật', 'On'), Colors.amberAccent);
    }
    final enabled = overlay is Map && overlay['burnIn'] != false;
    if (enabled) return ('…', Colors.amber.shade200);
    return (appText(context, 'Tắt', 'Off'), Colors.white38);
  }

  Widget _metricCell(Widget chip) {
    return Expanded(
      child: FittedBox(fit: BoxFit.scaleDown, child: chip),
    );
  }

  Widget _buildMetricChip({
    required IconData icon,
    required String value,
    required String tooltip,
    required Color color,
    VoidCallback? onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: color.withValues(alpha: 0.85)),
              const SizedBox(height: 4),
              Text(
                value,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // WIDGET: NÚT CHÍNH — to, ít chữ
  // ============================================================
  Widget _buildBigButton({
    required Widget leading,
    required String label,
    required VoidCallback? onTap,
    Gradient? gradient,
    Color? color,
    Color foreground = Colors.white,
    Color? borderColor,
    Color? glowColor,
    String? semanticsHint,
  }) {
    final button = Container(
      height: 58,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(29),
        gradient: gradient,
        color: gradient == null ? color : null,
        border: borderColor == null ? null : Border.all(color: borderColor),
        boxShadow: glowColor == null
            ? null
            : [
                BoxShadow(
                  color: glowColor.withValues(alpha: 0.35),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(29),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  leading,
                  const SizedBox(width: 10),
                  // Máy hẹp / chữ lớn: thu nhỏ nhãn thay vì tràn ngang.
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        label,
                        maxLines: 1,
                        style: TextStyle(
                          color: foreground,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                        ),
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
    if (semanticsHint == null) return button;
    return Semantics(hint: semanticsHint, child: button);
  }

  Widget _buildActionButton() {
    if (_platform == StreamPlatform.obs && !_isRtspActive && !_isWhipActive) {
      return _buildBigButton(
        leading: const Icon(Icons.copy_rounded, color: Colors.white, size: 22),
        label: appText(context, 'SAO CHÉP LINK', 'COPY LINK'),
        // Với OBS, _handleStartLive chỉ sao chép link RTSP nội bộ.
        onTap: _handleStartLive,
        gradient: const LinearGradient(
          colors: [Color(0xFF2979FF), Color(0xFF1565C0)],
        ),
        glowColor: const Color(0xFF2979FF),
      );
    }

    if (_isRtspActive) {
      return _buildBigButton(
        leading: const Icon(
          Icons.stop_circle_rounded,
          color: Colors.redAccent,
          size: 24,
        ),
        label: appText(context, 'DỪNG', 'STOP'),
        // Luôn bấm được (kể cả khi đang kết nối); chỉ khoá khi đang dừng.
        onTap: _stopInFlight ? null : () => _requestStop(whip: false),
        color: const Color(0xFF33181C),
        foreground: Colors.redAccent,
        borderColor: Colors.redAccent.withValues(alpha: 0.6),
      );
    }

    if (_isWhipActive) {
      final firstConnect = !_whipService.isLive &&
          !_whipWasLive &&
          _whipService.state != WhipPublishState.reconnecting;
      if (firstConnect) {
        // WHIP đang kết nối lần đầu (có thể tới ~50 giây): bấm để huỷ.
        return _buildBigButton(
          leading: const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: Colors.white,
            ),
          ),
          label: appText(
            context,
            'ĐANG KẾT NỐI · HỦY',
            'CONNECTING · CANCEL',
          ),
          semanticsHint: appText(context, 'Bấm để hủy', 'Tap to cancel'),
          onTap: _stopInFlight ? null : () => _requestStop(whip: true),
          gradient: LinearGradient(
            colors: [Colors.grey.shade700, Colors.grey.shade800],
          ),
        );
      }
      // Đang phát hoặc đang kết nối lại sau khi đã phát: như RTMP — DỪNG.
      return _buildBigButton(
        leading: const Icon(
          Icons.stop_circle_rounded,
          color: Colors.redAccent,
          size: 24,
        ),
        label: appText(context, 'DỪNG', 'STOP'),
        onTap: _stopInFlight ? null : () => _requestStop(whip: true),
        color: const Color(0xFF33181C),
        foreground: Colors.redAccent,
        borderColor: Colors.redAccent.withValues(alpha: 0.6),
      );
    }

    final isBusy = _isBusy || _actionInFlight;
    return _buildBigButton(
      leading: isBusy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.cell_tower_rounded, color: Colors.white, size: 22),
      label: isBusy
          ? appText(context, 'ĐANG KẾT NỐI', 'CONNECTING')
          : appText(context, 'PHÁT TRỰC TIẾP', 'GO LIVE'),
      onTap: isBusy ? null : _handleStartLive,
      gradient: isBusy
          ? LinearGradient(
              colors: [Colors.grey.shade700, Colors.grey.shade800],
            )
          : const LinearGradient(
              colors: [Color(0xFFFF2A4B), Color(0xFFD50000)],
            ),
      glowColor: isBusy ? null : const Color(0xFFFF1744),
    );
  }

  // ============================================================
  // WIDGET: ADVANCED SECTION
  // ============================================================
  Widget _buildAdvancedSection() {
    final localRtspUrl = _localRtspUrl;
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
              Expanded(
                child: Text(
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
              ),
              IconButton(
                tooltip: appText(
                  context,
                  'Sao chép link RTSP',
                  'Copy RTSP link',
                ),
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
                tooltip: _obscureWhipToken
                    ? appText(context, 'Hiện token', 'Show token')
                    : appText(context, 'Ẩn token', 'Hide token'),
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
                  ? (_stopInFlight ? null : () => _requestStop(whip: true))
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
