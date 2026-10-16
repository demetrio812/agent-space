import Foundation
import FlutterMacOS
final class HerdrNativeClient {
  private var connection:NSXPCConnection?
  private let channel:FlutterMethodChannel
  init(controller:FlutterViewController) {
    channel = FlutterMethodChannel(name:"agentspace/herdr",binaryMessenger:controller.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call,result in self?.handle(call,result:result) }
  }
  private func connect() throws -> NSXPCConnection {
    if let connection = connection { return connection }
    let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/AgentSpaceHerdrHelper.xpc")
    let requirement = try signingRequirement(at:helper,identifier:"io.agentspace.herdr-helper")
    let client = NSXPCConnection(serviceName:"io.agentspace.herdr-helper")
    client.setCodeSigningRequirement(requirement)
    client.remoteObjectInterface = NSXPCInterface(with:HerdrHelperProtocol.self)
    client.interruptionHandler = { [weak self,weak client] in DispatchQueue.main.async { if self?.connection === client { self?.connection = nil; client?.invalidate() } } }
    client.invalidationHandler = { [weak self,weak client] in DispatchQueue.main.async { if self?.connection === client { self?.connection = nil } } }
    connection = client; client.resume(); return client
  }
  private func handle(_ call:FlutterMethodCall,result:@escaping FlutterResult) {
    let once = NSLock(); var replied = false
    let finish:(Any?)->Void = { value in
      once.lock(); let deliver = !replied; replied = true; once.unlock()
      if deliver { DispatchQueue.main.async { result(value) } }
    }
    let failure:(String?)->Void = { message in finish(FlutterError(code:"herdr_helper",message:message ?? "Local Herdr helper disconnected.",details:nil)) }
    if call.method == "close" { let old = connection; connection = nil; old?.invalidate(); finish(nil); return }
    let row = call.arguments as? [String:Any] ?? [:]
    do {
      let client = try connect()
      guard let proxy = client.remoteObjectProxyWithErrorHandler({ _ in failure(nil) }) as? HerdrHelperProtocol else { failure(nil); return }
      switch call.method {
      case "discover": proxy.discover { executable,socket in finish(["executable":executable,"socketPath":socket]) }
      case "identity": guard let path = row["socketPath"] as? String else { failure("Invalid socket path."); return }; proxy.identity(path) { value,error in if let error = error { failure(error) } else { finish(value) } }
      case "start", "startBridge":
        let data = try JSONSerialization.data(withJSONObject:row)
        guard let request = String(data:data,encoding:.utf8) else { failure("Invalid request."); return }
        let completed:(String?)->Void = { error in if let error = error { failure(error) } else { finish(nil) } }
        if call.method=="startBridge" { proxy.startBridge(request,reply:completed) } else { proxy.start(request,reply:completed) }
      case "writeBridge":
        guard let id=row["id"] as? String,let record=row["record"] as? FlutterStandardTypedData else { failure("Invalid bridge request."); return }
        proxy.writeBridge(id,record:record.data) { error in if let error=error { failure(error) } else { finish(nil) } }
      case "read": guard let id = row["id"] as? String else { failure("Invalid request."); return }; proxy.read(id) { out,err,exit,error in
        if let error = error { failure(error) } else {
          var response:[String:Any] = ["out":FlutterStandardTypedData(bytes:out),"err":FlutterStandardTypedData(bytes:err)]
          if let exit = exit { response["exit"] = exit }
          finish(response)
        }
      }
      case "stop": guard let id = row["id"] as? String else { failure("Invalid request."); return }; proxy.stop(id) { finish(nil) }
      case "resize":
        guard let id = row["id"] as? String, let cols = row["cols"] as? Int, let rows = row["rows"] as? Int else { failure("Invalid dimensions."); return }
        proxy.resize(id,cols:cols,rows:rows) { error in if let error = error { failure(error) } else { finish(nil) } }
      default: finish(FlutterMethodNotImplemented)
      }
    } catch { failure((error as? HelperFault)?.message) }
  }
  deinit { connection?.invalidate() }
}
