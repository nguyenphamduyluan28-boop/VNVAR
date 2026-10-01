import AVFoundation
import CoreMedia
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var stationChannel: FlutterMethodChannel?
  private var rtspPublisher: VnvarRtspPublisher?
  private let audioSegmentRecorder = VnvarAudioSegmentRecorder()
  private var rtspGeneration: UInt64 = 0
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
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let stationChannel = FlutterMethodChannel(
      name: "vnvar/camera_station_service",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    self.stationChannel = stationChannel
    audioSegmentRecorder.onPcm = { [weak self] pcm in
      self?.rtspPublisher?.sendNativePcm(pcm)
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
      case "requestMicrophonePermission":
        self.requestMicrophonePermission(result)
      case "startNativeAudioSegment":
        self.startNativeAudioSegment(call, result)
      case "stopNativeAudioSegment":
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
        isUltraWide = (device.deviceType == .builtInUltraWideCamera ||
                       device.deviceType == .builtInTripleCamera ||
                       device.deviceType == .builtInDualWideCamera)
      } else {
        isUltraWide = false
      }
      let minZoom: Double = isUltraWide ? 0.5 : Double(device.minAvailableVideoZoomFactor)
      let maxZoom: Double = isUltraWide
        ? (Double(device.maxAvailableVideoZoomFactor) * 0.5)
        : min(10.0, Double(device.maxAvailableVideoZoomFactor))
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
          targetFactor = min(maxFactor, max(minFactor, CGFloat(requested) / baseRatio))
        } else {
          targetFactor = min(maxFactor, max(minFactor, CGFloat(requested)))
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
      "max": isUltraWide ? (Double(maxFactor) * Double(baseRatio)) : Double(maxFactor),
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
    let generation = rtspGeneration
    var startResultSent = false
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
    rtspPublisher?.stop()
    rtspPublisher = nil
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
        let sustainedFps = 30
        let formatFps = format.videoSupportedFrameRateRanges.compactMap { range -> Int? in
          let value = min(Int(range.maxFrameRate.rounded(.down)), sustainedFps)
          return Double(value) >= range.minFrameRate ? value : nil
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
