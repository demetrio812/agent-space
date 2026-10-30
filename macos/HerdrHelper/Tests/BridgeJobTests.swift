import XCTest
import Darwin
import CryptoKit
@testable import HerdrHelperCore

final class BridgeJobTests: XCTestCase {
  var root:URL!, packageURL:URL!, executable:String!, socketPath:String!, descriptor:Int32 = -1
  override func setUpWithError() throws {
    root=URL(fileURLWithPath:"/private/tmp/abj-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    executable=root.appendingPathComponent("herdr").path
    try "#!/bin/sh\nprintf '[]\\n'\n".write(toFile:executable,atomically:true,encoding:.utf8)
    try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable)
    socketPath=root.appendingPathComponent("herdr.sock").path
    descriptor=socket(AF_UNIX,SOCK_STREAM,0)
    var address=sockaddr_un(); address.sun_family=sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of:&address.sun_path) { $0.copyBytes(from:socketPath.utf8CString.map { UInt8(bitPattern:$0) }) }
    let result=withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(descriptor,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    XCTAssertEqual(result,0)
    let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("assets/bridge.pyz")
    packageURL=root.appendingPathComponent("bridge.pyz")
    try FileManager.default.copyItem(at:source,to:packageURL)
  }
  override func tearDownWithError() throws {
    if descriptor>=0 { Darwin.close(descriptor) }
    try? FileManager.default.removeItem(at:root)
  }
  func request(_ lane:String="discovery",extra:[String:Any]=[:]) throws -> String {
    var row:[String:Any]=["id":"bridge-test","lane":lane,"executable":executable!,"socketPath":socketPath!]
    row.merge(extra) { _,new in new }
    return String(decoding:try JSONSerialization.data(withJSONObject:row),as:UTF8.self)
  }
  func config(_ lane:String="discovery") throws -> BridgeConfiguration {
    try BridgeConfiguration(request:request(lane))
  }
  func collectRecord(_ job:BridgeJob) throws -> [String:Any] {
    var bytes=Data(); let deadline=Date().addingTimeInterval(4)
    while Date()<deadline {
      let (out,err,exit)=job.read(); bytes.append(out)
      if let end=bytes.firstIndex(of:10) {
        return try JSONSerialization.jsonObject(with:bytes.prefix(upTo:end)) as! [String:Any]
      }
      if exit != nil { XCTFail(String(decoding:err,as:UTF8.self)); break }
    }
    throw HelperFault(message:"Fixture did not produce a record")
  }
  func testImageLaneExactPayloadsAndBounds() throws {
    let c=try config("transfer")
    let route:[String:Any] = ["machine":"gateway","session":"default","targetHash":String(repeating:"a",count:64),"generation":String(repeating:"b",count:64),"terminal":"t1","pane":"p1"]
    func envelope(_ op:String,_ payload:[String:Any]) -> [String:Any] {
      ["type":"request","protocol":"agentspace-bridge-v2","nonce":c.nonce,"lane":"transfer","id":"1","op":op,"payload":payload,"route":route]
    }
    XCTAssertNoThrow(try validateBridgeEnvelope(envelope("image.begin",["extension":"png","size":8,"sha256":String(repeating:"a",count:64)]),configuration:c))
    XCTAssertNoThrow(try validateBridgeEnvelope(envelope("image.chunk",["token":String(repeating:"a",count:32),"offset":0,"bytes":"YWJj"]),configuration:c))
    for payload:[String:Any] in [["extension":"png","size":true,"sha256":String(repeating:"a",count:64)],["extension":"../png","size":8,"sha256":String(repeating:"a",count:64)]] {
      XCTAssertThrowsError(try validateBridgeEnvelope(envelope("image.begin",payload),configuration:c))
    }
    for payload:[String:Any] in [["token":String(repeating:"a",count:32),"offset":true,"bytes":"YWJj"],["token":String(repeating:"a",count:32),"offset":0,"bytes":"YQ==\n"],["token":String(repeating:"a",count:32),"offset":0,"bytes":String(repeating:"YQ==",count:100000)]] {
      XCTAssertThrowsError(try validateBridgeEnvelope(envelope("image.chunk",payload),configuration:c))
    }
  }
  func testImagePasteEnvelopePreservesSingleLiteralPathAndRejectsControls() throws {
    let c=try config("input")
    let route:[String:Any]=["machine":"gateway","session":"default","targetHash":String(repeating:"a",count:64),"generation":String(repeating:"b",count:64),"terminal":"t1","pane":"p1"]
    func envelope(_ payload:[String:Any]) -> [String:Any] {
      ["type":"request","protocol":"agentspace-bridge-v2","nonce":c.nonce,"lane":"input","id":"1","op":"input","payload":payload,"route":route]
    }
    XCTAssertNoThrow(try validateBridgeEnvelope(envelope(["paste":"/cache/a'post with space.png"]),configuration:c))
    XCTAssertNoThrow(try validateBridgeEnvelope(envelope(["paste":"  first\n\tsecond café\n"]),configuration:c))
    for payload:[String:Any] in [["paste":""],["paste":"bad\r"],["paste":"bad\u{1b}"],["paste":String(repeating:"x",count:16385)],["paste":"x","keys":["enter"]],["paste":true]] {
      XCTAssertThrowsError(try validateBridgeEnvelope(envelope(payload),configuration:c))
    }
  }
  func testCancelledBridgePreparationNeverLaunchesWorker() throws {
    let entered=expectation(description:"preparing bridge"), done=expectation(description:"cancelled bridge")
    let release=DispatchSemaphore(value:0); var launched=false
    let session=HelperSession(bridgePackageURL:packageURL,processFactory: {
      entered.fulfill(); _=release.wait(timeout:.now()+3); return Process()
    },processLauncher: { child in launched=true; try child.run() })
    session.startBridge(try request()) { error in XCTAssertNotNil(error); done.fulfill() }
    wait(for:[entered],timeout:2); session.stop("bridge-test") {}; release.signal()
    wait(for:[done],timeout:3); XCTAssertFalse(launched)
  }
  func testArbitraryPackageShellAndSourceFieldsAreRejectedBeforeLaunch() throws {
    for extra in [["packageURL":"/tmp/evil.pyz"],["source":"print('evil')"],["shell":"/bin/sh"],["python":"/bin/sh"]] {
      XCTAssertThrowsError(try BridgeConfiguration(request:request(extra:extra)))
    }
  }
  func testRealBundledWorkerHelloPreservesNativeIdentityAndAcceptsHealth() throws {
    let configuration=try config()
    let process=Process()
    let job=try BridgeJob(config:configuration,packageURL:packageURL,process:process); defer { job.stop() }
    try job.start()
    let hello=try collectRecord(job)
    XCTAssertEqual(hello["protocol"] as? String,"agentspace-bridge-v2")
    let expected=SHA256.hash(data:Data(try socketIdentity(socketPath).utf8)).map { String(format:"%02x",$0) }.joined()
    if hello["generation"] as? String != expected {
      let diagnostic=Process(), pipe=Pipe(); diagnostic.executableURL=process.executableURL
      diagnostic.arguments=["-c","import os,sys; s=os.stat(sys.argv[1]); print(os.path.realpath(sys.argv[1]),s.st_dev,s.st_ino,int(s.st_birthtime),sep=':')",socketPath]
      diagnostic.standardOutput=pipe; try diagnostic.run()
      let raw=pipe.fileHandleForReading.readDataToEndOfFile(); diagnostic.waitUntilExit()
      print("Swift identity: \(try socketIdentity(socketPath)); Python identity: \(String(decoding:raw,as:UTF8.self))")
    }
    XCTAssertEqual(hello["generation"] as? String,expected)
    let health:[String:Any]=["type":"request","protocol":"agentspace-bridge-v2","nonce":configuration.nonce,"lane":"discovery","id":"1","op":"health","payload":[:]]
    try job.write(JSONSerialization.data(withJSONObject:health))
    let reply=try collectRecord(job)
    XCTAssertEqual(reply["id"] as? String,"1"); XCTAssertEqual(reply["ok"] as? Bool,true)
    job.stop(); XCTAssertThrowsError(try job.write(JSONSerialization.data(withJSONObject:health)))
  }
  func testEnvelopeCannotCrossLaneOrInvokeShellAndKeyRulesStayAligned() throws {
    let configuration=try config("input")
    let route:[String:Any]=["machine":"gateway","session":"default","targetHash":String(repeating:"a",count:64),"generation":String(repeating:"b",count:64),"terminal":"t1","pane":"p1"]
    let valid:[String:Any]=["type":"request","protocol":"agentspace-bridge-v2","nonce":configuration.nonce,"lane":"input","id":"1","op":"input","route":route,"payload":["keys":["cmd+backspace","ctrl+enter","shift+cmd+left"]]]
    XCTAssertNoThrow(try validateBridgeEnvelope(valid,configuration:configuration))
    for change:[String:Any] in [["op":"shell"],["lane":"discovery"],["nonce":String(repeating:"c",count:32)],["payload":["keys":["ctrl+ctrl+c"]]],["payload":["text":"bad\u{1b}"]],["payload":["text":String(repeating:"x",count:16385)]]] {
      var row=valid; row.merge(change) { _,new in new }
      XCTAssertThrowsError(try validateBridgeEnvelope(row,configuration:configuration))
    }
  }
  func testExplicitViewportTakeoverEnvelopeForGatewayAndPeer() throws {
    let configuration=try config("streams")
    for machine in ["gateway",String(repeating:"a",count:32)] {
      let route:[String:Any] = ["machine":machine,"session":"default","targetHash":String(repeating:"a",count:64),"generation":String(repeating:"b",count:64),"terminal":"t1","pane":"p1"]
      func envelope(_ payload:[String:Any]) -> [String:Any] {
        ["type":"request","protocol":"agentspace-bridge-v2","nonce":configuration.nonce,"lane":"streams","id":"1","op":"observe","payload":payload,"route":route]
      }
      for payload:[String:Any] in [
        ["mode":"viewport","cols":80,"rows":25],
        ["mode":"viewport","cols":80,"rows":25,"takeover":true],
        ["mode":"viewport","cols":80,"rows":25,"takeover":false],
        ["mode":"preview","cols":80,"rows":25,"takeover":false]
      ] {
        XCTAssertNoThrow(try validateBridgeEnvelope(envelope(payload),configuration:configuration))
      }
      for payload:[String:Any] in [
        ["mode":"preview","cols":80,"rows":25,"takeover":true],
        ["mode":"viewport","cols":80,"rows":25,"takeover":1],
        ["mode":"viewport","cols":80,"rows":25,"takeover":"true"],
        ["mode":"viewport","cols":80,"rows":25,"takeover":NSNull()],
        ["mode":"viewport","cols":80,"rows":25,"takeover":true,"arguments":["--anything"]],
        ["mode":"viewport","cols":true,"rows":25,"takeover":true]
      ] {
        XCTAssertThrowsError(try validateBridgeEnvelope(envelope(payload),configuration:configuration))
      }
    }
  }

