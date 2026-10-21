import Cocoa

@main
enum MacKeyboardTests {
  static func main() {
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
      if !condition { fputs("FAIL: \(message)\n", stderr); failures += 1 }
    }
    func event(_ flags: UInt, type: NSEvent.EventType = .keyDown,
               keyCode: UInt16 = 9, characters: String = "v") -> NSEvent {
      NSEvent.keyEvent(with: type, location: NSPoint(x: 12, y: 34),
        modifierFlags: NSEvent.ModifierFlags(rawValue: flags), timestamp: 42,
        windowNumber: 123, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    // A dictation app can supply the public Command flag without a device side.
    // Flutter 3.47.7 synchronizes Meta from 0x8/0x10, not from 0x100000.
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      let original = event(0x100000, type: type)
      let normalized = MacKeyboardEventNormalizer.normalize(original)
      check(normalized.modifierFlags.rawValue == 0x100008,
            "generated Cmd+V must retain Command in Flutter for \(type)")
      check(original.modifierFlags.rawValue == 0x100000, "do not mutate original event")
      check(normalized.type == type && normalized.keyCode == 9 &&
            normalized.characters == "v" && normalized.charactersIgnoringModifiers == "v",
            "preserve key payload")
      check(normalized.windowNumber == 123 && normalized.timestamp == 42 &&
            normalized.locationInWindow == NSPoint(x: 12, y: 34), "preserve event routing")
      check(MacKeyboardEventNormalizer.normalize(normalized) === normalized,
            "redispatched events must not be rewritten again")
    }
    for flags: UInt in [0, 0x100008, 0x100010, 0x100018, 0x20000, 0x40000, 0x80000] {
      let original = event(flags)
      check(MacKeyboardEventNormalizer.normalize(original) === original,
            "physical keys and non-Command events stay unchanged: \(flags)")
    }
    let released = event(0, type: .keyUp)
    check(MacKeyboardEventNormalizer.normalize(released).modifierFlags.isEmpty,
          "Command must be released when the event has no modifier")
    let shifted = MacKeyboardEventNormalizer.normalize(event(0x120002, characters: "V"))
    check(shifted.modifierFlags.rawValue == 0x12000a, "preserve other modifiers")
    let flagsChanged = event(0x100000, type: .flagsChanged, keyCode: 54, characters: "")
    check(MacKeyboardEventNormalizer.normalize(flagsChanged) === flagsChanged,
          "do not rewrite the physical Right Command transition")
    if failures > 0 { exit(1) }
    print("macOS keyboard compatibility checks passed")
  }
}
