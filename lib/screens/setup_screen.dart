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
          ),
          const SizedBox(height: 10),
          // Stepper bar: [-]  SÂN X  [+] (từ 1 tới _maxCourtNumber)
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
                  onPressed: courtNumber < _maxCourtNumber
                      ? () => _selectCourtNumber(courtNumber + 1)
                      : null,
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
          Text(
            appText(context, 'Mã thiết bị: ', 'Device ID: '),
            style: const TextStyle(
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
    if (_loadingConfig) {
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
        // Cột trái: Logo, Sân
        Expanded(
          flex: 5,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildBrandLogo(),
              _buildCourtSelector(),
            ],
          ),
        ),
        const SizedBox(width: 18),
        // Cột phải: Camera ID, Device ID, Nút lưu
        Expanded(
          flex: 5,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildCameraIdSelector(),
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
            'Ví dụ: 1, 2, 25...',
            'Example: 1, 2, 25...',
          ),
          errorText: _invalid
              ? appText(
                  context,
                  'Số sân từ 1 đến $maxCourt',
                  'Court number must be 1 to $maxCourt',
                )
              : null,
          border: const OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(appText(context, 'HỦY', 'CANCEL')),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(appText(context, 'XÁC NHẬN', 'CONFIRM')),
        ),
      ],
    );
  }
}
