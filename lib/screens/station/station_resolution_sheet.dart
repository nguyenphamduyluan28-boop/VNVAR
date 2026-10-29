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
  bool _sportsChanging = false;

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

  Future<void> _setSportsShutter(int denominator) async {
    final runtime = widget.runtime;
    if (_sportsChanging || denominator == runtime.sportsShutter) return;
    final wasOn = runtime.sportsMode;
    setState(() => _sportsChanging = true);
    try {
      await runtime.setSportsShutter(denominator);
    } catch (error) {
      String reason(bool english) =>
          compactErrorText(stationErrorMessage(error, english: english));
      widget.showToast(
        vi: 'Không đổi được chế độ thể thao: ${reason(false)}',
        en: "Couldn't change sports mode: ${reason(true)}",
        kind: NoticeKind.error,
      );
      return;
    } finally {
      if (mounted) setState(() => _sportsChanging = false);
    }
    widget.onChanged();
    if (denominator <= 0) {
      widget.showToast(
        vi: 'Đã tắt chế độ thể thao.',
        en: 'Sports mode off.',
        kind: NoticeKind.success,
      );
      return;
    }
    final pending = !wasOn && runtime.sportsBitratePending;
    widget.showToast(
      vi: pending
          ? 'Màn trập 1/$denominator s. Bitrate cao áp dụng khi mở lại camera.'
          : 'Thể thao: màn trập 1/$denominator s.',
      en: pending
          ? 'Shutter 1/$denominator s. Higher bitrate after camera restart.'
          : 'Sports: shutter 1/$denominator s.',
      kind: NoticeKind.success,
    );
  }

  /// Cấu hình 50–60 FPS cùng độ phân giải hiện tại (nếu máy hỗ trợ).
  CameraResolutionProfile? _highFpsProfile() {
    final runtime = widget.runtime;
    final current = runtime.resolutionProfile;
    if (current.fps >= 50) return null;
    for (final profile in runtime.supportedResolutionProfiles) {
      if (profile.preset == current.preset && profile.fps >= 50) {
        return profile;
      }
    }
    return null;
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
    const sportsExtent = 104.0;
    final contentHeight = 56.0 +
        sportsExtent +
        BrandSpace.sm +
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
              // Không cố định chiều cao: chữ hệ thống phóng to thì khối tự cao
              // lên, lưới chất lượng bên dưới (cuộn được) nhường chỗ.
              _SportsModeTile(
                shutter: runtime.sportsShutter,
                busy: _sportsChanging,
                onChanged: _setSportsShutter,
                highFpsProfile: runtime.sportsMode ? _highFpsProfile() : null,
                onUseHighFps: (profile) {
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
              ),
              const SizedBox(height: BrandSpace.sm),
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

/// Chế độ thể thao: chọn mức màn trập (Tắt / 1/250 / 1/500) + gợi ý 60 FPS.
class _SportsModeTile extends StatelessWidget {
  const _SportsModeTile({
    required this.shutter,
    required this.busy,
    required this.onChanged,
    required this.highFpsProfile,
    required this.onUseHighFps,
  });

  final int shutter;
  final bool busy;
  final ValueChanged<int> onChanged;

  /// Cấu hình 60 FPS cùng độ phân giải (null = đã 60 FPS / máy không hỗ trợ).
  final CameraResolutionProfile? highFpsProfile;
  final ValueChanged<CameraResolutionProfile> onUseHighFps;

  @override
  Widget build(BuildContext context) {
    final enabled = shutter > 0;
    final accent =
        enabled ? BrandColors.primaryBright : BrandColors.textSecondary;
    final fpsProfile = highFpsProfile;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        BrandSpace.md,
        BrandSpace.sm,
        BrandSpace.sm,
        BrandSpace.sm,
      ),
      decoration: BoxDecoration(
        color: BrandColors.surfaceRaised,
        borderRadius: BorderRadius.circular(BrandRadius.medium),
        border: Border.all(
          color: enabled ? BrandColors.primaryBright : BrandColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(Icons.sports_tennis_rounded, color: accent, size: 20),
              const SizedBox(width: BrandSpace.sm),
              Expanded(
                child: Text(
                  appText(context, 'Thể thao', 'Sports mode'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BrandText.body.copyWith(
                    color: BrandColors.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (fpsProfile != null)
                BrandPill(
                  icon: Icons.speed_rounded,
                  text: '${fpsProfile.fps} FPS',
                  color: BrandColors.successSoft,
                  tooltip: appText(
                    context,
                    'Chuyển ${fpsProfile.shortLabel} ${fpsProfile.fps} FPS: bóng ít mất dấu hơn',
                    'Switch to ${fpsProfile.shortLabel} ${fpsProfile.fps} FPS: steadier ball tracking',
                  ),
                  onTap: busy ? null : () => onUseHighFps(fpsProfile),
                ),
            ],
          ),
          const SizedBox(height: BrandSpace.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: BrandSegmented<int>(
                values: StationConfigService.sportsShutterOptions,
                selected: shutter,
                dense: true,
                labelOf: (value) => value <= 0
                    ? appText(context, 'Tắt', 'Off')
                    : '1/$value s',
                onChanged: busy ? null : onChanged,
              ),
            ),
          ),
        ],
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
