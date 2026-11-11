#if DEBUG
import AppKit
@preconcurrency import AVFoundation
import CaptureLensKit
import QuartzCore
import SwiftUI

/// The demo video, played on the built-in display for `CAPTURELENS_DEBUG_DEMO=<trace file>`
/// (with `CAPTURELENS_DEFAULTS_SUITE` and `CAPTURELENS_LIBRARY_FOLDER`, so nothing real is
/// touched, and `CAPTURELENS_DEBUG_DEMO_VO=<folder>` holding the voiceover's timings, NN.json).
///
/// Everything on screen is one of SnagAnything's own windows: a desk (wallpaper, made-up app
/// windows, Desktop files), the real library, Settings and panels, then a pointer, keys,
/// subtitles and title cards on top. A recorder that captures only this app's windows films
/// it (Tools/demo), so nothing else on the screen gets in. The real pointer is left alone.
///
/// Each scene starts its voiceover line `lead` seconds in and waits for it to end; the trace
/// gets `scene <n> <host seconds>` so the mix can place each line. Actions wait for words
/// in the line with `at(_:)`.
@MainActor
enum DemoStage {
    static let state = DemoState()
    private static var screen: NSScreen!
    /// The filmed area, in screen coordinates.
    static var crop = CGRect.zero
    private static var windows: [NSWindow] = []
    private static var tracePath = "/dev/null"
    private static var traceLines: [String] = []
    static let lead = 0.45

