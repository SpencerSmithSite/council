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

    // Registered by hand rather than as a pub plugin: it is one file, specific
    // to this app, and wraps a framework that only exists on iOS 26+.
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "FoundationModelsBridge") {
      FoundationModelsBridge.register(with: registrar)
    }

    // Physical memory, so the app can stop offering a 2.1 GB model to a 2 GB
    // phone. Dart cannot read this portably; one method is cheaper than a
    // dependency.
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "CouncilDevice") {
      let channel = FlutterMethodChannel(
        name: "site.spencersmith.council/device",
        binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "totalMemoryMb":
          result(Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024)))
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }
}
