import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Bộ thành phần giao diện dùng chung (phong cách "bảng điều khiển phát sóng":
/// tối, gọn, icon + nhãn ngắn). Mọi màn hình dùng các widget này để đồng nhất.
///
/// Khoảng cách chuẩn: 4 / 8 / 12 / 16 / 24. Chữ: tiêu đề 17 w700, thân 14 w500,
/// phụ 12 textSecondary. Nút chạm tối thiểu 48 dp.
abstract final class BrandSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
}

abstract final class BrandText {
  static const title = TextStyle(
    color: BrandColors.textPrimary,
    fontSize: 17,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.1,
  );
  static const body = TextStyle(
    color: BrandColors.textPrimary,
    fontSize: 14,
    fontWeight: FontWeight.w500,
  );
  static const caption = TextStyle(
    color: BrandColors.textSecondary,
    fontSize: 12,
    fontWeight: FontWeight.w500,
  );
  static const label = TextStyle(
    color: BrandColors.textSecondary,
    fontSize: 11,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.8,
  );
}

/// Lớp nền tối bán trong suốt đặt trên hình camera (thanh trạng thái, cụm nút,
/// bảng zoom). Cố ý KHÔNG làm mờ nền (BackdropFilter): vẽ lại mỗi khung camera
/// tốn GPU và làm máy nóng khi chạy nhiều giờ.
class BrandGlass extends StatelessWidget {
  const BrandGlass({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(BrandSpace.sm),
    this.radius = BrandRadius.large,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xB3080D18),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: const Color(0x24FFFFFF)),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// Nút tròn icon (48–56 dp) dùng trên màn camera và thanh công cụ.
/// [active]: đang bật (nền xanh thương hiệu); [danger]: hành động nguy hiểm
/// (nền đỏ); [label]: nhãn rất ngắn dưới nút (tuỳ chọn).
class BrandIconButton extends StatelessWidget {
  const BrandIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.label,
    this.active = false,
    this.danger = false,
    this.loading = false,
    this.size = 52,
    this.glass = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final String? label;
  final bool active;
  final bool danger;
  final bool loading;
  final double size;
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    final Color background;
    if (danger) {
      background = BrandColors.danger;
    } else if (active) {
      background = BrandColors.primary;
    } else {
      background = glass ? const Color(0x66000000) : BrandColors.surfaceRaised;
    }
    final foreground = enabled ? Colors.white : BrandColors.textDisabled;
    final circle = Tooltip(
      message: tooltip,
      child: Material(
        color: background,
        shape: CircleBorder(
          side: BorderSide(
            color: active || danger
                ? Colors.transparent
                : const Color(0x33FFFFFF),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onPressed : null,
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: loading
                  ? SizedBox(
                      width: size * 0.38,
                      height: size * 0.38,
                      child: const CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(icon, color: foreground, size: size * 0.44),
            ),
          ),
        ),
      ),
    );
    final text = label;
    if (text == null) return circle;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        circle,
        const SizedBox(height: BrandSpace.xs),
        Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            shadows: [Shadow(color: Colors.black87, blurRadius: 4)],
          ),
        ),
      ],
    );
  }
}

/// Viên trạng thái nhỏ: chấm/icon màu + chữ ngắn (REC 00:12, LIVE, 1080p·30,
/// 38°C, 2 tablet...). [onTap] tuỳ chọn.
class BrandPill extends StatelessWidget {
  const BrandPill({
    super.key,
    required this.text,
    this.icon,
    this.color = BrandColors.textPrimary,
    this.dot = false,
    this.filled = false,
    this.onTap,
    this.tooltip,
  });

  final String text;
  final IconData? icon;
  final Color color;

  /// Chấm tròn màu [color] thay cho icon (kiểu đèn REC).
  final bool dot;

  /// Nền đặc màu [color] (chữ trắng) — dùng cho REC/LIVE đang chạy.
  final bool filled;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final foreground = filled ? Colors.white : color;
    Widget pill = Container(
      constraints: const BoxConstraints(minHeight: 32),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: filled ? color : const Color(0x8C080D18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: filled ? Colors.transparent : const Color(0x24FFFFFF),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot)
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: filled ? Colors.white : color,
                shape: BoxShape.circle,
              ),
            )
          else if (icon != null)
            Icon(icon, size: 16, color: foreground),
          if (dot || icon != null) const SizedBox(width: 6),
          Text(
            text,
            maxLines: 1,
            style: TextStyle(
              color: foreground,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
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
    final tip = tooltip;
    return tip == null ? pill : Tooltip(message: tip, child: pill);
  }
}

