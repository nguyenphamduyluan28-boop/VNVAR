import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'bounded_json_body.dart';
import 'discovery_service.dart';
import 'recording_service.dart';
import 'request_rate_limiter.dart';
import 'webrtc_service.dart';

String normalizeCheckVarRequestId(String? value, DateTime receivedAt) {
  final trimmed = value?.trim() ?? '';
  if (trimmed.isEmpty) return 'checkvar_${receivedAt.microsecondsSinceEpoch}';
  final safe = trimmed.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  return safe.length <= 96 ? safe : safe.substring(0, 96);
}

DateTime checkVarEventTime(String? epochMilliseconds, DateTime receivedAt) {
  final value = int.tryParse(epochMilliseconds ?? '');
  if (value == null || value <= 0) return receivedAt;
  final candidate = DateTime.fromMillisecondsSinceEpoch(value);
  // Reject corrupt clocks and malicious values while still allowing a tablet
  // to retry a recent event after a temporary LAN outage.
  if (candidate.isBefore(receivedAt.subtract(const Duration(minutes: 10))) ||
      candidate.isAfter(receivedAt.add(const Duration(seconds: 5)))) {
    return receivedAt;
  }
  return candidate;
}

String normalizeWebRtcPeerId(String? value, {required String fallbackAddress}) {
  final raw = (value?.trim().isNotEmpty ?? false)
      ? value!.trim()
      : 'legacy_$fallbackAddress';
  final safe = raw.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  final normalized = safe.isEmpty ? 'legacy_unknown' : safe;
  return normalized.length <= 96 ? normalized : normalized.substring(0, 96);
}

int effectiveWebRtcPeerLimit(String thermalState) {
  switch (thermalState.toLowerCase()) {
    case 'critical':
      return 1;
    case 'hot':
    case 'serious':
      return 2;
    default:
      return WebRtcService.maximumActivePeers;
  }
}

class CameraServer {
  // ============================================================
  // SERVER
  // ============================================================

  HttpServer? _server;

  static const int defaultApiPort = 8080;
  static const int maximumJsonBodyBytes = 256 * 1024;
  final int apiPort;

  // ============================================================
  // IDENTITY
  // ============================================================

  final String courtId;
  final String cameraId;
  final String deviceId;

  // ============================================================
  // SERVICES
  // ============================================================

  final WebRtcService webRtcService;
  final RecordingService recordingService;

  final VoidCallback? onStateChanged;
  final String Function()? captureStateProvider;
  final String Function()? thermalStateProvider;
  final double? Function()? temperatureProvider;
  final Map<String, dynamic> Function()? captureMetricsProvider;

  final DiscoveryService _discovery = DiscoveryService();

  // ============================================================
  // STATE
  // ============================================================

  bool recording = false;
  Future<void>? _ensureRecordingOperation;
  Future<void> _recordingRequestTail = Future<void>.value();
  bool _iosLifecycleSuspended = false;
  final Map<String, Future<Map<String, dynamic>>> _checkVarJobs = {};
  final Map<String, Map<String, dynamic>> _checkVarResults = {};
  final RequestRateLimiter _rateLimiter = RequestRateLimiter();
  Future<void> _webRtcOfferTail = Future<void>.value();
  int _pendingWebRtcOffers = 0;
  static const int maximumPendingWebRtcOffers = 4;

  bool get running => _server != null;

  // ============================================================
  // CONSTRUCTOR
  // ============================================================

  CameraServer({
    required this.courtId,
    required this.cameraId,
    required this.deviceId,
    required this.webRtcService,
    required this.recordingService,
    this.apiPort = defaultApiPort,
    this.onStateChanged,
    this.captureStateProvider,
    this.thermalStateProvider,
    this.temperatureProvider,
    this.captureMetricsProvider,
  }) : assert(apiPort > 0 && apiPort <= 65535);

  // ============================================================
  // START SERVER
  // ============================================================

