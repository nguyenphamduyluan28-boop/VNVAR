import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/station_identity.dart';
import '../services/app_language_service.dart';
import '../services/station_config_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_notice.dart';
import '../widgets/brand_widgets.dart';

class SetupScreen extends StatefulWidget {
  final ValueChanged<StationIdentity> onConfigured;
  final StationIdentity? initialIdentity;
  final bool persistOnSave;
  final VoidCallback? onBack;
  final bool isLandscape;

  const SetupScreen({
    super.key,
    required this.onConfigured,
    this.initialIdentity,
    this.persistOnSave = true,
    this.onBack,
    this.isLandscape = false,
  });

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  static const List<String> _cameraIds = ['CAM-01', 'CAM-02', 'CAM-03'];

  /// Số sân lớn nhất được chọn (đủ cho mọi cụm sân, giữ nhãn 2 chữ số).
  static const int _maxCourtNumber = 99;

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final StationConfigService _config = StationConfigService();

  /// Tên camera: giữ tên đã lưu, đổi theo Camera ID khi chọn camera khác.
  late String _cameraName;

  late String _cameraId;
  late String _courtId;
  late String _deviceId;
  bool _saving = false;
  bool _loadingConfig = true;

  @override
  void initState() {
    super.initState();
    _applyOrientation();

    final identity = widget.initialIdentity;

    final savedCameraNumber = int.tryParse(
      RegExp(r'(\d+)$').firstMatch(identity?.cameraId ?? '')?.group(1) ?? '',
    );
    _cameraId =
        savedCameraNumber != null &&
            savedCameraNumber >= 1 &&
            savedCameraNumber <= _cameraIds.length
        ? 'CAM-${savedCameraNumber.toString().padLeft(2, '0')}'
        : _cameraIds.first;
    _courtId = identity?.courtId ?? 'COURT-01';
    _deviceId = identity?.deviceId ?? _generateDeviceId();

    _cameraName =
        identity?.cameraName ?? 'Camera ${_cameraId.replaceAll('CAM-', '')}';
    _loadConfig();
  }

