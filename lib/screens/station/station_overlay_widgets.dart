part of '../station_screen.dart';

// ============================================================
// HEADER
// ============================================================

// ============================================================
// THANH TRẠNG THÁI & MENU (màn hình camera)
// ============================================================

const Color _glassColor = Color(0xA60E1116);
const Color _glassBorder = Color(0x1FFFFFFF);
const Color _accentBlue = Color(0xFF1E88E5);

/// Nền tối dùng chung cho thanh trạng thái, menu và các viên.
class _GlassSurface extends StatelessWidget {
  const _GlassSurface({
    required this.child,
    this.radius = 16,
    this.padding = EdgeInsets.zero,
    this.color = _glassColor,
    this.borderColor = _glassBorder,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final Color color;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    // Không dùng làm mờ nền (BackdropFilter): vẽ lại mỗi khung hình camera
    // tốn GPU và làm máy nóng thêm. Nền tối bán trong suốt là đủ đọc rõ.
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: borderColor),
        ),
        child: child,
      ),
    );
  }
}

/// Một viên trạng thái: cùng chiều cao, cùng kiểu chữ cho mọi thông tin.
class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.label,
    required this.color,
    required this.tooltip,
    this.icon,
    this.dotColor,
    this.loading = false,
    this.background,
    this.trailingIcon,
    this.trailingColor,
    this.onTap,
    this.onClose,
  });

  static const double height = 26;

  final String label;
  final Color color;
  final String tooltip;
  final IconData? icon;
  final Color? dotColor;
  final bool loading;
  final Color? background;
  final IconData? trailingIcon;
  final Color? trailingColor;
  final VoidCallback? onTap;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final leading = loading
        ? SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          )
        : dotColor != null
        ? Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          )
        : icon != null
        ? Icon(icon, size: 13, color: color)
        : null;
    final content = Container(
      height: height,
      padding: EdgeInsets.only(left: 9, right: onClose != null ? 3 : 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[leading, const SizedBox(width: 6)],
          Text(
            label,
            maxLines: 1,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
              height: 1.1,
            ),
          ),
          if (trailingIcon != null) ...[
            const SizedBox(width: 6),
            Icon(trailingIcon, size: 14, color: trailingColor ?? color),
          ],
          if (onTap != null && onClose == null) ...[
            const SizedBox(width: 3),
            Icon(
              Icons.expand_more_rounded,
              size: 15,
              color: color.withValues(alpha: 0.75),
            ),
          ],
          if (onClose != null)
            InkResponse(
              onTap: onClose,
              radius: 14,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.close_rounded,
                  size: 14,
                  color: color.withValues(alpha: 0.8),
                ),
              ),
            ),
        ],
      ),
    );
    return Tooltip(
      message: tooltip,
      child: _GlassSurface(
        radius: height / 2,
        color: background ?? _glassColor,
        borderColor: background != null
            ? Colors.transparent
            : color.withValues(alpha: 0.30),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(onTap: onTap, child: content),
        ),
      ),
    );
  }
}

/// Nhiệt độ trong thanh trạng thái: ngắn gọn, đọc lướt là hiểu. Chạm để chọn
/// chất lượng; giữ để xem giải thích đầy đủ.
///
/// Đếm ngược "hạ … sau Ns" tự cập nhật mỗi giây bằng Timer riêng của viên
/// này (chỉ khi có lịch hạ), không dựng lại cả màn hình Station.
class _ThermalPill extends StatefulWidget {
  const _ThermalPill({
    required this.onTap,
    this.onDismiss,
    this.temperatureC,
    this.userOverride = false,
    this.isCooledDown = false,
    this.isLocked = false,
    this.isThrottled = false,
    this.targetProfile,
    this.pendingAt,
    this.profile,
    this.loadLevel = 0,
  });

  final VoidCallback onTap;
  final VoidCallback? onDismiss;
  final double? temperatureC;
  final bool userOverride;
  final bool isCooledDown;
  final bool isLocked;
  final bool isThrottled;
  final CameraResolutionProfile? targetProfile;

