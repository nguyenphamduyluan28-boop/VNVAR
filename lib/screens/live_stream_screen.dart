import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/scoreboard_state.dart' show ScoreboardException;
import '../services/app_language_service.dart';
import '../services/camera_station_runtime.dart';
import '../services/station_config_service.dart';
import '../services/whip_publisher_service.dart';
import '../services/rtsp_publisher_service.dart';
import '../services/scoreboard_service.dart';
import '../theme/app_theme.dart';
import '../utils/stream_url_parser.dart';
import '../widgets/app_notice.dart';
import '../widgets/brand_widgets.dart';
import '../widgets/qr_stream_scanner_dialog.dart';
import '../services/station_errors.dart';

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
    color: BrandColors.primarySoft,
  ),
  StreamPlatform.custom: _PlatformMeta(
    name: null,
    icon: Icons.tune_rounded,
    color: BrandColors.success,
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
  StreamSubscription<Map<String, dynamic>>? _scoreSubscription;

  // Cấu hình overlay bảng tỉ số (đọc từ ScoreboardService). Mặc định overlay
  // ẩn nên ảnh in vào video trong suốt dù "In vào video" bật.
  bool _overlayVisible = false;
  bool _overlayBurnIn = true;

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

    final scoreboard = ScoreboardService.instance;
    final (visible, burnIn) = _overlayFlags(scoreboard.snapshot());
    _overlayVisible = visible;
    _overlayBurnIn = burnIn;
    _scoreSubscription = scoreboard.changes.listen(_onScoreboardChanged);
    unawaited(_loadScoreboard());
  }

  /// (overlay.visible, overlay.burnIn) trong JSON trạng thái bảng tỉ số.
  static (bool, bool) _overlayFlags(Map<String, dynamic> json) {
    final overlay = json['overlay'];
    if (overlay is! Map) return (false, false);
    return (overlay['visible'] != false, overlay['burnIn'] != false);
  }

  void _onScoreboardChanged(Map<String, dynamic> json) {
    if (!mounted) return;
    final (visible, burnIn) = _overlayFlags(json);
    if (visible == _overlayVisible && burnIn == _overlayBurnIn) return;
    setState(() {
      _overlayVisible = visible;
      _overlayBurnIn = burnIn;
    });
  }

  Future<void> _loadScoreboard() async {
    try {
      await ScoreboardService.instance.load();
    } catch (_) {
      // load() tự xử lý lỗi; dùng trạng thái mặc định.
    }
    _onScoreboardChanged(ScoreboardService.instance.snapshot());
  }

  void _setOverlayVisible(bool visible) {
    try {
      ScoreboardService.instance.apply({
        'action': 'overlay',
        'visible': visible,
      });
      setState(() => _overlayVisible = visible);
    } on ScoreboardException catch (error) {
      showAppNotice(
        context,
        vi: error.localizedMessage(english: false),
        en: error.localizedMessage(english: true),
        kind: NoticeKind.error,
      );
    }
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
          showAppNotice(
            context,
            vi: 'Không nạp được một phần cấu hình.',
            en: 'Some stream settings failed to load.',
            kind: NoticeKind.warning,
          );
        }
      }
    } catch (e, st) {
      debugPrint('[LIVESTREAM] Initial config load error: $e\n$st');
      if (mounted) {
        showAppNotice(
          context,
          vi: 'Lỗi nạp cấu hình livestream.',
          en: 'Failed to load stream settings.',
          kind: NoticeKind.error,
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
    _scoreSubscription?.cancel();
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
      showAppNotice(
        context,
        vi: 'Đã sao chép link RTSP cho OBS',
        en: 'RTSP link copied for OBS',
        kind: NoticeKind.success,
      );
      return;
    }

    if (_isWhipActive) {
      showAppNotice(
        context,
        vi: 'Đang phát qua WHIP. Hãy dừng WHIP trước.',
        en: 'Live via WHIP. Stop WHIP first.',
        kind: NoticeKind.warning,
      );
      return;
    }

    if (_platform == StreamPlatform.tiktok &&
        _serverController.text.trim().isEmpty) {
      showAppNotice(
        context,
        vi: 'Nhập Server URL của TikTok.',
        en: 'Enter the TikTok Server URL.',
        kind: NoticeKind.warning,
      );
      return;
    }

    final url = _buildEffectiveUrl();
    if (url.isEmpty ||
        (_platform != StreamPlatform.custom &&
            _streamKeyController.text.trim().isEmpty)) {
      showAppNotice(
        context,
        vi: 'Nhập khóa luồng (Stream Key).',
        en: 'Enter your Stream Key.',
        kind: NoticeKind.warning,
      );
      return;
    }

    final lowerUrl = url.toLowerCase();
    if (!lowerUrl.startsWith('rtmp://') &&
        !lowerUrl.startsWith('rtmps://') &&
        !lowerUrl.startsWith('rtsp://')) {
      showAppNotice(
        context,
        vi: 'URL phải bắt đầu bằng rtmp://, rtmps:// hoặc rtsp://',
        en: 'URL must start with rtmp://, rtmps:// or rtsp://',
        kind: NoticeKind.error,
      );
      return;
    }

    final webRtc = widget.runtime.webRtcService;
    if (webRtc == null || !webRtc.cameraInitialized) {
      showAppNotice(
        context,
        vi: 'Camera đang khởi động, thử lại sau giây lát.',
        en: 'Camera is starting, try again shortly.',
        kind: NoticeKind.warning,
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
        showAppNotice(
          context,
          vi: 'Lỗi bắt đầu phát: ${_streamErrorText(e, english: false)}',
          en: 'Failed to start stream: ${_streamErrorText(e, english: true)}',
          kind: NoticeKind.error,
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
        showAppNotice(
          context,
          vi: 'Lỗi dừng phát: ${_streamErrorText(e, english: false)}',
          en: 'Failed to stop stream: ${_streamErrorText(e, english: true)}',
          kind: NoticeKind.error,
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

  Future<bool> _confirmStop() {
    return showAppConfirm(
      context,
      titleVi: 'Dừng phát trực tiếp?',
      titleEn: 'Stop the live stream?',
      confirmVi: 'Dừng',
      confirmEn: 'Stop',
      icon: Icons.stop_circle_rounded,
      destructive: true,
    );
  }

  // ============================================================
  // START / STOP WHIP
  // ============================================================

  Future<void> _handleStartWhip() async {
    if (_actionInFlight || _isBusy) return;

    if (_isRtspActive) {
      showAppNotice(
        context,
        vi: 'Đang phát qua RTMP/RTSP. Hãy dừng phát trước.',
        en: 'Live via RTMP/RTSP. Stop streaming first.',
        kind: NoticeKind.warning,
      );
      return;
    }

    final url = _whipUrlController.text.trim();
    if (url.isEmpty) {
      showAppNotice(
        context,
        vi: 'Nhập địa chỉ WHIP.',
        en: 'Enter the WHIP link.',
        kind: NoticeKind.warning,
      );
      return;
    }

    final token = _whipTokenController.text.trim();

    final webRtc = widget.runtime.webRtcService;
    if (webRtc == null || !webRtc.cameraInitialized) {
      showAppNotice(
        context,
        vi: 'Camera đang khởi động, thử lại sau giây lát.',
        en: 'Camera is starting, try again shortly.',
        kind: NoticeKind.warning,
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
        showAppNotice(
          context,
          vi: 'Lỗi phát WHIP: ${_streamErrorText(e, english: false)}',
          en: 'WHIP error: ${_streamErrorText(e, english: true)}',
          kind: NoticeKind.error,
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
        showAppNotice(
          context,
          vi: 'Lỗi dừng WHIP: ${_streamErrorText(e, english: false)}',
          en: 'Failed to stop WHIP: ${_streamErrorText(e, english: true)}',
          kind: NoticeKind.error,
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
      showAppNotice(
        context,
        vi: 'Bộ nhớ tạm trống',
        en: 'Clipboard is empty',
        kind: NoticeKind.warning,
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

    showAppNotice(
      context,
      vi: 'Đã dán',
      en: 'Pasted',
      kind: NoticeKind.success,
    );
  }

  Future<void> _handleScanQrCode() async {
    if (_actionInFlight) return;
    if (_isRtspActive || _isWhipActive) {
      showAppNotice(
        context,
        vi: 'Dừng phát trước khi quét mã mới.',
        en: 'Stop streaming before scanning.',
        kind: NoticeKind.warning,
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
        showAppNotice(
          context,
          vi: 'Lỗi quét QR: ${_streamErrorText(e, english: false)}',
          en: 'QR scan error: ${_streamErrorText(e, english: true)}',
          kind: NoticeKind.error,
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

  /// Quét bằng camera phải tạm dừng camera trạm (cắt ghi hình). Khi trạm
  /// đang ghi hoặc có Tablet đang xem thì hỏi trước, kèm lựa chọn quét từ ảnh
  /// không ảnh hưởng camera trạm. Trả về null nếu huỷ.
  Future<_QrScanSource?> _chooseQrScanSource() async {
    final recording = widget.runtime.recordingService?.recording == true;
    final peers = widget.runtime.webRtcService?.activePeerCount ?? 0;
    if (!recording && peers == 0) return _QrScanSource.camera;

    return showDialog<_QrScanSource>(
      context: context,
      builder: (dialogContext) {
        String t(String vi, String en) => appText(dialogContext, vi, en);
        return _DialogShell(
          icon: Icons.qr_code_scanner_rounded,
          accent: BrandColors.primaryBright,
          title: t('Quét mã QR', 'Scan QR code'),
          message: recording
              ? t(
                  'Đang ghi hình. Quét bằng camera sẽ tạm dừng ghi.',
                  'Recording. Camera scan pauses recording.',
                )
              : t(
                  'Quét bằng camera sẽ tạm dừng camera trạm.',
                  'Camera scan pauses the station camera.',
                ),
          children: [
            _ChoiceCard(
              icon: Icons.photo_library_rounded,
              color: BrandColors.successSoft,
              title: t('Quét từ ảnh', 'Scan from photo'),
              subtitle: t('Camera vẫn chạy', 'Camera keeps running'),
              badge: t('Khuyên dùng', 'Recommended'),
              onTap: () => Navigator.pop(dialogContext, _QrScanSource.gallery),
            ),
            const SizedBox(height: BrandSpace.sm),
            _ChoiceCard(
              icon: Icons.photo_camera_rounded,
              color: BrandColors.warningSoft,
              title: t('Quét bằng camera', 'Scan with camera'),
              subtitle: recording
                  ? t('Tạm dừng ghi', 'Pauses recording')
                  : t('Tạm dừng camera', 'Pauses the camera'),
              onTap: () => Navigator.pop(dialogContext, _QrScanSource.camera),
            ),
            const SizedBox(height: BrandSpace.sm),
            Center(
              child: TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                style: TextButton.styleFrom(
                  foregroundColor: BrandColors.textSecondary,
                ),
                child: Text(t('Hủy', 'Cancel')),
              ),
            ),
          ],
        );
      },
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
        String t(String vi, String en) => appText(dialogContext, vi, en);
        final shownHost = host.isEmpty ? t('(không rõ)', '(unknown)') : host;
        final details = <String>[
          if (label.isNotEmpty) t('Nền tảng: $label', 'Platform: $label'),
          t('Máy chủ: $shownHost', 'Server: $shownHost'),
          if (maskedKey.isNotEmpty)
            t('Khóa luồng: $maskedKey', 'Stream key: $maskedKey'),
        ].join('\n');
        final intro = isPublic
            ? t(
                'Mã QR muốn phát camera và micro lên kênh $label. Kênh có '
                    'thể không phải của bạn (QR bị dán đè) — kiểm tra khóa '
                    'luồng.',
                'The QR code wants to stream camera and mic to a $label '
                    'channel. It may not be yours (tampered QR) — check the '
                    'stream key.',
              )
            : t(
                'Mã QR muốn phát camera và micro tới "$shownHost". Chỉ tiếp '
                    'tục nếu bạn tin máy chủ này.',
                'The QR code wants to stream camera and mic to '
                    '"$shownHost". Continue only if you trust it.',
              );
        return _DialogShell(
          icon: Icons.warning_amber_rounded,
          accent: BrandColors.warning,
          title: isPublic
              ? t('Phát lên kênh $label?', 'Stream to this $label channel?')
              : t('Phát tới máy chủ lạ?', 'Stream to an unknown server?'),
          message: intro,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: BrandColors.surfaceRaised,
                borderRadius: BorderRadius.circular(BrandRadius.small),
                border: Border.all(color: BrandColors.border),
              ),
              child: Text(
                details,
                style: const TextStyle(
                  color: BrandColors.textPrimary,
                  fontSize: 13,
                  fontFamily: 'monospace',
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(height: BrandSpace.lg),
            // Hai nút chia đều bề rộng: không tràn khi máy hẹp / chữ lớn.
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: BrandColors.textPrimary,
                    ),
                    child: Text(
                      t('Hủy', 'Cancel'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: BrandSpace.md),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: Text(
                      t('Phát', 'Stream'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
    return confirmed == true;
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  Duration get _currentLiveDuration => _whipService.isLive
      ? _whipService.liveDuration
      : _rtspService.liveDuration;

  /// Sự kiện mỗi giây (thời lượng / số liệu): chỉ các phần nhỏ dựng lại.
  Listenable get _liveTicker => Listenable.merge([
        _rtspService.durationListenable,
        _rtspService.metricsListenable,
        _whipService.durationListenable,
      ]);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          tooltip: appText(context, 'Quay lại', 'Back'),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          appText(context, 'Phát trực tiếp', 'Live streaming'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_isLive)
            Padding(
              padding: const EdgeInsets.only(right: BrandSpace.md),
              child: Center(
                child: ListenableBuilder(
                  listenable: Listenable.merge([
                    _rtspService.durationListenable,
                    _whipService.durationListenable,
                  ]),
                  builder: (context, _) => BrandPill(
                    text: 'LIVE ${_formatDuration(_currentLiveDuration)}',
                    dot: true,
                    filled: true,
                    color: BrandColors.live,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              bottom: false,
              child: LayoutBuilder(
                builder: (context, constraints) =>
                    _buildBody(wide: constraints.maxWidth >= 720),
              ),
            ),
      bottomNavigationBar: _isLoading ? null : _buildBottomBar(),
    );
  }

  // ============================================================
  // BỐ CỤC: dọc 1 cột; rộng ≥ 720 chia 2 cột
  // ============================================================
  Widget _buildBody({required bool wide}) {
    // Đang kết nối / kết nối lại: phần cài đặt vẫn hiện (mờ, khoá) để người
    // dùng thấy đang phát tới đâu.
    Widget dimmed(Widget child) => AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: _streamActive ? 0.5 : 1.0,
          child: child,
        );
    final options = _buildOptionsSection();

    final Widget content;
    if (_isLive) {
      // Đang phát: thẻ trạng thái thay cho phần chọn nền tảng / đích phát.
      final monitor = ListenableBuilder(
        listenable: _liveTicker,
        builder: (context, _) => _buildLiveMonitorCard(),
      );
      content = wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: monitor),
                const SizedBox(width: BrandSpace.xl),
                Expanded(child: options),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                monitor,
                const SizedBox(height: BrandSpace.xl),
                options,
              ],
            );
    } else if (wide) {
      // Máy ngang / tablet: trái = chọn nền tảng (+ tuỳ chọn), phải = thông
      // tin nhập của nền tảng vừa chọn.
      content = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                dimmed(_buildPlatformSection(compact: true)),
                const SizedBox(height: BrandSpace.xl),
                options,
              ],
            ),
          ),
          const SizedBox(width: BrandSpace.xl),
          Expanded(child: dimmed(_buildDestinationSection())),
        ],
      );
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          dimmed(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildPlatformSection(),
                const SizedBox(height: BrandSpace.xl),
                _buildDestinationSection(),
              ],
            ),
          ),
          const SizedBox(height: BrandSpace.xl),
          options,
        ],
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(BrandSpace.lg),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1080),
          child: content,
        ),
      ),
    );
  }

  /// Thanh đáy cố định: banner lỗi / kết nối lại + nút hành động chính.
  Widget _buildBottomBar() {
    final banner = _buildStatusBanner();
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: BrandColors.background,
        border: Border(top: BorderSide(color: BrandColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            BrandSpace.lg,
            BrandSpace.md,
            BrandSpace.lg,
            BrandSpace.md,
          ),
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (banner != null) ...[
                    banner,
                    const SizedBox(height: BrandSpace.sm),
                  ],
                  _buildActionButton(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, BrandSpace.sm),
      child: Text(
        text.toUpperCase(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: BrandText.label,
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
      return AppNoticeBanner(
        message: err,
        kind: NoticeKind.error,
        dense: true,
        action: TextButton(
          onPressed: (_isBusy || _actionInFlight)
              ? null
              : (_rtspService.state == RtspPublishState.error
                  ? _handleStartLive
                  : _handleStartWhip),
          child: Text(appText(context, 'Thử lại', 'Retry')),
        ),
      );
    }

    if (isReconnecting) {
      final base = appText(
        context,
        'Mất kết nối, đang thử lại…',
        'Connection lost, reconnecting…',
      );
      return AppNoticeBanner(
        message: reconnectReason != null && reconnectReason.isNotEmpty
            ? '$base\n$reconnectReason'
            : base,
        kind: NoticeKind.warning,
        icon: Icons.sync_rounded,
        dense: true,
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
  // KHỐI NỀN TẢNG — lưới ô logo vuông (3 cột, khối rộng 6 cột)
  // ============================================================
  /// [compact]: máy ngang/tablet — ô thấp hơn (tối đa 88) để cả 2 hàng nền
  /// tảng và phần tuỳ chọn vừa màn hình mà không phải cuộn nhiều.
  Widget _buildPlatformSection({bool compact = false}) {
    final locked = _streamActive;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _sectionLabel(appText(context, 'Nền tảng', 'Platform')),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 520 ? 6 : 3;
            const spacing = BrandSpace.sm;
            final tile =
                ((constraints.maxWidth - spacing * (columns - 1)) / columns)
                    .floorToDouble();
            final tileHeight = compact && tile > 88 ? 88.0 : tile;
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final platform in _platformOrder)
                  SizedBox(
                    width: tile,
                    height: tileHeight,
                    child: _buildPlatformTile(
                      platform,
                      locked: locked,
                      size: tileHeight,
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildPlatformTile(
    StreamPlatform platform, {
    required bool locked,
    required double size,
  }) {
    final meta = _platformMeta[platform]!;
    final selected = _platform == platform;
    final name = meta.name ?? appText(context, 'Tùy chỉnh', 'Custom');
    var logoSize = size * 0.4;
    if (logoSize > 48) logoSize = 48;
    if (logoSize < 24) logoSize = 24;
    return Semantics(
      button: true,
      selected: selected,
      enabled: !locked,
      child: Material(
        color: selected ? BrandColors.surfaceRaised : BrandColors.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(BrandRadius.medium),
          side: BorderSide(
            color: selected ? BrandColors.primaryBright : BrandColors.border,
            width: selected ? 2 : 1,
          ),
        ),
        child: InkWell(
          onTap: locked ? null : () => _selectPlatform(platform),
          child: Stack(
            children: [
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(BrandSpace.sm),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _platformLogo(platform, size: logoSize),
                      const SizedBox(height: 6),
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: selected
                              ? BrandColors.textPrimary
                              : BrandColors.textSecondary,
                          fontSize: 12,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (selected)
                const Positioned(
                  top: 6,
                  right: 6,
                  child: Icon(
                    Icons.check_circle_rounded,
                    size: 16,
                    color: BrandColors.primaryBright,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // KHỐI ĐÍCH PHÁT — ô nhập máy chủ / khoá luồng, hoặc link OBS
  // ============================================================
  Widget _buildDestinationSection() {
    return BrandSection(
      title: appText(context, 'Đích phát', 'Destination'),
      trailing: IconButton(
        icon: const Icon(
          Icons.qr_code_scanner_rounded,
          color: BrandColors.primaryBright,
        ),
        tooltip: appText(context, 'Quét mã QR', 'Scan QR code'),
        onPressed: _streamActive ? null : _handleScanQrCode,
      ),
      padding: const EdgeInsets.all(BrandSpace.md),
      children: [
        if (_platform == StreamPlatform.obs)
          _buildObsContent()
        else
          _buildInputContent(),
      ],
    );
  }

  /// OBS: chỉ link RTSP; hướng dẫn thu gọn sau nút "?".
  Widget _buildObsContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Icon(
              Icons.link_rounded,
              size: 18,
              color: BrandColors.textDisabled,
            ),
            const SizedBox(width: BrandSpace.sm),
            Expanded(
              child: SelectableText(
                _localRtspUrl,
                maxLines: 2,
                style: const TextStyle(
                  color: BrandColors.primarySoft,
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
                color: BrandColors.textSecondary,
              ),
              onPressed: () => setState(() => _showObsGuide = !_showObsGuide),
            ),
          ],
        ),
        if (_showObsGuide) ...[
          const SizedBox(height: BrandSpace.sm),
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
            color: BrandColors.primaryBright.withValues(alpha: 0.15),
            shape: BoxShape.circle,
            border: Border.all(
              color: BrandColors.primaryBright.withValues(alpha: 0.4),
            ),
          ),
          child: Center(
            child: Text(
              step,
              style: const TextStyle(
                color: BrandColors.primaryBright,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        const SizedBox(width: BrandSpace.sm),
        Expanded(
          child: Text(text, style: BrandText.caption),
        ),
      ],
    );
  }

  Widget _buildInputContent() {
    final isCustom = _platform == StreamPlatform.custom;
    final isTiktok = _platform == StreamPlatform.tiktok;
    final defaultServer = kDefaultServers[_platform] ?? '';
    final locked = _streamActive;
    const monoStyle = TextStyle(
      color: BrandColors.textPrimary,
      fontSize: 13,
      fontFamily: 'monospace',
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
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
          const SizedBox(height: BrandSpace.sm),
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
                    color: BrandColors.textSecondary,
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
            const SizedBox(height: BrandSpace.sm),
          ] else ...[
            // Server mặc định: chỉ hiện mờ, bấm bút để sửa.
            Row(
              children: [
                const SizedBox(width: BrandSpace.xs),
                const Icon(
                  Icons.dns_rounded,
                  size: 16,
                  color: BrandColors.textDisabled,
                ),
                const SizedBox(width: BrandSpace.sm),
                Expanded(
                  child: Text(
                    _serverController.text.isNotEmpty
                        ? _serverController.text
                        : defaultServer,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: BrandColors.textSecondary,
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.edit_rounded,
                    size: 18,
                    color: BrandColors.textSecondary,
                  ),
                  tooltip: appText(
                    context,
                    'Chỉnh sửa máy chủ',
                    'Edit server',
                  ),
                  onPressed:
                      locked ? null : () => setState(() => _editServer = true),
                ),
              ],
            ),
            const SizedBox(height: BrandSpace.xs),
          ],
        ],

        TextFormField(
          controller: isCustom ? _customUrlController : _streamKeyController,
          enabled: !locked,
          // URL tùy chỉnh cũng chứa stream key: che như ô khóa luồng.
          obscureText: _obscureKey,
          style: monoStyle,
          decoration: _inputDecoration(
            hint: isCustom
                ? 'rtmp://server/live/key'
                : appText(context, 'Khóa luồng (Stream Key)', 'Stream key'),
            prefixIcon: isCustom ? Icons.link_rounded : Icons.key_rounded,
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(
                    _obscureKey
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                    size: 18,
                    color: BrandColors.textSecondary,
                  ),
                  tooltip: _obscureKey
                      ? appText(context, 'Hiện', 'Show')
                      : appText(context, 'Ẩn', 'Hide'),
                  onPressed: () => setState(() => _obscureKey = !_obscureKey),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.content_paste_rounded,
                    size: 18,
                    color: BrandColors.warningSoft,
                  ),
                  tooltip: appText(context, 'Dán', 'Paste'),
                  onPressed: locked ? null : _pasteFromClipboard,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: BrandSpace.sm),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: BrandSpace.xs),
          child: Text(
            appText(
              context,
              'Dán khóa hoặc quét mã QR',
              'Paste the key or scan a QR code',
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: BrandText.caption,
          ),
        ),
      ],
    );
  }

  InputDecoration _inputDecoration({
    required String hint,
    Widget? suffixIcon,
    IconData? prefixIcon,
  }) {
    // Nền, viền, màu gợi ý: theo inputDecorationTheme của app.
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(
        color: BrandColors.textDisabled,
        fontSize: 12.5,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      prefixIcon: prefixIcon == null
          ? null
          : Icon(prefixIcon, size: 18, color: BrandColors.textDisabled),
      suffixIcon: suffixIcon,
    );
  }

  // ============================================================
  // KHỐI TUỲ CHỌN — bảng tỉ số, âm thanh Tablet, chất lượng, nâng cao
  // ============================================================
  Widget _buildOptionsSection() {
    final webRtc = widget.runtime.webRtcService;
    final resolution = webRtc?.resolutionProfile.shortLabel ?? '1080p';
    final fps = webRtc?.resolutionProfile.fps ?? 30;

    return BrandSection(
      title: appText(context, 'Tùy chọn', 'Options'),
      children: [
        ListenableBuilder(
          listenable: _liveTicker,
          builder: (context, _) => _buildScoreboardTile(),
        ),
        BrandTile(
          icon: Icons.volume_up_rounded,
          title: appText(context, 'Âm thanh Tablet', 'Tablet audio'),
          trailing: Switch.adaptive(
            value: widget.runtime.rtspTabletAudio,
            onChanged: _setTabletAudio,
          ),
        ),
        BrandTile(
          icon: Icons.hd_rounded,
          title: appText(context, 'Chất lượng', 'Quality'),
          trailing: Text(
            '$resolution · ${fps}fps',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: BrandColors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        _buildAdvancedTile(),
      ],
    );
  }

  Widget _buildScoreboardTile() {
    final isWhip = _whipService.isLive;
    final short = _scoreboardShortStatus(isWhip);
    final full = _scoreboardStatusText(isWhip);
    final visible = _overlayVisible;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        BrandTile(
          icon: Icons.scoreboard_rounded,
          title: appText(context, 'Bảng tỉ số', 'Scoreboard'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                short.$1,
                maxLines: 1,
                style: TextStyle(
                  color: short.$2,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: BrandSpace.xs),
              const Icon(
                Icons.info_outline_rounded,
                size: 18,
                color: BrandColors.textDisabled,
              ),
            ],
          ),
          onTap: () => showAppNotice(context, vi: full.$1, en: full.$2),
        ),
        // Ẩn/Hiện overlay (overlay.visible): ẩn thì ảnh in vào video trong
        // suốt dù đang phát.
        Padding(
          padding: const EdgeInsets.fromLTRB(
            BrandSpace.lg,
            0,
            BrandSpace.lg,
            BrandSpace.md,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  visible
                      ? appText(context, 'Hiện trên video', 'Shown on video')
                      : appText(
                          context,
                          'Chọn Hiện để in vào video',
                          'Pick Show to put it on video',
                        ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: BrandText.caption.copyWith(
                    color: visible
                        ? BrandColors.textSecondary
                        : BrandColors.warningSoft,
                  ),
                ),
              ),
              const SizedBox(width: BrandSpace.sm),
              BrandSegmented<bool>(
                values: const [false, true],
                labelOf: (value) => value
                    ? appText(context, 'Hiện', 'Show')
                    : appText(context, 'Ẩn', 'Hide'),
                selected: visible,
                dense: true,
                onChanged: (value) {
                  if (value != _overlayVisible) _setOverlayVisible(value);
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _setTabletAudio(bool value) async {
    try {
      await widget.runtime.setRtspTabletAudio(value);
    } catch (error) {
      if (!mounted) return;
      showAppNotice(
        context,
        vi: 'Không đổi được âm thanh Tablet: ${_streamErrorText(error, english: false)}',
        en: 'Could not change tablet audio: ${_streamErrorText(error, english: true)}',
        kind: NoticeKind.error,
      );
    }
    if (mounted) setState(() {});
  }

  /// Mục "Nâng cao" thu gọn: RTSP nội bộ + WHIP.
  Widget _buildAdvancedTile() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        BrandTile(
          icon: Icons.tune_rounded,
          title: appText(context, 'Nâng cao', 'Advanced'),
          subtitle: 'WHIP · RTSP',
          trailing: AnimatedRotation(
            turns: _showAdvanced ? 0.5 : 0,
            duration: const Duration(milliseconds: 150),
            child: const Icon(
              Icons.expand_more_rounded,
              color: BrandColors.textSecondary,
            ),
          ),
          onTap: () => setState(() => _showAdvanced = !_showAdvanced),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.topCenter,
          child: _showAdvanced
              ? _buildAdvancedContent()
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  // ============================================================
  // THẺ ĐANG PHÁT — nền tảng + danh sách tham số đang phát
  // ============================================================
  Widget _buildLiveMonitorCard() {
    final isWhip = _whipService.isLive;
    final duration =
        isWhip ? _whipService.liveDuration : _rtspService.liveDuration;
    final url = isWhip
        ? (_whipService.currentEndpoint ?? _whipUrlController.text.trim())
        : (_rtspService.targetUrl ?? _buildEffectiveUrl());

    final isCustom = !isWhip && _platform == StreamPlatform.custom;
    var name = isWhip
        ? 'WHIP'
        : (_platformMeta[_platform]!.name ??
            appText(context, 'Tùy chỉnh', 'Custom'));
    if (isCustom) {
      final detected = streamDestinationLabel(url);
      if (detected.isNotEmpty) name = '$name · $detected';
    }

    final server = _serverDisplay(url);
    final whipToken = _whipTokenController.text.trim();
    final maskedKey = isWhip
        ? (whipToken.isEmpty ? '' : maskStreamSecret(whipToken))
        : maskedStreamKeyOf(url);
    final protocol = isWhip ? 'WHIP' : _protocolOf(url);

    final webRtc = widget.runtime.webRtcService;
    final profile = webRtc?.resolutionProfile;
    final fps = isWhip ? 0.0 : _rtspService.currentFps;
    final bitrate = isWhip ? 0.0 : _rtspService.currentBitrateKbps;
    final targetKbps = isWhip ? 0 : _rtspService.targetBitrateKbps;
    final quality = isWhip ? null : _networkQualityLabel();

    final String scoreboard;
    final Color scoreboardColor;
    if (!isWhip && _rtspService.overlayActive && _overlayBurnIn) {
      if (_overlayVisible) {
        scoreboard = appText(context, 'Đang in', 'On video');
        scoreboardColor = BrandColors.successSoft;
      } else {
        scoreboard = appText(context, 'Đang ẩn', 'Hidden');
        scoreboardColor = BrandColors.warning;
      }
    } else {
      scoreboard = appText(context, 'Không', 'None');
      scoreboardColor = BrandColors.textSecondary;
    }

    final rows = <_InfoRow>[
      _InfoRow(
        appText(context, 'Thời lượng', 'Duration'),
        _formatDuration(duration),
        mono: true,
      ),
      _InfoRow(appText(context, 'Nền tảng', 'Platform'), name),
      if (server.isNotEmpty)
        _InfoRow(appText(context, 'Máy chủ', 'Server'), server, mono: true),
      if (maskedKey.isNotEmpty)
        _InfoRow(
          appText(context, 'Khóa luồng', 'Stream key'),
          maskedKey,
          mono: true,
        ),
      if (protocol.isNotEmpty)
        _InfoRow(appText(context, 'Giao thức', 'Protocol'), protocol),
      if (profile != null)
        _InfoRow(
          appText(context, 'Cấu hình', 'Profile'),
          '${profile.shortLabel} · ${profile.fps} FPS',
        ),
      if (targetKbps > 0)
        _InfoRow(
          appText(context, 'Bitrate đặt', 'Target bitrate'),
          _formatKbps(targetKbps.toDouble()),
        ),
      if (fps > 0)
        _InfoRow(
          appText(context, 'FPS thực', 'Actual FPS'),
          fps.toStringAsFixed(0),
        ),
      if (bitrate > 0)
        _InfoRow(
          appText(context, 'Bitrate thực', 'Actual bitrate'),
          _formatKbps(bitrate),
        ),
      if (quality != null)
        _InfoRow(
          appText(context, 'Mạng', 'Network'),
          quality.$1,
          color: quality.$2,
        ),
      _InfoRow(
        appText(context, 'Bảng tỉ số', 'Scoreboard'),
        scoreboard,
        color: scoreboardColor,
      ),
      if (!isWhip)
        _InfoRow(
          appText(context, 'Đường truyền', 'Uplink'),
          _rtspService.cellularFallbackActive ? '4G/5G' : 'Wi-Fi',
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _sectionLabel(appText(context, 'Đang phát', 'On air')),
        Container(
          padding: const EdgeInsets.all(BrandSpace.lg),
          decoration: BoxDecoration(
            color: BrandColors.surface,
            borderRadius: BorderRadius.circular(BrandRadius.medium),
            border: Border.all(
              color: BrandColors.live.withValues(alpha: 0.5),
              width: 1.5,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (isWhip)
                    const Icon(
                      Icons.podcasts_rounded,
                      size: 28,
                      color: BrandColors.primaryBright,
                    )
                  else
                    _platformLogo(_platform, size: 32),
                  const SizedBox(width: BrandSpace.md),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BrandText.title,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: BrandSpace.md),
              const Divider(height: 1, color: BrandColors.border),
              const SizedBox(height: BrandSpace.md),
              // Danh sách nhãn – giá trị; rộng thì chia 2 cột.
              LayoutBuilder(
                builder: (context, constraints) {
                  final twoColumns = constraints.maxWidth >= 520;
                  const gap = BrandSpace.xl;
                  final itemWidth = twoColumns
                      ? ((constraints.maxWidth - gap) / 2).floorToDouble()
                      : constraints.maxWidth;
                  return Wrap(
                    spacing: gap,
                    runSpacing: BrandSpace.sm,
                    children: [
                      for (final row in rows)
                        SizedBox(width: itemWidth, child: _buildInfoRow(row)),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(_InfoRow row) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          flex: 2,
          child: Text(
            row.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: BrandText.caption,
          ),
        ),
        const SizedBox(width: BrandSpace.sm),
        Expanded(
          flex: 3,
          child: Text(
            row.value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: TextStyle(
              color: row.color ?? BrandColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFamily: row.mono ? 'monospace' : null,
            ),
          ),
        ),
      ],
    );
  }

  /// Máy chủ để hiển thị: host(:port) + segment app đầu tiên; KHÔNG kèm
  /// khoá luồng / query.
  static String _serverDisplay(String url) {
    try {
      final uri = Uri.tryParse(url.trim());
      if (uri == null || uri.host.isEmpty) return '';
      final hostPort = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
      final segments = uri.pathSegments.where((s) => s.isNotEmpty);
      return segments.isEmpty ? hostPort : '$hostPort/${segments.first}';
    } catch (_) {
      // Đường dẫn mã hoá sai: không hiện máy chủ.
      return '';
    }
  }

  /// Giao thức theo scheme của URL phát (rỗng nếu không nhận ra).
  static String _protocolOf(String url) {
    final lower = url.trim().toLowerCase();
    for (final scheme in const ['rtmps', 'rtmp', 'rtsps', 'rtsp', 'srt']) {
      if (lower.startsWith('$scheme://')) return scheme.toUpperCase();
    }
    return '';
  }

  static String _formatKbps(double kbps) => kbps >= 1000
      ? '${(kbps / 1000).toStringAsFixed(1)} Mbps'
      : '${kbps.toStringAsFixed(0)} kbps';

  /// Chất lượng mạng RTMP/RTSP dạng chữ + màu (null khi chưa có số liệu).
  (String, Color)? _networkQualityLabel() {
    return switch (_rtspService.networkQuality) {
      StreamNetworkQuality.good =>
        (appText(context, 'Tốt', 'Good'), BrandColors.successSoft),
      StreamNetworkQuality.warning =>
        (appText(context, 'Trung bình', 'Fair'), BrandColors.warning),
      StreamNetworkQuality.poor =>
        (appText(context, 'Kém', 'Poor'), BrandColors.dangerSoft),
      StreamNetworkQuality.unknown => null,
    };
  }

  /// Trạng thái in bảng tỉ số vào video livestream (Việt, Anh).
  (String, String) _scoreboardStatusText(bool isWhip) {
    if (isWhip) {
      return (
        'WHIP không in được bảng tỉ số (dùng RTMP/RTSP hoặc OBS).',
        "WHIP can't show the scoreboard (use RTMP/RTSP or OBS).",
      );
    }
    if (!Platform.isAndroid && !Platform.isIOS) {
      return (
        'Thiết bị chưa hỗ trợ in bảng tỉ số (dùng OBS).',
        "This device can't burn in the scoreboard (use OBS).",
      );
    }
    if (_rtspService.overlayIssue != null) {
      return (
        'Máy không in được bảng tỉ số; đang phát không kèm bảng.',
        "This phone can't burn in the scoreboard; streaming without it.",
      );
    }
    if (!_overlayBurnIn) {
      return (
        'Bảng tỉ số đang tắt (bật: trang điều khiển → Overlay)',
        'Scoreboard off (turn on: control page → Overlay)',
      );
    }
    if (!_overlayVisible) {
      return (
        'Bảng tỉ số đang ẩn — chọn Hiện để in vào video',
        'Scoreboard hidden — pick Show to put it on video',
      );
    }
    if (_rtspService.overlayActive) {
      return (
        'Bảng tỉ số đang hiện trên livestream',
        'Scoreboard is shown on the livestream',
      );
    }
    if (_isRtspActive) {
      return (
        'Đang chuẩn bị bảng tỉ số…',
        'Preparing the scoreboard…',
      );
    }
    return (
      'Bảng tỉ số sẽ hiện khi bắt đầu phát',
      'Scoreboard shows once you go live',
    );
  }

  /// Trạng thái bảng tỉ số dạng ngắn, đúng với cái đang in vào video.
  (String, Color) _scoreboardShortStatus(bool isWhip) {
    if (isWhip ||
        (!Platform.isAndroid && !Platform.isIOS) ||
        _rtspService.overlayIssue != null) {
      return ('—', BrandColors.textDisabled);
    }
    if (!_overlayBurnIn) {
      return (appText(context, 'Tắt', 'Off'), BrandColors.textDisabled);
    }
    if (!_overlayVisible) {
      return (appText(context, 'Đang ẩn', 'Hidden'), BrandColors.warning);
    }
    if (_rtspService.overlayActive) {
      return (appText(context, 'Đang in', 'On video'), BrandColors.successSoft);
    }
    if (_isRtspActive) return ('…', BrandColors.warning);
    return (appText(context, 'Sẵn sàng', 'Ready'), BrandColors.textSecondary);
  }

  // ============================================================
  // NÚT CHÍNH — cố định ở đáy, full-width
  // ============================================================
  ButtonStyle _filledMainStyle(Color color) {
    return FilledButton.styleFrom(
      backgroundColor: color,
      foregroundColor: Colors.white,
      disabledBackgroundColor: BrandColors.surfaceRaised,
      disabledForegroundColor: BrandColors.textSecondary,
      padding: const EdgeInsets.symmetric(horizontal: BrandSpace.lg),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BrandRadius.medium),
      ),
      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
    );
  }

  ButtonStyle _outlinedMainStyle({
    required Color foreground,
    required Color border,
    required Color background,
  }) {
    return OutlinedButton.styleFrom(
      foregroundColor: foreground,
      backgroundColor: background,
      side: BorderSide(color: border, width: 1.5),
      padding: const EdgeInsets.symmetric(horizontal: BrandSpace.lg),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BrandRadius.medium),
      ),
      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
    );
  }

  Widget _mainButton({
    required Widget icon,
    required String label,
    required VoidCallback? onPressed,
    required ButtonStyle style,
    bool outlined = false,
    String? semanticsHint,
  }) {
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        const SizedBox(width: 10),
        // Máy hẹp / chữ lớn: thu nhỏ nhãn thay vì tràn ngang.
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(label, maxLines: 1),
          ),
        ),
      ],
    );
    final Widget button = outlined
        ? OutlinedButton(onPressed: onPressed, style: style, child: child)
        : FilledButton(onPressed: onPressed, style: style, child: child);
    final sized = SizedBox(width: double.infinity, height: 56, child: button);
    if (semanticsHint == null) return sized;
    return Semantics(hint: semanticsHint, child: sized);
  }

  Widget _stopButton({required bool whip}) {
    return _mainButton(
      icon: const Icon(Icons.stop_circle_rounded, size: 24),
      label: appText(context, 'Dừng', 'Stop'),
      // Luôn bấm được (kể cả khi đang kết nối); chỉ khoá khi đang dừng.
      onPressed: _stopInFlight ? null : () => _requestStop(whip: whip),
      outlined: true,
      style: _outlinedMainStyle(
        foreground: BrandColors.dangerSoft,
        border: BrandColors.danger.withValues(alpha: 0.7),
        background: BrandColors.danger.withValues(alpha: 0.12),
      ),
    );
  }

  Widget _buildActionButton() {
    if (_platform == StreamPlatform.obs && !_isRtspActive && !_isWhipActive) {
      return _mainButton(
        icon: const Icon(Icons.copy_rounded, size: 22),
        label: appText(context, 'Sao chép link', 'Copy link'),
        // Với OBS, _handleStartLive chỉ sao chép link RTSP nội bộ.
        onPressed: _handleStartLive,
        style: _filledMainStyle(BrandColors.primary),
      );
    }

    if (_isRtspActive) return _stopButton(whip: false);

    if (_isWhipActive) {
      final firstConnect = !_whipService.isLive &&
          !_whipWasLive &&
          _whipService.state != WhipPublishState.reconnecting;
      if (firstConnect) {
        // WHIP đang kết nối lần đầu (có thể tới ~50 giây): bấm để huỷ.
        return _mainButton(
          icon: const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: BrandColors.textPrimary,
            ),
          ),
          label: appText(
            context,
            'Đang kết nối · Hủy',
            'Connecting · Cancel',
          ),
          semanticsHint: appText(context, 'Bấm để hủy', 'Tap to cancel'),
          onPressed: _stopInFlight ? null : () => _requestStop(whip: true),
          outlined: true,
          style: _outlinedMainStyle(
            foreground: BrandColors.textPrimary,
            border: BrandColors.border,
            background: BrandColors.surfaceRaised,
          ),
        );
      }
      // Đang phát hoặc đang kết nối lại sau khi đã phát: như RTMP — Dừng.
      return _stopButton(whip: true);
    }

    final isBusy = _isBusy || _actionInFlight;
    return _mainButton(
      icon: isBusy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                color: BrandColors.textSecondary,
              ),
            )
          : const Icon(Icons.cell_tower_rounded, size: 22),
      label: isBusy
          ? appText(context, 'Đang kết nối', 'Connecting')
          : appText(context, 'Bắt đầu phát', 'Go live'),
      onPressed: isBusy ? null : _handleStartLive,
      style: _filledMainStyle(BrandColors.live),
    );
  }

  // ============================================================
  // NỘI DUNG NÂNG CAO — RTSP nội bộ + WHIP
  // ============================================================
  Widget _buildAdvancedContent() {
    final localRtspUrl = _localRtspUrl;
    final isWhipActive = _isWhipActive;
    final isWhipBusy = _whipService.state == WhipPublishState.connecting;
    final canStartWhip = !_isRtspActive && !_isBusy && !_actionInFlight;
    const monoStyle = TextStyle(
      color: BrandColors.textPrimary,
      fontSize: 12.5,
      fontFamily: 'monospace',
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        BrandSpace.lg,
        0,
        BrandSpace.lg,
        BrandSpace.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  appText(
                    context,
                    'RTSP nội bộ (VLC/NVR)',
                    'Local RTSP (VLC/NVR)',
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BrandText.caption,
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
                  size: 18,
                  color: BrandColors.primaryBright,
                ),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: localRtspUrl));
                  showAppNotice(
                    context,
                    vi: 'Đã sao chép link RTSP',
                    en: 'RTSP link copied',
                    kind: NoticeKind.success,
                  );
                },
              ),
            ],
          ),
          SelectableText(
            localRtspUrl,
            style: const TextStyle(
              color: BrandColors.primarySoft,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
          const Divider(color: BrandColors.border, height: BrandSpace.xl),
          Padding(
            padding: const EdgeInsets.only(bottom: BrandSpace.sm),
            child: Text(
              appText(
                context,
                'WHIP (MediaMTX nội bộ)',
                'WHIP (local MediaMTX)',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: BrandText.caption,
            ),
          ),
          TextFormField(
            controller: _whipUrlController,
            enabled: !isWhipActive,
            style: monoStyle,
            decoration: _inputDecoration(
              hint: 'http://server:8889/live/whip',
              prefixIcon: Icons.link_rounded,
            ),
          ),
          const SizedBox(height: BrandSpace.sm),
          TextFormField(
            controller: _whipTokenController,
            enabled: !isWhipActive,
            obscureText: _obscureWhipToken,
            style: monoStyle,
            decoration: _inputDecoration(
              hint: appText(
                context,
                'Bearer Token (tùy chọn)',
                'Bearer Token (optional)',
              ),
              prefixIcon: Icons.key_rounded,
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureWhipToken
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                  size: 18,
                  color: BrandColors.textSecondary,
                ),
                tooltip: _obscureWhipToken
                    ? appText(context, 'Hiện token', 'Show token')
                    : appText(context, 'Ẩn token', 'Hide token'),
                onPressed: () =>
                    setState(() => _obscureWhipToken = !_obscureWhipToken),
              ),
            ),
          ),
          const SizedBox(height: BrandSpace.md),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: isWhipActive ? BrandColors.danger : null,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(BrandRadius.small),
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
                    ? appText(context, 'Dừng WHIP', 'Stop WHIP')
                    : isWhipBusy
                        ? appText(
                            context,
                            'Đang kết nối WHIP…',
                            'Connecting WHIP…',
                          )
                        : appText(context, 'Phát WHIP', 'Start WHIP'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
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

/// Lỗi phát trực tiếp cho người dùng: dùng bản dịch nếu lỗi có sẵn hai ngôn ngữ,
/// ngược lại giữ nguyên nội dung (lỗi máy chủ RTMP/WHIP như "publish denied"
/// không được hiểu nhầm thành thiếu quyền Camera/Micro).
String _streamErrorText(Object error, {required bool english}) {
  if (error is StationException) return error.message(english: english);
  if (error is BilingualMessage) return error.localized(english: english);
  final raw = error
      .toString()
      .replaceFirst(RegExp(r'^(Exception|Bad state|StateError): '), '')
      .trim();
  return raw.isEmpty
      ? stationErrorMessage(error, english: english)
      : raw;
}

/// Khung hộp thoại của màn này: icon tròn, tiêu đề, một dòng mô tả, rồi nội
/// dung tuỳ ý ([children]). Rộng tối đa 420, cuộn được khi màn hình thấp
/// (điện thoại ngang); khi rất thấp thì bỏ icon cho gọn.
class _DialogShell extends StatelessWidget {
  const _DialogShell({
    required this.icon,
    required this.accent,
    required this.title,
    required this.message,
    required this.children,
  });

  final IconData icon;
  final Color accent;
  final String title;
  final String message;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final short = MediaQuery.sizeOf(context).height < 480;
    return Dialog(
      backgroundColor: BrandColors.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(
        horizontal: BrandSpace.xl,
        vertical: BrandSpace.lg,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BrandRadius.large),
        side: const BorderSide(color: BrandColors.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!short) ...[
                Center(
                  child: AppNoticeIcon(icon: icon, color: accent, size: 24),
                ),
                const SizedBox(height: BrandSpace.md),
              ],
              Text(
                title,
                textAlign: TextAlign.center,
                style: BrandText.title,
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: BrandColors.textSecondary,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: BrandSpace.lg),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// Thẻ lựa chọn full-width trong hộp thoại: icon trong ô màu, tiêu đề (kèm
/// nhãn [badge] tuỳ chọn) và một dòng phụ đề.
class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final tag = badge;
    return Material(
      color: BrandColors.surfaceRaised,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BrandRadius.medium),
        side: const BorderSide(color: BrandColors.border),
      ),
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.all(BrandSpace.md),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(BrandRadius.small),
                  ),
                  child: Icon(icon, color: color, size: 22),
                ),
                const SizedBox(width: BrandSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Wrap: máy hẹp / chữ lớn thì nhãn xuống dòng thay vì
                      // cắt tiêu đề.
                      Wrap(
                        spacing: BrandSpace.sm,
                        runSpacing: BrandSpace.xs,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: BrandText.body.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (tag != null)
                            BrandPill(
                              text: tag,
                              color: BrandColors.successSoft,
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: BrandText.caption,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Một dòng nhãn – giá trị trong thẻ "Đang phát".
class _InfoRow {
  const _InfoRow(this.label, this.value, {this.mono = false, this.color});

  final String label;
  final String value;
  final bool mono;
  final Color? color;
}
