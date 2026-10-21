import AVFoundation
import CoreMedia
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var stationChannel: FlutterMethodChannel?
  private var rtspPublisher: VnvarRtspPublisher? {
    didSet {
      audioPublisherLock.lock()
      audioPublisher = rtspPublisher
      audioPublisherLock.unlock()
    }
  }
  // Bản sao có khoá của rtspPublisher cho luồng nền đọc PCM: rtspPublisher chỉ
  // được gán trên main thread, đọc trực tiếp từ timer nền là data race.
  private let audioPublisherLock = NSLock()
  private var audioPublisher: VnvarRtspPublisher?
  private let cellularUplink = VnvarCellularUplink()
  private let audioSegmentRecorder = VnvarAudioSegmentRecorder()
  private var rtspGeneration: UInt64 = 0
  // Trả kết quả "đã huỷ" cho lần startRtsp đang chờ khi stopRtsp chạy trước lúc
  // server sẵn sàng; nếu không FlutterResult không bao giờ được gọi.
  private var pendingRtspStartCancel: (() -> Void)?
  // Luồng RTSP overlay (bảng tỉ số, chỉ loopback) cho livestream iOS (C5).
  // Chỉ truy cập trên main thread.
  private var overlayPublisher: VnvarOverlayRtspPublisher?
  private var overlayGeneration: UInt64 = 0
  private var pendingOverlayStartCancel: (() -> Void)?
  /// Thời gian chờ server nghe + encoder có SPS/PPS (cần cho DESCRIBE của FFmpeg).
  private let overlayStartTimeout: TimeInterval = 5
  private var finalizationTask: UIBackgroundTaskIdentifier = .invalid
  private var brightnessBeforeDimming: CGFloat?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    setupBrightnessLifecycleObservers()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationWillResignActive(_ application: UIApplication) {
    restoreBrightnessIfNeeded()
    super.applicationWillResignActive(application)
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    restoreBrightnessIfNeeded()
    super.applicationDidEnterBackground(application)
  }

  override func applicationWillTerminate(_ application: UIApplication) {
    restoreBrightnessIfNeeded()
    stopOverlayRtsp()
    super.applicationWillTerminate(application)
  }

  private func setupBrightnessLifecycleObservers() {
    let center = NotificationCenter.default
    center.addObserver(
      forName: UIApplication.willResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.restoreBrightnessIfNeeded()
    }
    center.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.restoreBrightnessIfNeeded()
    }
    center.addObserver(
      forName: UIApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.restoreBrightnessIfNeeded()
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    stopRtsp()
    stopOverlayRtsp()
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let stationChannel = FlutterMethodChannel(
      name: "vnvar/camera_station_service",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    self.stationChannel = stationChannel
    audioSegmentRecorder.onPcm = { [weak self] pcm in
      self?.currentAudioPublisher()?.sendNativePcm(pcm)
    }
    // Chỉ đọc PCM từ file ghi âm khi có client RTSP đang nhận tiếng.
    audioSegmentRecorder.isPcmNeeded = { [weak self] in
      self?.currentAudioPublisher()?.needsNativeAudio ?? false
    }
    // Gián đoạn micro (cuộc gọi, Siri...): báo Dart để xoay segment đồng bộ lại.
    audioSegmentRecorder.onInterruption = { [weak self] state, resumed in
      DispatchQueue.main.async {
        self?.stationChannel?.invokeMethod(
          "onNativeAudioInterruption",
          arguments: ["state": state, "resumed": resumed]
        )
      }
    }
    stationChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(
          FlutterError(
            code: "IOS_SERVICE_UNAVAILABLE",
            message: "Camera Station iOS service is unavailable.",
            details: nil
          )
        )
        return
      }
      switch call.method {
      case "startRtsp":
        self.startRtsp(call, result)
      case "stopRtsp":
        self.stopRtsp()
        result(nil)
      case "startOverlayRtsp":
        self.startOverlayRtsp(call, result)
      case "updateOverlayImage":
        guard let path = (call.arguments as? [String: Any])?["path"] as? String,
              !path.isEmpty else {
          result(
            FlutterError(
              code: "OVERLAY_RTSP_FAILED",
              message: "Overlay image path is required.",
              details: nil
            )
          )
          return
        }
        self.overlayPublisher?.updateOverlayImage(path: path)
        result(nil)
      case "setOverlayRtspBitrate":
        if let bitrate = (call.arguments as? [String: Any])?["bitrate"] as? NSNumber {
          self.overlayPublisher?.setTargetBitrate(bitrate.intValue)
        }
        result(nil)
      case "stopOverlayRtsp":
        self.stopOverlayRtsp()
        result(nil)
      case "openCellularTunnel":
        guard let arguments = call.arguments as? [String: Any],
              let host = arguments["host"] as? String, !host.isEmpty,
              let port = (arguments["port"] as? NSNumber)?.intValue,
              (1...65_535).contains(port) else {
          result(
            FlutterError(
              code: "INVALID_TUNNEL_TARGET",
              message: "Thiếu máy chủ hoặc cổng.",
              details: nil
            )
          )
          return
        }
        let tls = arguments["tls"] as? Bool ?? false
        self.cellularUplink.open(host: host, port: port, tls: tls) { localPort in
          DispatchQueue.main.async { result(localPort) }
        }
      case "closeCellularTunnel":
        self.cellularUplink.close()
        result(nil)
      case "setRtspBitrate":
        if let bitrate = (call.arguments as? [String: Any])?["bitrate"] as? NSNumber {
          self.rtspPublisher?.setTargetBitrate(bitrate.intValue)
        }
        result(nil)
      case "setRtspRemoteAudio":
        let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
        self.rtspPublisher?.setRemoteAudioEnabled(enabled)
        result(nil)
      case "openAppSettings":
        self.openAppSettings(result)
      case "requestMicrophonePermission":
        self.requestMicrophonePermission(result)
      case "ensureCapturePermissions":
        self.ensureCapturePermissions(result)
      case "startNativeAudioSegment":
        self.startNativeAudioSegment(call, result)
      case "stopNativeAudioSegment":
        // Map: path, active, bytes, firstSampleEpochMs (ms since epoch, nếu biết).
        do {
          result(try self.audioSegmentRecorder.stop())
        } catch {
          result(FlutterError(code: "AUDIO_STOP_FAILED", message: error.localizedDescription, details: nil))
        }
      case "getNativeAudioSegmentStatus":
        result(self.audioSegmentRecorder.status())
      case "getAvailableStorageBytes":
        self.getAvailableStorageBytes(result)
      case "getThermalStatus":
        result(["thermalStatus": self.thermalStatus()])
      case "getCameraResolutionProfiles":
        let arguments = call.arguments as? [String: Any]
        let facing = arguments?["facing"] as? String ?? "environment"
        result(self.cameraProfiles(facing: facing))
      case "getWifiIpAddress":
        result(VnvarNetworkUtils.wifiIPv4Address())
      case "beginBackgroundFinalization":
        self.beginBackgroundFinalization()
        result(nil)
      case "endBackgroundFinalization":
        self.endBackgroundFinalization()
        result(nil)
      case "setStationActive":
        self.setStationActive(call, result)
      case "setScreenDimmed":
        self.setScreenDimmed(call, result)
      case "getCameraZoom":
        self.cameraZoom(call, result, apply: false)
      case "setCameraZoom":
        self.cameraZoom(call, result, apply: true)
      case "getAvailableCameras":
        self.getAvailableCameras(call, result)
      case "switchCameraToId":
        self.switchCameraToId(call, result)
      case "setCameraLock":
        self.setCameraLock(call, result)
      case "setCameraExposureBoost":
        guard let arguments = call.arguments as? [String: Any],
              let trackId = arguments["trackId"] as? String, !trackId.isEmpty else {
          result(["applied": false, "reason": "invalid_track"])
          return
        }
        let target = (arguments["targetEv"] as? NSNumber)?.floatValue ?? 0
        let applied = VnvarWebRtcTrackBridge.setExposureBias(forTrackId: trackId, bias: target)
        if applied.isNaN {
          result(["applied": false, "reason": "unsupported_capturer"])
        } else {
          result(["applied": true, "appliedEv": Double(applied)])
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func setCameraLock(_ call: FlutterMethodCall, _ result: FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    let trackId = arguments?["trackId"] as? String ?? ""
    let locked = arguments?["locked"] as? Bool ?? true
    let success = VnvarWebRtcTrackBridge.setCameraLock(forTrackId: trackId, locked: locked)
    result(success)
  }

  private func switchCameraToId(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let trackId = arguments["trackId"] as? String,
          let cameraId = arguments["cameraId"] as? String else {
      result(false)
      return
    }
    VnvarWebRtcTrackBridge.switchCamera(forTrackId: trackId, toDeviceId: cameraId) { success, error in
      DispatchQueue.main.async {
        if success {
          result(true)
        } else {
          result(FlutterError(code: "SWITCH_CAMERA_FAILED", message: error ?? "Switch camera failed", details: nil))
        }
      }
    }
  }

  private func getAvailableCameras(_ call: FlutterMethodCall, _ result: FlutterResult) {
    var types: [AVCaptureDevice.DeviceType] = [
      .builtInWideAngleCamera,
    ]
    if #available(iOS 13.0, *) {
      types.append(.builtInUltraWideCamera)
      types.append(.builtInTelephotoCamera)
      types.append(.builtInTripleCamera)
      types.append(.builtInDualWideCamera)
    }
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: types,
      mediaType: .video,
      position: .unspecified
    )
    var cameras: [[String: Any]] = []
    for device in discovery.devices {
      let isUltraWide: Bool
      if #available(iOS 13.0, *) {
        // Chỉ đánh dấu physical ultra-wide camera. builtInTripleCamera và
        // builtInDualWideCamera là logical cameras tự quản lý lens switching
        // qua videoZoomFactor — không nên đánh dấu isUltraWide vì cameraZoom
        // function chỉ scale cho .builtInUltraWideCamera.
        isUltraWide = (device.deviceType == .builtInUltraWideCamera)
      } else {
        isUltraWide = false
      }
      let minZoom: Double = isUltraWide ? 0.5 : Double(device.minAvailableVideoZoomFactor)
      let maxZoom: Double = isUltraWide
        ? min(5.0, Double(device.maxAvailableVideoZoomFactor) * 0.5)
        : min(5.0, Double(device.maxAvailableVideoZoomFactor))
      cameras.append([
        "id": device.uniqueID,
        "facing": device.position == .front ? "front" : "back",
        "minZoom": minZoom,
        "maxZoom": maxZoom,
        "isUltraWide": isUltraWide,
      ])
    }
    result(cameras)
  }

  private func activeVideoDevice(trackId: String?, requestedId: String?, facing: String) -> AVCaptureDevice? {
    if let requestedId = requestedId, !requestedId.isEmpty,
       let device = AVCaptureDevice(uniqueID: requestedId) {
      return device
    }
    if let trackId = trackId, !trackId.isEmpty,
       let device = VnvarWebRtcTrackBridge.activeVideoDevice(forTrackId: trackId) {
      return device
    }
    let position: AVCaptureDevice.Position = facing == "user" ? .front : .back
    return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
  }

  private func cameraZoom(_ call: FlutterMethodCall, _ result: FlutterResult, apply: Bool) {
    let arguments = call.arguments as? [String: Any]
    let facing = arguments?["facing"] as? String ?? "environment"
    let requestedId = arguments?["deviceId"] as? String
    let trackId = arguments?["trackId"] as? String
    guard let device = self.activeVideoDevice(trackId: trackId, requestedId: requestedId, facing: facing) else {
      result(["supported": false]); return
    }
    let isUltraWide: Bool
    if #available(iOS 13.0, *) {
      isUltraWide = (device.deviceType == .builtInUltraWideCamera)
    } else {
      isUltraWide = false
    }

    let minFactor = device.minAvailableVideoZoomFactor
    let maxFactor = device.maxAvailableVideoZoomFactor
    let baseRatio: CGFloat = isUltraWide ? 0.5 : 1.0

    if apply, let requested = (arguments?["zoom"] as? NSNumber)?.doubleValue {
      do {
        try device.lockForConfiguration()
        let targetFactor: CGFloat
        if isUltraWide {
          targetFactor = min(min(maxFactor, 5.0 / baseRatio), max(minFactor, CGFloat(requested) / baseRatio))
        } else {
          targetFactor = min(min(maxFactor, 5.0), max(minFactor, CGFloat(requested)))
        }
        device.videoZoomFactor = targetFactor
        device.unlockForConfiguration()
      } catch {
        result(FlutterError(code: "ZOOM_FAILED", message: error.localizedDescription, details: nil)); return
      }
    }

    let currentZoom = isUltraWide
      ? (Double(device.videoZoomFactor) * Double(baseRatio))
      : Double(device.videoZoomFactor)

    result([
      "supported": maxFactor > minFactor,
      "min": isUltraWide ? 0.5 : Double(minFactor),
      "max": isUltraWide
        ? min(5.0, Double(maxFactor) * Double(baseRatio))
        : min(5.0, Double(maxFactor)),
      "current": currentZoom,
      "cameraId": device.uniqueID,
    ])
  }

  private func startRtsp(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let trackId = arguments["trackId"] as? String,
          !trackId.isEmpty else {
      result(
        FlutterError(
          code: "RTSP_TRACK_REQUIRED",
          message: "A WebRTC video track is required.",
          details: nil
        )
      )
      return
    }
    guard let track = VnvarWebRtcTrackBridge.videoTrack(forId: trackId) else {
      result(
        FlutterError(
          code: "RTSP_TRACK_NOT_FOUND",
          message: "The active iOS WebRTC video track was not found.",
          details: trackId
        )
      )
      return
    }

    let port = (arguments["port"] as? NSNumber)?.intValue ?? 8554
    let bitrate = (arguments["bitrate"] as? NSNumber)?.intValue ?? 2_000_000
    let fps = (arguments["fps"] as? NSNumber)?.intValue ?? 30
    let audioTrackId = arguments["audioTrackId"] as? String
    let remoteAudio = arguments["remoteAudio"] as? Bool ?? false
    guard (1...65_535).contains(port) else {
      result(
        FlutterError(
          code: "RTSP_INVALID_PORT",
          message: "RTSP port must be between 1 and 65535.",
          details: port
        )
      )
      return
    }
    stopRtsp()
    let publisher = VnvarRtspPublisher(
      track: track,
      audioTrackId: audioTrackId,
      nativeAudioAvailable: AVAudioSession.sharedInstance().recordPermission == .granted,
      port: port,
      bitrate: bitrate,
      fps: fps
    )
    publisher.setRemoteAudioEnabled(remoteAudio)
    let generation = rtspGeneration
    var startResultSent = false
    pendingRtspStartCancel = {
      guard !startResultSent else { return }
      startResultSent = true
      result(
        FlutterError(
          code: "RTSP_START_CANCELLED",
          message: "RTSP start was cancelled before the server became ready.",
          details: nil
        )
      )
    }
    publisher.onEncoderConfigured = { [weak self] in
      guard let self = self, self.rtspGeneration == generation else { return }
      self.stationChannel?.invokeMethod(
        "onRtspEncoderConfigured",
        arguments: ["platform": "ios"]
      )
    }
    publisher.onEncoderError = { [weak self] message in
      guard let self = self, self.rtspGeneration == generation else { return }
      if !startResultSent {
        startResultSent = true
        result(
          FlutterError(
            code: "RTSP_START_FAILED",
            message: message,
            details: nil
          )
        )
      }
      self.stationChannel?.invokeMethod(
        "onRtspEncoderError",
        arguments: ["error": message, "platform": "ios"]
      )
    }
    publisher.onServerReady = { [weak self] in
      guard let self = self,
            let publisher = self.rtspPublisher,
            self.rtspGeneration == generation,
            !startResultSent else { return }
      startResultSent = true
      self.rtspPublisher = publisher
      result([
        "running": true,
        "started": true,
        "port": port,
        "path": "/camera",
        "audio": publisher.audioAvailable,
      ])
    }
    publisher.onCapturePerformance = { [weak self] actualFps, requestedFps in
      guard let self = self, self.rtspGeneration == generation else { return }
      self.stationChannel?.invokeMethod(
        "onIosCapturePerformance",
        arguments: [
          "actualFps": actualFps,
          "requestedFps": requestedFps,
        ]
      )
    }
    rtspPublisher = publisher
    do {
      try publisher.start()
    } catch {
      // Invalidate every asynchronous publisher callback before returning the
      // synchronous startup failure. This guarantees FlutterResult is invoked
      // exactly once even when Network.framework reports a listener failure
      // at the same time as start() throws.
      startResultSent = true
      stopRtsp()
      result(
        FlutterError(
          code: "RTSP_START_FAILED",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  private func stopRtsp() {
    rtspGeneration &+= 1
    let cancelPendingStart = pendingRtspStartCancel
    pendingRtspStartCancel = nil
    rtspPublisher?.stop()
    rtspPublisher = nil
    cancelPendingStart?()
  }

  private func overlayFailure(_ message: String, details: Any? = nil) -> FlutterError {
    FlutterError(code: "OVERLAY_RTSP_FAILED", message: message, details: details)
  }

  /// C5: `true` khi server loopback đã nghe VÀ encoder đã có SPS/PPS (để
  /// DESCRIBE của FFmpeg không nhận 503). FlutterResult được gọi đúng một lần.
  private func startOverlayRtsp(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let trackId = arguments["trackId"] as? String, !trackId.isEmpty else {
      result(overlayFailure("A WebRTC video track is required."))
      return
    }
    guard let overlayPath = arguments["overlayPath"] as? String, !overlayPath.isEmpty else {
      result(overlayFailure("Overlay image path is required."))
      return
    }
    let port = (arguments["port"] as? NSNumber)?.intValue ?? 8555
    let bitrate = (arguments["bitrate"] as? NSNumber)?.intValue ?? 2_500_000
    let fps = (arguments["fps"] as? NSNumber)?.intValue ?? 30
    guard (1...65_535).contains(port) else {
      result(overlayFailure("Overlay RTSP port must be between 1 and 65535.", details: port))
      return
    }
    guard let track = VnvarWebRtcTrackBridge.videoTrack(forId: trackId) else {
      result(overlayFailure("The active iOS WebRTC video track was not found.", details: trackId))
      return
    }
    // Gọi lại khi đang chạy: dừng phiên cũ rồi chạy lại.
    stopOverlayRtsp()

    let publisher: VnvarOverlayRtspPublisher
    do {
      publisher = try VnvarOverlayRtspPublisher(
        track: track,
        port: port,
        bitrate: bitrate,
        fps: fps,
        overlayPath: overlayPath
      )
    } catch {
      result(overlayFailure(String(describing: error)))
      return
    }

    let generation = overlayGeneration
    var resultSent = false
    var serverReady = false
    var encoderReady = false
    let finish: (Any?) -> Void = { value in
      guard !resultSent else { return }
      resultSent = true
      result(value)
    }
    pendingOverlayStartCancel = {
      finish(
        FlutterError(
          code: "OVERLAY_RTSP_FAILED",
          message: "Overlay RTSP start was cancelled.",
          details: nil
        )
      )
    }
    let completeIfReady: () -> Void = { [weak self] in
      guard let self = self,
            self.overlayGeneration == generation,
            serverReady, encoderReady, !resultSent else { return }
      self.pendingOverlayStartCancel = nil
      finish(true)
    }
    publisher.onServerReady = {
      serverReady = true
      completeIfReady()
    }
    publisher.onEncoderConfigured = {
      encoderReady = true
      completeIfReady()
    }
    publisher.onError = { [weak self] message in
      guard let self = self, self.overlayGeneration == generation else { return }
      let startPending = !resultSent
      finish(
        FlutterError(code: "OVERLAY_RTSP_FAILED", message: message, details: nil)
      )
      // Dừng ngay để nhả GPU/encoder/cổng; Dart gọi stopOverlayRtsp sau đó
      // vẫn an toàn.
      self.stopOverlayRtsp()
      if !startPending {
        self.stationChannel?.invokeMethod(
          "onOverlayRtspError",
          arguments: ["error": message]
        )
      }
    }
    overlayPublisher = publisher
    do {
      try publisher.start()
    } catch {
      finish(overlayFailure(String(describing: error)))
      stopOverlayRtsp()
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + overlayStartTimeout) { [weak self] in
      guard let self = self,
            self.overlayGeneration == generation,
            !resultSent else { return }
      let reason = serverReady
        ? "No camera frame was encoded for the overlay stream."
        : "Overlay RTSP server did not start listening."
      finish(
        FlutterError(code: "OVERLAY_RTSP_FAILED", message: reason, details: nil)
      )
      self.stopOverlayRtsp()
    }
  }

  /// An toàn khi chưa chạy. Chỉ gọi trên main thread.
  private func stopOverlayRtsp() {
    overlayGeneration &+= 1
    let cancelPendingStart = pendingOverlayStartCancel
    pendingOverlayStartCancel = nil
    overlayPublisher?.stop()
    overlayPublisher = nil
    cancelPendingStart?()
  }

  /// An toàn khi gọi từ luồng nền (timer đọc PCM).
  private func currentAudioPublisher() -> VnvarRtspPublisher? {
    audioPublisherLock.lock()
    defer { audioPublisherLock.unlock() }
    return audioPublisher
  }

  private func openAppSettings(_ result: @escaping FlutterResult) {
    guard let url = URL(string: UIApplication.openSettingsURLString) else {
      result(false)
      return
    }
    UIApplication.shared.open(url, options: [:]) { opened in
      result(opened)
    }
  }

  /// Hỏi quyền camera rồi micro TRƯỚC khi mở camera (không giới hạn thời gian
  /// chờ người dùng). Trả `{camera: Bool, microphone: Bool}`.
  private func ensureCapturePermissions(_ result: @escaping FlutterResult) {
    requestCameraAccess { cameraGranted in
      self.requestMicrophonePermission { micGranted in
        result([
          "camera": cameraGranted,
          "microphone": (micGranted as? Bool) ?? false,
        ])
      }
    }
  }

  private func requestCameraAccess(_ completion: @escaping (Bool) -> Void) {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      completion(true)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async { completion(granted) }
      }
    default:
      completion(false)
    }
  }

  private func requestMicrophonePermission(_ result: @escaping FlutterResult) {
    let audioSession = AVAudioSession.sharedInstance()
    switch audioSession.recordPermission {
    case .granted:
      result(true)
    case .denied:
      result(false)
    case .undetermined:
      audioSession.requestRecordPermission { granted in
        DispatchQueue.main.async { result(granted) }
      }
    @unknown default:
      result(false)
    }
  }

  private func startNativeAudioSegment(_ call: FlutterMethodCall, _ result: FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let path = arguments["path"] as? String, !path.isEmpty else {
      result(FlutterError(code: "AUDIO_PATH_REQUIRED", message: "Audio path is required.", details: nil))
      return
    }
    guard AVAudioSession.sharedInstance().recordPermission == .granted else {
      result(FlutterError(code: "MICROPHONE_PERMISSION_DENIED", message: "Microphone permission is not granted.", details: nil))
      return
    }
    do {
      result(try audioSegmentRecorder.start(path: path))
    } catch {
      result(FlutterError(code: "AUDIO_START_FAILED", message: error.localizedDescription, details: nil))
    }
  }

  private func getAvailableStorageBytes(_ result: FlutterResult) {
    do {
      let documents = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
      ).first!
      let values = try documents.resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey,
      ])
      if let capacity = values.volumeAvailableCapacityForImportantUsage {
        result(capacity)
      } else if let capacity = values.volumeAvailableCapacity {
        result(Int64(capacity))
      } else {
        result(nil)
      }
    } catch {
      result(
        FlutterError(
          code: "STORAGE_QUERY_FAILED",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  private func thermalStatus() -> Int {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return 0
    case .fair: return 1
    case .serious: return 4
    case .critical: return 5
    @unknown default: return 0
    }
  }

  private func beginBackgroundFinalization() {
    guard finalizationTask == .invalid else { return }
    finalizationTask = UIApplication.shared.beginBackgroundTask(
      withName: "VNVAR finalize recording"
    ) { [weak self] in
      self?.endBackgroundFinalization()
    }
  }

  private func endBackgroundFinalization() {
    guard finalizationTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(finalizationTask)
    finalizationTask = .invalid
  }

  private func setStationActive(
    _ call: FlutterMethodCall,
    _ result: @escaping FlutterResult
  ) {
    guard let arguments = call.arguments as? [String: Any],
          let active = arguments["active"] as? Bool else {
      result(
        FlutterError(
          code: "INVALID_STATION_ACTIVE_ARGUMENT",
          message: "Missing active state.",
          details: nil
        )
      )
      return
    }
    DispatchQueue.main.async {
      UIApplication.shared.isIdleTimerDisabled = active
      if !active {
        self.restoreBrightnessIfNeeded()
        self.endBackgroundFinalization()
      }
      result(nil)
    }
  }

  private func cameraProfiles(facing: String) -> [[String: Any]] {
    let position: AVCaptureDevice.Position = facing == "user" ? .front : .back
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera],
      mediaType: .video,
      position: position
    )
    guard let device = discovery.devices.first else { return [] }

    let candidates: [(id: String, width: Int32, height: Int32)] = [
      ("hd720", 1280, 720),
      ("fullHd1080", 1920, 1080),
      ("qhd2k", 2560, 1440),
      ("ultraHd4k", 3840, 2160),
    ]
    var profiles: [[String: Any]] = []
    for candidate in candidates {
      var supportedFps = 0
      for format in device.formats {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        guard dimensions.width == candidate.width,
              dimensions.height == candidate.height else { continue }
        let formatFps = format.videoSupportedFrameRateRanges.compactMap { range -> Int? in
          let maxRate = Int(range.maxFrameRate.rounded(.down))
          return Double(maxRate) >= range.minFrameRate ? min(maxRate, 60) : nil
        }.max() ?? 0
        supportedFps = max(supportedFps, formatFps)
      }
      if supportedFps > 0 {
        profiles.append([
          "id": candidate.id,
          "width": Int(candidate.width),
          "height": Int(candidate.height),
          "maxFps": supportedFps,
          "deviceId": device.uniqueID,
        ])
      }
    }
    return profiles
  }

  private func setScreenDimmed(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard
      let arguments = call.arguments as? [String: Any],
      let dimmed = arguments["dimmed"] as? Bool
    else {
      result(
        FlutterError(
          code: "INVALID_DIM_ARGUMENT",
          message: "Thiếu tham số dimmed.",
          details: nil
        )
      )
      return
    }
    DispatchQueue.main.async {
      if dimmed {
        if self.brightnessBeforeDimming == nil {
          self.brightnessBeforeDimming = UIScreen.main.brightness
        }
        UIScreen.main.brightness = 0.05
      } else {
        self.restoreBrightnessIfNeeded()
      }
      result(nil)
    }
  }

  func restoreBrightnessIfNeeded() {
    if Thread.isMainThread {
      performRestoreBrightness()
    } else {
      DispatchQueue.main.sync {
        self.performRestoreBrightness()
      }
    }
  }

  private func performRestoreBrightness() {
    guard let previousBrightness = brightnessBeforeDimming else { return }
    UIScreen.main.brightness = previousBrightness
    brightnessBeforeDimming = nil
  }
}