  func testScrollEnvelopeUsesOnlyBoundedAttachedViewControls() throws {
    let configuration=try config("streams")
    var row:[String:Any]=["type":"request","protocol":"agentspace-bridge-v2","nonce":configuration.nonce,"lane":"streams","id":"1","op":"scroll","payload":["subscription":"7","direction":"up","steps":3]]
    XCTAssertNoThrow(try validateBridgeEnvelope(row,configuration:configuration))
    for payload:[String:Any] in [["subscription":"7","direction":"up","steps":true],["subscription":"7","direction":"up","steps":41],
      ["subscription":"7","direction":"up","steps":0],["subscription":"7","direction":"shell","steps":1],
      ["subscription":"7","direction":"up","steps":1,"text":"x"]] {
      row["payload"]=payload;XCTAssertThrowsError(try validateBridgeEnvelope(row,configuration:configuration))
    }
  }
  func testManagementEnvelopesAreTypedAndBounded() throws {
    let configuration=try config("input")
    let computer:[String:Any]=["machine":"gateway","session":"default","targetHash":String(repeating:"a",count:64),"generation":String(repeating:"b",count:64)]
    var terminal=computer; terminal["terminal"]="t1"; terminal["pane"]="p1"
    func row(_ op:String,_ route:[String:Any],_ payload:[String:Any]) -> [String:Any] {
      ["type":"request","protocol":"agentspace-bridge-v2","nonce":configuration.nonce,"lane":"input","id":"1","op":op,"route":route,"payload":payload]
    }
    XCTAssertNoThrow(try validateBridgeEnvelope(row("rename",terminal,["title":"Review café"]),configuration:configuration))
    XCTAssertNoThrow(try validateBridgeEnvelope(row("close",terminal,[:]),configuration:configuration))
    XCTAssertNoThrow(try validateBridgeEnvelope(row("create",computer,["workspace":"w1","title":"Shell","cwd":"~/project"]),configuration:configuration))
    XCTAssertNoThrow(try validateBridgeEnvelope(row("workspace.create",computer,["title":"Research","cwd":"~/project"]),configuration:configuration))
    XCTAssertNoThrow(try validateBridgeEnvelope(row("workspace.rename",computer,["workspace":"w1","title":"Research"]),configuration:configuration))
    XCTAssertNoThrow(try validateBridgeEnvelope(row("workspace.close",computer,["workspace":"w1"]),configuration:configuration))
    for invalid in [row("workspace.rename",terminal,["workspace":"w1","title":"Research"]),
                    row("workspace.rename",computer,["workspace":"w1","title":" "]),
                    row("workspace.close",computer,["workspace":"w1","close_group":true]),
                    row("workspace.close",computer,["workspace":"bad\n"]),
                    row("workspace.create",terminal,["title":"Research","cwd":""]),
                    row("workspace.create",computer,["title":" ","cwd":""]),
                    row("workspace.create",computer,["title":"Research","cwd":"relative"]),
                    row("workspace.create",computer,["title":"Research","cwd":"","command":"evil"])] {
      XCTAssertThrowsError(try validateBridgeEnvelope(invalid,configuration:configuration))
    }
    for bad in [row("rename",terminal,["title":"x","method":"shell"]),row("rename",terminal,["title":String(repeating:"é",count:65)]),
                row("rename",terminal,["title":"bad\n"]),row("close",computer,[:]),row("close",terminal,["force":true]),
                row("create",terminal,["workspace":"w1","title":"","cwd":""]),row("create",computer,["workspace":"w1","title":"","cwd":"relative"]),
                row("create",computer,["workspace":"w1","title":"","cwd":String(repeating:"/",count:4097)]),
                row("create",computer.merging(["generation":true]) { _,v in v },["workspace":"w1","title":"","cwd":""])] {
      XCTAssertThrowsError(try validateBridgeEnvelope(bad,configuration:configuration))
    }
  }
  func testExistingAgentSocketIsPreservedWithoutInjectionEnvironment() throws {
    let environment=bridgeEnvironment(["SSH_AUTH_SOCK":socketPath!,"DYLD_INSERT_LIBRARIES":"/tmp/evil","PYTHONPATH":"/tmp/evil","PATH":"/tmp/evil"],home:"/Users/fixture")
    XCTAssertEqual(environment["SSH_AUTH_SOCK"],socketPath)
    XCTAssertNil(environment["DYLD_INSERT_LIBRARIES"]); XCTAssertNil(environment["PYTHONPATH"])
    XCTAssertEqual(environment["HOME"],"/Users/fixture")
    XCTAssertNil(bridgeEnvironment(["SSH_AUTH_SOCK":executable!],home:"/Users/fixture")["SSH_AUTH_SOCK"])
  }
  func testNoisyNativeWorkerIsBoundedAndStopped() throws {
    let process=Process()
    let job=try BridgeJob(config:config(),packageURL:packageURL,process:process,launchProcess: { child in
      child.arguments=["-c","import os,time; os.write(1,b'x'*3145728); time.sleep(20)"]
      try child.run()
    })
    defer { job.stop() }
    let ended=expectation(description:"overflow stops child")
    let handler=process.terminationHandler
    process.terminationHandler={ child in handler?(child); ended.fulfill() }
    try job.start(); wait(for:[ended],timeout:5)
    var total=0; var exit:Int32?
    let deadline=Date().addingTimeInterval(3)
    while exit==nil && Date()<deadline {
      let row=job.read(); total+=row.0.count; exit=row.2
    }
    XCTAssertLessThanOrEqual(total,2*1024*1024)
    XCTAssertEqual(exit,75)
  }
}
