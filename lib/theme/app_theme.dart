import 'package:flutter/material.dart';

/// Bảng màu thương hiệu SportO-Cam / VNVAR. Mọi màn hình dùng các token này
/// thay vì mã màu rời rạc, để giao diện tối đồng nhất và dễ chỉnh một chỗ.
abstract final class BrandColors {
  // Thương hiệu
  static const primary = Color(0xFF1565C0);
  static const primaryBright = Color(0xFF42A5F5);
  static const primarySoft = Color(0xFF90CAF9);

  // Nền tối (từ sâu tới nổi)
  static const background = Color(0xFF0B1220);
  static const surface = Color(0xFF111A2B);
  static const surfaceRaised = Color(0xFF16223A);
  static const surfaceOverlay = Color(0xEB0A101C);
  static const border = Color(0x1FFFFFFF);

  // Chữ
  static const textPrimary = Color(0xFFF1F5F9);
  static const textSecondary = Color(0xFF94A3B8);
  static const textDisabled = Color(0xFF64748B);

  // Trạng thái
  static const success = Color(0xFF00C853);
  static const successSoft = Color(0xFF69F0AE);
  static const warning = Color(0xFFFFA726);
  static const warningSoft = Color(0xFFFFCC80);
  static const danger = Color(0xFFE53935);
  static const dangerSoft = Color(0xFFFF8A80);
  static const info = primaryBright;

  /// Đỏ "REC" / "LIVE".
  static const live = Color(0xFFE53935);
}

/// Bo góc / khoảng cách dùng chung.
abstract final class BrandRadius {
  static const small = 10.0;
  static const medium = 14.0;
  static const large = 20.0;
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: BrandColors.primary,
    brightness: Brightness.dark,
  ).copyWith(
    primary: BrandColors.primaryBright,
    onPrimary: Colors.white,
    primaryContainer: BrandColors.primary,
    onPrimaryContainer: Colors.white,
    secondary: BrandColors.primarySoft,
    surface: BrandColors.surface,
    onSurface: BrandColors.textPrimary,
    onSurfaceVariant: BrandColors.textSecondary,
    surfaceContainerHighest: BrandColors.surfaceRaised,
    surfaceContainerHigh: BrandColors.surfaceRaised,
    surfaceContainer: BrandColors.surface,
    surfaceContainerLow: BrandColors.surface,
    outline: BrandColors.border,
    outlineVariant: BrandColors.border,
    error: BrandColors.danger,
    onError: Colors.white,
  );
  final roundedMedium = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(BrandRadius.medium),
  );
  final roundedSmall = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(BrandRadius.small),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: BrandColors.background,
    canvasColor: BrandColors.background,
    dividerColor: BrandColors.border,
    appBarTheme: const AppBarThemeData(
      backgroundColor: BrandColors.background,
      foregroundColor: BrandColors.textPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: BrandColors.textPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      color: BrandColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BrandRadius.medium),
        side: const BorderSide(color: BrandColors.border),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: BrandColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BrandRadius.large),
        side: const BorderSide(color: BrandColors.border),
      ),
      titleTextStyle: const TextStyle(
        color: BrandColors.textPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w700,
      ),
      contentTextStyle: const TextStyle(
        color: BrandColors.textSecondary,
        fontSize: 14,
        height: 1.4,
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: BrandColors.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: BrandColors.textDisabled,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(BrandRadius.large),
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: BrandColors.surfaceRaised,
      contentTextStyle: const TextStyle(
        color: BrandColors.textPrimary,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
      actionTextColor: BrandColors.primarySoft,
      shape: roundedMedium,
      elevation: 6,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: BrandColors.primary,
        foregroundColor: Colors.white,
        minimumSize: const Size(48, 48),
        shape: roundedSmall,
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: BrandColors.primary,
        foregroundColor: Colors.white,
        minimumSize: const Size(48, 48),
        shape: roundedSmall,
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: BrandColors.primarySoft,
        side: const BorderSide(color: BrandColors.border),
        minimumSize: const Size(48, 48),
        shape: roundedSmall,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: BrandColors.primarySoft,
        minimumSize: const Size(48, 48),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: BrandColors.surfaceRaised,
      labelStyle: const TextStyle(color: BrandColors.textSecondary),
      hintStyle: const TextStyle(color: BrandColors.textDisabled),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(BrandRadius.small),
        borderSide: const BorderSide(color: BrandColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(BrandRadius.small),
        borderSide: const BorderSide(color: BrandColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(BrandRadius.small),
        borderSide: const BorderSide(color: BrandColors.primaryBright, width: 1.5),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.white
            : BrandColors.textSecondary,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? BrandColors.primary
            : BrandColors.surfaceRaised,
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: BrandColors.primaryBright,
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: BrandColors.primarySoft,
      textColor: BrandColors.textPrimary,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: BrandColors.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      shape: roundedMedium,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: BrandColors.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: BrandColors.border),
      ),
      textStyle: const TextStyle(color: BrandColors.textPrimary, fontSize: 12),
    ),
  );
}
