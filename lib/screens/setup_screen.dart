import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/station_identity.dart';
import '../services/app_language_service.dart';
import '../services/station_config_service.dart';

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

  static const List<String> _positions = [
    'Góc trái sân',
    'Góc phải sân',
    'Giữa sân',
    'Trên cao trung tâm',
    'Baseline A',
    'Baseline B',
    'Góc A',
    'Góc B',
    'Tùy chỉnh',
  ];

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final StationConfigService _config = StationConfigService();

  late final TextEditingController _cameraNameController;
  late final TextEditingController _customPositionController;
  late final TextEditingController _apiPortController;

  late String _cameraId;
  late String _courtId;
  late String _position;
  late String _deviceId;
  bool _saving = false;
  bool _loadingVenue = true;
  String _venueName = '';
  String _venueMapAddress = '';

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

    final savedPosition = identity?.cameraPosition ?? _positions.first;
    _position = _positions.contains(savedPosition)
        ? savedPosition
        : 'Tùy chỉnh';

    final defaultInitialName = AppLanguageService.instance.isEnglish
        ? 'Left-corner camera'
        : 'Camera góc trái';
    _cameraNameController = TextEditingController(
      text: identity?.cameraName ?? defaultInitialName,
    );
    _customPositionController = TextEditingController(
      text: _position == 'Tùy chỉnh' ? savedPosition : '',
    );
    _apiPortController = TextEditingController(text: '8080');
    _loadVenueConfig();
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
      const MethodChannel('vn.vnvar.cameraStation/channel')
          .invokeMethod('setScreenOrientation', {
        'mode': widget.isLandscape ? 'landscape' : 'portrait',
      });
    }
  }

  Future<void> _loadVenueConfig() async {
    final prefs = await SharedPreferences.getInstance();
    _venueName = prefs.getString('venueName')?.trim() ?? '';
    _venueMapAddress = prefs.getString('venueMapAddress')?.trim() ?? '';
    final port = await _config.loadApiPort();
    _apiPortController.text = port.toString();
    if (mounted) {
      setState(() {
        _loadingVenue = false;
      });
    }
  }

  @override
  void dispose() {
    _cameraNameController.dispose();
    _customPositionController.dispose();
    _apiPortController.dispose();
    super.dispose();
  }

  int get _selectedCourtNumber {
    return int.tryParse(_courtId.split('-').last) ?? 1;
  }

  void _selectCourtNumber(int number) {
    if (number < 1) return;
    setState(() {
      _courtId = 'COURT-${number.toString().padLeft(2, '0')}';
    });
  }

  Future<void> _showCourtNumberInputDialog(int current) async {
    final controller = TextEditingController(text: current.toString());
    final result = await showDialog<int>(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          title: Text(
            appText(dialogCtx, 'Nhập số sân', 'Enter court number'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: InputDecoration(
              hintText: appText(
                dialogCtx,
                'Ví dụ: 1, 2, 25...',
                'Example: 1, 2, 25...',
              ),
              border: const OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: Text(appText(dialogCtx, 'HỦY', 'CANCEL')),
            ),
            FilledButton(
              onPressed: () {
                final num = int.tryParse(controller.text.trim());
                if (num != null && num >= 1) {
                  Navigator.of(dialogCtx).pop(num);
                }
              },
              child: Text(appText(dialogCtx, 'XÁC NHẬN', 'CONFIRM')),
            ),
          ],
        );
      },
    );
    if (result != null && mounted) {
      _selectCourtNumber(result);
    }
  }

  void _onCameraIdSelected(String id) {
    setState(() {
      _cameraId = id;
      // Gợi ý tên và vị trí thông minh nếu tên hiện tại theo quy chuẩn mặc định
      final currentName = _cameraNameController.text.trim();
      final isDefaultName =
          currentName.isEmpty ||
          currentName == 'Camera góc trái' ||
          currentName == 'Camera góc phải' ||
          currentName == 'Camera giữa sân' ||
          currentName == 'Left-corner camera' ||
          currentName == 'Right-corner camera' ||
          currentName == 'Center camera';

      if (isDefaultName) {
        final isEn = AppLanguageService.instance.isEnglish;
        switch (id) {
          case 'CAM-01':
            _cameraNameController.text =
                isEn ? 'Left-corner camera' : 'Camera góc trái';
            _position = 'Góc trái sân';
            break;
          case 'CAM-02':
            _cameraNameController.text =
                isEn ? 'Right-corner camera' : 'Camera góc phải';
            _position = 'Góc phải sân';
            break;
          case 'CAM-03':
            _cameraNameController.text =
                isEn ? 'Center camera' : 'Camera giữa sân';
            _position = 'Giữa sân';
            break;
        }
      }
    });
  }

  String _positionLabel(String position) {
    if (!AppLanguageService.instance.isEnglish) return position;
    return switch (position) {
      'Góc trái sân' => 'Left corner',
      'Góc phải sân' => 'Right corner',
      'Giữa sân' => 'Center',
      'Trên cao trung tâm' => 'High center',
      'Baseline A' => 'Baseline A',
      'Baseline B' => 'Baseline B',
      'Góc A' => 'Corner A',
      'Góc B' => 'Corner B',
      'Tùy chỉnh' => 'Custom',
      _ => position,
    };
  }

  String _generateDeviceId() {
    final random = Random.secure();
    final suffix = List.generate(
      6,
      (_) => random.nextInt(16).toRadixString(16),
    ).join().toUpperCase();
    return 'PHONE-$suffix';
  }

  String? _requiredValidator(String? value) {
    if (value == null || value.trim().isEmpty) {
      return appText(
        context,
        'Vui lòng nhập thông tin này.',
        'Required field.',
      );
    }
    return null;
  }

  void _showSetupToast(
    String message, {
    bool isError = false,
    Duration duration = const Duration(seconds: 2),
    IconData? icon,
  }) {
    if (!mounted) return;
    final bg = isError ? const Color(0xFFC62828) : const Color(0xFF1565C0);
    final defIcon = isError
        ? Icons.error_outline_rounded
        : Icons.check_circle_outline_rounded;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          backgroundColor: bg,
          duration: duration,
          content: Row(
            children: [
              Icon(icon ?? defIcon, color: Colors.white, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
  }

  Future<void> _save() async {
    if (_saving || !(_formKey.currentState?.validate() ?? false)) return;

    final cameraName = _cameraNameController.text.trim();
    final cameraPosition = _position == 'Tùy chỉnh'
        ? _customPositionController.text.trim()
        : _position.trim();

    if (cameraPosition.isEmpty) {
      _showSetupToast(
        appText(
          context,
          'Vui lòng nhập vị trí Camera.',
          'Please enter the camera position.',
        ),
        isError: true,
      );
      return;
    }

    setState(() => _saving = true);

    try {
      final identity = StationIdentity(
        courtId: _courtId.trim(),
        cameraId: _cameraId.trim(),
        deviceId: _deviceId.trim(),
        cameraName: cameraName,
        cameraPosition: cameraPosition,
      );
      if (widget.persistOnSave) {
        await _config.saveIdentity(identity);
        final port = int.tryParse(_apiPortController.text.trim()) ?? 8080;
        await _config.saveApiPort(port);
      }
      if (!mounted) return;
      widget.onConfigured(identity);
    } catch (error) {
      if (!mounted) return;
      _showSetupToast(
        appText(
          context,
          'Không thể lưu cấu hình. Vui lòng thử lại sau.',
          'Cannot save settings. Please try again later.',
        ),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _buildSectionHeader({
    required IconData icon,
    required String title,
    String? subtitle,
  }) {
    return Row(
      children: [
        Icon(icon, size: 17, color: const Color(0xFF1565C0)),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.5,
            color: Color(0xFF1E293B),
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11.5,
                color: Color(0xFF64748B),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCourtSelector() {
    final courtNumber = _selectedCourtNumber;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(
            icon: Icons.stadium_rounded,
            title: appText(context, 'SÂN THI ĐẤU', 'COURT'),
            subtitle: _venueName.isNotEmpty ? _venueName : null,
          ),
          if (_venueMapAddress.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(
                  Icons.location_on_outlined,
                  size: 13,
                  color: Color(0xFF64748B),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _venueMapAddress,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          // Stepper bar: [-]  SÂN X  [+] (Tăng giảm tự do không giới hạn 20 sân)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  onPressed: courtNumber > 1
                      ? () => _selectCourtNumber(courtNumber - 1)
                      : null,
                  icon: const Icon(Icons.remove_circle_outline_rounded),
                  color: const Color(0xFF1565C0),
                  iconSize: 28,
                  tooltip: appText(context, 'Giảm sân', 'Decrease court'),
                ),
                InkWell(
                  onTap: () => _showCourtNumberInputDialog(courtNumber),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: Text(
                      '${appText(context, "SÂN", "COURT")} $courtNumber',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF0F172A),
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => _selectCourtNumber(courtNumber + 1),
                  icon: const Icon(Icons.add_circle_outline_rounded),
                  color: const Color(0xFF1565C0),
                  iconSize: 28,
                  tooltip: appText(context, 'Tăng sân', 'Increase court'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCameraIdSelector() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(
            icon: Icons.videocam_rounded,
            title: appText(context, 'CAMERA ID', 'CAMERA ID'),
          ),
          const SizedBox(height: 10),
          Row(
            children: _cameraIds.map((id) {
              final isSelected = id == _cameraId;
              final label = switch (id) {
                'CAM-01' => appText(context, 'Góc trái', 'Left corner'),
                'CAM-02' => appText(context, 'Góc phải', 'Right corner'),
                'CAM-03' => appText(context, 'Giữa sân', 'Center'),
                _ => id,
              };
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: InkWell(
                    onTap: () => _onCameraIdSelected(id),
                    borderRadius: BorderRadius.circular(12),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFF1565C0)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected
                              ? const Color(0xFF1565C0)
                              : const Color(0xFFCBD5E1),
                          width: isSelected ? 1.5 : 1,
                        ),
                        boxShadow: isSelected
                            ? [
                                BoxShadow(
                                  color: const Color(0xFF1565C0).withValues(alpha: 0.22),
                                  blurRadius: 4,
                                  offset: const Offset(0, 2),
                                ),
                              ]
                            : null,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.videocam_rounded,
                            size: 19,
                            color: isSelected
                                ? Colors.white
                                : const Color(0xFF64748B),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            id,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w800,
                              color: isSelected
                                  ? Colors.white
                                  : const Color(0xFF0F172A),
                            ),
                          ),
                          Text(
                            label,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                              color: isSelected
                                  ? Colors.white.withValues(alpha: 0.85)
                                  : const Color(0xFF64748B),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildPositionSelector() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(
            icon: Icons.place_rounded,
            title: appText(context, 'VỊ TRÍ CAMERA', 'CAMERA POSITION'),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _positions.map((pos) {
              final isSelected = _position == pos;
              return Theme(
                data: Theme.of(context).copyWith(
                  canvasColor: Colors.transparent,
                ),
                child: ChoiceChip(
                  label: Text(_positionLabel(pos)),
                  selected: isSelected,
                  showCheckmark: false,
                  visualDensity: const VisualDensity(
                    horizontal: -2,
                    vertical: -3,
                  ),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  onSelected: (selected) {
                    if (selected) {
                      setState(() => _position = pos);
                    }
                  },
                  selectedColor: const Color(0xFF1565C0),
                  backgroundColor: Colors.white,
                  labelStyle: TextStyle(
                    fontSize: 11.5,
                    fontWeight:
                        isSelected ? FontWeight.w700 : FontWeight.w500,
                    color: isSelected
                        ? Colors.white
                        : const Color(0xFF334155),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(
                      color: isSelected
                          ? const Color(0xFF1565C0)
                          : const Color(0xFFCBD5E1),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          if (_position == 'Tùy chỉnh') ...[
            const SizedBox(height: 8),
            TextFormField(
              controller: _customPositionController,
              validator: _requiredValidator,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: appText(
                  context,
                  'Nhập vị trí camera tùy chỉnh',
                  'Enter custom camera position',
                ),
                prefixIcon: const Icon(
                  Icons.edit_location_alt_outlined,
                  size: 20,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDeviceIdFooter() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.perm_device_information_rounded,
            size: 17,
            color: Color(0xFF64748B),
          ),
          const SizedBox(width: 8),
          const Text(
            'Device ID: ',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: Color(0xFF64748B),
            ),
          ),
          Expanded(
            child: SelectableText(
              _deviceId,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1E293B),
              ),
            ),
          ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: const Icon(
              Icons.copy_rounded,
              size: 15,
              color: Color(0xFF64748B),
            ),
            tooltip: appText(
              context,
              'Sao chép Device ID',
              'Copy Device ID',
            ),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _deviceId));
              _showSetupToast(
                appText(
                  context,
                  'Đã sao chép Device ID vào bộ nhớ tạm.',
                  'Device ID copied to clipboard.',
                ),
                icon: Icons.copy_rounded,
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSaveButton() {
    return FilledButton.icon(
      onPressed: _saving ? null : _save,
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        textStyle: const TextStyle(
          fontSize: 15.5,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
        ),
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
          : const Icon(Icons.check_circle_outline_rounded, size: 20),
      label: Text(
        _saving
            ? appText(context, 'ĐANG LƯU...', 'SAVING...')
            : (widget.persistOnSave
                ? appText(context, 'LƯU & KHỞI ĐỘNG', 'SAVE & START')
                : appText(context, 'ÁP DỤNG CẤU HÌNH', 'APPLY SETTINGS')),
      ),
    );
  }

  Widget _buildBrandLogo() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Image.asset(
          'assets/images/vnvar_logo.png',
          height: 32,
          fit: BoxFit.contain,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingVenue) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final media = MediaQuery.sizeOf(context);
    final isLandscape =
        widget.isLandscape || (media.width > media.height && media.width >= 560);
    final canGoBack = widget.onBack != null || Navigator.of(context).canPop();

    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: Colors.white,
        elevation: 0.5,
        centerTitle: true,
        leading: canGoBack
            ? IconButton(
                onPressed: () {
                  if (widget.onBack != null) {
                    widget.onBack!();
                  } else {
                    Navigator.of(context).pop();
                  }
                },
                tooltip: appText(context, 'Quay lại', 'Back'),
                icon: const Icon(
                  Icons.arrow_back_rounded,
                  color: Color(0xFF0F172A),
                ),
              )
            : null,
        title: Text(
          appText(context, 'THIẾT LẬP CAMERA', 'CAMERA SETUP'),
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: Color(0xFF0F172A),
          ),
        ),
        actions: const [
          AppLanguageButton(),
          SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: isLandscape ? 24 : 16,
              vertical: isLandscape ? 12 : 16,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: isLandscape ? 960 : 520,
              ),
              child: Card(
                elevation: 1.5,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: const BorderSide(color: Color(0xFFE2E8F0)),
                ),
                color: Colors.white,
                child: Padding(
                  padding: EdgeInsets.all(isLandscape ? 18 : 18),
                  child: Form(
                    key: _formKey,
                    child: isLandscape
                        ? _buildLandscapeLayout()
                        : _buildPortraitLayout(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPortraitLayout() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildBrandLogo(),
        _buildCourtSelector(),
        const SizedBox(height: 12),
        _buildCameraIdSelector(),
        const SizedBox(height: 12),
        TextFormField(
          controller: _cameraNameController,
          validator: _requiredValidator,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: appText(context, 'Tên Camera', 'Camera name'),
            hintText: appText(
              context,
              'Ví dụ: Camera góc trái',
              'Example: Left-corner camera',
            ),
            prefixIcon: const Icon(Icons.badge_outlined, size: 20),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            filled: true,
            fillColor: const Color(0xFFF8FAFC),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 12,
            ),
          ),
        ),
        const SizedBox(height: 12),
        _buildPositionSelector(),
        const SizedBox(height: 14),
        _buildDeviceIdFooter(),
        const SizedBox(height: 18),
        _buildSaveButton(),
      ],
    );
  }

  Widget _buildLandscapeLayout() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Cột trái: Sân, Camera ID, Tên camera
        Expanded(
          flex: 5,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildBrandLogo(),
              _buildCourtSelector(),
              const SizedBox(height: 12),
              _buildCameraIdSelector(),
              const SizedBox(height: 12),
              TextFormField(
                controller: _cameraNameController,
                validator: _requiredValidator,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: appText(context, 'Tên Camera', 'Camera name'),
                  hintText: appText(
                    context,
                    'Ví dụ: Camera góc trái',
                    'Example: Left-corner camera',
                  ),
                  prefixIcon: const Icon(Icons.badge_outlined, size: 20),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  filled: true,
                  fillColor: const Color(0xFFF8FAFC),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 11,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 18),
        // Cột phải: Vị trí, Device ID, Nút lưu (Port đã ẩn)
        Expanded(
          flex: 5,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildPositionSelector(),
              const SizedBox(height: 12),
              _buildDeviceIdFooter(),
              const SizedBox(height: 14),
              _buildSaveButton(),
            ],
          ),
        ),
      ],
    );
  }
}
