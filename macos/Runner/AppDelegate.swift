import Cocoa
import FlutterMacOS
import os.log

@main
class AppDelegate: FlutterAppDelegate {
  private var keyboardMonitor: Any?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // FlutterAppDelegate implements willFinishLaunching, but not this optional
    // callback. Calling super here raises before the monitor can be installed.
    keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
      // Local to our Flutter windows, including detached session windows.
      // This neither monitors other apps nor reads/pastes the clipboard itself.
      guard let window = event.window ?? NSApp.keyWindow,
            window.contentViewController is FlutterViewController else { return event }
      return MacKeyboardEventNormalizer.normalize(event)
    }
    os_log("Keyboard event monitor installed: %{public}d",
      log: OSLog(subsystem: "io.novaware.agentspace", category: "Keyboard"),
      type: .default, keyboardMonitor != nil ? 1 : 0)
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