  void _applyOrientation() {
    final orientations = widget.isLandscape
        ? const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]
        : const [
            DeviceOrientation.portraitUp,
            DeviceOrientation.portraitDown,
          ];
    SystemChrome.setPreferredOrientations(orientations);
    if (Platform.isAndroid) {
      // Kênh native thật của app (MainActivity); tên cũ không được đăng ký.
      const MethodChannel('vnvar/camera_station_service')
          .invokeMethod('setScreenOrientation', {
            'mode': widget.isLandscape ? 'landscape' : 'portrait',
          })
          .catchError((Object _) => null);
    }
  }

  Future<void> _loadConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey('venueName')) await prefs.remove('venueName');
      if (prefs.containsKey('venueMapAddress')) {
        await prefs.remove('venueMapAddress');
      }
    } catch (error) {
      // Không đọc được cấu hình: vẫn mở form (giữ giá trị mặc định) thay vì
      // quay vòng mãi.
      debugPrint('[SETUP] Unable to load config: $error');
    } finally {
      if (mounted) {
        setState(() {
          _loadingConfig = false;
        });
      }
    }
  }

  int get _selectedCourtNumber {
    return int.tryParse(_courtId.split('-').last) ?? 1;
  }

  void _selectCourtNumber(int number) {
    if (number < 1) return;
    // Cấu hình cũ có thể lưu số sân lớn hơn giới hạn: kéo về giới hạn.
    final court = number > _maxCourtNumber ? _maxCourtNumber : number;
    setState(() {
      _courtId = 'COURT-${court.toString().padLeft(2, '0')}';
    });
  }

  Future<void> _showCourtNumberInputDialog(int current) async {
    // Dialog tự quản lý (và dispose) TextEditingController của nó.
    final result = await showDialog<int>(
      context: context,
      builder: (_) => _CourtNumberDialog(
        initial: current,
        maxCourtNumber: _maxCourtNumber,
      ),
    );
    if (result != null && mounted) {
      _selectCourtNumber(result);
    }
  }

  void _onCameraIdSelected(String id) {
    setState(() {
      _cameraId = id;
      _cameraName = 'Camera ${id.replaceAll('CAM-', '')}';
    });
  }

  String _generateDeviceId() {
    final random = Random.secure();
    final suffix = List.generate(
      6,
      (_) => random.nextInt(16).toRadixString(16),
    ).join().toUpperCase();
    return 'PHONE-$suffix';
  }

  Future<void> _save() async {
    if (_saving || !(_formKey.currentState?.validate() ?? false)) return;

    final cameraName = _cameraName.trim().isNotEmpty
        ? _cameraName.trim()
        : _cameraId;

    setState(() => _saving = true);

    try {
      final identity = StationIdentity(
        courtId: _courtId.trim(),
        cameraId: _cameraId.trim(),
        deviceId: _deviceId.trim(),
        cameraName: cameraName,
        cameraPosition: '',
      );
      // Cổng API không chỉnh trên màn này: giữ nguyên giá trị đã lưu.
      if (widget.persistOnSave) {
        await _config.saveIdentity(identity);
      }
      if (!mounted) return;
      widget.onConfigured(identity);
    } catch (error) {
      if (!mounted) return;
      showAppNotice(
        context,
        vi: 'Không lưu được cấu hình. Thử lại sau.',
        en: 'Could not save settings. Try again later.',
        kind: NoticeKind.error,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _goBack() {
    final onBack = widget.onBack;
    if (onBack != null) {
      onBack();
    } else {
      Navigator.of(context).pop();
    }
  }

  void _copyDeviceId() {
    Clipboard.setData(ClipboardData(text: _deviceId));
    showAppNotice(
      context,
      vi: 'Đã sao chép mã thiết bị',
      en: 'Device ID copied',
      kind: NoticeKind.success,
    );
  }

  String get _cameraNumberLabel {
    final number = int.tryParse(_cameraId.replaceAll('CAM-', ''));
    return (number ?? 1).toString();
  }

  /// Khối nhận diện đầu trang: icon camera + "Sân X · Camera Y" + mã thiết bị.
  Widget _buildIdentityHeader() {
    final title =
        '${appText(context, 'Sân', 'Court')} $_selectedCourtNumber'
        ' · Camera $_cameraNumberLabel';
    return Container(
      padding: const EdgeInsets.fromLTRB(
        BrandSpace.lg,
        BrandSpace.md,
        BrandSpace.xs,
        BrandSpace.md,
      ),
      decoration: BoxDecoration(
        color: BrandColors.surface,
        borderRadius: BorderRadius.circular(BrandRadius.large),
        border: Border.all(color: BrandColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: BrandColors.primary.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(BrandRadius.medium),
              border: Border.all(
                color: BrandColors.primaryBright.withValues(alpha: 0.35),
              ),
            ),
            child: const Icon(
              Icons.videocam_rounded,
              color: BrandColors.primaryBright,
              size: 28,
            ),
          ),
          const SizedBox(width: BrandSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BrandText.title.copyWith(fontSize: 20),
                ),
                const SizedBox(height: 2),
                Text(
                  _deviceId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BrandText.caption.copyWith(
                    fontFamily: 'monospace',
                    letterSpacing: 0.4,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _copyDeviceId,
            tooltip: appText(context, 'Sao chép mã thiết bị', 'Copy device ID'),
            icon: const Icon(
              Icons.copy_rounded,
              size: 20,
              color: BrandColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  /// Bộ đếm sân: [−]  số lớn (chạm để nhập)  [+], từ 1 tới _maxCourtNumber.
  Widget _buildCourtSection() {
    final courtNumber = _selectedCourtNumber;
    return BrandSection(
      title: appText(context, 'Sân', 'Court'),
      padding: const EdgeInsets.symmetric(
        horizontal: BrandSpace.md,
        vertical: BrandSpace.md,
      ),
      children: [
        Row(
          children: [
            BrandIconButton(
              icon: Icons.remove_rounded,
              glass: false,
              tooltip: appText(context, 'Giảm sân', 'Decrease court'),
              onPressed: courtNumber > 1
                  ? () => _selectCourtNumber(courtNumber - 1)
                  : null,
            ),
            const SizedBox(width: BrandSpace.sm),
            Expanded(
              child: Tooltip(
                message: appText(context, 'Nhập số sân', 'Enter court number'),
                // Material trong suốt: nền BrandSection (DecoratedBox) che
                // hiệu ứng chạm vẽ trên Material của Scaffold.
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    onTap: () => _showCourtNumberInputDialog(courtNumber),
                    borderRadius: BorderRadius.circular(BrandRadius.small),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 64),
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            courtNumber.toString().padLeft(2, '0'),
                            style: const TextStyle(
                              color: BrandColors.textPrimary,
                              fontSize: 40,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: BrandSpace.sm),
            BrandIconButton(
              icon: Icons.add_rounded,
              glass: false,
              tooltip: appText(context, 'Tăng sân', 'Increase court'),
              onPressed: courtNumber < _maxCourtNumber
                  ? () => _selectCourtNumber(courtNumber + 1)
                  : null,
            ),
          ],
        ),
      ],
    );
  }

  /// Chọn camera: lưới 3 ô đồng kích thước (số lớn + vị trí ngắn).
  Widget _buildCameraSection() {
    return BrandSection(
      title: 'Camera',
      padding: const EdgeInsets.all(BrandSpace.sm),
      children: [
        Row(
          children: [
            for (var i = 0; i < _cameraIds.length; i++) ...[
              if (i > 0) const SizedBox(width: BrandSpace.sm),
              Expanded(child: _buildCameraChip(_cameraIds[i])),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildCameraChip(String id) {
    final isSelected = id == _cameraId;
    final position = switch (id) {
      'CAM-01' => appText(context, 'Góc trái', 'Left'),
      'CAM-02' => appText(context, 'Góc phải', 'Right'),
      'CAM-03' => appText(context, 'Giữa sân', 'Center'),
      _ => id,
    };
    final number = id.replaceAll('CAM-', '');
    return Tooltip(
      message: id,
      child: Material(
        color: isSelected ? BrandColors.primary : BrandColors.surfaceRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(BrandRadius.small),
          side: BorderSide(
            color: isSelected ? BrandColors.primaryBright : BrandColors.border,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _onCameraIdSelected(id),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: BrandSpace.xs,
                vertical: BrandSpace.sm,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    number,
                    maxLines: 1,
                    style: TextStyle(
                      color: isSelected ? Colors.white : BrandColors.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    position,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BrandText.caption.copyWith(
                      color: isSelected
                          ? Colors.white.withValues(alpha: 0.85)
                          : BrandColors.textSecondary,
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

  /// Mã kỹ thuật (tablet/server dùng): chỉ hiển thị.
  Widget _buildIdsSection() {
    const valueStyle = TextStyle(
      color: BrandColors.textSecondary,
      fontFamily: 'monospace',
      fontSize: 13,
      fontWeight: FontWeight.w600,
    );
    return BrandSection(
      title: appText(context, 'Mã', 'IDs'),
      children: [
        BrandTile(
          icon: Icons.stadium_rounded,
          title: 'Court ID',
          trailing: Flexible(
            child: Text(
              _courtId,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: valueStyle,
            ),
          ),
        ),
        BrandTile(
          icon: Icons.videocam_rounded,
          title: 'Camera ID',
          trailing: Flexible(
            child: Text(
              _cameraId,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: valueStyle,
            ),
          ),
        ),
      ],
    );
  }

  /// Thanh hành động cố định đáy: nút phụ dạng chữ + nút chính full-width.
  Widget _buildBottomBar(bool canGoBack) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: BrandColors.background,
        border: Border(top: BorderSide(color: BrandColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                BrandSpace.lg,
                BrandSpace.md,
                BrandSpace.lg,
                BrandSpace.md,
              ),
              child: Row(
                children: [
                  if (canGoBack) ...[
                    TextButton(
                      onPressed: _saving ? null : _goBack,
                      style: TextButton.styleFrom(
                        foregroundColor: BrandColors.textSecondary,
                        minimumSize: const Size(64, 52),
                      ),
                      child: Text(appText(context, 'Huỷ', 'Cancel')),
                    ),
                    const SizedBox(width: BrandSpace.sm),
                  ],
                  Expanded(child: _buildSaveButton()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSaveButton() {
    return FilledButton.icon(
      onPressed: _saving ? null : _save,
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
      icon: _saving
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.check_rounded, size: 20),
      label: Text(
        _saving
            ? appText(context, 'Đang lưu...', 'Saving...')
            : (widget.persistOnSave
                  ? appText(context, 'Lưu & khởi động', 'Save & start')
                  : appText(context, 'Áp dụng', 'Apply')),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingConfig) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final canGoBack = widget.onBack != null || Navigator.of(context).canPop();

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: true,
        leading: canGoBack
            ? IconButton(
                onPressed: _goBack,
                tooltip: appText(context, 'Quay lại', 'Back'),
                icon: const Icon(Icons.arrow_back_rounded),
              )
            : null,
        title: Text(
          appText(context, 'Thiết lập', 'Setup'),
          style: BrandText.title,
        ),
        actions: const [AppLanguageButton(), SizedBox(width: BrandSpace.sm)],
      ),
      body: Column(
        children: [
          Expanded(
            child: SafeArea(
              bottom: false,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 720;
                  return SingleChildScrollView(
                    padding: EdgeInsets.symmetric(
                      horizontal: wide ? BrandSpace.xl : BrandSpace.lg,
                      vertical: BrandSpace.lg,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: wide ? 960 : 560,
                        ),
                        child: Form(
                          key: _formKey,
                          child: wide
                              ? _buildWideLayout()
                              : _buildNarrowLayout(),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          _buildBottomBar(canGoBack),
        ],
      ),
    );
  }

  Widget _buildNarrowLayout() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildIdentityHeader(),
        const SizedBox(height: BrandSpace.xl),
        _buildCourtSection(),
        const SizedBox(height: BrandSpace.xl),
        _buildCameraSection(),
        const SizedBox(height: BrandSpace.xl),
        _buildIdsSection(),
      ],
    );
  }

  Widget _buildWideLayout() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildIdentityHeader(),
        const SizedBox(height: BrandSpace.xl),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _buildCourtSection()),
            const SizedBox(width: BrandSpace.xl),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildCameraSection(),
                  const SizedBox(height: BrandSpace.xl),
                  _buildIdsSection(),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Hộp thoại nhập số sân (1…[maxCourtNumber]). Là StatefulWidget để
/// TextEditingController được dispose sau khi hộp thoại đóng hẳn (dispose
/// ngay sau showDialog có thể chạy trước khi hiệu ứng đóng kết thúc).
class _CourtNumberDialog extends StatefulWidget {
  const _CourtNumberDialog({
    required this.initial,
    required this.maxCourtNumber,
  });

  final int initial;
  final int maxCourtNumber;

  @override
  State<_CourtNumberDialog> createState() => _CourtNumberDialogState();
}

class _CourtNumberDialogState extends State<_CourtNumberDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial.toString(),
  );
  bool _invalid = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final number = int.tryParse(_controller.text.trim());
    if (number == null || number < 1 || number > widget.maxCourtNumber) {
      setState(() => _invalid = true);
      return;
    }
    Navigator.of(context).pop(number);
  }

  @override
  Widget build(BuildContext context) {
    final maxCourt = widget.maxCourtNumber;
    return AlertDialog(
      title: Text(
        appText(context, 'Nhập số sân', 'Enter court number'),
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
      ),
      content: TextField(
        controller: _controller,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(maxCourt.toString().length),
        ],
        autofocus: true,
        onChanged: (_) {
          if (_invalid) setState(() => _invalid = false);
        },
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          hintText: appText(
            context,
            'VD: 1, 2, 25',
            'e.g. 1, 2, 25',
          ),
          errorText: _invalid
              ? appText(
                  context,
                  'Số sân từ 1 đến $maxCourt',
                  'Court 1 to $maxCourt',
                )
              : null,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(
            foregroundColor: BrandColors.textSecondary,
          ),
          child: Text(appText(context, 'Huỷ', 'Cancel')),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(appText(context, 'Xác nhận', 'Confirm')),
        ),
      ],
    );
  }
}
