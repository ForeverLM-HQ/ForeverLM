import AppKit

/// App-wide presenter for the system open/save panels.
///
/// Constructing the session's first `NSOpenPanel`/`NSSavePanel` blocks the main
/// thread inside AppKit's `_initBridgeAndStuff`: the sandbox's remote panel
/// service (`com.apple.appkit.xpc.openAndSavePanelService`) has to spawn and
/// check in before `init` returns, which ui-stall samples showed taking >1s —
/// a beachball when it happens inside a button action. AppKit requires panels
/// to be created and presented on the main thread, so the spawn cost cannot be
/// moved off-main; what this type does is contain it:
///
/// - One panel of each kind is created lazily and cached for the process
///   lifetime, so the service spawn is paid at most once per launch instead of
///   on every click at every call site.
/// - Presentation uses `begin(completionHandler:)`, not `runModal()`, so there
///   is no nested modal run-loop session on the main thread.
/// - Both entry points are `async`. Call them from a `Task` started in the
///   user-action handler: the hop onto the main-actor job queue lands after the
///   current turn's frame commit, so any "opening…" feedback the caller set is
///   on screen before a cold panel init can block.
///
/// If a stall sample ever points here, it is the once-per-launch service spawn,
/// not a regression at the call site.
@MainActor
enum FilePanel {
    private static var cachedOpenPanel: NSOpenPanel?
    private static var cachedSavePanel: NSSavePanel?
    /// The panel currently on screen, if any. Panels are cached and shared, so
    /// a second request while one is up fronts the existing panel and reports
    /// cancellation rather than reconfiguring it out from under the first
    /// caller.
    private static weak var activePanel: NSSavePanel?

    /// Presents the open panel and returns the chosen URLs (empty on cancel).
    static func open(_ configure: (NSOpenPanel) -> Void) async -> [URL] {
        if let active = activePanel {
            active.makeKeyAndOrderFront(nil)
            return []
        }
        let panel = sharedOpenPanel()
        resetCommonState(panel)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        configure(panel)
        let response = await present(panel)
        return response == .OK ? panel.urls : []
    }

    /// Presents the save panel and returns the chosen destination (nil on cancel).
    static func save(_ configure: (NSSavePanel) -> Void) async -> URL? {
        if let active = activePanel {
            active.makeKeyAndOrderFront(nil)
            return nil
        }
        let panel = sharedSavePanel()
        resetCommonState(panel)
        configure(panel)
        let response = await present(panel)
        return response == .OK ? panel.url : nil
    }

    private static func present(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        activePanel = panel
        defer { activePanel = nil }
        return await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
    }

    /// Cold init here is the once-per-launch panel-service spawn (see type doc).
    private static func sharedOpenPanel() -> NSOpenPanel {
        if let cached = cachedOpenPanel { return cached }
        let panel = NSOpenPanel()
        cachedOpenPanel = panel
        return panel
    }

    private static func sharedSavePanel() -> NSSavePanel {
        if let cached = cachedSavePanel { return cached }
        let panel = NSSavePanel()
        cachedSavePanel = panel
        return panel
    }

    /// The cached panel keeps whatever the previous caller configured, so every
    /// property any call site sets must be restored to its default here before
    /// the next caller's `configure` runs. Extend this when a call site starts
    /// setting a new property.
    private static func resetCommonState(_ panel: NSSavePanel) {
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = false
        panel.message = ""
        panel.prompt = nil
        panel.nameFieldStringValue = ""
    }
}
