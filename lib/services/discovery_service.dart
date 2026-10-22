import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Đóng kết nối discovery mà không bao giờ ném lỗi. [graceful]: đã trả lời
/// xong thì đóng chiều ghi và chờ tối đa [timeout]; ngược lại (client im lặng,
/// lỗi) huỷ socket ngay.
Future<void> closeDiscoveryClient(
  Socket client, {
  required bool graceful,
  Duration timeout = const Duration(seconds: 2),
}) async {
  if (graceful) {
    try {
      await client.close().timeout(timeout);
      return;
    } catch (_) {
      // Đóng lỗi/quá hạn: huỷ hẳn bên dưới.
    }
  }
  try {
    client.destroy();
  } catch (_) {}
}

class DiscoveryService {
  DiscoveryService({this.clientTimeout = const Duration(seconds: 2)});

  static const int discoveryPort = 40404;

  /// Thời gian chờ dòng lệnh discovery của một client trước khi đóng kết nối.
  final Duration clientTimeout;

  static const String discoverMessage = 'VNVAR_DISCOVER_V1';

  static const String responseType = 'VNVAR_CAMERA_V1';

  ServerSocket? _socket;

  String? _courtId;
  String? _cameraId;
  String? _deviceId;

  int _apiPort = 8080;

  String _status = 'READY';

  bool get running => _socket != null;

  // ============================================================
  // START
  // ============================================================

  /// Starts the legacy VNVAR discovery protocol over TCP.
  ///
  /// Despite the old `startBroadcast` name, this has never been a UDP/LAN
  /// broadcast: the tablet connects to TCP port 40404 and sends one line.
  Future<void> startTcpDiscovery({
    required String courtId,
    required String cameraId,
    required String deviceId,
    required int port,
    String status = 'READY',
  }) async {
    if (_socket != null) {
      return;
    }

    _courtId = courtId;
    _cameraId = cameraId;
    _deviceId = deviceId;
    _apiPort = port;
    _status = status;

    final socket = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      shared: true,
    );

    _socket = socket;

    developer.log(
      'Discovery listening on TCP $discoveryPort '
      '[$courtId/$cameraId/$deviceId]',
      name: 'DiscoveryService',
    );

    socket.listen(
      _handleClient,
      onError: (Object error, StackTrace stackTrace) {
        developer.log(
          'Discovery socket error',
          error: error,
          stackTrace: stackTrace,
          name: 'DiscoveryService',
        );
      },
    );
  }

  // ============================================================
  // UPDATE STATUS
  // ============================================================

  void updateStatus(String status) {
    _status = status;

    developer.log(
      'Discovery status updated: $_status',
      name: 'DiscoveryService',
    );
  }

  // ============================================================
  // HANDLE DISCOVERY
  // ============================================================

  /// Chỉ dùng trong test: xử lý một kết nối discovery đã nhận.
  @visibleForTesting
  Future<void> debugHandleClient(Socket client) => _handleClient(client);

  Future<void> _handleClient(Socket client) async {
    StreamSubscription<String>? subscription;
    var responded = false;
    try {
      client.setOption(SocketOption.tcpNoDelay, true);
      final firstLine = Completer<String?>();
      subscription = utf8.decoder
          .bind(client)
          .transform(const LineSplitter())
          .listen(
            (line) {
              if (!firstLine.isCompleted) firstLine.complete(line);
            },
            onError: (Object error, StackTrace stackTrace) {
              if (!firstLine.isCompleted) {
                firstLine.completeError(error, stackTrace);
              }
            },
            onDone: () {
              if (!firstLine.isCompleted) firstLine.complete(null);
            },
            cancelOnError: true,
          );
      // Client im lặng quá hạn: bỏ (subscription bị huỷ và socket bị đóng
      // hẳn ở finally, không treo tài nguyên).
      final message = await firstLine.future.timeout(
        clientTimeout,
        onTimeout: () => null,
      );
      if (message == null || message.trim() != discoverMessage) return;

      client.writeln(
        jsonEncode({
          'type': responseType,
          'courtId': _courtId,
          'cameraId': _cameraId,
          'deviceId': _deviceId,
          'apiPort': _apiPort,
          'webrtc': true,
          'transport': 'TCP',
          'status': _status,
        }),
      );
      await client.flush();
      responded = true;
    } catch (error, stackTrace) {
      developer.log(
        'TCP discovery client error',
        error: error,
        stackTrace: stackTrace,
        name: 'DiscoveryService',
      );
    } finally {
      try {
        await subscription?.cancel();
      } catch (_) {}
      await closeDiscoveryClient(client, graceful: responded);
    }
  }

  // ============================================================
  // STOP
  // ============================================================

  Future<void> stop() async {
    final socket = _socket;

    _socket = null;

    await socket?.close();

    developer.log('Discovery stopped', name: 'DiscoveryService');
  }
}
