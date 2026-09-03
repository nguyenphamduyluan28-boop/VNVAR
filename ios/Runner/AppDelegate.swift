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
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    stopRtsp()
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let stationChannel = FlutterMethodChannel(
      name: "vnvar/camera_station_service",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    self.stationChannel = stationChannel
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
      default:
        result(FlutterMethodNotImplemented)
      }
    }
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
    rtspPublisher = publisher
    do {
      try publisher.start()
    } catch {
      publisher.stop()
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
        let sustainedFps = candidate.id == "ultraHd4k" ? 20 : 30
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

  private func restoreBrightnessIfNeeded() {
    guard let previousBrightness = brightnessBeforeDimming else { return }
    UIScreen.main.brightness = previousBrightness
    brightnessBeforeDimming = nil
  }
}