  /// Thời điểm runtime sẽ tự hạ xuống [targetProfile].
  final DateTime? pendingAt;
  final CameraResolutionProfile? profile;

  /// Bậc giảm tải tại chỗ của runtime (2 = nóng, 3 = critical).
  final int loadLevel;

  @override
  State<_ThermalPill> createState() => _ThermalPillState();
}

class _ThermalPillState extends State<_ThermalPill> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant _ThermalPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Chỉ chạy Timer khi đang đếm ngược hạ độ phân giải.
  void _syncTicker() {
    final counting = widget.targetProfile != null && widget.pendingAt != null;
    if (!counting) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final temperatureC = widget.temperatureC;
    final userOverride = widget.userOverride;
    final isCooledDown = widget.isCooledDown;
    final isLocked = widget.isLocked;
    final isThrottled = widget.isThrottled;
    final targetProfile = widget.targetProfile;
    final profile = widget.profile;
    final loadLevel = widget.loadLevel;
    final temp = temperatureC != null
        ? '${temperatureC.toStringAsFixed(0)}°C'
        : null;
    String short(CameraResolutionProfile? p) =>
        p != null ? '${p.shortLabel}${p.fps}' : '720p30';
    String full(CameraResolutionProfile? p) =>
        p != null ? '${p.shortLabel} ${p.fps} FPS' : '720p 30 FPS';
    String withTemp(String text) => temp == null ? text : '$temp · $text';

    late final Color color;
    late final IconData icon;
    late final String label;
    late final String tooltip;
    if (isCooledDown) {
      color = const Color(0xFF69F0AE);
      icon = Icons.ac_unit_rounded;
      label = appText(context, 'Đã mát · nâng chất lượng', 'Cool · raise quality');
      tooltip = appText(
        context,
        'Máy đã mát. Chạm để chọn lại chất lượng video.',
        'Device has cooled down. Tap to choose video quality.',
      );
    } else if (targetProfile != null) {
      final secs = (secondsUntil(widget.pendingAt, DateTime.now()) ?? 0).clamp(
        0,
        999,
      );
      color = const Color(0xFFFFB74D);
      icon = Icons.timer_outlined;
      label = withTemp(
        secs < 5
            ? appText(
                context,
                'hạ ${short(targetProfile)}',
                'to ${short(targetProfile)}',
              )
            : appText(
                context,
                'hạ ${short(targetProfile)} sau ${secs}s',
                'to ${short(targetProfile)} in ${secs}s',
              ),
      );
      tooltip = appText(
        context,
        'Máy nóng: sẽ tự hạ xuống ${full(targetProfile)} để giảm nhiệt. Chạm để chọn chất lượng khác.',
        'Device is hot: lowering to ${full(targetProfile)} to cool down. Tap to choose another quality.',
      );
    } else if (isThrottled) {
      color = const Color(0xFFFFB74D);
      icon = Icons.whatshot_rounded;
      label = withTemp(
        appText(context, 'giảm nhiệt', 'cooling'),
      );
      tooltip = appText(
        context,
        'Đã hạ xuống ${full(profile)} để giữ máy mát. Chạm để chọn chất lượng khác.',
        'Lowered to ${full(profile)} to keep the device cool. Tap to choose another quality.',
      );
    } else if (userOverride || isLocked) {
      color = const Color(0xFFFF8A65);
      icon = isLocked ? Icons.lock_rounded : Icons.thermostat_rounded;
      label = withTemp(appText(context, 'máy nóng', 'hot'));
      tooltip = appText(
        context,
        'Máy nóng nhưng đang giữ ${full(profile)} theo lựa chọn của bạn.',
        'Device is hot but keeping ${full(profile)} as you selected.',
      );
    } else if (loadLevel >= 2) {
      color = const Color(0xFFFFB74D);
      icon = Icons.whatshot_rounded;
      label = withTemp(appText(context, 'giảm tải', 'reducing load'));
      tooltip = appText(
        context,
        'Máy nóng: đã giảm FPS/bitrate và làm tối màn hình. Giữ nguyên độ phân giải để Tablet và livestream không mất hình.',
        'Device is hot: FPS/bitrate reduced and screen dimmed. Resolution is kept so the tablet and livestream are not interrupted.',
      );
    } else {
      color = const Color(0xFFFFE082);
      icon = Icons.thermostat_rounded;
      label = withTemp(appText(context, 'máy ấm', 'warm'));
      tooltip = appText(
        context,
        'Máy hơi ấm, app đang theo dõi nhiệt độ.',
        'Device is warm; temperature is being monitored.',
      );
    }
    return _StatusPill(
      icon: icon,
      label: label,
      color: color,
      tooltip: tooltip,
      onTap: widget.onTap,
      onClose: isCooledDown ? widget.onDismiss : null,
    );
  }
}

