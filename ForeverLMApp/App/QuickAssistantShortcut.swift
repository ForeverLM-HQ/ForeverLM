import AppKit
import Carbon.HIToolbox
import Observation
import os

// MARK: - The quick assistant's shortcut
//
// The product owner, 2026-10-02, of Claude's Caps Lock voice bar: "when you hit caps
// lock, claude becomes a helpful assistant … make it an assistant that can do
// one off stuff". Caps Lock is Claude's on his Mac and ⌥Space is ChatGPT's, so
// the quick assistant takes a shortcut the learner picks (Settings › General ›
// Quick assistant), ⌃⌥Space until they do (⌃⌥⇧Space in a development build).
// docs/quick-assistant-design.md.

/// A global keyboard shortcut: one key and the modifiers held with it, in
/// Carbon's terms, because `RegisterEventHotKey` is the one way to hear a key
/// combination pressed in another app without asking for Input Monitoring or
/// Accessibility.
///
/// Written down as `ctrl+option+space` — the form `get_app_settings` reports,
/// `set_app_setting` takes, and this Mac's defaults store — and shown as
/// `⌃⌥Space`.
struct QuickAssistantShortcut: Equatable {
    /// A virtual key code (`kVK_…`): a position on the keyboard, not a letter.
    let keyCode: UInt32
    /// Carbon modifier bits: `controlKey`, `optionKey`, `shiftKey`, `cmdKey`.
    let modifiers: UInt32

