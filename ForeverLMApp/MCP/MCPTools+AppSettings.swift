import Foundation
import AppKit

// MARK: - Every Settings control, from a chat
//
// The product owner, 2026-09-11: "setting any of the settings needs to be possible via
// MCP as well"; 2026-09-22, after an audit found most of the Settings window
// out of reach: "that needs to be the case". The in-app chat is handed the
// whole MCP catalog (`StudioAssistantSession.makeManager`), so a tool here
// reaches it and Claude/ChatGPT alike.
//
// Shape:
// - `get_app_settings` / `set_app_setting` are one catalog of the plain
//   preferences — a switch, a picker, a slider — each entry reading and
//   writing through the exact setter its pane calls, with the options that
//   pane offers. Panes that already had a dedicated pair (Sources, Day,
//   Memory, AI Models, own key, automatic audio) keep it; the catalog lists
//   them under `dedicated_tools` so one read shows the whole window.
// - `run_settings_action` is the pane buttons that do something once
//   (Sync now, Prepare now, Check now, …).
// - `open_settings` is for what a chat must not do for the learner — a
//   sign-in, a payment, Apple's sharing sheet — and shows the pane instead.
// - The account and plugin tools (teams, disconnects, feeds, calendars, chat
//   model list, spending limit) live beside it in their own files and are
//   gathered by `settingsParityToolDefs` / `executeSettingsParityTool`.

/// The app's one Studio view model and account model, for the few settings
/// whose pane calls an instance method rather than a static setter. Set once
/// when the first Studio window appears; nil before that, which a tool
/// reports rather than guesses around.
@MainActor
enum AppModelBridge {
    static weak var studio: StudioViewModel?
    static weak var account: ManagedAIAccountModel?

    static func requireStudio() throws -> StudioViewModel {
        guard let studio else {
            throw MCPError.invalidInput("ForeverLM has no Studio window open yet; open one and try again.")
        }
        return studio
    }

    static func requireAccount() throws -> ManagedAIAccountModel {
        guard let account else {
            throw MCPError.invalidInput("ForeverLM has no Studio window open yet; open one and try again.")
        }
        return account
    }
}

/// One Settings control as a chat sees it.
struct AppSettingEntry: @unchecked Sendable {
    enum Reach: String { case account, thisMac = "this_mac" }

    enum Kind {
        case boolean
        case number(min: Double, max: Double, step: Double?)
        case choice
        case text
        case stringList
    }

    let id: String
    let pane: String
    let title: String
    let detail: String
    let reach: Reach
    let kind: Kind
    /// The preference keys `write` sets, whichever provider is stored; for a
    /// family (a voice's rating) the key it sets now. Never read at run time:
    /// `SettingsCatalogTests` holds them to `schema/generated/settings-catalog.json`,
    /// which the hosted MCP writes Setting records by, and `reach` to
    /// `SyncedPreferenceKeys`.
    var preferenceKeys: [String] = []
    /// `[{value, label, detail?}]` — exactly what the pane's picker lists.
    var options: (@MainActor () async -> [[String: Any]])? = nil
    let read: @MainActor () async -> Any
    /// Throws `MCPError.invalidInput` for a value the pane would not accept.
    let write: @MainActor (Any) async throws -> Void

    @MainActor
    func payload(includeOptions: Bool) async -> [String: Any] {
        var row: [String: Any] = [
            "id": id,
            "pane": pane,
            "title": title,
            "detail": detail,
            "reach": reach.rawValue,
            "value": await read(),
        ]
        switch kind {
        case .boolean: row["type"] = "boolean"
        case let .number(min, max, step):
            row["type"] = "number"
            row["minimum"] = min
            row["maximum"] = max
            if let step { row["step"] = step }
        case .choice: row["type"] = "choice"
        case .text: row["type"] = "text"
        case .stringList: row["type"] = "string_list"
        }
        if includeOptions, let options {
            row["options"] = await options()
        }
        return row
    }
}

extension AppSettingEntry {
    // Value coercion shared by every entry's `write`.

    static func bool(_ value: Any, _ id: String) throws -> Bool {
        if let bool = value as? Bool { return bool }
        if let text = value as? String {
            switch text.lowercased() {
            case "true", "on", "yes": return true
            case "false", "off", "no": return false
            default: break
            }
        }
        throw MCPError.invalidInput("\(id) takes true or false.")
    }

    static func number(_ value: Any, _ id: String) throws -> Double {
        // Not `!(value is Bool)`: a JSON 0 or 1 bridges to Bool on Darwin.
        if let number = ToolArgumentNumber.value(value) { return number }
        if let text = value as? String, let number = Double(text) { return number }
        throw MCPError.invalidInput("\(id) takes a number.")
    }

    static func string(_ value: Any, _ id: String) throws -> String {
        if let text = value as? String { return text }
        throw MCPError.invalidInput("\(id) takes a string.")
    }

    static func strings(_ value: Any, _ id: String) throws -> [String] {
        if let list = value as? [String] { return list }
        if let list = value as? [Any] {
            let strings = list.compactMap { $0 as? String }
            if strings.count == list.count { return strings }
        }
        throw MCPError.invalidInput("\(id) takes a list of strings.")
    }

    /// A choice must be one the pane offers.
    @MainActor
    func requireOption(_ value: Any) async throws -> String {
        let choice = try Self.string(value, id)
        guard let options else { return choice }
        let offered = await options().compactMap { $0["value"] as? String }
        guard offered.contains(choice) else {
            throw MCPError.invalidInput("\(id) takes one of: \(offered.joined(separator: ", ")).")
        }
        return choice
    }
}

extension MCPDataStore {

    // MARK: - The catalog

    /// Every entry, pane by pane in the Settings sidebar's order. The voice
    /// entries live in `MCPTools+VoiceSettings.swift`.
    @MainActor
    static func appSettingsCatalog() -> [AppSettingEntry] {
        accountSettingEntries()
            + appearanceSettingEntries()
            + quickAssistantSettingEntries()
            + activitySettingEntries()
            + memoryReviewLayoutSettingEntries()
            + scheduledTaskSettingEntries()
            + backgroundAISettingEntries()
            + voiceSettingEntries()
            + imageSettingEntries()
            // Generation 1 has no notebook cover to draw, so the switch is
            // neither listed nor synced there (schema v2 D40, D53).
            + (ForeverLMRuntimeIdentity.syncGeneration == .two ? notebookCoverSettingEntries() : [])
            + videoSettingEntries()
            + sourceAndPluginSettingEntries()
            + webLinkSettingEntries()
            + viewSettingEntries()
            + (JournalWatch.isEnabled ? feedSettingEntries() : [])
            // Admin only: absent for everyone else, so `get_app_settings` never
            // lists it and `set_app_setting` answers "No setting …" as for any
            // id it does not know.
            + (ScreenRecordMode.isAvailable ? screenRecordSettingEntries() : [])
    }

    /// Panes with a pair of their own; `get_app_settings` points at them so a
    /// caller never concludes a pane is unreachable.
    static let dedicatedSettingsTools: [[String: String]] = [
        ["pane": "Sources › Search & AI", "read": "get_source_settings", "write": "set_source_settings"],
        ["pane": "Chat › Day", "read": "get_day_settings", "write": "set_day_settings"],
        ["pane": "Background › Memory review", "read": "get_memory_review_settings", "write": "set_memory_review_settings"],
        ["pane": "Background › Models (Text-only, Multimodal, Tasks), a card's ⋯ for its host; Data & Privacy", "read": "get_ai_task_settings", "write": "set_ai_task_settings"],
        ["pane": "Chat › Models (which models the chat picker offers)", "read": "get_ai_task_settings", "write": "set_chat_model_offered"],
        ["pane": "AI Usage › API keys", "read": "get_own_router_key", "write": "set_own_router_key"],
        ["pane": "Billing › Plan; AI Usage › Spending (monthly spending limit)", "read": "get_billing_settings", "write": "set_billing_settings"],
        ["pane": "Sources sidebar › bulk re-queues waiting for a decision", "read": "get_background_ai_jobs", "write": "decide_background_ai_job"],
        ["pane": "Automatic audio (no pane)", "read": "get_automatic_audio_settings", "write": "set_automatic_audio_settings"],
        ["pane": "Plugins › Calendar (the Mac's Calendar, which is the day)", "read": "get_calendar_settings", "write": "set_calendar_settings"],
        ["pane": "Data & Privacy › Notes about your work (reading, correcting and forgetting notes)", "read": "list_working_notes", "write": "save_working_note, update_working_note, forget_working_note"],
        ["pane": "Data & Privacy › Teams", "read": "list_teams", "write": "create_team, rename_team, delete_team, leave_team, open_team_library, get_team_invitation_link"],
        ["pane": "Plugins › connected accounts", "read": "get_plugin_connections", "write": "disconnect_plugin, set_slack_channel_enabled"],
        ["pane": "Plugins › YouTube", "read": "get_plugin_connections", "write": "set_connector_auto_import, follow_youtube_liked_videos, follow_youtube_foreverlm_playlist, follow_youtube_channel, unfollow_youtube_channel, set_youtube_channel_hidden"],
        ["pane": "Feeds › followed journals", "read": "list_journal_feeds", "write": "follow_journal_feed, unfollow_journal_feed"],
        ["pane": "Sources › Zoom recordings", "read": "list_unconverted_zoom_recordings", "write": "resolve_unconverted_zoom_recording"],
    ].filter { JournalWatch.isEnabled || $0["pane"]?.hasPrefix("Feeds") != true }