    private static let deskLevel = NSWindow.Level.normal
    private static let overlayLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)

    // MARK: - Voiceover timings

    struct Word { var text: String; var start: Double; var end: Double }
    struct Line {
        var text: String
        var starts: [Double]
        var words: [Word]
        var duration: Double { words.last?.end ?? 0 }
    }
    private static var lines: [Int: Line] = [:]
    private static var line: Line?
    private static var sceneStart = 0.0
    private static var subtitles: [(start: Double, end: Double, text: String)] = []

    private static func loadVoiceover(_ folder: String) {
        for n in 1...30 {
            let url = URL(fileURLWithPath: folder).appending(path: String(format: "%02d.json", n))
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let chars = json["characters"] as? [String],
                  let starts = json["character_start_times_seconds"] as? [Double],
                  let ends = json["character_end_times_seconds"] as? [Double] else { continue }
            var words: [Word] = []
            var current = "", start = 0.0, end = 0.0
            for (i, c) in chars.enumerated() {
                if c == " " || c == "\n" {
                    if !current.isEmpty { words.append(Word(text: current, start: start, end: end)) }
                    current = ""
                } else {
                    if current.isEmpty { start = starts[i] }
                    current += c
                    end = ends[i]
                }
            }
            if !current.isEmpty { words.append(Word(text: current, start: start, end: end)) }
            lines[n] = Line(text: chars.joined(), starts: starts, words: words)
        }
        trace("voiceover lines \(lines.keys.sorted())")
    }

    /// The line cut into subtitle-sized pieces, broken after punctuation where it can be.
    private static func chunks(_ line: Line) -> [(start: Double, end: Double, text: String)] {
        var out: [(Double, Double, String)] = []
        var words: [Word] = []
        func flush() {
            guard let first = words.first, let last = words.last else { return }
            out.append((first.start, last.end, words.map(\.text).joined(separator: " ")))
            words = []
        }
        for word in line.words {
            words.append(word)
            let length = words.map(\.text.count).reduce(0, +) + words.count
            let ends = word.text.last.map { ".?!…:".contains($0) } ?? false
            let pause = word.text.last.map { ",;".contains($0) } ?? false
            if ends && length > 14 || pause && length > 34 || length > 52 { flush() }
        }
        flush()
        // Each piece stays up until the next one starts.
        return out.enumerated().map { i, piece in
            (piece.0, i + 1 < out.count ? out[i + 1].0 : piece.1 + 0.5, piece.2)
        }
    }

    // MARK: - Running

    static func run(trace path: String) {
        tracePath = path
        let env = ProcessInfo.processInfo.environment
        guard env["CAPTURELENS_DEFAULTS_SUITE"] != nil, env["CAPTURELENS_LIBRARY_FOLDER"] != nil else { exit(2) }
        guard let built = NSScreen.screens.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) else {
            trace("no built-in display"); exit(3)
        }
        screen = built
        if let folder = env["CAPTURELENS_DEBUG_DEMO_VO"] { loadVoiceover(folder) }
        let frame = built.frame, visible = built.visibleFrame
        let width = frame.width, height = (width * 9 / 16).rounded()
        // At the bottom of the visible area, so the corner preview lands inside it.
        let bottom = min(max(visible.minY, frame.minY), frame.maxY - 40 - height)
        crop = CGRect(x: frame.minX, y: bottom, width: width, height: height)
        trace("crop \(crop) screen \(frame) visible \(visible) scale \(built.backingScaleFactor)")
        // The recorder wants this in the display's own top-left coordinates.
        let topLeft = CGRect(x: 0, y: frame.maxY - crop.maxY, width: crop.width, height: crop.height)
        try? "\(Int(topLeft.minX)) \(Int(topLeft.minY)) \(Int(topLeft.width)) \(Int(topLeft.height))"
            .write(toFile: path + ".crop", atomically: true, encoding: .utf8)

        NSApp.setActivationPolicy(.regular)
        // No keychain key for a throwaway library.
        AppDefaults.store.set(false, forKey: "library.encrypt")
        AppDefaults.store.set("dark", forKey: AppAppearance.key)
        AppDefaults.store.set("left", forKey: "editor.palettePlacement")
        AppDefaults.store.set(true, forKey: "library.sidebar.appsOpen")
        let prefs = Preferences.shared
        prefs.toolStyle = .toolbar
        prefs.dialLayout = .slices
        prefs.autoName = false
        prefs.copyToClipboard = false
        prefs.showCaptureBar = false

        Task {
            await DemoLibrary.fill()
            trace("library \(LibraryStore.shared.items.count) items")
            // The words in the pictures, for searching.
            for _ in 0..<80 where LibraryStore.shared.items.contains(where: { $0.kind != .video && $0.recognizedText.isEmpty }) {
                try? await Task.sleep(for: .milliseconds(250))
            }
            makeWindows()
            // Opened once off screen, so its first appearance in the film is settled.
            LibraryWindow.shared.show(select: DemoLibrary.ids.chart)
            placeLibrary()
            LibraryWindow.shared.window?.orderOut(nil)
            try? await Task.sleep(for: .seconds(1.5))
            // Played from a timer, not a main-queue block, so pumping the run loop lets the
            // app's own async work run (see ToolHUD's DemoStage).
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in
                MainActor.assumeIsolated {
                    trace("stage ready")
                    pump(Double(env["CAPTURELENS_DEBUG_DEMO_LEAD"] ?? "") ?? 3)
                    trace("action \(CACurrentMediaTime())")
                    play()
                    trace("cut \(CACurrentMediaTime())")
                    pump(0.6)
                    exit(0)
                }
            }
        }
    }

    static func trace(_ line: String) {
        traceLines.append(line)
        try? traceLines.joined(separator: "\n").appending("\n").write(toFile: tracePath, atomically: true, encoding: .utf8)
    }

    // MARK: - Windows

    @discardableResult
    private static func panel(level: NSWindow.Level, view: some View) -> NSWindow {
        let window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = level
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        // Fixed to the screen: left to size itself, an empty view shrinks the window to nothing.
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }

    private static func makeWindows() {
        let cropInView = viewRect(crop)
        panel(level: deskLevel, view: DemoDesk(state: state, crop: cropInView)).orderBack(nil)
        _ = panel(level: overlayLevel, view: DemoOverlay(state: state, crop: cropInView))
    }

    /// Screen point → the desk's and overlay's own top-left coordinates.
    static func viewPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - screen.frame.minX, y: screen.frame.maxY - p.y)
    }

    static func viewRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX - screen.frame.minX, y: screen.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// A point in the film (top-left origin, crop-relative) → screen.
    static func filmPoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: crop.minX + x, y: crop.maxY - y)
    }

    private static func filmRect(_ r: CGRect) -> CGRect {
        CGRect(x: crop.minX + r.minX, y: crop.maxY - r.maxY, width: r.width, height: r.height)
    }

    static let libraryFrame = CGRect(x: 84, y: 26, width: 1560, height: 852)

    private static func placeLibrary() {
        guard let window = LibraryWindow.shared.window else { return }
        window.setFrameAutosaveName("")
        window.animationBehavior = .none
        let target = filmRect(libraryFrame)
        if window.frame != target {
            window.orderOut(nil)
            window.setFrame(target, display: true)
        }
    }

    private static func showLibrary(select id: UUID? = nil) {
        LibraryWindow.shared.show(select: id)
        placeLibrary()
        LibraryWindow.shared.window?.orderFrontRegardless()
        LibraryWindow.shared.window?.makeKey()
        NSApp.activate()
    }

    private static func hideLibrary() {
        LibraryWindow.shared.window?.orderOut(nil)
    }

    // MARK: - Time

    /// Runs the app for `seconds`, keeping the subtitles in step.
    static func pump(_ seconds: Double) {
        let end = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
            tickSubtitles()
        }
    }

    private static func pump(until time: Double) {
        pump(max(0, time - CACurrentMediaTime()))
    }

    /// Seconds since this scene's voiceover began.
    private static var now: Double { CACurrentMediaTime() - sceneStart - lead }

    private static func tickSubtitles() {
        guard line != nil else { return }
        let t = now
        let text = subtitles.first { t >= $0.start && t < $0.end }?.text
        if state.subtitle != text { state.subtitle = text }
    }

    /// Waits until `phrase` is spoken in this scene's line (plus `offset` seconds).
    private static func at(_ phrase: String, _ offset: Double = 0) {
        guard let line else { return }
        let lower = line.text.lowercased()
        guard let range = lower.range(of: phrase.lowercased()) else { trace("phrase not found: \(phrase)"); return }
        let index = lower.distance(from: lower.startIndex, to: range.lowerBound)
        guard index < line.starts.count else { return }
        pump(until: sceneStart + lead + line.starts[index] + offset)
    }

    /// One scene: its voiceover line starts `lead` seconds in, and it ends `tail` seconds
    /// after the line does (or later, if the actions take longer).
    private static func scene(_ n: Int, tail: Double = 0.7, _ body: () -> Void) {
        sceneStart = CACurrentMediaTime()
        line = lines[n]
        subtitles = line.map(chunks) ?? []
        trace("scene \(n) \(sceneStart + lead) \(line?.duration ?? 0)")
        body()
        pump(until: sceneStart + lead + (line?.duration ?? 0) + tail)
        state.subtitle = nil
        line = nil
    }

    // MARK: - The pointer

    private static func glide(to target: CGPoint, _ duration: Double = 0.7, bend: Double = 0.1) {
        let start = state.pointerScreen
        let dx = target.x - start.x, dy = target.y - start.y
        let begin = CACurrentMediaTime()
        while true {
            let t = min(1, (CACurrentMediaTime() - begin) / duration)
            let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            let arc = sin(.pi * e) * bend
            setPointer(CGPoint(x: start.x + dx * e - dy * arc, y: start.y + dy * e + dx * arc))
            if t >= 1 { break }
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
            tickSubtitles()
        }
    }

    /// Glides to a point in the film's own coordinates.
    private static func glide(_ x: CGFloat, _ y: CGFloat, _ duration: Double = 0.7) {
        glide(to: filmPoint(x, y), duration)
    }

    private static func setPointer(_ p: CGPoint) {
        state.pointerScreen = p
        state.pointer = viewPoint(p)
    }

    private static func click() {
        state.clicks += 1
        pump(0.12)
    }

    private static func keys(_ keys: [String], hold: Double? = nil) {
        state.keys = keys
        if let hold {
            pump(hold)
            state.keys = []
        }
    }

    // MARK: - The picture in the library

    private static func layer() -> AnnotationLayerView? {
        DebugShots.find(LibraryWindow.shared.window?.contentView)
    }

    /// A point in the shown capture (its points, top-left origin) → screen.
    private static func imagePoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        guard let layer = layer(), let window = layer.window else { return filmPoint(860, 450) }
        return window.convertPoint(toScreen: layer.convert(CGPoint(x: x, y: y), to: nil))
    }

    private static func imageRect(_ r: CGRect) -> CGRect {
        let a = imagePoint(r.minX, r.minY), b = imagePoint(r.maxX, r.maxY)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private static func fit() {
        CanvasZoom.shared.fitRequested += 1
        pump(0.15)
    }

    private static func add(_ mark: Annotation, action: String = "Add") {
        let editor = AnnotationEditor.shared
        editor.commit(editor.annotations + [mark], action: action)
    }

    private static func setMarks(_ id: UUID, _ marks: [Annotation]) {
        guard var item = LibraryStore.shared.entry(id) else { return }
        item.annotations = marks
        LibraryStore.shared.update(item)
    }

    private static func setEdits(_ id: UUID, _ edits: ImageEdits) {
        guard var item = LibraryStore.shared.entry(id) else { return }
        item.edits = edits
        LibraryStore.shared.update(item)
    }

    // MARK: - The film

    private static func play() {
        let ids = DemoLibrary.ids
        let store = LibraryStore.shared
        let editor = AnnotationEditor.shared
        let library = LibraryWindow.shared
        let prefs = Preferences.shared
        setPointer(filmPoint(1100, 600))

        // 1. A cluttered Desktop, swept into the app.
        scene(1, tail: 0.5) {
            state.desk = .files
            at("Meet")
            state.filesGathered = true
            pump(0.5)
            state.card = DemoCard(title: "SnagAnything", subtitle: "Every capture, in one library.", footnote: "for macOS")
        }

        // 2. Capturing.
        scene(2) {
            state.card = nil
            state.desk = .capture
            pump(0.3)
            state.showPointer = true
            glide(900, 520, 0.6)
            at("one shortcut")
            keys(["⌥", "⇧", "⌘", "4"])
            at("Click a window", -0.2)
            glide(320, 380, 0.6)
            state.highlight = DemoDesk.mailFrame
            at("or drag", -0.3)
            state.highlight = nil
            keys([])
            let from = CGPoint(x: 846, y: 214), to = CGPoint(x: 1530, y: 360)
            glide(from.x, from.y, 0.45)
            state.dragging = true
            let begin = CACurrentMediaTime()
            while CACurrentMediaTime() - begin < 1.1 {
                let t = min(1, (CACurrentMediaTime() - begin) / 1.0)
                let e = 1 - pow(1 - t, 3)
                let p = CGPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e)
                setPointer(filmPoint(p.x, p.y))
                state.selection = CGRect(x: from.x, y: from.y, width: p.x - from.x, height: p.y - from.y)
                pump(1.0 / 60)
            }
            state.dragging = false
            pump(0.3)
            state.selection = nil
            at("whole screen", -0.1)
            state.highlight = CGRect(x: 0, y: 0, width: crop.width, height: crop.height)
            at("an exact size", -0.1)
            state.highlight = nil
            state.selection = CGRect(x: 760, y: 150, width: 800, height: 450)
            state.selectionLabel = "800 × 450"
            at("countdown", -0.2)
            state.selection = nil
            state.selectionLabel = nil
            for n in [3, 2, 1] {
                state.countdown = n
                pump(0.38)
            }
            state.countdown = nil
            state.flash += 1
            at("A preview")
            if let item = store.entry(ids.captured) { CapturePreview.shared.show(item, near: crop, copied: false) }
            at("Click it", 0.1)
            let preview = NSApp.windows.first { $0.isVisible && $0 is NSPanel && $0.frame.width < 400 && $0.frame.minY < crop.minY + 200 }
            let previewCenter = preview.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? filmPoint(1560, 880)
            glide(to: previewCenter, 0.7)
            at("or drag", -0.2)
            CapturePreview.shared.hide()
            state.ghost = true
            state.ghostAt = viewPoint(previewCenter)
            let target = filmPoint(330, 470)
            let start = previewCenter
            let begin2 = CACurrentMediaTime()
            while CACurrentMediaTime() - begin2 < 1.3 {
                let t = min(1, (CACurrentMediaTime() - begin2) / 1.2)
                let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                let p = CGPoint(x: start.x + (target.x - start.x) * e, y: start.y + (target.y - start.y) * e - sin(.pi * e) * 60)
                setPointer(p)
                state.ghostAt = viewPoint(p)
                pump(1.0 / 60)
            }
            state.ghost = false
            state.mailImage = true
        }

        // 3. The library, named automatically, and search.
        scene(3) {
            state.desk = .wallpaper
            state.mailImage = false
            state.showPointer = false
            showLibrary(select: ids.chart)
            library.state.showInfo = true
            fit()
            at("names it", -0.3)
            for id in DemoLibrary.renames.keys {
                if let name = DemoLibrary.renames[id] { store.rename(id, to: name) }
                pump(0.22)
            }
            at("Search by name", -0.2)
            @MainActor func type(_ text: String) {
                library.state.filter.text = ""
                for ch in text {
                    library.state.filter.text.append(ch)
                    pump(0.09)
                }
            }
            type("revenue")
            at("by date", -0.1)
            library.state.filter.text = ""
            library.state.filter.dateRange = .yesterday
            at("by tag", -0.1)
            library.state.filter.dateRange = .any
            type("tag:travel")
            at("any word", 0.2)
            type("buttered")
            pump(1.4)
            library.state.filter.text = ""
        }

        // 4. Markup.
        scene(4) {
            library.state.filter = LibraryFilter()
            library.state.showInfo = false
            library.state.foldedSide = .captures
            setMarks(ids.chart, [])
            library.show(select: ids.chart)
            pump(0.4)
            fit()
            editor.open(ids.chart)
            state.showPointer = true
            setPointer(imagePoint(560, 40))
            let red = AnnotationStyle(color: .red, lineWidth: 4)
            at("Boxes", -0.2)
            editor.pick(.draw(.rectangle))
            glide(to: imagePoint(36, 96), 0.35)
            add(Annotation(kind: .rectangle, rect: CGRect(x: 36, y: 96, width: 196, height: 104), style: red))
            glide(to: imagePoint(232, 200), 0.3)
            at("arrows", -0.1)
            editor.pick(.draw(.arrow))
            glide(to: imagePoint(268, 372), 0.35)
            add(Annotation(kind: .arrow, from: CGPoint(x: 330, y: 440), to: CGPoint(x: 268, y: 372), style: AnnotationStyle(color: .orange, lineWidth: 5)))
            at("callouts", -0.1)
            editor.pick(.draw(.callout))
            glide(to: imagePoint(560, 250), 0.35)
            let callout = Annotation(kind: .callout, rect: CGRect(x: 500, y: 236, width: 210, height: 64), tail: CGPoint(x: 600, y: 330),
                                     text: "Up 12% after the September launch", style: AnnotationStyle(color: .purple, lineWidth: 3, fontSize: 16))
            add(callout)
            at("numbered steps", -0.1)
            editor.pick(.draw(.step))
            glide(to: imagePoint(34, 96), 0.35)
            add(Annotation(kind: .step, rect: CGRect(x: 18, y: 80, width: 32, height: 32), style: AnnotationStyle(color: .blue, lineWidth: 4, fontSize: 20)))
            glide(to: imagePoint(270, 96), 0.3)
            add(Annotation(kind: .step, rect: CGRect(x: 254, y: 80, width: 32, height: 32), style: AnnotationStyle(color: .blue, lineWidth: 4, fontSize: 20)))
            at("highlighter", -0.1)
            editor.pick(.draw(.highlighter))
            let stroke = stride(from: 54.0, through: 190.0, by: 6).map { CGPoint(x: $0, y: 243 + sin($0 / 14) * 1.5) }
            glide(to: imagePoint(54, 243), 0.3)
            for i in stride(from: 2, through: stroke.count, by: 2) {
                setPointer(imagePoint(stroke[i - 1].x, stroke[i - 1].y))
                if i == 2 {
                    add(Annotation(kind: .highlighter, points: Array(stroke.prefix(i)), style: AnnotationStyle(color: .yellow, lineWidth: 16)))
                } else if let last = editor.annotations.last {
                    editor.change(last.id, action: "Draw") { $0.points = Array(stroke.prefix(i)) }
                }
                pump(0.025)
            }
            at("spotlight", -0.1)
            editor.pick(.draw(.spotlight))
            glide(to: imagePoint(640, 290), 0.3)
            let spotlight = Annotation(kind: .spotlight, rect: CGRect(x: 600, y: 262, width: 90, height: 192), style: AnnotationStyle(color: .black, lineWidth: 0))
            add(spotlight)
            at("magnifier", -0.1)
            editor.commit(editor.annotations.filter { $0.id != spotlight.id }, action: "Remove")
            editor.pick(.draw(.magnify))
            glide(to: imagePoint(560, 150), 0.3)
            add(Annotation(kind: .magnify, rect: CGRect(x: 520, y: 110, width: 120, height: 120), zoom: 1.8, style: AnnotationStyle(color: .white, lineWidth: 3)))
            at("stays editable", -0.2)
            editor.pick(.select)
            glide(to: imagePoint(600, 268), 0.4)
            editor.select(callout.id)
            pump(0.3)
            for step in 1...24 {
                editor.change(callout.id, action: "Move") { $0.rect.origin.y = 236 - CGFloat(step) * 4; $0.rect.origin.x = 500 - CGFloat(step) * 2 }
                setPointer(imagePoint(600 - CGFloat(step) * 2, 268 - CGFloat(step) * 4))
                pump(0.02)
            }
            at("change it", 0)
            editor.change(callout.id, action: "Color") { $0.style.color = .green }
            pump(0.4)
            editor.change(callout.id, action: "Color") { $0.style.color = .blue }
            at("slim strip", -0.2)
            editor.select(nil)
            let strip = LibraryWindow.shared.window.map { CGPoint(x: $0.frame.minX + 48, y: $0.frame.midY + 120) } ?? filmPoint(140, 400)
            glide(to: strip, 0.5)
            for dy in [0.0, -44, -88, -132] {
                glide(to: CGPoint(x: strip.x, y: strip.y + dy), 0.18)
                pump(0.12)
            }
            at("as a dial", -0.2)
            prefs.toolStyle = .dial
            let center = imagePoint(420, 300)
            glide(to: center, 0.4)
            pump(0.2)
            if let scroll = DebugShots.findScroll(LibraryWindow.shared.window?.contentView) {
                scroll.openDial(at: scroll.convert(scroll.window!.convertPoint(fromScreen: center), from: nil), held: false)
                pump(0.6)
                for angle in stride(from: -90.0, through: 200, by: 58) {
                    let r = angle * .pi / 180
                    glide(to: CGPoint(x: center.x + cos(r) * 110, y: center.y - sin(r) * 110), 0.22)
                    pump(0.12)
                }
                pump(0.6)
                scroll.closeDial()
            }
            prefs.toolStyle = .toolbar
        }

        // 5. Adjusting, and Smart Redact.
        scene(5) {
            state.showPointer = false
            setEdits(ids.account, .none)
            setMarks(ids.account, [])
            library.show(select: ids.account)
            editor.open(ids.account)
            pump(0.4)
            fit()
            at("Crop", -0.1)
            editor.editEdits("Crop") { $0.crop = CGRect(x: 0, y: 0, width: 800, height: 470) }
            fit()
            at("rotate", -0.05)
            editor.editEdits("Rotate") { $0.rotation = 1 }
            fit()
            pump(0.45)
            editor.editEdits("Rotate") { $0.rotation = 0 }
            fit()
            at("shadow", -0.1)
            editor.editEdits("Border") { $0.border = Border(width: 0, color: .black, cornerRadius: 14, shadow: true) }
            at("torn edge", -0.1)
            editor.editEdits("Edges") { $0.edges = EdgeEffect(kind: .torn, sides: [.bottom]) }
            at("remove the background", -0.6)
            library.show(select: ids.product)
            editor.open(ids.product)
            pump(0.3)
            fit()
            pump(0.5)
            editor.editEdits("Remove Background") { $0.removeBackground = true }
            at("Smart Redact", -0.3)
            library.show(select: ids.account)
            editor.open(ids.account)
            pump(0.3)
            fit()
            at("finds", 0)
            editor.smartRedact(with: .blur)
        }

        // 6. Changing what's in the picture.
        scene(6) {
            library.show(select: ids.typo)
            editor.open(ids.typo)
            pump(0.3)
            fit()
            editor.analyze()
            state.showPointer = true
            setPointer(imagePoint(560, 60))
            at("Fix a typo", -0.1)
            editor.pick(.draw(.editText))
            glide(to: imagePoint(150, 46), 0.4)
            if let analysis = waitForAnalysis(), let typo = analysis.lines.first(where: { $0.text.contains("Acount") }),
               let mark = editor.editTextMark(text: "Account Settings", box: typo.box) {
                add(mark, action: "Edit Text")
            } else { trace("edit text: no line found") }
            at("Pick up a button", -0.1)
            editor.pick(.draw(.move))
            let button = CGRect(x: 40, y: 400, width: 160, height: 40)
            glide(to: imagePoint(button.midX, button.midY), 0.4)
            var moved = Annotation(kind: .move, rect: button, source: button, style: AnnotationStyle(color: .black, lineWidth: 0, shadow: false))
            add(moved, action: "Smart Move")
            for step in 1...30 {
                let t = Double(step) / 30
                let e = 1 - pow(1 - t, 3)
                moved.rect.origin = CGPoint(x: 40 + 520 * e, y: 400 - 10 * sin(.pi * t))
                editor.change(moved.id, action: "Move") { $0.rect = moved.rect }
                setPointer(imagePoint(moved.rect.midX, moved.rect.midY))
                pump(0.025)
            }
            editor.pick(.select)
            at("simplify", -0.1)
            state.showPointer = false
            editor.simplify(.original)
            for _ in 0..<40 where editor.simplifying { pump(0.1) }
        }

        // 7. Text.
        scene(7) {
            library.show(select: ids.recipe)
            editor.open(ids.recipe)
            pump(0.3)
            fit()
            state.showPointer = true
            setPointer(imagePoint(300, 40))
            at("Select text", -0.1)
            let rows: [CGRect] = (0..<4).map { CGRect(x: 38, y: 84 + CGFloat($0) * 30, width: [140, 170, 120, 150][$0], height: 24) }
            glide(to: imagePoint(38, 90), 0.35)
            for (i, row) in rows.enumerated() {
                state.textSelection.append(viewRect(imageRect(row)))
                setPointer(imagePoint(row.maxX, row.midY))
                pump(i == rows.count - 1 ? 0.3 : 0.22)
            }
            at("Or press", -0.2)
            state.textSelection = []
            hideLibrary()
            state.desk = .poster
            keys(["⌥", "⇧", "⌘", "T"])
            glide(560, 300, 0.4)
            at("drag over", -0.1)
            keys([])
            let from = CGPoint(x: 330, y: 300), to = CGPoint(x: 900, y: 470)
            glide(from.x, from.y, 0.35)
            let begin = CACurrentMediaTime()
            while CACurrentMediaTime() - begin < 1.0 {
                let t = min(1, (CACurrentMediaTime() - begin) / 0.9)
                let e = 1 - pow(1 - t, 3)
                let p = CGPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e)
                setPointer(filmPoint(p.x, p.y))
                state.selection = CGRect(x: from.x, y: from.y, width: p.x - from.x, height: p.y - from.y)
                pump(1.0 / 60)
            }
            state.selection = nil
            let saved = NSPasteboard.general.string(forType: .string)
            var done = false
            if let image = DemoMock.posterText() {
                Task {
                    await CaptureEngine.shared.deliverText(from: image, frame: filmRect(CGRect(x: from.x, y: from.y, width: to.x - from.x, height: to.y - from.y)),
                                                           display: nil, windows: [])
                    done = true
                }
            }
            for _ in 0..<30 where !done { pump(0.1) }
            if let saved { Clipboard.copy(text: saved) } else { NSPasteboard.general.clearContents() }
            at("ready to paste", -0.1)
            glide(1180, 640, 0.5)
            click()
            keys(["⌘", "V"])
            state.notesPasted = true
            pump(0.8)
            keys([])
        }

        // 8. Scrolling captures, how-tos and guides.
        scene(8) {
            state.desk = .longPage
            state.showPointer = true
            glide(860, 420, 0.4)
            at("Scroll", -0.1)
            state.scrollFrame = DemoDesk.pageFrame
            let begin = CACurrentMediaTime()
            while CACurrentMediaTime() - begin < 2.2 {
                let t = min(1, (CACurrentMediaTime() - begin) / 2.1)
                state.pageScroll = 1100 * (t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2)
                pump(1.0 / 60)
            }
            at("one tall picture", -0.3)
            state.scrollFrame = nil
            state.showPointer = false
            showLibrary(select: ids.tall)
            library.state.foldedSide = .captures
            fit()
            at("Showing someone", -0.2)
            hideLibrary()
            state.pageScroll = 0
            state.desk = .settingsApp
            state.showPointer = true
            at("every click", -0.3)
            for (i, p) in DemoDesk.howToClicks.enumerated() {
                glide(p.x, p.y, 0.4)
                click()
                state.stepBadges.append(p)
                _ = i
                pump(0.25)
            }
            at("polished guide", -0.4)
            state.showPointer = false
            state.stepBadges = []
            library.state.foldedSide = nil
            showLibrary(select: ids.steps.first)
            library.state.guide = GuideRequest(items: ids.steps, title: "How To · Turn On Dark Mode", template: .steps)
        }

        // 9. The pointer, separate.
        scene(9) {
            library.state.guide = nil
            if let sheet = library.window?.attachedSheet { library.window?.endSheet(sheet) }
            library.state.foldedSide = .captures
            library.show(select: ids.pointer)
            editor.open(ids.pointer)
            pump(0.3)
            fit()
            @MainActor func cursor(_ body: (inout CursorLayer) -> Void) {
                guard var item = store.entry(ids.pointer), var c = item.cursor else { return }
                body(&c)
                item.cursor = c
                store.update(item)
            }
            at("move it", -0.1)
            for step in 1...20 {
                cursor { $0.x = 300 + Double(step) * 12; $0.y = 300 - Double(step) * 6 }
                pump(0.03)
            }
            at("resize it", -0.1)
            for step in 1...12 {
                cursor { $0.size = 1 + Double(step) * 0.1 }
                pump(0.03)
            }
            at("disappear", 0)
            cursor { $0.visible = false }
        }

        // 10. Recording video.
        scene(10) {
            hideLibrary()
            library.state.foldedSide = nil
            state.desk = .slides
            pump(0.2)
            let area = filmRect(DemoDesk.slidesFrame.insetBy(dx: -8, dy: -8))
            var bar: NSWindow?
            at("record", -0.3)
            bar = ScreenRecorder.shared.debugShowBar(over: area)
            bar?.level = .popUpMenu
            state.showPointer = true
            if let bar {
                let rows = 5.0
                for i in 0..<Int(rows) {
                    glide(to: CGPoint(x: bar.frame.maxX - 40, y: bar.frame.maxY - 70 - Double(i) * (bar.frame.height - 110) / rows), 0.3)
                    pump(0.35)
                }
            }
            at("rings where", -0.4)
            bar?.orderOut(nil)
            var reset = false
            Task { await ScreenRecorder.shared.debugReset(); reset = true }
            state.recordFrame = DemoDesk.slidesFrame.insetBy(dx: -8, dy: -8)
            state.recording = true
            state.cameraBubble = true
            glide(700, 520, 0.4)
            click()
            glide(1000, 380, 0.4)
            click()
            at("the keys", 0)
            keys(["⌘", "B"], hold: 0.8)
            at("Pause", -0.1)
            state.paused = true
            at("trim", -0.4)
            for _ in 0..<10 where !reset { pump(0.1) }
            state.paused = false
            state.recording = false
            state.cameraBubble = false
            state.recordFrame = nil
            state.showPointer = false
            state.desk = .wallpaper
            if var item = store.entry(ids.video) { item.video?.edits = VideoEdits(); store.update(item) }
            showLibrary(select: ids.video)
            pump(0.4)
            at("the ends", -0.1)
            for step in 1...12 {
                if var item = store.entry(ids.video) {
                    item.video?.edits.trimStart = Double(step) * 0.06
                    item.video?.edits.trimEnd = 8 - Double(step) * 0.05
                    store.update(item)
                }
                pump(0.04)
            }
            at("cut out", 0)
            if var item = store.entry(ids.video) {
                item.video?.edits.cuts = [TimeCut(start: 3.2, end: 4.4)]
                store.update(item)
            }
            at("animated GIF", -0.2)
            Notice.shared.show("Saved as an animated GIF", symbol: "photo.stack")
        }

        // 11. Organizing.
        scene(11) {
            library.state.showInfo = true
            library.state.foldedSide = nil
            library.show(select: ids.chart)
            pump(0.3)
            at("tags", -0.1)
            store.setTags([ids.chart], add: ["q3"])
            at("favorites", -0.1)
            store.toggleFavorite([ids.chart])
            at("notes", -0.1)
            if var item = store.entry(ids.chart) { item.notes = "For the Monday review: the September jump."; store.update(item) }
            at("by date", -0.1)
            library.state.filter.dateRange = .lastWeek
            at("app", -0.05)
            library.state.filter.dateRange = .any
            if let safari = store.facets.apps.first(where: { $0.name == "Safari" })?.key { library.state.section = .app(safari) }
            at("website", -0.05)
            library.state.section = .site("analytics.example.com")
            at("your way", -0.2)
            library.state.section = .all
            library.state.showFullWidth()
            pump(1.0)
            library.state.leaveFullWidth()
            at("remembers", -0.1)
            library.show(select: ids.chart)
        }

        // 12. Bringing captures in.
        scene(12) {
            var shown = false
            Task {
                if let folder = await DebugShots.sampleSnagitFolder() {
                    SnagitImporter.shared.debugUse([folder.0, folder.1], videoFolder: FileManager.default.temporaryDirectory.appending(path: "SnagAnything Shot Videos"))
                    SnagitImporter.shared.nameCaptures = true
                    SnagitImportWindow.shared.show()
                }
                shown = true
            }
            for _ in 0..<20 where !shown { pump(0.1) }
            pump(0.3)
            if let window = SnagitImporter.shared.debugWindow {
                window.setFrameOrigin(CGPoint(x: crop.midX - window.frame.width / 2, y: crop.midY - window.frame.height / 2 + 30))
                window.orderFrontRegardless()
            }
            at("other tools", -0.3)
            SnagitImporter.shared.debugWindow?.orderOut(nil)
            if let item = DemoLibrary.addCollected() { library.show(select: item) }
        }

        // 13. Activity.
        scene(13) {
            hideLibrary()
            SettingsWindow.shared.show(tab: "Activity")
            placeSettings()
        }

        // 14. Privacy and sync.
        scene(14) {
            SettingsWindow.shared.show(tab: "Privacy")
            placeSettings()
            at("syncs", -0.2)
            SettingsWindow.shared.show(tab: "Library")
            placeSettings()
        }

        // 15. The end.
        scene(15, tail: 2.2) {
            SettingsWindow.shared.debugWindow?.orderOut(nil)
            state.desk = .wallpaper
            state.card = DemoCard(title: "SnagAnything", subtitle: "Capture anything… and actually find it again.", footnote: "stevemanke.com")
        }
    }

    private static func waitForAnalysis() -> AnnotationEditor.SmartAnalysis? {
        let editor = AnnotationEditor.shared
        for _ in 0..<60 where editor.analysis == nil { pump(0.05) }
        return editor.analysis
    }

    /// Settings sizes itself to each pane; this centers it and keeps it inside the film.
    private static func placeSettings() {
        guard let window = SettingsWindow.shared.debugWindow else { return }
        window.setFrameAutosaveName("")
        window.animationBehavior = .none
        for _ in 0..<3 {
            pump(0.35)
            let size = CGSize(width: max(window.frame.width, 760), height: min(window.frame.height, crop.height - 90))
            let target = CGRect(x: (crop.midX - size.width / 2).rounded(), y: (crop.midY - size.height / 2 + 30).rounded(),
                                width: size.width, height: size.height)
            if window.frame != target { window.setFrame(target, display: true, animate: false) }
        }
        window.orderFrontRegardless()
        window.makeKey()
        trace("settings frame \(window.frame)")
    }
}

