import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/app_language_service.dart';

/// Kết quả phân tích dữ liệu từ mã QR.
class QrStreamParseResult {
  final String streamUrl;
  final String? matchId;
  final String? matchTitle;
  final String protocol; // 'rtsp' hoặc 'whip'
  final String? token;
  final bool autoStart;

  const QrStreamParseResult({
    required this.streamUrl,
    this.matchId,
    this.matchTitle,
    this.protocol = 'rtsp',
    this.token,
    this.autoStart = false,
  });

  /// Phân tích chuỗi quét được từ mã QR thành [QrStreamParseResult].
  static QrStreamParseResult? parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;

    // 1. Kiểm tra nếu là JSON
    if (text.startsWith('{') && text.endsWith('}')) {
      try {
        final Map<String, dynamic> data = jsonDecode(text) as Map<String, dynamic>;
        final url = data['stream_url'] ??
            data['streamUrl'] ??
            data['rtsp_url'] ??
            data['rtspUrl'] ??
            data['rtmp_url'] ??
            data['whip_url'] ??
            data['url'];

        if (url != null && url.toString().trim().isNotEmpty) {
          final streamUrl = url.toString().trim();
          final protocol = (data['protocol']?.toString().toLowerCase() == 'whip' ||
                  streamUrl.contains('/whip'))
              ? 'whip'
              : 'rtsp';
          return QrStreamParseResult(
            streamUrl: streamUrl,
            matchId: data['match_id']?.toString() ?? data['matchId']?.toString(),
            matchTitle: data['match_title']?.toString() ??
                data['matchTitle']?.toString() ??
                data['title']?.toString(),
            protocol: protocol,
            token: data['token']?.toString() ?? data['key']?.toString(),
            // Chỉ tự phát khi QR ghi rõ "auto_start": true. Dù vậy, màn hình
            // phát vẫn hỏi lại nếu đích là nền tảng công cộng/máy chủ lạ.
            autoStart: data['auto_start'] == true || data['autoStart'] == true,
          );
        }
      } catch (_) {
        // Nếu parse JSON lỗi thì tiếp tục thử phân tích theo định dạng URL thông thường.
      }
    }

    // 2. Dạng URL trực tiếp (rtmp, rtmps, rtsp)
    if (text.startsWith('rtmp://') ||
        text.startsWith('rtmps://') ||
        text.startsWith('rtsp://')) {
      return QrStreamParseResult(
        streamUrl: text,
        protocol: 'rtsp',
        autoStart: true,
      );
    }

    // 3. Dạng URL WHIP (http/https chứa whip)
    if ((text.startsWith('http://') || text.startsWith('https://')) &&
        text.toLowerCase().contains('whip')) {
      return QrStreamParseResult(
        streamUrl: text,
        protocol: 'whip',
        autoStart: true,
      );
    }

    // 4. Dạng rút gọn: "cam1?key=pk_..." (chỉ tên luồng + key, không phải URL
    // đầy đủ; nếu không "https://x/y?key=1" sẽ bị ghép thành URL rtmp sai).
    if (!text.contains('://') &&
        RegExp(r'^[\w.-]+\?key=[\w.-]+$').hasMatch(text)) {
      final formattedUrl = 'rtmp://media.aqvision.net:11935/live/$text';
      return QrStreamParseResult(
        streamUrl: formattedUrl,
        protocol: 'rtsp',
        autoStart: true,
      );
    }

    return null;
  }
}

enum _ImageScanStatus { found, noCode, invalid, failed }

class _ImageScanOutcome {
  final _ImageScanStatus status;
  final QrStreamParseResult? result;

  const _ImageScanOutcome(this.status, [this.result]);
}

/// Phân tích một file ảnh, trả về mã QR luồng phát hợp lệ đầu tiên.
Future<_ImageScanOutcome> _scanImageFile(
  MobileScannerController controller,
  String path,
) async {
  final capture = await controller.analyzeImage(path);
  if (capture == null || capture.barcodes.isEmpty) {
    return const _ImageScanOutcome(_ImageScanStatus.noCode);
  }
  for (final barcode in capture.barcodes) {
    final raw = barcode.rawValue;
    if (raw == null || raw.trim().isEmpty) continue;
    final parsed = QrStreamParseResult.parse(raw);
    if (parsed != null) {
      return _ImageScanOutcome(_ImageScanStatus.found, parsed);
    }
  }
  return const _ImageScanOutcome(_ImageScanStatus.invalid);
}

