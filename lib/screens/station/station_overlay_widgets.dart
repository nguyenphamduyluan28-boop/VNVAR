part of '../station_screen.dart';

// ============================================================
// THANH TRẠNG THÁI, RAIL & MENU (màn hình camera)
//
// Ngôn ngữ chung: nền kính tối (BrandGlass / viên 0x8C080D18), viền mảnh,
// chữ trắng; màu nhấn duy nhất là xanh thương hiệu (trạng thái đang bật),
// đỏ chỉ cho REC/LIVE/nguy hiểm, cam cho cảnh báo.
// ============================================================

/// Dải tối mờ dần (đen → trong suốt) sau thanh trạng thái/thanh zoom: chữ
/// trắng dễ đọc mà không có khối nền nặng che hình camera. Không bắt chạm.
class _Scrim extends StatelessWidget {
  const _Scrim({required this.fromTop});

  final bool fromTop;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: fromTop ? Alignment.topCenter : Alignment.bottomCenter,
            end: fromTop ? Alignment.bottomCenter : Alignment.topCenter,
            colors: const [Color(0x99000000), Color(0x00000000)],
          ),
        ),
      ),
    );
  }
}

/// Logo nhỏ ở góc trái thanh trạng thái.
class _StationLogo extends StatelessWidget {
  const _StationLogo({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: compact ? 76 : 92,
      height: compact ? 24 : 28,
      child: Image.asset(
        'assets/images/vnvar_logo.png',
        fit: BoxFit.contain,
        alignment: Alignment.centerLeft,
      ),
    );
  }
}

/// Hàng viên trạng thái một dòng; thiếu chỗ thì cuộn ngang (không xuống
/// dòng, không đẩy nút Menu).
class _PillStrip extends StatelessWidget {
  const _PillStrip({required this.pills});

  final List<Widget> pills;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < pills.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            pills[i],
          ],
        ],
      ),
    );
  }
}

/// Viên trạng thái cùng kiểu [BrandPill] (cao 32, bo tròn, nền kính), thêm
/// các biến thể BrandPill chưa có: vòng xoay đang xử lý, icon đuôi (chất
/// lượng luồng phát), nút đóng và mũi tên "chạm để mở".
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

  final String label;
  final Color color;
  final String tooltip;
  final IconData? icon;
  final Color? dotColor;
  final bool loading;

  /// Nền đặc (vd đỏ LIVE); null = nền kính tối.
  final Color? background;
  final IconData? trailingIcon;
  final Color? trailingColor;
  final VoidCallback? onTap;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final filled = background != null;
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
        ? Icon(icon, size: 16, color: color)
        : null;
    Widget pill = Container(
      constraints: const BoxConstraints(minHeight: 32),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: background ?? const Color(0x8C080D18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: filled ? Colors.transparent : const Color(0x24FFFFFF),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[leading, const SizedBox(width: 6)],
          Text(
            label,
            maxLines: 1,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (trailingIcon != null) ...[
            const SizedBox(width: 6),
            // Trên nền đặc (đỏ LIVE) icon màu đặt trong vòng tối để vẫn đọc
            // được màu xanh/cam/đỏ.
            if (filled)
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: Color(0x66000000),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  trailingIcon,
                  size: 14,
                  color: trailingColor ?? color,
                ),
              )
            else
              Icon(trailingIcon, size: 15, color: trailingColor ?? color),
          ],
          if (onTap != null && onClose == null) ...[
            const SizedBox(width: 2),
            Icon(
              Icons.expand_more_rounded,
              size: 16,
              color: color.withValues(alpha: 0.7),
            ),
          ],
        ],
      ),
    );
    if (onTap != null) {
      pill = Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: pill,
        ),
      );
    }
    pill = Tooltip(message: tooltip, child: pill);
    final close = onClose;
    if (close == null) return pill;
    // Nút đóng tách khỏi vùng chạm của viên (chạm viên = mở chất lượng) và có
    // vùng chạm riêng 48 dp.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        pill,
        _PillCloseButton(onPressed: close, color: color),
      ],
    );
  }
}

/// Nút đóng tròn nhỏ (hình 28 dp) cạnh viên trạng thái, vùng chạm 48 dp.
class _PillCloseButton extends StatelessWidget {
  const _PillCloseButton({required this.onPressed, required this.color});

