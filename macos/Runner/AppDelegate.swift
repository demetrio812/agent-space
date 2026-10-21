import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var keyboardMonitor: Any?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
      // Local to our Flutter windows, including detached session windows.
      // This neither monitors other apps nor reads/pastes the clipboard itself.
      guard let window = event.window ?? NSApp.keyWindow,
            window.contentViewController is FlutterViewController else { return event }
      return MacKeyboardEventNormalizer.normalize(event)
    }
  }

  deinit {
    if let monitor = keyboardMonitor { NSEvent.removeMonitor(monitor) }
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let window = sender.windows.first(where: { $0 is MainFlutterWindow }) as? MainFlutterWindow else {
      return .terminateNow
    }
    window.prepareForTermination {
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