// MARK: - The made-up library

@MainActor
enum DemoLibrary {
    struct IDs {
        var chart = UUID(), captured = UUID(), account = UUID(), product = UUID(), typo = UUID(), recipe = UUID()
        var tall = UUID(), steps: [UUID] = [], pointer = UUID(), video = UUID()
    }
    static var ids = IDs()
    /// Captures that start with a date for a name and get their real one on screen.
    static var renames: [UUID: String] = [:]

    private static func add(_ image: CGImage?, name: String, app: String, bundle: String, title: String, url: String? = nil,
                            tags: [String] = [], favorite: Bool = false, notes: String = "", daysAgo: Double,
                            marks: [Annotation] = [], cursor: CursorLayer? = nil, kind: CaptureItem.Kind? = nil,
                            tool: String? = nil, startDated: Bool = false) -> UUID? {
        let store = LibraryStore.shared
        let created = Date().addingTimeInterval(-daysAgo * 86_400)
        guard let image, var item = store.add(image: image, kind: kind ?? (url == nil ? .window : .region), scale: 2,
                                              source: .init(appName: app, bundleID: bundle, windowTitle: title, url: url,
                                                            pageTitle: url == nil ? nil : title, tool: tool),
                                              cursor: cursor, created: created, analyze: false) else { return nil }
        item.name = startDated ? "Screenshot \(created.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))) at \(created.formatted(.dateTime.hour().minute().second()))" : name
        item.nameIsAutomatic = false
        item.tags = tags
        item.favorite = favorite
        item.notes = notes
        item.annotations = marks
        store.update(item)
        store.analyze(item.id, rename: false)
        if startDated { renames[item.id] = name }
        return item.id
    }

