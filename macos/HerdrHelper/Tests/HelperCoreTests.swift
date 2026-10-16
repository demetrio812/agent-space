import XCTest
import Darwin
import Security
@testable import HerdrHelperCore
final class HelperCoreTests: XCTestCase {
  var root: URL!, executable: String!, socketPath: String!, descriptor: Int32 = -1
  override func setUpWithError() throws {
    root = URL(fileURLWithPath: "/tmp/ash-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    socketPath = root.appendingPathComponent("custom.rpc").path
    descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let bytes = socketPath.utf8CString
    withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
    let result = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    XCTAssertEqual(result, 0)
    executable = root.appendingPathComponent("custom-herdr").path
    try #"""
#!/usr/bin/env python3
import os,sys,json,time
from pathlib import Path
root=Path(os.environ['HERDR_SOCKET_PATH']).parent
(root/'invoked').write_text(json.dumps(sys.argv[1:],ensure_ascii=False))
if sys.argv[1:4]==['terminal','session','observe']:
 print(json.dumps({'type':'terminal.frame','encoding':'ansi','width':175,'height':55,'seq':0,'full':True,'bytes':'ZGVtbw=='}),flush=True)
 time.sleep(60)
elif sys.argv[1:4]==['terminal','session','control']:
 print('controller started',flush=True)
 for line in sys.stdin:
  (root/'resize').write_text(line)
elif (root/'noisy').exists():
 sys.stdout.write('x'*3000000); sys.stdout.flush()
else:
 print(json.dumps({'result':{'type':'ok'}}))
"""#.write(toFile: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable)
  }
  override func tearDownWithError() throws { if descriptor >= 0 { Darwin.close(descriptor) }; try? FileManager.default.removeItem(at: root) }
  func collect(_ job: HerdrJob) throws -> (Data, Data, Int32) {
    var out = Data(), err = Data(); let limit = Date().addingTimeInterval(5)
    while Date() < limit { let chunk = job.read(); out.append(chunk.0); err.append(chunk.1); if let code = chunk.2 { return (out,err,code) } }
    job.stop(); XCTFail("Job never completed"); throw HelperFault(message: "Timeout")
  }
  func testCancellationBeforeQueuedLaunchNeverInvokesExecutable() throws {
    for disconnect in [false,true] {
      let queue = DispatchQueue(label:"fixture.launch.\(disconnect)")
      queue.suspend()
      let marker = root.appendingPathComponent("launch-boundary")
      let session = HelperSession(launchQueue:queue,processLauncher:{ child in try Data("launch requested".utf8).write(to:marker); try child.run() })
      let completed = expectation(description:"cancelled pending launch")
      let request:[String:Any] = ["id":"queued","executable":executable!,"socketPath":socketPath!,"arguments":["pane","run","p1","must not be delivered"]]
      session.start(String(decoding:try JSONSerialization.data(withJSONObject:request),as:UTF8.self)) { error in XCTAssertNotNil(error); completed.fulfill() }
      if disconnect { session.stopAll() } else { session.stop("queued") {} }
      queue.resume()
      wait(for:[completed],timeout:3)
      XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
      try? FileManager.default.removeItem(at:marker)
      Thread.sleep(forTimeInterval:0.1)
      XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("invoked").path))
      try? FileManager.default.removeItem(at:root.appendingPathComponent("invoked"))
    }
  }
  func testCancellationDuringPreparationNeverCrossesLaunchBoundary() throws {
    let preparing = expectation(description:"preparing")
    let finished = expectation(description:"cancelled")
    let release = DispatchSemaphore(value:0)
    let marker = root.appendingPathComponent("during-launch")
    let session = HelperSession(processFactory:{ preparing.fulfill(); _ = release.wait(timeout:.now()+3); return Process() }, processLauncher:{ child in try Data("launch requested".utf8).write(to:marker); try child.run() })
    let request:[String:Any] = ["id":"preparing","executable":executable!,"socketPath":socketPath!,"arguments":["pane","run","p1","must not be delivered"]]
    session.start(String(decoding:try JSONSerialization.data(withJSONObject:request),as:UTF8.self)) { error in XCTAssertNotNil(error); finished.fulfill() }
    wait(for:[preparing],timeout:2)
    session.stop("preparing") {}
    release.signal()
    wait(for:[finished],timeout:3)
    XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
  }
  func testSigningRequirementAcceptsOnlyTheExpectedBinary() throws {
    let original = URL(fileURLWithPath:"/usr/bin/true")
    let rule = try signingRequirement(at:original,identifier:"com.apple.true")
    var requirement:SecRequirement?
    XCTAssertEqual(SecRequirementCreateWithString(rule as CFString,[],&requirement),errSecSuccess)
    for (path,allowed) in [("/usr/bin/true",true),("/usr/bin/false",false)] {
      var code:SecStaticCode?
      XCTAssertEqual(SecStaticCodeCreateWithPath(URL(fileURLWithPath:path) as CFURL,[],&code),errSecSuccess)
      let status = SecStaticCodeCheckValidity(code!,[],requirement)
      XCTAssertEqual(status == errSecSuccess,allowed)
    }
    XCTAssertThrowsError(try signingRequirement(at:original,identifier:"io.impostor"))
    XCTAssertThrowsError(try signingRequirement(at:URL(fileURLWithPath:executable),identifier:"io.impostor"))
  }
  func testLiteralInputAtCustomLocation() throws {
    let text = "--literal café; $(touch should-not-exist)\nsecond line"
    let job = try HerdrJob(executable: executable, socketPath: socketPath, arguments: ["pane","run","p1",text])
    let response = try collect(job)
    XCTAssertEqual(response.2, 0)
    let request = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("invoked"))) as! [String]
    XCTAssertEqual(request, ["pane","run","p1",text])
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("should-not-exist").path))
  }
  func testKeyboardInputSeparatesLiteralTypingAndLogicalKeys() throws {
    for args in [["pane","send-text","p1"," café "],["pane","send-keys","p1","up","ctrl+enter","shift+tab","cmd+backspace","shift+cmd+left"]] {
      let job = try HerdrJob(executable:executable,socketPath:socketPath,arguments:args)
      XCTAssertEqual(try collect(job).2,0)
      let request = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("invoked"))) as! [String]
      XCTAssertEqual(request,args)
    }
    for args in [["pane","send-keys","p1","ctrl+enter; injected"],["pane","send-keys","p1","ctrl+ctrl+c"],["pane","send-text","p1","bad\u{1b}"]] {
      XCTAssertThrowsError(try HerdrJob(executable:executable,socketPath:socketPath,arguments:args))
    }
  }
  func testViewportControllerIsBoundedAndCannotTakeOver() throws {
    XCTAssertTrue(try validateOperation(["terminal","session","control","t1","--cols","90","--rows","30"]))
    for args in [["terminal","session","control","t1","--takeover"], ["terminal","session","control","t1","--cols","512","--rows","256"]] {
      XCTAssertThrowsError(try validateOperation(args))
    }
  }
  func testViewportPipeAcceptsOnlyTypedResizeAndReleasesOnStop() throws {
    let job = try HerdrJob(executable:executable,socketPath:socketPath,arguments:["terminal","session","control","t1","--cols","90","--rows","30"])
    var initial = Data(); let deadline = Date().addingTimeInterval(3)
    while initial.isEmpty && Date() < deadline { initial.append(job.read().0) }
    XCTAssertTrue(String(decoding:initial,as:UTF8.self).contains("controller started"))
    try job.resize(cols:80,rows:25)
    let file = root.appendingPathComponent("resize")
    while !FileManager.default.fileExists(atPath:file.path) && Date() < deadline { Thread.sleep(forTimeInterval:0.01) }
    let value = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
    XCTAssertEqual(value["type"] as? String,"terminal.resize")
    XCTAssertEqual(value["cols"] as? Int,80)
    XCTAssertThrowsError(try job.resize(cols:512,rows:256))
    job.stop()
    _ = try collect(job)
    XCTAssertThrowsError(try job.resize(cols:80,rows:25))
    let observer = try HerdrJob(executable:executable,socketPath:socketPath,arguments:["terminal","session","observe","t1"])
    defer { observer.stop() }
    XCTAssertThrowsError(try observer.resize(cols:80,rows:25))
  }
  func testRejectsShellAndMalformedOperationsBeforeSpawning() throws {
    for args in [["server","start"],["-c","echo injected"],["pane","run","--evil","x"],["pane","run","p1","bad\u{1b}"],["terminal","session","observe","t1","--cols","99999","--rows","40"]] {
      XCTAssertThrowsError(try HerdrJob(executable: executable, socketPath: socketPath, arguments: args))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("invoked").path))
  }
  func testMissingSocketDoesNotLaunchHerdr() throws {
    XCTAssertThrowsError(try HerdrJob(executable: executable, socketPath: root.appendingPathComponent("missing.sock").path, arguments: ["agent","list"]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("invoked").path))
  }
  func testIdentityRejectsMissingOrRegularFileAndTracksSocketReplacement() throws {
    let first = try socketIdentity(socketPath)
    try FileManager.default.removeItem(atPath: socketPath)
    XCTAssertThrowsError(try socketIdentity(socketPath))
    try Data("not a socket".utf8).write(to: URL(fileURLWithPath: socketPath))
    XCTAssertThrowsError(try socketIdentity(socketPath))
    XCTAssertFalse(first.isEmpty)
  }
  func testObservationCancellationEndsOnlyItsChild() throws {
    let job = try HerdrJob(executable: executable, socketPath: socketPath, arguments: ["terminal","session","observe","t1","--cols","175","--rows","55"])
    var initial = Data(); let deadline = Date().addingTimeInterval(3)
    while initial.isEmpty && Date() < deadline { initial.append(job.read().0) }
    XCTAssertTrue(String(decoding:initial,as:UTF8.self).contains("175"))
    job.stop()
    let result = try collect(job)
    XCTAssertNotEqual(result.2, 0)
    XCTAssertNoThrow(try socketIdentity(socketPath))
  }
  func testOversizedOutputIsBoundedAndTerminatesChild() throws {
    try Data().write(to: root.appendingPathComponent("noisy"))
    let job = try HerdrJob(executable: executable, socketPath: socketPath, arguments: ["agent","list"])
    Thread.sleep(forTimeInterval: 0.25)
    let result = try collect(job)
    XCTAssertLessThanOrEqual(result.0.count, 2*1024*1024)
    XCTAssertNotEqual(result.2, 0)
  }
}
