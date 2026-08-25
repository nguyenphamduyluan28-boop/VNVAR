import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'discovery_service.dart';
import 'recording_service.dart';
import 'webrtc_service.dart';

class CameraServer {
  // ============================================================
  // SERVER
  // ============================================================

  HttpServer? _server;

  static const int apiPort = 8080;

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

  final DiscoveryService _discovery = DiscoveryService();

  // ============================================================
  // STATE
  // ============================================================

  bool recording = false;
  Future<void>? _ensureRecordingOperation;

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
    this.onStateChanged,
  });

  // ============================================================
  // START SERVER
  // ============================================================

  Future<void> start() async {
    if (_server != null) {
      return;
    }

    final server = await HttpServer.bind(InternetAddress.anyIPv4, apiPort);

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
    await _discovery.startTcpDiscovery(
      courtId: courtId,
      cameraId: cameraId,
      deviceId: deviceId,
      port: apiPort,
      status: recordingService.recording ? 'RECORDING' : 'READY',
    );
  }

  // ============================================================
  // STOP SERVER
  // ============================================================

  Future<void> stop() async {
    await _discovery.stop();

    try {
      await recordingService.dispose();
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
  try{
    const pc=new RTCPeerConnection({iceServers:[{urls:'stun:stun.l.google.com:19302'}]});
    pc.addTransceiver('video',{direction:'recvonly'});
    pc.ontrack=e=>{try{e.receiver.playoutDelayHint=0;e.receiver.jitterBufferTarget=0}catch(_){}document.getElementById('video').srcObject=e.streams[0];state.textContent='LIVE'};
    pc.onconnectionstatechange=()=>state.textContent=pc.connectionState==='connected'?'LIVE':pc.connectionState;
    await pc.setLocalDescription(await pc.createOffer());
    if(pc.iceGatheringState!=='complete')await new Promise(resolve=>{const done=()=>{if(pc.iceGatheringState==='complete'){pc.removeEventListener('icegatheringstatechange',done);resolve()}};pc.addEventListener('icegatheringstatechange',done);setTimeout(resolve,8000)});
    const offer=pc.localDescription;
    const response=await fetch('/webrtc/offer',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sdp:offer.sdp,type:offer.type})});
    if(!response.ok)throw new Error('HTTP '+response.status);
    const answer=await response.json();
    await pc.setRemoteDescription(answer);
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
        await _autoStartRecording(request);
        return;
      }

      // ========================================================
      // START CŨ
      //
      // Giữ để tương thích.
      // ========================================================

      if (path == '/start' && method == 'POST') {
        await _startRecording(request);
        return;
      }

      // ========================================================
      // STOP
      // ========================================================

      if (path == '/stop' && method == 'POST') {
        await _stopRecording(request);
        return;
      }

      // ========================================================
      // CHECKVAR
      //
      // KHÔNG checkpoint nữa.
      // Recorder 3 phút phải chạy liên tục.
      // ========================================================

      if (path == '/checkvar' && method == 'POST') {
        await _checkVar(request);
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

      // ========================================================
      // 404
      // ========================================================

      await _sendJson(request.response, HttpStatus.notFound, {
        'error': 'Not Found',
        'path': path,
      });
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
          'message': error.toString(),
        });
      } catch (_) {
        // Response có thể đã đóng.
      }
    }
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

      'webrtc': true,

      'cameraReady': webRtcService.cameraInitialized,

      'rtspSupported': webRtcService.rtspSupported,

      'rtspError': webRtcService.rtspError,

      'segmentCount': recordingService.segments.length,

      'currentSegmentStartedAt': recordingService.currentSegmentStartedAt
          ?.toIso8601String(),

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

    await recordingService.start(videoTrack: videoTrack);

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
    if (recordingService.recording) {
      await recordingService.stop();
    }

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
    });
  }

  // ============================================================
  // CHECKVAR
  //
  // Chốt ngay file đang quay và mở file kế tiếp để ghi liên tục.
  // ============================================================

  Future<void> _checkVar(HttpRequest request) async {
    final segment = await recordingService.checkpointCurrentSegment();
    await _sendJson(request.response, HttpStatus.ok, {
      'success': true,
      'checkpointSegment': {
        'id': segment.id,
        'fileName': segment.fileName,
        'durationMs': segment.durationMs,
        'downloadUrl': '/video/${segment.fileName}',
      },
    });
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
    final body = await _readJson(request);
    final segmentId = body['segmentId'];
    final startMs = body['startMs'];
    final endMs = body['endMs'];
    if (segmentId is! String || startMs is! num || endMs is! num) {
      await _sendJson(request.response, HttpStatus.badRequest, {
        'error': 'segmentId, startMs và endMs là bắt buộc',
      });
      return;
    }
    final clip = await recordingService.trimSegment(
      segmentId: segmentId,
      startMs: startMs.toInt(),
      endMs: endMs.toInt(),
    );
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
    final body = await _readJson(request);

    final sdp = body['sdp'] as String?;

    final type = body['type'] as String?;

    if (sdp == null || sdp.isEmpty || type == null || type.isEmpty) {
      await _sendJson(request.response, HttpStatus.badRequest, {
        'error': 'Invalid WebRTC offer',
      });

      return;
    }

    developer.log('Received WebRTC offer', name: 'CameraServer');

    final RTCSessionDescription answer = await webRtcService.handleOffer(
      sdp: sdp,

      type: type,
    );

    await _sendJson(request.response, HttpStatus.ok, {
      'sdp': answer.sdp,

      'type': answer.type,
    });

    developer.log('WebRTC answer returned', name: 'CameraServer');
  }

  // ============================================================
  // WEBRTC ICE
  // ============================================================

  Future<void> _handleWebRtcIce(HttpRequest request) async {
    final body = await _readJson(request);

    final candidate = body['candidate'] as String?;

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
    );

    await _sendJson(request.response, HttpStatus.ok, {'success': true});
  }

  // ============================================================
  // READ JSON
  // ============================================================

  Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();

    if (body.trim().isEmpty) {
      return {};
    }

    final decoded = jsonDecode(body);

    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('JSON body must be object');
    }

    return decoded;
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
