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
    stationChannel.setMethodCallHandler { call, result in
      guard call.method == "setScreenDimmed" else {
        result(FlutterMethodNotImplemented)
        return
      }

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
}
