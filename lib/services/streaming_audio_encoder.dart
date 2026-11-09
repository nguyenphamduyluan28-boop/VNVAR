import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_video/return_code.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// Bố cục PCM của một file WAV, đọc từ header.
class WavPcmLayout {
  const WavPcmLayout({
    required this.dataOffset,
    required this.declaredDataBytes,
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
  });

  /// Vị trí byte PCM đầu tiên trong file.
  final int dataOffset;

  /// Số byte PCM header ghi; null khi header chưa chốt (file đang ghi).
  final int? declaredDataBytes;
  final int sampleRate;
  final int channels;
  final int bitsPerSample;

  int get blockAlign => channels * bitsPerSample ~/ 8;
}

/// Đọc bố cục PCM 16-bit từ đầu file WAV. null khi chưa đủ header, không
/// phải WAV hoặc không phải PCM 16-bit mono/stereo.
WavPcmLayout? parseWavPcmLayout(Uint8List bytes) {
  if (bytes.length < 12) return null;
  String tag(int offset) => String.fromCharCodes(bytes, offset, offset + 4);
  if (tag(0) != 'RIFF' || tag(8) != 'WAVE') return null;
  final view = ByteData.sublistView(bytes);
  int? format;
  int? channels;
  int? sampleRate;
  int? bitsPerSample;
  var position = 12;
  while (position + 8 <= bytes.length) {
    final id = tag(position);
    final size = view.getUint32(position + 4, Endian.little);
    final body = position + 8;
    if (id == 'data') {
      if (format == null ||
          channels == null ||
          sampleRate == null ||
          bitsPerSample == null) {
        return null;
      }
      const pcm = 1;
      const extensible = 0xFFFE;
      if ((format != pcm && format != extensible) ||
          bitsPerSample != 16 ||
          channels < 1 ||
          channels > 2 ||
          sampleRate < 8000 ||
          sampleRate > 192000) {
        return null;
      }
      return WavPcmLayout(
        dataOffset: body,
        declaredDataBytes: size == 0 || size == 0xFFFFFFFF ? null : size,
        sampleRate: sampleRate,
        channels: channels,
        bitsPerSample: bitsPerSample,
      );
    }
    if (id == 'fmt ') {
      if (body + 16 > bytes.length) return null;
      format = view.getUint16(body, Endian.little);
      channels = view.getUint16(body + 2, Endian.little);
      sampleRate = view.getUint32(body + 4, Endian.little);
      bitsPerSample = view.getUint16(body + 14, Endian.little);
    }
    if (size == 0xFFFFFFFF) return null;
    position = body + size + (size.isOdd ? 1 : 0);
  }
  return null;
}

/// Số byte PCM đọc được lúc này: không vượt độ dài file, không vượt số byte
/// header đã chốt (nếu có), làm tròn xuống theo khung mẫu.
int availablePcmBytes({
  required int dataOffset,
  required int blockAlign,
  required int fileLength,
  int? declaredDataBytes,
}) {
  var available = fileLength - dataOffset;
  if (available <= 0) return 0;
  if (declaredDataBytes != null && declaredDataBytes < available) {
    available = declaredDataBytes;
  }
  return available - available % blockAlign;
}

/// Lệnh FFmpeg lọc + nén AAC liên tục PCM đọc từ pipe (cùng bộ lọc và
/// bitrate với bước chuyển TS cũ).
List<String> streamingAudioEncodeArguments({
  required String pipePath,
  required String aacPath,
  required WavPcmLayout layout,
  required String filter,
}) => [
  '-y',
  '-hide_banner',
  '-nostats',
  '-loglevel',
  'error',
  '-f',
  's16le',
  '-ar',
  '${layout.sampleRate}',
  '-ac',
  '${layout.channels}',
  '-i',
  pipePath,
  '-af',
  filter,
  '-c:a',
  'aac',
  '-b:a',
  '128k',
  '-f',
  'adts',
  aacPath,
];

