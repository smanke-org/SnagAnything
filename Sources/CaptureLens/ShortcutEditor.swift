import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A shortcut box. Clicking it opens an editor with modifier buttons and a key field; pressing
/// the keys while it's open fills them in too. `action` is which shortcut this is, so the same
/// keys can be moved off another SnagAnything shortcut.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var hotKey: HotKey?
    var action: HotKeyCenter.Action? = nil

    func makeNSView(context: Context) -> RecorderButton {
        let view = RecorderButton()
        // Keep its own width rather than stretching across a row.
        view.setContentHuggingPriority(.required, for: .horizontal)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: RecorderButton, context: Context) {
        view.onChange = { hotKey = $0 }
        view.action_ = action
        view.hotKey = hotKey
    }

    final class RecorderButton: NSButton {
        var onChange: ((HotKey?) -> Void)?
        var action_: HotKeyCenter.Action?
        var hotKey: HotKey? { didSet { refresh() } }
        private var popover: NSPopover?
        private var model: ShortcutEditorModel?
        private var monitor: Any?

        override init(frame: NSRect) {
            super.init(frame: frame)
            bezelStyle = .rounded
            target = self
            action = #selector(open)
            refresh()
        }

        required init?(coder: NSCoder) { fatalError() }

        override var intrinsicContentSize: NSSize { NSSize(width: 140, height: super.intrinsicContentSize.height) }

        private func refresh() {
            title = popover != nil ? "Set a shortcut…" : (hotKey?.display ?? "Click to set")
        }

        @objc private func open() {
            guard popover == nil, window != nil else { popover?.close(); return }
            // The current shortcuts must not fire while new keys are pressed.
            HotKeyCenter.shared.unregisterAll()
            let model = ShortcutEditorModel(hotKey: hotKey, action: action_)
            model.finish = { [weak self] result in self?.finish(result) }
            self.model = model
            let host = NSHostingController(rootView: ShortcutEditor(model: model))
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = host
            popover.contentSize = host.view.fittingSize
            popover.delegate = PopoverCloser.shared
            PopoverCloser.shared.onClose[ObjectIdentifier(popover)] = { [weak self] in self?.closed() }
            self.popover = popover
            refresh()
            popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak model] event in
                guard let model else { return event }
                return model.handle(event) ? nil : event
            }
        }

        /// Set or Clear. Nil result with `set` false means cancelled.
        private func finish(_ result: ShortcutEditorModel.Result) {
            if case .set(let key) = result {
                if let key {
                    // Move: the keys leave any other shortcut that had them.
                    for other in HotKeyCenter.shared.others(using: key, except: action_) {
                        HotKeyCenter.shared.save(nil, for: other)
                    }
                }
                hotKey = key
                onChange?(key)
            }
            popover?.close()
        }

        private func closed() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let popover { PopoverCloser.shared.onClose[ObjectIdentifier(popover)] = nil }
            popover = nil
            model = nil
            refresh()
            // The binding writes Preferences synchronously, so this sees the new key.
            HotKeyCenter.shared.apply()
        }

        #if DEBUG
        var debugHintShowing: Bool { model?.showHint ?? false }
        var debugHintFrame: NSRect { popover?.contentViewController?.view.window?.frame ?? .zero }
        var debugScreenFrame: NSRect { window?.convertToScreen(convert(bounds, to: nil)) ?? .zero }
        var debugTitle: String { title }
        var debugModel: ShortcutEditorModel? { model }
        var debugPopoverView: NSView? { popover?.contentViewController?.view }
        #endif
    }
}

/// NSPopover's delegate is weak; one shared object tells each button its popover closed.
@MainActor private final class PopoverCloser: NSObject, NSPopoverDelegate {
    static let shared = PopoverCloser()
    var onClose: [ObjectIdentifier: () -> Void] = [:]
    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        onClose[ObjectIdentifier(popover)]?()
    }
}