/// Thanh trên: viên trạng thái + nút "Menu" có chữ.
class _StationHeader extends StatelessWidget {
  const _StationHeader({
    required this.compact,
    required this.landscape,
    required this.statusPills,
    required this.menuOpen,
    required this.onToggleMenu,
  });

  final bool compact;
  final bool landscape;
  final List<Widget> statusPills;
  final bool menuOpen;
  final VoidCallback onToggleMenu;

  @override
  Widget build(BuildContext context) {
    final menuButton = _MenuButton(open: menuOpen, onTap: onToggleMenu);
    if (landscape) {
      return Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              // Máy hẹp: hàng trạng thái tự cuộn ngang, không đẩy nút Menu.
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < statusPills.length; i++) ...[
                      if (i > 0) const SizedBox(width: 6),
                      statusPills[i],
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          menuButton,
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _GlassSurface(
              radius: 10,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: SizedBox(
                width: compact ? 70 : 84,
                height: compact ? 22 : 26,
                child: Image.asset(
                  'assets/images/vnvar_logo.png',
                  fit: BoxFit.contain,
                ),
              ),
            ),
            const Spacer(),
            menuButton,
          ],
        ),
        SizedBox(height: compact ? 6 : 8),
        Wrap(spacing: 6, runSpacing: 6, children: statusPills),
      ],
    );
  }
}

/// Nút mở/đóng menu: có chữ để người dùng nhìn là biết.
class _MenuButton extends StatelessWidget {
  const _MenuButton({required this.open, required this.onTap});

  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: open
          ? appText(context, 'Đóng menu', 'Close menu')
          : appText(context, 'Mở menu chức năng', 'Open menu'),
      child: _GlassSurface(
        radius: 15,
        color: open ? _accentBlue : _glassColor,
        borderColor: open ? Colors.transparent : const Color(0x33FFFFFF),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              height: 30,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 11),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      open ? Icons.close_rounded : Icons.menu_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      open
                          ? appText(context, 'Đóng', 'Close')
                          : appText(context, 'Menu', 'Menu'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
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

/// Menu chức năng: một hàng nút nhỏ, gọn.
class _QuickMenuPanel extends StatelessWidget {
  const _QuickMenuPanel({required this.tiles});

  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
    return _GlassSurface(
      radius: 14,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(mainAxisSize: MainAxisSize.min, children: tiles),
    );
  }
}

/// Một nút trong menu: biểu tượng nhỏ + nhãn ngắn bên dưới.
class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.label,
    required this.tooltip,
    this.icon,
    this.custom,
    this.onTap,
    this.active = false,
    this.activeColor = _accentBlue,
  });

  static const double width = 52;

  final String label;
  final String tooltip;
  final IconData? icon;

  /// Nút tự xử lý chạm (ví dụ chọn ngôn ngữ).
  final Widget? custom;
  final VoidCallback? onTap;
  final bool active;
  final Color activeColor;

  @override
  Widget build(BuildContext context) {
    final body = SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 30,
              child: Center(
                child: custom ??
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: active
                            ? activeColor.withValues(alpha: 0.9)
                            : Colors.white.withValues(alpha: 0.10),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(icon, size: 17, color: Colors.white),
                    ),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
    if (custom != null) return body;
    return Tooltip(
      message: tooltip,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: body,
        ),
      ),
    );
  }
}

