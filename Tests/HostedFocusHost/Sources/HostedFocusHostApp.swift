import AppKit

@main
@MainActor
final class HostedFocusHostAppDelegate: NSObject, NSApplicationDelegate {
  @objc dynamic private(set) var didFinishLaunching = false

  static func main() {
    let application = HostedFocusHostApplication.shared
    let delegate = HostedFocusHostAppDelegate()
    application.delegate = delegate
    _ = application.setActivationPolicy(.regular)
    application.run()
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    _ = NSApp.setActivationPolicy(.regular)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    didFinishLaunching = true
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }
}
