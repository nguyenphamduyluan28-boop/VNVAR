part of '../station_screen.dart';

class _BottomControlPanel extends StatelessWidget {
  const _BottomControlPanel({
    required this.compact,
    required this.cameraReady,
    required this.recording,
    required this.zoomSupported,
    required this.zoomValue,
    required this.minimumZoom,
    required this.maximumZoom,
    required this.hasUltraWide,
    required this.ultraWideRatio,
    required this.ultraWideLabel,
    required this.onZoomChanged,
    required this.onQuickSelectZoom,
    required this.exposureEv,
    required this.onExposureChanged,
    this.zoomEnabled = true,
  });

  final bool compact;
  final double exposureEv;
  final ValueChanged<double> onExposureChanged;
  final bool cameraReady;
  final bool recording;
  final bool zoomSupported;
  final double zoomValue;
  final double minimumZoom;
  final double maximumZoom;
  final bool hasUltraWide;
  final double ultraWideRatio;
  final String ultraWideLabel;
  final ValueChanged<double> onZoomChanged;
  final ValueChanged<double> onQuickSelectZoom;

  /// false: khoá thanh trượt, nút bước và nút nhanh (đang đổi camera).
  final bool zoomEnabled;

  @override
  Widget build(BuildContext context) {
    // Camera chưa sẵn sàng: không có zoom hay độ sáng để chỉnh, ẩn hẳn khung.
    if (!cameraReady && !zoomSupported) return const SizedBox.shrink();
    // Cùng kiểu nền với thanh trạng thái/menu; không làm mờ nền (đỡ tốn GPU).
    return ClipRRect(
      borderRadius: BorderRadius.circular(compact ? 18 : 20),
      child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 10,
            vertical: compact ? 4 : 6,
          ),
          decoration: BoxDecoration(
            color: _glassColor,
            borderRadius: BorderRadius.circular(compact ? 18 : 20),
            border: Border.all(color: _glassBorder),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (zoomSupported) ...[
                _CameraZoomSlider(
                  compact: compact,
                  value: zoomValue,
                  minimum: minimumZoom,
                  maximum: maximumZoom,
                  hasUltraWide: hasUltraWide,
                  ultraWideRatio: ultraWideRatio,
                  ultraWideLabel: ultraWideLabel,
                  enabled: zoomEnabled,
                  onChanged: onZoomChanged,
                  onQuickSelect: onQuickSelectZoom,
                ),
                Container(
                  height: 1,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  color: Colors.white.withValues(alpha: 0.09),
                ),
              ],
              if (cameraReady)
                _BrightnessControl(
                  compact: compact,
                  ev: exposureEv,
                  onChanged: onExposureChanged,
                ),
            ],
          ),
        ),
    );
  }
}

/// Nút chỉnh độ sáng hình cho người dùng phổ thông: "Tối hơn / Tự động /
/// Sáng hơn", mỗi bước 0,5 EV, từ −1 tới +2.
class _BrightnessControl extends StatelessWidget {
  const _BrightnessControl({
    required this.compact,
    required this.ev,
    required this.onChanged,
  });

  static const double _step = 0.5;
  static const double _min = -1.0;
  static const double _max = 2.0;

