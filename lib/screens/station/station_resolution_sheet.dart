part of '../station_screen.dart';

typedef _StationToast =
    void Function({
      required String vi,
      required String en,
      NoticeKind kind,
      Duration? duration,
    });

/// Bảng chọn chất lượng camera. Nghe [CameraStationRuntime.stateChanges] khi
/// đang mở để không hiển thị dữ liệu cũ (nhiệt độ, profile, khoá…).
class _ResolutionPickerSheet extends StatefulWidget {
  const _ResolutionPickerSheet({
    required this.runtime,
    required this.showToast,
    required this.onChanged,
  });

  final CameraStationRuntime runtime;

  /// Toast của màn hình Station (hiển thị bằng ScaffoldMessenger của màn hình).
  final _StationToast showToast;

  /// Báo màn hình Station dựng lại (ví dụ sau khi đổi chế độ khoá).
  final VoidCallback onChanged;

  @override
  State<_ResolutionPickerSheet> createState() => _ResolutionPickerSheetState();
}

class _ResolutionPickerSheetState extends State<_ResolutionPickerSheet> {
  StreamSubscription<void>? _stateSubscription;
  bool _lockChanging = false;

  @override
  void initState() {
    super.initState();
    _stateSubscription = widget.runtime.stateChanges.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    super.dispose();
  }

