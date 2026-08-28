import AVFoundation
import CoreMedia
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let stationChannel = FlutterMethodChannel(
      name: "vnvar/camera_station_service",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
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
      case "requestMicrophonePermission":
        self.requestMicrophonePermission(result)
      case "getAvailableStorageBytes":
        self.getAvailableStorageBytes(result)
      case "getThermalStatus":
        result(self.thermalStatus())
      case "getCameraResolutionProfiles":
        let arguments = call.arguments as? [String: Any]
        let facing = arguments?["facing"] as? String ?? "environment"
        result(self.cameraProfiles(facing: facing))
      case "setScreenDimmed":
        self.setScreenDimmed(call, result)
      default:
        result(FlutterMethodNotImplemented)
      }
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
        let formatFps = format.videoSupportedFrameRateRanges
          .map { Int($0.maxFrameRate.rounded(.down)) }
          .max() ?? 0
        supportedFps = max(supportedFps, min(formatFps, 30))
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

  private func setScreenDimmed(_ call: FlutterMethodCall, _ result: FlutterResult) {
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
      UIScreen.main.brightness = dimmed ? 0.05 : 0.6
      result(nil)
    }
  }
}
