import AppKit
import ApplicationServices
import Carbon.HIToolbox

// A Bluetooth camera remote or presentation clicker pairs as a keyboard. A person teaches the
// app a button once, then during a take that button does an action instead of its usual job.

/// One button, learned from a press.
struct RemoteButton: Codable, Hashable {
    enum Kind: Codable, Hashable {
        /// A key. `modifiers` is an NSEvent.ModifierFlags raw value holding only Shift, Control,
        /// Option and Command.
        case key(code: UInt16, modifiers: UInt)
        /// A media key by its NX_KEYTYPE number: 0 volume up, 1 volume down, 16 play, 17 next,
        /// 18 previous, 19 fast forward, 20 rewind.
        case media(code: Int)
    }
    var kind: Kind
    /// What a person reads: "Volume Up", "Return", "Page Down", "Shift-F5".
    var name: String
}

enum RemoteAction: String, Codable, CaseIterable, Identifiable {
    case nextLine, previousLine, switchView, startStop
    var id: String { rawValue }

    var title: String {
        switch self {
        case .nextLine: "Next line"
        case .previousLine: "Previous line"
        case .switchView: "Switch Me and Screen"
        case .startStop: "Start or stop recording"
        }
    }
}

/// Hot key signature 'AVRM'. PrompterKeys uses 'AVAR'.
private let hotKeySignature: OSType = 0x4156_524D
private let defaultsKey = "remoteButtons"
private let refusedTyping = "Letters and numbers cannot be used. Press a remote button."

/// Listens for the learned buttons. With Accessibility allowed it uses an event tap, which sees
/// every key and media key and can stop them doing their usual job. Without it, learned keys
/// still work during a take as hot keys, but media keys (Volume Up) cannot be caught.
@MainActor
final class RemoteControl: ObservableObject {
    static let shared = RemoteControl()

    @Published private(set) var buttons: [RemoteAction: RemoteButton] = [:]
    /// Waiting for a press to assign.
    @Published private(set) var learning: RemoteAction?
    /// The last button heard while learning or in a take, or why a press was refused.
    @Published private(set) var lastHeard: String?
    /// Accessibility is allowed. Refreshed by refreshTrust().
    @Published private(set) var trusted: Bool
    /// Called on the main thread.
    var onAction: ((RemoteAction) -> Void)?