void _showImageScanError(
  ScaffoldMessengerState? messenger,
  _ImageScanStatus status,
  Object? error,
) {
  if (messenger == null || !messenger.mounted) return;
  final isEn = AppLanguageService.instance.isEnglish;
  final String message;
  final Color color;
  switch (status) {
    case _ImageScanStatus.found:
      return;
    case _ImageScanStatus.noCode:
      message = isEn
          ? 'No QR code found in the selected photo.'
          : 'Không tìm thấy mã QR trong ảnh đã chọn.';
      color = const Color(0xFFC62828);
    case _ImageScanStatus.invalid:
      message = isEn
          ? 'QR code content is not a valid stream link or match info.'
          : 'Mã QR trong ảnh không phải thông tin luồng phát hợp lệ.';
      color = const Color(0xFFE65100);
    case _ImageScanStatus.failed:
      message = isEn ? 'Error reading photo: $error' : 'Lỗi khi đọc ảnh: $error';
      color = const Color(0xFFC62828);
  }
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
    ),
  );
}

/// Màn hình/Hộp thoại quét mã QR dành cho luồng phát trực tiếp.
class QrStreamScannerDialog extends StatefulWidget {
  const QrStreamScannerDialog({super.key});

  static Future<QrStreamParseResult?> show(BuildContext context) {
    return Navigator.of(context).push<QrStreamParseResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const QrStreamScannerDialog(),
      ),
    );
  }

  /// Đọc mã QR từ một ảnh trong thư viện máy mà KHÔNG mở camera, nên không
  /// phải tạm dừng camera của trạm (đang ghi hình / đang phát cho Tablet).
  /// Trả về null nếu người dùng huỷ hoặc ảnh không có mã hợp lệ (đã báo lỗi
  /// bằng SnackBar).
  static Future<QrStreamParseResult?> scanFromGallery(
    BuildContext context,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final XFile? file;
    try {
      file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 100,
      );
    } catch (error) {
      _showImageScanError(messenger, _ImageScanStatus.failed, error);
      return null;
    }
    if (file == null) return null;

    // Controller chỉ dùng để phân tích ảnh; không gắn vào widget và không
    // start nên không chiếm camera phần cứng.
    final controller = MobileScannerController(autoStart: false);
    try {
      final outcome = await _scanImageFile(controller, file.path);
      if (outcome.result == null) {
        _showImageScanError(messenger, outcome.status, null);
      }
      return outcome.result;
    } catch (error) {
      _showImageScanError(messenger, _ImageScanStatus.failed, error);
      return null;
    } finally {
      controller.dispose();
    }
  }

  @override
  State<QrStreamScannerDialog> createState() => _QrStreamScannerDialogState();
}

class _QrStreamScannerDialogState extends State<QrStreamScannerDialog> {
  late final MobileScannerController _controller;
  bool _hasDetected = false;
  bool _torchOn = false;
  bool _isProcessingImage = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      autoStart: false,
      detectionSpeed: DetectionSpeed.noDuplicates,
      facing: CameraFacing.back,
      torchEnabled: false,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        if (!_controller.value.isRunning) {
          await _controller.start();
        }
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleClose([QrStreamParseResult? result]) async {
    try {
      await _controller.stop();
    } catch (_) {}
    if (mounted) {
      Navigator.of(context).pop(result);
    }
  }

  Future<void> _handleBarcodeDetected(BarcodeCapture capture) async {
    if (_hasDetected) return;

    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.trim().isEmpty) continue;

