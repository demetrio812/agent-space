import Foundation
import Darwin
import CoreFoundation
import CryptoKit

struct BridgeConfiguration {
  let id:String, lane:String, executable:String, socketPath:String, nonce:String
  init(request:String) throws {
    guard request.utf8.count<=65536, let data=request.data(using:.utf8),
          let row=try JSONSerialization.jsonObject(with:data) as? [String:Any],
          Set(row.keys)==Set(["id","lane","executable","socketPath"]),
          let id=row["id"] as? String, id.range(of:#"^[A-Za-z0-9-]{1,80}$"#,options:.regularExpression) != nil,
          let lane=row["lane"] as? String, ["discovery","input","streams","transfer"].contains(lane),
          let executable=row["executable"] as? String, executable.hasPrefix("/"),
          executable.utf8.count<=4096, !executable.contains("\0"),
          FileManager.default.isExecutableFile(atPath:executable),
          let socketPath=row["socketPath"] as? String, socketPath.hasPrefix("/"),
          socketPath.utf8.count<=4096, !socketPath.contains("\0") else {
      throw HelperFault(message:"Choose valid Herdr paths and a supported connection.")
    }
    self.id=id; self.lane=lane; self.executable=executable; self.socketPath=socketPath
    nonce=UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
  }
}

func bridgeEnvironment(_ inherited:[String:String],home:String) -> [String:String] {
  var result=["HOME":home,"PATH":"/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin","LANG":"en_US.UTF-8"]
  if let path=inherited["SSH_AUTH_SOCK"],path.hasPrefix("/"),path.utf8.count<=4096,!path.contains("\0") {
    let canonical=URL(fileURLWithPath:path).resolvingSymlinksInPath().path
    var info=stat()
    if Darwin.lstat(canonical,&info)==0,info.st_mode&S_IFMT==S_IFSOCK,info.st_uid==geteuid() {
      result["SSH_AUTH_SOCK"]=path
    }
  }
  return result
}

func bridgeInteger(_ value:Any?) -> Int? {
  guard let number=value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
        number.doubleValue.isFinite, number.doubleValue.rounded()==number.doubleValue,
        abs(number.doubleValue)<=9007199254740991 else { return nil }
  return number.intValue
}

func validateBridgeEnvelope(_ row:[String:Any],configuration:BridgeConfiguration) throws {
  func match(_ value:Any?,_ pattern:String) -> Bool {
    guard let text=value as? String else { return false }
    return text.range(of:pattern,options:.regularExpression) != nil
  }
  let fields=Set(["type","protocol","nonce","lane","id","op","payload","route"])
  let operations:[String:Set<String>]=["discovery":["catalog","machines","health"],"input":["input","send","rename","close","create","workspace.create","health"],"streams":["observe","resize","scroll","click","cancel","health"],"transfer":["image.begin","image.chunk","image.finish","image.cancel","health"]]
  guard Set(row.keys).isSubset(of:fields), row["type"] as? String=="request",
        row["protocol"] as? String=="agentspace-bridge-v2", row["nonce"] as? String==configuration.nonce,
        row["lane"] as? String==configuration.lane, match(row["id"],#"^[1-9][0-9]{0,15}$"#),
        let op=row["op"] as? String, operations[configuration.lane]!.contains(op),
        let payload=row["payload"] as? [String:Any] else { throw HelperFault(message:"Unsupported bridge action.") }
  let terminalPattern=#"^[A-Za-z0-9_.:@%+/][A-Za-z0-9_.:@%+/-]{0,255}$"#
  var pane="p1"
  if op.hasPrefix("image.") || ["input","send","observe","rename","close","create","workspace.create"].contains(op) {
    let routeFields:Set<String> = ["create","workspace.create"].contains(op) ? ["machine","session","targetHash","generation"] : ["machine","session","targetHash","generation","terminal","pane"]
    guard let route=row["route"] as? [String:Any], Set(route.keys)==routeFields,
          match(route["machine"],#"^(?:gateway|[0-9a-f]{32})$"#), match(route["session"],#"^[A-Za-z0-9_.-]{1,64}$"#),
          ![".",".."].contains(route["session"] as! String), match(route["targetHash"],#"^[0-9a-f]{64}$"#),
          match(route["generation"],#"^[0-9a-f]{64}$"#),
          (["create","workspace.create"].contains(op) || (match(route["terminal"],terminalPattern) && match(route["pane"],terminalPattern))) else {
      throw HelperFault(message:"Invalid terminal route.")
    }
    if !["create","workspace.create"].contains(op) { pane=route["pane"] as! String }
  }
  func dimensions() throws {
    guard let cols=bridgeInteger(payload["cols"]), let rows=bridgeInteger(payload["rows"]),
          (1...512).contains(cols),(1...256).contains(rows),cols*rows<=65536 else { throw HelperFault(message:"Invalid terminal dimensions.") }
  }
  func literal(_ value:Any?,limit:Int) -> Bool {
    guard let text=value as? String,text.utf8.count<=limit else { return false }
    return !text.unicodeScalars.contains { $0.value<32 || (127..<160).contains($0.value) }
  }
  switch op {
  case "image.begin":
    guard Set(payload.keys)==Set(["extension","size","sha256"]),let ext=payload["extension"] as? String,["png","jpg","jpeg","gif","webp","bmp"].contains(ext),
          let size=bridgeInteger(payload["size"]),(1...16777216).contains(size),match(payload["sha256"],#"^[0-9a-f]{64}$"#) else { throw HelperFault(message:"Invalid image metadata.") }
  case "image.chunk":
    guard Set(payload.keys)==Set(["token","offset","bytes"]),match(payload["token"],#"^[0-9a-f]{32}$"#),
          let offset=bridgeInteger(payload["offset"]),(0...16777216).contains(offset),let value=payload["bytes"] as? String,value.utf8.count<=349528,
          let bytes=Data(base64Encoded:value),!bytes.isEmpty,bytes.count<=262144,bytes.base64EncodedString()==value else { throw HelperFault(message:"Invalid image chunk.") }
  case "image.finish","image.cancel":
    guard Set(payload.keys)==Set(["token"]),match(payload["token"],#"^[0-9a-f]{32}$"#) else { throw HelperFault(message:"Invalid image transfer.") }
  case "rename":
    guard Set(payload.keys)==Set(["title"]),literal(payload["title"],limit:128) else { throw HelperFault(message:"Invalid terminal title.") }
  case "close":
    guard payload.isEmpty else { throw HelperFault(message:"Invalid terminal close.") }
  case "workspace.create":
    guard Set(payload.keys)==Set(["title","cwd"]),literal(payload["title"],limit:128),
          let title=payload["title"] as? String,!title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
          literal(payload["cwd"],limit:4096),let cwd=payload["cwd"] as? String,
          cwd.isEmpty || cwd.hasPrefix("/") || cwd.hasPrefix("~/") else { throw HelperFault(message:"Invalid workspace creation.") }
  case "create":
    guard Set(payload.keys)==Set(["workspace","title","cwd"]),match(payload["workspace"],terminalPattern),
          literal(payload["title"],limit:128),literal(payload["cwd"],limit:4096),let cwd=payload["cwd"] as? String,
          cwd.isEmpty || cwd.hasPrefix("/") || cwd.hasPrefix("~/") else { throw HelperFault(message:"Invalid terminal creation.") }
  case "input":
    if Set(payload.keys)==Set(["text"]) || Set(payload.keys)==Set(["paste"]),
       let text=(payload["text"] ?? payload["paste"]) as? String {
      if payload["paste"] != nil {
        guard !text.isEmpty, text.utf8.count <= 16384,
              !text.unicodeScalars.contains(where: {
                ($0.value < 32 && $0.value != 9 && $0.value != 10) || (127...159).contains($0.value)
              }) else { throw HelperFault(message:"Invalid terminal paste.") }
      } else {
        _=try validateOperation(["pane","send-text",pane,text])
      }
    } else if Set(payload.keys)==Set(["keys"]),let keys=payload["keys"] as? [String] {
      _=try validateOperation(["pane","send-keys",pane]+keys)
    } else { throw HelperFault(message:"Invalid terminal input.") }
  case "send":
    guard Set(payload.keys)==Set(["text"]),let text=payload["text"] as? String else { throw HelperFault(message:"Invalid reviewed message.") }
    _=try validateOperation(["pane","run",pane,text])
  case "observe":
    guard Set(payload.keys)==Set(["mode","cols","rows"]),let mode=payload["mode"] as? String,["preview","viewport"].contains(mode) else { throw HelperFault(message:"Invalid terminal observation.") }
    try dimensions()
  case "scroll":
    guard Set(payload.keys)==Set(["subscription","direction","steps"]),match(payload["subscription"],#"^[1-9][0-9]{0,15}$"#),
          let direction=payload["direction"] as? String,["up","down"].contains(direction),
          let steps=bridgeInteger(payload["steps"]),(1...40).contains(steps) else { throw HelperFault(message:"Invalid terminal scroll.") }
  case "click":
    guard Set(payload.keys)==Set(["subscription","column","row"]),match(payload["subscription"],#"^[1-9][0-9]{0,15}$"#),
          let column=bridgeInteger(payload["column"]),(0..<512).contains(column),
          let row=bridgeInteger(payload["row"]),(0..<256).contains(row) else { throw HelperFault(message:"Invalid terminal click.") }
  case "resize":
    guard Set(payload.keys)==Set(["subscription","cols","rows"]),match(payload["subscription"],#"^[1-9][0-9]{0,15}$"#) else { throw HelperFault(message:"Invalid terminal resize.") }
    try dimensions()
  case "cancel":
    guard Set(payload.keys)==Set(["subscription"]),match(payload["subscription"],#"^[1-9][0-9]{0,15}$"#) else { throw HelperFault(message:"Invalid cancellation.") }
  case "catalog":
    guard Set(payload.keys)==Set(["epoch","priorityMachines"]),let epoch=bridgeInteger(payload["epoch"]),epoch>=0,
          let priorities=payload["priorityMachines"] as? [String],priorities.count<=16,
          priorities.allSatisfy({ match($0,#"^[0-9a-f]{32}$"#) }) else { throw HelperFault(message:"Invalid computer discovery.") }
  default:
    guard payload.isEmpty else { throw HelperFault(message:"Invalid connection check.") }
  }
}

final class BridgeJob: HelperOwnedJob {
  let configuration:BridgeConfiguration
  private let process:Process, launcher:(Process) throws->Void
  private let input=Pipe(), output=Pipe(), errors=Pipe()
  private let condition=NSCondition(), inputLock=NSLock()
  private var out=Data(), err=Data(), errTotal=0
  private var launched=false, stopped=false, outFinished=false, errFinished=false, overflow=false
  private var exit:Int32?
  static func bundledPackageURL() throws -> URL {
    let url=Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bridge.pyz")
    guard FileManager.default.fileExists(atPath:url.path) else { throw HelperFault(message:"The bundled Herdr helper is missing. Reinstall AgentSpace.") }
    return url
  }
  init(config:BridgeConfiguration,packageURL:URL,process:Process=Process(),launchProcess:@escaping (Process)throws->Void = { try $0.run() }) throws {
    configuration=config; self.process=process; launcher=launchProcess
    var info=stat()
    guard Darwin.lstat(packageURL.path,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_size<=512*1024 else { throw HelperFault(message:"Invalid bundled Herdr helper.") }
    let package=try Data(contentsOf:packageURL)
    guard package.count<=512*1024 else { throw HelperFault(message:"Bundled helper exceeds its limit.") }
    let digest=SHA256.hash(data:package).map { String(format:"%02x",$0) }.joined()
    let candidates=["/opt/homebrew/bin/python3","/usr/local/bin/python3","/usr/bin/python3"]
    guard let python=candidates.first(where:{ FileManager.default.isExecutableFile(atPath:$0) }) else { throw HelperFault(message:"This Mac needs Python 3 to connect to Herdr.") }
    let value:[String:Any]=["role":"gateway","lane":config.lane,"herdr":config.executable,"socket":config.socketPath,
                          "generationStyle":"native","allowInput":true,"allowManagement":true,"allowImages":true,"nonce":config.nonce,"digest":digest]
    process.executableURL=URL(fileURLWithPath:python)
    process.arguments=["-B",packageURL.path,try JSONSerialization.data(withJSONObject:value).base64EncodedString()]
    process.environment=bridgeEnvironment(ProcessInfo.processInfo.environment,home:NSHomeDirectory())
    process.standardInput=input; process.standardOutput=output; process.standardError=errors
    let fd=input.fileHandleForWriting.fileDescriptor
    _=fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK); _=fcntl(fd,F_SETNOSIGPIPE,1)
    process.terminationHandler={ [weak self] child in
      guard let self=self else { return }
      self.condition.lock(); self.exit=child.terminationStatus; self.condition.broadcast(); self.condition.unlock()
    }
  }
  func launch() throws { try start() }
  func start() throws {
    condition.lock(); guard !stopped && !launched else { condition.unlock(); throw HelperFault(message:"Herdr connection was cancelled.") }
    launched=true; condition.unlock()
    do { try launcher(process) } catch { throw HelperFault(message:"The local Herdr worker could not start.") }
    pump(output.fileHandleForReading,isOutput:true); pump(errors.fileHandleForReading,isOutput:false)
  }
  private func pump(_ handle:FileHandle,isOutput:Bool) {
    DispatchQueue.global(qos:.utility).async { [self] in
      defer {
        try? handle.close(); condition.lock()
        if isOutput { outFinished=true } else { errFinished=true }
        condition.broadcast(); condition.unlock()
      }
      var buffer=[UInt8](repeating:0,count:32768)
      while true {
        let count=Darwin.read(handle.fileDescriptor,&buffer,buffer.count)
        if count==0 { break }
        if count<0 { if errno==EINTR { continue }; stop(); break }
        let data=Data(buffer.prefix(count))
        condition.lock()
        let exceeded=(isOutput ? out.count : errTotal)+count>(isOutput ? 2*1024*1024 : 64*1024)
        if exceeded { overflow=true }
        else if isOutput { out.append(data) } else { err.append(data); errTotal+=count }
        condition.broadcast(); condition.unlock()
        if exceeded { stop(); break }
      }
    }
  }
  func read() -> (Data,Data,Int32?) {
    condition.lock(); defer { condition.unlock() }
    if out.isEmpty && err.isEmpty && !(exit != nil && outFinished && errFinished) { _=condition.wait(until:Date().addingTimeInterval(0.25)) }
    let stdout=Data(out.prefix(32768)),stderr=Data(err.prefix(32768))
    out.removeFirst(stdout.count); err.removeFirst(stderr.count)
    let finished=exit != nil && outFinished && errFinished && out.isEmpty && err.isEmpty
    return (stdout,stderr,finished ? (overflow ? 75 : exit) : nil)
  }
  func write(_ data:Data) throws {
    guard data.count<=2*1024*1024,let row=try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw HelperFault(message:"Invalid bridge request.") }
    try validateBridgeEnvelope(row,configuration:configuration)
    inputLock.lock(); defer { inputLock.unlock() }
    let bytes=data+Data([10]); let deadline=Date().addingTimeInterval(2)
    try bytes.withUnsafeBytes { raw in
      var offset=0
      while offset<bytes.count {
        condition.lock(); let active=launched && !stopped && exit==nil; condition.unlock()
        guard active,Date()<deadline else { throw HelperFault(message:"Herdr connection is closed or busy.") }
        let count=Darwin.write(input.fileHandleForWriting.fileDescriptor,raw.baseAddress!.advanced(by:offset),bytes.count-offset)
        if count>0 { offset+=count; continue }
        if count<0 && errno==EINTR { continue }
        if count<0 && (errno==EAGAIN || errno==EWOULDBLOCK) {
          var waiter=pollfd(fd:input.fileHandleForWriting.fileDescriptor,events:Int16(POLLOUT),revents:0)
          _=Darwin.poll(&waiter,1,10); continue
        }
        throw HelperFault(message:"Terminal input delivery could not be confirmed.")
      }
    }
  }
  func stop() {
    condition.lock(); let first = !stopped; stopped=true; let started=launched; condition.unlock()
    guard first else { return }
    inputLock.lock(); try? input.fileHandleForWriting.close(); inputLock.unlock()
    guard started else { return }
    // EOF lets Python reap its separately owned SSH/observer process groups.
    DispatchQueue.global().asyncAfter(deadline:.now()+2) { [self] in if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline:.now()+4.5) { [self] in if process.isRunning { Darwin.kill(process.processIdentifier,SIGKILL) } }
  }
}