  Future<void> start() async {
    if (_server != null) {
      return;
    }

    final HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, apiPort);
    } on SocketException catch (error) {
      throw StateError(
        'Không thể mở HTTP port $apiPort. '
        'Port có thể đang được ứng dụng khác sử dụng: ${error.message}',
      );
    }

    _server = server;

    developer.log(
      'Camera Server started '
      '[$courtId/$cameraId/$deviceId] '
      'on port $apiPort',
      name: 'CameraServer',
    );

    server.listen(
      _handleRequest,
      onError: (Object error, StackTrace stackTrace) {
        developer.log(
          'HTTP server error',
          error: error,
          stackTrace: stackTrace,
          name: 'CameraServer',
        );
      },
    );

    await recordingService.loadSettings();

    // Nạp lại video đã lưu trên điện thoại.
    await recordingService.cleanupOldTempFiles();

    // Legacy tablet discovery uses a short TCP request/response on port 40404.
    try {
      await _discovery.startTcpDiscovery(
        courtId: courtId,
        cameraId: cameraId,
        deviceId: deviceId,
        port: apiPort,
        status: recordingService.recording ? 'RECORDING' : 'READY',
      );
    } on SocketException catch (error) {
      await server.close(force: true);
      _server = null;
      throw StateError(
        'HTTP port $apiPort đã mở nhưng discovery port '
        '${DiscoveryService.discoveryPort} không khả dụng: ${error.message}',
      );
    }
  }

  // ============================================================
  // STOP SERVER
  // ============================================================

  Future<void> stop({Future<void> Function()? onRecorderStopped}) async {
    await _discovery.stop();

    try {
      await recordingService.dispose(onRecorderStopped: onRecorderStopped);
    } catch (error, stackTrace) {
      developer.log(
        'Recording dispose error',
        error: error,
        stackTrace: stackTrace,
        name: 'CameraServer',
      );
    }

    try {
      await webRtcService.disposeConnection();
    } catch (error, stackTrace) {
      developer.log(
        'WebRTC dispose error',
        error: error,
        stackTrace: stackTrace,
        name: 'CameraServer',
      );
    }

    await _server?.close(force: true);

    _server = null;

    recording = false;

    developer.log('Camera Server stopped', name: 'CameraServer');
  }

  /// Rebinds discovery and native live transports without touching the
  /// camera or RecordingService. HTTP is bound to anyIPv4 and automatically
  /// becomes reachable when a Wi-Fi interface receives an address.
  Future<void> reconnectNetworkServices() async {
    if (_server == null) {
      throw StateError('Camera Server is not running.');
    }
    await webRtcService.reconnectNetworkTransports();
    await _discovery.stop();
    await _discovery.startTcpDiscovery(
      courtId: courtId,
      cameraId: cameraId,
      deviceId: deviceId,
      port: apiPort,
      status: recordingService.recording ? 'RECORDING' : 'READY',
    );
    developer.log(
      'Network services rebound without restarting capture',
      name: 'CameraServer',
    );
  }

  Future<void> _viewerPage(HttpRequest request) async {
    request.response.headers.contentType = ContentType.html;
    request.response.write('''<!doctype html>
<html lang="vi">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>VNVAR - $cameraId</title>
  <style>
    *{box-sizing:border-box}body{margin:0;background:#050b16;color:#fff;font-family:Arial,sans-serif}
    main{width:100vw;height:100vh;display:flex;flex-direction:column}header{padding:10px 16px;background:#09254b;font-weight:700}
    video{width:100%;height:calc(100vh - 42px);object-fit:contain;background:#000}.state{position:fixed;right:14px;top:11px;color:#b9d7ff;font-size:13px}
  </style>
</head>
<body><main><header>VNVAR · $courtId · $cameraId</header><span class="state" id="state">Đang kết nối...</span><video id="video" autoplay playsinline muted></video></main>
<script>
(async()=>{
  const state=document.getElementById('state');
  const peerId='viewer_'+(globalThis.crypto?.randomUUID?.()||Date.now()+'_'+Math.random());
  try{
    const pc=new RTCPeerConnection({iceServers:[{urls:'stun:stun.l.google.com:19302'}]});
    pc.addTransceiver('video',{direction:'recvonly'});
    pc.ontrack=e=>{try{e.receiver.playoutDelayHint=0;e.receiver.jitterBufferTarget=0}catch(_){}document.getElementById('video').srcObject=e.streams[0];state.textContent='LIVE'};
    pc.onconnectionstatechange=()=>state.textContent=pc.connectionState==='connected'?'LIVE':pc.connectionState;
    await pc.setLocalDescription(await pc.createOffer());
    if(pc.iceGatheringState!=='complete')await new Promise(resolve=>{const done=()=>{if(pc.iceGatheringState==='complete'){pc.removeEventListener('icegatheringstatechange',done);resolve()}};pc.addEventListener('icegatheringstatechange',done);setTimeout(resolve,8000)});
    const offer=pc.localDescription;
    const response=await fetch('/webrtc/offer',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sdp:offer.sdp,type:offer.type,peerId})});
    if(!response.ok)throw new Error('HTTP '+response.status);
    const answer=await response.json();
    await pc.setRemoteDescription(answer);
    addEventListener('pagehide',()=>navigator.sendBeacon('/webrtc/disconnect',new Blob([JSON.stringify({peerId})],{type:'application/json'})),{once:true});
  }catch(error){state.textContent='Lỗi kết nối';document.body.insertAdjacentHTML('beforeend','<div style="position:fixed;left:16px;bottom:16px;color:#ff8a80">'+String(error)+'</div>')}
})();
</script></body></html>''');
    await request.response.close();
  }

  // ============================================================
  // ROUTER
  // ============================================================

  Future<void> _handleRequest(HttpRequest request) async {
    final path = request.uri.path;

    final method = request.method;

    developer.log('$method $path', name: 'CameraServer');

    try {
      if (!await _admitRequest(request, path: path, method: method)) return;

      if ((path == '/' || path == '/viewer') && method == 'GET') {
        await _viewerPage(request);
        return;
      }

      // ========================================================
      // STATUS
      // ========================================================

      if (path == '/status' && method == 'GET') {
        await _status(request);
        return;
      }

      // ========================================================
      // AUTO START
      //
      // Tablet gọi ngay khi tìm thấy/kết nối camera.
      //
      // Không phụ thuộc BẮT ĐẦU TRẬN.
      // ========================================================

      if (path == '/recording/auto-start' && method == 'POST') {
        await _serializeRecordingRequest(() => _autoStartRecording(request));
        return;
      }

      // ========================================================
      // START CŨ
      //
      // Giữ để tương thích.
      // ========================================================

      if (path == '/start' && method == 'POST') {
        await _serializeRecordingRequest(() => _startRecording(request));
        return;
      }

      // ========================================================
      // STOP
      // ========================================================

      if (path == '/stop' && method == 'POST') {
        await _serializeRecordingRequest(() => _stopRecording(request));
        return;
      }

      // ========================================================
      // CHECKVAR
      //
      // Chốt segment hiện tại và mở segment kế tiếp. Live WebRTC vẫn dùng
      // video track đang chạy nên không được đóng camera/peer connection.
      // ========================================================

      const checkVarPaths = {
        '/checkvar',
        '/check-var',
        '/checkpoint',
        '/recording/checkvar',
      };
      if (path.startsWith('/checkvar/jobs/') && method == 'GET') {
        final requestId = normalizeCheckVarRequestId(
          Uri.decodeComponent(path.substring('/checkvar/jobs/'.length)),
          DateTime.now(),
        );
        final result = _checkVarResults[requestId];
        final processing = _checkVarJobs.containsKey(requestId);
        await _sendJson(
          request.response,
          result != null
              ? HttpStatus.ok
              : processing
              ? HttpStatus.accepted
              : HttpStatus.notFound,
          result ??
              {
                'success': processing,
                'requestId': requestId,
                'status': processing ? 'PROCESSING' : 'NOT_FOUND',
                'retryable': !processing,
              },
        );
        return;
      }
      if (checkVarPaths.contains(path) &&
          (method == 'POST' || method == 'GET')) {
        if (_iosLifecycleSuspended) {
          request.response.headers.set(HttpHeaders.retryAfterHeader, '2');
          await _sendJson(request.response, HttpStatus.serviceUnavailable, {
            'success': false,
            'status': 'LIFECYCLE_SUSPENDED',
            'retryable': true,
            'message': 'Camera Station is entering the iOS background.',
          });
          return;
        }
        final receivedAt = DateTime.now();
        final requestId = normalizeCheckVarRequestId(
          request.headers.value('X-Request-ID') ??
              request.uri.queryParameters['requestId'],
          receivedAt,
        );
        final requestedAt = checkVarEventTime(
          request.headers.value('X-Event-Time-Ms') ??
              request.uri.queryParameters['eventTimeMs'],
          receivedAt,
        );
        developer.log(
          '[CHECKVAR] Request received ($method) at ${requestedAt.toIso8601String()} '
          'from ${request.connectionInfo?.remoteAddress.address ?? 'unknown'}',
          name: 'CameraServer',
        );
        final completed = _checkVarResults[requestId];
        if (completed != null) {
          if (request.contentLength != 0) await request.drain<void>();
          await _sendJson(request.response, HttpStatus.ok, completed);
          return;
        }
        var operation = _checkVarJobs[requestId];
        if (operation == null) {
          operation = _serializeRecordingRequest(
            () => _checkVar(
              request,
              requestId: requestId,
              requestedAt: requestedAt,
            ),
          );
          _checkVarJobs[requestId] = operation;
        } else if (request.contentLength != 0) {
          // A retry has its own HTTP body even though it shares the original
          // operation. Drain it so the keep-alive connection remains valid.
          await request.drain<void>();
        }
        try {
          final result = await operation;
          _checkVarResults[requestId] = result;
          if (identical(_checkVarJobs[requestId], operation)) {
            _checkVarJobs.remove(requestId);
          }
          while (_checkVarResults.length > 100) {
            _checkVarResults.remove(_checkVarResults.keys.first);
          }
          await _sendJson(request.response, HttpStatus.ok, result);
        } catch (_) {
          if (identical(_checkVarJobs[requestId], operation)) {
            _checkVarJobs.remove(requestId);
          }
          rethrow;
        }
        return;
      }

      // ========================================================
      // SEGMENTS
      //
      // Tablet hỏi danh sách segment đã hoàn tất.
      // ========================================================

      if (path == '/segments' && method == 'GET') {
        await _segments(request);
        return;
      }

      // ========================================================
      // ACK DOWNLOAD
      //
      // POST /segments/{id}/downloaded
      // ========================================================

      if (_isDownloadedRoute(request) && method == 'POST') {
        await _markSegmentDownloaded(request);
        return;
      }

      // ========================================================
      // VIDEO LIST CŨ
      // ========================================================

      if (path == '/video' && method == 'GET') {
        await _videos(request);
        return;
      }

      // ========================================================
      // TRIM VIDEO
      //
      // Route tĩnh phải được kiểm tra trước /video/{fileName}, nếu không
      // GET /video/trim sẽ bị hiểu nhầm "trim" là tên một file video.
      // ========================================================

      const trimPaths = {'/trim', '/videos/process/trim', '/video/trim'};
      if (trimPaths.contains(path)) {
        if (method == 'POST') {
          await _trimVideo(request);
        } else {
          request.response.headers.set(HttpHeaders.allowHeader, 'POST');
          await _sendJson(request.response, HttpStatus.methodNotAllowed, {
            'error': 'API /video/trim chỉ hỗ trợ POST',
            'requiredContentType': 'application/json',
            'requiredBody': {
              'segmentId': 'ID lấy từ GET /segments',
              'startMs': 0,
              'endMs': 10000,
            },
          });
        }
        return;
      }

      // ========================================================
      // VIDEO FILE
      //
      // GET /video/file.mp4
      // ========================================================

      if (path.startsWith('/video/') && method == 'GET') {
        await _serveVideo(request);
        return;
      }

      // ========================================================
      // DOWNLOAD CŨ
      // ========================================================

      if (path == '/download/session/close' && method == 'POST') {
        await _closeDownloadSession(request);
        return;
      }

      if (path.startsWith('/download/') && method == 'GET') {
        await _downloadVideo(request);
        return;
      }

      // ========================================================
      // WEBRTC OFFER
      // ========================================================

      if (path == '/webrtc/offer' && method == 'POST') {
        await _handleWebRtcOffer(request);
        return;
      }

      // ========================================================
      // WEBRTC ICE
      // ========================================================

      if (path == '/webrtc/ice' && method == 'POST') {
        await _handleWebRtcIce(request);
        return;
      }

      if (path == '/webrtc/disconnect' && method == 'POST') {
        await _handleWebRtcDisconnect(request);
        return;
      }

      // ========================================================
      // 404
      // ========================================================

      await _sendJson(request.response, HttpStatus.notFound, {
        'error': 'Not Found',
        'path': path,
      });
    } on PayloadTooLargeException catch (error, stackTrace) {
      developer.log(
        'CameraServer rejected oversized request body',
        error: error,
        stackTrace: stackTrace,
        name: 'CameraServer',
      );
      try {
        await _sendJson(request.response, HttpStatus.requestEntityTooLarge, {
          'error': 'Payload Too Large',
          'maximumBytes': maximumJsonBodyBytes,
        });
      } catch (_) {
        // The client may have disconnected while uploading the body.
      }
    } catch (error, stackTrace) {
      developer.log(
        'CameraServer request error',
        error: error,
        stackTrace: stackTrace,
        name: 'CameraServer',
      );

      try {
        await _sendJson(request.response, HttpStatus.internalServerError, {
          'error': 'Internal Server Error',
          'message': 'Camera Station không thể xử lý yêu cầu.',
        });
      } catch (_) {
        // Response có thể đã đóng.
      }
    }
  }

  Future<bool> _admitRequest(
    HttpRequest request, {
    required String path,
    required String method,
  }) async {
    final client = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    var bucket = 'general';
    var maximum = 240;
    var window = const Duration(minutes: 1);
    if (path == '/webrtc/offer') {
      bucket = 'webrtc-offer';
      maximum = 6;
      window = const Duration(minutes: 1);
    } else if (path == '/webrtc/ice') {
      bucket = 'webrtc-ice';
      maximum = 120;
    } else if (method != 'GET') {
      bucket = 'control';
      maximum = 30;
    }
    final allowed = _rateLimiter.allow(
      '$client:$bucket',
      maximumRequests: maximum,
      window: window,
    );
    if (allowed) return true;
    request.response.headers.set(HttpHeaders.retryAfterHeader, '5');
    await _sendJson(request.response, HttpStatus.tooManyRequests, {
      'error': 'Too Many Requests',
      'message': 'Thiết bị gửi yêu cầu quá nhanh. Vui lòng thử lại.',
    });
    return false;
  }

  Future<T> _serializeRecordingRequest<T>(Future<T> Function() operation) {
    final previous = _recordingRequestTail;
    final current = previous.catchError((Object _) {}).then((_) => operation());
    _recordingRequestTail = current.then<void>((_) {}, onError: (_) {});
    return current;
  }

  /// Prevents a lifecycle stop from racing an accepted CheckVAR/recording
  /// request. iOS calls this while a native background task is active, so an
  /// already accepted checkpoint gets the best available chance to finish
  /// before the camera session is released.
  Future<void> prepareForIosBackground() async {
    _iosLifecycleSuspended = true;
    try {
      await _recordingRequestTail.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      developer.log(
        '[LIFECYCLE] Pending recording request exceeded the iOS background '
        'drain window; continuing camera finalization',
        name: 'CameraServer',
      );
    } catch (error, stackTrace) {
      developer.log(
        '[LIFECYCLE] Pending recording request failed before iOS background',
        error: error,
        stackTrace: stackTrace,
        name: 'CameraServer',
      );
    }
  }

  void resumeAfterIosBackground() {
    _iosLifecycleSuspended = false;
  }

  // ============================================================
  // STATUS
  // ============================================================

  Future<void> _status(HttpRequest request) async {
    recording = recordingService.recording;

    await _sendJson(request.response, HttpStatus.ok, {
      'type': 'VNVAR_CAMERA_STATUS_V1',

      'courtId': courtId,

      'cameraId': cameraId,

      'deviceId': deviceId,

      'status': recordingService.recording ? 'RECORDING' : 'READY',

      'recording': recordingService.recording,
      'acceptingCheckVar': !_iosLifecycleSuspended,

      'webrtc': true,

      'cameraReady': webRtcService.cameraInitialized,

      'rtspSupported': webRtcService.rtspSupported,

      'rtspRunning': webRtcService.rtspRunning,

      'rtspAudio': webRtcService.rtspAudio,

      'rtspError': webRtcService.rtspError,

      'videoProfile': {
        'id': webRtcService.resolutionProfile.id,
        'label': webRtcService.resolutionProfile.shortLabel,
        'width': webRtcService.resolutionProfile.width,
        'height': webRtcService.resolutionProfile.height,
        'fps': webRtcService.resolutionProfile.fps,
        'bitrate': webRtcService.resolutionProfile.bitrate,
        'rtspBitrate': webRtcService.resolutionProfile.rtspBitrate,
      },

      'segmentCount': recordingService.segments.length,

      'currentSegmentStartedAt': recordingService.currentSegmentStartedAt
          ?.toIso8601String(),

      'recordingAudio': recordingService.currentSegmentHasAudio,
      'storageWarning': recordingService.lowStorageWarning,
      'storageSuspended': recordingService.storageSuspended,
      'captureState':
          captureStateProvider?.call() ??
          (recordingService.recording ? 'recording' : 'ready'),
      'thermalState': thermalStateProvider?.call() ?? 'unknown',
      'temperatureC': temperatureProvider?.call(),
      'captureMetrics': captureMetricsProvider?.call() ?? const {},
      'webrtcPeers': webRtcService.activePeerCount,
      'webrtcPeerLimit': effectiveWebRtcPeerLimit(
        thermalStateProvider?.call() ?? 'normal',
      ),
      'capabilities': {
        'continuousBackgroundCapture': Platform.isAndroid,
        'foregroundCaptureRequired': Platform.isIOS,
        'rtspFeedback': Platform.isAndroid || Platform.isIOS,
        'preservedShortFragments': true,
      },

      'apiPort': apiPort,
    });
  }

  // ============================================================
  // AUTO START RECORDING
  // ============================================================

  Future<void> ensureRecording() async {
    if (recordingService.recording) {
      recording = true;
      _discovery.updateStatus('RECORDING');
      onStateChanged?.call();
      return;
    }

    final current = _ensureRecordingOperation;
    if (current != null) return current;

    final operation = _startRecorder();
    _ensureRecordingOperation = operation;
    try {
      await operation;
    } finally {
      if (identical(_ensureRecordingOperation, operation)) {
        _ensureRecordingOperation = null;
      }
    }
  }

  Future<void> _autoStartRecording(HttpRequest request) async {
    if (recordingService.recording) {
      recording = true;

      _discovery.updateStatus('RECORDING');

      await _sendJson(request.response, HttpStatus.ok, {
        'success': true,

        'cameraId': cameraId,

        'recording': true,

        'alreadyRunning': true,
      });

      return;
    }

    await ensureRecording();

    await _sendJson(request.response, HttpStatus.ok, {
      'success': true,

      'cameraId': cameraId,

      'recording': true,

      'alreadyRunning': false,
    });
  }

  // ============================================================
  // START RECORDING OLD API
  // ============================================================

  Future<void> _startRecording(HttpRequest request) async {
    final alreadyRunning = recordingService.recording;
    if (!alreadyRunning) {
      await ensureRecording();
    }

    await _sendJson(request.response, HttpStatus.ok, {
      'success': true,

      'courtId': courtId,

      'cameraId': cameraId,

      'deviceId': deviceId,

      'status': 'RECORDING',

      'recording': true,

      'alreadyRunning': alreadyRunning,
    });
  }

  // ============================================================
  // INTERNAL START
  // ============================================================

  Future<void> _startRecorder() async {
    final videoTrack = webRtcService.localVideoTrack;

    if (videoTrack == null) {
      throw StateError('Camera video track unavailable.');
    }

    await recordingService.start(
      videoTrack: videoTrack,
      audioAvailable: webRtcService.microphoneAvailable,
    );

    recording = true;

    _discovery.updateStatus('RECORDING');

    onStateChanged?.call();

    developer.log(
      'AUTO RECORDING STARTED '
      '[$courtId/$cameraId]',
      name: 'CameraServer',
    );
  }

  // ============================================================
  // STOP RECORDING
  // ============================================================

  Future<void> _stopRecording(HttpRequest request) async {
    // Luôn gọi stop để chốt cả recorder/rotation đang finalize, kể cả khi cờ
    // recording vừa đổi trạng thái do một thao tác lifecycle đồng thời.
    final finalSegment = await recordingService.stop();

    recording = false;

    _discovery.updateStatus('READY');

    onStateChanged?.call();

    await _sendJson(request.response, HttpStatus.ok, {
      'success': true,

      'courtId': courtId,

      'cameraId': cameraId,

      'status': 'READY',

      'recording': false,

      'segmentCount': recordingService.segments.length,

      'finalSegment': finalSegment == null
          ? null
          : {
              'id': finalSegment.id,
              'fileName': finalSegment.fileName,
              'durationMs': finalSegment.durationMs,
              'downloadUrl': '/video/${finalSegment.fileName}',
            },
    });
  }

  // ============================================================
  // CHECKVAR
  //
  // Chốt ngay file đang quay và mở file kế tiếp để ghi liên tục.
  // ============================================================

  Future<Map<String, dynamic>> _checkVar(
    HttpRequest request, {
    required String requestId,
    required DateTime requestedAt,
  }) async {
    int? requestedLookback = int.tryParse(
      request.uri.queryParameters['lookbackSeconds'] ??
          request.uri.queryParameters['lookback'] ??
          request.uri.queryParameters['duration'] ??
          '',
    );
    final activeStartedAt = recordingService.currentSegmentStartedAt;
    final historical =
        activeStartedAt != null && requestedAt.isBefore(activeStartedAt)
        ? recordingService.findByTime(requestedAt)
        : null;
    if (activeStartedAt != null &&
        requestedAt.isBefore(activeStartedAt) &&
        historical == null) {
      throw StateError(
        'Không còn segment chứa thời điểm CheckVAR '
        '${requestedAt.toIso8601String()}.',
      );
    }
    final segment =
        historical ?? await recordingService.checkpointCurrentSegment();
    developer.log(
      '[CHECKVAR] Source ready: ${segment.fileName} '
      '(${segment.durationMs}ms)',
      name: 'CameraServer',
    );
    // Đảm bảo recording tiếp tục ngay sau checkpoint. Nếu _startNewSegment()
    // bên trong rotation thất bại (ví dụ: lỗi audio tạm thời trên Android),
    // recording bị dừng nhưng caller không biết. Gọi ensureRecording() ở đây
    // để phục hồi ngay thay vì chờ health monitor retry sau 10 giây.
    if (!recordingService.recording && !recordingService.rotating) {
      try {
        await ensureRecording();
      } catch (error, stackTrace) {
        developer.log(
          '[CHECKVAR] Failed to restart recording after checkpoint',
          error: error,
          stackTrace: stackTrace,
          name: 'CameraServer',
        );
      }
    }
    // The recorder boundary is the time-sensitive part of CheckVAR. Never
    // wait for a slow HTTP body before stopping it: on a weak LAN that used
    // to turn a 14:00:31 press into a source file ending at 14:00:45. The
    // optional lookback only affects the exported clip and can be parsed once
    // the source boundary is already secured.
    if (requestedLookback == null && request.contentLength > 0) {
      try {
        final body = await _readJson(request);
        final raw =
            body['lookbackSeconds'] ?? body['lookback'] ?? body['duration'];
        if (raw is num) requestedLookback = raw.toInt();
        if (raw is String) requestedLookback = int.tryParse(raw);
      } catch (_) {
        // No or non-JSON body is safe to ignore.
      }
    }
    final lookbackSeconds = (requestedLookback ?? 15).clamp(5, 60).toInt();
    RecordedSegment checkpoint = segment;
    var autoTrimmed = false;
    String? trimError;
    final range = checkVarClipRange(
      segmentStartedAt: segment.startedAt,
      segmentEndedAt: segment.endedAt,
      requestedAt: requestedAt,
      lookback: Duration(seconds: lookbackSeconds),
      keyframeSafetyMargin: const Duration(seconds: 5),
    );
    if (range.endMs - range.startMs >= 500) {
      try {
        checkpoint = await recordingService.trimSegment(
          segmentId: segment.id,
          startMs: range.startMs,
          endMs: range.endMs,
          streamCopy: true,
          minimumOutputDurationMs: 500,
        );
        autoTrimmed = true;
        developer.log(
          '[CHECKVAR] Clip ready: ${checkpoint.fileName} '
          '(${checkpoint.durationMs}ms)',
          name: 'CameraServer',
        );
      } catch (error, stackTrace) {
        trimError = userFacingError(error);
        developer.log(
          'Unable to create automatic Check VAR clip; returning source segment',
          error: error,
          stackTrace: stackTrace,
          name: 'CameraServer',
        );
      }
    }
    final checkpointDownloadUrl = autoTrimmed
        ? '/download/${checkpoint.fileName}'
        : '/video/${checkpoint.fileName}';
    final result = <String, dynamic>{
      'success': true,
      'requestId': requestId,
      'status': 'READY',
      'requestedAt': requestedAt.toIso8601String(),
      'usedPreviousSegment': recordingService.lastCheckpointUsedPrevious,
      'autoTrimmed': autoTrimmed,
      'lookbackSeconds': lookbackSeconds,
      'trimError': trimError,
      'checkpointSegment': {
        'id': segment.id,
        'fileName': segment.fileName,
        'durationMs': segment.durationMs,
        'downloadUrl': '/video/${segment.fileName}',
      },
      'checkVarClip': autoTrimmed
          ? {
              'id': checkpoint.id,
              'fileName': checkpoint.fileName,
              'durationMs': checkpoint.durationMs,
              'downloadUrl': checkpointDownloadUrl,
              'eventOffsetMs': checkpoint.durationMs,
            }
          : null,
      'preferredDownloadUrl': checkpointDownloadUrl,
    };
    developer.log(
      '[CHECKVAR] Response sent: autoTrimmed=$autoTrimmed '
      'url=$checkpointDownloadUrl',
      name: 'CameraServer',
    );
    return result;
  }

  // ============================================================
  // SEGMENTS
  // ============================================================

  Future<void> _segments(HttpRequest request) async {
    final segments = recordingService.segments.map((segment) {
      return {...segment.toJson(), 'downloadUrl': '/video/${segment.fileName}'};
    }).toList();

    await _sendJson(request.response, HttpStatus.ok, {
      'type': 'VNVAR_SEGMENT_LIST_V1',

      'courtId': courtId,

      'cameraId': cameraId,

      'recording': recordingService.recording,

      'segments': segments,
    });
  }

  // ============================================================
  // CHECK ROUTE:
  //
  // /segments/{id}/downloaded
  // ============================================================

  bool _isDownloadedRoute(HttpRequest request) {
    final parts = request.uri.pathSegments;

    if (parts.length != 3) {
      return false;
    }

    return parts[0] == 'segments' && parts[2] == 'downloaded';
  }

  // ============================================================
  // TABLET ACK DOWNLOAD
  // ============================================================

  Future<void> _markSegmentDownloaded(HttpRequest request) async {
    final parts = request.uri.pathSegments;

    if (parts.length != 3) {
      await _sendJson(request.response, HttpStatus.badRequest, {
        'error': 'Invalid segment route',
      });

      return;
    }

    final segmentId = parts[1];

    developer.log(
      'Tablet confirmed segment downloaded: '
      '$segmentId',
      name: 'CameraServer',
    );

    final marked = await recordingService.markDownloadedAndDelete(segmentId);

    if (!marked) {
      await _sendJson(request.response, HttpStatus.notFound, {
        'success': false,

        'segmentId': segmentId,

        'error': 'Segment not found',
      });

      return;
    }

    await _sendJson(request.response, HttpStatus.ok, {
      'success': true,

      'segmentId': segmentId,

      'downloaded': true,

      'keptOnCamera': true,
    });
  }

  // ============================================================
  // OLD VIDEO LIST
  // ============================================================

  Future<void> _videos(HttpRequest request) async {
    final videos = recordingService.segments
        .map((segment) => segment.toJson())
        .toList();

    await _sendJson(request.response, HttpStatus.ok, {
      'courtId': courtId,

      'cameraId': cameraId,

      'videos': videos,
    });
  }

  // ============================================================
  // FIND VIDEO
  // ============================================================

  RecordedSegment? _findVideo(String fileName) {
    return recordingService.findByFileName(fileName);
  }

  // ============================================================
  // SERVE VIDEO
  // ============================================================

  Future<void> _serveVideo(HttpRequest request) async {
    if (request.uri.pathSegments.isEmpty) {
      await _sendNotFound(request.response);

      return;
    }

    final fileName = request.uri.pathSegments.last;

    final segment = _findVideo(fileName);

    if (segment == null) {
      await _sendNotFound(request.response);

      return;
    }

    final file = File(segment.path);

    if (!await file.exists()) {
      await _sendNotFound(request.response);

      return;
    }

    await _sendVideoFile(request, file, attachment: false);
  }

  // ============================================================
  // DOWNLOAD
  // ============================================================

  Future<void> _downloadVideo(HttpRequest request) async {
    if (request.uri.pathSegments.isEmpty) {
      await _sendNotFound(request.response);

      return;
    }

    final fileName = request.uri.pathSegments.last;

    final segment =
        recordingService.findExportByFileName(fileName) ?? _findVideo(fileName);

    if (segment == null) {
      await _sendNotFound(request.response);

      return;
    }

    final file = File(segment.path);

    if (!await file.exists()) {
      await _sendNotFound(request.response);

      return;
    }

    await _sendVideoFile(request, file, attachment: true);
  }

  Future<void> _closeDownloadSession(HttpRequest request) async {
    await recordingService.cleanupExportDownloads();
    onStateChanged?.call();
    await _sendJson(request.response, HttpStatus.ok, {
      'success': true,
      'downloadSession': 'closed',
    });
  }

  Future<void> _trimVideo(HttpRequest request) async {
    late final Map<String, dynamic> body;
    try {
      body = await _readJson(request);
    } on FormatException catch (error) {
      await _sendJson(request.response, HttpStatus.badRequest, {
        'error': 'Bad Request',
        'message': error.message,
      });
      return;
    }
    final segmentId = body['segmentId'];
    final startMs = body['startMs'];
    final endMs = body['endMs'];
    if (segmentId is! String ||
        segmentId.trim().isEmpty ||
        startMs is! num ||
        endMs is! num) {
      await _sendJson(request.response, HttpStatus.badRequest, {
        'error': 'Bad Request',
        'message': 'segmentId, startMs và endMs là bắt buộc',
      });
      return;
    }
    late final RecordedSegment clip;
    try {
      clip = await recordingService.trimSegment(
        segmentId: segmentId.trim(),
        startMs: startMs.toInt(),
        endMs: endMs.toInt(),
      );
    } on InvalidTrimRangeException catch (error) {
      await _sendJson(request.response, HttpStatus.badRequest, {
        'error': 'Bad Request',
        'message': error.message,
      });
      return;
    } on TrimSegmentNotFoundException catch (error) {
      await _sendJson(request.response, HttpStatus.notFound, {
        'error': 'Not Found',
        'message': error.message,
      });
      return;
    } on TrimInProgressException catch (error) {
      await _sendJson(request.response, HttpStatus.conflict, {
        'error': 'Conflict',
        'message': error.message,
      });
      return;
    }
    onStateChanged?.call();
    await _sendJson(request.response, HttpStatus.ok, {
      'success': true,
      'courtId': courtId,
      ...clip.toJson(),
      'downloadUrl': '/download/${clip.fileName}',
      'cleanupUrl': '/download/session/close',
      'cleanupMethod': 'POST',
    });
  }

  // ============================================================
  // SEND VIDEO FILE
  //
  // Có hỗ trợ HTTP Range để:
  //
  // - Tablet download
  // - video_player seek
  // - tua video ổn định
  // ============================================================

  Future<void> _sendVideoFile(
    HttpRequest request,
    File file, {
    required bool attachment,
  }) async {
    recordingService.acquireFileRead(file.path);
    try {
      await _sendVideoFileWhileLeased(request, file, attachment: attachment);
    } finally {
      recordingService.releaseFileRead(file.path);
    }
  }

  Future<void> _sendVideoFileWhileLeased(
    HttpRequest request,
    File file, {
    required bool attachment,
  }) async {
    final response = request.response;

    final int fileLength = await file.length();

    final String fileName = file.uri.pathSegments.last;

    response.headers.set('Accept-Ranges', 'bytes');

    response.headers.set(
      HttpHeaders.contentTypeHeader,
      fileName.toLowerCase().endsWith('.ts') ? 'video/mp2t' : 'video/mp4',
    );

    response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');

    if (attachment) {
      response.headers.set(
        'Content-Disposition',
        'attachment; filename="$fileName"',
      );
    }

    final String? rangeHeader = request.headers.value('Range');

    // ==========================================================
    // NORMAL FULL FILE
    // ==========================================================

    if (rangeHeader == null || !rangeHeader.startsWith('bytes=')) {
      response.statusCode = HttpStatus.ok;

      response.headers.set(HttpHeaders.contentLengthHeader, fileLength);

      await response.addStream(file.openRead());

      await response.close();

      return;
    }

    // ==========================================================
    // RANGE
    // ==========================================================

    final String rawRange = rangeHeader.substring(6).trim();
    final parts = rawRange.split('-');

    int? start;
    int? end;
    var validRange =
        fileLength > 0 &&
        !rawRange.contains(',') &&
        parts.length == 2 &&
        (parts[0].isNotEmpty || parts[1].isNotEmpty);

    if (validRange && parts[0].isEmpty) {
      // Suffix range, ví dụ bytes=-500: lấy 500 byte cuối file.
      final suffixLength = int.tryParse(parts[1]);
      if (suffixLength == null || suffixLength <= 0) {
        validRange = false;
      } else {
        end = fileLength - 1;
        start = suffixLength >= fileLength ? 0 : fileLength - suffixLength;
      }
    } else if (validRange) {
      start = int.tryParse(parts[0]);
      if (start == null || start < 0 || start >= fileLength) {
        validRange = false;
      } else if (parts[1].isEmpty) {
        end = fileLength - 1;
      } else {
        end = int.tryParse(parts[1]);
        if (end == null || end < start) {
          validRange = false;
        } else if (end >= fileLength) {
          end = fileLength - 1;
        }
      }
    }

    if (!validRange || start == null || end == null) {
      response.statusCode = 416;

      response.headers.set('Content-Range', 'bytes */$fileLength');

      await response.close();

      return;
    }

    final int contentLength = end - start + 1;

    response.statusCode = HttpStatus.partialContent;

    response.headers.set('Content-Range', 'bytes $start-$end/$fileLength');

    response.headers.set(HttpHeaders.contentLengthHeader, contentLength);

    await response.addStream(file.openRead(start, end + 1));

    await response.close();
  }

  // ============================================================
  // WEBRTC OFFER
  // ============================================================

  Future<void> _handleWebRtcOffer(HttpRequest request) async {
    if (_pendingWebRtcOffers >= maximumPendingWebRtcOffers) {
      request.response.headers.set(HttpHeaders.retryAfterHeader, '1');
      await _sendJson(request.response, HttpStatus.serviceUnavailable, {
        'error': 'WebRTC negotiation queue is full',
        'retryable': true,
      });
      return;
    }
    _pendingWebRtcOffers++;
    final previous = _webRtcOfferTail;
    final turn = Completer<void>();
    _webRtcOfferTail = turn.future;
    try {
      try {
        await previous;
      } catch (_) {
        // A failed older offer must not poison the next handover.
      }
      final body = await _readJson(request);

      final sdp = body['sdp'] as String?;

      final type = body['type'] as String?;

      final peerId = _peerIdForRequest(request, body);

      if (sdp == null || sdp.isEmpty || type == null || type.isEmpty) {
        await _sendJson(request.response, HttpStatus.badRequest, {
          'error': 'Invalid WebRTC offer',
        });

        return;
      }

      developer.log('Received WebRTC offer', name: 'CameraServer');

      final peerLimit = effectiveWebRtcPeerLimit(
        thermalStateProvider?.call() ?? 'normal',
      );
      if (!webRtcService.hasPeer(peerId) &&
          webRtcService.activePeerCount >= peerLimit) {
        request.response.headers.set(HttpHeaders.retryAfterHeader, '2');
        await _sendJson(request.response, HttpStatus.serviceUnavailable, {
          'error': 'WebRTC peer capacity reached',
          'retryable': true,
          'peerId': peerId,
          'activePeers': webRtcService.activePeerCount,
          'maximumPeers': peerLimit,
        });
        return;
      }

      late final RTCSessionDescription answer;
      try {
        answer = await webRtcService.handleOffer(
          sdp: sdp,
          type: type,
          peerId: peerId,
          maximumPeers: peerLimit,
        );
      } catch (_) {
        // A malformed/aborted negotiation must not consume a peer slot.
        await webRtcService.disposePeerConnection(peerId);
        rethrow;
      }

      await _sendJson(request.response, HttpStatus.ok, {
        'sdp': answer.sdp,

        'type': answer.type,

        'peerId': peerId,
      });

      developer.log('WebRTC answer returned', name: 'CameraServer');
    } finally {
      _pendingWebRtcOffers--;
      if (!turn.isCompleted) turn.complete();
    }
  }

  // ============================================================
  // WEBRTC ICE
  // ============================================================

  Future<void> _handleWebRtcIce(HttpRequest request) async {
    final body = await _readJson(request);

    final candidate = body['candidate'] as String?;

    final peerId = _peerIdForRequest(request, body);

    if (candidate == null || candidate.isEmpty) {
      await _sendJson(request.response, HttpStatus.badRequest, {
        'error': 'Invalid ICE candidate',
      });

      return;
    }

    final rawIndex = body['sdpMLineIndex'];

    int? index;

    if (rawIndex is int) {
      index = rawIndex;
    } else if (rawIndex is num) {
      index = rawIndex.toInt();
    }

    await webRtcService.addIceCandidate(
      candidate: candidate,

      sdpMid: body['sdpMid'] as String?,

      sdpMLineIndex: index,

      peerId: peerId,
    );

    await _sendJson(request.response, HttpStatus.ok, {
      'success': true,
      'peerId': peerId,
    });
  }

  Future<void> _handleWebRtcDisconnect(HttpRequest request) async {
    final body = await _readJson(request);
    final peerId = _peerIdForRequest(request, body);
    final existed = webRtcService.hasPeer(peerId);
    await webRtcService.disposePeerConnection(peerId);
    await _sendJson(request.response, HttpStatus.ok, {
      'success': true,
      'peerId': peerId,
      'disconnected': existed,
      'activePeers': webRtcService.activePeerCount,
    });
  }

  String _peerIdForRequest(HttpRequest request, Map<String, dynamic> body) {
    final supplied =
        body['peerId'] ??
        body['sessionId'] ??
        request.headers.value('X-Peer-ID');
    return normalizeWebRtcPeerId(
      supplied?.toString(),
      fallbackAddress:
          request.connectionInfo?.remoteAddress.address ?? 'unknown',
    );
  }

  // ============================================================
  // READ JSON
  // ============================================================

  Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
    final declaredLength = request.contentLength;
    if (declaredLength > maximumJsonBodyBytes) {
      throw const PayloadTooLargeException(maximumJsonBodyBytes);
    }

    final decoder = BoundedJsonBodyDecoder(maximumBytes: maximumJsonBodyBytes);
    await for (final chunk in request) {
      decoder.add(chunk);
    }
    return decoder.decode();
  }

  // ============================================================
  // NOT FOUND
  // ============================================================

  Future<void> _sendNotFound(HttpResponse response) async {
    response.statusCode = HttpStatus.notFound;

    response.headers.contentType = ContentType.json;

    response.write(jsonEncode({'error': 'Not Found'}));

    await response.close();
  }

  // ============================================================
  // SEND JSON
  // ============================================================

  Future<void> _sendJson(
    HttpResponse response,
    int statusCode,
    Map<String, dynamic> data,
  ) {
    response.statusCode = statusCode;

    response.headers.contentType = ContentType.json;

    response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');

    response.write(jsonEncode(data));

    return response.close();
  }
}
