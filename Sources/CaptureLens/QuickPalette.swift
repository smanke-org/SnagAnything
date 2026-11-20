import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// The quick palette: a small row of capture tools that opens beside the pointer with its
/// shortcut. Holding ⌥ swaps the tools for their video versions while it's open. Choose a tool
/// by clicking it (or its number, or the arrows and Return); Esc or a click elsewhere closes it.
/// With "hold and release" chosen, hold the shortcut, point at a tool and let go.
@MainActor
final class QuickPalette: NSObject, NSWindowDelegate {
    static let shared = QuickPalette()

    enum Tool: Int, CaseIterable, Identifiable {
        case captureArea, captureWindow, captureText, captureScreen
        case recordArea, recordWindow, recordScreen
        case library

        var id: Int { rawValue }

        static let photo: [Tool] = [.captureArea, .captureWindow, .captureText, .captureScreen, .library]
        static let video: [Tool] = [.recordArea, .recordWindow, .recordScreen, .library]

        var title: String {
            switch self {
            case .captureArea: "Capture Area"
            case .captureWindow: "Capture Window"
            case .captureText: "Capture Text"
            case .captureScreen: "Capture Full Screen"
            case .recordArea: "Record Area"
            case .recordWindow: "Record Window"
            case .recordScreen: "Record Screen"
            case .library: "Open Library"
            }
        }

        /// The capture bar's symbols.
        var symbol: String {
            switch self {
            case .captureArea, .recordArea: CaptureMode.region.symbol
            case .captureWindow, .recordWindow: CaptureMode.window.symbol
            case .captureScreen, .recordScreen: CaptureMode.screen.symbol
            case .captureText: "text.viewfinder"
            case .library: "photo.on.rectangle"
            }
        }

        var isVideo: Bool { self == .recordArea || self == .recordWindow || self == .recordScreen }
    }

    @Observable @MainActor
    final class Model {
        var video = false
        /// The tool under the pointer or picked with the arrow keys.
        var highlighted: Tool?
        var tools: [Tool] { video ? Tool.video : Tool.photo }
    }

    let model = Model()
    private var panel: QuickPalettePanel?
    private var modifierTimer: Timer?
    private var clickMonitor: Any?
    private var openedAt = Date.distantPast
    private var holding = false

    var isShown: Bool { panel?.isVisible == true }

    /// The shortcut: opens the palette at the pointer, or closes it if it's open.
    func toggle() {
        if isShown { close() } else { show() }
    }

    /// ⌥ belongs to the ⌃⌥⌘-right-click that opened it, so it means video only once it has
    /// been let go and pressed again.
    private var optionIsTrigger = false

    func show(at point: NSPoint = NSEvent.mouseLocation, fromMouse: Bool = false) {
        guard !CaptureEngine.shared.isBusy, !CaptureOverlay.shared.isSelecting else { return }
        optionIsTrigger = fromMouse
        model.video = !fromMouse && NSEvent.modifierFlags.contains(.option)
        model.highlighted = nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        place(panel, near: point)
        panel.alphaValue = 1
        // A non-activating panel takes the keys without bringing SnagAnything forward.
        panel.makeKeyAndOrderFront(nil)
        openedAt = Date()
        // From the mouse, holding the button and letting go over a tool always works.
        holding = fromMouse || Preferences.shared.paletteChoosing == .holdAndRelease
        watchModifiers()
        watchClicksOutside()
    }

    func close() {
        modifierTimer?.invalidate()
        modifierTimer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        holding = false
        panel?.orderOut(nil)
    }

    /// The right button came up: over a tool chooses it; otherwise the palette stays up for a click.
    func triggerReleased() {
        guard isShown, holding else { return }
        holding = false
        if let tool = tool(at: NSEvent.mouseLocation) ?? model.highlighted { choose(tool) }
    }

    /// The tool under a screen point, from the layout (4 pt padding, 28 pt buttons 2 pt apart):
    /// while a button is held, hover events can't be trusted.
    func tool(at point: NSPoint) -> Tool? {
        guard let frame = panel?.frame, frame.contains(point) else { return nil }
        let x = point.x - frame.minX - Space.xs
        let index = Int(x / (28 + Space.xxs))
        guard x >= 0, index < model.tools.count, x - CGFloat(index) * (28 + Space.xxs) <= 28 else { return nil }
        return model.tools[index]
    }

    /// Hold and release: letting go over a tool chooses it; a quick press leaves the palette up.
    func hotKeyReleased() {
        guard isShown, holding else { return }
        holding = false
        if let tool = tool(at: NSEvent.mouseLocation) ?? model.highlighted { return choose(tool) }
        if Date().timeIntervalSince(openedAt) > 0.4 { close() }
    }

