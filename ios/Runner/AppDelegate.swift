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
  }
}
