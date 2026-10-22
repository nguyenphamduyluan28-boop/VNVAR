import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/scoreboard_state.dart';
import '../services/app_language_service.dart';
import '../services/camera_station_runtime.dart';
import '../services/scoreboard_service.dart';
import '../theme/app_theme.dart';
import 'app_notice.dart';
import 'brand_widgets.dart';

/// Mở Hub bảng tỉ số: mã QR + link điều khiển, link overlay cho OBS. Mọi thao
/// tác tỉ số/overlay làm trên trang web nội bộ (dễ bấm hơn trên app camera).
Future<void> showScoreboardHub(
  BuildContext context, {
  required String? Function() lanAddress,
  required int port,
  Stream<void>? networkChanges,
  ScoreboardService? service,
  bool Function()? showRestartsLive,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: BrandColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(BrandRadius.large),
      ),
    ),
    builder: (_) => ScoreboardHubSheet(
      lanAddress: lanAddress,
      port: port,
      networkChanges: networkChanges,
      service: service ?? ScoreboardService.instance,
      showRestartsLive:
          showRestartsLive ??
          (() => CameraStationRuntime.instance.scoreboardShowRestartsLive),
    ),
  );
}

class ScoreboardHubSheet extends StatefulWidget {
  const ScoreboardHubSheet({
    super.key,
    required this.lanAddress,
    required this.port,
    required this.service,
    this.networkChanges,
    this.showRestartsLive,
  });

  final String? Function() lanAddress;
  final int port;
  final ScoreboardService service;
  final Stream<void>? networkChanges;

  /// Đang phát và bảng đang Ẩn: bấm Hiện sẽ phát lại live (~3 giây).
  final bool Function()? showRestartsLive;

  @override
  State<ScoreboardHubSheet> createState() => _ScoreboardHubSheetState();
}

class _ScoreboardHubSheetState extends State<ScoreboardHubSheet> {
  StreamSubscription<void>? _networkSubscription;
  StreamSubscription<Map<String, dynamic>>? _scoreSubscription;

  /// Overlay đang hiện (trường `overlay.visible` của bảng tỉ số).
  bool _overlayVisible = false;
  String? _address;
  /// Thông báo trong Hub, lưu cả hai ngôn ngữ để đổi ngôn ngữ vẫn đúng.
  ({String vi, String en})? _message;
  bool _messageIsError = false;
  Timer? _messageTimer;

  @override
  void initState() {
    super.initState();
    _address = widget.lanAddress();
    _networkSubscription = widget.networkChanges?.listen((_) {
      final next = widget.lanAddress();
      if (mounted && next != _address) setState(() => _address = next);
    });
    // Bật/tắt từ trang web cũng cập nhật công tắc ở đây.
    _scoreSubscription = widget.service.changes.listen((json) {
      final visible = _readVisible(json);
      if (mounted && visible != _overlayVisible) {
        setState(() => _overlayVisible = visible);
      }
    });
    // Mã điều khiển được nạp cùng trạng thái bảng tỉ số.
    unawaited(_load());
  }

  static bool _readVisible(Map<String, dynamic> json) {
    final overlay = json['overlay'];
    return overlay is Map && overlay['visible'] != false;
  }

  void _setOverlayVisible(bool visible) {
    try {
      widget.service.apply({'action': 'overlay', 'visible': visible});
      setState(() => _overlayVisible = visible);
    } on ScoreboardException catch (error) {
      _showMessage(
        error.localizedMessage(english: false),
        error.localizedMessage(english: true),
        error: true,
      );
    }
  }

  Future<void> _load() async {
    try {
      await widget.service.load();
    } catch (_) {
      // load() tự xử lý lỗi; luôn có mã mặc định.
    }
    if (!mounted) return;
    setState(() => _overlayVisible = _readVisible(widget.service.snapshot()));
  }