    private let defaults: UserDefaults
    private var active = false
    fileprivate var monitor: Any?
    fileprivate var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    fileprivate var hotKeys: [EventHotKeyRef] = []
    fileprivate var hotKeyActions: [UInt32: RemoteAction] = [:]
    fileprivate var hotKeyHandler: EventHandlerRef?
    /// Keys whose press was swallowed, so their release is swallowed too.
    private var held: Set<UInt16> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        trusted = AXIsProcessTrusted()
        buttons = Self.load(from: defaults)
    }

    // MARK: What the app calls

    /// The next key or media press is assigned to `action`. It is heard from any app when
    /// trusted, otherwise only while this app is in front. Escape cancels.
    func learn(_ action: RemoteAction) {
        refreshTrust()
        learning = action
        lastHeard = nil
        reconcile()
    }

    func cancelLearning() {
        guard learning != nil else { return }
        learning = nil
        reconcile()
    }

    func forget(_ action: RemoteAction) {
        buttons[action] = nil
        save()
        reconcile()
    }

    /// On for a take only. Learned buttons then run their action and do nothing else.
    func setActive(_ on: Bool) {
        var changed = on != active
        if on {
            refreshTrust()
            if learning != nil { learning = nil; changed = true }
        }
        // Asked again on every change of the take, so only a real change touches the listeners.
        // Setting `learning` every time used to wake the app's watcher, which asked again: a loop
        // that kept one core busy for the whole take.
        guard changed else { return }
        active = on
        held = []
        reconcile()
    }

    func refreshTrust() {
        let now = AXIsProcessTrusted()
        guard now != trusted else { return }
        trusted = now
        reconcile()
    }

    /// Shows the system's Accessibility prompt and opens Privacy & Security > Accessibility.
    func askForAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refreshTrust()
    }

    /// The action a button runs, if it has been learned.
    func action(for kind: RemoteButton.Kind) -> RemoteAction? {
        buttons.first { $0.value.kind == kind }?.key
    }

    /// Gives `button` to `action`, taking it off any other action first.
    func assign(_ button: RemoteButton, to action: RemoteAction) {
        for (other, existing) in buttons where existing.kind == button.kind {
            buttons[other] = nil
        }
        buttons[action] = button
        save()
        learning = nil
        lastHeard = button.name
        settle()
    }

    // MARK: Listening

    /// Puts the listeners in line with the state: the tap when trusted and learning or in a
    /// take, hot keys in a take without a tap, the in-app monitor while learning.
    private func reconcile() {
        if trusted && (active || learning != nil) { installTap() } else { removeTap() }
        unregisterHotKeys()
        if active && learning == nil && tap == nil { registerHotKeys() }
        if learning != nil { addMonitor() } else { removeMonitor() }
    }

    /// Reconciles on the next turn of the main loop. Used from inside the tap and the monitor,
    /// which must not remove themselves while they run.
    private func settle() {
        Task { @MainActor [weak self] in self?.reconcile() }
    }

    private func addMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .systemDefined]) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.monitored(event) } ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// A press seen inside this app while learning. Returns true to swallow it.
    fileprivate func monitored(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown:
            let kind = RemoteButton.Kind.key(code: event.keyCode, modifiers: Self.cleanModifiers(event.modifierFlags.rawValue))
            return heardWhileLearning(kind, isRepeat: event.isARepeat, characters: event.charactersIgnoringModifiers)
        case .systemDefined where event.subtype.rawValue == 8:
            let key = Self.mediaKey(data1: event.data1)
            guard key.down else { return false }
            return heardWhileLearning(.media(code: key.code), isRepeat: event.data1 & 0x1 != 0, characters: nil)
        default:
            return false
        }
    }

    private func installTap() {
        guard tap == nil else { return }
        // Key down, key up, and NX_SYSDEFINED (14), which carries the media keys.
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue) | CGEventMask(1 << 14)
        // It runs on the main run loop, so the controller can be read directly.
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let control = Unmanaged<RemoteControl>.fromOpaque(info).takeUnretainedValue()
            let swallow = MainActor.assumeIsolated { control.tapped(type, event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        tapSource = source
    }

    fileprivate func removeTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        tapSource = nil
        held = []
    }

    /// One event from the tap. Returns true to swallow it. Anything not learned goes through untouched.
    fileprivate func tapped(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .keyDown:
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let kind = RemoteButton.Kind.key(code: code, modifiers: Self.cleanModifiers(UInt(event.flags.rawValue)))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if learning != nil {
                return heardWhileLearning(kind, isRepeat: isRepeat, characters: NSEvent(cgEvent: event)?.charactersIgnoringModifiers)
            }
            guard active, let action = action(for: kind) else { return false }
            held.insert(code)
            if !isRepeat { fire(action) }
            return true
        case .keyUp:
            return held.remove(UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))) != nil
        default:
            guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
            let key = Self.mediaKey(data1: ns.data1)
            let isRepeat = ns.data1 & 0x1 != 0
            if learning != nil {
                return key.down && heardWhileLearning(.media(code: key.code), isRepeat: isRepeat, characters: nil)
            }
            // Both the press and the release are swallowed, so the volume never moves.
            guard active, let action = action(for: .media(code: key.code)) else { return false }
            if key.down && !isRepeat { fire(action) }
            return true
        }
    }

    /// A press while learning. Returns true to swallow it.
    private func heardWhileLearning(_ kind: RemoteButton.Kind, isRepeat: Bool, characters: String?) -> Bool {
        guard let action = learning, !isRepeat else { return false }
        if case .key(let code, let modifiers) = kind {
            if Int(code) == kVK_Escape {
                learning = nil
                lastHeard = nil
                settle()
                return true
            }
            if Self.stealsTyping(modifiers: modifiers, characters: characters) {
                lastHeard = refusedTyping
                return false
            }
        }
        assign(RemoteButton(kind: kind, name: Self.name(for: kind, characters: characters)), to: action)
        return true
    }

    /// Runs the action after the tap has returned, so a slow action never holds up typing.
    private func fire(_ action: RemoteAction) {
        let name = buttons[action]?.name
        Task { @MainActor [weak self] in
            self?.lastHeard = name
            self?.onAction?(action)
        }
    }

    // MARK: Hot keys, for a take without Accessibility

    fileprivate func registerHotKeys() {
        var id: UInt32 = 0
        for action in RemoteAction.allCases {
            guard case .key(let code, let modifiers)? = buttons[action]?.kind else { continue }
            installHotKeyHandler()
            id += 1
            var ref: EventHotKeyRef?
            let key = EventHotKeyID(signature: hotKeySignature, id: id)
            if RegisterEventHotKey(UInt32(code), Self.carbonModifiers(modifiers), key, GetEventDispatcherTarget(), 0, &ref) == noErr,
               let ref {
                hotKeys.append(ref)
                hotKeyActions[id] = action
            }
        }
    }

    fileprivate func unregisterHotKeys() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys = []
        hotKeyActions = [:]
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        hotKeyHandler = nil
    }

    /// Hot keys go to the event dispatcher rather than the application target, so PrompterKeys'
    /// handler there, which takes every hot key it is sent, never sees ours.
    private func installHotKeyHandler() {
        guard hotKeyHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, info in
            var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard key.signature == hotKeySignature, let info else { return OSStatus(eventNotHandledErr) }
            let control = Unmanaged<RemoteControl>.fromOpaque(info).takeUnretainedValue()
            let id = key.id
            Task { @MainActor in control.hotKeyPressed(id) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
    }

    private func hotKeyPressed(_ id: UInt32) {
        guard active, let action = hotKeyActions[id] else { return }
        lastHeard = buttons[action]?.name
        onAction?(action)
    }

    // MARK: Saved buttons

    nonisolated static func load(from defaults: UserDefaults) -> [RemoteAction: RemoteButton] {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode([String: RemoteButton].self, from: data) else { return [:] }
        var buttons: [RemoteAction: RemoteButton] = [:]
        for (key, button) in saved {
            if let action = RemoteAction(rawValue: key) { buttons[action] = button }
        }
        return buttons
    }

    /// Saved as a JSON object keyed by action, so it reads plainly.
    private func save() {
        let saved = Dictionary(uniqueKeysWithValues: buttons.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: defaultsKey) }
    }

    // MARK: Pure parts

    /// Reads a media key from a system-defined event's data1: which key, and whether it went down.
    nonisolated static func mediaKey(data1: Int) -> (code: Int, down: Bool) {
        let code = (data1 & 0xFFFF_0000) >> 16
        let flags = data1 & 0xFFFF
        return (code, (flags & 0xFF00) >> 8 == 0x0A)
    }

    /// Keeps Shift, Control, Option and Command. Arrow and function keys carry the Fn and number
    /// pad flags by themselves, and Caps Lock would stop a button matching.
    nonisolated static func cleanModifiers(_ raw: UInt) -> UInt {
        NSEvent.ModifierFlags(rawValue: raw).intersection([.shift, .control, .option, .command]).rawValue
    }

    /// A letter or number with no modifier but Shift. Taking it would take typing away.
    nonisolated static func stealsTyping(modifiers: UInt, characters: String?) -> Bool {
        guard NSEvent.ModifierFlags(rawValue: modifiers).subtracting(.shift).isEmpty,
              let characters, characters.count == 1, let c = characters.first else { return false }
        return c.isLetter || c.isNumber
    }

    nonisolated static func carbonModifiers(_ raw: UInt) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: raw)
        var carbon = 0
        if flags.contains(.shift) { carbon |= shiftKey }
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.command) { carbon |= cmdKey }
        return UInt32(carbon)
    }

    /// What a person reads for a button. `characters` is what the key types, for keys without a name.
    nonisolated static func name(for kind: RemoteButton.Kind, characters: String?) -> String {
        switch kind {
        case .media(let code):
            switch code {
            case 0: return "Volume Up"
            case 1: return "Volume Down"
            case 7: return "Mute"
            case 16: return "Play/Pause"
            case 17: return "Next Track"
            case 18: return "Previous Track"
            case 19: return "Fast Forward"
            case 20: return "Rewind"
            default: return "Media key \(code)"
            }
        case .key(let code, let modifiers):
            let flags = NSEvent.ModifierFlags(rawValue: modifiers)
            var prefix = ""
            if flags.contains(.control) { prefix += "Control-" }
            if flags.contains(.option) { prefix += "Option-" }
            if flags.contains(.shift) { prefix += "Shift-" }
            if flags.contains(.command) { prefix += "Command-" }
            return prefix + keyName(code: code, characters: characters)
        }
    }

    private nonisolated static func keyName(code: UInt16, characters: String?) -> String {
        let named: [Int: String] = [
            kVK_Return: "Return", kVK_ANSI_KeypadEnter: "Enter", kVK_Space: "Space", kVK_Escape: "Escape",
            kVK_Tab: "Tab", kVK_Delete: "Delete", kVK_ForwardDelete: "Forward Delete",
            kVK_LeftArrow: "Left Arrow", kVK_RightArrow: "Right Arrow", kVK_UpArrow: "Up Arrow", kVK_DownArrow: "Down Arrow",
            kVK_PageUp: "Page Up", kVK_PageDown: "Page Down", kVK_Home: "Home", kVK_End: "End",
        ]
        if let name = named[Int(code)] { return name }
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        if let i = functionKeys.firstIndex(of: Int(code)) { return "F\(i + 1)" }
        // Otherwise what it types, unless that is blank, a control character or Apple's private
        // range (which other function keys type).
        if let characters, !characters.trimmingCharacters(in: .whitespaces).isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xE000...0xF8FF).contains($0.value) }) {
            return characters.uppercased()
        }
        return "Key \(code)"
    }
}