/// Màn hình nghỉ: nền đen, vẫn hiện trạng thái (REC, nhiệt độ, LIVE); chạm
/// bất kỳ đâu để xem lại hình.
class _PreviewRestOverlay extends StatelessWidget {
  const _PreviewRestOverlay({required this.statusPills, required this.onWake});

  final List<Widget> statusPills;
  final VoidCallback onWake;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onWake,
      child: ColoredBox(
        color: Colors.black,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Chỉ để xem: chạm vào đâu cũng là "xem lại hình".
                IgnorePointer(
                  child: Wrap(spacing: 6, runSpacing: 6, children: statusPills),
                ),
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.touch_app_rounded,
                          color: Colors.white38,
                          size: 30,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          appText(context, 'Chạm để xem hình', 'Tap to view'),
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          appText(
                            context,
                            'Tạm tắt hình xem trước để giảm nhiệt. Ghi hình, Tablet và livestream vẫn chạy.',
                            'Preview paused to reduce heat. Recording, tablet and livestream keep running.',
                          ),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
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

class _NetworkStatusBanner extends StatelessWidget {
  const _NetworkStatusBanner({
    required this.compact,
    required this.connectedAddress,
    required this.recovering,
    required this.hasError,
    required this.onReconnect,
  });

  final bool compact;
  final String? connectedAddress;
  final bool recovering;
  final bool hasError;
  final VoidCallback? onReconnect;

  @override
  Widget build(BuildContext context) {
    final message = recovering
        ? appText(
            context,
            'Đang khởi động lại kết nối live…',
            'Restarting live connection…',
          )
        : connectedAddress == null
        ? appText(
            context,
            'Chưa có Wi-Fi. Camera vẫn ghi hình bình thường; Tablet sẽ kết nối được khi điện thoại vào Wi-Fi.',
            'No Wi-Fi. Recording continues; tablets can connect once the phone joins Wi-Fi.',
          )
        : appText(
            context,
            hasError
                ? 'Kết nối live gặp lỗi. Camera vẫn tiếp tục ghi hình.'
                : 'Kết nối live cần được làm mới.',
            hasError
                ? 'Live connection has an error. Recording is still active.'
                : 'Live connection needs to be refreshed.',
          );
    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(bottom: compact ? 6 : 8),
      padding: EdgeInsets.fromLTRB(
        compact ? 10 : 12,
        compact ? 6 : 8,
        6,
        compact ? 6 : 8,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF37474F).withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(compact ? 10 : 12),
      ),
      child: Row(
        children: [
          if (recovering)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          else
            const Icon(Icons.wifi_off_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: compact ? 2 : 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: compact ? 11 : 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: onReconnect,
            icon: const Icon(Icons.sync_rounded, size: 17),
            label: Text(
              appText(context, 'KẾT NỐI LẠI', 'RECONNECT'),
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }
}

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

/// "Tự thử lại sau Ns": đếm ngược tới lần runtime tự khởi tạo lại, cập nhật
/// mỗi giây bằng Timer riêng.
class _RetryCountdownText extends StatefulWidget {
  const _RetryCountdownText({required this.target});

  final DateTime target;

  @override
  State<_RetryCountdownText> createState() => _RetryCountdownTextState();
}

class _RetryCountdownTextState extends State<_RetryCountdownText> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = secondsUntil(widget.target, DateTime.now()) ?? 0;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Colors.white54,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            seconds > 0
                ? appText(
                    context,
                    'Tự thử lại sau ${seconds}s',
                    'Retrying automatically in ${seconds}s',
                  )
                : appText(context, 'Đang tự thử lại…', 'Retrying…'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

/// Hộp xác nhận áp dụng cấu hình mới (khởi động lại dịch vụ). Khi đang ghi
/// hoặc đang live thì nói rõ ghi hình/phát sẽ gián đoạn vài giây.
class _ApplyConfigDialog extends StatelessWidget {
  const _ApplyConfigDialog({
    required this.identity,
    required this.courtLabel,
    required this.interruptsCapture,
  });

  final StationIdentity identity;
  final String courtLabel;
  final bool interruptsCapture;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final landscape = media.orientation == Orientation.landscape;
    final compactHeight = media.size.height < 480;
    final identityDetails = landscape
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ConfigLine(
                      title: appText(context, 'Tên', 'Name'),
                      value: identity.cameraName,
                    ),
                    _ConfigLine(
                      title: 'Camera',
                      value: identity.cameraId,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ConfigLine(
                      title: appText(context, 'Sân', 'Court'),
                      value: courtLabel,
                    ),
                  ],
                ),
              ),
            ],
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ConfigLine(
                title: appText(context, 'Tên', 'Name'),
                value: identity.cameraName,
              ),
              _ConfigLine(title: 'Camera', value: identity.cameraId),
              _ConfigLine(
                title: appText(context, 'Sân', 'Court'),
                value: courtLabel,
              ),
            ],
          );
    return AlertDialog(
      scrollable: true,
      insetPadding: EdgeInsets.symmetric(
        horizontal: landscape ? 32 : 20,
        vertical: landscape ? 12 : 24,
      ),
      iconPadding: EdgeInsets.fromLTRB(20, compactHeight ? 12 : 20, 20, 4),
      titlePadding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      contentPadding: EdgeInsets.fromLTRB(
        landscape ? 18 : 20,
        0,
        landscape ? 18 : 20,
        compactHeight ? 8 : 14,
      ),
      actionsPadding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        compactHeight ? 10 : 16,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      icon: Icon(
        Icons.settings_rounded,
        color: const Color(0xFF1565C0),
        size: compactHeight ? 30 : 38,
      ),
      title: Text(
        appText(context, 'ÁP DỤNG CẤU HÌNH MỚI?', 'APPLY NEW SETTINGS?'),
        textAlign: TextAlign.center,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            appText(
              context,
              'Camera Station sẽ khởi động lại dịch vụ với cấu hình mới.',
              'Camera Station will restart its services with the new settings.',
            ),
            textAlign: TextAlign.center,
          ),
          if (interruptsCapture) ...[
            SizedBox(height: compactHeight ? 6 : 10),
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(compactHeight ? 8 : 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFFFB74D)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    color: Color(0xFFE65100),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      appText(
                        context,
                        'Đang ghi hình/phát trực tiếp: ghi hình và livestream sẽ bị gián đoạn vài giây trong lúc khởi động lại.',
                        'Recording/live streaming is active: recording and the livestream will be interrupted for a few seconds while restarting.',
                      ),
                      style: const TextStyle(
                        color: Color(0xFF8D3B00),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          SizedBox(height: compactHeight ? 8 : 14),
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(compactHeight ? 9 : 12),
            decoration: BoxDecoration(
              color: const Color(0xFFF4F6F9),
              borderRadius: BorderRadius.circular(14),
            ),
            child: identityDetails,
          ),
        ],
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        OutlinedButton(
          onPressed: () {
            Navigator.pop(context, false);
          },
          child: Text(appText(context, 'HỦY', 'CANCEL')),
        ),
        FilledButton.icon(
          onPressed: () {
            Navigator.pop(context, true);
          },
          icon: const Icon(Icons.check_rounded),
          label: Text(appText(context, 'ÁP DỤNG', 'APPLY')),
        ),
      ],
    );
  }
}

