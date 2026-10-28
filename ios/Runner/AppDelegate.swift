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
    let channel = FlutterMethodChannel(
      name: "pixelbox/display",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "maximumRefreshRate" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let screen = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first?.screen
      result(screen?.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond)
    }
  }
}