  final VoidCallback onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: appText(context, 'Đóng', 'Close'),
      child: Material(
        type: MaterialType.transparency,
        child: InkResponse(
          onTap: onPressed,
          radius: 22,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: const Color(0x8C080D18),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0x24FFFFFF)),
                ),
                child: Icon(
                  Icons.close_rounded,
                  size: 15,
                  color: color.withValues(alpha: 0.8),
                ),
              ),
            ),
          ),
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
      color = BrandColors.successSoft;
      icon = Icons.ac_unit_rounded;
      label = appText(context, 'Đã mát · nâng chất lượng', 'Cool · raise quality');
      tooltip = appText(
        context,
        'Máy đã mát. Chạm để chọn lại chất lượng.',
        'Device cooled down. Tap to choose quality.',
      );
    } else if (targetProfile != null) {
      final secs = (secondsUntil(widget.pendingAt, DateTime.now()) ?? 0).clamp(
        0,
        999,
      );
      color = BrandColors.warning;
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
        'Máy nóng: sẽ tự hạ xuống ${full(targetProfile)}. Chạm để chọn khác.',
        'Hot: lowering to ${full(targetProfile)}. Tap to choose another.',
      );
    } else if (isThrottled) {
      color = BrandColors.warning;
      icon = Icons.whatshot_rounded;
      label = withTemp(
        appText(context, 'giảm nhiệt', 'cooling'),
      );
      tooltip = appText(
        context,
        'Đã hạ xuống ${full(profile)} để giảm nhiệt. Chạm để chọn khác.',
        'Lowered to ${full(profile)} to cool down. Tap to choose another.',
      );
    } else if (userOverride || isLocked) {
      color = BrandColors.dangerSoft;
      icon = isLocked ? Icons.lock_rounded : Icons.thermostat_rounded;
      label = withTemp(appText(context, 'máy nóng', 'hot'));
      tooltip = appText(
        context,
        'Máy nóng, vẫn giữ ${full(profile)} theo lựa chọn của bạn.',
        'Hot, keeping ${full(profile)} as you chose.',
      );
    } else if (loadLevel >= 2) {
      color = BrandColors.warning;
      icon = Icons.whatshot_rounded;
      label = withTemp(appText(context, 'giảm tải', 'reducing load'));
      tooltip = appText(
        context,
        'Máy nóng: đã giảm FPS/bitrate, làm tối màn hình; giữ độ phân giải để Tablet và live không mất hình.',
        'Hot: FPS/bitrate reduced, screen dimmed; resolution kept so tablet and live stay on.',
      );
    } else {
      color = BrandColors.warningSoft;
      icon = Icons.thermostat_rounded;
      label = withTemp(appText(context, 'máy ấm', 'warm'));
      tooltip = appText(
        context,
        'Máy hơi ấm, đang theo dõi nhiệt độ.',
        'Device is warm; monitoring temperature.',
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

/// Viền đỏ quanh nút tròn của rail cho hành động nguy hiểm (tắt camera):
/// báo hiệu rõ mà không thành khối đỏ lớn. Viền chỉ bao hình tròn (không bao
/// nhãn bên dưới) và không bắt chạm.
class _DangerRing extends StatelessWidget {
  const _DangerRing({
    required this.enabled,
    required this.size,
    required this.child,
  });

  final bool enabled;
  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return Stack(
      alignment: Alignment.topCenter,
      children: [
        child,
        IgnorePointer(
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: BrandColors.danger.withValues(alpha: 0.9),
                width: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Menu chức năng: bảng kính nổi, mỗi ô một icon + nhãn ngắn. [columns] = 2
/// khi máy ngang thấp (xếp lưới 2 cột để không phải cuộn); [maxWidth] là bề
/// rộng vùng đặt menu (bảng không bao giờ rộng hơn).
class _QuickMenuPanel extends StatelessWidget {
  const _QuickMenuPanel({
    required this.tiles,
    this.columns = 1,
    this.maxWidth = double.infinity,
  });

  final List<Widget> tiles;
  final int columns;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    const gap = BrandSpace.sm;
    final desired = columns <= 1
        ? 224.0
        : columns * quickMenuGridTileWidth + (columns - 1) * gap;
    final width = math.max(
      0.0,
      math.min(desired, maxWidth - quickMenuHorizontalChrome),
    );
    final Widget content;
    if (columns <= 1) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: tiles,
      );
    } else {
      final rows = (tiles.length + columns - 1) ~/ columns;
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var r = 0; r < rows; r++)
            Row(
              children: [
                for (var c = 0; c < columns; c++) ...[
                  if (c > 0) const SizedBox(width: gap),
                  Expanded(
                    child: r * columns + c < tiles.length
                        ? tiles[r * columns + c]
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
        ],
      );
    }
    return BrandGlass(
      radius: BrandRadius.medium,
      padding: const EdgeInsets.all(6),
      child: SizedBox(width: width, child: content),
    );
  }
}

/// Một dòng trong menu: icon tròn nhỏ + nhãn; [trailing] tự xử lý chạm
/// (ví dụ nút chọn ngôn ngữ) thì cả dòng không bắt chạm. [dense] = dòng gọn
/// (cao 48) cho màn hình thấp.
class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.icon,
    required this.label,
    required this.tooltip,
    this.trailing,
    this.onTap,
    this.active = false,
    this.activeColor = BrandColors.primary,
    this.dense = false,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool active;
  final Color activeColor;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final circle = dense ? 32.0 : 36.0;
    final row = SizedBox(
      height: dense ? quickMenuDenseRowHeight : quickMenuRowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: BrandSpace.sm),
        child: Row(
          children: [
            Container(
              width: circle,
              height: circle,
              decoration: BoxDecoration(
                color: active ? activeColor : const Color(0x1FFFFFFF),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 20, color: Colors.white),
            ),
            SizedBox(width: dense ? BrandSpace.sm : BrandSpace.md),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: BrandText.body,
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
    if (trailing != null) return row;
    return Tooltip(
      message: tooltip,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(BrandRadius.small),
          onTap: onTap,
          child: row,
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
            padding: const EdgeInsets.all(BrandSpace.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Chỉ để xem: chạm vào đâu cũng là "xem lại hình".
                IgnorePointer(
                  child: Wrap(spacing: 6, runSpacing: 6, children: statusPills),
                ),
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(BrandSpace.lg),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const AppNoticeIcon(
                            icon: Icons.touch_app_rounded,
                            color: BrandColors.textSecondary,
                            size: 26,
                          ),
                          const SizedBox(height: BrandSpace.md),
                          Text(
                            appText(context, 'Chạm để xem hình', 'Tap to view'),
                            textAlign: TextAlign.center,
                            style: BrandText.title,
                          ),
                          const SizedBox(height: BrandSpace.xs),
                          Text(
                            appText(
                              context,
                              'Tạm ẩn hình để giảm nhiệt. Ghi hình, Tablet, live vẫn chạy.',
                              'Preview paused to cool down. Recording, tablet, live keep running.',
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: BrandText.caption,
                          ),
                        ],
                      ),
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
            'Kết nối Tablet…',
            'Connecting tablets…',
          )
        : connectedAddress == null
        ? appText(
            context,
            'Chưa có Wi-Fi. Vẫn ghi hình; Tablet cần Wi-Fi để kết nối.',
            'No Wi-Fi. Still recording; tablets need Wi-Fi to connect.',
          )
        : appText(
            context,
            hasError
                ? 'Lỗi kết nối Tablet. Vẫn đang ghi hình.'
                : 'Kết nối Tablet cần làm mới.',
            hasError
                ? 'Tablet connection error. Still recording.'
                : 'Tablet connection needs a refresh.',
          );
    return _CameraNotice(
      compact: compact,
      message: message,
      kind: recovering
          ? NoticeKind.info
          : hasError
          ? NoticeKind.error
          : NoticeKind.warning,
      icon: recovering ? null : Icons.wifi_off_rounded,
      loading: recovering,
      action: TextButton.icon(
        onPressed: onReconnect,
        icon: const Icon(Icons.sync_rounded, size: 17),
        label: Text(appText(context, 'Kết nối lại', 'Reconnect')),
      ),
    );
  }
}

/// Thông báo trạng thái trên khung camera (mạng, bộ nhớ, iOS…): cùng một
/// kiểu cho mọi thông báo: nền tối đặc, viền mảnh, icon theo loại.
class _CameraNotice extends StatelessWidget {
  const _CameraNotice({
    required this.compact,
    required this.message,
    this.kind = NoticeKind.info,
    this.icon,
    this.loading = false,
    this.action,
  });

  final bool compact;

  /// Nội dung đã dịch (dùng `appText`).
  final String message;
  final NoticeKind kind;
  final IconData? icon;

  /// Hiện vòng xoay thay cho icon (đang xử lý).
  final bool loading;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final color = kind.color;
    final horizontal = compact ? 10.0 : 12.0;
    final vertical = compact ? 6.0 : 8.0;
    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(bottom: compact ? 6 : 8),
      padding: EdgeInsets.fromLTRB(
        horizontal,
        vertical,
        action != null ? 6 : horizontal,
        vertical,
      ),
      decoration: BoxDecoration(
        color: BrandColors.surfaceOverlay,
        borderRadius: BorderRadius.circular(
          compact ? BrandRadius.small : 12,
        ),
        border: Border.all(color: BrandColors.border),
      ),
      child: Row(
        children: [
          if (loading)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            )
          else
            Icon(icon ?? kind.icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: compact ? 2 : 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: BrandColors.textPrimary,
                fontSize: compact ? 11 : 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          ?action,
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
      padding: const EdgeInsets.symmetric(vertical: BrandSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(title, style: BrandText.caption),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: BrandText.body.copyWith(fontSize: 13),
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
    return _StatusPill(
      loading: true,
      color: BrandColors.textSecondary,
      label: seconds > 0
          ? appText(
              context,
              'Tự thử lại sau ${seconds}s',
              'Auto-retry in ${seconds}s',
            )
          : appText(context, 'Đang tự thử lại…', 'Retrying…'),
      tooltip: appText(
        context,
        'Camera Station tự thử khởi động lại',
        'Camera Station retries automatically',
      ),
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
    final nameLine = _ConfigLine(
      title: appText(context, 'Tên', 'Name'),
      value: identity.cameraName,
    );
    final cameraLine = _ConfigLine(title: 'Camera', value: identity.cameraId);
    final courtLine = _ConfigLine(
      title: appText(context, 'Sân', 'Court'),
      value: courtLabel,
    );
    final identityDetails = landscape
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [nameLine, cameraLine],
                ),
              ),
              const SizedBox(width: BrandSpace.lg),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [courtLine],
                ),
              ),
            ],
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [nameLine, cameraLine, courtLine],
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
      icon: AppNoticeIcon(
        icon: Icons.settings_rounded,
        color: BrandColors.info,
        size: compactHeight ? 22 : 28,
      ),
      title: Text(
        appText(context, 'Áp dụng cấu hình mới?', 'Apply new settings?'),
        textAlign: TextAlign.center,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            appText(
              context,
              'Camera Station sẽ khởi động lại.',
              'Camera Station will restart.',
            ),
            textAlign: TextAlign.center,
            style: BrandText.caption.copyWith(fontSize: 14),
          ),
          if (interruptsCapture) ...[
            SizedBox(height: compactHeight ? 6 : 10),
            AppNoticeBanner(
              dense: compactHeight,
              kind: NoticeKind.warning,
              message: appText(
                context,
                'Ghi hình và live sẽ gián đoạn vài giây khi khởi động lại.',
                'Recording and live will pause for a few seconds.',
              ),
            ),
          ],
          SizedBox(height: compactHeight ? 8 : 14),
          Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(
              horizontal: BrandSpace.md,
              vertical: compactHeight ? 6 : 10,
            ),
            decoration: BoxDecoration(
              color: BrandColors.surfaceRaised,
              borderRadius: BorderRadius.circular(BrandRadius.medium),
              border: Border.all(color: BrandColors.border),
            ),
            child: identityDetails,
          ),
        ],
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(context, false);
          },
          style: TextButton.styleFrom(
            foregroundColor: BrandColors.textSecondary,
          ),
          child: Text(appText(context, 'Huỷ', 'Cancel')),
        ),
        FilledButton.icon(
          onPressed: () {
            Navigator.pop(context, true);
          },
          icon: const Icon(Icons.check_rounded),
          label: Text(appText(context, 'Áp dụng', 'Apply')),
        ),
      ],
    );
  }
}

