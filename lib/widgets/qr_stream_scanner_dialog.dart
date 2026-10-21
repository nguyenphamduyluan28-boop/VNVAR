import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/app_language_service.dart';
import '../theme/app_theme.dart';
import 'app_notice.dart';
import 'brand_widgets.dart';

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
  BuildContext context,
  _ImageScanStatus status,
  Object? error,
) {
  switch (status) {
    case _ImageScanStatus.found:
      return;
    case _ImageScanStatus.noCode:
      showAppNotice(
        context,
        vi: 'Không thấy mã QR trong ảnh',
        en: 'No QR code in this photo',
        kind: NoticeKind.error,
      );
    case _ImageScanStatus.invalid:
      showAppNotice(
        context,
        vi: 'Mã QR không phải thông tin luồng phát',
        en: 'QR code is not a valid stream link',
        kind: NoticeKind.warning,
      );
    case _ImageScanStatus.failed:
      showAppNotice(
        context,
        vi: 'Lỗi đọc ảnh: $error',
        en: 'Error reading photo: $error',
        kind: NoticeKind.error,
      );
  }
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
  /// bằng thông báo nổi).
  static Future<QrStreamParseResult?> scanFromGallery(
    BuildContext context,
  ) async {
    final XFile? file;
    try {
      file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 100,
      );
    } catch (error) {
      if (context.mounted) {
        _showImageScanError(context, _ImageScanStatus.failed, error);
      }
      return null;
    }
    if (file == null) return null;

    // Controller chỉ dùng để phân tích ảnh; không gắn vào widget và không
    // start nên không chiếm camera phần cứng.
    final controller = MobileScannerController(autoStart: false);
    try {
      final outcome = await _scanImageFile(controller, file.path);
      if (outcome.result == null && context.mounted) {
        _showImageScanError(context, outcome.status, null);
      }
      return outcome.result;
    } catch (error) {
      if (context.mounted) {
        _showImageScanError(context, _ImageScanStatus.failed, error);
      }
      return null;
    } finally {
      controller.dispose();
    }
  }

  @override
  State<QrStreamScannerDialog> createState() => _QrStreamScannerDialogState();
}