  @override
  void dispose() {
    _scoreSubscription?.cancel();
    _networkSubscription?.cancel();
    _messageTimer?.cancel();
    super.dispose();
  }

  String? get _baseUrl {
    final address = _address;
    if (address == null || address.isEmpty) return null;
    return 'http://$address:${widget.port}';
  }

  /// Thông báo hiện ngay trong Hub (SnackBar của màn hình chính bị bottom
  /// sheet che mất).
  void _showMessage(String vi, String en, {bool error = false}) {
    if (!mounted) return;
    _messageTimer?.cancel();
    setState(() {
      _message = (vi: vi, en: en);
      _messageIsError = error;
    });
    _messageTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _message = null);
    });
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _showMessage('Đã sao chép', 'Copied');
  }

  Future<void> _regenerateKey() async {
    final ok = await showAppConfirm(
      context,
      titleVi: 'Đổi mã điều khiển?',
      titleEn: 'Change control code?',
      messageVi: 'Máy đang dùng mã cũ sẽ mất quyền và phải quét lại QR.',
      messageEn: 'Phones using the old code lose access and must rescan.',
      confirmVi: 'Đổi mã',
      confirmEn: 'Change',
      icon: Icons.key_rounded,
      kind: NoticeKind.warning,
    );
    if (!ok) return;
    final String newKey;
    try {
      newKey = await widget.service.regenerateKey();
    } catch (error) {
      if (!mounted) return;
      _showMessage(
        'Không tạo được mã mới. Thử lại.',
        'Could not create a new code. Try again.',
        error: true,
      );
      return;
    }
    // regenerateKey() nuốt lỗi lưu mã và không trả kết quả lưu: đọc lại bộ
    // nhớ để phát hiện trường hợp không mở được/không ghi được
    // SharedPreferences (khi đó mở lại app sẽ quay về mã cũ). Lỗi ghi xuống
    // đĩa sau khi cache đã cập nhật thì vẫn chưa phát hiện được từ đây.
    final saved = await _isControlKeySaved(newKey);
    if (!mounted) return;
    setState(() {});
    if (saved) {
      _showMessage('Đã tạo mã mới', 'New code created');
    } else {
      _showMessage(
        'Đã đổi mã nhưng chưa lưu; có thể quay về mã cũ khi mở lại app.',
        'Code changed but not saved; may revert after restart.',
        error: true,
      );
    }
  }

  Future<bool> _isControlKeySaved(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(widget.service.controlKeyStorageKey) == key;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final base = _baseUrl;
    final key = widget.service.controlKey;
    final message = _message;
    final controlUrl = base == null ? null : '$base/control?k=$key';

    // Mã QR giữ nền trắng + viền trắng để mọi máy quét được.
    final qr = controlUrl == null
        ? null
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(BrandSpace.md),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(BrandRadius.medium),
                ),
                child: QrImageView(
                  data: controlUrl,
                  version: QrVersions.auto,
                  size: 170,
                  backgroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: BrandSpace.sm),
              Text(
                appText(context, 'Quét để điều khiển', 'Scan to control'),
                style: BrandText.caption,
              ),
            ],
          );

    final details = <Widget>[
      if (controlUrl == null) ...[
        AppNoticeBanner(
          icon: Icons.wifi_off_rounded,
          kind: NoticeKind.warning,
          message: appText(
            context,
            'Chưa có Wi-Fi. Kết nối để dùng mã QR.',
            'No Wi-Fi. Connect to use the QR code.',
          ),
        ),
        const SizedBox(height: BrandSpace.lg),
      ],
      BrandSection(
        title: appText(context, 'Kết nối', 'Access'),
        children: [
          if (controlUrl != null) ...[
            _linkTile(
              icon: Icons.tune_rounded,
              title: appText(context, 'Điều khiển', 'Control'),
              value: controlUrl,
            ),
            _linkTile(
              icon: Icons.cast_rounded,
              title: 'OBS 1920×1080',
              value: '$base/overlay',
            ),
          ],
          BrandTile(
            icon: Icons.key_rounded,
            iconColor: BrandColors.warning,
            title: appText(context, 'Mã', 'Code'),
            subtitle: key,
            trailing: TextButton.icon(
              onPressed: _regenerateKey,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(appText(context, 'Đổi mã', 'New code')),
            ),
          ),
        ],
      ),
    ];

    return Padding(
      padding: EdgeInsets.only(
        left: BrandSpace.lg,
        right: BrandSpace.lg,
        top: BrandSpace.md,
        bottom: MediaQuery.of(context).viewInsets.bottom + BrandSpace.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: BrandColors.primary.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(BrandRadius.small),
                  ),
                  child: const Icon(
                    Icons.scoreboard_rounded,
                    color: BrandColors.primaryBright,
                    size: 22,
                  ),
                ),
                const SizedBox(width: BrandSpace.md),
                Expanded(
                  child: Text(
                    appText(context, 'Bảng tỉ số', 'Scoreboard'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BrandText.title,
                  ),
                ),
                IconButton(
                  tooltip: appText(context, 'Đóng', 'Close'),
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(
                    Icons.close_rounded,
                    color: BrandColors.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: BrandSpace.md),
            if (message != null)
              Padding(
                padding: const EdgeInsets.only(bottom: BrandSpace.md),
                child: AppNoticeBanner(
                  dense: true,
                  kind: _messageIsError ? NoticeKind.error : NoticeKind.success,
                  message: appText(context, message.vi, message.en),
                ),
              ),
            BrandSection(
              children: [
                BrandTile(
                  icon: _overlayVisible
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded,
                  iconColor: _overlayVisible
                      ? BrandColors.success
                      : BrandColors.textSecondary,
                  title: 'Overlay',
                  subtitle: !_overlayVisible &&
                          (widget.showRestartsLive?.call() ?? false)
                      ? appText(
                          context,
                          'Bấm Hiện sẽ phát lại live ~3 giây',
                          'Show restarts the live stream (~3 s)',
                        )
                      : null,
                  trailing: BrandSegmented<bool>(
                    dense: true,
                    values: const [false, true],
                    selected: _overlayVisible,
                    labelOf: (visible) => visible
                        ? appText(context, 'Hiện', 'Show')
                        : appText(context, 'Ẩn', 'Hide'),
                    onChanged: (visible) {
                      if (visible != _overlayVisible) {
                        _setOverlayVisible(visible);
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: BrandSpace.xl),
            // Chỉ khi chọn "Hiện" mới mở mã QR và link điều khiển.
            if (!_overlayVisible)
              Padding(
                padding: const EdgeInsets.only(bottom: BrandSpace.sm),
                child: BrandEmptyState(
                  icon: Icons.qr_code_2_rounded,
                  message: appText(
                    context,
                    'Bật để hiện mã QR',
                    'Turn on to show the QR code',
                  ),
                ),
              )
            else
              LayoutBuilder(
                builder: (context, constraints) {
                  // Máy camera thường để ngang: mã QR bên trái, link bên phải.
                  if (qr != null && constraints.maxWidth >= 560) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        qr,
                        const SizedBox(width: BrandSpace.xl),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: details,
                          ),
                        ),
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (qr != null) ...[
                        Center(child: qr),
                        const SizedBox(height: BrandSpace.xl),
                      ],
                      ...details,
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Dòng link: chạm cả dòng hoặc nút để sao chép.
  Widget _linkTile({
    required IconData icon,
    required String title,
    required String value,
  }) {
    return BrandTile(
      icon: icon,
      title: title,
      subtitle: value,
      onTap: () => _copy(value),
      trailing: IconButton(
        tooltip: appText(context, 'Sao chép', 'Copy'),
        onPressed: () => _copy(value),
        icon: const Icon(Icons.copy_rounded, color: BrandColors.primarySoft),
      ),
    );
  }
}