    func choose(_ tool: Tool) {
        close()
        // Let the panel leave the screen before the overlay freezes it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Self.run(tool) }
    }

    private static func run(_ tool: Tool) {
        let engine = CaptureEngine.shared
        switch tool {
        case .captureArea: engine.run(stillPreset(.region))
        case .captureWindow: engine.run(stillPreset(.window))
        case .captureScreen: engine.run(stillPreset(.screen))
        case .captureText: engine.captureText()
        case .library: LibraryWindow.shared.show()
        case .recordArea: record(.region)
        case .recordWindow: record(.window)
        case .recordScreen: record(.screen)
        }
    }

    /// The person's own preset for that mode with no countdown, so its clipboard and
    /// after-capture choices hold; otherwise a plain one.
    private static func stillPreset(_ mode: CaptureMode) -> CapturePreset {
        Preferences.shared.presets.first { $0.mode == mode && $0.delay == 0 } ?? CapturePreset(name: mode.title, mode: mode)
    }

    private static func record(_ target: CaptureMode) {
        let recorder = ScreenRecorder.shared
        // One under way already: the palette's video tools stop it, like the record shortcut.
        guard recorder.phase == .idle else {
            if recorder.phase == .recording || recorder.phase == .paused { recorder.stop() }
            return
        }
        let preset = Preferences.shared.presets.first { $0.mode == .recording }
            ?? CapturePreset(name: CaptureMode.recording.title, mode: .recording)
        Task { await recorder.begin(preset, target: target) }
    }

    // MARK: - Keys

    /// Number keys, arrows, Return and Esc while the palette has the keys.
    fileprivate func handle(_ event: NSEvent) -> Bool {
        let tools = model.tools
        switch Int(event.keyCode) {
        case kVK_Escape: close(); return true
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
            if let tool = model.highlighted { choose(tool) }
            return true
        case kVK_LeftArrow, kVK_RightArrow:
            let step = Int(event.keyCode) == kVK_LeftArrow ? -1 : 1
            let index = model.highlighted.flatMap { tools.firstIndex(of: $0) } ?? (step > 0 ? -1 : tools.count)
            model.highlighted = tools[(index + step + tools.count) % tools.count]
            return true
        default:
            if let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...tools.count).contains(digit) {
                choose(tools[digit - 1])
                return true
            }
            return false
        }
    }

    // MARK: - Watching ⌥ and outside clicks

    /// ⌥ is read on a timer: SnagAnything isn't the active app, so flagsChanged events
    /// don't reach it, and a global monitor would need Accessibility.
    private func watchModifiers() {
        modifierTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated {
                let palette = QuickPalette.shared
                let option = NSEvent.modifierFlags.contains(.option)
                if palette.optionIsTrigger {
                    if !option { palette.optionIsTrigger = false }
                    return
                }
                let video = option
                guard video != palette.model.video else { return }
                withAnimation(Motion.quick) {
                    palette.model.video = video
                    if let tool = palette.model.highlighted, !palette.model.tools.contains(tool) { palette.model.highlighted = nil }
                }
                palette.resize()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        modifierTimer = timer
    }

    private func watchClicksOutside() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
            MainActor.assumeIsolated { QuickPalette.shared.close() }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Another window took the keys (a click in one of SnagAnything's own windows).
        if isShown, !holding { close() }
    }

    // MARK: - Panel

    private func makePanel() -> QuickPalettePanel {
        let panel = QuickPalettePanel()
        panel.delegate = self
        let host = NSHostingView(rootView: QuickPaletteView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        return panel
    }

    /// Just below and to the right of the pointer, flipped to stay on the pointer's screen.
    private func place(_ panel: NSPanel, near point: NSPoint) {
        guard let host = panel.contentView else { return }
        let size = host.fittingSize
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(origin: .zero, size: size)
        let gap: CGFloat = 14
        var origin = NSPoint(x: point.x + gap, y: point.y - gap - size.height)
        if origin.x + size.width > visible.maxX { origin.x = point.x - gap - size.width }
        if origin.y < visible.minY { origin.y = point.y + gap }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    /// Four tools or five: keep the edge nearest the pointer where it was.
    private func resize() {
        guard let panel, let host = panel.contentView else { return }
        DispatchQueue.main.async {
            let size = host.fittingSize
            var frame = panel.frame
            if frame.midX < NSEvent.mouseLocation.x { frame.origin.x = frame.maxX - size.width }
            frame.size = size
            panel.setFrame(frame, display: true)
        }
    }

    #if DEBUG
    var debugFrame: CGRect? { isShown ? panel?.frame : nil }
    #endif
}

final class QuickPalettePanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if !MainActor.assumeIsolated({ QuickPalette.shared.handle(event) }) { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { QuickPalette.shared.close() }
    }
}

struct QuickPaletteView: View {
    @Bindable var model: QuickPalette.Model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: Space.xxs) {
            ForEach(Array(model.tools.enumerated()), id: \.element) { index, tool in
                PaletteToolButton(tool: tool, number: index + 1, highlighted: model.highlighted == tool) {
                    QuickPalette.shared.choose(tool)
                } hover: { inside in
                    if inside { model.highlighted = tool } else if model.highlighted == tool { model.highlighted = nil }
                }
            }
        }
        .padding(Space.xs)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.card))
        .id(colorScheme)
        .fixedSize()
    }
}

