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
  final ScrollController _courtChipScrollController = ScrollController();

  late final TextEditingController _cameraNameController;
  late final TextEditingController _customPositionController;
  late final TextEditingController _apiPortController;

  late String _cameraId;
  late String _courtId;
  late String _position;
  late String _deviceId;
  bool _saving = false;
  bool _loadingCourts = true;
  List<String> _courtIds = const ['COURT-01'];
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

    _cameraNameController = TextEditingController(
      text: identity?.cameraName ?? 'Camera góc trái',
    );
    _customPositionController = TextEditingController(
      text: _position == 'Tùy chỉnh' ? savedPosition : '',
    );
    _apiPortController = TextEditingController(text: '8080');
    _loadCourts();
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

  Future<void> _loadCourts() async {
    final prefs = await SharedPreferences.getInstance();
    final savedCourtNumber = int.tryParse(_courtId.split('-').last) ?? 1;
    final configuredCount = prefs.getInt('courtCount') ?? 20;
    final count = max(configuredCount, max(savedCourtNumber, 20));
    _venueName = prefs.getString('venueName')?.trim() ?? '';
    _venueMapAddress = prefs.getString('venueMapAddress')?.trim() ?? '';
    _apiPortController.text = (await _config.loadApiPort()).toString();
    final courts = List.generate(
      count,
      (index) => 'COURT-${(index + 1).toString().padLeft(2, '0')}',
    );
    if (!courts.contains(_courtId)) _courtId = courts.first;
    if (mounted) {
      setState(() {
        _courtIds = courts;
        _loadingCourts = false;
      });
      _scrollToSelectedCourt();
    }
  }

  void _scrollToSelectedCourt() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_courtChipScrollController.hasClients) return;
      final selectedIndex = _selectedCourtNumber - 1;
      final targetOffset = (selectedIndex * 50.0) - 80.0;
      _courtChipScrollController.animateTo(
        targetOffset.clamp(
          0.0,
          _courtChipScrollController.position.maxScrollExtent,
        ),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _courtChipScrollController.dispose();
    _cameraNameController.dispose();
    _customPositionController.dispose();
    _apiPortController.dispose();
    super.dispose();
  }

  int get _selectedCourtNumber {
    return int.tryParse(_courtId.split('-').last) ?? 1;
  }

  void _selectCourtNumber(int number) {
    if (number < 1 || number > _courtIds.length) return;
    setState(() {
      _courtId = 'COURT-${number.toString().padLeft(2, '0')}';
    });
    _scrollToSelectedCourt();
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
          currentName == 'Camera giữa sân';

      if (isDefaultName) {
        switch (id) {
          case 'CAM-01':
            _cameraNameController.text = 'Camera góc trái';
            _position = 'Góc trái sân';
            break;
          case 'CAM-02':
            _cameraNameController.text = 'Camera góc phải';
            _position = 'Góc phải sân';
            break;
          case 'CAM-03':
            _cameraNameController.text = 'Camera giữa sân';
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

  Future<void> _save() async {
    if (_saving || !(_formKey.currentState?.validate() ?? false)) return;

    final cameraName = _cameraNameController.text.trim();
    final cameraPosition = _position == 'Tùy chỉnh'
        ? _customPositionController.text.trim()
        : _position.trim();

    if (cameraPosition.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            appText(
              context,
              'Vui lòng nhập vị trí Camera.',
              'Enter the camera position.',
            ),
          ),
        ),
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
        await _config.saveApiPort(int.parse(_apiPortController.text.trim()));
      }
      if (!mounted) return;
      widget.onConfigured(identity);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            appText(
              context,
              'Không thể lưu cấu hình: $error',
              'Cannot save settings: $error',
            ),
          ),
        ),
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
        Icon(icon, size: 18, color: const Color(0xFF1565C0)),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            fontSize: 13,
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
                fontSize: 12,
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
    final totalCourts = _courtIds.length;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(
            icon: Icons.stadium_rounded,
            title: appText(context, 'SÂN THI ĐẤU', 'COURT'),
            subtitle: _venueName.isNotEmpty ? _venueName : null,
          ),
          if (_venueMapAddress.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(
                  Icons.location_on_outlined,
                  size: 14,
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
          const SizedBox(height: 12),
          // Stepper bar: [-]  SÂN X  [+]
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
                  tooltip: appText(context, 'Sân trước', 'Previous court'),
                ),
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        '${appText(context, "SÂN", "COURT")} $courtNumber',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF0F172A),
                          letterSpacing: 0.5,
                        ),
                      ),
                      Text(
                        '$courtNumber / $totalCourts ${appText(context, "sân", "courts")}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF64748B),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: courtNumber < totalCourts
                      ? () => _selectCourtNumber(courtNumber + 1)
                      : null,
                  icon: const Icon(Icons.add_circle_outline_rounded),
                  color: const Color(0xFF1565C0),
                  iconSize: 28,
                  tooltip: appText(context, 'Sân kế tiếp', 'Next court'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // Quick-select chips bar (1, 2, 3... 20)
          SizedBox(
            height: 38,
            child: ListView.separated(
              controller: _courtChipScrollController,
              scrollDirection: Axis.horizontal,
              itemCount: totalCourts,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final num = index + 1;
                final isSelected = num == courtNumber;
                return InkWell(
                  onTap: () => _selectCourtNumber(num),
                  borderRadius: BorderRadius.circular(10),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF1565C0)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isSelected
                            ? const Color(0xFF1565C0)
                            : const Color(0xFFCBD5E1),
                        width: isSelected ? 1.5 : 1.0,
                      ),
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: const Color(0xFF1565C0).withValues(alpha: 0.25),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ]
                          : null,
                    ),
                    child: Text(
                      '$num',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight:
                            isSelected ? FontWeight.w800 : FontWeight.w600,
                        color: isSelected
                            ? Colors.white
                            : const Color(0xFF334155),
                      ),
                    ),
                  ),
                );
              },
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
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(
            icon: Icons.videocam_rounded,
            title: appText(context, 'CAMERA ID', 'CAMERA ID'),
          ),
          const SizedBox(height: 12),
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
                      padding: const EdgeInsets.symmetric(vertical: 10),
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
                                  color: const Color(0xFF1565C0).withValues(alpha: 0.25),
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
                            size: 20,
                            color: isSelected
                                ? Colors.white
                                : const Color(0xFF64748B),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            id,
                            style: TextStyle(
                              fontSize: 14,
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
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(
            icon: Icons.place_rounded,
            title: appText(context, 'VỊ TRÍ CAMERA', 'CAMERA POSITION'),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _positions.map((pos) {
              final isSelected = _position == pos;
              return ChoiceChip(
                label: Text(_positionLabel(pos)),
                selected: isSelected,
                showCheckmark: false,
                onSelected: (selected) {
                  if (selected) {
                    setState(() => _position = pos);
                  }
                },
                selectedColor: const Color(0xFF1565C0),
                backgroundColor: Colors.white,
                labelStyle: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected ? Colors.white : const Color(0xFF334155),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(
                    color: isSelected
                        ? const Color(0xFF1565C0)
                        : const Color(0xFFCBD5E1),
                  ),
                ),
              );
            }).toList(),
          ),
          if (_position == 'Tùy chỉnh') ...[
            const SizedBox(height: 12),
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
                prefixIcon: const Icon(Icons.edit_location_alt_outlined),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.perm_device_information_rounded,
            size: 18,
            color: Color(0xFF64748B),
          ),
          const SizedBox(width: 8),
          Text(
            'Device ID: ',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF64748B),
            ),
          ),
          Expanded(
            child: SelectableText(
              _deviceId,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
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
              size: 16,
              color: Color(0xFF64748B),
            ),
            tooltip: appText(
              context,
              'Sao chép Device ID',
              'Copy Device ID',
            ),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _deviceId));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    appText(
                      context,
                      'Đã sao chép Device ID',
                      'Device ID copied',
                    ),
                  ),
                  duration: const Duration(seconds: 2),
                ),
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
        minimumSize: const Size.fromHeight(50),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        textStyle: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
        ),
      ),
      icon: _saving
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.check_circle_outline_rounded),
      label: Text(
        _saving
            ? appText(context, 'ĐANG LƯU...', 'SAVING...')
            : (widget.persistOnSave
                ? appText(context, 'LƯU & KHỞI ĐỘNG', 'SAVE & START')
                : appText(context, 'ÁP DỤNG CẤU HÌNH', 'APPLY SETTINGS')),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingCourts) {
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
                icon: const Icon(Icons.arrow_back_rounded, color: Color(0xFF0F172A)),
              )
            : null,
        title: Row(
          children: [
            Image.asset(
              'assets/images/vnvar_logo.png',
              height: 28,
              fit: BoxFit.contain,
            ),
            const SizedBox(width: 10),
            Text(
              appText(context, 'THIẾT LẬP CAMERA', 'CAMERA SETUP'),
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: Color(0xFF0F172A),
              ),
            ),
          ],
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
              vertical: isLandscape ? 14 : 20,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: isLandscape ? 980 : 540,
              ),
              child: Card(
                elevation: 1.5,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: const BorderSide(color: Color(0xFFE2E8F0)),
                ),
                color: Colors.white,
                child: Padding(
                  padding: EdgeInsets.all(isLandscape ? 20 : 20),
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
        _buildCourtSelector(),
        const SizedBox(height: 14),
        _buildCameraIdSelector(),
        const SizedBox(height: 14),
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
            prefixIcon: const Icon(Icons.badge_outlined),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            filled: true,
            fillColor: const Color(0xFFF8FAFC),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 14,
            ),
          ),
        ),
        const SizedBox(height: 14),
        _buildPositionSelector(),
        const SizedBox(height: 14),
        TextFormField(
          controller: _apiPortController,
          keyboardType: TextInputType.number,
          validator: (val) {
            final port = int.tryParse(val?.trim() ?? '');
            if (port == null || port < 1024 || port > 65535) {
              return appText(
                context,
                'Port phải từ 1024 - 65535',
                'Port must be between 1024 and 65535',
              );
            }
            return null;
          },
          decoration: InputDecoration(
            labelText: appText(context, 'Cổng API HTTP (Port)', 'API HTTP Port'),
            prefixIcon: const Icon(Icons.lan_outlined),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            filled: true,
            fillColor: const Color(0xFFF8FAFC),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 14,
            ),
          ),
        ),
        const SizedBox(height: 14),
        _buildDeviceIdFooter(),
        const SizedBox(height: 22),
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
              _buildCourtSelector(),
              const SizedBox(height: 14),
              _buildCameraIdSelector(),
              const SizedBox(height: 14),
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
                  prefixIcon: const Icon(Icons.badge_outlined),
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
            ],
          ),
        ),
        const SizedBox(width: 18),
        // Cột phải: Vị trí, Port, Device ID, Nút lưu
        Expanded(
          flex: 5,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildPositionSelector(),
              const SizedBox(height: 14),
              TextFormField(
                controller: _apiPortController,
                keyboardType: TextInputType.number,
                validator: (val) {
                  final port = int.tryParse(val?.trim() ?? '');
                  if (port == null || port < 1024 || port > 65535) {
                    return appText(
                      context,
                      'Port phải từ 1024 - 65535',
                      'Port must be between 1024 and 65535',
                    );
                  }
                  return null;
                },
                decoration: InputDecoration(
                  labelText:
                      appText(context, 'Cổng API HTTP (Port)', 'API HTTP Port'),
                  prefixIcon: const Icon(Icons.lan_outlined),
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
              const SizedBox(height: 14),
              _buildDeviceIdFooter(),
              const SizedBox(height: 16),
              _buildSaveButton(),
            ],
          ),
        ),
      ],
    );
  }
}
