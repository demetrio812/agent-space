import Foundation
import Darwin
func socketIdentity(_ path: String) throws -> String {
  guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0") else { throw HelperFault(message: "Choose an absolute Herdr socket path.") }
  let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  var attributes = stat()
  guard Darwin.lstat(canonical, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFSOCK else { throw HelperFault(message: "Herdr is offline. Start Herdr, then reconnect.") }
  return "\(canonical):\(attributes.st_dev):\(attributes.st_ino):\(attributes.st_birthtimespec.tv_sec)"
}
func validateOperation(_ args: [String]) throws -> Bool {
  func id(_ value: String) -> Bool { value.range(of: #"^[A-Za-z0-9_.:@%+/][A-Za-z0-9_.:@%+/-]{0,255}$"#, options: .regularExpression) != nil }
  if args == ["agent","list"] || args == ["workspace","list"] || args == ["tab","list"] { return false }
  if args.count == 4 && args[0...2] == ["pane","layout","--pane"] && id(args[3]) { return false }
  if args.count == 4 && args[0...1] == ["pane","send-text"] && id(args[2]) {
    let text = args[3]
    guard !text.isEmpty, text.utf8.count <= 16384,
          !text.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else { throw HelperFault(message:"Invalid terminal text.") }
    return false
  }
  if (4...35).contains(args.count) && args[0...1] == ["pane","send-keys"] && id(args[2]) {
    let base = #"^(?:[a-z0-9]|up|down|left|right|enter|esc|tab|backspace|delete|insert|home|end|pageup|pagedown|space|f[1-9]|f1[0-2])$"#
    for key in args.dropFirst(3) {
      var parts = key.components(separatedBy:"+"); let name = parts.removeLast()
      guard key.count <= 40, Set(parts).count == parts.count,
            parts.allSatisfy({ ["ctrl","alt","shift","cmd"].contains($0) }),
            name.range(of:base,options:.regularExpression) != nil else { throw HelperFault(message:"Unsupported terminal key.") }
    }
    return false
  }
  if args.count == 4 && args[0...1] == ["pane","run"] && id(args[2]) {
    let text = args[3]
    guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, text.utf8.count <= 16384,
          !text.unicodeScalars.contains(where: { ($0.value < 32 && $0.value != 9 && $0.value != 10) || (127...159).contains($0.value) }) else { throw HelperFault(message: "Invalid terminal input.") }
    return false
  }
  if (args.count == 4 || args.count == 8) && args[0...1] == ["terminal","session"] &&
      (args[2] == "observe" || (args[2] == "control" && args.count == 8)) && id(args[3]) {
    if args.count == 8 {
      guard args[4] == "--cols", args[6] == "--rows", let cols = Int(args[5]), let rows = Int(args[7]),
            (1...512).contains(cols), (1...256).contains(rows), cols * rows <= 65536 else { throw HelperFault(message: "Invalid terminal geometry.") }
    }
    return true
  }
  throw HelperFault(message: "Unsupported Herdr operation.")
}
protocol HelperOwnedJob: AnyObject {
  func launch() throws
  func read() -> (Data,Data,Int32?)
  func stop()
}
final class HerdrJob: HelperOwnedJob {
  private let process: Process
  private let launchProcess: (Process) throws -> Void
  private let outPipe = Pipe(), errPipe = Pipe()
  private let inputLock = NSLock()
  private let controlPipe: Pipe?
  private var launched = false
  private let condition = NSCondition()
  private var stdout = Data(), stderr = Data()
  private var outTotal = 0, errTotal = 0
  private let observation: Bool
  private var outFinished = false, errFinished = false, exit: Int32?, stopped = false, overflow = false
  private var deadline: DispatchWorkItem?
  init(executable: String, socketPath: String, arguments: [String], process:Process = Process(), launchProcess:@escaping (Process) throws -> Void = { try $0.run() }, startImmediately:Bool = true) throws {
    self.process = process
    self.launchProcess = launchProcess
    observation = try validateOperation(arguments)
    controlPipe = arguments.prefix(3) == ["terminal","session","control"] ? Pipe() : nil
    _ = try socketIdentity(socketPath)
    guard executable.hasPrefix("/"), !executable.contains("\0"), FileManager.default.isExecutableFile(atPath: executable) else { throw HelperFault(message: "Choose an installed Herdr executable.") }
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    // Do not inherit preload/injection variables from the calling environment.
    process.environment = ["HERDR_SOCKET_PATH":socketPath,"PATH":"/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin","HOME":NSHomeDirectory(),"LANG":"en_US.UTF-8"]
    process.standardOutput = outPipe; process.standardError = errPipe
    process.standardInput = controlPipe ?? FileHandle.nullDevice as Any
    if let input = controlPipe {
      let fd = input.fileHandleForWriting.fileDescriptor
      _ = fcntl(fd,F_SETFL,fcntl(fd,F_GETFL) | O_NONBLOCK)
      _ = fcntl(fd,F_SETNOSIGPIPE,1)
    }
    process.terminationHandler = { [weak self] child in
      guard let self = self else { return }
      self.condition.lock(); self.exit = child.terminationStatus; self.deadline?.cancel(); self.condition.broadcast(); self.condition.unlock()
    }
    if startImmediately { try launch() }
  }
  func launch() throws {
    condition.lock()
    guard !stopped && !launched else { condition.unlock(); throw HelperFault(message:"Herdr request was cancelled or already started.") }
    launched = true; condition.unlock()
    do { try launchProcess(process) } catch { throw HelperFault(message: "Herdr could not be launched. Check its executable path.") }
    pump(outPipe.fileHandleForReading, output: true)
    pump(errPipe.fileHandleForReading, output: false)
    if !observation {
      let task = DispatchWorkItem { [weak self] in self?.stop() }
      deadline = task; DispatchQueue.global().asyncAfter(deadline:.now()+6,execute:task)
    }
  }
  private func pump(_ handle: FileHandle, output: Bool) {
    DispatchQueue.global(qos:.utility).async { [self] in
      defer {
        try? handle.close()
        condition.lock(); if output { outFinished = true } else { errFinished = true }; condition.broadcast(); condition.unlock()
      }
      do {
        var buffer = [UInt8](repeating:0,count:32768)
        while true {
          let countRead = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
          if countRead == 0 { break }
          if countRead < 0 { if errno == EINTR { continue }; throw HelperFault(message:"Herdr stream disconnected.") }
          let bytes = Data(buffer.prefix(countRead))
          condition.lock()
          let count = output ? (observation ? stdout.count : outTotal) : errTotal
          let limit = output ? 2*1024*1024 : 64*1024
          let exceeded = count + bytes.count > limit
          if exceeded { overflow = true }
          else if output { stdout.append(bytes); outTotal += bytes.count } else { stderr.append(bytes); errTotal += bytes.count }
          condition.broadcast(); condition.unlock()
          if exceeded { stop(); break }
        }
      } catch { stop() }
    }
  }
  func read() -> (Data, Data, Int32?) {
    condition.lock(); defer { condition.unlock() }
    if stdout.isEmpty && stderr.isEmpty && !(exit != nil && outFinished && errFinished) { _ = condition.wait(until:Date().addingTimeInterval(0.25)) }
    let out = Data(stdout.prefix(32768)), err = Data(stderr.prefix(32768))
    stdout.removeFirst(out.count); stderr.removeFirst(err.count)
    let complete = exit != nil && outFinished && errFinished && stdout.isEmpty && stderr.isEmpty
    return (out,err,complete ? (overflow ? 75 : exit) : nil)
  }
  func resize(cols:Int, rows:Int) throws {
    guard (1...512).contains(cols), (1...256).contains(rows), cols*rows <= 65536 else { throw HelperFault(message:"Invalid terminal dimensions.") }
    inputLock.lock(); defer { inputLock.unlock() }
    condition.lock(); let active = !stopped && launched && exit == nil; condition.unlock()
    guard active, let input = controlPipe else { throw HelperFault(message:"Terminal resize is unavailable.") }
    let bytes = Data("{\"type\":\"terminal.resize\",\"cols\":\(cols),\"rows\":\(rows)}\n".utf8)
    let count = bytes.withUnsafeBytes { Darwin.write(input.fileHandleForWriting.fileDescriptor,$0.baseAddress,bytes.count) }
    guard count == bytes.count else { throw HelperFault(message:"Terminal resize could not be sent.") }
  }
  func stop() {
    condition.lock(); let shouldStop = !stopped; stopped = true; condition.unlock()
    guard shouldStop else { return }
    inputLock.lock(); try? controlPipe?.fileHandleForWriting.close(); inputLock.unlock()
    if process.isRunning { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline:.now()+0.5) { [self] in
      if process.isRunning { Darwin.kill(process.processIdentifier,SIGKILL) }
    }
  }
}
