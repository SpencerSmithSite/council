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
        case "freeDiskMb":
          // `volumeAvailableCapacityForImportantUsage` rather than the plain
          // free-space attribute: it reports what iOS will actually let the app
          // have, which accounts for purgeable caches the system will evict.
          // The older key under-reports and would refuse downloads that would
          // in fact succeed.
          let url = URL(fileURLWithPath: NSHomeDirectory())
          if let values = try? url.resourceValues(
               forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
             let bytes = values.volumeAvailableCapacityForImportantUsage {
            result(Int(bytes / (1024 * 1024)))
          } else {
            result(nil)
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }
}