/// Màn hình chờ khi Camera Station đang khởi động: logo, vòng xoay mảnh,
/// một dòng chữ.
class _StationLoadingView extends StatelessWidget {
  const _StationLoadingView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrandColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(BrandSpace.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  'assets/images/vnvar_logo.png',
                  width: 200,
                  height: 48,
                  fit: BoxFit.contain,
                ),
                const SizedBox(height: BrandSpace.xl),
                const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    color: BrandColors.primaryBright,
                    strokeWidth: 2.4,
                  ),
                ),
                const SizedBox(height: BrandSpace.lg),
                Text(
                  appText(
                    context,
                    'Đang khởi động camera…',
                    'Starting camera…',
                  ),
                  textAlign: TextAlign.center,
                  style: BrandText.caption.copyWith(fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Màn lỗi khởi động: icon lớn, tiêu đề 1 dòng, mô tả ngắn, nút chính
/// "Thử lại" (+ "Mở Cài đặt" khi thiếu quyền). Lỗi khác có lịch tự thử lại
/// thì hiện đếm ngược và nút "Thử lại ngay".
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
    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(BrandRadius.medium),
    );
    final retryButton = FilledButton.icon(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        shape: buttonShape,
      ),
      onPressed: onRetry,
      icon: const Icon(Icons.refresh_rounded),
      label: Text(
        retryAt != null && !permissionError
            ? appText(context, 'Thử lại ngay', 'Retry now')
            : appText(context, 'Thử lại', 'Try again'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
    final settingsButton = OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: BrandColors.textPrimary,
        minimumSize: const Size.fromHeight(48),
        side: const BorderSide(color: BrandColors.border),
        shape: buttonShape,
      ),
      onPressed: onOpenSettings,
      icon: const Icon(Icons.settings_rounded),
      label: Text(
        appText(context, 'Mở Cài đặt', 'Open Settings'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
    return Scaffold(
      backgroundColor: BrandColors.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Màn ngang/rộng: hai nút cạnh nhau cho đỡ cao.
            final sideBySide = constraints.maxWidth >= 520;
            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: BrandSpace.xl,
                  vertical: BrandSpace.lg,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppNoticeIcon(
                        icon: permissionError
                            ? Icons.no_photography_rounded
                            : Icons.videocam_off_rounded,
                        color: BrandColors.danger,
                        size: 36,
                      ),
                      const SizedBox(height: BrandSpace.lg),
                      Text(
                        permissionError
                            ? appText(
                                context,
                                'Cần quyền Camera/Micro',
                                'Camera/Mic permission needed',
                              )
                            : appText(
                                context,
                                'Không khởi động được camera',
                                'Camera failed to start',
                              ),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: BrandText.title,
                      ),
                      const SizedBox(height: BrandSpace.sm),
                      Text(
                        permissionError
                            ? appText(
                                context,
                                'Bật Camera và Micro trong Cài đặt rồi quay lại.',
                                'Allow Camera and Mic in Settings, then come back.',
                              )
                            : message,
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: BrandText.caption.copyWith(
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                      if (permissionError) ...[
                        const SizedBox(height: BrandSpace.xs),
                        // Lý do gốc (đã dịch) ở dạng phụ, một dòng.
                        Tooltip(
                          message: message,
                          child: Text(
                            message,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: BrandText.caption.copyWith(
                              color: BrandColors.textDisabled,
                            ),
                          ),
                        ),
                      ] else if (retryAt != null) ...[
                        const SizedBox(height: BrandSpace.md),
                        _RetryCountdownText(target: retryAt),
                      ],
                      const SizedBox(height: BrandSpace.xl),
                      if (!permissionError)
                        retryButton
                      else if (sideBySide)
                        Row(
                          children: [
                            Expanded(child: retryButton),
                            const SizedBox(width: BrandSpace.md),
                            Expanded(child: settingsButton),
                          ],
                        )
                      else ...[
                        retryButton,
                        const SizedBox(height: BrandSpace.sm),
                        settingsButton,
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
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

  static Widget _badge({
    required Widget child,
    Color? background,
    Color? border,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background ?? const Color(0x8C080D18),
        borderRadius: BorderRadius.circular(999),
        border: border == null ? null : Border.all(color: border),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    const badgeText = TextStyle(
      color: Colors.white,
      fontSize: 9,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.4,
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (recording)
              _badge(
                background: BrandColors.live,
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, color: Colors.white, size: 6),
                    SizedBox(width: 3),
                    Text('REC', style: badgeText),
                  ],
                ),
              ),
            if (recording && live) const SizedBox(width: 4),
            if (live)
              _badge(
                background: BrandColors.live,
                child: const Text('LIVE', style: badgeText),
              ),
          ],
        ),
        if (thermalWarning)
          _badge(
            border: BrandColors.warning.withValues(alpha: 0.7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.thermostat_rounded,
                  color: BrandColors.warning,
                  size: 10,
                ),
                const SizedBox(width: 3),
                Text(
                  profileText,
                  style: badgeText.copyWith(color: BrandColors.warning),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