@MainActor final class ShortcutEditorModel: ObservableObject {
    enum Result { case set(HotKey?), cancel }

    @Published var control = false
    @Published var option = false
    @Published var shift = false
    @Published var command = false
    /// What's in the key box: one typed character, or a named key from the menu.
    @Published var keyText = ""
    /// Set when the key came from the menu or a key press, so its name needn't be looked up.
    @Published var keyCode: Int?
    @Published var showHint = false

    let action: HotKeyCenter.Action?
    let original: HotKey?
    var finish: ((Result) -> Void)?
    private var modifiersDown = false
    private var sawKey = false

    init(hotKey: HotKey?, action: HotKeyCenter.Action?) {
        self.action = action
        original = hotKey
        if let hotKey {
            control = hotKey.modifiers & UInt32(controlKey) != 0
            option = hotKey.modifiers & UInt32(optionKey) != 0
            shift = hotKey.modifiers & UInt32(shiftKey) != 0
            command = hotKey.modifiers & UInt32(cmdKey) != 0
            keyCode = Int(hotKey.keyCode)
            keyText = KeyNames.name(Int(hotKey.keyCode))
        }
    }

    var carbonModifiers: Int {
        (control ? controlKey : 0) | (option ? optionKey : 0) | (shift ? shiftKey : 0) | (command ? cmdKey : 0)
    }

    var combo: HotKey? {
        guard let code = keyCode else { return nil }
        return HotKey(keyCode: code, carbonModifiers: carbonModifiers)
    }

    /// Why Set is off, when a key is chosen.
    var problem: String? {
        guard !keyText.isEmpty else { return nil }
        guard let code = keyCode else { return "SnagAnything can't find “\(keyText)” on this keyboard." }
        if combo == nil && !HotKey.isFunctionKey(code) && !(control || option || command) {
            return "Add ⌃, ⌥ or ⌘. Only F-keys can be used on their own."
        }
        return nil
    }

    /// Other SnagAnything shortcuts these keys will be taken from.
    var movesFrom: [String] {
        guard let combo else { return [] }
        return HotKeyCenter.shared.others(using: combo, except: action).map { HotKeyCenter.shared.title(of: $0) }
    }

    var systemUse: String? {
        guard let combo else { return nil }
        return KeyNames.systemShortcuts[KeyNames.Combo(code: Int(combo.keyCode), mods: Int(combo.modifiers))]
    }

    /// The key box changed: keep the last character typed and find its key.
    func typed(_ text: String) {
        if text.count > 1, let last = text.last { keyText = String(last); return }
        guard !text.isEmpty else { keyCode = nil; return }
        if let code = keyCode, KeyNames.name(code) == text { return }
        if let (code, needsShift) = KeyNames.keyCode(for: text) {
            keyCode = code
            if needsShift { shift = true }
            // Show the base key: ⇧ + = stays “=”, not “+”.
            let base = KeyNames.name(code)
            if base != text { keyText = base }
        } else {
            keyCode = nil
        }
    }

    func choose(_ code: Int) {
        keyCode = code
        keyText = KeyNames.name(code)
    }

    /// A key press while the editor is open. True when it was used.
    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.type == .flagsChanged {
            // A shortcut another app has taken never arrives: the modifiers go down and up
            // with no key between them.
            let held = !flags.intersection([.command, .option, .control]).isEmpty
            if held && !modifiersDown { modifiersDown = true; sawKey = false }
            else if !held && modifiersDown { modifiersDown = false; if !sawKey { showHint = true } }
            return false
        }
        sawKey = true
        let code = Int(event.keyCode)
        if code == kVK_Escape { finish?(.cancel); return true }
        if code == kVK_Return || code == kVK_ANSI_KeypadEnter, flags.isEmpty {
            if combo != nil && problem == nil { finish?(.set(combo)) }
            return true
        }
        // With ⌃ ⌥ or ⌘ held, or an F-key, it's the whole shortcut; plain typing goes to the key box.
        guard !flags.intersection([.command, .option, .control]).isEmpty || HotKey.isFunctionKey(code) else { return false }
        control = flags.contains(.control)
        option = flags.contains(.option)
        shift = flags.contains(.shift)
        command = flags.contains(.command)
        choose(code)
        showHint = false
        return true
    }
}

