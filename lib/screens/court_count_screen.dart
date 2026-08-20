import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CourtCountScreen extends StatefulWidget {
  final ValueChanged<int> onSaved;

  const CourtCountScreen({super.key, required this.onSaved});

  @override
  State<CourtCountScreen> createState() => _CourtCountScreenState();
}

class _CourtCountScreenState extends State<CourtCountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _countController = TextEditingController();
  final _venueNameController = TextEditingController();
  final _mapAddressController = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final prefs = await SharedPreferences.getInstance();
    final count = prefs.getInt('courtCount');
    _countController.text = count == null ? '' : '$count';
    _venueNameController.text = prefs.getString('venueName') ?? '';
    _mapAddressController.text = prefs.getString('venueMapAddress') ?? '';
  }

  Future<void> _save() async {
    if (_saving || !(_formKey.currentState?.validate() ?? false)) return;
    final count = int.parse(_countController.text.trim());
    setState(() => _saving = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('courtCount', count);
      await prefs.setString('venueName', _venueNameController.text.trim());
      await prefs.setString(
        'venueMapAddress',
        _mapAddressController.text.trim(),
      );
      if (mounted) widget.onSaved(count);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _required(String? value) {
    return value == null || value.trim().isEmpty
        ? 'Vui lòng nhập thông tin này.'
        : null;
  }

  @override
  void dispose() {
    _countController.dispose();
    _venueNameController.dispose();
    _mapAddressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F6FA),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Card(
              margin: const EdgeInsets.all(24),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Image.asset(
                        'assets/images/vnvar_logo.png',
                        height: 80,
                        fit: BoxFit.contain,
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'THIẾT LẬP HỆ THỐNG SÂN',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'THÔNG TIN SÂN',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF1565C0),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: _venueNameController,
                        validator: _required,
                        decoration: const InputDecoration(
                          labelText: 'Tên sân Pickleball',
                          hintText: 'Ví dụ: VNVAR Pickleball Center',
                          prefixIcon: Icon(Icons.business_rounded),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _mapAddressController,
                        validator: _required,
                        maxLines: 2,
                        decoration: const InputDecoration(
                          labelText: 'Địa chỉ / vị trí trên bản đồ',
                          hintText: 'Ví dụ: 123 Nguyễn Trãi, Quận 1, TP.HCM',
                          prefixIcon: Icon(Icons.location_on_rounded),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _countController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Số lượng sân Pickleball',
                          hintText: 'Ví dụ: 8',
                          prefixIcon: Icon(Icons.stadium_rounded),
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          final count = int.tryParse(value?.trim() ?? '');
                          return count == null || count <= 0 || count > 99
                              ? 'Vui lòng nhập số từ 1 đến 99.'
                              : null;
                        },
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: _saving ? null : _save,
                        icon: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.arrow_forward_rounded),
                        label: const Text('TIẾP TỤC THIẾT LẬP CAMERA'),
                      ),
                    ],
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
