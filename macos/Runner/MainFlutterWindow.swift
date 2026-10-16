import Cocoa
import FlutterMacOS
import desktop_multi_window

class MainFlutterWindow: NSWindow {
  private var bridge: AgentSpaceWindowBridge?
  private var closeRequested = false

  override func awakeFromNib() {
    let controller = FlutterViewController()
    contentViewController = controller
    title = "AgentSpace"
    minSize = NSSize(width: 420, height: 430)
    setContentSize(NSSize(width: 1280, height: 800))
    center()
    RegisterGeneratedPlugins(registry: controller)
    bridge = AgentSpaceWindowBridge(controller: controller)
    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
      RegisterGeneratedPlugins(registry: controller)
      AgentSpaceWindowBridge.attach(to: controller)
    }
    super.awakeFromNib()
  }

  override func close() {
    if closeRequested { return }
    closeRequested = true
    prepareForTermination { [weak self] in self?.finishClose() }
  }
  func prepareForTermination(_ completion: @escaping () -> Void) {
    var replied = false
    let finish = {
      guard !replied else { return }
      replied = true
      completion()
    }
    guard let bridge = bridge else { finish(); return }
    bridge.channel.invokeMethod("requestClose", arguments: nil) { _ in finish() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: finish)
  }
  private func finishClose() {
    guard closeRequested else { return }
    closeRequested = false
    super.close()
  }
}

final class AgentSpaceWindowBridge {
  private static var bridges: [AgentSpaceWindowBridge] = []
  let channel: FlutterMethodChannel
  private weak var controller: FlutterViewController?
  private var notifications: [NSObjectProtocol] = []
  private var herdrClient: HerdrNativeClient?
  private var geometryWork: DispatchWorkItem?

  static func attach(to controller: FlutterViewController) {
    bridges.append(AgentSpaceWindowBridge(controller: controller))
  }
  init(controller: FlutterViewController) {
    self.controller = controller
    channel = FlutterMethodChannel(name: "agentspace/window", binaryMessenger: controller.engine.binaryMessenger)
    herdrClient = HerdrNativeClient(controller:controller)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "bootstrap":
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir }.map { String(cString: $0) } ?? NSHomeDirectory()
        result(["userHome": home])
      case "restoreGeometry":
        if let data = call.arguments as? [String: Any] { self.restoreGeometry(data) }
        result(nil)
      case "setTitle":
        self.controller?.view.window?.title = call.arguments as? String ?? "AgentSpace"
        result(nil)
      case "show":
        self.controller?.view.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        result(nil)
      case "hide":
        self.controller?.view.window?.orderOut(nil)
        result(nil)
      case "close":
        self.controller?.view.window?.performClose(nil)
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
    for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
      notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
        guard let self = self, let window = self.controller?.view.window, notification.object as? NSWindow === window else { return }
        self.geometryWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak window] in
          guard let self = self, let frame = window?.frame else { return }
          self.channel.invokeMethod("geometry", arguments: ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height])
        }
        self.geometryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
      })
    }
  }
  deinit { for observer in notifications { NotificationCenter.default.removeObserver(observer) } }
  private func restoreGeometry(_ data: [String: Any]) {
    guard let window = controller?.view.window else { return }
    let x = (data["x"] as? NSNumber)?.doubleValue
    let y = (data["y"] as? NSNumber)?.doubleValue
    let width = (data["width"] as? NSNumber)?.doubleValue ?? 1280
    let height = (data["height"] as? NSNumber)?.doubleValue ?? 840
    let screen = NSScreen.screens.first(where: { screen in
      guard let x = x, let y = y else { return false }
      return screen.visibleFrame.contains(NSPoint(x: x + width / 2, y: y + height / 2))
    }) ?? NSScreen.main
    guard let bounds = screen?.visibleFrame else { return }
    let w = min(max(420, width.isFinite ? width : 1280), bounds.width)
    let h = min(max(430, height.isFinite ? height : 840), bounds.height)
    let px = min(max(x ?? bounds.midX - w / 2, bounds.minX), bounds.maxX - w)
    let py = min(max(y ?? bounds.midY - h / 2, bounds.minY), bounds.maxY - h)
    window.setFrame(NSRect(x: px, y: py, width: w, height: h), display: true)
  }
}
