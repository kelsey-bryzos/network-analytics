import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationWillFinishLaunching(_ notification: Notification) {
    // Kill window restoration before anything else loads.
    UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    UserDefaults.standard.set(false, forKey: "ApplePersistenceIgnoreState")
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)

    // Listen for our Flutter window to signal it's ready.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(flutterWindowReady(_:)),
      name: NSNotification.Name("MainFlutterWindowReady"),
      object: nil
    )

    // Also try immediately in case the notification already fired.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      self.bringWindowForward()
    }
  }

  @objc private func flutterWindowReady(_ note: Notification) {
    guard let window = note.object as? NSWindow else { return }
    showWindow(window)
  }

  private func bringWindowForward() {
    // Fallback: iterate all windows and show any that exist.
    for window in NSApp.windows {
      showWindow(window)
    }
  }

  private func showWindow(_ window: NSWindow) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.setIsVisible(true)
    window.orderFrontRegardless()
    window.makeKeyAndOrderFront(nil)
  }
}