/// Thẻ nhóm nội dung cho các màn cài đặt / kho video: tiêu đề nhỏ viết hoa
/// phía trên, khối nền surface bo góc, các dòng con ngăn bằng đường mảnh.
class BrandSection extends StatelessWidget {
  const BrandSection({
    super.key,
    this.title,
    this.trailing,
    required this.children,
    this.padding = EdgeInsets.zero,
  });

  final String? title;
  final Widget? trailing;
  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final heading = title;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (heading != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, BrandSpace.sm),
            child: Row(
              children: [
                Expanded(
                  child: Text(heading.toUpperCase(), style: BrandText.label),
                ),
                ?trailing,
              ],
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: BrandColors.surface,
            borderRadius: BorderRadius.circular(BrandRadius.medium),
            border: Border.all(color: BrandColors.border),
          ),
          child: Padding(
            padding: padding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    const Divider(
                      height: 1,
                      thickness: 1,
                      indent: BrandSpace.lg,
                      endIndent: BrandSpace.lg,
                      color: BrandColors.border,
                    ),
                  children[i],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Một dòng trong [BrandSection]: icon trong ô vuông bo góc + tiêu đề + mô tả
/// ngắn + phần đuôi (switch, giá trị, mũi tên).
class BrandTile extends StatelessWidget {
  const BrandTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.iconColor = BrandColors.primaryBright,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    final sub = subtitle;
    // Material riêng (trong suốt): nền surface của BrandSection là DecoratedBox
    // nên hiệu ứng chạm vẽ trên Material tổ tiên (Scaffold) sẽ bị che mất.
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(BrandRadius.medium),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: BrandSpace.lg,
              vertical: BrandSpace.md,
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(BrandRadius.small),
                  ),
                  child: Icon(icon, color: iconColor, size: 20),
                ),
                const SizedBox(width: BrandSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, style: BrandText.body),
                      if (sub != null) ...[
                        const SizedBox(height: 2),
                        Text(sub, style: BrandText.caption),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: BrandSpace.sm),
                  trailing!,
                ] else if (onTap != null)
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: BrandColors.textDisabled,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Lựa chọn dạng viên (segmented) — dùng cho zoom 1×/2×/5×, chế độ xoay,
/// độ dài đoạn ghi... [selected] là chỉ số đang chọn (null = không chọn).
class BrandSegmented<T> extends StatelessWidget {
  const BrandSegmented({
    super.key,
    required this.values,
    required this.labelOf,
    required this.selected,
    required this.onChanged,
    this.dense = false,
  });

  final List<T> values;
  final String Function(T value) labelOf;
  final T? selected;
  final ValueChanged<T>? onChanged;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0x66000000),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x24FFFFFF)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final value in values)
            _segment(value, value == selected),
        ],
      ),
    );
  }

  Widget _segment(T value, bool isSelected) {
    final callback = onChanged;
    return Material(
      color: isSelected ? BrandColors.primary : Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: callback == null ? null : () => callback(value),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: dense ? 40 : 48,
            minHeight: dense ? 36 : 42,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(
              widthFactor: 1,
              child: Text(
                labelOf(value),
                style: TextStyle(
                  color: isSelected ? Colors.white : BrandColors.textSecondary,
                  fontSize: dense ? 13 : 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Trạng thái rỗng / chưa có dữ liệu: icon lớn mờ + một dòng chữ + nút tuỳ chọn.
class BrandEmptyState extends StatelessWidget {
  const BrandEmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(BrandSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: BrandColors.textDisabled),
            const SizedBox(height: BrandSpace.md),
            Text(
              message,
              textAlign: TextAlign.center,
              style: BrandText.caption.copyWith(fontSize: 14),
            ),
            if (action != null) ...[
              const SizedBox(height: BrandSpace.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