  Future<void> _toggleLock() async {
    if (_lockChanging) return;
    final runtime = widget.runtime;
    final nextLock = !runtime.resolutionLocked;
    final currentTitle = runtime.resolutionProfile.title;
    _lockChanging = true;
    try {
      await runtime.setResolutionLocked(nextLock);
    } catch (error) {
      String reason(bool english) =>
          compactErrorText(stationErrorMessage(error, english: english));
      // Toast của màn hình Station tự kiểm tra màn hình còn hiển thị.
      widget.showToast(
        vi: 'Không đổi được chế độ khoá: ${reason(false)}',
        en: "Couldn't change lock mode: ${reason(true)}",
        kind: NoticeKind.error,
      );
      return;
    } finally {
      _lockChanging = false;
    }
    widget.onChanged();
    if (!mounted) return;
    setState(() {});
    widget.showToast(
      vi: nextLock
          ? 'Đã khoá $currentTitle. Không tự hạ khi máy nóng.'
          : 'Đã mở khoá. Tự chỉnh chất lượng khi máy nóng.',
      en: nextLock
          ? 'Locked $currentTitle. No auto-downgrade when hot.'
          : 'Unlocked. Quality auto-adjusts when hot.',
      kind: NoticeKind.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final runtime = widget.runtime;
    final media = MediaQuery.of(context);
    final profiles = runtime.supportedResolutionProfiles;
    final landscape = media.orientation == Orientation.landscape;
    final columns = landscape && media.size.width >= 560 ? 2 : 1;
    final rows = (profiles.length / columns).ceil();
    final hasThermalBanner =
        (runtime.temperatureC != null && runtime.temperatureC! >= 38.0) ||
        runtime.justCooledDown;
    const tileExtent = 72.0;
    final contentHeight = 56.0 +
        (rows * tileExtent) +
        ((rows - 1) * BrandSpace.sm) +
        (hasThermalBanner ? 58.0 : 16.0);
    final maximumHeight = (media.size.height * (landscape ? 0.85 : 0.65)).clamp(
      240.0,
      480.0,
    );
    final sheetHeight = contentHeight < maximumHeight
        ? contentHeight
        : maximumHeight;
    final isLocked = runtime.resolutionLocked;
    final temperature = runtime.temperatureC?.toStringAsFixed(0) ?? '';

    return SafeArea(
      child: SizedBox(
        height: sheetHeight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            BrandSpace.lg,
            0,
            BrandSpace.lg,
            BrandSpace.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      appText(context, 'Chất lượng camera', 'Camera quality'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BrandText.title,
                    ),
                  ),
                  const SizedBox(width: BrandSpace.sm),
                  BrandPill(
                    icon: isLocked
                        ? Icons.lock_rounded
                        : Icons.lock_open_rounded,
                    text: isLocked
                        ? appText(context, 'Đã khoá', 'Locked')
                        : appText(context, 'Khoá', 'Lock'),
                    color: isLocked
                        ? BrandColors.warningSoft
                        : BrandColors.textSecondary,
                    tooltip: isLocked
                        ? appText(
                            context,
                            'Mở khoá: tự chỉnh khi máy nóng',
                            'Unlock: auto-adjust when hot',
                          )
                        : appText(
                            context,
                            'Khoá: không tự hạ khi máy nóng',
                            'Lock: no auto-downgrade when hot',
                          ),
                    onTap: _toggleLock,
                  ),
                ],
              ),
              if (hasThermalBanner) ...[
                const SizedBox(height: BrandSpace.sm),
                AppNoticeBanner(
                  dense: true,
                  kind: runtime.justCooledDown
                      ? NoticeKind.success
                      : runtime.thermalWarning
                          ? NoticeKind.warning
                          : NoticeKind.info,
                  icon: runtime.justCooledDown
                      ? Icons.ac_unit_rounded
                      : runtime.thermalWarning
                          ? Icons.whatshot_rounded
                          : Icons.thermostat_rounded,
                  message: runtime.justCooledDown
                      ? appText(
                          context,
                          'Máy đã mát ($temperature°C). Có thể nâng chất lượng.',
                          'Cooled down ($temperature°C). You can raise quality.',
                        )
                      : runtime.thermalWarning
                          ? appText(
                              context,
                              'Máy đang nóng ($temperature°C). Vẫn chọn được chất lượng.',
                              'Device is hot ($temperature°C). You can still choose.',
                            )
                          : appText(
                              context,
                              'Nhiệt độ: $temperature°C',
                              'Temperature: $temperature°C',
                            ),
                ),
              ],
              const SizedBox(height: BrandSpace.md),
              Expanded(
                child: GridView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: profiles.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: BrandSpace.sm,
                    mainAxisSpacing: BrandSpace.sm,
                    mainAxisExtent: tileExtent,
                  ),
                  itemBuilder: (context, index) {
                    final profile = profiles[index];
                    return _ResolutionTile(
                      profile: profile,
                      active: profile == runtime.resolutionProfile,
                      locked: isLocked,
                      onTap: () {
                        if (isLocked) {
                          widget.showToast(
                            vi: 'Đang khoá chất lượng. Mở khoá ở góc trên để đổi.',
                            en: 'Quality is locked. Unlock at the top to change.',
                            kind: NoticeKind.warning,
                          );
                          return;
                        }
                        Navigator.pop(context, profile);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Một lựa chọn chất lượng: dấu chọn + tên + thông số phụ + viên FPS.
class _ResolutionTile extends StatelessWidget {
  const _ResolutionTile({
    required this.profile,
    required this.active,
    required this.locked,
    required this.onTap,
  });

  final CameraResolutionProfile profile;
  final bool active;
  final bool locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dimmed = locked && !active;
    final highFps = profile.fps >= 50;
    return Material(
      color: active ? BrandColors.primary : BrandColors.surfaceRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BrandRadius.medium),
        side: BorderSide(
          color: active ? BrandColors.primaryBright : BrandColors.border,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: active ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: BrandSpace.md,
            vertical: BrandSpace.sm,
          ),
          child: Row(
            children: [
              Icon(
                active
                    ? Icons.check_circle_rounded
                    : locked
                        ? Icons.lock_outline_rounded
                        : Icons.radio_button_unchecked_rounded,
                color: active
                    ? Colors.white
                    : locked
                        ? BrandColors.textDisabled
                        : BrandColors.textSecondary,
              ),
              const SizedBox(width: BrandSpace.md),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BrandText.body.copyWith(
                        color: dimmed
                            ? BrandColors.textDisabled
                            : BrandColors.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${profile.width} × ${profile.height} · '
                      '${(profile.bitrate / 1000000).toStringAsFixed(1)} Mbps',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BrandText.caption.copyWith(
                        color: dimmed
                            ? BrandColors.textDisabled
                            : active
                                ? Colors.white70
                                : BrandColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: BrandSpace.sm),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: BrandSpace.sm,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: highFps
                      ? BrandColors.success.withValues(alpha: 0.18)
                      : const Color(0x14FFFFFF),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${profile.fps} FPS',
                  style: TextStyle(
                    color: highFps
                        ? BrandColors.successSoft
                        : active
                            ? Colors.white
                            : BrandColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
