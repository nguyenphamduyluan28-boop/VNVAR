import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'webrtc_service.dart';

enum WhipPublishState { idle, connecting, publishing, reconnecting, error }

/// Chỉ chấp nhận chứng chỉ TLS tự ký với máy chủ WHIP trong mạng nội bộ
/// (ví dụ MediaMTX đặt tại sân). Máy chủ trên Internet luôn được kiểm tra
/// chứng chỉ đầy đủ.
bool allowsSelfSignedWhipCertificate(String host) {
  final name = host.toLowerCase();
  if (name == 'localhost' || name.endsWith('.local')) return true;
  final address = InternetAddress.tryParse(host);
  if (address == null) return false;
  if (address.isLoopback || address.isLinkLocal) return true;
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return bytes[0] == 10 ||
        (bytes[0] == 192 && bytes[1] == 168) ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31);
  }
  // IPv6 unique local fc00::/7.
  return (bytes[0] & 0xfe) == 0xfc;
}

class WhipPublisherService {
  WhipPublishState _state = WhipPublishState.idle;
  final StreamController<WhipPublishState> _stateController =
      StreamController<WhipPublishState>.broadcast();

  RTCPeerConnection? _peerConnection;
  String? _sessionResourceUrl;
  String? _endpointUrl;
  String? _bearerToken;
  WebRtcService? _webRtcService;

  DateTime? _connectedAt;
  String? _currentError;
  int _retryAttempt = 0;
  Timer? _reconnectTimer;
  Timer? _durationTimer;
  Duration _liveDuration = Duration.zero;
  bool _intentionalStop = false;

  static const int maxReconnectAttempts = 6;
  static const int slowRetrySeconds = 30;
  static const List<int> _backoffDelaysSeconds = [2, 4, 6, 10, 15, 20];

  static const Map<String, dynamic> _rtcConfiguration = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  WhipPublishState get state => _state;
  Stream<WhipPublishState> get onStateChanged => _stateController.stream;
  DateTime? get connectedAt => _connectedAt;
  Duration get liveDuration => _liveDuration;
  String? get currentError => _currentError;
  String? get currentEndpoint => _endpointUrl;
  bool get isLive => _state == WhipPublishState.publishing;

  /// Người dùng đang muốn phát (chưa bấm dừng), kể cả khi phiên đang tạm dừng
  /// vì camera đổi cấu hình hoặc đang kết nối lại.
  bool get wantsPublishing =>
      !_intentionalStop &&
      (_endpointUrl?.isNotEmpty ?? false) &&
      _state != WhipPublishState.idle;

  /// Runtime tạo WebRtcService mới sau mỗi lần khởi động lại; publisher phải
  /// dùng instance hiện hành thay vì instance đã bị dispose.
  void attachWebRtcService(WebRtcService? webRtcService) {
    _webRtcService = webRtcService;
  }