    /// What stays in the window on purpose: each needs the learner's own
    /// hand — a browser consent, a payment, a macOS permission sheet. A
    /// plugin is connected in the Plugins place, which `open_settings`
    /// opens for its id as it does a pane.
    static let settingsOnlyInTheWindow: [[String: String]] = [
        ["control": "Sign in with Apple", "why": "An Apple sign-in sheet only the learner can answer.", "open_settings": "billing"],
        ["control": "Connect a plugin (X, YouTube, Google Drive, Slack, GitHub), in the Plugins place on the icon strip", "why": "The provider's consent page in a browser.", "open_settings": "plugins"],
        ["control": "Unlock MCP, or change or cancel a monthly plan", "why": "Stripe Checkout or the Stripe billing portal.", "open_settings": "billing"],
        ["control": "Manage team members", "why": "Apple's iCloud sharing sheet.", "open_settings": "data_privacy"],
        ["control": "Remove old iCloud data", "why": "It deletes the old iCloud library for good, so the learner confirms in its dialog after reading what remains; get_sync_status says when it is available.", "open_settings": "data_privacy"],
    ]

    func getAppSettings(pane: String?, settingID: String?) async throws -> String {
        let rows: [[String: Any]] = try await Self.appSettingsRows(pane: pane, settingID: settingID)
        var payload: [String: Any] = [
            "settings": rows,
            "how_to_change": "set_app_setting with setting (an id below) and value. A choice takes one of its options' value; a string_list takes the whole list.",
        ]
        if settingID == nil {
            payload["dedicated_tools"] = Self.dedicatedSettingsTools
            payload["only_in_the_settings_window"] = Self.settingsOnlyInTheWindow
            payload["actions"] = Self.settingsActionIDs
        }
        return try jsonString(payload)
    }

    @MainActor
    private static func appSettingsRows(pane: String?, settingID: String?) async throws -> [[String: Any]] {
        var entries = appSettingsCatalog()
        if let settingID, !settingID.isEmpty {
            entries = entries.filter { $0.id == settingID }
            guard !entries.isEmpty else {
                throw MCPError.notFound("No setting \(settingID). Call get_app_settings without setting for the list.")
            }
        }
        if let pane, !pane.trimmingCharacters(in: .whitespaces).isEmpty {
            let needle = pane.lowercased()
            entries = entries.filter { $0.pane.lowercased().contains(needle) }
        }
        var rows: [[String: Any]] = []
        for entry in entries {
            rows.append(await entry.payload(includeOptions: true))
        }
        return rows
    }

    func setAppSetting(settingID: String?, value: Any?) async throws -> String {
        guard let settingID = settingID?.trimmingCharacters(in: .whitespacesAndNewlines), !settingID.isEmpty else {
            throw MCPError.invalidInput("Pass setting, an id from get_app_settings.")
        }
        guard let value, !(value is NSNull) else {
            throw MCPError.invalidInput("Pass value for \(settingID).")
        }
        let row = try await Self.applyAppSetting(settingID: settingID, value: value)
        await PreferenceStore.flushPendingWrites()
        return try jsonString(row)
    }

    @MainActor
    private static func applyAppSetting(settingID: String, value: Any) async throws -> [String: Any] {
        guard let entry = appSettingsCatalog().first(where: { $0.id == settingID }) else {
            throw MCPError.notFound("No setting \(settingID). Call get_app_settings for the list.")
        }
        let before = await entry.read()
        try await entry.write(value)
        var row = await entry.payload(includeOptions: false)
        row["changed"] = !plistValuesEqual(before, row["value"] as Any)
        row["settings_pane"] = "Settings › \(entry.pane)"
        return row
    }

