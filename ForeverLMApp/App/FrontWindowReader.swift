import AppKit
import ApplicationServices

/// Reads what is in front on the Mac for Nudge Me Back on Track
/// (`FocusWatch`): the frontmost app's focused window title, and in a browser
/// the page's address, through Accessibility. Never the screen's pixels.
///
/// Every call here is a round trip to another process, which blocks while
/// that app is busy, so it runs off the main actor and each element answers
/// within `messagingTimeout` or not at all.
enum FrontWindowReader {
    /// Accessibility is granted to ForeverLM. Only the learner can grant it,
    /// in System Settings › Privacy & Security › Accessibility.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS to show its Accessibility prompt, which offers to open
    /// System Settings. Shows nothing once granted.
    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// System Settings › Privacy & Security › Accessibility.
    static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

    static let messagingTimeout: Float = 0.25

    /// The browsers whose address the reader looks for, by bundle id: the
    /// window title names the page, the address names the site. Identity, not
    /// meaning, so a fixed list; another app is judged by its title alone.
    static let browserBundleIDs: Set<String> = [
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "org.mozilla.firefox", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium",
    ]

    /// What `app` has in front. Blocking: call off the main actor.
    static func scene(pid: pid_t, appName: String, bundleID: String) -> FocusScene {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        let window = axElement(app, kAXFocusedWindowAttribute)
        let title = window.flatMap { string($0, kAXTitleAttribute) }
        var url: URL?
        if let window, browserBundleIDs.contains(bundleID) {
            url = pageURL(in: window)
        }
        return FocusScene(appName: appName, bundleID: bundleID, windowTitle: title, url: url)
    }

    /// The page's address: a web area's `AXURL` (Safari, Chromium when its
    /// accessibility tree is on), else the toolbar's address field (Chromium
    /// browsers, Firefox). A bounded walk from the window; nil when neither
    /// turns up, and the title alone is judged.
    private static func pageURL(in window: AXUIElement) -> URL? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        var addressField: URL?
        while !queue.isEmpty, visited < 400 {
            let (node, depth) = queue.removeFirst()
            visited += 1
            let role = string(node, kAXRoleAttribute)
            if role == "AXWebArea" {
                if let url = urlValue(node, "AXURL"), url.scheme?.hasPrefix("http") == true { return url }
                continue // the page's own tree is not where the address is
            }
            if role == kAXTextFieldRole as String, addressField == nil, isAddressField(node),
               let text = string(node, kAXValueAttribute) {
                addressField = addressURL(from: text)
            }
            guard depth < 12, let children = children(node) else { continue }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return addressField
    }

    private static func isAddressField(_ node: AXUIElement) -> Bool {
        let words = [string(node, kAXDescriptionAttribute), string(node, kAXTitleAttribute), string(node, "AXPlaceholderValue")]
            .compactMap { $0?.lowercased() }
        return words.contains { $0.contains("address") || $0.contains("search or enter") || $0.contains("url") }
    }

    /// What an address bar shows, as a URL: browsers often drop the scheme.
    static func addressURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" "), trimmed.contains(".") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), url.host != nil else { return nil }
        return url
    }

    // MARK: Accessibility values

    private static func copy(_ node: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func axElement(_ node: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(node, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(_ node: AXUIElement) -> [AXUIElement]? {
        copy(node, kAXChildrenAttribute) as? [AXUIElement]
    }

    private static func string(_ node: AXUIElement, _ attribute: String) -> String? {
        let value = copy(node, attribute) as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private static func urlValue(_ node: AXUIElement, _ attribute: String) -> URL? {
        guard let value = copy(node, attribute) else { return nil }
        if CFGetTypeID(value) == CFURLGetTypeID() { return (value as! CFURL) as URL }
        return (value as? String).flatMap(URL.init(string:))
    }
}