struct ShortcutEditor: View {
    @ObservedObject var model: ShortcutEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.xs) {
                toggle("⌃", "Control", $model.control)
                toggle("⌥", "Option", $model.option)
                toggle("⇧", "Shift", $model.shift)
                toggle("⌘", "Command", $model.command)
                Text("+").foregroundStyle(.secondary)
                TextField("Key", text: Binding(get: { model.keyText }, set: { model.typed($0) }))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(width: 64)
                    .help("Type a letter, number or symbol")
                Menu {
                    ForEach(KeyNames.specialKeys, id: \.self) { code in
                        Button(KeyNames.spoken(code)) { model.choose(code) }
                    }
                    Divider()
                    ForEach(Array(KeyNames.functionKeys.prefix(12)), id: \.self) { code in
                        Button(KeyNames.name(code)) { model.choose(code) }
                    }
                    Menu("More F-keys") {
                        ForEach(Array(KeyNames.functionKeys.dropFirst(12)), id: \.self) { code in
                            Button(KeyNames.name(code)) { model.choose(code) }
                        }
                    }
                } label: { Image(systemName: "keyboard") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Keys you can't type: arrows, Space, Return, F-keys…")
            }

            Text(model.combo?.display ?? "No shortcut")
                .font(.title2.monospaced())
                .frame(maxWidth: .infinity)
                .foregroundStyle(model.combo == nil ? .secondary : .primary)

            if let problem = model.problem {
                note(problem, "exclamationmark.triangle")
            } else if !model.movesFrom.isEmpty {
                note("Moves from \(model.movesFrom.joined(separator: ", ")), which will have no shortcut.", "arrow.right.circle")
            } else if let system = model.systemUse {
                note("macOS uses this for \(system). It may not reach SnagAnything.", "exclamationmark.triangle")
            }
            if model.showHint {
                note("Nothing came through. If you pressed a shortcut, another app is using those keys. Press different keys, or set them with the buttons above.", "info.circle")
            }
            Text("Or press the shortcut now.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button("Clear") { model.finish?(.set(nil)) }
                    .disabled(model.original == nil)
                Spacer()
                Button("Cancel") { model.finish?(.cancel) }
                Button("Set") { model.finish?(.set(model.combo)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.combo == nil || model.problem != nil)
            }
        }
        .padding(Space.lg)
        .frame(width: 380)
    }

    private func toggle(_ symbol: String, _ name: String, _ on: Binding<Bool>) -> some View {
        Toggle(isOn: on) {
            Text(symbol).font(.title3).frame(minWidth: 22)
        }
        .toggleStyle(.button)
        .controlSize(.large)
        .help(name)
        .accessibilityLabel(name)
    }

    private func note(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Key names and lookups for the editor.
enum KeyNames {
    static let specialKeys = [kVK_Space, kVK_Return, kVK_Tab, kVK_Escape, kVK_Delete, kVK_ForwardDelete,
                              kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                              kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown]
    static let functionKeys: [Int] = HotKey.fKeys.sorted { $0.value < $1.value }.map(\.key)

    static func name(_ code: Int) -> String {
        switch code {
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default: return HotKey.name(keyCode: code, characters: HotKey.layoutCharacter(code))
        }
    }

    static func spoken(_ code: Int) -> String {
        switch code {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return ↩"
        case kVK_Tab: return "Tab ⇥"
        case kVK_Escape: return "Escape ⎋"
        case kVK_Delete: return "Delete ⌫"
        case kVK_ForwardDelete: return "Forward Delete ⌦"
        case kVK_LeftArrow: return "Left Arrow ←"
        case kVK_RightArrow: return "Right Arrow →"
        case kVK_UpArrow: return "Up Arrow ↑"
        case kVK_DownArrow: return "Down Arrow ↓"
        case kVK_Home: return "Home ↖"
        case kVK_End: return "End ↘"
        case kVK_PageUp: return "Page Up ⇞"
        case kVK_PageDown: return "Page Down ⇟"
        default: return name(code)
        }
    }

    /// The key that types this character in the current layout, and whether it needs ⇧.
    static func keyCode(for text: String) -> (Int, Bool)? {
        let wanted = text.lowercased()
        if wanted == " " { return (kVK_Space, false) }
        let typing = (0...127).filter { !HotKey.isFunctionKey($0) && !specialKeys.contains($0) && !keypad.contains($0) }
        if let code = typing.first(where: { HotKey.layoutCharacter($0)?.lowercased() == wanted }) { return (code, false) }
        if let code = typing.first(where: { HotKey.layoutCharacter($0, shift: true) == text }) { return (code, true) }
        return nil
    }

    /// Prefer the main keys over the keypad's copies of the digits.
    private static let keypad: Set<Int> = [kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3,
        kVK_ANSI_Keypad4, kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9,
        kVK_ANSI_KeypadDecimal, kVK_ANSI_KeypadMultiply, kVK_ANSI_KeypadPlus, kVK_ANSI_KeypadClear,
        kVK_ANSI_KeypadDivide, kVK_ANSI_KeypadEnter, kVK_ANSI_KeypadMinus, kVK_ANSI_KeypadEquals]

    struct Combo: Hashable { let code: Int; let mods: Int }

    /// Common macOS shortcuts, for a warning (not a block).
    static let systemShortcuts: [Combo: String] = {
        let c = controlKey, o = optionKey, s = shiftKey, m = cmdKey
        let list: [(Int, Int, String)] = [
            (kVK_ANSI_3, m | s, "screenshots"), (kVK_ANSI_4, m | s, "screenshots"),
            (kVK_ANSI_5, m | s, "screenshots"), (kVK_ANSI_6, m | s, "Touch Bar screenshots"),
            (kVK_ANSI_3, m | s | c, "screenshots"), (kVK_ANSI_4, m | s | c, "screenshots"),
            (kVK_Space, m, "Spotlight"), (kVK_Space, m | o, "Finder search"), (kVK_Space, c, "input sources"),
            (kVK_Tab, m, "switching apps"), (kVK_ANSI_Q, m, "Quit"), (kVK_ANSI_W, m, "Close"),
            (kVK_ANSI_H, m, "Hide"), (kVK_ANSI_M, m, "Minimize"), (kVK_Escape, m | o, "Force Quit"),
            (kVK_ANSI_Q, m | c, "Lock Screen"), (kVK_ANSI_F, m | c, "full screen"), (kVK_ANSI_D, m | o, "showing the Dock"),
            (kVK_UpArrow, c, "Mission Control"), (kVK_DownArrow, c, "App Exposé"),
            (kVK_LeftArrow, c, "switching Spaces"), (kVK_RightArrow, c, "switching Spaces"),
            (kVK_ANSI_C, m, "Copy"), (kVK_ANSI_V, m, "Paste"), (kVK_ANSI_X, m, "Cut"), (kVK_ANSI_Z, m, "Undo"),
            (kVK_ANSI_A, m, "Select All"), (kVK_ANSI_S, m, "Save"), (kVK_ANSI_N, m, "New"), (kVK_ANSI_O, m, "Open"),
            (kVK_ANSI_P, m, "Print"), (kVK_ANSI_Comma, m, "Settings"),
        ]
        return Dictionary(list.map { (Combo(code: $0.0, mods: $0.1), $0.2) }, uniquingKeysWith: { a, _ in a })
    }()
}
