import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Apple's on-device model, same bridge as iOS. Registered by hand rather
    // than as a pub plugin: it is one file, specific to this app, and wraps a
    // framework that only exists on macOS 26+.
    //
    // Without this the Mac reported "no built-in model" and offered nothing,
    // on hardware that has Apple Intelligence — the Dart side gated on
    // `Platform.isIOS` and the macOS runner never registered the channel, so
    // both halves had to be fixed for either to matter.
    // Non-optional here, unlike the iOS registry, so no `if let`.
    FoundationModelsBridge.register(
      with: flutterViewController.registrar(forPlugin: "FoundationModelsBridge"))

    super.awakeFromNib()
  }
}
