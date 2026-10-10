import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/services.dart';

/// Đích mà bộ chuyển tiếp 4G/5G phải kết nối tới thay cho FFmpeg.
typedef CellularTunnelEndpoint = ({String host, int port, bool tls});

/// Xác định server phát cần đi qua mạng di động. Trả null với giao thức không
/// hỗ trợ chuyển tiếp (RTSPS, WHIP); khi đó luồng chỉ dùng mạng mặc định.
CellularTunnelEndpoint? cellularTunnelEndpoint(String targetUrl) {
  final uri = Uri.tryParse(targetUrl.trim());
  if (uri == null || uri.host.isEmpty) return null;
  final scheme = uri.scheme.toLowerCase();
  final defaultPort = switch (scheme) {
    'rtmp' => 1935,
    'rtmps' => 443,
    'rtsp' => 554,
    _ => null,
  };
  if (defaultPort == null) return null;
  return (
    host: uri.host,
    port: uri.hasPort ? uri.port : defaultPort,
    tls: scheme == 'rtmps',
  );
}

/// URL và tham số FFmpeg khi đẩy qua bộ chuyển tiếp cục bộ ở [localPort].
///
/// RTMPS: bộ chuyển tiếp tự mở TLS tới server thật (đúng SNI và chứng chỉ),
/// nên FFmpeg chỉ nói RTMP thường với 127.0.0.1. `rtmp_tcurl` giữ địa chỉ gốc
/// để server phát (YouTube, Facebook…) nhận đúng ứng dụng và stream key.
({String url, List<String> args}) buildCellularRelayTarget(
  String targetUrl,
  int localPort,
) {
  final uri = Uri.parse(targetUrl.trim());
  final scheme = uri.scheme.toLowerCase();
  final pathAndQuery = '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
  if (scheme == 'rtsp') {
    return (url: 'rtsp://127.0.0.1:$localPort$pathAndQuery', args: const []);
  }
  final segments = uri.pathSegments.where((part) => part.isNotEmpty).toList();
  final app = segments.isEmpty ? '' : segments.first;
  final authority = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  return (
    url: 'rtmp://127.0.0.1:$localPort$pathAndQuery',
    args: ['-rtmp_tcurl', '$scheme://$authority/$app'],
  );
}

/// Kênh native điều khiển đường 4G/5G dự phòng cho livestream.
class CellularUplinkService {
  static const MethodChannel _channel = MethodChannel(
    'vnvar/camera_station_service',
  );

  /// Mở (hoặc dùng lại) bộ chuyển tiếp tới [endpoint]; trả cổng cục bộ, hoặc
  /// null khi máy không có mạng di động khả dụng.
  static Future<int?> openTunnel(CellularTunnelEndpoint endpoint) async {
    if (!Platform.isAndroid && !Platform.isIOS) return null;
    try {
      return await _channel
          .invokeMethod<int>('openCellularTunnel', {
            'host': endpoint.host,
            'port': endpoint.port,
            'tls': endpoint.tls,
          })
          .timeout(const Duration(seconds: 12));
    } catch (error) {
      developer.log(
        '[CELLULAR] Unable to open uplink tunnel: $error',
        name: 'CellularUplinkService',
      );
      return null;
    }
  }

  static Future<void> closeTunnel() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('closeCellularTunnel');
    } catch (_) {}
  }

  /// Mạng mặc định (thường là Wi-Fi) có tới được server phát không: thử mở
  /// một kết nối TCP rồi đóng ngay, không gửi dữ liệu.
  static Future<bool> defaultRouteReaches(CellularTunnelEndpoint endpoint) async {
    try {
      final socket = await Socket.connect(
        endpoint.host,
        endpoint.port,
        timeout: const Duration(seconds: 4),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}
