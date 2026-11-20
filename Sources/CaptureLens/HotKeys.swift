import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A keyboard shortcut: a key code plus Carbon modifier flags, and how to show it.
struct HotKey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    static let controlOptionCommand = UInt32(controlKey | optionKey | cmdKey)

    init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    /// Builds one from a key press, if it has at least one of ⌘ ⌥ ⌃ — a bare key would
    /// steal ordinary typing from every app.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty || Self.isFunctionKey(Int(event.keyCode)) else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers = Self.carbon(flags)
        display = Self.symbols(flags) + Self.name(for: event)
    }

    /// Builds one from a key code and Carbon modifiers (ShortcutsLens's Change Shortcut), named
    /// the way a key press would be in the current keyboard layout. Nil without ⌘ ⌥ or ⌃.
    init?(keyCode: Int, carbonModifiers: Int) {
        let mods = UInt32(carbonModifiers) & UInt32(controlKey | optionKey | shiftKey | cmdKey)
        guard (0...127).contains(keyCode), mods & UInt32(controlKey | optionKey | cmdKey) != 0 || Self.isFunctionKey(keyCode) else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if mods & UInt32(controlKey) != 0 { flags.insert(.control) }
        if mods & UInt32(optionKey) != 0 { flags.insert(.option) }
        if mods & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if mods & UInt32(cmdKey) != 0 { flags.insert(.command) }
        self.keyCode = UInt32(keyCode)
        modifiers = mods
        display = Self.symbols(flags) + Self.name(keyCode: keyCode, characters: Self.layoutCharacter(keyCode))
    }

    /// Whether a key press is this shortcut.
    func matches(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        UInt32(keyCode) == self.keyCode
            && Self.carbon(flags.intersection([.command, .option, .control, .shift])) == modifiers
    }

    /// For showing the shortcut beside a menu item.
    var menuKeyEquivalent: (key: String, mask: NSEvent.ModifierFlags) {
        var mask: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        let key = display.drop(while: { "⌃⌥⇧⌘".contains($0) }).lowercased()
        return (key.count == 1 ? key : "", mask)
    }

    /// F1–F20 may stand alone: no app types with them.
    static func isFunctionKey(_ code: Int) -> Bool { fKeys[code] != nil }

    static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }

    static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    private static func name(for event: NSEvent) -> String {
        name(keyCode: Int(event.keyCode), characters: event.charactersIgnoringModifiers)
    }

    static func name(keyCode code: Int, characters: String?) -> String {
        if let f = fKeys[code] { return "F\(f)" }
        switch code {
        case kVK_Return: return "↩"
        case kVK_Space: return "Space"
        case kVK_Escape: return "⎋"
        case kVK_Tab: return "⇥"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default: return (characters ?? "?").uppercased()
        }
    }

    /// What the key types with no modifiers in the current layout ("t" for kVK_ANSI_T on QWERTY).
    static func layoutCharacter(_ keyCode: Int, shift: Bool = false) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), shift ? UInt32(shiftKey >> 8) & 0xFF : 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }

    /// Key code → F-key number. A table, not a range: the codes are scattered (F1 is 122,
    /// F20 is 90).
    static let fKeys: [Int: Int] = {
        let codes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        return Dictionary(uniqueKeysWithValues: codes.enumerated().map { ($1, $0 + 1) })
    }()
}

/// System-wide shortcuts through Carbon's RegisterEventHotKey: works from a menu bar app
/// and needs no permission.
@MainActor
final class HotKeyCenter {
    enum Action: Hashable {
        case preset(UUID)
        case captureAgain
        case captureText
        case library
        case captureBar
        case palette
    }

