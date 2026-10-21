part of '../station_screen.dart';

/// Khay mở rộng phía trên thanh điều khiển đáy (chỉ một khay mỗi lúc).
enum _ControlTray { none, zoom, exposure }

/// Thanh điều khiển nhỏ ở đáy màn camera:
/// `[0.5× 1× 2× 5×] (zoom chi tiết) (độ sáng)`.
/// Thanh trượt zoom và bước độ sáng chỉ hiện khi bấm mở khay tương ứng, để
/// chừa tối đa diện tích cho hình camera.
class _CameraControlBar extends StatefulWidget {
  const _CameraControlBar({
    required this.compact,
    required this.cameraReady,
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
  State<_CameraControlBar> createState() => _CameraControlBarState();
}

class _CameraControlBarState extends State<_CameraControlBar> {
  _ControlTray _tray = _ControlTray.none;

  void _toggleTray(_ControlTray tray) {
    setState(() => _tray = _tray == tray ? _ControlTray.none : tray);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    // Camera chưa sẵn sàng: không có zoom hay độ sáng để chỉnh, ẩn hẳn.
    if (!w.cameraReady && !w.zoomSupported) return const SizedBox.shrink();

    var tray = _tray;
    if (tray == _ControlTray.zoom && !w.zoomSupported) {
      tray = _ControlTray.none;
    }
    if (tray == _ControlTray.exposure && !w.cameraReady) {
      tray = _ControlTray.none;
    }

    final effectiveMin = w.hasUltraWide
        ? math.min(w.ultraWideRatio, w.minimumZoom)
        : w.minimumZoom.clamp(1.0, 5.0);
    // max(...) thay vì clamp(min + 0.1, 5.0): clamp ném lỗi khi cận dưới > 5
    // (thiết bị báo minimumZoom = 5).
    final effectiveMax = math.max(
      math.min(w.maximumZoom, 5.0),
      effectiveMin + 0.1,
    );
    final safeValue = w.zoomValue.clamp(effectiveMin, effectiveMax).toDouble();

    // Mức zoom nhanh: [siêu rộng], 1×, 2×, 5×.
    final presets = <double>[
      if (w.hasUltraWide) w.ultraWideRatio,
      1.0,
      2.0,
      5.0,
    ];
    String presetLabel(int index) => w.hasUltraWide && index == 0
        ? w.ultraWideLabel
        : '${presets[index].toStringAsFixed(0)}×';
    int? selectedPreset;
    for (var i = 0; i < presets.length; i++) {
      if ((safeValue - presets[i]).abs() < 0.08) {
        selectedPreset = i;
        break;
      }
    }

    final evAuto = w.exposureEv.abs() < 0.01;
    final bar = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (w.zoomSupported) ...[
          Semantics(
            container: true,
            label: appText(context, 'Thu phóng', 'Zoom'),
            child: BrandSegmented<int>(
              values: List<int>.generate(presets.length, (i) => i),
              labelOf: presetLabel,
              selected: selectedPreset,
              dense: w.compact,
              onChanged: w.zoomEnabled
                  ? (index) => w.onQuickSelectZoom(presets[index])
                  : null,
            ),
          ),
          const SizedBox(width: BrandSpace.sm),
          BrandIconButton(
            icon: Icons.zoom_in_rounded,
            tooltip: appText(
              context,
              'Zoom chi tiết (${safeValue.toStringAsFixed(1)}×)',
              'Fine zoom (${safeValue.toStringAsFixed(1)}×)',
            ),
            size: 48,
            active: tray == _ControlTray.zoom,
            onPressed: () => _toggleTray(_ControlTray.zoom),
          ),
        ],
        if (w.cameraReady) ...[
          if (w.zoomSupported) const SizedBox(width: BrandSpace.sm),
          BrandIconButton(
            icon: evAuto
                ? Icons.brightness_auto_rounded
                : Icons.exposure_rounded,
            tooltip: appText(context, 'Độ sáng hình', 'Image brightness'),
            size: 48,
            active: tray == _ControlTray.exposure,
            onPressed: () => _toggleTray(_ControlTray.exposure),
          ),
        ],
      ],
    );

    final Widget? trayContent = switch (tray) {
      _ControlTray.zoom => _ZoomFineControl(
        value: safeValue,
        minimum: effectiveMin,
        maximum: effectiveMax,
        enabled: w.zoomEnabled,
        onChanged: w.onZoomChanged,
      ),
      _ControlTray.exposure => _ExposureStepper(
        ev: w.exposureEv,
        onChanged: w.onExposureChanged,
      ),
      _ControlTray.none => null,
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (trayContent != null) ...[
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: BrandGlass(
              radius: BrandRadius.large,
              padding: const EdgeInsets.symmetric(horizontal: BrandSpace.xs),
              child: trayContent,
            ),
          ),
          const SizedBox(height: BrandSpace.sm),
        ],
        // Chữ hệ thống phóng to trên máy hẹp: thu nhỏ cả thanh thay vì tràn.
        FittedBox(fit: BoxFit.scaleDown, child: bar),
      ],
    );
  }
}