/// `--remote-test <dir>`: checks the remote's pure parts, learning, a take and saved settings with
/// made-up presses that never leave the app, and writes each check to <dir>/remote-test.json.
/// It saves only to its own settings suite, so the real buttons are untouched.
enum RemoteTest {
    struct Check: Encodable {
        var name: String
        var pass: Bool
        var detail: String
    }

    private struct Report: Encodable {
        var trusted: Bool
        var passed: Int
        var failed: Int
        var checks: [Check]
    }

    @MainActor
    static func run(dir: URL) {
        NSApp.windows.forEach { $0.orderOut(nil) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            var checks: [Check] = []
            func check(_ name: String, _ pass: Bool, _ detail: String = "") {
                checks.append(Check(name: name, pass: pass, detail: detail))
            }
            func settle() async { try? await Task.sleep(nanoseconds: 150_000_000) }
            func media(_ code: Int, down: Bool, repeating: Bool = false) -> NSEvent? {
                let flags = (down ? 0x0A00 : 0x0B00) | (repeating ? 1 : 0)
                return NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                          context: nil, subtype: 8, data1: code << 16 | flags, data2: -1)
            }
            func key(_ code: Int, _ characters: String, _ flags: NSEvent.ModifierFlags = [], repeating: Bool = false) -> NSEvent? {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                 characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeating, keyCode: UInt16(code))
            }
            let realBefore = UserDefaults.standard.data(forKey: defaultsKey)