    static func fill() async {
        let store = LibraryStore.shared
        _ = add(Mock.palette(), name: "Brand Color Palette", app: "Preview", bundle: "com.apple.Preview", title: "Palette.png",
                tags: ["design"], daysAgo: 9, startDated: true)
        _ = add(Mock.flight(), name: "Flight to Lisbon Itinerary", app: "Mail", bundle: "com.apple.mail", title: "Your trip to Lisbon",
                tags: ["travel"], notes: "Seat 14A. Check in opens 24 hours before.", daysAgo: 6, startDated: true)
        _ = add(Mock.calendar(), name: "Team Calendar Week 44", app: "Calendar", bundle: "com.apple.iCal", title: "Calendar",
                tags: ["work"], daysAgo: 4.2, startDated: true)
        ids.recipe = add(Mock.recipe(), name: "Lemon Ricotta Pancakes Recipe", app: "Notes", bundle: "com.apple.Notes", title: "Recipes",
                         tags: ["recipes"], favorite: true, daysAgo: 3, startDated: true) ?? UUID()
        _ = add(Mock.codeError(), name: "Xcode Build Error", app: "Xcode", bundle: "com.apple.dt.Xcode", title: "Shop — OrderView.swift",
                tags: ["bugs", "work"], notes: "Happens after the cart refactor.", daysAgo: 1.2, startDated: true)
        ids.typo = add(DemoMock.settingsWithTypo(), name: "Account Settings Draft", app: "Safari", bundle: "com.apple.Safari", title: "Account Settings",
                       url: "https://app.example.com/settings/account", tags: ["design"], daysAgo: 2.4) ?? UUID()
        ids.account = add(DemoMock.checkout(), name: "Checkout Details", app: "Safari", bundle: "com.apple.Safari", title: "Checkout",
                          url: "https://shop.example.com/checkout", tags: ["work"], daysAgo: 2.2) ?? UUID()
        ids.product = add(DemoMock.product(), name: "Ceramic Mug Product Shot", app: "Photos", bundle: "com.apple.Photos", title: "Product shots",
                          tags: ["design"], daysAgo: 2.1) ?? UUID()
        ids.pointer = add(Mock.calendar(), name: "Design Review Invite", app: "Calendar", bundle: "com.apple.iCal", title: "Calendar",
                          tags: ["work"], daysAgo: 1.6, cursor: DemoMock.cursorLayer(x: 300, y: 300)) ?? UUID()
        ids.tall = add(DemoMock.longPage(), name: "Trail Guide Full Page", app: "Safari", bundle: "com.apple.Safari", title: "Trail Guide",
                       url: "https://trails.example.com/guide", tags: ["travel"], daysAgo: 1.4) ?? UUID()
        var steps: [UUID] = []
        for (i, name) in ["Click Appearance", "Choose Dark", "Click Save"].enumerated() {
            if let id = add(DemoMock.settingsApp(step: i), name: name, app: "Acme Notes", bundle: "com.example.notes", title: "Preferences",
                            tags: ["how-to"], daysAgo: 1.3 - Double(i) * 0.01,
                            marks: [Annotation(kind: .step, rect: DemoMock.stepRect(i), style: AnnotationStyle(color: .red, lineWidth: 4, fontSize: 20))]) {
                steps.append(id)
            }
        }
        ids.steps = steps
        ids.chart = add(Mock.dashboard(), name: "Quarterly Revenue Chart", app: "Safari", bundle: "com.apple.Safari", title: "Sales Dashboard",
                        url: "https://analytics.example.com/q3", tags: ["work", "reports"],
                        notes: "For the Monday review.", daysAgo: 0.2, startDated: true) ?? UUID()
        // A recording, 8 seconds.
        let movie = FileManager.default.temporaryDirectory.appending(path: "SnagAnything Demo \(UUID().uuidString).mp4")
        if await DebugMovie.write(to: movie, seconds: 8, startFrame: 0, size: CGSize(width: 1520, height: 960), background: DemoMock.slides()) {
            let asset = AVURLAsset(url: movie)
            let duration = (try? await asset.load(.duration).seconds) ?? 8
            if let poster = await VideoStore.frame(of: asset, at: 0.5),
               var item = store.addVideo(movie: movie, poster: poster, scale: 2, info: VideoInfo(duration: duration),
                                         source: .init(appName: "Keynote", bundleID: "com.apple.iWork.Keynote", windowTitle: "Product Tour")) {
                item.name = "Product Tour Walkthrough"
                item.nameIsAutomatic = false
                item.tags = ["demo", "work"]
                store.update(item)
                ids.video = item.id
            }
        }
        // The one captured on screen in scene 2 (hidden from the library until then would be
        // nicer, but the preview needs a real capture).
        ids.captured = add(DemoMock.kpis(), name: "Sales KPI Cards", app: "Safari", bundle: "com.apple.Safari", title: "Sales Dashboard",
                           url: "https://analytics.example.com/q3", tags: ["work"], daysAgo: 0.05) ?? UUID()
        seedActivity()
    }