  final bool compact;
  final double ev;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final label = ev.abs() < 0.01
        ? appText(context, 'Tự động', 'Auto')
        : ev > 0
        ? appText(
            context,
            'Sáng hơn +${ev.toStringAsFixed(1)}',
            'Brighter +${ev.toStringAsFixed(1)}',
          )
        : appText(
            context,
            'Tối hơn ${ev.toStringAsFixed(1)}',
            'Darker ${ev.toStringAsFixed(1)}',
          );
    Widget button(IconData icon, double next, bool enabled, String tooltip) {
      // Vùng chạm tối thiểu 48dp; biểu tượng giữ nguyên kích thước.
      return Tooltip(
        message: tooltip,
        child: InkResponse(
          radius: 20,
          onTap: enabled ? () => onChanged(next) : null,
          child: SizedBox(
            width: kMinInteractiveDimension,
            height: kMinInteractiveDimension,
            child: Icon(
              icon,
              size: 17,
              color: enabled ? Colors.white : Colors.white24,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          const Icon(
            Icons.wb_sunny_rounded,
            size: 15,
            color: Colors.amberAccent,
          ),
          const SizedBox(width: 6),
          Text(
            appText(context, 'Độ sáng', 'Brightness'),
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          button(
            Icons.remove_rounded,
            ev - _step,
            ev > _min + 0.01,
            appText(context, 'Tối hơn', 'Darker'),
          ),
          SizedBox(
            width: 92,
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          button(
            Icons.add_rounded,
            ev + _step,
            ev < _max - 0.01,
            appText(context, 'Sáng hơn', 'Brighter'),
          ),
        ],
      ),
    );
  }
}

class _CameraZoomSlider extends StatelessWidget {
  const _CameraZoomSlider({
    required this.compact,
    required this.value,
    required this.minimum,
    required this.maximum,
    required this.hasUltraWide,
    required this.ultraWideRatio,
    required this.ultraWideLabel,
    required this.onChanged,
    required this.onQuickSelect,
    this.enabled = true,
  });

  final bool compact;
  final double value;
  final double minimum;
  final double maximum;
  final bool hasUltraWide;
  final double ultraWideRatio;
  final String ultraWideLabel;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onQuickSelect;
  final bool enabled;

  /// Bề rộng tối thiểu dành cho thanh trượt khi tính vùng chạm nút nhanh.
  static const double _minSliderWidth = 96;

  @override
  Widget build(BuildContext context) {
    final effectiveMin = hasUltraWide
        ? math.min(ultraWideRatio, minimum)
        : minimum.clamp(1.0, 5.0);
    final effectiveMax = math.min(maximum, 5.0).clamp(effectiveMin + 0.1, 5.0);
    final safeValue = value.clamp(effectiveMin, effectiveMax).toDouble();

    void stepZoom(double delta) {
      final raw = safeValue + delta;
      final stepped = (raw * 10).round() / 10.0;
      final clamped = stepped.clamp(effectiveMin, effectiveMax).toDouble();
      onChanged(clamped);
    }

    final canDecrease = enabled && safeValue > (effectiveMin + 0.04);
    final canIncrease = enabled && safeValue < (effectiveMax - 0.04);

    VoidCallback? quickSelect(double target) =>
        enabled ? () => onQuickSelect(target) : null;

    Widget buildStepButton({
      required IconData icon,
      required String tooltip,
      required VoidCallback? onTap,
    }) {
      final enabled = onTap != null;
      // Vùng chạm 48dp, hình tròn hiển thị vẫn 28dp.
      return Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: kMinInteractiveDimension,
              height: kMinInteractiveDimension,
              child: Center(
                child: Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: enabled
                        ? Colors.white.withValues(alpha: 0.12)
                        : Colors.white.withValues(alpha: 0.04),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: enabled
                          ? Colors.white.withValues(alpha: 0.22)
                          : Colors.white.withValues(alpha: 0.06),
                      width: 1,
                    ),
                  ),
                  child: Icon(
                    icon,
                    color: enabled ? Colors.white : Colors.white24,
                    size: 16,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    // Một hàng gọn: [nút nhanh] [−] [thanh trượt] [+] [giá trị]. Máy hẹp
    // (dọc ~360px) bỏ ô giá trị để thanh trượt đủ dài.
    return LayoutBuilder(
      builder: (context, constraints) {
        final showValue = constraints.maxWidth >= 360;
        // Vùng chạm nút nhanh: cao 48dp; rộng 48dp khi đủ chỗ, máy hẹp thì
        // co lại (không nhỏ hơn hình hiển thị) để thanh trượt vẫn còn
        // ≥ [_minSliderWidth]. Các vùng chạm sát nhau nên không có khe chết.
        final presetCount = hasUltraWide ? 4 : 3;
        final presetBudget =
            constraints.maxWidth -
            4 - // padding ngang của hàng
            2 - // khoảng cách trước nút [−]
            2 * kMinInteractiveDimension - // nút [−] và [+]
            (showValue ? 38 : 0) -
            _minSliderWidth;
        final presetTapWidth = (presetBudget / presetCount)
            .clamp(0.0, kMinInteractiveDimension)
            .toDouble();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          child: Row(
            children: [
              if (hasUltraWide)
                _ZoomPresetButton(
                  label: ultraWideLabel,
                  selected: (safeValue - ultraWideRatio).abs() < 0.08,
                  compact: true,
                  minTapWidth: presetTapWidth,
                  onTap: quickSelect(ultraWideRatio),
                ),
              _ZoomPresetButton(
                label: '1×',
                selected: (safeValue - 1.0).abs() < 0.08,
                compact: true,
                minTapWidth: presetTapWidth,
                onTap: quickSelect(1.0),
              ),
              _ZoomPresetButton(
                label: '2×',
                selected: (safeValue - 2.0).abs() < 0.08,
                compact: true,
                minTapWidth: presetTapWidth,
                onTap: quickSelect(2.0),
              ),
              _ZoomPresetButton(
                label: '5×',
                selected: (safeValue - 5.0).abs() < 0.08,
                compact: true,
                minTapWidth: presetTapWidth,
                onTap: quickSelect(5.0),
              ),
              const SizedBox(width: 2),
              buildStepButton(
                icon: Icons.remove_rounded,
                tooltip: appText(context, 'Thu nhỏ', 'Zoom out'),
                onTap: canDecrease ? () => stepZoom(-0.1) : null,
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 8,
                      elevation: 2.0,
                      pressedElevation: 4.0,
                    ),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                    activeTrackColor: const Color(0xFF22C55E),
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.20),
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: safeValue,
                    min: effectiveMin,
                    max: effectiveMax,
                    divisions: ((effectiveMax - effectiveMin) * 10)
                        .round()
                        .clamp(1, 100),
                    onChanged: enabled ? onChanged : null,
                  ),
                ),
              ),
              buildStepButton(
                icon: Icons.add_rounded,
                tooltip: appText(context, 'Phóng to', 'Zoom in'),
                onTap: canIncrease ? () => stepZoom(0.1) : null,
              ),
              if (showValue)
                SizedBox(
                  width: 38,
                  child: Text(
                    '${safeValue.toStringAsFixed(1)}×',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ZoomPresetButton extends StatelessWidget {
  final String label;
  final bool selected;
  final bool compact;

  /// Bề rộng tối thiểu của vùng chạm (≤ 48dp). Chiều cao vùng chạm luôn
  /// [kMinInteractiveDimension]; hình hiển thị giữ kích thước cũ.
  final double minTapWidth;

  /// null: nút bị khoá (đang đổi camera).
  final VoidCallback? onTap;

  const _ZoomPresetButton({
    required this.label,
    required this.selected,
    required this.compact,
    required this.onTap,
    this.minTapWidth = kMinInteractiveDimension,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      enabled: onTap != null,
      label: appText(context, 'Thu phóng $label', 'Zoom $label'),
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        // Chạm vào phần trong suốt quanh hình cũng kích hoạt.
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: minTapWidth,
            minHeight: kMinInteractiveDimension,
          ),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Padding(
              // Khoảng hở giữa các nút nằm trong vùng chạm (không có khe chết).
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 8 : 10,
                  vertical: compact ? 2 : 3,
                ),
                decoration: BoxDecoration(
                  color: selected
                      ? const Color(0xFF1565C0)
                      : Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: selected
                        ? const Color(0xFF64B5F6)
                        : Colors.white.withValues(alpha: 0.15),
                    width: selected ? 1.5 : 1,
                  ),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: const Color(
                              0xFF1565C0,
                            ).withValues(alpha: 0.4),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: onTap == null ? Colors.white38 : Colors.white,
                    fontWeight: selected ? FontWeight.w900 : FontWeight.w600,
                    fontSize: compact ? 11 : 12,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CameraDock extends StatelessWidget {
  const _CameraDock({required this.buttons});

  final List<Widget> buttons;

  @override
  Widget build(BuildContext context) {
    return _GlassSurface(
      radius: 22,
      padding: const EdgeInsets.all(5),
      // Màn hình rất thấp (menu đang mở): cụm nút tự cuộn, không tràn.
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Mỗi nút đã có vùng chạm 48dp (hình 36dp) nên không cần khoảng
            // cách thêm giữa các nút.
            for (var i = 0; i < buttons.length; i++) buttons[i],
          ],
        ),
      ),
    );
  }
}

class _DockButton extends StatelessWidget {
  const _DockButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.loading = false,
    this.background,
  });

  static const double size = 36;

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool loading;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    // Vùng chạm tối thiểu 48dp (kMinInteractiveDimension); hình tròn hiển thị
    // vẫn [size]. Chạm vào phần viền trong suốt quanh hình cũng kích hoạt.
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Ngữ nghĩa (nút bấm) do InkWell bên trong cung cấp.
        excludeFromSemantics: true,
        onTap: onTap,
        child: SizedBox(
          width: kMinInteractiveDimension,
          height: kMinInteractiveDimension,
          child: Center(
            child: Material(
              color: background ?? Colors.white.withValues(alpha: 0.10),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onTap,
                child: SizedBox(
                  width: size,
                  height: size,
                  child: Center(
                    child: loading
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Icon(
                            icon,
                            size: 18,
                            color: onTap == null ? Colors.white30 : Colors.white,
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
