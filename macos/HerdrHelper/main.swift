import Foundation
@main struct HerdrHelperMain {
  static func main() {
    let delegate = HerdrHelperListener()
    let listener = NSXPCListener.service()
    listener.delegate = delegate
    withExtendedLifetime(delegate) { listener.resume() }
  }
}
