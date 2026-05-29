import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Clamp to screen bounds so a stale off-screen frame doesn't hide the window.
    if let screen = NSScreen.main {
      let visible = screen.visibleFrame
      let targetW = min(max(self.frame.width, 1280), visible.width - 40)
      let targetH = min(max(self.frame.height, 820), visible.height - 40)
      let originX = visible.origin.x + (visible.width - targetW) / 2
      let originY = visible.origin.y + (visible.height - targetH) / 2
      self.setFrame(NSRect(x: originX, y: originY, width: targetW, height: targetH),
                    display: true)
    }
    self.minSize = NSSize(width: 960, height: 640)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Set the window title explicitly — the XIB uses APP_NAME as a placeholder
    // which only resolves if an InfoPlist.strings localization file exists.
    self.title = "Network Analytics"

    super.awakeFromNib()

    // Notify AppDelegate that our window is ready so it can call makeKeyAndOrderFront.
    NotificationCenter.default.post(name: NSNotification.Name("MainFlutterWindowReady"),
                                    object: self)
  }
}
