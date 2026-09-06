import AppKit

@main
final class HostedFocusHostAppDelegate: NSObject, NSApplicationDelegate {
  static func main() {
    let application = NSApplication.shared
    let delegate = HostedFocusHostAppDelegate()
    application.delegate = delegate
    _ = application.setActivationPolicy(.regular)
    application.run()
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    _ = NSApp.setActivationPolicy(.regular)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }
}