      final parsed = QrStreamParseResult.parse(raw);
      if (parsed != null) {
        _hasDetected = true;
        HapticFeedback.mediumImpact();
        await _handleClose(parsed);
        break;
      }
    }
  }

  Future<void> _pickImageFromGallery() async {
    if (_isProcessingImage || _hasDetected) return;
    setState(() => _isProcessingImage = true);
    final messenger = ScaffoldMessenger.maybeOf(context);

    try {
      final picker = ImagePicker();
      final XFile? file = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 100,
      );

      if (!mounted) return;
      if (file == null) {
        setState(() => _isProcessingImage = false);
        return;
      }

      final outcome = await _scanImageFile(_controller, file.path);
      if (!mounted) return;

      final parsed = outcome.result;
      if (parsed != null) {
        _hasDetected = true;
        HapticFeedback.mediumImpact();
        await _handleClose(parsed);
        return;
      }
      setState(() => _isProcessingImage = false);
      _showImageScanError(messenger, outcome.status, null);
    } catch (e) {
      if (mounted) {
        setState(() => _isProcessingImage = false);
        _showImageScanError(messenger, _ImageScanStatus.failed, e);
      }
    }
  }

  Future<void> _toggleTorch() async {
    try {
      await _controller.toggleTorch();
    } catch (error) {
      // Máy không có đèn flash/camera đang bận: giữ nguyên trạng thái nút.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLanguageService.instance.isEnglish
                ? 'Flashlight is not available.'
                : 'Không bật được đèn flash.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _torchOn = !_torchOn);
  }

  @override
  Widget build(BuildContext context) {
    final isEn = AppLanguageService.instance.isEnglish;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) async {
        try {
          await _controller.stop();
        } catch (_) {}
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // Camera Scanner View
            MobileScanner(
              controller: _controller,
              onDetect: _handleBarcodeDetected,
              errorBuilder: (context, error) {
                final msg = error.errorDetails?.message ?? error.toString();
                // Bỏ qua lỗi "already running" hoặc "already started" để không che mất màn hình camera
                if (msg.contains('already running') ||
                    msg.contains('already started')) {
                  return const SizedBox.shrink();
                }
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.error_outline_rounded,
                          color: Colors.orangeAccent,
                          size: 36,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          msg,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12.5,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.lightBlueAccent,
                          ),
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: Text(isEn ? 'Retry' : 'Thử lại'),
                          onPressed: () async {
                            try {
                              await _controller.stop();
                              await Future.delayed(
                                const Duration(milliseconds: 200),
                              );
                              await _controller.start();
                            } catch (_) {}
                          },
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),

          // Dark Overlay with Cutout Scanner Frame
          SafeArea(
            child: Column(
              children: [
                // Top App Bar
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton.filledTonal(
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.black54,
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(Icons.close_rounded, size: 22),
                        onPressed: () => _handleClose(),
                      ),
                      Text(
                        isEn ? 'Scan Match QR Code' : 'Quét Mã QR Trận Đấu',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton.filledTonal(
                            tooltip: isEn ? 'Select photo' : 'Chọn ảnh QR',
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.black54,
                              foregroundColor: Colors.white,
                            ),
                            icon: _isProcessingImage
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(
                                    Icons.photo_library_rounded,
                                    size: 20,
                                  ),
                            onPressed: _isProcessingImage ? null : _pickImageFromGallery,
                          ),
                          const SizedBox(width: 8),
                          IconButton.filledTonal(
                            style: IconButton.styleFrom(
                              backgroundColor: _torchOn
                                  ? Colors.amberAccent.withValues(alpha: 0.3)
                                  : Colors.black54,
                              foregroundColor:
                                  _torchOn ? Colors.amberAccent : Colors.white,
                            ),
                            icon: Icon(
                              _torchOn
                                  ? Icons.flash_on_rounded
                                  : Icons.flash_off_rounded,
                              size: 20,
                            ),
                            onPressed: _toggleTorch,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const Spacer(),

                // Visual Reticle (Khung ngắm quét)
                Center(
                  child: Container(
                    width: 260,
                    height: 260,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: Colors.lightBlueAccent,
                        width: 2.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.lightBlueAccent.withValues(alpha: 0.25),
                          blurRadius: 20,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Stack(
                      children: [
                        // Góc viền nổi bật
                        Align(
                          alignment: Alignment.topLeft,
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: const BoxDecoration(
                              border: Border(
                                top: BorderSide(color: Colors.white, width: 4),
                                left: BorderSide(color: Colors.white, width: 4),
                              ),
                              borderRadius: BorderRadius.only(
                                topLeft: Radius.circular(16),
                              ),
                            ),
                          ),
                        ),
                        Align(
                          alignment: Alignment.topRight,
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: const BoxDecoration(
                              border: Border(
                                top: BorderSide(color: Colors.white, width: 4),
                                right: BorderSide(color: Colors.white, width: 4),
                              ),
                              borderRadius: BorderRadius.only(
                                topRight: Radius.circular(16),
                              ),
                            ),
                          ),
                        ),
                        Align(
                          alignment: Alignment.bottomLeft,
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: const BoxDecoration(
                              border: Border(
                                bottom: BorderSide(color: Colors.white, width: 4),
                                left: BorderSide(color: Colors.white, width: 4),
                              ),
                              borderRadius: BorderRadius.only(
                                bottomLeft: Radius.circular(16),
                              ),
                            ),
                          ),
                        ),
                        Align(
                          alignment: Alignment.bottomRight,
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: const BoxDecoration(
                              border: Border(
                                bottom: BorderSide(color: Colors.white, width: 4),
                                right: BorderSide(color: Colors.white, width: 4),
                              ),
                              borderRadius: BorderRadius.only(
                                bottomRight: Radius.circular(16),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const Spacer(),

                // Bottom Instructions Card
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF161B22).withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.5),
                        blurRadius: 16,
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.lightBlueAccent.withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.qr_code_scanner_rounded,
                              color: Colors.lightBlueAccent,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  isEn
                                      ? 'Point camera at match QR code'
                                      : 'Hướng camera về phía mã QR',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  isEn
                                      ? 'Match QR code on sporto.asia / AQP'
                                      : 'Mã QR hiển thị trên sporto.asia hoặc AQP',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.7),
                                    fontSize: 11.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.lightBlueAccent,
                            side: BorderSide(
                              color: Colors.lightBlueAccent.withValues(alpha: 0.5),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          icon: _isProcessingImage
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.lightBlueAccent,
                                  ),
                                )
                              : const Icon(Icons.photo_library_outlined, size: 18),
                          label: Text(
                            isEn
                                ? 'Or pick QR photo from gallery'
                                : 'Hoặc chọn ảnh QR từ thư viện máy',
                            style: const TextStyle(fontSize: 12.5),
                          ),
                          onPressed: _isProcessingImage ? null : _pickImageFromGallery,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
}