    /// A macOS screenshot, collected as it's taken.
    static func addCollected() -> UUID? {
        add(DemoMock.boardingPass(), name: "Boarding Pass Lisbon", app: "Wallet", bundle: "com.apple.Passbook", title: "Boarding Pass",
            tags: ["travel"], daysAgo: 0, kind: .screen, tool: "Screenshot")
    }

    /// Four weeks of made-up activity on this Mac.
    private static func seedActivity() {
        var rng = SystemRandomNumberGenerator()
        let calendar = Calendar.current
        for day in 0..<45 {
            guard let date = calendar.date(byAdding: .day, value: -day, to: Date()) else { continue }
            let weekday = calendar.component(.weekday, from: date)
            let busy = weekday == 1 || weekday == 7 ? 0.35 : 1.0
            func record(_ key: String, _ base: Int) {
                let n = Int((Double(Int.random(in: base / 2...base + base / 2, using: &rng)) * busy).rounded())
                if n > 0 { ActivityStore.shared.debugRecord(key, count: n, at: date) }
            }
            record(ActivityKey.area, 9)
            record(ActivityKey.window, 5)
            record(ActivityKey.screen, 2)
            record(ActivityKey.scrolling, 1)
            record(ActivityKey.video, 1)
            record(ActivityKey.text, 3)
            record(ActivityKey.recordingSeconds, 90)
            record(ActivityKey.marks, 14)
            record(ActivityKey.copies, 6)
            record(ActivityKey.shares, 3)
        }
    }
}

// MARK: - Made-up pictures