            // Media keys, as a remote sends Volume Up.
            let up = media(0, down: true), upRelease = media(0, down: false)
            check("Volume Up press is a system-defined event with subtype 8",
                  up?.type == .systemDefined && up?.subtype.rawValue == 8, "data1 \(up.map { String($0.data1, radix: 16) } ?? "none")")
            let pressed = up.map { RemoteControl.mediaKey(data1: $0.data1) }
            check("Volume Up press decodes as code 0, down", pressed?.code == 0 && pressed?.down == true, "\(String(describing: pressed))")
            let released = upRelease.map { RemoteControl.mediaKey(data1: $0.data1) }
            check("Volume Up release decodes as code 0, up", released?.code == 0 && released?.down == false, "\(String(describing: released))")
            let held = media(0, down: true, repeating: true).map { RemoteControl.mediaKey(data1: $0.data1) }
            check("Volume Up repeat still decodes as down", held?.code == 0 && held?.down == true, "\(String(describing: held))")
            let play = media(16, down: true).map { RemoteControl.mediaKey(data1: $0.data1) }
            check("Play/Pause press decodes as code 16, down", play?.code == 16 && play?.down == true, "\(String(describing: play))")
            let cg = up?.cgEvent
            let back = cg.flatMap { NSEvent(cgEvent: $0) }
            check("Volume Up keeps its data through a CGEvent, as the tap sees it",
                  cg?.type.rawValue == 14 && back?.subtype.rawValue == 8 && back?.data1 == up?.data1,
                  "CGEvent type \(cg.map { String($0.type.rawValue) } ?? "none")")

