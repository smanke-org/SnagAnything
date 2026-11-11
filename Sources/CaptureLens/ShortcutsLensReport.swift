import Foundation

/// Tells ShortcutsLens this app's global shortcuts, so it lists them exactly (with their real
/// names) instead of guessing from the settings file.
///
/// ShortcutsLens asks with a distributed notification when it scans; the app answers with
/// every shortcut it registers, and posts again by itself whenever one changes. Nothing is
/// sent if nobody asked and nothing changed. A shortcut that's switched off or not set is
/// left out, or sent with `enabled: false`.
///
/// The same file is copied into every app that registers global shortcuts (the master copy
/// is in ShortcutsLens/Shared/). Call `start` once at launch, and `publish()` after a
/// shortcut changes.
///
/// Pass `change` to let ShortcutsLens give a shortcut new keys (its Change Shortcut button).
/// It gets the shortcut's `id`, a key code and Carbon modifiers; save them exactly as the
/// app's own Settings would (so Settings shows them), re-register, and return nil, or return
/// a short sentence saying why not. The report is sent again afterwards by itself.
@MainActor
enum ShortcutsLensReport {
    static let request = Notification.Name("com.smanke.ShortcutsLens.request")
    static let report = Notification.Name("com.smanke.ShortcutsLens.report")
    static let changeRequest = Notification.Name("com.smanke.ShortcutsLens.change")
    static let changed = Notification.Name("com.smanke.ShortcutsLens.changed")

    struct Shortcut: Equatable {
        /// Stable within the app ("captureText").
        var id: String
        /// As the app's settings name it ("Capture Text").
        var title: String
        /// The virtual key code (kVK_…); nil for a modifier-only trigger.
        var keyCode: Int?
        /// Carbon modifiers: cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000.
        var carbonModifiers: Int
        var enabled = true
        /// An optional heading ("Capture", "Windows").
        var category: String? = nil
        /// How the keys are used, when it isn't an ordinary press: "hold", "doubleTap" or
        /// "toggle". Two of the app's own shortcuts on the same keys with different gestures
        /// aren't counted as a conflict.
        var gesture: String? = nil

        var plist: [String: Any] {
            var d: [String: Any] = ["id": id, "title": title, "carbonModifiers": carbonModifiers, "enabled": enabled]
            if let keyCode { d["keyCode"] = keyCode }
            if let category { d["category"] = category }
            if let gesture { d["gesture"] = gesture }
            return d
        }
    }

    private static var provider: (@MainActor () -> [Shortcut])?
    private static var observer: NSObjectProtocol?
    private static var changeObserver: NSObjectProtocol?
    private static var changer: (@MainActor (_ id: String, _ keyCode: Int, _ carbonModifiers: Int) -> String?)?
    private static var last: [Shortcut]?

    /// Starts answering ShortcutsLens. `shortcuts` reports every global shortcut as it is now.
    static func start(_ shortcuts: @escaping @MainActor () -> [Shortcut],
                      change: (@MainActor (_ id: String, _ keyCode: Int, _ carbonModifiers: Int) -> String?)? = nil) {
        provider = shortcuts
        changer = change
        if change != nil, changeObserver == nil, let me = Bundle.main.bundleIdentifier {
            changeObserver = DistributedNotificationCenter.default().addObserver(forName: changeRequest, object: me, queue: .main) { note in
                let info = note.userInfo ?? [:]
                guard let id = info["id"] as? String, let keyCode = info["keyCode"] as? Int,
                      let modifiers = info["carbonModifiers"] as? Int, let requestID = info["requestID"] as? String else { return }
                MainActor.assumeIsolated { ShortcutsLensReport.handleChange(id: id, keyCode: keyCode, modifiers: modifiers, requestID: requestID) }
            }
        }
        if observer == nil {
            observer = DistributedNotificationCenter.default().addObserver(forName: request, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ShortcutsLensReport.publish(force: true) }
            }
        }
        publish(force: true)
    }

    private static func handleChange(id: String, keyCode: Int, modifiers: Int, requestID: String) {
        guard let changer, let me = Bundle.main.bundleIdentifier else { return }
        let problem = changer(id, keyCode, modifiers)
        publish(force: true)
        var answer: [String: Any] = ["requestID": requestID, "ok": problem == nil]
        if let problem { answer["message"] = problem }
        DistributedNotificationCenter.default().postNotificationName(changed, object: me, userInfo: answer, deliverImmediately: true)
    }

    /// Call whenever a shortcut changes. Repeats of the same list are skipped unless `force`.
    static func publish(force: Bool = false) {
        guard let provider, let id = Bundle.main.bundleIdentifier else { return }
        let shortcuts = provider()
        guard force || shortcuts != last else { return }
        last = shortcuts
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? id
        DistributedNotificationCenter.default().postNotificationName(report, object: id,
                                                                     userInfo: ["app": name, "shortcuts": shortcuts.map(\.plist), "canChange": changer != nil],
                                                                     deliverImmediately: true)
    }
}