@MainActor
enum DemoMock {
    static func settingsWithTypo() -> CGImage? {
        Mock.draw(CGSize(width: 800, height: 500)) { r in
            NSColor(white: 0.95, alpha: 1).setFill(); r.fill()
            Mock.text("Acount Settings", 26, .bold, at: CGPoint(x: 40, y: 30))
            Mock.text("Your plan renews on November 1", 15, .regular, .darkGray, at: CGPoint(x: 40, y: 90))
            NSColor.systemIndigo.setFill(); NSBezierPath(ovalIn: CGRect(x: 690, y: 30, width: 48, height: 48)).fill()
            Mock.text("Display name", 13, .medium, .gray, at: CGPoint(x: 40, y: 140))
            Mock.box(CGRect(x: 40, y: 162, width: 320, height: 34), .white, radius: 6)
            Mock.text("Alex Morgan", 15, .regular, at: CGPoint(x: 52, y: 170))
            Mock.text("Time zone", 13, .medium, .gray, at: CGPoint(x: 40, y: 216))
            Mock.box(CGRect(x: 40, y: 238, width: 320, height: 34), .white, radius: 6)
            Mock.text("Eastern Time (US)", 15, .regular, at: CGPoint(x: 52, y: 246))
            Mock.box(CGRect(x: 440, y: 140, width: 300, height: 132), .white, radius: 12)
            Mock.text("Pro plan", 18, .bold, at: CGPoint(x: 460, y: 156))
            Mock.text("5 seats · billed yearly", 13, .regular, .gray, at: CGPoint(x: 460, y: 186))
            Mock.box(CGRect(x: 460, y: 222, width: 120, height: 30), .systemGreen, radius: 15)
            Mock.text("Active", 14, .semibold, .white, at: CGPoint(x: 496, y: 228))
            Mock.box(CGRect(x: 40, y: 400, width: 160, height: 40), .systemBlue, radius: 8)
            Mock.text("Save Changes", 15, .semibold, .white, at: CGPoint(x: 70, y: 410))
            Mock.text("Cancel", 15, .regular, .systemBlue, at: CGPoint(x: 226, y: 410))
        }
    }

    static func checkout() -> CGImage? {
        Mock.draw(CGSize(width: 800, height: 500)) { r in
            NSColor(white: 0.96, alpha: 1).setFill(); r.fill()
            Mock.text("Checkout", 26, .bold, at: CGPoint(x: 40, y: 30))
            let rows: [(String, String)] = [("Email", "alex.morgan@example.com"), ("Phone", "(555) 014-2389"),
                                            ("Card", "4242 4242 4242 4242"), ("API key", "sk_live_51Hx9QeT2vB8mN4kP7rZ")]
            for (i, row) in rows.enumerated() {
                let y = 100 + CGFloat(i) * 78
                Mock.text(row.0, 13, .medium, .gray, at: CGPoint(x: 40, y: y))
                Mock.box(CGRect(x: 40, y: y + 22, width: 440, height: 38), .white, radius: 8)
                NSAttributedString(string: row.1, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular),
                                                               .foregroundColor: NSColor.black]).draw(at: CGPoint(x: 54, y: y + 31))
            }
            Mock.box(CGRect(x: 530, y: 100, width: 230, height: 300), .white, radius: 14)
            Mock.text("Order summary", 16, .bold, at: CGPoint(x: 550, y: 118))
            for (i, row) in [("Ceramic mug ×2", "$36.00"), ("Shipping", "$5.00"), ("Total", "$41.00")].enumerated() {
                Mock.text(row.0, 14, i == 2 ? .bold : .regular, at: CGPoint(x: 550, y: 160 + CGFloat(i) * 34))
                Mock.text(row.1, 14, i == 2 ? .bold : .regular, at: CGPoint(x: 690, y: 160 + CGFloat(i) * 34))
            }
            Mock.box(CGRect(x: 550, y: 330, width: 190, height: 44), .systemGreen, radius: 10)
            Mock.text("Place Order", 16, .semibold, .white, at: CGPoint(x: 600, y: 342))
        }
    }

    /// A mug on a plain backdrop, for Remove Background.
    static func product() -> CGImage? {
        Mock.draw(CGSize(width: 720, height: 480)) { r in
            NSGradient(starting: NSColor(calibratedRed: 0.93, green: 0.88, blue: 0.80, alpha: 1),
                       ending: NSColor(calibratedRed: 0.80, green: 0.74, blue: 0.66, alpha: 1))?.draw(in: r, angle: 90)
            NSColor.black.withAlphaComponent(0.18).setFill()
            NSBezierPath(ovalIn: CGRect(x: 240, y: 380, width: 260, height: 36)).fill()
            let body = NSBezierPath(roundedRect: CGRect(x: 250, y: 130, width: 200, height: 260), xRadius: 26, yRadius: 26)
            NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.62, alpha: 1),
                       ending: NSColor(calibratedRed: 0.20, green: 0.62, blue: 0.82, alpha: 1))?.draw(in: body, angle: 0)
            let handle = NSBezierPath(ovalIn: CGRect(x: 410, y: 180, width: 110, height: 150))
            handle.lineWidth = 26
            NSColor(calibratedRed: 0.14, green: 0.50, blue: 0.70, alpha: 1).setStroke()
            handle.stroke()
            NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.62, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: 250, y: 116, width: 200, height: 30)).fill()
            NSColor.white.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: CGRect(x: 272, y: 160, width: 18, height: 190), xRadius: 9, yRadius: 9).fill()
        }
    }

    static func kpis() -> CGImage? {
        guard let full = Mock.dashboard() else { return nil }
        return full.cropping(to: CGRect(x: 60, y: 180, width: 1380, height: 260))
    }

    /// What Capture Text "reads" in scene 7.
    static func posterText() -> CGImage? {
        Mock.draw(CGSize(width: 570, height: 170)) { r in
            NSColor.white.setFill(); r.fill()
            Mock.text("Farmers Market", 40, .heavy, at: CGPoint(x: 20, y: 18))
            Mock.text("Saturdays 8 AM – 1 PM", 26, .semibold, at: CGPoint(x: 22, y: 76))
            Mock.text("Main Street Square", 22, .regular, .darkGray, at: CGPoint(x: 22, y: 118))
        }
    }

    static func longPage() -> CGImage? {
        Mock.draw(CGSize(width: 720, height: 2200)) { r in
            NSColor.white.setFill(); r.fill()
            Mock.box(CGRect(x: 0, y: 0, width: 720, height: 300), NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.30, alpha: 1), radius: 0)
            Mock.text("Ridge Loop Trail Guide", 34, .heavy, .white, at: CGPoint(x: 40, y: 200))
            let sections = ["Getting there", "Trailhead and parking", "Mile 1: Into the pines", "Mile 3: The overlook",
                            "Mile 5: Creek crossing", "Mile 7: Back to the lot", "What to bring", "Seasons and weather"]
            for (i, title) in sections.enumerated() {
                let y = 340 + CGFloat(i) * 230
                Mock.text(title, 22, .bold, at: CGPoint(x: 40, y: y))
                for line in 0..<3 {
                    Mock.box(CGRect(x: 40, y: y + 44 + CGFloat(line) * 24, width: [620, 590, 420][line], height: 10), NSColor(white: 0.85, alpha: 1), radius: 5)
                }
                Mock.box(CGRect(x: 40, y: y + 124, width: 300, height: 80),
                         NSColor(hue: CGFloat(i) / 8, saturation: 0.35, brightness: 0.85, alpha: 1), radius: 10)
            }
        }
    }

    static let stepPoints = [CGPoint(x: 120, y: 132), CGPoint(x: 420, y: 196), CGPoint(x: 560, y: 420)]
    static func stepRect(_ i: Int) -> CGRect {
        CGRect(x: stepPoints[i].x + 14, y: stepPoints[i].y - 46, width: 32, height: 32)
    }

    /// A made-up app's Preferences, at each step of the how-to.
    static func settingsApp(step: Int) -> CGImage? {
        Mock.draw(CGSize(width: 700, height: 480)) { r in
            NSColor(white: step >= 1 ? 0.18 : 0.96, alpha: 1).setFill(); r.fill()
            let fg: NSColor = step >= 1 ? .white : .black
            Mock.box(CGRect(x: 0, y: 0, width: 220, height: 480), NSColor(white: step >= 1 ? 0.13 : 0.91, alpha: 1), radius: 0)
            for (i, title) in ["General", "Appearance", "Sync", "Shortcuts"].enumerated() {
                if i == 1 { Mock.box(CGRect(x: 12, y: 112 + CGFloat(i - 1) * 40, width: 196, height: 32), .systemBlue, radius: 7) }
                Mock.text(title, 15, .medium, i == 1 ? .white : fg, at: CGPoint(x: 28, y: 78 + CGFloat(i) * 40))
            }
            Mock.text("Appearance", 24, .bold, fg, at: CGPoint(x: 250, y: 40))
            for (i, mode) in ["Light", "Dark", "Auto"].enumerated() {
                let box = CGRect(x: 250 + CGFloat(i) * 140, y: 110, width: 120, height: 80)
                Mock.box(box, i == 1 ? NSColor(white: 0.1, alpha: 1) : i == 0 ? .white : NSColor(white: 0.6, alpha: 1), radius: 10)
                if step >= 1 && i == 1 {
                    NSColor.systemBlue.setStroke()
                    let ring = NSBezierPath(roundedRect: box.insetBy(dx: -3, dy: -3), xRadius: 12, yRadius: 12); ring.lineWidth = 3; ring.stroke()
                }
                Mock.text(mode, 14, .medium, fg, at: CGPoint(x: box.minX + 40, y: box.maxY + 10))
            }
            Mock.box(CGRect(x: 500, y: 400, width: 140, height: 40), .systemBlue, radius: 8)
            Mock.text("Save", 16, .semibold, .white, at: CGPoint(x: 550, y: 410))
        }
    }

    static func slides() -> CGImage? {
        Mock.draw(CGSize(width: 1520, height: 960)) { r in
            NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.30, alpha: 1),
                       ending: NSColor(calibratedRed: 0.30, green: 0.14, blue: 0.42, alpha: 1))?.draw(in: r, angle: 45)
            Mock.text("Product Tour", 96, .heavy, .white, at: CGPoint(x: 120, y: 300))
            Mock.text("Everything new this fall", 44, .medium, NSColor.white.withAlphaComponent(0.75), at: CGPoint(x: 124, y: 440))
        }
    }

    static func boardingPass() -> CGImage? {
        Mock.draw(CGSize(width: 520, height: 300)) { r in
            NSColor.white.setFill(); r.fill()
            Mock.box(CGRect(x: 0, y: 0, width: 520, height: 70), .systemIndigo, radius: 0)
            Mock.text("BOARDING PASS", 20, .heavy, .white, at: CGPoint(x: 24, y: 22))
            Mock.text("BOS → LIS", 40, .heavy, .systemIndigo, at: CGPoint(x: 24, y: 96))
            Mock.text("Gate B12 · Boards 7:05 PM · Seat 14A", 16, .medium, .darkGray, at: CGPoint(x: 24, y: 160))
        }
    }

    static func cursorLayer(x: Double, y: Double) -> CursorLayer? {
        let image = NSCursor.arrow.image
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return CursorLayer(png: png, width: image.size.width, height: image.size.height, x: x, y: y)
    }
}