/// Lọc tạp âm và nén AAC tiếng của segment NGAY TRONG LÚC QUAY.
///
/// Trước đây khi chốt segment (hết 3 phút, Check VAR), FFmpeg phải lọc và nén
/// lại toàn bộ tiếng của cả segment nên Check VAR chờ 4–9 giây. Lớp này cho
/// một FFmpeg chạy nền đọc PCM của file WAV đang ghi qua một pipe; lúc chốt
/// chỉ còn bơm nốt vài trăm ms cuối, đóng pipe, rồi ghép hình + AAC bằng
/// stream copy.
///
/// An toàn: mọi lỗi (không đọc được WAV, FFmpeg dừng giữa chừng, thiếu byte...)
/// chỉ làm [finish] trả null; RecordingService khi đó chuyển TS theo cách cũ
/// từ file WAV (vẫn còn nguyên). Lớp này không bao giờ sửa hay xoá file WAV.
///
/// Pipe luôn có một đầu đọc giữ chỗ ([_pipeKeeper], không bao giờ đọc khi
/// chạy bình thường) để ghi vào pipe không bao giờ gặp EPIPE/SIGPIPE nếu
/// FFmpeg dừng bất ngờ.
class StreamingAudioEncoder {
  StreamingAudioEncoder._(this.wavPath, this.aacPath, this._filter);

  /// Bắt đầu chạy nền, không chờ. Lỗi khởi động chỉ làm [finish] trả null.
  factory StreamingAudioEncoder.launch({
    required String wavPath,
    required String aacPath,
    required String filter,
  }) {
    final encoder = StreamingAudioEncoder._(wavPath, aacPath, filter);
    encoder._ready = encoder._initialize();
    return encoder;
  }

  final String wavPath;
  final String aacPath;
  final String _filter;
  late final Future<bool> _ready;

  static const Duration _pollInterval = Duration(milliseconds: 250);

  /// FFmpegKit chỉ nhớ một số phiên gần nhất (mặc định 10). Phiên tiếng sống
  /// suốt segment (3 phút) trong khi các lệnh chuyển TS/cắt clip/ffprobe tạo
  /// thêm nhiều phiên; nếu phiên này bị đẩy khỏi lịch sử, FFmpegKit không báo
  /// kết thúc và không đọc được mã trả về. Nâng lịch sử lên đủ lớn một lần.
  static const int _minimumSessionHistory = 200;
  static Future<void>? _sessionHistoryConfigured;

  static Future<void> _ensureSessionHistory() =>
      _sessionHistoryConfigured ??= () async {
        try {
          final current = await FFmpegKitConfig.getSessionHistorySize();
          if ((current ?? 0) < _minimumSessionHistory) {
            await FFmpegKitConfig.setSessionHistorySize(
              _minimumSessionHistory,
            );
          }
        } catch (_) {
          // Không đặt được: lỗi chỉ làm lúc chốt quay về cách cũ.
        }
      }();
  static const Duration _headerWait = Duration(seconds: 3);

  /// Mỗi lần ghi vào pipe tối đa 16 KB (~170 ms tiếng 48 kHz mono).
  static const int _writeChunkBytes = 16 * 1024;

  /// Mỗi nhịp bơm tối đa 32 KB khi đang quay: nếu FFmpeg dừng bất ngờ, pipe
  /// (64 KB) không kịp đầy trước khi biết FFmpeg đã dừng.
  static const int _maxBytesPerTick = 32 * 1024;

  String? _pipePath;
  RandomAccessFile? _pipeWriter;
  RandomAccessFile? _pipeKeeper;
  RandomAccessFile? _wav;
  WavPcmLayout? _layout;
  Timer? _timer;
  Future<void>? _pump;
  Future<File?>? _finishing;
  int _fedBytes = 0;
  int? _sessionId;
  bool _sessionEnded = false;
  bool _failed = false;
  bool _stopped = false;
  bool _disposed = false;
  final Completer<bool> _sessionResult = Completer<bool>();

  /// Số byte PCM đã chuyển cho FFmpeg.
  int get fedBytes => _fedBytes;

  /// Tần số lấy mẫu của file WAV (dùng bù độ trễ mồi AAC khi ghép).
  int get sampleRate => _layout?.sampleRate ?? 48000;

  void _log(String message, [Object? error]) {
    developer.log(
      '[AUDIO-STREAM] $message',
      error: error,
      name: 'RecordingService',
    );
    // Hiện cả trong logcat bản release để biết vì sao phải dùng cách cũ.
    debugPrint(
      '[VNVAR-AUDIO-STREAM] $message${error == null ? '' : ' | $error'}',
    );
  }

