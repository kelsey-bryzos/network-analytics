import Cocoa
import FlutterMacOS
import Sparkle

@main
class AppDelegate: FlutterAppDelegate {

  // Sparkle silent auto-update controller. Configured via Info.plist:
  //   SUFeedURL              = https://updates.optics.bryzos.com/macos/appcast.xml
  //   SUPublicEDKey          = (Ed25519 public key, base64)
  //   SUEnableAutomaticChecks = true
  //   SUScheduledCheckInterval = 86400 (daily)
  //   SUAutomaticallyUpdate    = true
  // We start the updater immediately so background checks begin at launch.
  private lazy var updaterController: SPUStandardUpdaterController = {
    return SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
  }()

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

    // Touch the updater so it boots and begins its scheduled check cycle.
    _ = updaterController

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

  /// Triggered by the "Check for Updates…" menu item.
  @IBAction func checkForUpdates(_ sender: Any?) {
    updaterController.checkForUpdates(sender)
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
