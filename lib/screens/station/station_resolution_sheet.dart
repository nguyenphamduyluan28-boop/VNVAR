part of '../station_screen.dart';

typedef _StationToast =
    void Function(String message, {bool isError, IconData? icon});

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
    final english = AppLanguageScope.of(context).isEnglish;
    final lockMsg = nextLock
        ? appText(
            context,
            'Đã khóa chế độ $currentTitle. Camera sẽ giữ nguyên chất lượng này kể cả khi máy nóng.',
            'Locked $currentTitle. Camera will remain at this quality even when device is hot.',
          )
        : appText(
            context,
            'Đã mở khóa chế độ phân giải. Camera sẽ tự động điều chỉnh khi máy nóng.',
            'Resolution mode unlocked. Camera will automatically adjust when hot.',
          );
    _lockChanging = true;
    try {
      await runtime.setResolutionLocked(nextLock);
    } catch (error) {
      final reason = compactErrorText(
        stationErrorMessage(error, english: english),
      );
      // Toast của màn hình Station tự kiểm tra màn hình còn hiển thị.
      widget.showToast(
        english
            ? 'Unable to change lock mode: $reason'
            : 'Không đổi được chế độ khóa: $reason',
        isError: true,
      );
      return;
    } finally {
      _lockChanging = false;
    }
    widget.onChanged();
    if (!mounted) return;
    setState(() {});
    widget.showToast(
      lockMsg,
      icon: nextLock ? Icons.lock_rounded : Icons.lock_open_rounded,
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
    final contentHeight = 58.0 +
        (rows * 88.0) +
        ((rows - 1) * 10.0) +
        (hasThermalBanner ? 52.0 : 16.0);
    final maximumHeight = (media.size.height * (landscape ? 0.85 : 0.65)).clamp(
      240.0,
      480.0,
    );
    final sheetHeight = contentHeight < maximumHeight
        ? contentHeight
        : maximumHeight;
    final isLocked = runtime.resolutionLocked;

    return SafeArea(
      child: SizedBox(
        height: sheetHeight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      appText(context, 'CHẤT LƯỢNG CAMERA', 'CAMERA QUALITY'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: _toggleLock,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: isLocked
                              ? const Color(0xFFE65100).withValues(alpha: 0.25)
                              : Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isLocked
                                ? const Color(0xFFFF9800)
                                : Colors.white24,
                            width: 1.2,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isLocked
                                  ? Icons.lock_rounded
                                  : Icons.lock_open_rounded,
                              size: 14,
                              color: isLocked
                                  ? const Color(0xFFFFB74D)
                                  : Colors.white70,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              isLocked
                                  ? appText(context, 'Đã khóa', 'Locked')
                                  : appText(context, 'Khóa chế độ', 'Lock mode'),
                              style: TextStyle(
                                color: isLocked
                                    ? const Color(0xFFFFB74D)
                                    : Colors.white70,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (hasThermalBanner) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: runtime.justCooledDown
                        ? const Color(0xFF00C853).withValues(alpha: 0.15)
                        : runtime.thermalWarning
                            ? const Color(0xFFC62828).withValues(alpha: 0.18)
                            : const Color(0xFFE65100).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: runtime.justCooledDown
                          ? const Color(0xFF00E676).withValues(alpha: 0.35)
                          : runtime.thermalWarning
                              ? const Color(0xFFEF5350).withValues(alpha: 0.35)
                              : const Color(0xFFFF9800).withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        runtime.justCooledDown
                            ? Icons.ac_unit_rounded
                            : runtime.thermalWarning
                                ? Icons.whatshot_rounded
                                : Icons.thermostat_rounded,
                        size: 15,
                        color: runtime.justCooledDown
                            ? const Color(0xFF69F0AE)
                            : runtime.thermalWarning
                                ? const Color(0xFFFF8A80)
                                : const Color(0xFFFFB74D),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          runtime.justCooledDown
                              ? appText(
                                  context,
                                  'Thiết bị đã hạ nhiệt an toàn (${runtime.temperatureC?.toStringAsFixed(0) ?? ''}°C). Bạn có thể chọn lại độ phân giải mong muốn.',
                                  'Device has cooled down (${runtime.temperatureC?.toStringAsFixed(0) ?? ''}°C). You can re-select your preferred quality.',
                                )
                              : runtime.thermalWarning
                                  ? appText(
                                      context,
                                      'Thiết bị đang nóng (${runtime.temperatureC?.toStringAsFixed(0)}°C). Bạn vẫn có thể chủ động chọn độ phân giải theo ý muốn.',
                                      'Device is warm (${runtime.temperatureC?.toStringAsFixed(0)}°C). You can still choose your preferred quality.',
                                    )
                                  : appText(
                                      context,
                                      'Nhiệt độ hiện tại: ${runtime.temperatureC?.toStringAsFixed(0)}°C.',
                                      'Current temperature: ${runtime.temperatureC?.toStringAsFixed(0)}°C.',
                                    ),
                          style: TextStyle(
                            color: runtime.justCooledDown
                                ? const Color(0xFFB9F6CA)
                                : runtime.thermalWarning
                                    ? const Color(0xFFFFCDD2)
                                    : const Color(0xFFFFE0B2),
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Expanded(
                child: GridView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: profiles.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    mainAxisExtent: 88,
                  ),
                  itemBuilder: (context, index) {
                    final profile = profiles[index];
                    final active = profile == runtime.resolutionProfile;
                    final displayProfile = profile;
                    return Material(
                      color: active
                          ? const Color(0xFF1565C0)
                          : isLocked
                              ? const Color(0xFF15181E)
                              : const Color(0xFF1A2028),
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: active
                            ? null
                            : () {
                                if (isLocked) {
                                  widget.showToast(
                                    appText(
                                      context,
                                      'Chế độ phân giải đang khóa. Vui lòng bấm nút mở khóa ở góc trên để đổi.',
                                      'Resolution mode is locked. Please unlock using the top button to change.',
                                    ),
                                    icon: Icons.lock_rounded,
                                  );
                                  return;
                                }
                                Navigator.pop(context, profile);
                              },
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: active
                                  ? const Color(0xFF64B5F6)
                                  : Colors.white.withValues(alpha: 0.08),
                              width: active ? 1.5 : 1.0,
                            ),
                            boxShadow: active
                                ? [
                                    BoxShadow(
                                      color: const Color(0xFF1565C0)
                                          .withValues(alpha: 0.35),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ]
                                : null,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  active
                                      ? Icons.check_circle_rounded
                                      : isLocked
                                          ? Icons.lock_outline_rounded
                                          : Icons.radio_button_unchecked_rounded,
                                  color: active
                                      ? Colors.white
                                      : isLocked
                                          ? Colors.white24
                                          : Colors.white38,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment:
                                        MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              displayProfile.title,
                                              maxLines: 1,
                                              overflow:
                                                  TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: isLocked && !active
                                                    ? Colors.white54
                                                    : Colors.white,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Container(
                                            padding:
                                                const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: displayProfile.fps >=
                                                      50
                                                  ? const Color(0xFF00E676)
                                                      .withValues(
                                                          alpha: 0.18)
                                                  : Colors.white
                                                      .withValues(
                                                          alpha: 0.08),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                              border: Border.all(
                                                color: displayProfile.fps >=
                                                        50
                                                    ? const Color(
                                                            0xFF00E676)
                                                        .withValues(
                                                            alpha: 0.5)
                                                    : Colors.white24,
                                                width: 0.8,
                                              ),
                                            ),
                                            child: Text(
                                              '${displayProfile.fps} FPS',
                                              style: TextStyle(
                                                color: displayProfile.fps >=
                                                        50
                                                    ? const Color(
                                                        0xFF69F0AE)
                                                    : Colors.white70,
                                                fontSize: 10.5,
                                                fontWeight:
                                                    FontWeight.w800,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${displayProfile.width} × ${displayProfile.height}  •  '
                                        '${(displayProfile.bitrate / 1000000).toStringAsFixed(1)} Mbps',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: isLocked && !active
                                              ? Colors.white30
                                              : Colors.white60,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
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