/// Màn hình chờ khi Camera Station đang khởi động.
class _StationLoadingView extends StatelessWidget {
  const _StationLoadingView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF05070A),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/vnvar_logo.png',
                width: 240,
                height: 54,
                fit: BoxFit.contain,
              ),
              const SizedBox(height: 28),
              const CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2.6,
              ),
              const SizedBox(height: 18),
              Text(
                appText(
                  context,
                  'ĐANG KHỞI ĐỘNG CAMERA STATION...',
                  'STARTING CAMERA STATION...',
                ),
                style: const TextStyle(
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
}

/// Màn lỗi khởi động. Thiếu quyền: nút "Mở Cài đặt" + "Thử lại". Lỗi khác:
/// đếm ngược tới lần runtime tự thử lại + nút "Thử lại ngay".
class _StationErrorView extends StatelessWidget {
  const _StationErrorView({
    required this.message,
    required this.permissionError,
    required this.retryAt,
    required this.onOpenSettings,
    required this.onRetry,
  });

  final String message;
  final bool permissionError;

  /// Thời điểm runtime tự khởi tạo lại (null: không có lịch).
  final DateTime? retryAt;
  final VoidCallback onOpenSettings;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final retryAt = this.retryAt;
    final buttonStyle = FilledButton.styleFrom(
      padding: const EdgeInsets.symmetric(vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    );
    final outlinedStyle = OutlinedButton.styleFrom(
      foregroundColor: Colors.white,
      side: const BorderSide(color: Colors.white38),
      padding: const EdgeInsets.symmetric(vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    );
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
                    child: Icon(
                      permissionError
                          ? Icons.no_photography_rounded
                          : Icons.videocam_off_rounded,
                      color: Colors.redAccent,
                      size: 48,
                    ),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    permissionError
                        ? appText(
                            context,
                            'CHƯA CẤP QUYỀN CAMERA/MICRO',
                            'CAMERA/MICROPHONE PERMISSION NEEDED',
                          )
                        : appText(
                            context,
                            'LỖI KHỞI ĐỘNG CAMERA',
                            'CAMERA STATION ERROR',
                          ),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                  if (permissionError) ...[
                    const SizedBox(height: 8),
                    Text(
                      appText(
                        context,
                        'Bấm "Mở Cài đặt", bật quyền Camera và Micro rồi quay lại: ứng dụng sẽ tự thử lại.',
                        'Tap "Open Settings", allow Camera and Microphone, then come back: the app will retry automatically.',
                      ),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ] else if (retryAt != null) ...[
                    const SizedBox(height: 10),
                    _RetryCountdownText(target: retryAt),
                  ],
                  const SizedBox(height: 26),
                  if (permissionError) ...[
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: buttonStyle,
                        onPressed: onOpenSettings,
                        icon: const Icon(Icons.settings_rounded),
                        label: Text(
                          appText(context, 'MỞ CÀI ĐẶT', 'OPEN SETTINGS'),
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: outlinedStyle,
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh_rounded),
                        label: Text(
                          appText(context, 'THỬ LẠI', 'TRY AGAIN'),
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                  ] else
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: buttonStyle,
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh_rounded),
                        label: Text(
                          retryAt != null
                              ? appText(context, 'THỬ LẠI NGAY', 'RETRY NOW')
                              : appText(context, 'THỬ LẠI', 'TRY AGAIN'),
                          style: const TextStyle(fontWeight: FontWeight.w800),
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
}

/// Trạng thái tối giản khi đang ở chế độ PiP (hình trong hình).
class _PipStatusOverlay extends StatelessWidget {
  const _PipStatusOverlay({
    required this.recording,
    required this.live,
    required this.thermalWarning,
    required this.profileText,
  });

  final bool recording;
  final bool live;
  final bool thermalWarning;
  final String profileText;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (recording)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 5,
                  vertical: 2,
                ),
                margin: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, color: Colors.white, size: 6),
                    SizedBox(width: 3),
                    Text(
                      'REC',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            if (live)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 5,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'LIVE',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
          ],
        ),
        if (thermalWarning)
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 5,
              vertical: 2,
            ),
            decoration: BoxDecoration(
              color: const Color(0xFF2A1C08).withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: Colors.amber.withValues(alpha: 0.7),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.amber,
                  size: 10,
                ),
                const SizedBox(width: 3),
                Text(
                  profileText,
                  style: const TextStyle(
                    color: Colors.amber,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