            // Names.
            let shift = NSEvent.ModifierFlags.shift.rawValue
            let names: [(RemoteButton.Kind, String?, String)] = [
                (.media(code: 0), nil, "Volume Up"), (.media(code: 1), nil, "Volume Down"), (.media(code: 16), nil, "Play/Pause"),
                (.media(code: 17), nil, "Next Track"), (.media(code: 18), nil, "Previous Track"), (.media(code: 19), nil, "Fast Forward"),
                (.media(code: 20), nil, "Rewind"), (.media(code: 99), nil, "Media key 99"),
                (.key(code: 36, modifiers: 0), "\r", "Return"), (.key(code: 76, modifiers: 0), "\u{3}", "Enter"),
                (.key(code: 49, modifiers: 0), " ", "Space"), (.key(code: 121, modifiers: 0), "\u{F72D}", "Page Down"),
                (.key(code: 116, modifiers: 0), "\u{F72C}", "Page Up"), (.key(code: 124, modifiers: 0), "\u{F703}", "Right Arrow"),
                (.key(code: 123, modifiers: 0), "\u{F702}", "Left Arrow"), (.key(code: 96, modifiers: shift), "\u{F708}", "Shift-F5"),
                (.key(code: 111, modifiers: 0), "\u{F70F}", "F12"),
                (.key(code: 80, modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue), nil, "Control-Option-Command-F19"),
                (.key(code: 11, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue), "b", "Shift-Command-B"),
                (.key(code: 47, modifiers: 0), ".", "."), (.key(code: 200, modifiers: 0), nil, "Key 200"),
                (.key(code: 200, modifiers: 0), "\u{F746}", "Key 200"),
            ]
            for (kind, characters, expected) in names {
                let got = RemoteControl.name(for: kind, characters: characters)
                check("Name \(expected)", got == expected, "got \(got)")
            }

            // Modifiers and typing.
            let arrowFlags = NSEvent.ModifierFlags([.numericPad, .function, .shift, .capsLock]).rawValue
            check("Fn, number pad and Caps Lock are dropped, Shift kept", RemoteControl.cleanModifiers(arrowFlags) == shift)
            check("Carbon modifiers for Control-Option-Command",
                  RemoteControl.carbonModifiers(NSEvent.ModifierFlags([.control, .option, .command]).rawValue) == UInt32(controlKey | optionKey | cmdKey))
            let typing: [(UInt, String?, Bool)] = [(0, "a", true), (shift, "A", true), (0, "5", true),
                                                    (NSEvent.ModifierFlags.command.rawValue, "a", false), (0, "\r", false), (0, " ", false), (0, nil, false)]
            for (modifiers, characters, expected) in typing {
                check("Typing refusal for \(String(reflecting: characters)) with modifiers \(modifiers)",
                      RemoteControl.stealsTyping(modifiers: modifiers, characters: characters) == expected)
            }

            // Learning, through the in-app monitor, with its own settings.
            let suiteName = "inc.ava.recorder.remote-test"
            guard let suite = UserDefaults(suiteName: suiteName) else {
                check("Test settings suite opens", false)
                finish(checks, dir)
            }
            suite.removePersistentDomain(forName: suiteName)
            let first = RemoteControl(defaults: suite)
            check("A fresh suite has no buttons", first.buttons.isEmpty)