    /// ⌃⌥Space until the learner picks another.
    static let productionDefault = QuickAssistantShortcut(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey | optionKey)
    )
    /// ⌃⌥⇧Space. macOS lets two apps register the same combination, so a
    /// Dev or First Run build left on the installed app's default would
    /// answer the keys the learner's own ForeverLM is meant to.
    static let developmentDefault = QuickAssistantShortcut(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey | optionKey | shiftKey)
    )

    static var `default`: QuickAssistantShortcut {
        ForeverLMRuntimeIdentity.isDevelopment ? developmentDefault : productionDefault
    }

    /// This Mac's choice. Never synced: another Mac may have another keyboard,
    /// and another app there may own the combination.
    static let storageKey = "quickAssistant.shortcut"
    /// Stored for a learner who turned the shortcut off.
    static let offValue = "off"

    /// The shortcut this Mac listens for, or nil when the learner turned it
    /// off. Never set means the default; a stored value this build cannot read
    /// is treated as off rather than guessed at.
    static func stored(in defaults: UserDefaults = .standard) -> QuickAssistantShortcut? {
        guard let raw = defaults.string(forKey: storageKey) else { return .default }
        return try? parse(raw)
    }

    static func store(_ shortcut: QuickAssistantShortcut?, in defaults: UserDefaults = .standard) {
        defaults.set(shortcut?.serialized ?? offValue, forKey: storageKey)
    }

    // MARK: Keys

    /// The keys a shortcut may end in. Escape and Delete are left out: the
    /// recorder uses them to cancel and to turn the shortcut off.
    private static let namedKeys: [(name: String, code: Int, label: String)] = [
        ("a", kVK_ANSI_A, "A"), ("b", kVK_ANSI_B, "B"), ("c", kVK_ANSI_C, "C"),
        ("d", kVK_ANSI_D, "D"), ("e", kVK_ANSI_E, "E"), ("f", kVK_ANSI_F, "F"),
        ("g", kVK_ANSI_G, "G"), ("h", kVK_ANSI_H, "H"), ("i", kVK_ANSI_I, "I"),
        ("j", kVK_ANSI_J, "J"), ("k", kVK_ANSI_K, "K"), ("l", kVK_ANSI_L, "L"),
        ("m", kVK_ANSI_M, "M"), ("n", kVK_ANSI_N, "N"), ("o", kVK_ANSI_O, "O"),
        ("p", kVK_ANSI_P, "P"), ("q", kVK_ANSI_Q, "Q"), ("r", kVK_ANSI_R, "R"),
        ("s", kVK_ANSI_S, "S"), ("t", kVK_ANSI_T, "T"), ("u", kVK_ANSI_U, "U"),
        ("v", kVK_ANSI_V, "V"), ("w", kVK_ANSI_W, "W"), ("x", kVK_ANSI_X, "X"),
        ("y", kVK_ANSI_Y, "Y"), ("z", kVK_ANSI_Z, "Z"),
        ("0", kVK_ANSI_0, "0"), ("1", kVK_ANSI_1, "1"), ("2", kVK_ANSI_2, "2"),
        ("3", kVK_ANSI_3, "3"), ("4", kVK_ANSI_4, "4"), ("5", kVK_ANSI_5, "5"),
        ("6", kVK_ANSI_6, "6"), ("7", kVK_ANSI_7, "7"), ("8", kVK_ANSI_8, "8"),
        ("9", kVK_ANSI_9, "9"),
        ("-", kVK_ANSI_Minus, "-"), ("=", kVK_ANSI_Equal, "="),
        ("[", kVK_ANSI_LeftBracket, "["), ("]", kVK_ANSI_RightBracket, "]"),
        ("\\", kVK_ANSI_Backslash, "\\"), (";", kVK_ANSI_Semicolon, ";"),
        ("'", kVK_ANSI_Quote, "'"), (",", kVK_ANSI_Comma, ","),
        (".", kVK_ANSI_Period, "."), ("/", kVK_ANSI_Slash, "/"),
        ("`", kVK_ANSI_Grave, "`"),
        ("space", kVK_Space, "Space"), ("return", kVK_Return, "Return"), ("tab", kVK_Tab, "Tab"),
        ("f1", kVK_F1, "F1"), ("f2", kVK_F2, "F2"), ("f3", kVK_F3, "F3"), ("f4", kVK_F4, "F4"),
        ("f5", kVK_F5, "F5"), ("f6", kVK_F6, "F6"), ("f7", kVK_F7, "F7"), ("f8", kVK_F8, "F8"),
        ("f9", kVK_F9, "F9"), ("f10", kVK_F10, "F10"), ("f11", kVK_F11, "F11"), ("f12", kVK_F12, "F12"),
        ("f13", kVK_F13, "F13"), ("f14", kVK_F14, "F14"), ("f15", kVK_F15, "F15"), ("f16", kVK_F16, "F16"),
        ("f17", kVK_F17, "F17"), ("f18", kVK_F18, "F18"), ("f19", kVK_F19, "F19"), ("f20", kVK_F20, "F20"),
    ]

    /// Modifiers in the order macOS menus draw them.
    private static let namedModifiers: [(name: String, bit: Int, symbol: String)] = [
        ("ctrl", controlKey, "⌃"), ("option", optionKey, "⌥"), ("shift", shiftKey, "⇧"), ("cmd", cmdKey, "⌘"),
    ]

    private static let modifierAliases: [String: Int] = [
        "ctrl": controlKey, "control": controlKey, "⌃": controlKey,
        "option": optionKey, "opt": optionKey, "alt": optionKey, "⌥": optionKey,
        "shift": shiftKey, "⇧": shiftKey,
        "cmd": cmdKey, "command": cmdKey, "⌘": cmdKey,
    ]

    /// F1–F20; the letter F is "f" alone.
    private var isFunctionKey: Bool {
        guard let name = Self.namedKeys.first(where: { $0.code == Int(keyCode) })?.name else { return false }
        return name.count > 1 && name.hasPrefix("f")
    }

    /// Whether this is a combination worth taking from every other app. A
    /// key needs ⌃, ⌥ or ⌘ held with it — a letter with only ⇧ is typing —
    /// unless it is a function key, which can stand alone.
    var isUsable: Bool {
        guard Self.namedKeys.contains(where: { $0.code == Int(keyCode) }) else { return false }
        if isFunctionKey { return true }
        return modifiers & UInt32(controlKey | optionKey | cmdKey) != 0
    }

    // MARK: Writing it down

    /// `ctrl+option+space`.
    var serialized: String {
        let mods = Self.namedModifiers.filter { modifiers & UInt32($0.bit) != 0 }.map(\.name)
        let key = Self.namedKeys.first { $0.code == Int(keyCode) }?.name ?? "key\(keyCode)"
        return (mods + [key]).joined(separator: "+")
    }

    /// `⌃⌥Space`.
    var displayString: String {
        let mods = Self.namedModifiers.filter { modifiers & UInt32($0.bit) != 0 }.map(\.symbol).joined()
        let key = Self.namedKeys.first { $0.code == Int(keyCode) }?.label ?? "Key \(keyCode)"
        return mods + key
    }

    enum ParseError: LocalizedError {
        case unknownToken(String)
        case noKey
        case twoKeys
        case unusable(String)

        var errorDescription: String? {
            switch self {
            case .unknownToken(let token):
                return "\"\(token)\" is not a key or modifier. Write the shortcut as modifiers and one key joined by +, such as ctrl+option+space or cmd+shift+k, or off."
            case .noKey:
                return "The shortcut names modifiers but no key, such as ctrl+option+space."
            case .twoKeys:
                return "A shortcut ends in one key, such as ctrl+option+space."
            case .unusable(let text):
                return "\(text) needs ctrl, option or cmd held with it (a function key such as f5 may stand alone)."
            }
        }
    }

    /// Reads `ctrl+option+space`, `⌃⌥Space` or `off` (nil). Case and spaces
    /// around the `+` do not matter.
    static func parse(_ text: String) throws -> QuickAssistantShortcut? {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["off", "none", ""].contains(rest.lowercased()) { return nil }

        var modifiers = 0
        // `⌃⌥Space`: the symbols run straight into the key.
        while let first = rest.first, let bit = modifierAliases[String(first)] {
            modifiers |= bit
            rest.removeFirst()
            rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "+ "))
        }

        var key: Int?
        for rawToken in rest.split(separator: "+", omittingEmptySubsequences: true) {
            let token = rawToken.trimmingCharacters(in: .whitespaces).lowercased()
            guard !token.isEmpty else { continue }
            if let bit = modifierAliases[token] {
                modifiers |= bit
            } else if let named = namedKeys.first(where: { $0.name == token }) {
                guard key == nil else { throw ParseError.twoKeys }
                key = named.code
            } else {
                throw ParseError.unknownToken(String(rawToken))
            }
        }
        guard let key else { throw ParseError.noKey }
        let shortcut = QuickAssistantShortcut(keyCode: UInt32(key), modifiers: UInt32(modifiers))
        guard shortcut.isUsable else { throw ParseError.unusable(shortcut.serialized) }
        return shortcut
    }

    /// The shortcut a key press in the recorder spells, whether or not it is
    /// usable; nil for a key no shortcut may end in.
    init?(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        guard Self.namedKeys.contains(where: { $0.code == Int(keyCode) }) else { return nil }
        var bits = 0
        if modifierFlags.contains(.control) { bits |= controlKey }
        if modifierFlags.contains(.option) { bits |= optionKey }
        if modifierFlags.contains(.shift) { bits |= shiftKey }
        if modifierFlags.contains(.command) { bits |= cmdKey }
        self.init(keyCode: UInt32(keyCode), modifiers: UInt32(bits))
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

// MARK: - Listening for it everywhere

private let quickAssistantHotKeySignature: OSType = 0x464C_4D51 // "FLMQ"

/// The one global hotkey ForeverLM registers. Carbon's `RegisterEventHotKey`
/// is heard in every app and needs no privacy permission. A registration
/// macOS refuses is reported as `.unavailable` for Settings to say, never
/// silently ignored. It does not refuse a combination another app holds
/// (measured 2026-10-02: two processes both registered ⌃⇧F19), so a clash
/// with another app shows only as the panel not coming up.
@Observable
@MainActor
final class QuickAssistantHotKey {
    static let shared = QuickAssistantHotKey()

    enum Status: Equatable {
        /// The learner turned the shortcut off.
        case off
        case listening(QuickAssistantShortcut)
        /// macOS would not register it.
        case unavailable(QuickAssistantShortcut, OSStatus)
    }

    private(set) var status: Status = .off
    @ObservationIgnored var onPress: (@MainActor () -> Void)?

    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var handlerRef: EventHandlerRef?
    @ObservationIgnored private var wanted: QuickAssistantShortcut?
    /// Settings' recorder holds the hotkey down while it listens, so pressing
    /// the current combination records it instead of summoning the panel.
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
        category: "QuickAssistant"
    )

    private init() {}

    /// The learner's choice, from Settings or `set_app_setting`: kept on this
    /// Mac and listened for at once.
    func choose(_ shortcut: QuickAssistantShortcut?) {
        QuickAssistantShortcut.store(shortcut)
        apply(shortcut)
    }

    /// Listens for `shortcut` from now on, or for nothing.
    func apply(_ shortcut: QuickAssistantShortcut?) {
        wanted = shortcut
        register()
    }

    func suspend() {
        isSuspended = true
        unregister()
    }

    func resume() {
        isSuspended = false
        register()
    }

    private func register() {
        unregister()
        guard let shortcut = wanted else {
            status = .off
            return
        }
        guard !isSuspended else { return }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let result = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            EventHotKeyID(signature: quickAssistantHotKeySignature, id: 1),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if result == noErr, let ref {
            hotKeyRef = ref
            status = .listening(shortcut)
        } else {
            logger.error("Could not register the quick assistant shortcut \(shortcut.serialized, privacy: .public): \(result, privacy: .public)")
            status = .unavailable(shortcut, result)
        }
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Carbon calls this on the main thread, for the application target.
        let handler: EventHandlerUPP = { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let read = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard read == noErr, hotKeyID.signature == quickAssistantHotKeySignature else {
                return OSStatus(eventNotHandledErr)
            }
            Task { @MainActor in QuickAssistantHotKey.shared.onPress?() }
            return noErr
        }
        let installed = InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, &handlerRef)
        if installed != noErr {
            logger.error("Could not install the quick assistant hotkey handler: \(installed, privacy: .public)")
        }
    }
}
