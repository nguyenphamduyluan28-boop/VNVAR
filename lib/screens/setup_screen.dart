import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/station_identity.dart';
import '../services/station_config_service.dart';

class SetupScreen extends StatefulWidget {
  final ValueChanged<StationIdentity> onConfigured;
  final StationIdentity? initialIdentity;
  final bool persistOnSave;
  final VoidCallback? onBack;

  const SetupScreen({
    super.key,
    required this.onConfigured,
    this.initialIdentity,
    this.persistOnSave = true,
    this.onBack,
  });

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  static const List<String> _cameraIds = [
    'CAM-01',
    'CAM-02',
    'CAM-03',
    'CAM-04',
    'CAM-05',
    'CAM-06',
    'CAM-07',
    'CAM-08',
  ];

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
    final identity = widget.initialIdentity;

    _cameraId = identity?.cameraId ?? _cameraIds.first;
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
    _loadCourts();
  }

  Future<void> _loadCourts() async {
    final prefs = await SharedPreferences.getInstance();
    final count = prefs.getInt('courtCount') ?? 1;
    _venueName = prefs.getString('venueName')?.trim() ?? '';
    _venueMapAddress = prefs.getString('venueMapAddress')?.trim() ?? '';
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
    }
  }

  @override
  void dispose() {
    _cameraNameController.dispose();
    _customPositionController.dispose();
    super.dispose();
  }

  String _courtLabel(String courtId) {
    final number = int.tryParse(courtId.split('-').last) ?? 1;
    return _venueName.isEmpty ? 'SÂN $number' : 'SÂN $number · $_venueName';
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
      return 'Vui lòng nhập thông tin này.';
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
        const SnackBar(content: Text('Vui lòng nhập vị trí Camera.')),
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
      if (widget.persistOnSave) await _config.saveIdentity(identity);
      if (!mounted) return;
      widget.onConfigured(identity);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Không thể lưu cấu hình: $error')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingCourts) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      backgroundColor: const Color(0xFFF3F6FA),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: widget.onBack == null
            ? null
            : IconButton(
                onPressed: widget.onBack,
                tooltip: 'Quay lại thông tin sân',
                icon: const Icon(Icons.arrow_back_rounded),
              ),
        title: const Text('THIẾT LẬP CAMERA'),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Card(
                elevation: 2,
                color: Colors.white,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    MediaQuery.sizeOf(context).width < 500 ? 16 : 40,
                    32,
                    MediaQuery.sizeOf(context).width < 500 ? 16 : 40,
                    36,
                  ),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Image.asset(
                          'assets/images/vnvar_logo.png',
                          height: 86,
                          fit: BoxFit.contain,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'CAMERA STATION',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Color(0xFF1565C0),
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 28),
                        const Text(
                          'THIẾT LẬP CAMERA',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 28),
                        TextFormField(
                          controller: _cameraNameController,
                          validator: _requiredValidator,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: 'Tên Camera',
                            hintText: 'Ví dụ: Camera góc trái',
                            prefixIcon: Icon(Icons.badge_outlined),
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 18),
                        DropdownButtonFormField<String>(
                          initialValue: _cameraId,
                          decoration: const InputDecoration(
                            labelText: 'Camera ID',
                            prefixIcon: Icon(Icons.videocam_outlined),
                            border: OutlineInputBorder(),
                          ),
                          items: _cameraIds
                              .map(
                                (id) => DropdownMenuItem(
                                  value: id,
                                  child: Text(id),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _cameraId = value);
                            }
                          },
                        ),
                        const SizedBox(height: 18),
                        DropdownButtonFormField<String>(
                          initialValue: _courtId,
                          decoration: const InputDecoration(
                            labelText: 'Sân',
                            prefixIcon: Icon(Icons.stadium_outlined),
                            border: OutlineInputBorder(),
                          ),
                          items: _courtIds
                              .map(
                                (id) => DropdownMenuItem(
                                  value: id,
                                  child: Text(_courtLabel(id)),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _courtId = value);
                            }
                          },
                        ),
                        if (_venueMapAddress.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.location_on_outlined,
                                size: 17,
                                color: Colors.black54,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  _venueMapAddress,
                                  style: const TextStyle(
                                    color: Colors.black54,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 18),
                        DropdownButtonFormField<String>(
                          initialValue: _position,
                          decoration: const InputDecoration(
                            labelText: 'Vị trí Camera',
                            prefixIcon: Icon(Icons.place_outlined),
                            border: OutlineInputBorder(),
                          ),
                          items: _positions
                              .map(
                                (position) => DropdownMenuItem(
                                  value: position,
                                  child: Text(position),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _position = value);
                            }
                          },
                        ),
                        if (_position == 'Tùy chỉnh') ...[
                          const SizedBox(height: 14),
                          TextFormField(
                            controller: _customPositionController,
                            validator: _requiredValidator,
                            textInputAction: TextInputAction.done,
                            decoration: const InputDecoration(
                              labelText: 'Nhập vị trí Camera',
                              prefixIcon: Icon(
                                Icons.edit_location_alt_outlined,
                              ),
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ],
                        const SizedBox(height: 18),
                        InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Device ID',
                            prefixIcon: Icon(Icons.phone_android_rounded),
                            border: OutlineInputBorder(),
                          ),
                          child: Text(
                            _deviceId,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(height: 30),
                        FilledButton.icon(
                          onPressed: _saving ? null : _save,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(56),
                            textStyle: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w900,
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
                              : const Icon(Icons.save_rounded),
                          label: Text(
                            _saving ? 'ĐANG LƯU...' : 'LƯU & KHỞI ĐỘNG',
                          ),
                        ),
                      ],
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
