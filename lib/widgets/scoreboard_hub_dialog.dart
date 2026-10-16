import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/scoreboard_state.dart';
import '../services/app_language_service.dart';
import '../services/scoreboard_service.dart';

/// Mở Hub bảng tỉ số: mã QR + link điều khiển, link overlay cho OBS. Mọi thao
/// tác tỉ số/overlay làm trên trang web nội bộ (dễ bấm hơn trên app camera).
Future<void> showScoreboardHub(
  BuildContext context, {
  required String? Function() lanAddress,
  required int port,
  Stream<void>? networkChanges,
  ScoreboardService? service,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: const Color(0xFF0E1726),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => ScoreboardHubSheet(
      lanAddress: lanAddress,
      port: port,
      networkChanges: networkChanges,
      service: service ?? ScoreboardService.instance,
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
  });

  final String? Function() lanAddress;
  final int port;
  final ScoreboardService service;
  final Stream<void>? networkChanges;

  @override
  State<ScoreboardHubSheet> createState() => _ScoreboardHubSheetState();
}

class _ScoreboardHubSheetState extends State<ScoreboardHubSheet> {
  StreamSubscription<void>? _networkSubscription;
  StreamSubscription<Map<String, dynamic>>? _scoreSubscription;

  /// Overlay đang hiện (trường `overlay.visible` của bảng tỉ số).
  bool _overlayVisible = false;
  String? _address;
  String? _message;
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
      _showMessage(error.message, error: true);
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
  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    _messageTimer?.cancel();
    setState(() {
      _message = message;
      _messageIsError = error;
    });
    _messageTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _message = null);
    });
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _showMessage(appText(context, 'Đã sao chép', 'Copied'));
  }

  Future<bool> _confirm(String title, String message, String confirm) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(appText(dialogContext, 'HỦY', 'CANCEL')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(confirm),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _regenerateKey() async {
    final ok = await _confirm(
      appText(context, 'Đổi mã điều khiển?', 'Change control code?'),
      appText(
        context,
        'Mọi điện thoại đang dùng mã cũ sẽ mất quyền chỉnh tỉ số và phải quét lại mã QR mới.',
        'Every phone using the old code loses control and must scan the new QR code.',
      ),
      appText(context, 'ĐỔI MÃ', 'CHANGE'),
    );
    if (!ok) return;
    await widget.service.regenerateKey();
    if (!mounted) return;
    setState(() {});
    _showMessage(appText(context, 'Đã tạo mã mới', 'New code created'));
  }

  @override
  Widget build(BuildContext context) {
    final base = _baseUrl;
    final key = widget.service.controlKey;
    final message = _message;
    final controlUrl = base == null ? null : '$base/control?k=$key';

    final qr = controlUrl == null
        ? null
        : Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: QrImageView(
              data: controlUrl,
              version: QrVersions.auto,
              size: 170,
              backgroundColor: Colors.white,
            ),
          );

    final details = <Widget>[
      if (controlUrl == null)
        _InfoCard(
          icon: Icons.wifi_off_rounded,
          color: const Color(0xFFFFC107),
          text: appText(
            context,
            'Chưa có Wi-Fi. Kết nối Wi-Fi để dùng mã QR.',
            'No Wi-Fi. Connect to Wi-Fi to use the QR code.',
          ),
        )
      else ...[
        _LinkRow(
          label: appText(context, 'Link điều khiển', 'Control link'),
          value: controlUrl,
          onCopy: () => _copy(controlUrl),
        ),
        const SizedBox(height: 8),
        _LinkRow(
          label: appText(context, 'Link OBS (1920×1080)', 'OBS link (1920×1080)'),
          value: '$base/overlay',
          onCopy: () => _copy('$base/overlay'),
        ),
      ],
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: Text(
              '${appText(context, 'Mã', 'Code')}: $key',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: _regenerateKey,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(appText(context, 'Đổi mã', 'New code')),
          ),
        ],
      ),
    ];

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.scoreboard_rounded, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    appText(context, 'Overlay', 'Overlay'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close_rounded, color: Colors.white70),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (message != null)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: _messageIsError
                      ? const Color(0xFF7A2430)
                      : const Color(0xFF1E5631),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            _OverlaySwitch(
              visible: _overlayVisible,
              onChanged: _setOverlayVisible,
            ),
            const SizedBox(height: 12),
            // Chỉ khi chọn "Hiện overlay" mới mở mã QR và link điều khiển.
            if (!_overlayVisible)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  appText(context, 'Bật để hiện mã QR', 'Turn on to show the QR code'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
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
                      const SizedBox(width: 16),
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
                      const SizedBox(height: 12),
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
}

/// Công tắc lớn "Hiện overlay" ở đầu Hub.
class _OverlaySwitch extends StatelessWidget {
  const _OverlaySwitch({required this.visible, required this.onChanged});

  final bool visible;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: visible ? const Color(0xFF1E3A5F) : const Color(0xFF16223A),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => onChanged(!visible),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          child: Row(
            children: [
              Icon(
                visible ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                color: visible ? const Color(0xFF69F0AE) : Colors.white54,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      appText(context, 'Hiện overlay', 'Show overlay'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              Switch.adaptive(value: visible, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.label, required this.value, required this.onCopy});

  final String label;
  final String value;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF16223A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(color: Colors.white60, fontSize: 12)),
                const SizedBox(height: 2),
                SelectableText(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: appText(context, 'Sao chép', 'Copy'),
            onPressed: onCopy,
            icon: const Icon(Icons.copy_rounded, color: Colors.white),
          ),
        ],
      ),
    );
  }
}