class _QrStreamScannerDialogState extends State<QrStreamScannerDialog>
    with SingleTickerProviderStateMixin {
  /// Chiều cao thanh trên: nút 52 + đệm 12 × 2.
  static const double _topBarHeight = 76;

  late final MobileScannerController _controller;

  /// Đường quét chạy lên xuống trong khung ngắm (chỉ trang trí).
  late final AnimationController _scanLine;
  bool _hasDetected = false;
  bool _torchOn = false;
  bool _isProcessingImage = false;

  String _t(String vi, String en) => appText(context, vi, en);

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      autoStart: false,
      detectionSpeed: DetectionSpeed.noDuplicates,
      facing: CameraFacing.back,
      torchEnabled: false,
    );
    _scanLine = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

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
    _scanLine.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleClose([QrStreamParseResult? result]) async {
    try {
      await _controller.stop();
    } catch (_) {}
    if (mounted) {
      _scanLine.stop();
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
      _showImageScanError(context, outcome.status, null);
    } catch (e) {
      if (mounted) {
        setState(() => _isProcessingImage = false);
        _showImageScanError(context, _ImageScanStatus.failed, e);
      }
    }
  }

  Future<void> _toggleTorch() async {
    try {
      await _controller.toggleTorch();
    } catch (error) {
      // Máy không có đèn flash/camera đang bận: giữ nguyên trạng thái nút.
      if (!mounted) return;
      showAppNotice(
        context,
        vi: 'Không bật được đèn flash',
        en: 'Flashlight not available',
        kind: NoticeKind.warning,
      );
      return;
    }
    if (!mounted) return;
    setState(() => _torchOn = !_torchOn);
  }

  @override
  Widget build(BuildContext context) {
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
          fit: StackFit.expand,
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
                          color: BrandColors.warning,
                          size: 36,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _t('Không mở được camera', 'Camera unavailable'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: BrandColors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          msg,
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: BrandColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: BrandColors.primaryBright,
                          ),
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: Text(_t('Thử lại', 'Retry')),
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

            // Lớp phủ: tối mờ ngoài khung + thanh trên + hướng dẫn. Tự co
            // theo màn hình (xoay ngang thì khung ngắm và bảng hướng dẫn đặt
            // cạnh nhau) để không tràn.
            LayoutBuilder(
              builder: (context, constraints) => _buildOverlay(constraints),
            ),
          ],
        ),
      ),
    );
  }

  /// Khung ngắm tối đa 260 px, co lại khi màn hình thấp/hẹp.
  static double _reticleSize(double maxWidth, double maxHeight) =>
      math.max(0.0, math.min(260.0, math.min(maxWidth, maxHeight)));

  /// Hình chữ nhật không âm (màn quá nhỏ thì co về 0 thay vì lỗi layout).
  static Rect _safeRect(double left, double top, double right, double bottom) =>
      Rect.fromLTRB(left, top, math.max(left, right), math.max(top, bottom));

  Widget _buildOverlay(BoxConstraints constraints) {
    final insets = MediaQuery.paddingOf(context);
    final content = _safeRect(
      insets.left,
      insets.top + _topBarHeight,
      constraints.maxWidth - insets.right,
      constraints.maxHeight - insets.bottom,
    );
    final landscape = content.width > content.height;
    final Rect frameArea;
    final Rect panelArea;
    if (landscape) {
      final panelWidth = math.min(320.0, content.width * 0.42);
      frameArea = _safeRect(
        content.left,
        content.top,
        content.right - panelWidth,
        content.bottom,
      );
      panelArea = _safeRect(
        frameArea.right,
        content.top,
        content.right,
        content.bottom,
      );
    } else {
      final panelHeight = math.min(148.0, content.height * 0.4);
      frameArea = _safeRect(
        content.left,
        content.top,
        content.right,
        content.bottom - panelHeight,
      );
      panelArea = _safeRect(
        content.left,
        frameArea.bottom,
        content.right,
        content.bottom,
      );
    }
    final size = _reticleSize(frameArea.width - 48, frameArea.height - 24);
    final hole = Rect.fromCenter(
      center: frameArea.center,
      width: size,
      height: size,
    );

    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _ScannerOverlayPainter(
                hole: hole,
                radius: BrandRadius.large,
              ),
            ),
          ),
        ),
        if (size > 0 && !_isProcessingImage)
          Positioned.fromRect(
            rect: hole,
            child: IgnorePointer(child: _buildScanLine()),
          ),
        Positioned(
          left: insets.left,
          right: insets.right,
          top: insets.top,
          height: _topBarHeight,
          child: _buildTopBar(),
        ),
        Positioned.fromRect(
          rect: panelArea,
          child: _buildGuidePanel(landscape),
        ),
      ],
    );
  }

  Widget _buildScanLine() {
    return AnimatedBuilder(
      animation: _scanLine,
      builder: (context, child) => Align(
        alignment: Alignment(
          0,
          -0.86 + 1.72 * Curves.easeInOut.transform(_scanLine.value),
        ),
        child: child,
      ),
      child: FractionallySizedBox(
        widthFactor: 0.84,
        child: Container(
          height: 2,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(2),
            gradient: LinearGradient(
              colors: [
                BrandColors.primaryBright.withValues(alpha: 0),
                BrandColors.primaryBright,
                BrandColors.primaryBright.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: BrandSpace.lg,
        vertical: BrandSpace.md,
      ),
      child: Row(
        children: [
          BrandIconButton(
            icon: Icons.close_rounded,
            tooltip: _t('Đóng', 'Close'),
            onPressed: () => _handleClose(),
          ),
          const SizedBox(width: BrandSpace.md),
          Expanded(
            child: Text(
              _t('Quét QR', 'Scan QR'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: BrandText.title.copyWith(
                shadows: const [Shadow(color: Colors.black87, blurRadius: 6)],
              ),
            ),
          ),
          const SizedBox(width: BrandSpace.md),
          BrandIconButton(
            icon: Icons.photo_library_rounded,
            tooltip: _t('Chọn ảnh QR', 'Pick QR photo'),
            loading: _isProcessingImage,
            onPressed: _pickImageFromGallery,
          ),
          const SizedBox(width: BrandSpace.sm),
          BrandIconButton(
            icon: _torchOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
            tooltip: _t('Đèn flash', 'Flashlight'),
            active: _torchOn,
            onPressed: _toggleTorch,
          ),
        ],
      ),
    );
  }

  /// Hướng dẫn 1 dòng + nút phụ "Chọn ảnh QR" (dưới khung / bên phải khi ngang).
  Widget _buildGuidePanel(bool landscape) {
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          landscape ? 0 : BrandSpace.xl,
          BrandSpace.md,
          landscape ? BrandSpace.lg : BrandSpace.xl,
          BrandSpace.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BrandGlass(
              radius: 999,
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 10,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.qr_code_scanner_rounded,
                    size: 18,
                    color: BrandColors.primaryBright,
                  ),
                  const SizedBox(width: BrandSpace.sm),
                  Flexible(
                    child: Text(
                      _t('Đưa mã QR vào khung', 'Fit the QR in the frame'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: BrandText.body,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: BrandSpace.md),
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: const Color(0x66000000),
                minimumSize: const Size(0, 48),
                padding: const EdgeInsets.symmetric(horizontal: 18),
                shape: const StadiumBorder(
                  side: BorderSide(color: Color(0x33FFFFFF)),
                ),
              ),
              icon: _isProcessingImage
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.photo_library_rounded, size: 18),
              label: Text(
                _t('Chọn ảnh QR', 'Pick QR photo'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onPressed: _isProcessingImage ? null : _pickImageFromGallery,
            ),
          ],
        ),
      ),
    );
  }
}