private struct PaletteToolButton: View {
    let tool: QuickPalette.Tool
    let number: Int
    let highlighted: Bool
    let action: () -> Void
    let hover: (Bool) -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 28, height: 28)
                .overlay(alignment: .bottomTrailing) {
                    if tool.isVideo {
                        Circle().fill(.red).frame(width: 7, height: 7).offset(x: -2, y: -2)
                    }
                }
                .background(highlighted ? Color.primary.opacity(0.14) : .clear, in: .rect(cornerRadius: Radius.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(tool.title)  (\(number))")
        .accessibilityLabel(tool.title)
        .onHover(perform: hover)
    }
}

// MARK: - ⌃⌥⌘-right-click

/// Opens the quick palette on ⌃⌥⌘-right-click. With Accessibility allowed, an event tap keeps
/// the click from the app under the pointer (no context menu there); without it, a plain
/// monitor still opens the palette, and the app sees the click too. Holding the button and
/// letting go over a tool chooses it, as holding the shortcut does.
@MainActor
final class PaletteMouseTrigger {
    static let shared = PaletteMouseTrigger()

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var monitor: Any?
    private var trustTimer: Timer?
    /// The button went down with the modifiers, so its release belongs to the palette.
    fileprivate var pressed = false

    static let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]

    var usesTap: Bool { tap != nil }

    /// Starts or stops watching to match the setting.
    func apply() {
        stop()
        guard Preferences.shared.paletteRightClick else { return }
        if AXIsProcessTrusted(), startTap() { return }
        startMonitor()
        // Switch to the tap once Accessibility is allowed, without a relaunch.
        let timer = Timer(timeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                if AXIsProcessTrusted() { PaletteMouseTrigger.shared.apply() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustTimer = timer
    }

    /// Asks for Accessibility (the system's own prompt, which opens System Settings).
    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func stop() {
        trustTimer?.invalidate()
        trustTimer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        tapSource = nil
    }

    private func startTap() -> Bool {
        let mask = (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: paletteTapCallback, userInfo: nil)
        else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
        return true
    }

    private func startMonitor() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown, .rightMouseUp]) { event in
            MainActor.assumeIsolated {
                let trigger = PaletteMouseTrigger.shared
                if event.type == .rightMouseDown {
                    let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
                    guard flags == [.command, .option, .control] else { return }
                    trigger.pressed = true
                    trigger.opened()
                } else if trigger.pressed {
                    trigger.pressed = false
                    QuickPalette.shared.triggerReleased()
                }
            }
        }
    }

    fileprivate func opened() {
        // Right after the click: ⌥ is still held as part of the trigger, so the photo tools
        // show first; let go of ⌥ and press it again for video.
        QuickPalette.shared.show(fromMouse: true)
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    static func matches(_ flags: CGEventFlags) -> Bool {
        flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]) == modifiers
    }
}

private func paletteTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                                _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    MainActor.assumeIsolated {
        let trigger = PaletteMouseTrigger.shared
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            trigger.reenable()
            return Unmanaged.passUnretained(event)
        case .rightMouseDown:
            guard PaletteMouseTrigger.matches(event.flags) else { return Unmanaged.passUnretained(event) }
            trigger.pressed = true
            trigger.opened()
            return nil
        case .rightMouseDragged:
            return trigger.pressed ? nil : Unmanaged.passUnretained(event)
        case .rightMouseUp:
            guard trigger.pressed else { return Unmanaged.passUnretained(event) }
            trigger.pressed = false
            QuickPalette.shared.triggerReleased()
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

/// Accessibility lets ⌃⌥⌘-right-click open only the palette, not the app's own menu too.
struct PaletteAccessibilityRow: View {
    @State private var trusted = AXIsProcessTrusted()
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if trusted {
                Label("Accessibility is allowed, so the app under the pointer doesn't get the click.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Label("Allow Accessibility so the app under the pointer doesn't show its own menu too.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Allow…") { PaletteMouseTrigger.shared.requestAccess() }
                }
            }
        }
        .font(.callout)
        .onReceive(timer) { _ in trusted = AXIsProcessTrusted() }
    }
}