    static let shared = HotKeyCenter()
    var perform: ((Action) -> Void)?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: Action] = [:]
    private var installed = false

    /// Every shortcut that's set, with what it does.
    private var bindings: [(Action, HotKey)] {
        let prefs = Preferences.shared
        var out: [(Action, HotKey)] = []
        if let key = prefs.libraryHotKey { out.append((.library, key)) }
        if let key = prefs.captureAgainHotKey { out.append((.captureAgain, key)) }
        if let key = prefs.captureTextHotKey { out.append((.captureText, key)) }
        if let key = prefs.captureBarHotKey { out.append((.captureBar, key)) }
        if let key = prefs.paletteHotKey { out.append((.palette, key)) }
        for preset in prefs.presets { if let key = preset.hotKey { out.append((.preset(preset.id), key)) } }
        return out
    }

    /// Registers the shortcuts in Preferences, replacing earlier registrations.
    func apply() {
        installHandlerOnce()
        unregisterAll()
        for (index, (action, key)) in bindings.enumerated() {
            let number = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4350_4C53), id: number) // "CPLS"
            let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[number] = ref
                actions[number] = action
            } else {
                NSLog("SnagAnything: shortcut \(key.display) not registered (\(status)), probably taken by another app")
            }
        }
        ShortcutsLensReport.publish()
    }

    /// For ShortcutsLens: the shortcuts that registered, named as Settings names them.
    var reportedShortcuts: [ShortcutsLensReport.Shortcut] {
        let registered = Set(actions.values)
        let prefs = Preferences.shared
        return bindings.compactMap { action, key in
            guard registered.contains(action) else { return nil }
            let id: String, title: String, category: String?
            switch action {
            case .library: (id, title, category) = ("library", self.title(of: action), nil)
            case .captureAgain: (id, title, category) = ("captureAgain", self.title(of: action), nil)
            case .captureText: (id, title, category) = ("captureText", self.title(of: action), nil)
            case .captureBar: (id, title, category) = ("captureBar", self.title(of: action), nil)
            case .palette: (id, title, category) = ("palette", self.title(of: action), nil)
            case .preset(let uuid):
                (id, title, category) = ("preset-\(uuid.uuidString)", prefs.preset(uuid)?.name ?? "Preset", "Presets")
            }
            return .init(id: id, title: title, keyCode: Int(key.keyCode), carbonModifiers: Int(key.modifiers), category: category)
        }
    }

    /// ShortcutsLens's Change Shortcut: saves the keys as the Settings recorder does (so Settings
    /// shows them and sync carries them) and registers again. Nil when done, or why not.
    func change(id: String, keyCode: Int, carbonModifiers: Int) -> String? {
        let prefs = Preferences.shared
        let action: Action
        switch id {
        case "library": action = .library
        case "captureAgain": action = .captureAgain
        case "captureText": action = .captureText
        case "captureBar": action = .captureBar
        case "palette": action = .palette
        default:
            guard id.hasPrefix("preset-"), let uuid = UUID(uuidString: String(id.dropFirst("preset-".count))),
                  prefs.preset(uuid) != nil else { return "SnagAnything has no shortcut called \(id)." }
            action = .preset(uuid)
        }
        guard let key = HotKey(keyCode: keyCode, carbonModifiers: carbonModifiers) else {
            return "SnagAnything shortcuts need ⌘, ⌥ or ⌃ (F-keys may stand alone)."
        }
        if let other = bindings.first(where: { $0.0 != action && $0.1.keyCode == key.keyCode && $0.1.modifiers == key.modifiers }) {
            return "SnagAnything already uses \(key.display) for \(title(of: other.0))."
        }
        let previous = hotKey(for: action)
        save(key, for: action)
        apply()
        guard !actions.values.contains(action) else { return nil }
        // Taken by another app: keep the old keys rather than leave the shortcut dead.
        save(previous, for: action)
        apply()
        return "\(key.display) is taken by another app, so SnagAnything kept \(previous?.display ?? "no shortcut")."
    }

    func hotKey(for action: Action) -> HotKey? {
        let prefs = Preferences.shared
        switch action {
        case .library: return prefs.libraryHotKey
        case .captureAgain: return prefs.captureAgainHotKey
        case .captureText: return prefs.captureTextHotKey
        case .captureBar: return prefs.captureBarHotKey
        case .palette: return prefs.paletteHotKey
        case .preset(let uuid): return prefs.preset(uuid)?.hotKey
        }
    }

    /// Writes the same settings the Settings recorders do.
    func save(_ key: HotKey?, for action: Action) {
        let prefs = Preferences.shared
        switch action {
        case .library: prefs.libraryHotKey = key
        case .captureAgain: prefs.captureAgainHotKey = key
        case .captureText: prefs.captureTextHotKey = key
        case .captureBar: prefs.captureBarHotKey = key
        case .palette: prefs.paletteHotKey = key
        case .preset(let uuid):
            guard var preset = prefs.preset(uuid) else { return }
            preset.hotKey = key
            prefs.update(preset)
        }
    }

    func title(of action: Action) -> String {
        switch action {
        case .library: return "Open the library"
        case .captureAgain: return "Capture the same area again"
        case .captureText: return "Capture text"
        case .captureBar: return "Show or hide the capture bar"
        case .palette: return "Show the quick palette"
        case .preset(let uuid): return Preferences.shared.preset(uuid)?.name ?? "a preset"
        }
    }

    /// The other shortcuts that use these keys.
    func others(using key: HotKey, except action: Action?) -> [Action] {
        bindings.filter { $0.0 != action && $0.1.keyCode == key.keyCode && $0.1.modifiers == key.modifiers }.map(\.0)
    }

    /// Whether a key press is one of SnagAnything's own shortcuts.
    func isOwnHotKey(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        bindings.contains { $0.1.matches(keyCode: keyCode, flags: flags) }
    }

    /// While a shortcut is being recorded, the current ones must not fire.
    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actions.removeAll()
    }

    private func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 2, &specs, nil, nil)
    }

    fileprivate func fire(_ id: UInt32, released: Bool) {
        guard let action = actions[id] else { return }
        if released {
            // Only the palette cares when its keys come up (hold and release).
            if action == .palette { QuickPalette.shared.hotKeyReleased() }
            return
        }
        perform?(action)
    }
}

private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    let value = id.id
    let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
    // Carbon delivers hot keys on the main thread's event loop.
    MainActor.assumeIsolated { HotKeyCenter.shared.fire(value, released: released) }
    return noErr
}
