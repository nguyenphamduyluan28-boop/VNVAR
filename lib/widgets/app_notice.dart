import 'package:flutter/material.dart';

import '../services/app_language_service.dart';
import '../theme/app_theme.dart';

/// Loại thông báo: quyết định icon và màu nhấn.
enum NoticeKind { info, success, warning, error }

extension NoticeKindStyle on NoticeKind {
  Color get color => switch (this) {
        NoticeKind.info => BrandColors.info,
        NoticeKind.success => BrandColors.success,
        NoticeKind.warning => BrandColors.warning,
        NoticeKind.error => BrandColors.danger,
      };

  IconData get icon => switch (this) {
        NoticeKind.info => Icons.info_rounded,
        NoticeKind.success => Icons.check_circle_rounded,
        NoticeKind.warning => Icons.warning_amber_rounded,
        NoticeKind.error => Icons.error_rounded,
      };
}

/// Lề màn hình của SnackBar nổi.
const double _noticeGutter = 16;

/// Thông báo nổi (SnackBar) chuẩn của app: một dòng ngắn, có icon theo loại,
/// song ngữ. Thay thế mọi `ScaffoldMessenger.showSnackBar` tự dựng.
///
/// [vi]/[en]: nội dung ngắn (nên ≤ 60 ký tự). [actionVi]/[actionEn] + [onAction]:
/// nút hành động tuỳ chọn (vd "Thử lại" / "Retry").
void showAppNotice(
  BuildContext context, {
  required String vi,
  required String en,
  NoticeKind kind = NoticeKind.info,
  String? actionVi,
  String? actionEn,
  VoidCallback? onAction,
  Duration? duration,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final english = AppLanguageScope.of(context).isEnglish;
  final text = english ? en : vi;
  final actionLabel = english ? actionEn : actionVi;
  // Scaffold đặt SnackBar nổi phía trên phần đệm đáy (thanh điều hướng hệ
  // thống); chỉ cần cộng thêm phần đệm hai bên (tai thỏ khi xoay ngang).
  final safe = MediaQuery.maybeViewPaddingOf(context) ?? EdgeInsets.zero;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        // margin chỉ hợp lệ với SnackBar nổi: đặt rõ để không phụ thuộc theme
        // (vd test/MaterialApp không dùng buildAppTheme()).
        behavior: SnackBarBehavior.floating,
        duration: duration ??
            (kind == NoticeKind.error
                ? const Duration(seconds: 5)
                : const Duration(seconds: 3)),
        margin: EdgeInsets.fromLTRB(
          _noticeGutter + safe.left,
          0,
          _noticeGutter + safe.right,
          _noticeGutter,
        ),
        padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
        backgroundColor: BrandColors.surfaceRaised,
        elevation: 3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(BrandRadius.medium),
          side: BorderSide(color: kind.color.withValues(alpha: 0.28)),
        ),
        content: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: kind.color.withValues(alpha: 0.16),
                shape: BoxShape.circle,
              ),
              child: Icon(kind.icon, color: kind.color, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: BrandColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
        action: actionLabel != null && onAction != null
            ? SnackBarAction(
                label: actionLabel,
                textColor: BrandColors.primarySoft,
                onPressed: onAction,
              )
            : null,
      ),
    );
}

/// Hộp thoại xác nhận chuẩn: icon tròn, tiêu đề ngắn, mô tả 1–2 dòng, hai nút.
/// Trả `true` khi người dùng bấm nút xác nhận.
Future<bool> showAppConfirm(
  BuildContext context, {
  required String titleVi,
  required String titleEn,
  String? messageVi,
  String? messageEn,
  required String confirmVi,
  required String confirmEn,
  String cancelVi = 'Huỷ',
  String cancelEn = 'Cancel',
  IconData? icon,
  NoticeKind kind = NoticeKind.info,
  bool destructive = false,
  bool barrierDismissible = true,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (dialogContext) {
      String t(String vi, String en) => appText(dialogContext, vi, en);
      final accent = destructive ? BrandColors.danger : kind.color;
      final message = messageVi != null && messageEn != null
          ? t(messageVi, messageEn)
          : null;
      return _AppDialog(
        icon: icon ?? kind.icon,
        accent: accent,
        title: t(titleVi, titleEn),
        message: message,
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            style: OutlinedButton.styleFrom(
              foregroundColor: BrandColors.textPrimary,
            ),
            child: _ButtonLabel(t(cancelVi, cancelEn)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: BrandColors.danger,
                    foregroundColor: Colors.white,
                  )
                : null,
            child: _ButtonLabel(t(confirmVi, confirmEn)),
          ),
        ],
      );
    },
  );
  return result == true;
}