            first.learn(.nextLine)
            let letter = key(0, "a").map { first.monitored($0) } ?? true
            check("A bare letter is refused and passes through", !letter && first.learning == .nextLine && first.lastHeard == refusedTyping,
                  "lastHeard \(first.lastHeard ?? "nil")")
            let repeated = key(124, "\u{F703}", [.function, .numericPad], repeating: true).map { first.monitored($0) } ?? true
            check("A key repeat is ignored while learning", !repeated && first.learning == .nextLine)
            let volume = up.map { first.monitored($0) } ?? false
            check("Volume Up is learned for Next line and swallowed",
                  volume && first.learning == nil && first.buttons[.nextLine] == RemoteButton(kind: .media(code: 0), name: "Volume Up"),
                  "\(String(describing: first.buttons[.nextLine]))")
            await settle()
            check("Learning ends with no monitor or tap left", first.monitor == nil && first.tap == nil)

            first.learn(.previousLine)
            _ = key(36, "\r").map { first.monitored($0) }
            check("Return is learned for Previous line", first.buttons[.previousLine] == RemoteButton(kind: .key(code: 36, modifiers: 0), name: "Return"))

            first.learn(.switchView)
            let escape = key(53, "\u{1B}").map { first.monitored($0) } ?? false
            check("Escape cancels learning and is not assigned", escape && first.learning == nil && first.buttons[.switchView] == nil)

            first.learn(.switchView)
            _ = key(121, "\u{F72D}", [.function, .numericPad]).map { first.monitored($0) }
            check("Page Down from a clicker is learned without its Fn flag",
                  first.buttons[.switchView] == RemoteButton(kind: .key(code: 121, modifiers: 0), name: "Page Down"),
                  "\(String(describing: first.buttons[.switchView]))")

            first.learn(.startStop)
            _ = up.map { first.monitored($0) }
            check("Learning Volume Up again moves it from Next line to Start or stop",
                  first.buttons[.startStop]?.kind == .media(code: 0) && first.buttons[.nextLine] == nil)
            await settle()

            // Saved and loaded again.
            let second = RemoteControl(defaults: suite)
            check("Buttons load back the same", second.buttons == first.buttons, "\(second.buttons.count) buttons")
            let stored = suite.data(forKey: defaultsKey).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            check("Saved as a JSON object keyed by action", stored.map { Set($0.keys) } == ["previousLine", "switchView", "startStop"],
                  stored.map { $0.keys.sorted().joined(separator: ", ") } ?? "nothing saved")
            check("A learned media button is found", second.action(for: .media(code: 0)) == .startStop)
            check("A learned key is found", second.action(for: .key(code: 36, modifiers: 0)) == .previousLine)
            check("The same key with Shift is not", second.action(for: .key(code: 36, modifiers: shift)) == nil)
            second.forget(.switchView)
            check("Forget removes it after a reload", RemoteControl(defaults: suite).buttons[.switchView] == nil)

            // A take, with a key nobody presses and Volume Up. Presses are handed straight to the
            // tap's decision, never posted to the system.
            suite.removePersistentDomain(forName: suiteName)
            let take = RemoteControl(defaults: suite)
            let f19 = NSEvent.ModifierFlags([.control, .option, .command])
            take.assign(RemoteButton(kind: .key(code: 80, modifiers: f19.rawValue), name: "Control-Option-Command-F19"), to: .nextLine)
            take.assign(RemoteButton(kind: .media(code: 0), name: "Volume Up"), to: .startStop)
            await settle()
            var heard: [RemoteAction] = []
            take.onAction = { heard.append($0) }
            take.setActive(true)
            check("A take listens through the tap when trusted, else hot keys",
                  take.trusted ? take.tap != nil : (take.tap == nil && take.hotKeys.count == 1 && take.hotKeyHandler != nil),
                  "trusted \(take.trusted), tap \(take.tap != nil), hot keys \(take.hotKeys.count)")