/// Lớp phủ tối có "lỗ" bo góc ở khung ngắm + viền mảnh + 4 góc trắng.
/// Vẽ trực tiếp (không BackdropFilter) để nhẹ GPU trên hình camera.
class _ScannerOverlayPainter extends CustomPainter {
  const _ScannerOverlayPainter({required this.hole, required this.radius});

  final Rect hole;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = RRect.fromRectAndRadius(hole, Radius.circular(radius));
    final dim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size);
    if (!hole.isEmpty) dim.addRRect(frame);
    canvas.drawPath(dim, Paint()..color = const Color(0x99000000));
    if (hole.isEmpty) return;

    canvas.drawRRect(
      frame,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x40FFFFFF),
    );

    final arm = math.min(40.0, hole.shortestSide / 2);
    final r = math.min(radius, arm);
    final corner = Radius.circular(r);
    final l = hole.left;
    final t = hole.top;
    final rt = hole.right;
    final b = hole.bottom;
    final corners = Path()
      // Trên trái
      ..moveTo(l, t + arm)
      ..lineTo(l, t + r)
      ..arcToPoint(Offset(l + r, t), radius: corner)
      ..lineTo(l + arm, t)
      // Trên phải
      ..moveTo(rt - arm, t)
      ..lineTo(rt - r, t)
      ..arcToPoint(Offset(rt, t + r), radius: corner)
      ..lineTo(rt, t + arm)
      // Dưới phải
      ..moveTo(rt, b - arm)
      ..lineTo(rt, b - r)
      ..arcToPoint(Offset(rt - r, b), radius: corner)
      ..lineTo(rt - arm, b)
      // Dưới trái
      ..moveTo(l + arm, b)
      ..lineTo(l + r, b)
      ..arcToPoint(Offset(l, b - r), radius: corner)
      ..lineTo(l, b - arm);
    canvas.drawPath(
      corners,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_ScannerOverlayPainter oldDelegate) =>
      oldDelegate.hole != hole || oldDelegate.radius != radius;
}