  Future<bool> _initialize() async {
    try {
      final layout = await _waitForLayout();
      if (layout == null) {
        _log('No usable WAV header for $wavPath; using full conversion.');
        _failed = true;
        return false;
      }
      _layout = layout;
      if (_disposed) return false;
      await _ensureSessionHistory();
      final pipe = await FFmpegKitConfig.registerNewFFmpegPipe();
      if (pipe == null || _disposed) {
        _failed = true;
        return false;
      }
      _pipePath = pipe;
      // Mở cùng lúc đầu đọc giữ chỗ và đầu ghi: mở pipe một đầu sẽ chờ đầu
      // kia, nên hai lệnh mở tự gỡ chờ cho nhau.
      final keeperOpen = File(pipe).open();
      // writeOnly (không phải *Append): chế độ append của Dart gọi lseek tới
      // cuối file sau khi mở, lseek trên pipe luôn lỗi (ESPIPE) nên mở hỏng.
      // O_TRUNC thì hệ điều hành bỏ qua với pipe.
      final writerOpen = File(pipe).open(mode: FileMode.writeOnly);
      try {
        final opened = await Future.wait([
          keeperOpen,
          writerOpen,
        ]).timeout(const Duration(seconds: 3));
        _pipeKeeper = opened[0];
        _pipeWriter = opened[1];
      } catch (error) {
        unawaited(keeperOpen.then((file) => file.close(), onError: (_) {}));
        unawaited(writerOpen.then((file) => file.close(), onError: (_) {}));
        rethrow;
      }
      _wav = await File(wavPath).open();
      if (_disposed) return false;
      final session = await FFmpegKit.executeWithArgumentsAsync(
        streamingAudioEncodeArguments(
          pipePath: pipe,
          aacPath: aacPath,
          layout: layout,
          filter: _filter,
        ),
        (session) async {
          var success = false;
          try {
            success = ReturnCode.isSuccess(await session.getReturnCode());
          } catch (_) {}
          _sessionEnded = true;
          if (!success && !_stopped) {
            _failed = true;
            _log('FFmpeg stopped unexpectedly for $wavPath.');
          }
          if (!_sessionResult.isCompleted) _sessionResult.complete(success);
        },
      );
      _sessionId = session.getSessionId();
      if (_disposed) return false;
      _timer = Timer.periodic(_pollInterval, (_) => _schedulePump());
      return true;
    } catch (error) {
      _log('Unable to start streaming audio encoder for $wavPath.', error);
      _failed = true;
      return false;
    }
  }

