import Foundation
import Darwin
final class HelperSession: NSObject, HerdrHelperProtocol {
  private let lock = NSLock()
  private let launchQueue: DispatchQueue
  private let processFactory: () -> Process
  private let processLauncher: (Process) throws -> Void
  private let bridgePackageURL:URL?
  init(launchQueue:DispatchQueue = DispatchQueue.global(qos:.userInitiated), bridgePackageURL:URL? = nil, processFactory:@escaping ()->Process = { Process() }, processLauncher:@escaping (Process) throws->Void = { try $0.run() }) { self.launchQueue = launchQueue; self.bridgePackageURL=bridgePackageURL; self.processFactory = processFactory; self.processLauncher = processLauncher; super.init() }
  private var jobs:[String:HelperOwnedJob] = [:], pending = Set<String>(), cancelled = Set<String>(), reading = Set<String>()
  private var closed = false
  func discover(_ reply:@escaping (String,String)->Void) {
    let home = NSHomeDirectory()
    let choices = ["\(home)/.local/bin/herdr","/opt/homebrew/bin/herdr","/usr/local/bin/herdr"]
    reply(choices.first(where: { FileManager.default.isExecutableFile(atPath:$0) }) ?? choices[0], "\(home)/.config/herdr/herdr.sock")
  }
  func identity(_ path:String, reply:@escaping (String?,String?)->Void) {
    do { reply(try socketIdentity(path),nil) } catch { reply(nil,(error as? HelperFault)?.message ?? "Herdr is unavailable.") }
  }
  func start(_ request:String, reply:@escaping (String?)->Void) {
    guard request.utf8.count <= 65536, let data = request.data(using:.utf8), let row = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
          let id = row["id"] as? String, id.range(of:#"^[A-Za-z0-9-]{1,80}$"#,options:.regularExpression) != nil,
          let executable = row["executable"] as? String, let path = row["socketPath"] as? String, let args = row["arguments"] as? [String] else { reply("Invalid Herdr request."); return }
    lock.lock()
    guard !closed, jobs.count + pending.count < 24, jobs[id] == nil, !pending.contains(id) else { lock.unlock(); reply("Herdr helper is busy or closed."); return }
    pending.insert(id); lock.unlock()
    launchQueue.async { [self] in
      lock.lock()
      let alreadyCancelled = closed || cancelled.remove(id) != nil
      if alreadyCancelled { pending.remove(id) }
      lock.unlock()
      if alreadyCancelled { reply("Herdr request was cancelled."); return }
      do {
        let job = try HerdrJob(executable:executable,socketPath:path,arguments:args,process:processFactory(),launchProcess:processLauncher,startImmediately:false)
        lock.lock(); pending.remove(id)
        let abandon = closed || cancelled.remove(id) != nil
        if abandon { lock.unlock(); job.stop(); reply("Herdr request was cancelled.") }
        else {
          // Cancellation and the actual spawn share this lock; preparation is outside it.
          do { try job.launch(); jobs[id] = job; lock.unlock(); reply(nil) }
          catch { lock.unlock(); throw error }
        }
      } catch {
        lock.lock(); pending.remove(id); cancelled.remove(id); lock.unlock()
        reply((error as? HelperFault)?.message ?? "Herdr could not start.")
      }
    }
  }
  func read(_ id:String, reply:@escaping (Data,Data,NSNumber?,String?)->Void) {
    lock.lock()
    guard let job = jobs[id], !reading.contains(id), !closed else { lock.unlock(); reply(Data(),Data(),nil,"Herdr request is no longer available."); return }
    reading.insert(id); lock.unlock()
    DispatchQueue.global(qos:.utility).async { [self] in
      let (out,err,exit) = job.read()
      lock.lock(); reading.remove(id); if exit != nil { jobs.removeValue(forKey:id) }; lock.unlock()
      reply(out,err,exit.map { NSNumber(value:$0) },nil)
    }
  }
  func startBridge(_ request:String, reply:@escaping (String?)->Void) {
    do {
      let config=try BridgeConfiguration(request:request), id=config.id
      lock.lock()
      guard !closed, jobs.count+pending.count<24,jobs[id]==nil,!pending.contains(id) else { lock.unlock(); reply("Herdr helper is busy or closed."); return }
      pending.insert(id); lock.unlock()
      launchQueue.async { [self] in
        lock.lock(); let cancelledBefore=closed || cancelled.remove(id) != nil
        if cancelledBefore { pending.remove(id) }; lock.unlock()
        if cancelledBefore { reply("Herdr connection was cancelled."); return }
        do {
          let process=processFactory()
          let package=try bridgePackageURL ?? BridgeJob.bundledPackageURL()
          let job=try BridgeJob(config:config,packageURL:package,process:process,launchProcess:processLauncher)
          lock.lock(); pending.remove(id)
          if closed || cancelled.remove(id) != nil { lock.unlock(); job.stop(); reply("Herdr connection was cancelled."); return }
          do { try job.start(); jobs[id]=job; lock.unlock(); reply(nil) }
          catch { lock.unlock(); throw error }
        } catch {
          lock.lock(); pending.remove(id); cancelled.remove(id); lock.unlock()
          reply((error as? HelperFault)?.message ?? "The local Herdr worker could not start.")
        }
      }
    } catch { reply((error as? HelperFault)?.message ?? "Invalid Herdr connection.") }
  }
  func writeBridge(_ id:String,record:Data,reply:@escaping (String?)->Void) {
    lock.lock(); let job=closed ? nil : jobs[id] as? BridgeJob; lock.unlock()
    guard let job=job else { reply("Herdr connection is no longer available."); return }
    do { try job.write(record); reply(nil) }
    catch { reply((error as? HelperFault)?.message ?? "Terminal delivery could not be confirmed.") }
  }
  func stop(_ id:String, reply:@escaping ()->Void) {
    lock.lock(); let job = jobs.removeValue(forKey:id); if pending.contains(id) { cancelled.insert(id) }; lock.unlock()
    job?.stop(); reply()
  }
  func resize(_ id:String, cols:Int, rows:Int, reply:@escaping (String?)->Void) {
    lock.lock(); let job = closed ? nil : jobs[id]; lock.unlock()
    guard let job = job as? HerdrJob else { reply("Terminal resize is unavailable."); return }
    do { try job.resize(cols:cols,rows:rows); reply(nil) }
    catch { reply((error as? HelperFault)?.message ?? "Terminal resize failed.") }
  }
  func stopAll() {
    lock.lock(); closed = true; let current = Array(jobs.values); jobs.removeAll(); lock.unlock()
    for job in current { job.stop() }
  }
}
final class HerdrHelperListener: NSObject, NSXPCListenerDelegate {
  func listener(_ listener:NSXPCListener, shouldAcceptNewConnection connection:NSXPCConnection)->Bool {
    guard connection.effectiveUserIdentifier == geteuid() else { return false }
    let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard app.pathExtension == "app", let requirement = try? signingRequirement(at:app,identifier:"io.agentspace.desktop") else { return false }
    connection.setCodeSigningRequirement(requirement)
    let session = HelperSession()
    connection.exportedInterface = NSXPCInterface(with:HerdrHelperProtocol.self)
    connection.exportedObject = session
    connection.interruptionHandler = { session.stopAll() }
    connection.invalidationHandler = { session.stopAll() }
    connection.resume()
    return true
  }
}
