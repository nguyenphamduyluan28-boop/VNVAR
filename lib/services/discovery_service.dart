import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

class DiscoveryService {
  static const int discoveryPort = 40404;

  static const String discoverMessage = 'VNVAR_DISCOVER_V1';

  static const String responseType = 'VNVAR_CAMERA_V1';

  ServerSocket? _socket;

  String? _courtId;
  String? _cameraId;
  String? _deviceId;
  String? _apiToken;

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
    required String apiToken,
    String status = 'READY',
  }) async {
    if (_socket != null) {
      return;
    }

    _courtId = courtId;
    _cameraId = cameraId;
    _deviceId = deviceId;
    _apiToken = apiToken;
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

  Future<void> _handleClient(Socket client) async {
    try {
      client.setOption(SocketOption.tcpNoDelay, true);
      final message = await utf8.decoder
          .bind(client)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 2));
      if (message.trim() != discoverMessage) return;

      client.writeln(
        jsonEncode({
          'type': responseType,
          'courtId': _courtId,
          'cameraId': _cameraId,
          'deviceId': _deviceId,
          'apiPort': _apiPort,
          'apiToken': _apiToken,
          'webrtc': true,
          'transport': 'TCP',
          'status': _status,
        }),
      );
      await client.flush();
    } catch (error, stackTrace) {
      developer.log(
        'TCP discovery client error',
        error: error,
        stackTrace: stackTrace,
        name: 'DiscoveryService',
      );
    } finally {
      await client.close();
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
