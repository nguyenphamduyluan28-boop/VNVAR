import 'dart:async';
import 'dart:io';

/// Đích TLS của một URL livestream RTMPS (null nếu không phải `rtmps://`).
typedef TlsRelayEndpoint = ({String host, int port});

TlsRelayEndpoint? rtmpsRelayEndpoint(String targetUrl) {
  final uri = Uri.tryParse(targetUrl.trim());
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme.toLowerCase() != 'rtmps') return null;
  return (host: uri.host, port: uri.hasPort ? uri.port : 443);
}

/// Bộ chuyển tiếp TLS cục bộ cho livestream RTMPS (Facebook, YouTube RTMPS…).
///
/// Bản FFmpeg app dùng (`ffmpeg_kit_flutter_new_video`) không có thư viện TLS
/// nên không tự mở được `rtmps://`. FFmpeg đẩy RTMP thường tới 127.0.0.1, bộ
/// này mở TLS tới server thật (đúng SNI, kiểm chứng chỉ theo kho hệ thống) và
/// chuyển dữ liệu hai chiều. Dùng mạng mặc định (Wi-Fi/Ethernet); đường 4G/5G
/// dự phòng có bộ chuyển tiếp native riêng (CellularUplinkService).
class TlsStreamRelay {
  TlsStreamRelay._(
    this.host,
    this.port,
    this._server,
    this._connectTimeout,
    this._context,
    this._onBadCertificate,
    this._log,
  );

  /// Server thật (tên miền dùng cho SNI và kiểm chứng chỉ).
  final String host;
  final int port;
  final ServerSocket _server;
  final Duration _connectTimeout;
  final SecurityContext? _context;
  final bool Function(X509Certificate certificate)? _onBadCertificate;
  final void Function(String message)? _log;
  final Set<Socket> _sockets = {};
  bool _closed = false;

  /// Lỗi gần nhất khi mở TLS tới server (null nếu chưa lỗi).
  Object? lastError;

  /// Cổng 127.0.0.1 mà FFmpeg kết nối tới.
  int get localPort => _server.port;

  bool get isClosed => _closed;

  /// Mở bộ chuyển tiếp trên 127.0.0.1 (cổng ngẫu nhiên). [context] và
  /// [onBadCertificate] chỉ dùng cho test; mặc định tin kho chứng chỉ hệ thống.
  static Future<TlsStreamRelay> start(
    String host,
    int port, {
    Duration connectTimeout = const Duration(seconds: 10),
    SecurityContext? context,
    bool Function(X509Certificate certificate)? onBadCertificate,
    void Function(String message)? log,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final relay = TlsStreamRelay._(
      host,
      port,
      server,
      connectTimeout,
      context,
      onBadCertificate,
      log,
    );
    server.listen(
      relay._accept,
      onError: (Object error) => log?.call('TLS relay listener error: $error'),
      cancelOnError: false,
    );
    return relay;
  }

  Future<void> _accept(Socket local) async {
    if (_closed) {
      local.destroy();
      return;
    }
    _sockets.add(local);
    final SecureSocket remote;
    try {
      remote = await SecureSocket.connect(
        host,
        port,
        context: _context,
        onBadCertificate: _onBadCertificate,
        timeout: _connectTimeout,
      );
    } catch (error) {
      lastError = error;
      _log?.call('TLS relay cannot reach $host:$port: $error');
      _sockets.remove(local);
      local.destroy();
      return;
    }
    if (_closed) {
      remote.destroy();
      _sockets.remove(local);
      local.destroy();
      return;
    }
    lastError = null;
    _sockets.add(remote);
    for (final socket in <Socket>[local, remote]) {
      try {
        socket.setOption(SocketOption.tcpNoDelay, true);
      } catch (_) {}
    }
    var finished = false;
    void closeBoth() {
      if (finished) return;
      finished = true;
      local.destroy();
      remote.destroy();
      _sockets
        ..remove(local)
        ..remove(remote);
    }

    // pipe() tôn trọng nghẽn (chờ socket kia nhận xong) và đóng chiều kia khi
    // một chiều kết thúc; lỗi ở bất kỳ chiều nào thì đóng cả hai.
    unawaited(
      local
          .cast<List<int>>()
          .pipe(remote)
          .catchError((Object _) {})
          .whenComplete(closeBoth),
    );
    unawaited(
      remote
          .cast<List<int>>()
          .pipe(local)
          .catchError((Object _) {})
          .whenComplete(closeBoth),
    );
  }

  /// Đóng cổng cục bộ và mọi kết nối đang chuyển tiếp.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    _sockets.clear();
    await _server.close();
  }
}