            func keyboard(_ code: Int, down: Bool, _ flags: CGEventFlags) -> CGEvent? {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)
                event?.flags = flags
                return event
            }
            let f19Flags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
            let f19Down = keyboard(80, down: true, f19Flags).map { take.tapped($0.type, $0) } ?? false
            let f19Up = keyboard(80, down: false, f19Flags).map { take.tapped($0.type, $0) } ?? false
            let plainA = keyboard(0, down: true, []).map { take.tapped($0.type, $0) } ?? true
            let plainAUp = keyboard(0, down: false, []).map { take.tapped($0.type, $0) } ?? true
            check("A learned key is swallowed, press and release", f19Down && f19Up)
            check("Other keys pass through", !plainA && !plainAUp)
            let volumeDown = up?.cgEvent.map { take.tapped($0.type, $0) } ?? false
            let volumeRepeat = media(0, down: true, repeating: true)?.cgEvent.map { take.tapped($0.type, $0) } ?? false
            let volumeUp = upRelease?.cgEvent.map { take.tapped($0.type, $0) } ?? false
            let otherMedia = media(1, down: true)?.cgEvent.map { take.tapped($0.type, $0) } ?? true
            check("Learned Volume Up is swallowed, press, repeat and release", volumeDown && volumeRepeat && volumeUp)
            check("Volume Down, not learned, passes through", !otherMedia)

            // The hot key path, used in a take without Accessibility, run whether or not this Mac
            // has allowed it. A handler like PrompterKeys' (it takes every hot key) sits on the
            // application target. Hot key presses are sent inside the app, never to the system.
            take.removeTap()
            take.unregisterHotKeys()
            take.registerHotKeys()
            let id = take.hotKeyActions.first(where: { $0.value == .nextLine })?.key
            check("Without the tap, learned keys become hot keys and media keys do not",
                  take.hotKeys.count == 1 && take.hotKeyHandler != nil && id != nil, "hot keys \(take.hotKeys.count)")
            let prompter = Counter()
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            var prompterHandler: EventHandlerRef?
            InstallEventHandler(GetApplicationEventTarget(), { _, _, info in
                if let info { Unmanaged<Counter>.fromOpaque(info).takeUnretainedValue().count += 1 }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(prompter).toOpaque(), &prompterHandler)
            let ours = sendHotKey(signature: hotKeySignature, id: id ?? 1, to: GetEventDispatcherTarget())
            check("Our hot key is handled by us and never reaches the prompter's handler", ours == noErr && prompter.count == 0,
                  "status \(ours), prompter saw \(prompter.count)")
            let theirs = sendHotKey(signature: 0x4156_4152, id: 1, to: GetEventDispatcherTarget())
            let theirsDirect = sendHotKey(signature: 0x4156_4152, id: 1, to: GetApplicationEventTarget())
            check("The prompter's hot key is not taken by us", theirsDirect == noErr && prompter.count >= 1,
                  "through the dispatcher \(theirs), direct \(theirsDirect), prompter saw \(prompter.count)")
            if let prompterHandler { RemoveEventHandler(prompterHandler) }
            await settle()
            let expected: [RemoteAction] = [.nextLine, .startStop, .nextLine]
            check("Actions ran once per press, repeats and releases ignored", heard == expected, heard.map(\.rawValue).joined(separator: ", "))
            check("The last button heard is shown", take.lastHeard != nil, take.lastHeard ?? "nil")

            take.setActive(false)
            check("After the take nothing is left listening",
                  take.tap == nil && take.hotKeys.isEmpty && take.hotKeyHandler == nil && take.monitor == nil)

            suite.removePersistentDomain(forName: suiteName)
            check("The real remote settings are untouched", UserDefaults.standard.data(forKey: defaultsKey) == realBefore)
            finish(checks, dir)
        }
    }

    private final class Counter { var count = 0 }

    @MainActor
    private static func sendHotKey(signature: OSType, id: UInt32, to target: EventTargetRef) -> OSStatus {
        var event: EventRef?
        CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), GetCurrentEventTime(),
                    EventAttributes(kEventAttributeNone), &event)
        guard let event else { return OSStatus(eventNotHandledErr) }
        var key = EventHotKeyID(signature: signature, id: id)
        SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          MemoryLayout<EventHotKeyID>.size, &key)
        let status = SendEventToEventTarget(event, target)
        ReleaseEvent(event)
        return status
    }

    @MainActor
    private static func finish(_ checks: [Check], _ dir: URL) -> Never {
        let failed = checks.filter { !$0.pass }.count
        let report = Report(trusted: AXIsProcessTrusted(), passed: checks.count - failed, failed: failed, checks: checks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(report).write(to: dir.appendingPathComponent("remote-test.json"))
        exit(0)
    }
}