  void _setState(WhipPublishState newState) {
    if (_state == newState) return;
    _state = newState;
    if (newState == WhipPublishState.publishing) {
      _connectedAt ??= DateTime.now();
      _startDurationTimer();
    } else if (newState == WhipPublishState.idle ||
        newState == WhipPublishState.error) {
      _stopDurationTimer();
      _connectedAt = null;
      _liveDuration = Duration.zero;
    }
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  void _startDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_connectedAt != null && !_stateController.isClosed) {
        _liveDuration = DateTime.now().difference(_connectedAt!);
        _stateController.add(_state);
      }
    });
  }

  void _stopDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = null;
  }

  /// Starts publishing the active camera track to the partner's WHIP endpoint.
  Future<void> startPublish({
    required String endpointUrl,
    WebRtcService? webRtcService,
    String? bearerToken,
  }) async {
    _intentionalStop = false;
    _endpointUrl = endpointUrl.trim();
    _bearerToken = bearerToken?.trim();
    _webRtcService = webRtcService;
    _currentError = null;

    if (_endpointUrl == null || _endpointUrl!.isEmpty) {
      _intentionalStop = true; // Cấu hình sai: không tự phát lại.
      _currentError = 'Chưa cấu hình URL WHIP Endpoint.';
      _setState(WhipPublishState.error);
      return;
    }

    _setState(WhipPublishState.connecting);
    await _executePublish();
  }

  Future<void> _executePublish() async {
    final webRtc = _webRtcService;
    final stream = webRtc?.localStream;

    if (webRtc == null || stream == null || !webRtc.cameraInitialized) {
      // Camera có thể đang được khôi phục/đổi cấu hình: thử lại theo backoff
      // thay vì dừng hẳn ở trạng thái lỗi.
      _scheduleReconnect('Camera chưa sẵn sàng hoặc chưa khởi động.');
      return;
    }

    await _cleanupConnection();
    HttpClient? client;

    try {
      final pc = await createPeerConnection(_rtcConfiguration);
      _peerConnection = pc;

      // 1. Add video track from active local camera
      final videoTracks = stream.getVideoTracks();
      if (videoTracks.isEmpty) {
        throw StateError('Không tìm thấy VideoTrack từ camera.');
      }
      for (final track in videoTracks) {
        await pc.addTrack(track, stream);
      }

      // 2. Add audio track if available and permitted
      if (webRtc.microphoneEnabled && webRtc.localAudioTrack != null) {
        for (final track in stream.getAudioTracks()) {
          await pc.addTrack(track, stream);
        }
      }

      // 3. Set transceivers to send-only
      final transceivers = await pc.transceivers;
      for (final transceiver in transceivers) {
        await transceiver.setDirection(TransceiverDirection.SendOnly);
      }

      // 4. Connection state handler
      pc.onConnectionState = (RTCPeerConnectionState connectionState) {
        developer.log(
          '[WHIP] PeerConnection state: $connectionState',
          name: 'WhipPublisherService',
        );
        // Bỏ qua sự kiện của PeerConnection cũ đã bị thay thế/đóng.
        if (!identical(_peerConnection, pc)) return;
        if (connectionState ==
            RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _retryAttempt = 0;
          _reconnectTimer?.cancel();
          _currentError = null;
          _setState(WhipPublishState.publishing);
        } else if (connectionState ==
                RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            connectionState ==
                RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          if (!_intentionalStop) {
            _scheduleReconnect('Mất kết nối mạng tới Server');
          }
        }
      };

      // 5. Create SDP Offer
      final offer = await pc.createOffer({
        'offerToReceiveVideo': false,
        'offerToReceiveAudio': false,
      });
      await pc.setLocalDescription(offer);

      // Wait for ICE candidates gathering (up to 2.5s) to produce complete SDP
      if (pc.iceGatheringState !=
          RTCIceGatheringState.RTCIceGatheringStateComplete) {
        await _waitForIceGatheringComplete(
          pc,
        ).timeout(const Duration(milliseconds: 2500), onTimeout: () {});
      }

      final localDesc = await pc.getLocalDescription();
      final offerSdp = localDesc?.sdp ?? offer.sdp;
      if (offerSdp == null || offerSdp.isEmpty) {
        throw StateError('Không thể tạo SDP Offer.');
      }

      // 6. Send HTTP POST to partner's WHIP endpoint
      final httpClient = HttpClient();
      client = httpClient;
      httpClient.connectionTimeout = const Duration(seconds: 12);
      // Support self-signed or internal test certificates
      // Không bỏ qua kiểm tra chứng chỉ với máy chủ Internet; chỉ cho phép
      // chứng chỉ tự ký với máy chủ trong mạng nội bộ.
      httpClient.badCertificateCallback = (cert, host, port) =>
          allowsSelfSignedWhipCertificate(host);

      final uri = Uri.parse(_endpointUrl!);
      developer.log(
        '[WHIP] Connecting to WHIP endpoint: $uri',
        name: 'WhipPublisherService',
      );
      final request = await httpClient.postUrl(uri);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/sdp');
      request.headers.set(HttpHeaders.acceptHeader, 'application/sdp');

      if (_bearerToken != null && _bearerToken!.isNotEmpty) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $_bearerToken',
        );
      }

      request.write(offerSdp);
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );

      if (response.statusCode == HttpStatus.ok ||
          response.statusCode == HttpStatus.created) {
        // Extract session URL for teardown
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location != null && location.isNotEmpty) {
          _sessionResourceUrl = uri.resolve(location).toString();
        }

        final answerSdp = await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 20));
        if (answerSdp.isEmpty) {
          throw StateError('Server trả về Answer SDP rỗng.');
        }

        await pc.setRemoteDescription(
          RTCSessionDescription(answerSdp, 'answer'),
        );

        _retryAttempt = 0;
        _currentError = null;
        _setState(WhipPublishState.publishing);
        developer.log(
          '[WHIP] Successfully published stream to $_endpointUrl',
          name: 'WhipPublisherService',
        );
      } else {
        final errorBody = await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 20));
        throw HttpException(
          'WHIP Server từ chối (${response.statusCode}): ${errorBody.isEmpty ? response.reasonPhrase : errorBody}',
          uri: uri,
        );
      }
    } catch (e, stackTrace) {
      final formattedError = _formatErrorMessage(e);
      _currentError = formattedError;
      developer.log(
        '[WHIP] Publish error: $formattedError',
        error: e,
        stackTrace: stackTrace,
        name: 'WhipPublisherService',
      );
      if (!_intentionalStop) {
        _scheduleReconnect(formattedError);
      }
    } finally {
      client?.close();
    }
  }

  String _formatErrorMessage(Object error) {
    final str = error.toString();
    if (error is SocketException) {
      return 'Không thể kết nối đến server. Vui lòng kiểm tra IP máy tính, cổng 8889 và đảm bảo MediaMTX đang chạy.';
    }
    if (error is HttpException) {
      return error.message;
    }
    if (str.contains('Cleartext HTTP traffic')) {
      return 'Lỗi: Thiết bị chặn kết nối HTTP không bảo mật.';
    }
    return str.replaceAll('Exception: ', '').replaceAll('StateError: ', '');
  }

  Future<void> _waitForIceGatheringComplete(RTCPeerConnection pc) async {
    if (pc.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      return;
    }
    final completer = Completer<void>();
    pc.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !completer.isCompleted) {
        completer.complete();
      }
    };
    try {
      await completer.future.timeout(const Duration(milliseconds: 1800));
    } catch (_) {
      // Timeout is acceptable; candidates in localDesc will be used
    }
  }

  void _scheduleReconnect(String reason) {
    if (_intentionalStop) return;

    _currentError = reason;
    // Hết các lần thử nhanh thì vẫn thử tiếp thưa hơn cho tới khi có mạng.
    final slowRetry = _retryAttempt >= maxReconnectAttempts;
    if (slowRetry) {
      _currentError =
          'Mất kết nối tới server WHIP; tự thử lại mỗi $slowRetrySeconds giây: $reason';
    }

    _setState(WhipPublishState.reconnecting);
    final delaySeconds = slowRetry
        ? slowRetrySeconds
        : _backoffDelaysSeconds[_retryAttempt.clamp(
            0,
            _backoffDelaysSeconds.length - 1,
          )];
    _retryAttempt++;

    developer.log(
      '[WHIP] Reconnecting in ${delaySeconds}s (attempt $_retryAttempt/$maxReconnectAttempts)...',
      name: 'WhipPublisherService',
    );

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      if (!_intentionalStop) {
        _executePublish();
      }
    });
  }

  /// Mạng của điện thoại vừa thay đổi: nếu đang chờ kết nối lại thì thử ngay.
  /// Phiên đang phát để WebRTC/ICE tự phát hiện và báo mất kết nối.
  void handleNetworkChange() {
    if (!wantsPublishing) return;
    if (_state != WhipPublishState.reconnecting &&
        _state != WhipPublishState.error) {
      return;
    }
    _retryAttempt = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    unawaited(_executePublish());
  }

  /// Stops publishing and gracefully tears down the remote session.
  Future<void> stopPublish() async {
    _intentionalStop = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _retryAttempt = 0;

    // Gracefully send HTTP DELETE to session resource URL (RFC 9450)
    if (_sessionResourceUrl != null) {
      try {
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 4);
        try {
          final request = await client.deleteUrl(
            Uri.parse(_sessionResourceUrl!),
          );
          if (_bearerToken != null && _bearerToken!.isNotEmpty) {
            request.headers.set(
              HttpHeaders.authorizationHeader,
              'Bearer $_bearerToken',
            );
          }
          final response = await request.close().timeout(
            const Duration(seconds: 6),
          );
          await response.drain<void>().timeout(const Duration(seconds: 6));
          developer.log(
            '[WHIP] Session deleted: ${response.statusCode}',
            name: 'WhipPublisherService',
          );
        } finally {
          client.close();
        }
      } catch (e) {
        developer.log(
          '[WHIP] Session delete error (non-fatal): $e',
          name: 'WhipPublisherService',
        );
      }
      _sessionResourceUrl = null;
    }

    await _cleanupConnection();
    _setState(WhipPublishState.idle);
    developer.log('[WHIP] Publish stopped', name: 'WhipPublisherService');
  }

  Future<void> prepareForReconfiguration() async {
    if (!wantsPublishing) return;
    developer.log(
      '[WHIP] Preparing for camera reconfiguration (pausing WHIP)...',
      name: 'WhipPublisherService',
    );
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _setState(WhipPublishState.connecting);
    await _cleanupConnection();
  }

  Future<void> restartIfPublishing() async {
    final url = _endpointUrl;
    if (url == null || url.isEmpty) return;
    // Người dùng đã bấm dừng trong lúc camera đang đổi cấu hình: không tự phát lại.
    if (_intentionalStop) return;
    developer.log(
      '[WHIP] Restarting WHIP session due to camera reconfiguration...',
      name: 'WhipPublisherService',
    );
    _intentionalStop = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _retryAttempt = 0;
    await _cleanupConnection();
    _setState(WhipPublishState.connecting);
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    if (_intentionalStop) return;
    await _executePublish();
  }

  Future<void> _cleanupConnection() async {
    if (_peerConnection != null) {
      try {
        await _peerConnection!.close();
        await _peerConnection!.dispose();
      } catch (_) {}
      _peerConnection = null;
    }
  }

  Future<void> dispose() async {
    await stopPublish();
    if (!_stateController.isClosed) {
      await _stateController.close();
    }
  }
}