/// Hộp thoại chỉ báo tin (một nút Đóng/OK).
Future<void> showAppMessage(
  BuildContext context, {
  required String titleVi,
  required String titleEn,
  String? messageVi,
  String? messageEn,
  NoticeKind kind = NoticeKind.info,
  IconData? icon,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      String t(String vi, String en) => appText(dialogContext, vi, en);
      final message = messageVi != null && messageEn != null
          ? t(messageVi, messageEn)
          : null;
      return _AppDialog(
        icon: icon ?? kind.icon,
        accent: kind.color,
        title: t(titleVi, titleEn),
        message: message,
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: _ButtonLabel(t('Đã hiểu', 'Got it')),
          ),
        ],
      );
    },
  );
}

/// Khung hộp thoại chung: icon tròn, tiêu đề 17 w700 căn giữa, mô tả căn giữa,
/// các nút chia đều bề rộng. Cuộn được khi màn hình thấp (điện thoại ngang).
class _AppDialog extends StatelessWidget {
  const _AppDialog({
    required this.icon,
    required this.accent,
    required this.title,
    required this.message,
    required this.actions,
  });

  final IconData icon;
  final Color accent;
  final String title;
  final String? message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final body = message;
    return Dialog(
      backgroundColor: BrandColors.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BrandRadius.large),
        side: const BorderSide(color: BrandColors.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(child: AppNoticeIcon(icon: icon, color: accent, size: 26)),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: BrandColors.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
              ),
              if (body != null) ...[
                const SizedBox(height: 8),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: BrandColors.textSecondary,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              Row(
                children: [
                  for (var i = 0; i < actions.length; i++) ...[
                    if (i > 0) const SizedBox(width: 12),
                    Expanded(child: actions[i]),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ButtonLabel extends StatelessWidget {
  const _ButtonLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
    );
  }
}

/// Icon tròn có nền nhạt theo màu trạng thái, dùng đầu hộp thoại/thẻ.
class AppNoticeIcon extends StatelessWidget {
  const AppNoticeIcon({
    super.key,
    required this.icon,
    required this.color,
    this.size = 28,
  });

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(size * 0.45),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Icon(icon, color: color, size: size),
    );
  }
}

/// Dải thông báo gắn trong trang (thay cho Container màu tự dựng): icon + một
/// dòng chữ + nút hành động tuỳ chọn.
class AppNoticeBanner extends StatelessWidget {
  const AppNoticeBanner({
    super.key,
    required this.message,
    this.kind = NoticeKind.info,
    this.icon,
    this.action,
    this.dense = false,
  });

  /// Nội dung đã dịch (dùng `appText`).
  final String message;
  final NoticeKind kind;
  final IconData? icon;
  final Widget? action;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final color = kind.color;
    return Container(
      padding: EdgeInsets.fromLTRB(
        dense ? 8 : 10,
        dense ? 6 : 10,
        12,
        dense ? 6 : 10,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(BrandRadius.small),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          Container(
            width: dense ? 26 : 30,
            height: dense ? 26 : 30,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              shape: BoxShape.circle,
            ),
            child: Icon(icon ?? kind.icon, color: color, size: dense ? 15 : 17),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: BrandColors.textPrimary,
                fontSize: dense ? 12.5 : 13.5,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
          ),
          if (action != null) ...[const SizedBox(width: 8), action!],
        ],
      ),
    );
  }
}
