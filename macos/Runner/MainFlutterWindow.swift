// © 2026 Apurba Laskar (Byte desktop window: title, size)
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // Byte: open at 1280 x 820; the wide (tablet) layout needs at least 900 x 600.
    self.title = "Byte"
    self.contentMinSize = NSSize(width: 900, height: 600)
    self.setContentSize(NSSize(width: 1280, height: 820))
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