    private static func plistValuesEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        (lhs as? NSObject)?.isEqual(rhs) ?? false
    }

    // MARK: - Data & Privacy › Your name

    @MainActor
    private static func accountSettingEntries() -> [AppSettingEntry] {
        [
            AppSettingEntry(
                id: "account.display_name",
                pane: "Data & Privacy › Your name",
                title: "Name",
                detail: "The name the account button, the account menu and the chat greeting show, on every Mac and the web. It starts as the Apple Account name. A blank name, or one longer than \(MacAccountUser.maximumDisplayNameLength) characters, is refused. Ask the learner before renaming them.",
                reach: .account,
                kind: .text,
                preferenceKeys: [MacAccountUser.displayNamePreferenceKey],
                read: { MacAccountUser.fullName ?? "" },
                write: { value in
                    let name = try AppSettingEntry.string(value, "account.display_name")
                    guard MacAccountUser.setDisplayName(name) else {
                        throw MCPError.invalidInput("account.display_name takes a name of 1 to \(MacAccountUser.maximumDisplayNameLength) characters.")
                    }
                }
            ),
            AppSettingEntry(
                id: "account.about_you",
                pane: "Add Textbook › About you",
                title: "About you",
                detail: "Where the learner is coming from, in their own words: their background, what they know well, what is new to them. Every course tailors to it: the readings add_textbook_to_course chooses leave out what this says they already know. Up to \(LearnerProfile.maximumAboutYouLength) characters; an empty string clears it. Write the learner's words, or words they approved, never a guess about them.",
                reach: .account,
                kind: .text,
                preferenceKeys: [LearnerProfile.aboutYouPreferenceKey],
                read: { LearnerProfile.aboutYou },
                write: { value in
                    let text = try AppSettingEntry.string(value, "account.about_you")
                    guard LearnerProfile.setAboutYou(text) else {
                        throw MCPError.invalidInput("account.about_you takes at most \(LearnerProfile.maximumAboutYouLength) characters.")
                    }
                }
            ),
            AppSettingEntry(
                id: "think_first.level",
                pane: "Chat › Think first",
                title: "Ask for your own line first",
                detail: "Think first for the whole library: before ForeverLM shows what it wrote about the learner's material, it asks for the learner's own line, keeps it in their words and shows the two side by side, never graded. off (the default); summariesAndStudio asks before a source's gist in the Reader's Levels, a Studio report and Find directions; alsoChat also asks for a guess before a question in a notebook's chat. Skip is one click and costs nothing. A notebook may have its own level (update_notebook think_first; get_notebook shows it). Ask the learner before changing it.",
                reach: .account,
                kind: .choice,
                preferenceKeys: [ThinkFirst.levelKey],
                options: {
                    ThinkFirstLevel.allCases.map { ["value": $0.rawValue, "label": $0.title] }
                },
                read: { ThinkFirst.libraryLevel().rawValue },
                write: { value in
                    let raw = try AppSettingEntry.string(value, "think_first.level")
                    guard let level = ThinkFirstLevel(rawValue: raw) else {
                        throw MCPError.invalidInput("think_first.level takes one of: \(ThinkFirstLevel.allCases.map(\.rawValue).joined(separator: ", ")).")
                    }
                    ThinkFirst.setLibraryLevel(level)
                }
            ),
            AppSettingEntry(
                id: "working_notes.enabled",
                pane: "Data & Privacy › Notes about your work",
                title: "Keep notes about my work",
                detail: "Whether ForeverLM keeps notes about how the learner is working: written when the learner adds one, or asks ForeverLM to remember something; handed, the nearest few, to every chat they open. Kept in the background, as a memory and never as a Doc; the learner reviews them in Settings › Data & Privacy › Notes about your work, and list_working_notes reads them. On by default. Off, nothing new is written or sent, and the notes that exist stay until they are forgotten (list_working_notes, forget_working_note). It follows the account to the learner's other Macs. Ask the learner before switching it.",
                reach: .account,
                kind: .boolean,
                preferenceKeys: [WorkingNotesPreference.enabledKey],
                read: { WorkingNotesPreference.isEnabled },
                write: { WorkingNotesPreference.setEnabled(try AppSettingEntry.bool($0, "working_notes.enabled")) }
            ),
            AppSettingEntry(
                id: "account.show_comp_crown",
                pane: "Data & Privacy › Your name (the crown has no pane)",
                title: "Show the crown by your name",
                detail: "Whether an account whose AI usage ForeverLM pays for shows it: the crown in the web's account footer and the Mac account menu's \"Usage is paid for\" row (the Mac's account button carries no crown since 2026-10-06). On by default; off hides both on every client, for screenshots and recordings. It shows nothing on an account that pays for itself either way, and AI Usage still says who pays.",
                reach: .account,
                kind: .boolean,
                preferenceKeys: [MacAccountUser.showsCompCrownPreferenceKey],
                read: { MacAccountUser.showsCompCrown },
                write: { MacAccountUser.setShowsCompCrown(try AppSettingEntry.bool($0, "account.show_comp_crown")) }
            ),
            AppSettingEntry(
                id: "mcp.show_status_light",
                pane: "MCP",
                title: "Show the MCP status light in the account button",
                detail: "Whether the account button carries a dot while assistants cannot reach this Mac over MCP: amber while connecting, red while offline or failed. Once connected, or while the learner has turned assistant integrations off, it draws nothing (since 2026-10-06; until then a green dot showed at all times), and the account menu's MCP row still says how the connection stands. On by default; it follows the account to the learner's other Macs. The switch sits under the connection card in Settings › MCP; it had no pane from 2026-09-24 to 2026-09-28.",
                reach: .account,
                kind: .boolean,
                preferenceKeys: [AssistantIntegrationSettings.statusLightVisibleKey],
                read: { UserDefaults.standard.object(forKey: AssistantIntegrationSettings.statusLightVisibleKey) as? Bool ?? true },
                write: { PreferenceStore.set(try AppSettingEntry.bool($0, "mcp.show_status_light"), forKey: AssistantIntegrationSettings.statusLightVisibleKey) }
            ),
            AppSettingEntry(
                id: "updates.beta_releases",
                pane: "Settings sidebar › Beta releases",
                title: "Get beta releases",
                detail: "Whether the learner's Macs are offered beta builds: releases published to the update feed's beta channel before they reach everyone. It also shows the features still in beta, the Canvas and the Atlas for now, with their MCP tools; while it is off they are hidden. Off by default; it follows the account to the learner's other Macs, and a Mac checks for updates as soon as it changes. Turning it off never downgrades: a Mac on a beta stays on it until a production release passes it. Ask the learner before signing them up.",
                reach: .account,
                kind: .boolean,
                preferenceKeys: [BetaReleases.preferenceKey],
                read: { BetaReleases.isSignedUp },
                write: { BetaReleases.setSignedUp(try AppSettingEntry.bool($0, "updates.beta_releases")) }
            ),
        ]
    }

    // MARK: - Sources › Links

    /// Settings › Sources › Links (`WebLinkOpening`).
    @MainActor
    private static func webLinkSettingEntries() -> [AppSettingEntry] {
        [
            AppSettingEntry(
                id: "links.open_in",
                pane: "Sources › Links",
                title: "Open links in",
                detail: "Where a web link the learner clicks in ForeverLM opens on this Mac: browserPane (the default) opens it in a tab of ForeverLM's own Browser pane, where Add to Sources files the page in the library; defaultBrowser hands it to the Mac's default browser (Safari when ForeverLM is the default). A link to a page the library already holds still opens the saved source, and a YouTube video still plays in the Reader. Links of other apps (mailto:, zoommtg:) always go to macOS. This Mac only; it never syncs. Ask the learner before changing it.",
                reach: .thisMac,
                kind: .choice,
                preferenceKeys: [WebLinkOpening.preferenceKey],
                options: {
                    WebLinkDestination.allCases.map { ["value": $0.rawValue, "label": $0.title] }
                },
                read: { WebLinkOpening.destination.rawValue },
                write: { value in
                    let raw = try AppSettingEntry.string(value, "links.open_in")
                    guard let destination = WebLinkDestination(rawValue: raw) else {
                        throw MCPError.invalidInput("links.open_in takes one of: \(WebLinkDestination.allCases.map(\.rawValue).joined(separator: ", ")).")
                    }
                    WebLinkOpening.setDestination(destination)
                }
            ),
        ]
    }

    // MARK: - Tasks › Keep this Mac awake

    /// The Tasks pane's ⋯ › Keep This Mac Awake for Tasks (`ScheduledTaskWakePolicy`).
    @MainActor
    private static func scheduledTaskSettingEntries() -> [AppSettingEntry] {
        [
            AppSettingEntry(
                id: "tasks.keep_mac_awake",
                pane: "Tasks (the pane's ⋯ › Keep This Mac Awake for Tasks; not in Settings)",
                title: "Keep this Mac awake for tasks",
                detail: "While on and plugged in, this Mac does not idle to sleep when a scheduled task is due within the next 12 hours, so a task set for the night runs at its time rather than when someone next wakes the Mac. The display still sleeps; closing a laptop's lid still sleeps it; on battery the Mac sleeps as usual. A run in progress always keeps the Mac awake, whatever this says. Off by default. This Mac only; it never syncs.",
                reach: .thisMac,
                kind: .boolean,
                preferenceKeys: [ScheduledTaskWakePolicy.keepMacAwakeKey],
                read: { ScheduledTaskRunner.shared.keepsMacAwake },
                write: { ScheduledTaskRunner.shared.setKeepsMacAwake(try AppSettingEntry.bool($0, "tasks.keep_mac_awake")) }
            ),
        ]
    }

    // MARK: - Data & Privacy › Screen recording (admin only)

    /// Screen record mode, for the overnight recording run and any filmed
    /// connector take: the same device-local switch and Notebook the Data &
    /// Privacy pane's Screen recording group writes (`ScreenRecordMode`). Listed only
    /// for an account the proxy calls admin; see `appSettingsCatalog`.
    @MainActor
    private static func screenRecordSettingEntries() -> [AppSettingEntry] {
        let notebookOptions: @MainActor () async -> [[String: Any]] = {
            let notebooks = (AppModelBridge.studio?.learningGoals ?? [])
                .filter { $0.isNotebook && !$0.isArchived && $0.teamID == nil }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            var options: [[String: Any]] = [["value": "none", "label": "None"]]
                + notebooks.map { ["value": $0.id, "label": $0.title] }
            // The stored choice is always offered back, even before a Studio
            // window has loaded the Notebooks, so a read never reports a value
            // its own options lack.
            if let stored = ScreenRecordMode.notebookID, !notebooks.contains(where: { $0.id == stored }) {
                options.append(["value": stored, "label": "Notebook not loaded"])
            }
            return options
        }
        return [
            AppSettingEntry(
                id: "recording.screen_record_mode",
                pane: "Data & Privacy › Screen recording",
                title: "Screen record mode",
                detail: "While on, every list, search, chat pick, the Now chip's calendar and memory review on this Mac, and every MCP listing, shows only the recording Notebook (recording.notebook_id), its sources (with recording.library_sources, the library's public sources too), public Reading List pages and X bookmarks added during the take, the public sources the learner adds during the take to a Notebook or Goal made during it (and the older public library sources on recording.source_ids), meeting folders on recording.meeting_group_ids, the images on recording.image_ids, and only chats, Pages, Sites, Animations, Goals, Ideas, walkthroughs and cards created after the mode was turned on, even within the recording Notebook. A new private meeting, Drive page, local upload, pasted source, podcast subscription, followed video or plugin source does not earn a pass merely by syncing during the take. Other Notebooks, every other old chat and Page, other images, meetings, email and usage stay off screen. Turning it on stamps that moment; turning it on again while on keeps it. Nothing is deleted or hidden in the library. This Mac only; it never syncs.",
                reach: .thisMac,
                kind: .boolean,
                preferenceKeys: [ScreenRecordMode.enabledKey, ScreenRecordMode.cutoffKey],
                read: { ScreenRecordMode.isStoredOn },
                write: { ScreenRecordMode.setEnabled(try AppSettingEntry.bool($0, "recording.screen_record_mode")) }
            ),
            AppSettingEntry(
                id: "recording.notebook_id",
                pane: "Data & Privacy › Screen recording",
                title: "Show only this Notebook's sources",
                detail: "The Notebook whose sources stay on screen in screen record mode, by id (list_notebooks lists every Notebook while the mode is off). Use a curated Notebook as the exact source list for a take. \"none\" leaves new public Reading List pages, X bookmarks and work made during the recording. The Notebook itself always shows.",
                reach: .thisMac,
                kind: .choice,
                preferenceKeys: [ScreenRecordMode.notebookIDKey],
                options: notebookOptions,
                read: { ScreenRecordMode.notebookID ?? "none" },
                write: { value in
                    let choice = try AppSettingEntry.string(value, "recording.notebook_id")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if choice.isEmpty || choice == "none" {
                        ScreenRecordMode.setNotebookID(nil)
                        return
                    }
                    guard AppModelBridge.studio != nil else {
                        throw MCPError.invalidInput("ForeverLM has no Studio window open yet; open one and try again.")
                    }
                    let offered = await notebookOptions().compactMap { $0["value"] as? String }
                    guard offered.contains(choice) else {
                        throw MCPError.invalidInput("recording.notebook_id takes a Notebook id from this library's own Notebooks, or none.")
                    }
                    ScreenRecordMode.setNotebookID(choice)
                }
            ),
            AppSettingEntry(
                id: "recording.library_sources",
                pane: "Data & Privacy › Screen recording",
                title: "Also show the library's public sources",
                detail: "In screen record mode, also show every public source in the library beside the recording Notebook's: published papers, articles, podcast episodes, books, courses and videos on public video sites. Meetings, X posts, uploads without a web address and pages on private hosts (Zoom, Drive, Slack, Notion …) stay off screen, and so do the learner's own chats, Pages, Goals and other Notebooks. This Mac only; it never syncs.",
                reach: .thisMac,
                kind: .boolean,
                preferenceKeys: [ScreenRecordMode.librarySourcesKey],
                read: { ScreenRecordMode.showsLibrarySources },
                write: { ScreenRecordMode.setShowsLibrarySources(try AppSettingEntry.bool($0, "recording.library_sources")) }
            ),
            AppSettingEntry(
                id: "recording.image_ids",
                pane: "Data & Privacy › Screen recording",
                title: "Images kept on screen",
                detail: "Image ids (from list_images while the mode is off) that screen record mode shows although they were drawn before it went on. An image carries no Notebook or source, so without this only pictures drawn during the recording show. Pass the whole list; [] clears it. This Mac only; it never syncs.",
                reach: .thisMac,
                kind: .stringList,
                preferenceKeys: [ScreenRecordMode.imageIDsKey],
                read: { ScreenRecordMode.imageIDs },
                write: { ScreenRecordMode.setImageIDs(try AppSettingEntry.strings($0, "recording.image_ids")) }
            ),
            AppSettingEntry(
                id: "recording.source_ids",
                pane: "Data & Privacy › Screen recording",
                title: "Older public sources kept on screen",
                detail: "Source ids (from list_sources while the mode is off) of public library sources that screen record mode shows although the library held them before it went on: a book or talk a from-scratch take files into its own Notebook from the library instead of importing it. Only a source with a public address (or a book) shows; a meeting, upload or private host never does. Every other older source stays off screen, filed into a take Notebook or not, except the recording library built into the app (ScreenRecordLibrary: a few whole books and a themed set of papers, articles, podcast episodes, videos and X posts), which always shows; this list adds to it. Pass the whole list; [] clears it. This Mac only; it never syncs.",
                reach: .thisMac,
                kind: .stringList,
                preferenceKeys: [ScreenRecordMode.sourceIDsKey],
                read: { ScreenRecordMode.sourceIDs },
                write: { ScreenRecordMode.setSourceIDs(try AppSettingEntry.strings($0, "recording.source_ids")) }
            ),
            AppSettingEntry(
                id: "recording.meeting_group_ids",
                pane: "Data & Privacy › Screen recording",
                title: "Meeting folders kept on screen",
                detail: "Meeting folder ids (group_id from list_meeting_groups while the mode is off) whose sessions screen record mode shows. Every other meeting, and every folder with no session on screen, stays off. Pass the whole list; [] clears it. This Mac only; it never syncs.",
                reach: .thisMac,
                kind: .stringList,
                preferenceKeys: [ScreenRecordMode.meetingGroupIDsKey],
                read: { ScreenRecordMode.meetingGroupIDs },
                write: { ScreenRecordMode.setMeetingGroupIDs(try AppSettingEntry.strings($0, "recording.meeting_group_ids")) }
            ),
        ]
    }

    // MARK: - Appearance

    @MainActor
    private static func appearanceSettingEntries() -> [AppSettingEntry] {
        [
            AppSettingEntry(
                id: "appearance.thinking_mark_speed",
                pane: "Thinking mark (no pane)",
                title: "Thinking mark speed",
                detail: "How fast the ForeverLM mark loops while a reply is on the way, as a multiple of the normal pace (1). It holds still under Reduce Motion whatever the value.",
                reach: .thisMac,
                kind: .number(min: LoadingIndicatorSpeed.minimum, max: LoadingIndicatorSpeed.maximum, step: LoadingIndicatorSpeed.step),
                preferenceKeys: [LoadingIndicatorSpeed.key],
                read: { LoadingIndicatorSpeed.clamped(UserDefaults.standard.object(forKey: LoadingIndicatorSpeed.key) as? Double) },
                write: { value in
                    let speed = try AppSettingEntry.number(value, "appearance.thinking_mark_speed")
                    guard LoadingIndicatorSpeed.range.contains(speed) else {
                        throw MCPError.invalidInput("appearance.thinking_mark_speed runs from \(LoadingIndicatorSpeed.minimum) to \(LoadingIndicatorSpeed.maximum).")
                    }
                    UserDefaults.standard.set(LoadingIndicatorSpeed.clamped(speed), forKey: LoadingIndicatorSpeed.key)
                }
            ),
        ]
    }

    // MARK: - Quick assistant

    /// The shortcut that brings up the quick assistant over any app
    /// (docs/quick-assistant-design.md): the value Settings › Chat ›
    /// Quick assistant records, written through the same `choose`.
    @MainActor
    private static func quickAssistantSettingEntries() -> [AppSettingEntry] {
        [
            AppSettingEntry(
                id: "quick_assistant.shortcut",
                pane: "Chat › Quick assistant",
                title: "Shortcut",
                detail: "The keys that bring up ForeverLM's quick assistant over any app: a bar that listens, sends what was said to a new ForeverLM chat with every app tool, and shows the answer above it. Modifiers and one key joined by +, such as ctrl+option+space (the default; ctrl+option+shift+space in ForeverLM Dev) or cmd+shift+k; ctrl, option or cmd must be held unless the key is f1–f20. off turns it off. Pick keys no other app on this Mac uses: macOS does not stop two apps taking the same ones. This Mac only; it never syncs.",
                reach: .thisMac,
                kind: .text,
                preferenceKeys: [QuickAssistantShortcut.storageKey],
                read: { QuickAssistantShortcut.stored()?.serialized ?? QuickAssistantShortcut.offValue },
                write: { value in
                    let text = try AppSettingEntry.string(value, "quick_assistant.shortcut")
                    do {
                        QuickAssistantHotKey.shared.choose(try QuickAssistantShortcut.parse(text))
                    } catch {
                        throw MCPError.invalidInput("quick_assistant.shortcut: \(error.localizedDescription)")
                    }
                }
            ),
        ]
    }

    // MARK: - Activity

    /// The Activity pane's By Source / History choice. It sits in the
    /// pane's ⋯, not the Settings window, but it is a remembered preference
    /// all the same (product owner, 2026-09-23: "yes add it to MCP too").
    @MainActor
    private static func activitySettingEntries() -> [AppSettingEntry] {
        [
            AppSettingEntry(
                id: "activity.layout",
                pane: "Activity (the pane's ⋯ › View)",
                title: "View",
                detail: "How the Activity pane draws the log; the Day pane is the calendar alone and has no views. by_source: the day's log, one row per source, chat or Doc, its sittings as bars along the hours the log covers, glances counted in the totals line only. history: every day's time spent, newest first, a month at a time.",
                reach: .thisMac,
                kind: .choice,
                preferenceKeys: [DayActivityLayout.storageKey],
                options: {
                    DayActivityLayout.allCases.map { layout in
                        ["value": layout.mcpValue, "label": layout.title] as [String: Any]
                    }
                },
                read: { DayActivityLayout.stored.mcpValue },
                write: { value in
                    let raw = try AppSettingEntry.string(value, "activity.layout")
                    guard let layout = DayActivityLayout.allCases.first(where: { $0.mcpValue == raw }) else {
                        throw MCPError.invalidInput("activity.layout takes one of: \(DayActivityLayout.allCases.map(\.mcpValue).joined(separator: ", ")).")
                    }
                    UserDefaults.standard.set(layout.rawValue, forKey: DayActivityLayout.storageKey)
                }
            ),
        ]
    }

    // MARK: - Memory review layout

    /// Cards or conversation for the day's memory review. It sits in the
    /// review chat's ⋯ menu, not Settings › Background › Memory review, whose own pair
    /// (`get_memory_review_settings`) covers what the review asks about.
    @MainActor
    private static func memoryReviewLayoutSettingEntries() -> [AppSettingEntry] {
        [
            AppSettingEntry(
                id: "memory.review_layout",
                pane: "Memory review (the review chat's ⋯ menu)",
                title: "Show review as",
                detail: "How the Mac draws the day's memory review. cards: one exchange a card — the learner's answer, then the tutor's reply and next question — with Back and Next through the day's earlier cards. conversation: the whole transcript, as any chat. The review, its grading and what is saved are the same either way.",
                reach: .thisMac,
                kind: .choice,
                preferenceKeys: [MemoryReviewLayout.storageKey],
                options: {
                    MemoryReviewLayout.allCases.map { layout in
                        ["value": layout.mcpValue, "label": layout.title] as [String: Any]
                    }
                },
                read: { MemoryReviewLayout.stored.mcpValue },
                write: { value in
                    let raw = try AppSettingEntry.string(value, "memory.review_layout")
                    guard let layout = MemoryReviewLayout.allCases.first(where: { $0.mcpValue == raw }) else {
                        throw MCPError.invalidInput("memory.review_layout takes one of: \(MemoryReviewLayout.allCases.map(\.mcpValue).joined(separator: ", ")).")
                    }
                    UserDefaults.standard.set(layout.rawValue, forKey: MemoryReviewLayout.storageKey)
                }
            ),
        ]
    }

    // MARK: - AI Usage › Spending

    @MainActor
    private static func backgroundAISettingEntries() -> [AppSettingEntry] {
        [
            AppSettingEntry(
                id: "billing.background_daily_cap_usd",
                pane: "AI Usage › Spending",
                title: "Daily limit",
                detail: "The most background AI tasks — source clean-up, Listen preparation, metadata, idea extraction, classification and the like — may spend in one local day, in US dollars, calls paid by the learner's own OpenRouter key included. When today's spend reaches it the background drains pause until midnight and the learner is told once; chat, reviews and anything the learner starts keep working. null means off, the default; 0 turns it off. It changes what the account spends, so ask the learner before setting it.",
                reach: .account,
                kind: .number(min: 0, max: BackgroundAIDailyCap.maximumUSD, step: nil),
                preferenceKeys: [BackgroundAIDailyCap.preferenceKey],
                read: { BackgroundAIDailyCap.capUSD().map { $0 as Any } ?? NSNull() },
                write: { value in
                    if let text = value as? String, text.lowercased() == "off" {
                        BackgroundAIDailyCap.setCapUSD(nil)
                        return
                    }
                    let amount = try AppSettingEntry.number(value, "billing.background_daily_cap_usd")
                    guard amount.isFinite, amount >= 0, amount <= BackgroundAIDailyCap.maximumUSD else {
                        throw MCPError.invalidInput("billing.background_daily_cap_usd takes 0 (off) to \(Int(BackgroundAIDailyCap.maximumUSD)) dollars.")
                    }
                    BackgroundAIDailyCap.setCapUSD(amount == 0 ? nil : amount)
                }
            ),
        ]
    }

    // MARK: - Images and Videos

    @MainActor
    private static func imageSettingEntries() -> [AppSettingEntry] {
        [
            AppSettingEntry(
                id: "images.model",
                pane: "Images",
                title: "Model",
                detail: "Draws the pictures the learner asks Chat for, quiz pictures, and meeting icons: every model OpenRouter's Image API serves that draws from a prompt, read live from OpenRouter, newest first. Billed to the learner's own OpenRouter key.",
                reach: .account,
                kind: .choice,
                preferenceKeys: [MacImageGenerationSettings.modelKey],
                options: {
                    let models = (try? await ImageGenerationDirectory.modelsWithPrices()) ?? ImageGenerationCatalog.models
                    return models.map { model in
                        var option: [String: Any] = [
                            "value": model.id,
                            "label": "\(model.name) · \(model.maker)",
                            "detail": model.detail,
                            "revises_pictures": model.revisesPictures,
                        ]
                        switch model.price {
                        case .perImage(let usd): option["usd_per_image"] = usd
                        case .perMegapixel(let usd): option["usd_per_megapixel"] = usd
                        case .perMillionTokens(let usd): option["usd_per_million_image_tokens"] = usd
                        case nil: break
                        }
                        return option
                    }
                },
                read: { MacImageGenerationSettings.model.id },
                write: { value in
                    let id = ImageGenerationCatalog.canonicalID(try AppSettingEntry.string(value, "images.model"))
                    let models = try await ImageGenerationDirectory.models()
                    guard models.contains(where: { $0.id == id }) else {
                        throw MCPError.invalidInput("images.model takes one of OpenRouter's image models: \(models.map(\.id).joined(separator: ", ")).")
                    }
                    MacImageGenerationSettings.setModel(id)
                }
            ),
            AppSettingEntry(
                id: "images.draw_meeting_icons",
                pane: "Images (no pane)",
                title: "Draw icons for meetings",
                detail: "Whether ForeverLM may pay to draw an icon for a meeting with no picture to take a thumbnail from. Off until the learner asks; every other icon source is free.",
                reach: .account,
                kind: .boolean,
                preferenceKeys: [MacImageGenerationSettings.enabledKey],
                read: { MacImageGenerationSettings.isEnabled },
                write: { MacImageGenerationSettings.setEnabled(try AppSettingEntry.bool($0, "images.draw_meeting_icons")) }
            ),
            AppSettingEntry(
                id: "images.draw_for_new_meetings",
                pane: "Images (no pane)",
                title: "Draw one for each new meeting",
                detail: "With drawing on, a meeting imported from now on gets an icon without being asked. Off means icons are drawn only on request (run_settings_action draw_missing_meeting_icons).",
                reach: .account,
                kind: .boolean,
                preferenceKeys: [MacImageGenerationSettings.automaticForNewMeetingsKey],
                read: { MacImageGenerationSettings.generatesForNewMeetings },
                write: { MacImageGenerationSettings.setGeneratesForNewMeetings(try AppSettingEntry.bool($0, "images.draw_for_new_meetings")) }
            ),
            AppSettingEntry(
                id: "images.draw_for_new_quizzes",
                pane: "Images",
                title: "Draw pictures for new quizzes",
                detail: "A course quiz gets a picture of its topic as soon as it is written, from Write Quizzes or generate_course_quizzes: one small image request per quiz on images.model; and its writer may ask for up to \(CourseQuizPictures.maximumDrawingsPerQuiz) drawings for questions no lecture slide or reading figure shows, drawn at once, one image request each. On by default. Off, a quiz is drawn only from its Draw Picture or the course's Draw Quiz Pictures, and its questions' drawings only from Add Pictures to Questions or add_course_quiz_pictures.",
                reach: .account,
                kind: .boolean,
                preferenceKeys: [MacImageGenerationSettings.automaticForNewQuizzesKey],
                read: { MacImageGenerationSettings.drawsForNewQuizzes },
                write: { MacImageGenerationSettings.setDrawsForNewQuizzes(try AppSettingEntry.bool($0, "images.draw_for_new_quizzes")) }
            ),
            AppSettingEntry(
                id: "images.icon_source",
                pane: "Images (no pane)",
                title: "Where icons come from",
                detail: "Prefer a free thumbnail clipped from the call and draw only the rest, or draw every icon. Only matters while drawing is on.",
                reach: .account,
                kind: .choice,
                preferenceKeys: [MacImageGenerationSettings.sourceKey],
                options: {
                    ImageGenerationCatalog.Source.allCases.map { ["value": $0.rawValue, "label": $0.displayName, "detail": $0.detail] }
                },
                read: { MacImageGenerationSettings.source.rawValue },
                write: { value in
                    let raw = try AppSettingEntry.string(value, "images.icon_source")
                    guard let source = ImageGenerationCatalog.Source(rawValue: raw) else {
                        throw MCPError.invalidInput("images.icon_source takes one of: \(ImageGenerationCatalog.Source.allCases.map(\.rawValue).joined(separator: ", ")).")
                    }
                    MacImageGenerationSettings.setSource(source)
                }
            ),
            AppSettingEntry(
                id: "images.icon_style",
                pane: "Images (no pane)",
                title: "Style",
                detail: "One style for every drawn icon.",
                reach: .account,
                kind: .choice,
                preferenceKeys: [MacImageGenerationSettings.styleKey],
                options: {
                    ImageGenerationCatalog.Style.allCases.map { ["value": $0.rawValue, "label": $0.displayName, "detail": $0.detail] }
                },
                read: { MacImageGenerationSettings.style.rawValue },
                write: { value in
                    let raw = try AppSettingEntry.string(value, "images.icon_style")
                    guard let style = ImageGenerationCatalog.Style(rawValue: raw) else {
                        throw MCPError.invalidInput("images.icon_style takes one of: \(ImageGenerationCatalog.Style.allCases.map(\.rawValue).joined(separator: ", ")).")
                    }
                    MacImageGenerationSettings.setStyle(style)
                }
            ),
        ]
    }

    /// Settings › Images › Notebooks, generation 2 only (schema v2 D53).
    @MainActor
    private static func notebookCoverSettingEntries() -> [AppSettingEntry] {
        [
            AppSettingEntry(
                id: "images.draw_notebook_covers",
                pane: "Images",
                title: "Draw notebook covers",
                detail: "A notebook the learner makes one at a time (New notebook, create_notebook) gets a cover, a small emoji-style picture of its subject shown in place of its emoji, drawn once on images.model when it has a name; and every active notebook without one gets one once, on the Mac that keeps the library's maintenance. One small image request each. Off by default, so a notebook keeps its emoji. Imported notebooks and a split's new notebooks get none. Off, a notebook is drawn only from Draw Cover With in its menu.",
                reach: .account,
                kind: .boolean,
                preferenceKeys: [MacImageGenerationSettings.automaticForNewNotebooksKey],
                read: { MacImageGenerationSettings.drawsNotebookCovers },
                write: { MacImageGenerationSettings.setDrawsNotebookCovers(try AppSettingEntry.bool($0, "images.draw_notebook_covers")) }
            ),
        ]
    }

    @MainActor
    private static func videoSettingEntries() -> [AppSettingEntry] {
        [
            AppSettingEntry(
                id: "videos.model",
                pane: "Videos",
                title: "Model",
                detail: "Films explainer videos scene by scene: every model OpenRouter's video API serves that films from a prompt, read live from OpenRouter, newest first. Billed to the learner's own OpenRouter key. The price is asked before a video is made. makes_sound false means a silent film with no narration; clip_seconds is how long each scene runs; usd_per_second is OpenRouter's price by resolution, absent for a model priced by video tokens. Changing it keeps the resolution when the new model offers it, else the one nearest 720p.",
                reach: .account,
                kind: .choice,
                preferenceKeys: [MacVideoGenerationSettings.modelKey],
                options: {
                    let models = (try? await VideoGenerationDirectory.models()) ?? VideoGenerationCatalog.models
                    return models.map { model in
                        var option: [String: Any] = [
                            "value": model.id,
                            "label": "\(model.name) · \(model.maker)",
                            "detail": model.detail,
                            "resolutions": model.resolutions.map(\.rawValue),
                            "clip_seconds": model.clipSeconds,
                            "priced_by_video_tokens": model.pricedByTokens,
                        ]
                        if let sound = model.makesSound { option["makes_sound"] = sound }
                        let rates = Dictionary(uniqueKeysWithValues: model.resolutions.compactMap { resolution in
                            model.usdPerSecond(at: resolution).map { (resolution.rawValue, $0) }
                        })
                        if !rates.isEmpty { option["usd_per_second"] = rates }
                        return option
                    }
                },
                read: { MacVideoGenerationSettings.model.id },
                write: { value in
                    let id = VideoGenerationCatalog.canonicalID(try AppSettingEntry.string(value, "videos.model"))
                    let models = try await VideoGenerationDirectory.models()
                    guard models.contains(where: { $0.id == id }) else {
                        throw MCPError.invalidInput("videos.model takes one of OpenRouter's video models: \(models.map(\.id).joined(separator: ", ")).")
                    }
                    MacVideoGenerationSettings.setModel(id)
                }
            ),
            AppSettingEntry(
                id: "videos.resolution",
                pane: "Videos",
                title: "Resolution",
                detail: "The resolution every scene is filmed at; the options are what the selected model offers, with its published price a second.",
                reach: .account,
                kind: .choice,
                preferenceKeys: [MacVideoGenerationSettings.resolutionKey],
                options: {
                    let model = (try? await VideoGenerationDirectory.resolve(MacVideoGenerationSettings.model)) ?? MacVideoGenerationSettings.model
                    return model.resolutions.map { resolution in
                        var option: [String: Any] = ["value": resolution.rawValue, "label": resolution.displayName]
                        if let perSecond = model.usdPerSecond(at: resolution) { option["usd_per_second"] = perSecond }
                        return option
                    }
                },
                read: { MacVideoGenerationSettings.resolution.rawValue },
                write: { value in
                    let raw = try AppSettingEntry.string(value, "videos.resolution")
                    let model = try await VideoGenerationDirectory.resolve(MacVideoGenerationSettings.model)
                    guard let resolution = model.resolutions.first(where: { $0.id == raw.lowercased() }) else {
                        throw MCPError.invalidInput("\(model.name) offers: \(model.resolutions.map(\.rawValue).joined(separator: ", ")).")
                    }
                    MacVideoGenerationSettings.setResolution(resolution)
                }
            ),
        ]
    }

    // MARK: - Sources and plugins

    @MainActor
    private static func sourceAndPluginSettingEntries() -> [AppSettingEntry] {
        [
            AppSettingEntry(
                id: "sources.reading_list_browsers",
                pane: "Sources › Reading Lists",
                title: "Reading List browsers",
                detail: "Which browsers' Reading Lists this Mac imports: any of safari, chrome, brave. Turning one on imports its list at once (as far back as sources.reading_list_import_window reaches); turning one off stops new imports and keeps what it brought in.",
                reach: .thisMac,
                kind: .stringList,
                preferenceKeys: ReadingListBrowser.allCases.map(\.enabledKey),
                read: { ReadingListBrowser.allCases.filter(\.isEnabled).map(\.rawValue) },
                write: { value in
                    let names = try AppSettingEntry.strings(value, "sources.reading_list_browsers")
                    var chosen: Set<ReadingListBrowser> = []
                    for name in names {
                        guard let browser = ReadingListBrowser(rawValue: name.lowercased()) else {
                            throw MCPError.invalidInput("sources.reading_list_browsers takes any of: \(ReadingListBrowser.allCases.map(\.rawValue).joined(separator: ", ")).")
                        }
                        chosen.insert(browser)
                    }
                    for browser in ReadingListBrowser.allCases {
                        browser.setEnabled(chosen.contains(browser))
                    }
                    AppModelBridge.studio?.readingListBrowsersDidChange()
                }
            ),
            AppSettingEntry(
                id: "sources.reading_list_import_window",
                pane: "Sources › Reading Lists",
                title: "Reading List backlog",
                detail: "How far back the Reading List import reaches, measured from the moment it is set: everything, the last 30 days, or only pages saved from now on. Pages saved before the cutoff are never imported; already-imported pages stay. Every imported page is fetched and cleaned up by AI once, so a narrower window costs less.",
                reach: .thisMac,
                kind: .choice,
                preferenceKeys: [SourceDiscovery.ReadingListImportWindow.windowKey, SourceDiscovery.ReadingListImportWindow.sinceKey],
                options: {
                    SourceDiscovery.ReadingListImportWindow.allCases.map { ["value": $0.rawValue, "label": $0.title] }
                },
                read: { (SourceDiscovery.ReadingListImportWindow.chosen ?? .everything).rawValue },
                write: { value in
                    let raw = try AppSettingEntry.string(value, "sources.reading_list_import_window")
                    guard let window = SourceDiscovery.ReadingListImportWindow(rawValue: raw) else {
                        throw MCPError.invalidInput("sources.reading_list_import_window takes one of: \(SourceDiscovery.ReadingListImportWindow.allCases.map(\.rawValue).joined(separator: ", ")).")
                    }
                    let widened = SourceDiscovery.ReadingListImportWindow.widens(
                        from: SourceDiscovery.ReadingListImportWindow.chosen,
                        to: window
                    )
                    SourceDiscovery.ReadingListImportWindow.choose(window)
                    if widened { AppModelBridge.studio?.readingListBrowsersDidChange() }
                }
            ),
            AppSettingEntry(
                id: "sources.zoom_transcript_folder",
                pane: "Sources › Zoom Transcripts",
                title: "Zoom transcript folder",
                detail: "The folder Zoom saves captions and local recordings in, if not Zoom's default ~/Documents/Zoom (which is watched as well). An absolute path to an existing folder on this Mac; an empty string goes back to the default only. The folder is read at once for transcripts Zoom wrote before.",
                reach: .thisMac,
                kind: .text,
                preferenceKeys: [StudioViewModel.zoomLocalTranscriptFolderKey],
                read: { StudioViewModel.zoomLocalTranscriptCustomFolder ?? "" },
                write: { value in
                    let raw = try AppSettingEntry.string(value, "sources.zoom_transcript_folder")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if raw.isEmpty {
                        UserDefaults.standard.removeObject(forKey: StudioViewModel.zoomLocalTranscriptFolderKey)
                    } else {
                        let path = (raw as NSString).expandingTildeInPath
                        var isDirectory: ObjCBool = false
                        guard path.hasPrefix("/"),
                              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                              isDirectory.boolValue else {
                            throw MCPError.invalidInput("\(raw) is not a folder on this Mac.")
                        }
                        UserDefaults.standard.set(path, forKey: StudioViewModel.zoomLocalTranscriptFolderKey)
                    }
                    AppModelBridge.studio?.zoomLocalTranscriptFolderDidChange()
                }
            ),
            AppSettingEntry(
                id: "google_drive.transcribe_when_google_did_not",
                pane: "Plugins › Google Drive",
                title: "Transcribe recordings Google didn't",
                detail: "Whether ForeverLM runs its own speech-to-text over a Google Meet recording that came without Gemini's transcript. Off by default: Google's transcript is normally in the Doc already, and transcribing again is billed.",
                reach: .account,
                kind: .boolean,
                preferenceKeys: [StudioViewModel.meetingOwnTranscriptionEnabledKey],
                read: { StudioViewModel.isMeetingOwnTranscriptionEnabled },
                write: {
                    PreferenceStore.set(
                        try AppSettingEntry.bool($0, "google_drive.transcribe_when_google_did_not"),
                        forKey: StudioViewModel.meetingOwnTranscriptionEnabledKey
                    )
                }
            ),
            AppSettingEntry(
                id: "youtube.format_new_transcripts",
                pane: "Plugins › YouTube",
                title: "Format new transcripts automatically",
                detail: "Whether a liked video's captions are rewritten into readable paragraphs as it arrives. Each long transcript can be several billed calls; raw captions are always kept.",
                reach: .account,
                kind: .boolean,
                preferenceKeys: [StudioViewModel.youtubeLikedTranscriptFormattingKey],
                read: { StudioViewModel.isLikedYouTubeTranscriptFormattingEnabled },
                write: { StudioViewModel.setLikedYouTubeTranscriptFormattingEnabled(try AppSettingEntry.bool($0, "youtube.format_new_transcripts")) }
            ),
        ]
    }

    // MARK: - Feeds

    @MainActor
    private static func feedSettingEntries() -> [AppSettingEntry] {
        [
            AppSettingEntry(
                id: "feeds.notify_on_match",
                pane: "Feeds (no pane)",
                title: "Notify me when an article matches a Notebook",
                detail: "A notification on this Mac when a followed journal publishes an article that matches one of the learner's Notebooks. Turning it on asks macOS for notification permission; if that is refused it stays off.",
                reach: .thisMac,
                kind: .boolean,
                preferenceKeys: [JournalWatch.notifyOnMatchKey],
                read: { UserDefaults.standard.bool(forKey: JournalWatch.notifyOnMatchKey) },
                write: { value in
                    let enabled = try AppSettingEntry.bool(value, "feeds.notify_on_match")
                    if enabled {
                        guard await JournalWatchNotifications.requestAuthorization() else {
                            UserDefaults.standard.set(false, forKey: JournalWatch.notifyOnMatchKey)
                            throw MCPError.invalidInput("macOS refused notifications for ForeverLM; the learner can allow them in System Settings › Notifications.")
                        }
                    }
                    UserDefaults.standard.set(enabled, forKey: JournalWatch.notifyOnMatchKey)
                }
            ),
        ]
    }

    // MARK: - One-shot pane buttons

    static let settingsActionIDs: [[String: String]] = [
        ["action": "sync_icloud_now", "pane": "Data & Privacy › iCloud", "does": "Sync now: push and pull every pending iCloud change."],
        ["action": "confirm_this_mac_holds_my_library", "pane": "Data & Privacy › iCloud", "does": "This Mac holds my library: upload this Mac's library to the new iCloud store, catching up with the old one first. Only after the learner has said this Mac's library is the one to keep; get_sync_status migration.this_mac_holds_my_library says when it is offered."],
        ["action": "upload_library_to_icloud_again", "pane": "Data & Privacy › iCloud", "does": "Upload my library to iCloud again, after iCloud lost the library (get_sync_status migration.private_database_stopped)."],
        ["action": "replace_icloud_library", "pane": "Data & Privacy › iCloud", "does": "Delete this account's ForeverLM library from iCloud, then upload this Mac's library from the start. For when iCloud holds only a stub of the library (get_sync_status shows little uploading and the phone shows no notebooks). Only on the Mac that holds the library, and only after the learner has said so: iCloud's copy is removed for every device."],
        ["action": "apply_old_library_removals", "pane": "Data & Privacy › iCloud", "does": "Apply: an older ForeverLM removed more than 5% of the old iCloud library, and the learner chose to apply those removals here too."],
        ["action": "keep_old_library_removals", "pane": "Data & Privacy › iCloud", "does": "Keep: apply everything else from the old iCloud library and list those removals under Kept from an older ForeverLM."],
        ["action": "prepare_memory_review_now", "pane": "no pane", "does": "Select today's cards for the memory review now, whatever the hour."],
        ["action": "check_feeds_now", "pane": "Feeds", "does": "Check now: read every followed journal, due or not."],
        ["action": "draw_missing_meeting_icons", "pane": "no pane", "does": "Fill in the meetings that have no icon, with the image model when drawing is on (billed)."],
        ["action": "sync_x_bookmarks", "pane": "Plugins › X", "does": "Sync: import new X bookmarks now, from every connected account."],
        ["action": "clear_usage_ledger_warning", "pane": "AI Usage › Activity", "does": "Clear Warning: forget the recorded usage-ledger write failures."],
    ].filter { JournalWatch.isEnabled || $0["pane"] != "Feeds" }

    func runSettingsAction(action: String?) async throws -> String {
        guard let action = action?.trimmingCharacters(in: .whitespacesAndNewlines), !action.isEmpty else {
            throw MCPError.invalidInput("Pass action, one of: \(Self.settingsActionIDs.compactMap { $0["action"] }.joined(separator: ", ")).")
        }
        var result: [String: Any] = ["action": action]
        switch action {
        case "sync_icloud_now":
            guard MacSyncSession.current != nil else {
                result["done"] = "This Mac's iCloud sync has not started, so nothing was synced; get_sync_status says why."
                break
            }
            let storage = StorageService()
            await storage.syncCloudKitNow()
            let waiting = try await storage.pendingCloudKitChangeCount()
            result["still_waiting"] = waiting
            result["done"] = waiting == 0
                ? "Synced with iCloud now; everything on this Mac has reached iCloud."
                : "Synced with iCloud now; \(waiting) local change\(waiting == 1 ? " still waits" : "s still wait") to upload. get_sync_status says why."
        case "confirm_this_mac_holds_my_library", "upload_library_to_icloud_again", "replace_icloud_library", "apply_old_library_removals", "keep_old_library_removals":
            result["done"] = try await Self.runICloudMoveAction(action)
        case "prepare_memory_review_now":
            // Since the card review (2026-10-01): today's cards selected
            // again, no model called, no chat made.
            if let attempt = await Self.prepareMemoryReviewNow() {
                result["succeeded"] = attempt.succeeded
                result["message"] = attempt.message ?? NSNull()
                result["cards"] = attempt.cardsLine ?? NSNull()
            }
        case "check_feeds_now" where JournalWatch.isEnabled:
            result["summary"] = await Self.checkFeedsNow() ?? NSNull()
        case "draw_missing_meeting_icons":
            try await Self.drawMissingMeetingIcons()
            result["done"] = MacImageGenerationSettings.isEnabled
                ? "Filled in the missing meeting icons, drawing where no thumbnail served."
                : "Filled in the missing meeting icons from free thumbnails; drawing is off (images.draw_meeting_icons)."
        case "sync_x_bookmarks":
            result["imported"] = try await Self.syncXBookmarksNow()
        case "clear_usage_ledger_warning":
            AIUsageLedgerHealth.reset()
            result["done"] = "Cleared the usage-ledger warning."
        default:
            throw MCPError.invalidInput("Unknown action \(action). Actions: \(Self.settingsActionIDs.compactMap { $0["action"] }.joined(separator: ", ")).")
        }
        return try jsonString(result)
    }

    /// The buttons of Settings › iCloud's move, on the same model the pane uses (`ICloudMigrationModel`).
    @MainActor
    private static func runICloudMoveAction(_ action: String) async throws -> String {
        guard ForeverLMRuntimeIdentity.syncGeneration == .two else {
            throw MCPError.invalidInput("This build syncs with the old iCloud container; the new iCloud store's buttons do not exist.")
        }
        let model = ICloudMigrationModel.shared
        await model.refresh()
        switch action {
        case "confirm_this_mac_holds_my_library": await model.confirmHoldsMyLibrary()
        case "upload_library_to_icloud_again": await model.uploadAgain()
        case "replace_icloud_library": await model.replaceICloudLibrary()
        case "apply_old_library_removals": await model.answerImportQuestion(.apply)
        default: await model.answerImportQuestion(.keep)
        }
        return model.notice ?? "Done; get_sync_status shows where the move stands."
    }

    @MainActor
    private static func prepareMemoryReviewNow() async -> MemoryReviewPreparationRunner.Attempt? {
        await MemoryReviewPreparationRunner.shared.prepareNow()
        return MemoryReviewPreparationRunner.shared.lastAttempt
    }

    @MainActor
    private static func checkFeedsNow() async -> String? {
        await JournalWatchRunner.shared.checkNow()
        return JournalWatchRunner.shared.lastCheckSummary
    }

    @MainActor
    private static func drawMissingMeetingIcons() async throws {
        try await AppModelBridge.requireStudio().generateMissingMeetingIcons()
    }

    @MainActor
    private static func syncXBookmarksNow() async throws -> Int {
        let studio = try AppModelBridge.requireStudio()
        guard XBookmarkService.shared.isOAuthSignedIn else {
            throw MCPError.invalidInput("X is not connected. Connect it in Plugins › X (open_settings x).")
        }
        return await studio.syncXBookmarks(showResult: false)
    }

    // MARK: - Showing a pane

    /// What `open_settings` shows for an id: a Settings pane, or — since the
    /// plugins left Settings for a place of their own (2026-10-13) — the
    /// Plugins place, at a plugin's page or, for nil, at its list.
    enum SettingsPaneTarget: Equatable {
        case pane(SettingsPane)
        case plugins(PluginPage?)
    }

    /// The ids `open_settings` takes, as the Settings sidebar titles its
    /// panes. The plugins' ids are the ones they had as Settings panes, so the
    /// tool's contract is unchanged; they open the Plugins place.
    static let settingsPaneIDs: [(id: String, target: SettingsPaneTarget)] = [
        // "general" stays in the published enum; the pane went on 2026-11-08
        // and Settings opens on Chat in its place.
        ("general", .pane(.aiChatModels)), ("chat", .pane(.aiChatModels)), ("voice", .pane(.aiTextToSpeech)),
        ("images", .pane(.aiImages)), ("videos", .pane(.aiVideos)), ("background", .pane(.aiBackgroundModels)),
        ("billing", .pane(.aiBilling)), ("ai_usage", .pane(.aiUsage)), ("data_privacy", .pane(.dataPrivacy)),
        ("team_general", .pane(.teamGeneral)), ("team_members", .pane(.teamMembers)),
        ("sources", .pane(.sources)), ("plugins", .plugins(nil)),
        ("mcp", .pane(.mcp)), ("mcp_pairing", .pane(.mcpPairing)), (PluginPage.x.rawValue, .plugins(.x)),
        (PluginPage.youtube.rawValue, .plugins(.youtube)), (PluginPage.googleDrive.rawValue, .plugins(.googleDrive)),
        (PluginPage.appleCalendar.rawValue, .plugins(.appleCalendar)),
        (PluginPage.slack.rawValue, .plugins(.slack)), (PluginPage.linear.rawValue, .plugins(.linear)),
        (PluginPage.github.rawValue, .plugins(.github)),
        (PluginPage.notion.rawValue, .plugins(.notion)), (PluginPage.yourPlugins.rawValue, .plugins(.yourPlugins)),
    ]

    func openSettings(pane: String?) async throws -> String {
        let id = pane?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let match: SettingsPaneTarget
        if id.isEmpty {
            match = .pane(.aiBilling)
        } else if let found = Self.settingsPaneIDs.first(where: { $0.id == id }) {
            match = found.target
        } else {
            throw MCPError.invalidInput("pane takes one of: \(Self.settingsPaneIDs.map { $0.id }.joined(separator: ", ")).")
        }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            switch match {
            case .pane(let pane):
                NotificationCenter.default.post(name: .requestOpenStudioSettings, object: pane)
            case .plugins(let page):
                Self.bringActiveStudioWindowForward()
                PluginsPlace.requestOpen(page)
            }
        }
        var payload: [String: Any] = ["opened": id.isEmpty ? "billing" : id]
        if case .plugins = match { payload["in"] = "plugins" }
        return try jsonString(payload)
    }

    static let openInAppKinds = ["notebook", "doc", "chat", "source", "quiz", "idea", "space", "plugins"]

    /// What a click on the thing does, so a chat can drive the window: the
    /// notebook, doc, chat, quiz and idea go through `StudioViewModel.open`
    /// (the link every `foreverlm://` address takes), a source through the
    /// Reader's link path, and the Space's All list through the View menu's
    /// own entry. The Notebooks home this once showed (`notebooks_home`) is
    /// gone, and the Space lists every notebook.
    func openInApp(kind rawKind: String?, id rawID: String?, sideBySide: Bool = false) async throws -> String {
        let kind = rawKind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard Self.openInAppKinds.contains(kind) else {
            throw MCPError.invalidInput("kind takes one of: \(Self.openInAppKinds.joined(separator: ", ")).")
        }
        let id = rawID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if kind != "space", kind != "plugins", id.isEmpty {
            throw MCPError.invalidInput("Pass id: the \(kind)'s id from its list tool.")
        }
        let pluginPage: PluginPage?
        if kind == "plugins", !id.isEmpty {
            guard let page = PluginPage(rawValue: id.lowercased()) else {
                throw MCPError.invalidInput("For plugins, id is omitted for the list or one of: \(PluginPage.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            pluginPage = page
        } else {
            pluginPage = nil
        }
        let studio = try await MainActor.run { try AppModelBridge.requireStudio() }
        let title: String? = try await MainActor.run {
            switch kind {
            case "notebook":
                guard let notebook = studio.notebook(id: id) else {
                    throw MCPError.invalidInput("No notebook \(id) in the open library. list_notebooks has the ids.")
                }
                return notebook.title
            case "doc":
                return studio.artifacts.first { $0.id == id }?.title
            case "plugins":
                return pluginPage?.title
            default:
                return nil
            }
        }
        // A source already drawn in a Reader, in any window, is not opened a
        // second time: the window that shows it comes forward and the answer
        // says so, so the chat does not go on to open it again (product owner,
        // 2026-10-16: the chat opened a paper another window already had open).
        if kind == "source" {
            let shown: (id: String, title: String, here: Bool)? = await MainActor.run {
                guard let article = studio.loadedArticle(forLinkToken: id) else { return nil }
                let windows = ChatOpenPanes.windows(showing: article.id, vm: studio)
                guard let first = windows.first else { return nil }
                NSApp.activate(ignoringOtherApps: true)
                StudioWorkspaceWindowCoordinator.shared.window(for: first)?.makeKeyAndOrderFront(nil)
                return (article.id, studio.displayTitle(for: article), first === StudioWindowRegistry.shared.activeState)
            }
            if let shown {
                return try jsonString([
                    "opened": "source",
                    "id": shown.id,
                    "title": shown.title,
                    "already_open": true,
                    "note": shown.here
                        ? "This source is already open in the Reader of the window the learner is using. Nothing was opened again."
                        : "This source is already open in the Reader of another ForeverLM window, which now comes forward. Nothing was opened again.",
                ])
            }
        }
        await MainActor.run { Self.bringActiveStudioWindowForward() }
        switch kind {
        case "space":
            await MainActor.run { studio.showSpaceAll() }
        case "plugins":
            await MainActor.run { studio.openPluginsPlace(pluginPage) }
        case "source":
            await studio.openLinkedSourceInReader(id)
        case "notebook": await studio.open(.notebook(id))
        case "doc":
            if sideBySide {
                await studio.openDocSideBySide(id)
            } else {
                await studio.open(.doc(id))
            }
        case "chat": await studio.open(.chat(id))
        case "quiz": await studio.open(.quiz(id))
        default: await studio.open(.idea(id))
        }
        var payload: [String: Any] = ["opened": kind]
        if kind != "space", !id.isEmpty { payload["id"] = kind == "plugins" ? id.lowercased() : id }
        if let title { payload["title"] = title }
        return try jsonString(payload)
    }

    /// ForeverLM in front, with the window the learner last used, where
    /// `open_in_app` and `practice_cards` show what they open.
    @MainActor
    static func bringActiveStudioWindowForward() {
        NSApp.activate(ignoringOtherApps: true)
        if let state = StudioWindowRegistry.shared.activeState,
           let window = StudioWorkspaceWindowCoordinator.shared.window(for: state) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

extension MCPToolRegistry {

    /// Every tool that exists so a Settings control has a chat equivalent.
    /// `tools` appends these; `executeTool` asks `executeSettingsParityTool`
    /// before its own switch.
    static var settingsParityToolDefs: [MCPToolDef] {
        appSettingsToolDefs
            + pluginSettingsToolDefs
            + accountSettingsToolDefs
            + backgroundAISpendToolDefs
    }

    /// None of these holds the store gate: they wait on the UI, the network
    /// (Slack, Google, the billing service) or a macOS permission sheet, and
    /// their own store reads are single statements, like the exempt connector
    /// reads in `storeGateExemptToolNames`.
    static let settingsParityToolNames: Set<String> = Set(settingsParityToolDefs.map(\.name))

    static let settingsParityReadOnlyToolNames: Set<String> =
        Set(["get_app_settings"])
            .union(pluginSettingsReadOnlyToolNames)
            .union(accountSettingsReadOnlyToolNames)
            .union(backgroundAISpendReadOnlyToolNames)

    private static var appSettingsToolDefs: [MCPToolDef] {
        [
            MCPToolDef(
                name: "get_app_settings",
                description: "Read the ForeverLM Settings window as chat can change it: every switch, picker and slider in Appearance, Voice (speech-to-text models, text-to-speech voice and speed), Images, Videos, Sources › Reading Lists and Zoom Transcripts, and the Plugins place (Google Drive, YouTube), each with its id, current value, type, whether it follows the learner's account or stays on this Mac, and the options its picker offers. Also lists the panes that have tools of their own (dedicated_tools), the one-shot buttons run_settings_action performs (actions), and the few controls that stay in the window because they need the learner's own hand (only_in_the_settings_window). Pass pane to narrow by pane name, or setting for one entry.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "pane": ["type": "string", "description": "Optional: only settings whose pane contains this text, e.g. voice, images, youtube."],
                        "setting": ["type": "string", "description": "Optional: one setting id, e.g. read_aloud.speed."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "set_app_setting",
                description: "Change one Settings control exactly as the pane does, through the pane's own setter, and return the setting with changed. setting is an id from get_app_settings; value is true/false for a boolean, a number within its range, one option's value for a choice, text, or the whole list for a string_list. A choice outside the pane's options is refused with the options. Model and voice pickers change what the learner's work is billed at, so ask before changing them unasked. For the panes listed under dedicated_tools use those tools instead.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "setting": ["type": "string", "description": "The setting id from get_app_settings."],
                        "value": ["description": "The new value: boolean, number, string, or list of strings, per the setting's type."],
                    ],
                    "required": ["setting", "value"],
                ]
            ),
            MCPToolDef(
                name: "run_settings_action",
                description: "Press one of the Settings window's one-shot buttons: sync_icloud_now (Data & Privacy › iCloud › Sync now), prepare_memory_review_now (make today's memory review ready now), draw_missing_meeting_icons (fill in missing meeting icons — billed when drawing is on), sync_x_bookmarks (Plugins › X › Sync), clear_usage_ledger_warning (AI Usage › Activity › Clear Warning), and Data & Privacy › iCloud's confirm_this_mac_holds_my_library (This Mac holds my library; only once the learner has said this Mac's library is the one to keep), upload_library_to_icloud_again, apply_old_library_removals and keep_old_library_removals (Apply and Keep for the question an older ForeverLM's removals raise). Some have no button in the window any more; this is where they are pressed. Returns what the button did.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": MCPDataStore.settingsActionIDs.compactMap { $0["action"] }, "description": "The button to press."],
                    ],
                    "required": ["action"],
                ]
            ),
            MCPToolDef(
                name: "open_settings",
                description: "Open ForeverLM's Settings window on the learner's Mac at one pane, for what a chat must leave to the learner — signing in, unlocking MCP, managing team members in Apple's sharing sheet. team_general and team_members open the open team's own Settings, a separate window from the learner's, and need a team library open. Plugins are not in Settings: plugins, and a plugin's id (x, youtube, google_drive, apple_calendar, slack, linear, github, notion, build_your_own_plugin), open the Plugins place on the icon strip at every plugin or at that plugin's page, where the learner connects it through the provider's consent page. Brings ForeverLM to the front.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "pane": ["type": "string", "enum": MCPDataStore.settingsPaneIDs.map { $0.id }, "description": "The pane to show. Omit for Billing, unlocking MCP; ai_usage is the key, spending and activity; plugins and a plugin's id open the Plugins place."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "open_in_app",
                description: "Show one of the learner's things in the ForeverLM window on this Mac, as a click on it would: a notebook opens in its workspace, a doc comes forward in Docs, a chat resumes in the chat panel, a source opens in the Reader (one already open in any window is brought forward, not opened again), a course quiz is taken, an idea opens, space shows the Space's All list, where every notebook and course is listed, and plugins shows the Plugins place, at one plugin's page when id names it (x, youtube, google_drive, apple_calendar, slack, linear, github, notion, build_your_own_plugin). Use it whenever the learner asks to open, show, go to or switch to something (\"open this notebook\") — listing or loading it for yourself (list_notebooks, get_notebook) changes nothing on screen. id is the thing's own id from the list tools or the call that created it; space takes none, and plugins none for every plugin. Opens in the window the learner last used and brings ForeverLM to the front. Writes nothing synced. Needs a Studio window open.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string", "enum": MCPDataStore.openInAppKinds, "description": "What to open."],
                        "id": ["type": "string", "description": "The notebook, doc, chat (review session), source, quiz or idea id, or a plugin's id for plugins. Omit for space, and for plugins to show every plugin."],
                        "side_by_side": ["type": "boolean", "description": "Only with kind doc: true opens the Page beside what the learner is reading or watching, so the video or paper stays on screen on the left and the Page is on the right. Use it when they ask for notes next to the source they have open."],
                    ],
                    "required": ["kind"],
                ]
            ),
        ]
    }
}

extension MCPDataStore {
    /// The dispatch for `settingsParityToolDefs`; nil for any other name.
    func executeSettingsParityTool(name: String, arguments: [String: Any]) async throws -> String? {
        switch name {
        case "get_app_settings":
            return try await getAppSettings(pane: arguments["pane"] as? String, settingID: arguments["setting"] as? String)
        case "set_app_setting":
            return try await setAppSetting(settingID: arguments["setting"] as? String, value: arguments["value"])
        case "run_settings_action":
            return try await runSettingsAction(action: arguments["action"] as? String)
        case "open_settings":
            return try await openSettings(pane: arguments["pane"] as? String)
        case "open_in_app":
            return try await openInApp(
                kind: arguments["kind"] as? String,
                id: arguments["id"] as? String,
                sideBySide: arguments["side_by_side"] as? Bool ?? false
            )
        default:
            if let result = try await executeBackgroundAISpendTool(name: name, arguments: arguments) { return result }
            if let result = try await executePluginSettingsTool(name: name, arguments: arguments) { return result }
            return try await executeAccountSettingsTool(name: name, arguments: arguments)
        }
    }
}
