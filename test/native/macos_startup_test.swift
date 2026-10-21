import Cocoa

// The launch regression runs the real delegate against the built Flutter
// framework without opening a Flutter window or connecting to any sessions.
class MainFlutterWindow: NSWindow {
  func prepareForTermination(_ completion: @escaping () -> Void) { completion() }
}

@main
enum MacStartupTests {
  static func main() {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let monitor = Mirror(reflecting: delegate).children.first { $0.label == "keyboardMonitor" }
    guard let monitor, !Mirror(reflecting: monitor.value).children.isEmpty else {
      fputs("FAIL: application startup must install the keyboard monitor\n", stderr)
      exit(1)
    }
    print("macOS application startup checks passed")
  }
}
