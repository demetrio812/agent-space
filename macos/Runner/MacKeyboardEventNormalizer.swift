import Cocoa

enum MacKeyboardEventNormalizer {
  static func normalize(_ event: NSEvent) -> NSEvent {
    // Dictation/clipboard tools can send Command without a left/right device
    // bit. Flutter 3.47.7 tracks only those bits, dropping the paste modifier.
    // Preserve physical keys (including Right Command) and non-key events.
    let flags = event.modifierFlags.rawValue
    let commandSides: UInt = 0x18 // NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK
    guard (event.type == .keyDown || event.type == .keyUp),
          event.modifierFlags.contains(.command), flags & commandSides == 0 else {
      return event
    }
    return NSEvent.keyEvent(
      with: event.type, location: event.locationInWindow,
      modifierFlags: NSEvent.ModifierFlags(rawValue: flags | 0x8),
      timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
      characters: event.characters ?? "",
      charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
      isARepeat: event.isARepeat, keyCode: event.keyCode
    ) ?? event
  }
}