// MARK: - State and views

enum DemoDeskScene: Equatable { case none, wallpaper, files, capture, poster, longPage, settingsApp, slides }

struct DemoCard: Equatable {
    var title: String
    var subtitle: String
    var footnote: String
}

@Observable
@MainActor
final class DemoState {
    var desk: DemoDeskScene = .wallpaper
    var filesGathered = false
    var pointer = CGPoint.zero
    @ObservationIgnored var pointerScreen = CGPoint.zero
    var showPointer = false
    var clicks = 0
    var keys: [String] = []
    var subtitle: String?
    var card: DemoCard?
    /// Film coordinates (top-left of the filmed area).
    var highlight: CGRect?
    var selection: CGRect?
    var selectionLabel: String?
    var dragging = false
    var countdown: Int?
    var flash = 0
    var ghost = false
    var ghostAt = CGPoint.zero
    var mailImage = false
    var notesPasted = false
    /// Overlay view coordinates.
    var textSelection: [CGRect] = []
    var scrollFrame: CGRect?
    var pageScroll: CGFloat = 0
    var stepBadges: [CGPoint] = []
    var recordFrame: CGRect?
    var recording = false
    var paused = false
    var cameraBubble = false
}

/// A made-up wallpaper.
struct DemoWallpaper: View {
    var body: some View {
        ZStack {
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.42, 0.55], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: [
                Color(red: 0.05, green: 0.10, blue: 0.22), Color(red: 0.08, green: 0.22, blue: 0.40), Color(red: 0.04, green: 0.30, blue: 0.40),
                Color(red: 0.12, green: 0.18, blue: 0.42), Color(red: 0.10, green: 0.40, blue: 0.55), Color(red: 0.06, green: 0.46, blue: 0.48),
                Color(red: 0.30, green: 0.16, blue: 0.40), Color(red: 0.14, green: 0.22, blue: 0.46), Color(red: 0.03, green: 0.18, blue: 0.26),
            ])
            Circle().fill(Color(red: 0.98, green: 0.50, blue: 0.30).opacity(0.30)).frame(width: 560).blur(radius: 130).offset(x: -460, y: 260)
            Circle().fill(Color(red: 0.30, green: 0.85, blue: 1.0).opacity(0.25)).frame(width: 660).blur(radius: 150).offset(x: 480, y: -230)
        }
        .ignoresSafeArea()
    }
}

/// A made-up app window: a title bar and a picture or view.
struct FakeWindow<Content: View>: View {
    let title: String
    let frame: CGRect
    var dark = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(dark ? .white.opacity(0.85) : .black.opacity(0.75))
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 12, height: 12)
                    Spacer()
                }
                .padding(.horizontal, 14)
            }
            .frame(height: 34)
            .background(dark ? Color(white: 0.2) : Color(white: 0.93))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .frame(width: frame.width, height: frame.height)
        .background(dark ? Color(white: 0.12) : .white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(dark ? 0.15 : 0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
        .position(x: frame.midX, y: frame.midY)
    }
}

@MainActor
struct DemoDesk: View {
    let state: DemoState
    let crop: CGRect

    static let mailFrame = CGRect(x: 110, y: 150, width: 560, height: 560)
    static let safariFrame = CGRect(x: 600, y: 80, width: 1000, height: 660)
    static let posterFrame = CGRect(x: 240, y: 120, width: 760, height: 560)
    static let notesFrame = CGRect(x: 1040, y: 380, width: 520, height: 360)
    static let pageFrame = CGRect(x: 420, y: 60, width: 880, height: 780)
    static let settingsFrame = CGRect(x: 500, y: 140, width: 700, height: 514)
    static let howToClicks = [CGPoint(x: 620, y: 300), CGPoint(x: 920, y: 364), CGPoint(x: 1060, y: 588)]
    static let slidesFrame = CGRect(x: 300, y: 110, width: 1120, height: 700)

    private func image(_ cg: CGImage?) -> Image {
        cg.map { Image(nsImage: NSImage(cgImage: $0, size: CGSize(width: $0.width / 2, height: $0.height / 2))) } ?? Image(systemName: "photo")
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if state.desk != .none {
                DemoWallpaper()
                ZStack(alignment: .topLeading) {
                    Color.clear
                    switch state.desk {
                    case .files: files
                    case .capture: capture
                    case .poster: poster
                    case .longPage: longPage
                    case .settingsApp:
                        FakeWindow(title: "Acme Notes Preferences", frame: Self.settingsFrame) {
                            image(DemoMock.settingsApp(step: 0)).resizable().aspectRatio(contentMode: .fill)
                        }
                    case .slides:
                        FakeWindow(title: "Product Tour", frame: Self.slidesFrame, dark: true) {
                            image(DemoMock.slides()).resizable().aspectRatio(contentMode: .fill)
                        }
                    case .none, .wallpaper: EmptyView()
                    }
                }
                .frame(width: crop.width, height: crop.height)
                .offset(x: crop.minX, y: crop.minY)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: state.desk)
        .ignoresSafeArea()
    }