  Future<WavPcmLayout?> _waitForLayout() async {
    final deadline = DateTime.now().add(_headerWait);
    final file = File(wavPath);
    while (true) {
      try {
        final header = await _readHeaderFrom(file);
        if (header != null) {
          final layout = parseWavPcmLayout(header);
          if (layout != null) return layout;
        }
      } on FileSystemException {
        // File chưa tạo xong: thử lại.
      }
      if (_disposed || !DateTime.now().isBefore(deadline)) return null;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  static Future<Uint8List?> _readHeaderFrom(File file) async {
    final raf = await file.open();
    try {
      final length = await raf.length();
      if (length < 44) return null;
      return await raf.read(math.min(length, 8192));
    } finally {
      await raf.close();
    }
  }

  void _schedulePump() {
    if (_pump != null || _stopped || _failed || _sessionEnded) return;
    final pump = _pumpAvailable(maxBytes: _maxBytesPerTick);
    _pump = pump;
    pump.whenComplete(() {
      if (identical(_pump, pump)) _pump = null;
    });
  }

  /// Số byte PCM có thể đọc lúc này (theo header mới nhất).
  Future<int> _availableBytes() async {
    final wav = _wav!;
    final layout = _layout!;
    final length = await wav.length();
    int? declared;
    await wav.setPosition(0);
    final header = await wav.read(math.min(length, 8192));
    final fresh = parseWavPcmLayout(header);
    if (fresh != null && fresh.dataOffset == layout.dataOffset) {
      declared = fresh.declaredDataBytes;
    }
    return availablePcmBytes(
      dataOffset: layout.dataOffset,
      blockAlign: layout.blockAlign,
      fileLength: length,
      declaredDataBytes: declared,
    );
  }

  /// Chuyển phần PCM mới cho FFmpeg. [maxBytes] null = bơm hết.
  Future<void> _pumpAvailable({int? maxBytes}) async {
    try {
      final wav = _wav!;
      final writer = _pipeWriter!;
      final layout = _layout!;
      var target = await _availableBytes();
      if (maxBytes != null) target = math.min(target, _fedBytes + maxBytes);
      while (_fedBytes < target && !_failed && !_sessionEnded) {
        final count = math.min(_writeChunkBytes, target - _fedBytes);
        await wav.setPosition(layout.dataOffset + _fedBytes);
        final bytes = await wav.read(count);
        if (bytes.isEmpty) break;
        await writer.writeFrom(bytes);
        _fedBytes += bytes.length;
      }
    } catch (error) {
      _failed = true;
      _log('Streaming audio pump failed for $wavPath.', error);
    }
  }

  /// Gọi SAU khi file WAV đã chốt (micro đã dừng hoặc đã chuyển sang file
  /// mới). Bơm nốt phần cuối, đóng pipe, chờ FFmpeg xong. Trả file AAC đã
  /// lọc khi đủ toàn bộ tiếng, null khi phải dùng cách cũ.
  Future<File?> finish({Duration timeout = const Duration(seconds: 3)}) =>
      _finishing ??= _finish(timeout);

  Future<File?> _finish(Duration timeout) async {
    final watch = Stopwatch()..start();
    try {
      if (!await _ready) return null;
      _timer?.cancel();
      final pending = _pump;
      if (pending != null) await pending.timeout(const Duration(seconds: 2));
      if (_failed || _sessionEnded || _disposed) return null;
      _stopped = true;
      await _pumpAvailable();
      final total = await _availableBytes();
      if (_failed || _sessionEnded || total <= 0 || _fedBytes != total) {
        _log(
          'Incomplete streamed audio for $wavPath '
          '(fed=$_fedBytes total=$total failed=$_failed); using full conversion.',
        );
        return null;
      }
      // Đóng đầu ghi: FFmpeg nhận EOF, xử lý nốt rồi kết thúc.
      final writer = _pipeWriter;
      _pipeWriter = null;
      await writer?.close().timeout(const Duration(seconds: 2));
      final success = await _sessionResult.future.timeout(timeout);
      final output = File(aacPath);
      if (!success || !await output.exists() || await output.length() <= 0) {
        _log('Streamed AAC missing or failed for $wavPath.');
        return null;
      }
      _log(
        'Streamed audio ready in ${watch.elapsedMilliseconds}ms '
        '($_fedBytes PCM bytes): $aacPath',
      );
      return output;
    } catch (error) {
      _log('Unable to finish streamed audio for $wavPath.', error);
      return null;
    }
  }

  /// Dừng FFmpeg (nếu còn chạy), đóng pipe/file và xoá file AAC tạm. Gọi
  /// sau khi đã dùng xong kết quả [finish] (hoặc khi bỏ segment).
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _stopped = true;
    _timer?.cancel();
    try {
      final finishing = _finishing;
      if (finishing != null) {
        await finishing.timeout(const Duration(seconds: 10));
      }
    } catch (_) {}
    try {
      await _ready.timeout(const Duration(seconds: 5));
    } catch (_) {}
    final sessionId = _sessionId;
    if (!_sessionEnded && sessionId != null) {
      try {
        await FFmpegKit.cancel(sessionId);
      } catch (_) {}
    }
    await _settlePump();
    final writer = _pipeWriter;
    _pipeWriter = null;
    try {
      await writer?.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      await _pipeKeeper?.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    _pipeKeeper = null;
    try {
      await _wav?.close();
    } catch (_) {}
    _wav = null;
    final pipe = _pipePath;
    if (pipe != null) {
      try {
        await FFmpegKitConfig.closeFFmpegPipe(pipe);
      } catch (_) {}
    }
    try {
      final output = File(aacPath);
      if (await output.exists()) await output.delete();
    } catch (_) {}
  }

  /// Chờ lần bơm đang chạy kết thúc. Nếu nó kẹt vì pipe đầy (FFmpeg đã
  /// dừng), đọc bớt từ đầu giữ chỗ để lệnh ghi thoát ra.
  Future<void> _settlePump() async {
    final pending = _pump;
    if (pending == null) return;
    try {
      await pending.timeout(const Duration(milliseconds: 500));
      return;
    } catch (_) {}
    final keeper = _pipeKeeper;
    if (keeper == null) return;
    for (var attempt = 0; attempt < 8; attempt++) {
      try {
        await keeper.read(64 * 1024).timeout(const Duration(seconds: 1));
        await pending.timeout(const Duration(milliseconds: 300));
        return;
      } catch (_) {}
    }
    // Không gỡ được: bỏ đầu giữ chỗ (một fd treo trong trường hợp hiếm này
    // tốt hơn treo việc chốt segment).
    _pipeKeeper = null;
  }
}
