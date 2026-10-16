import Foundation
import Security
struct HelperFault: Error { let message: String }
@objc(AgentSpaceHerdrHelperProtocol) protocol HerdrHelperProtocol {
  func discover(_ reply:@escaping (String,String) -> Void)
  func identity(_ path:String, reply:@escaping (String?,String?) -> Void)
  func start(_ request:String, reply:@escaping (String?) -> Void)
  func startBridge(_ request:String, reply:@escaping (String?) -> Void)
  func writeBridge(_ id:String, record:Data, reply:@escaping (String?) -> Void)
  func read(_ id:String, reply:@escaping (Data,Data,NSNumber?,String?) -> Void)
  func resize(_ id:String, cols:Int, rows:Int, reply:@escaping (String?) -> Void)
  func stop(_ id:String, reply:@escaping () -> Void)
}
func signingRequirement(at url:URL, identifier:String) throws -> String {
  var code: SecStaticCode?
  guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code = code,
        SecStaticCodeCheckValidity(code, SecCSFlags(rawValue:kSecCSStrictValidate), nil) == errSecSuccess else { throw HelperFault(message:"The bundled app or helper signature is invalid.") }
  var details: CFDictionary?
  guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue:kSecCSSigningInformation), &details) == errSecSuccess,
        let info = details as? [String:Any], info[kSecCodeInfoIdentifier as String] as? String == identifier,
        let hash = info[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty else { throw HelperFault(message:"Unexpected app or helper identity.") }
  // Pin this exact embedded build, including ad-hoc development signatures.
  // The XPC runtime applies this requirement to incoming messages (no PID lookup).
  let digest = hash.map { String(format:"%02x",$0) }.joined()
  return "identifier \"\(identifier)\" and cdhash H\"\(digest)\""
}