    // The Desktop, littered with screenshots.
    private var files: some View {
        let names = (0..<18).map { i in "Screenshot 2026-11-\(String(format: "%02d", 1 + i % 10)) at \(9 + i % 8).\(String(format: "%02d", (i * 7) % 60)).\(String(format: "%02d", (i * 13) % 60))" }
        let center = CGPoint(x: crop.width / 2, y: crop.height / 2 - 40)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                let col = i % 6, row = i / 6
                let p = CGPoint(x: 210 + CGFloat(col) * 240 + CGFloat((i * 37) % 60) - 30, y: 190 + CGFloat(row) * 230 + CGFloat((i * 53) % 70) - 35)
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: [Color(hue: Double(i % 7) / 7, saturation: 0.25, brightness: 0.95), .white], startPoint: .top, endPoint: .bottom))
                        .frame(width: 96, height: 66)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                    Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).multilineTextAlignment(.center)
                        .frame(width: 150).lineLimit(2).shadow(color: .black.opacity(0.6), radius: 2)
                }
                .rotationEffect(.degrees(state.filesGathered ? Double(i * 40) : Double((i * 17) % 9) - 4))
                .scaleEffect(state.filesGathered ? 0.1 : 1)
                .opacity(state.filesGathered ? 0 : 1)
                .position(state.filesGathered ? center : p)
                .animation(.easeIn(duration: 0.7).delay(Double(i) * 0.025), value: state.filesGathered)
            }
        }
    }

    private var capture: some View {
        ZStack(alignment: .topLeading) {
            FakeWindow(title: "New Message", frame: Self.mailFrame) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(["To:  Jordan Lee", "Subject:  Q3 numbers"], id: \.self) { row in
                        Text(row).font(.system(size: 14)).foregroundStyle(.black.opacity(0.75)).padding(.horizontal, 18).padding(.vertical, 10)
                        Divider()
                    }
                    Text("Here are the latest numbers:").font(.system(size: 15)).foregroundStyle(.black).padding(18)
                    if state.mailImage {
                        image(DemoMock.kpis()).resizable().aspectRatio(contentMode: .fit).frame(width: 500)
                            .padding(.horizontal, 18).transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.spring(duration: 0.4), value: state.mailImage)
            }
            FakeWindow(title: "analytics.example.com", frame: Self.safariFrame) {
                image(Mock.dashboard()).resizable().aspectRatio(contentMode: .fill)
            }
        }
    }

    private var poster: some View {
        ZStack(alignment: .topLeading) {
            FakeWindow(title: "Market Poster.jpg", frame: Self.posterFrame, dark: true) {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.95, green: 0.62, blue: 0.30), Color(red: 0.85, green: 0.32, blue: 0.36)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Farmers Market").font(.system(size: 52, weight: .heavy))
                        Text("Saturdays 8 AM – 1 PM").font(.system(size: 30, weight: .semibold))
                        Text("Main Street Square").font(.system(size: 26))
                    }
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(-3))
                }
            }
            FakeWindow(title: "Notes", frame: Self.notesFrame) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Weekend").font(.system(size: 22, weight: .bold)).foregroundStyle(.black)
                    if state.notesPasted {
                        Text("Farmers Market\nSaturdays 8 AM – 1 PM\nMain Street Square").font(.system(size: 16)).foregroundStyle(.black)
                            .transition(.opacity)
                    }
                    Spacer()
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(red: 1, green: 0.99, blue: 0.93))
                .animation(.easeOut(duration: 0.25), value: state.notesPasted)
            }
        }
    }

    private var longPage: some View {
        FakeWindow(title: "trails.example.com", frame: Self.pageFrame) {
            image(DemoMock.longPage()).resizable()
                .frame(width: Self.pageFrame.width, height: Self.pageFrame.width * 2200 / 720)
                .offset(y: -state.pageScroll)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

struct DemoOverlay: View {
    let state: DemoState
    let crop: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ZStack(alignment: .topLeading) {
                Color.clear
                if let highlight = state.highlight {
                    RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.28))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 3))
                        .frame(width: highlight.width, height: highlight.height)
                        .offset(x: highlight.minX, y: highlight.minY)
                        .transition(.opacity)
                }
                if let selection = state.selection { selectionView(selection) }
                if let frame = state.scrollFrame {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                        .frame(width: frame.width + 12, height: frame.height + 12)
                        .offset(x: frame.minX - 6, y: frame.minY - 6)
                    pill("Scrolling capture… 2 pages", symbol: "arrow.down.to.line")
                        .position(x: frame.midX, y: frame.maxY + 34)
                }
                ForEach(Array(state.stepBadges.enumerated()), id: \.offset) { i, p in
                    Text("\(i + 1)").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 36, height: 36).background(Circle().fill(.red))
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .shadow(radius: 4)
                        .position(x: p.x + 30, y: p.y - 30)
                        .transition(.scale.combined(with: .opacity))
                }
                if let frame = state.recordFrame {
                    Rectangle().strokeBorder(.red, style: StrokeStyle(lineWidth: 3, dash: [9, 6]))
                        .frame(width: frame.width, height: frame.height).offset(x: frame.minX, y: frame.minY)
                    pill(state.paused ? "Paused · 0:07" : "Recording · 0:07", symbol: state.paused ? "pause.fill" : "record.circle", tint: state.paused ? .orange : .red)
                        .position(x: frame.midX, y: frame.minY - 26)
                    if state.cameraBubble {
                        ZStack {
                            Circle().fill(LinearGradient(colors: [Color(red: 0.45, green: 0.55, blue: 0.75), Color(red: 0.20, green: 0.25, blue: 0.40)], startPoint: .top, endPoint: .bottom))
                            Image(systemName: "person.fill").font(.system(size: 78)).foregroundStyle(.white.opacity(0.85)).offset(y: 14)
                        }
                        .frame(width: 150, height: 150).clipShape(Circle())
                        .overlay(Circle().strokeBorder(.white, lineWidth: 4)).shadow(radius: 10)
                        .position(x: frame.minX + 110, y: frame.maxY - 110)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                if let n = state.countdown {
                    Text("\(n)").font(.system(size: 160, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        .frame(width: 260, height: 260).background(Circle().fill(.black.opacity(0.55)))
                        .position(x: crop.width / 2, y: crop.height / 2).id(n).transition(.scale.combined(with: .opacity))
                }
                if state.ghost, let kpis = DemoMock.kpis() {
                    Image(nsImage: NSImage(cgImage: kpis, size: CGSize(width: 220, height: 41)))
                        .resizable().frame(width: 220, height: 41)
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                        .opacity(0.9)
                        .position(x: state.ghostAt.x - crop.minX + 60, y: state.ghostAt.y - crop.minY + 30)
                }
                FlashView(trigger: state.flash).frame(width: crop.width, height: crop.height).allowsHitTesting(false)
            }
            .frame(width: crop.width, height: crop.height, alignment: .topLeading)
            .offset(x: crop.minX, y: crop.minY)

            ForEach(Array(state.textSelection.enumerated()), id: \.offset) { _, r in
                RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.35))
                    .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
            }
            if let card = state.card {
                DemoCardView(card: card).frame(width: crop.width, height: crop.height)
                    .position(x: crop.midX, y: crop.midY).transition(.opacity)
            }
            if !state.keys.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(state.keys.enumerated()), id: \.offset) { _, key in
                        Text(key).font(.system(size: 30, weight: .semibold, design: .rounded))
                            .frame(minWidth: 56, minHeight: 56).padding(.horizontal, key.count > 1 ? 12 : 0)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.7)))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1))
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                .position(x: crop.maxX - 190, y: crop.minY + 70)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            if let subtitle = state.subtitle {
                Text(subtitle)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.68)))
                    .frame(maxWidth: crop.width - 200)
                    .position(x: crop.midX, y: crop.maxY - 52)
                    .id(subtitle)
                    .transition(.opacity)
            }
            if state.showPointer {
                DemoPointer(clicks: state.clicks, dragging: state.dragging || state.selection != nil)
                    .position(state.pointer)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: state.card)
        .animation(.easeInOut(duration: 0.18), value: state.subtitle)
        .animation(.easeInOut(duration: 0.2), value: state.keys)
        .animation(.easeInOut(duration: 0.25), value: state.showPointer)
        .animation(.easeInOut(duration: 0.25), value: state.highlight)
        .animation(.spring(duration: 0.3), value: state.countdown)
        .animation(.spring(duration: 0.3), value: state.stepBadges.count)
        .animation(.spring(duration: 0.35), value: state.cameraBubble)
        .ignoresSafeArea()
    }

    private func selectionView(_ r: CGRect) -> some View {
        let rect = r.standardized
        return ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(CGRect(origin: .zero, size: crop.size))
                p.addRect(rect)
            }
            .fill(.black.opacity(0.35), style: FillStyle(eoFill: true))
            Rectangle().strokeBorder(.white, lineWidth: 2)
                .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
            Text(state.selectionLabel ?? "\(Int(rect.width)) × \(Int(rect.height))")
                .font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(.black.opacity(0.7)))
                .offset(x: rect.maxX - 90, y: rect.maxY + 10)
        }
    }

    private func pill(_ text: String, symbol: String, tint: Color = .white) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
        }
        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(Capsule().fill(.black.opacity(0.72)))
    }
}

/// A white flash, as a capture is taken.
struct FlashView: View {
    let trigger: Int
    @State private var opacity = 0.0
    var body: some View {
        Rectangle().fill(.white).opacity(opacity)
            .onChange(of: trigger) {
                opacity = 0.55
                withAnimation(.easeOut(duration: 0.45)) { opacity = 0 }
            }
    }
}

struct DemoCardView: View {
    let card: DemoCard

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.3))
            VStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 176, height: 176)
                    .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
                Text(card.title).font(.system(size: 76, weight: .bold))
                Text(card.subtitle).font(.system(size: 30, weight: .medium)).foregroundStyle(.white.opacity(0.88))
                Text(card.footnote).font(.system(size: 21, weight: .medium)).foregroundStyle(.white.opacity(0.6)).padding(.top, 6)
            }
            .foregroundStyle(.white)
        }
    }
}

/// The arrow, with its tip at the view's position, and a ring on each click.
struct DemoPointer: View {
    let clicks: Int
    var dragging = false
    private static let arrow = NSCursor.arrow
    private static let cross = NSCursor.crosshair
    private static let zoom = 1.45

    var body: some View {
        let cursor = dragging ? Self.cross : Self.arrow
        let size = cursor.image.size
        ZStack {
            if clicks > 0 { ClickRing().id(clicks) }
            Image(nsImage: cursor.image)
                .resizable()
                .frame(width: size.width * Self.zoom, height: size.height * Self.zoom)
                .offset(x: (size.width / 2 - cursor.hotSpot.x) * Self.zoom, y: (size.height / 2 - cursor.hotSpot.y) * Self.zoom)
        }
        .frame(width: 90, height: 90)
    }
}

struct ClickRing: View {
    @State private var grown = false

    var body: some View {
        Circle()
            .strokeBorder(Color.yellow.opacity(0.95), lineWidth: 4)
            .frame(width: 46, height: 46)
            .scaleEffect(grown ? 1.5 : 0.3)
            .opacity(grown ? 0 : 1)
            .onAppear { withAnimation(.easeOut(duration: 0.5)) { grown = true } }
    }
}
#endif