/// Khay zoom chi tiết: `[−] thanh trượt [+] 1.3×`, bước 0,1×.
class _ZoomFineControl extends StatelessWidget {
  const _ZoomFineControl({
    required this.value,
    required this.minimum,
    required this.maximum,
    required this.enabled,
    required this.onChanged,
  });

  final double value;
  final double minimum;
  final double maximum;
  final bool enabled;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    void stepZoom(double delta) {
      final raw = value + delta;
      final stepped = (raw * 10).round() / 10.0;
      final clamped = stepped.clamp(minimum, maximum).toDouble();
      onChanged(clamped);
    }

    final canDecrease = enabled && value > (minimum + 0.04);
    final canIncrease = enabled && value < (maximum - 0.04);

    return Row(
      children: [
        _TrayStepButton(
          icon: Icons.remove_rounded,
          tooltip: appText(context, 'Thu nhỏ', 'Zoom out'),
          onTap: canDecrease ? () => stepZoom(-0.1) : null,
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(
                enabledThumbRadius: 8,
                elevation: 0,
                pressedElevation: 0,
              ),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              activeTrackColor: BrandColors.primaryBright,
              inactiveTrackColor: Colors.white.withValues(alpha: 0.20),
              thumbColor: Colors.white,
            ),
            child: Slider(
              value: value,
              min: minimum,
              max: maximum,
              divisions: ((maximum - minimum) * 10).round().clamp(1, 100),
              onChanged: enabled ? onChanged : null,
            ),
          ),
        ),
        _TrayStepButton(
          icon: Icons.add_rounded,
          tooltip: appText(context, 'Phóng to', 'Zoom in'),
          onTap: canIncrease ? () => stepZoom(0.1) : null,
        ),
        SizedBox(
          width: 44,
          child: Text(
            '${value.toStringAsFixed(1)}×',
            textAlign: TextAlign.center,
            maxLines: 1,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

/// Khay độ sáng hình: `☀ [−] Tự động [+]`, mỗi bước 0,5 EV, từ −1 tới +2.
class _ExposureStepper extends StatelessWidget {
  const _ExposureStepper({required this.ev, required this.onChanged});

  static const double _step = 0.5;
  static const double _min = -1.0;
  static const double _max = 2.0;

  final double ev;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final label = ev.abs() < 0.01
        ? appText(context, 'Tự động', 'Auto')
        : '${ev > 0 ? '+' : ''}${ev.toStringAsFixed(1)} EV';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(width: BrandSpace.sm),
        Tooltip(
          message: appText(context, 'Độ sáng hình', 'Image brightness'),
          child: const Icon(
            Icons.wb_sunny_rounded,
            size: 18,
            color: BrandColors.warningSoft,
          ),
        ),
        const SizedBox(width: BrandSpace.xs),
        _TrayStepButton(
          icon: Icons.remove_rounded,
          tooltip: appText(context, 'Tối hơn', 'Darker'),
          onTap: ev > _min + 0.01 ? () => onChanged(ev - _step) : null,
        ),
        SizedBox(
          width: 84,
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        _TrayStepButton(
          icon: Icons.add_rounded,
          tooltip: appText(context, 'Sáng hơn', 'Brighter'),
          onTap: ev < _max - 0.01 ? () => onChanged(ev + _step) : null,
        ),
      ],
    );
  }
}

/// Nút bước trong khay: vùng chạm 48dp, hình tròn hiển thị 30dp.
class _TrayStepButton extends StatelessWidget {
  const _TrayStepButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Tooltip(
      message: tooltip,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: kMinInteractiveDimension,
            height: kMinInteractiveDimension,
            child: Center(
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: enabled
                      ? const Color(0x1FFFFFFF)
                      : const Color(0x0AFFFFFF),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: enabled
                        ? const Color(0x33FFFFFF)
                        : const Color(0x0FFFFFFF),
                  ),
                ),
                child: Icon(
                  icon,
                  size: 16,
                  color: enabled ? Colors.white : BrandColors.textDisabled,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
