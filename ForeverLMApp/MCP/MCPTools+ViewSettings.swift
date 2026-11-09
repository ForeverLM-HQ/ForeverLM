import Foundation

// MARK: - Display, layout and remembered choices, from a chat
//
// Schema v2 D28: every synced Setting stays settable over MCP. The panes of the Settings
// window have entries of their own (`MCPTools+AppSettings.swift`); these are the account's
// other remembered preferences: how lists sort and what they show, the zoom, how the window is
// laid out and what is folded, the reader's pane widths, a Doc's page width, what Getting
// Started has recorded, and the few lists the app keeps for the learner. Each is one key of
// `UserDefaults`, written through `PreferenceStore` exactly as the control that sets it writes it,
// so the open window reseeds from it and the account's other devices follow.
//
// The keys' catalog rows (`schema/cloudkit-schema.json`, `settings.keys`) name the entry by id;
// `SettingsCatalogTests` holds each entry to its row's type and range, and
// `MCPToolContractTests.everyGenerationTwoSettingIsSettableOverMCP` holds every synced key to a
// route.

extension MCPDataStore {

    /// One remembered preference as an entry: its key, its kind, what it reads as when the key is
    /// absent, and what a write must be (a choice's options, a number's range, an integer or not).
    @MainActor
    private static func preferenceEntry(
        id: String,
        pane: String,
        title: String,
        detail: String,
        key: String,
        kind: AppSettingEntry.Kind,
        absent: Any,
        integer: Bool = false,
        options: [(value: String, label: String)] = []
    ) -> AppSettingEntry {
        let optionValues = options.map(\.value)
        return AppSettingEntry(
            id: id,
            pane: pane,
            title: title,
            detail: detail,
            reach: .account,
            kind: kind,
            preferenceKeys: [key],
            options: options.isEmpty ? nil : { options.map { ["value": $0.value, "label": $0.label] } },
            read: {
                let stored = UserDefaults.standard.object(forKey: key)
                switch kind {
                case .boolean: return stored as? Bool ?? absent
                case .number: return (stored as? NSNumber)?.doubleValue ?? absent
                case .choice, .text: return stored as? String ?? absent
                case .stringList: return UserDefaults.standard.stringArray(forKey: key) ?? absent
                }
            },
            write: { value in
                switch kind {
                case .boolean:
                    PreferenceStore.set(try AppSettingEntry.bool(value, id), forKey: key)
                case let .number(min, max, _):
                    let number = try AppSettingEntry.number(value, id)
                    guard number.isFinite, number >= min, number <= max, !integer || number == number.rounded() else {
                        throw MCPError.invalidInput("\(id) takes \(integer ? "a whole number" : "a number") from \(min) to \(max).")
                    }
                    PreferenceStore.set(integer ? Int(number) as Any : number as Any, forKey: key)
                case .choice:
                    let choice = try AppSettingEntry.string(value, id)
                    guard optionValues.contains(choice) else {
                        throw MCPError.invalidInput("\(id) takes one of: \(optionValues.joined(separator: ", ")).")
                    }
                    PreferenceStore.set(choice, forKey: key)
                case .text:
                    PreferenceStore.set(try AppSettingEntry.string(value, id), forKey: key)
                case .stringList:
                    PreferenceStore.set(try AppSettingEntry.strings(value, id), forKey: key)
                }
            }
        )
    }

    /// A text value that holds JSON, refused unless it parses as a JSON object (or, for a list of
    /// hidden rows, an array) the way the control that writes it would have produced.
    @MainActor
    private static func jsonTextEntry(
        id: String, pane: String, title: String, detail: String, key: String, absent: String, isArray: Bool = false
    ) -> AppSettingEntry {
        AppSettingEntry(
            id: id,
            pane: pane,
            title: title,
            detail: detail,
            reach: .account,
            kind: .text,
            preferenceKeys: [key],
            read: { UserDefaults.standard.string(forKey: key) ?? absent },
            write: { value in
                let text = try AppSettingEntry.string(value, id)
                let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                guard isArray ? parsed is [Any] : parsed is [String: Any] else {
                    throw MCPError.invalidInput("\(id) takes a JSON \(isArray ? "array" : "object") as text.")
                }
                PreferenceStore.set(text, forKey: key)
            }
        )
    }

    /// The rail's hidden rows as MCP reads them: a JSON array of row ids, from the comma-separated
    /// form the rail stores (`StudioRailHiddenItems.storage`), a retired row's name left out as the
    /// rail leaves it out.
    static func railHiddenItemsJSON(_ storage: String) -> String {
        let ids = StudioRailHiddenItems(storage: storage).items.map(\.rawValue).sorted()
        guard let data = try? JSONSerialization.data(withJSONObject: ids), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// A JSON array of row ids in the comma-separated form the rail reads. Until 2026-10-05 the
    /// array was stored as it came, which the rail parsed as one unknown name and so hid nothing.
    static func railHiddenItemsStorage(fromJSON text: String) throws -> String {
        let known = StudioRailItem.allCases.map(\.rawValue).joined(separator: ", ")
        guard let ids = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String] else {
            throw MCPError.invalidInput("window.rail_hidden_items takes a JSON array of row ids as text: \(known).")
        }
        var items = Set<StudioRailItem>()
        for id in ids {
            guard let item = StudioRailItem(rawValue: id.trimmingCharacters(in: .whitespaces)) else {
                throw MCPError.invalidInput("window.rail_hidden_items has no row ‘\(id)’; the rows are \(known).")
            }
            items.insert(item)
        }
        return StudioRailHiddenItems(items).storage
    }

    /// The strip's shortcuts as a JSON array of place ids, in their order.
    static func railShortcutsJSON(_ storage: String) -> String {
        let ids = StudioRailShortcuts(storage: storage).items.map(\.key)
        guard let data = try? JSONSerialization.data(withJSONObject: ids), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// A JSON array of place ids in the comma-separated form the strip reads.
    static func railShortcutsStorage(fromJSON text: String) throws -> String {
        let known = StudioRailShortcut.offered(listsCanvases: true).map(\.key).joined(separator: ", ")
        guard let ids = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String] else {
            throw MCPError.invalidInput("window.rail_shortcuts takes a JSON array of place ids as text: \(known).")
        }
        var shortcuts: [StudioRailShortcut] = []
        for id in ids {
            guard let shortcut = StudioRailShortcut(key: id.trimmingCharacters(in: .whitespaces)) else {
                throw MCPError.invalidInput("window.rail_shortcuts has no place ‘\(id)’; the places are \(known).")
            }
            shortcuts.append(shortcut)
        }
        return StudioRailShortcuts(shortcuts).storage
    }

    /// One group of the strip's order as a JSON array of icon ids, in order.
    static func stripOrderJSON(_ storage: String) -> String {
        let ids = StudioStripOrder(storage: storage).keys
        guard let data = try? JSONSerialization.data(withJSONObject: ids), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// A JSON array of icon ids of one group (`footer` or the top) in the comma-separated form
    /// the strip reads, refused when an id is not one of that group's icons.
    static func stripOrderStorage(fromJSON text: String, footer: Bool, setting: String) throws -> String {
        let known = stripOrderIDs(footer: footer)
        guard let ids = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String] else {
            throw MCPError.invalidInput("\(setting) takes a JSON array of icon ids as text: \(known.joined(separator: ", ")).")
        }
        var keys: [String] = []
        for raw in ids {
            let id = raw.trimmingCharacters(in: .whitespaces)
            guard let entry = StudioStripEntry(key: id), entry.isFooter == footer, known.contains(id) else {
                throw MCPError.invalidInput("\(setting) has no icon ‘\(raw)’; the icons are \(known.joined(separator: ", ")).")
            }
            keys.append(entry.key)
        }
        return StudioStripOrder(keys).storage
    }

    /// The ids one group of the strip can order: the footer's icons, or the strip's rows and
    /// every place that can be kept there.
    static func stripOrderIDs(footer: Bool) -> [String] {
        footer
            ? StudioStripFooterItem.allCases.map(\.rawValue)
            : StudioRailHiddenItems.railOrder.map(\.rawValue) + StudioRailShortcut.offered(listsCanvases: true).map(\.key)
    }

    @MainActor
    static func viewSettingEntries() -> [AppSettingEntry] {
        sourceListSettingEntries()
            + displaySettingEntries()
            + windowLayoutSettingEntries()
            + readerAndDocSettingEntries()
            + rememberedStateSettingEntries()
            + aiChoiceSettingEntries()
            + speechInstructionSettingEntries()
    }

    // MARK: Sources lists

    @MainActor
    private static func sourceListSettingEntries() -> [AppSettingEntry] {
        [
            preferenceEntry(
                id: "sources.podcast_sort_mode", pane: "Sources sidebar › Podcasts filter (no pane)", title: "Podcast sort",
                detail: "How podcast episodes sort in the Sources sidebar: by date, or grouped by podcast channel.",
                key: "podcastSortMode", kind: .choice, absent: PodcastSortMode.date.rawValue,
                options: PodcastSortMode.allCases.map { ($0.rawValue, $0.title) }
            ),
            preferenceEntry(
                id: "sources.video_sort_mode", pane: "Sources sidebar › Videos filter (no pane)", title: "Video sort",
                detail: "How videos sort in the Sources sidebar: by when the learner liked them, or by their own publication date.",
                key: "videoSortMode", kind: .choice, absent: VideoSortMode.liked.rawValue,
                options: VideoSortMode.allCases.map { ($0.rawValue, $0.title) }
            ),
            preferenceEntry(
                id: "sources.meeting_list_order", pane: "Sources sidebar › Meetings, By Date toggle beside the search", title: "Meetings list order",
                detail: "How the Meetings tab lists sessions: one row per series (bySeries), or every session on its own row, newest first (byDate).",
                key: "meetingListOrder", kind: .choice, absent: MeetingListOrder.bySeries.rawValue,
                options: MeetingListOrder.allCases.map { ($0.rawValue, $0.title) }
            ),
            preferenceEntry(
                id: "sources.apple_podcast_discovery_scope", pane: "Sources › Podcasts (no pane)", title: "Apple Podcasts discovery",
                detail: "Which Apple Podcasts episodes discovery reads: only the ones the learner listened to, those downloaded or listened to, or only the ones played to the end.",
                key: ApplePodcastDiscoveryScope.defaultsKey, kind: .choice, absent: ApplePodcastDiscoveryScope.listened.rawValue,
                options: ApplePodcastDiscoveryScope.allCases.map { ($0.rawValue, $0.rawValue) }
            ),
            preferenceEntry(
                id: "sources.youtube_fallback_shows", pane: "Sources › Podcasts (no pane)", title: "Podcasts matched on YouTube",
                detail: "The shows whose episodes are matched on YouTube when their feed carries no transcript, by show name. The whole list is replaced.",
                key: "podcasts.youtubeFallbackShows", kind: .stringList, absent: [String]()
            ),
            preferenceEntry(
                id: "sources.tab_bar_layout", pane: "Sources sidebar › tab bar (no pane)", title: "Source tab bar layout",
                detail: "Compact keeps the source types in one narrow row; roomy shows them across two rows with larger icons.",
                key: "studio.sourceTabBarLayout", kind: .choice, absent: SourceTabBarLayout.compact.rawValue,
                options: SourceTabBarLayout.allCases.map { ($0.rawValue, $0.title) }
            ),
            preferenceEntry(
                id: "sources.show_tab_labels", pane: "Sources sidebar › tab bar (no pane)", title: "Show source tab labels",
                detail: "Whether the source tabs show their labels beside the icons. On by default.",
                key: "studio.showSourceTabLabels", kind: .boolean, absent: true
            ),
            preferenceEntry(
                id: "sources.tab_icon_size", pane: "Sources sidebar › tab bar (no pane)", title: "Source tab icon size",
                detail: "The size of the source tabs' icons, and with it the tab bar's height.",
                key: "studio.sourceTabIconSize", kind: .choice, absent: SourceTabIconSize.medium.rawValue,
                options: SourceTabIconSize.allCases.map { ($0.rawValue, $0.title) }
            ),
            preferenceEntry(
                id: "sources.tab_order", pane: "Sources sidebar › tab bar (no pane)", title: "Source tab order",
                detail: "The source tab bar's order, as source type ids (the values source_type takes). Types the list leaves out follow in their usual order. The whole list is replaced.",
                key: "studio.tabOrder", kind: .stringList, absent: [String]()
            ),
        ]
    }

    // MARK: Display

    @MainActor
    private static func displaySettingEntries() -> [AppSettingEntry] {
        [
            preferenceEntry(
                id: "appearance.zoom_step", pane: "View › Zoom (no pane)", title: "Zoom",
                detail: "The app-wide zoom step, from \(UIZoom.minStep) (smallest) to \(UIZoom.maxStep) (largest); the default is \(UIZoom.defaultStep). The View menu's Zoom In and Zoom Out move it by one.",
                key: "uiZoomStep", kind: .number(min: Double(UIZoom.minStep), max: Double(UIZoom.maxStep), step: 1),
                absent: Double(UIZoom.defaultStep), integer: true
            ),
            jsonTextEntry(
                id: "appearance.metadata_visibility", pane: "Sources sidebar › filter popover (no pane)", title: "Metadata shown in lists",
                detail: "Which metadata fields each source type's rows hide, as a JSON object of source type id to the list of hidden field ids, such as {\"podcast\":[\"duration\"]}. Everything shows by default, so only hidden fields are stored; {} shows all.",
                key: "metadataVisibility", absent: "{}"
            ),
            preferenceEntry(
                id: "appearance.reader_original_page_colors", pane: "Reader › Dark Mode (no pane)", title: "Original page colors",
                detail: "Read sources as they were published rather than darkened in Dark Mode. Off by default: Dark Mode still means a dark page.",
                key: ReaderDarkMode.originalPageColorsKey, kind: .boolean, absent: false
            ),
        ]
    }

    // MARK: Window layout

    @MainActor
    private static func windowLayoutSettingEntries() -> [AppSettingEntry] {
        [
            preferenceEntry(
                id: "window.show_search_panel", pane: "Window › Search panel (no pane)", title: "Show the Search panel",
                detail: "Whether a new Studio window shows its Search panel. On by default.",
                key: "studio.showSearchPanel", kind: .boolean, absent: true
            ),
            preferenceEntry(
                id: "window.navigation_rail_visible", pane: "Window › Navigation rail (no pane)", title: "Show the navigation rail",
                detail: "Whether a new Studio window shows the navigation rail. On by default.",
                key: "studio.navigationRailVisible", kind: .boolean, absent: true
            ),
            preferenceEntry(
                id: "window.expanded_panel", pane: "Window (no pane)", title: "Expanded panel",
                detail: "Which Studio panel is expanded to fill the window: sources, reader or search; none leaves them side by side.",
                key: "studio.expandedPanel", kind: .choice, absent: "none",
                options: [("none", "None"), ("sources", "Sources"), ("reader", "Reader"), ("search", "Search")]
            ),
            preferenceEntry(
                id: "window.center_tab_groups", pane: "Window (no pane)", title: "Center tab groups",
                detail: "The center pane's tab groups, in the stored form the window writes (strings). The whole list is replaced; one the window cannot read falls back to its default layout.",
                key: "studio.centerTabGroups.v1", kind: .stringList, absent: [String]()
            ),
            preferenceEntry(
                id: "window.chat_order", pane: "Navigation rail › Chats (no pane)", title: "Chat order",
                detail: "The order the learner gave the chats in the navigation rail, as chat ids; chats it leaves out keep their usual place. The whole list is replaced.",
                key: "studio.chatOrder", kind: .stringList, absent: [String]()
            ),
            preferenceEntry(
                id: "window.course_order", pane: "Courses tab (no pane)", title: "Course order",
                detail: "The Courses tab's order, as course ids, account-wide. The whole list is replaced.",
                key: "studio.courseOrder", kind: .stringList, absent: [String]()
            ),
            preferenceEntry(
                id: "window.rail_chats_expanded", pane: "Navigation rail › Chats (no pane)", title: "Chats section open",
                detail: "Whether the navigation rail's Chats section is open. On by default.",
                key: "studio.navigation.chatsExpanded.v1", kind: .boolean, absent: true
            ),
            preferenceEntry(
                id: "window.rail_hidden_chats_expanded", pane: "Navigation rail › Chats (no pane)", title: "Hidden chats section open",
                detail: "Whether the navigation rail's Hidden chats section is open. Off by default.",
                key: "studio.navigation.hiddenChatsExpanded.v1", kind: .boolean, absent: false
            ),
            AppSettingEntry(
                id: "window.rail_hidden_items", pane: "Navigation rail (no pane)", title: "Hidden rail rows",
                detail: "The navigation rail's rows the learner hid, as a JSON array of row ids (\(StudioRailItem.allCases.map(\.rawValue).joined(separator: ", "))). [] shows every row.",
                reach: .account, kind: .text, preferenceKeys: [StudioRailHiddenItems.storageKey],
                read: { Self.railHiddenItemsJSON(UserDefaults.standard.string(forKey: StudioRailHiddenItems.storageKey) ?? "") },
                write: { value in
                    let text = try AppSettingEntry.string(value, "window.rail_hidden_items")
                    PreferenceStore.set(try Self.railHiddenItemsStorage(fromJSON: text), forKey: StudioRailHiddenItems.storageKey)
                }
            ),
            AppSettingEntry(
                id: "window.rail_shortcuts", pane: "Navigation rail (no pane)", title: "Icon strip shortcuts",
                detail: "The places kept on the icon strip, as a JSON array of place ids (\(StudioRailShortcut.offered(listsCanvases: true).map(\.key).joined(separator: ", "))). [] keeps none. Where each stands is window.rail_order.",
                reach: .account, kind: .text, preferenceKeys: [StudioRailShortcuts.storageKey],
                read: { Self.railShortcutsJSON(UserDefaults.standard.string(forKey: StudioRailShortcuts.storageKey) ?? "") },
                write: { value in
                    let text = try AppSettingEntry.string(value, "window.rail_shortcuts")
                    PreferenceStore.set(try Self.railShortcutsStorage(fromJSON: text), forKey: StudioRailShortcuts.storageKey)
                }
            ),
            AppSettingEntry(
                id: "window.rail_order", pane: "Navigation rail (no pane)", title: "Icon strip order",
                detail: "The order of the icon strip's top icons, its rows and the places kept there, as a JSON array of ids (\(Self.stripOrderIDs(footer: false).joined(separator: ", "))). An icon not listed stands after the one before it in the strip's own order; [] is the strip's own order.",
                reach: .account, kind: .text, preferenceKeys: [StudioStripOrder.topStorageKey],
                read: { Self.stripOrderJSON(UserDefaults.standard.string(forKey: StudioStripOrder.topStorageKey) ?? "") },
                write: { value in
                    let text = try AppSettingEntry.string(value, "window.rail_order")
                    PreferenceStore.set(
                        try Self.stripOrderStorage(fromJSON: text, footer: false, setting: "window.rail_order"),
                        forKey: StudioStripOrder.topStorageKey
                    )
                }
            ),
            AppSettingEntry(
                id: "window.rail_footer_order", pane: "Navigation rail (no pane)", title: "Icon strip footer order",
                detail: "The order of the icon strip's bottom icons as a JSON array of ids (\(Self.stripOrderIDs(footer: true).joined(separator: ", "))). An icon not listed stands after the one before it in the strip's own order; [] is the strip's own order.",
                reach: .account, kind: .text, preferenceKeys: [StudioStripOrder.footerStorageKey],
                read: { Self.stripOrderJSON(UserDefaults.standard.string(forKey: StudioStripOrder.footerStorageKey) ?? "") },
                write: { value in
                    let text = try AppSettingEntry.string(value, "window.rail_footer_order")
                    PreferenceStore.set(
                        try Self.stripOrderStorage(fromJSON: text, footer: true, setting: "window.rail_footer_order"),
                        forKey: StudioStripOrder.footerStorageKey
                    )
                }
            ),
            preferenceEntry(
                id: "window.integration_tab_unpin_applied", pane: "Window (no pane)", title: "Integration tabs already unpinned",
                detail: "Which integration tabs Studio's one-time unpin has already run for, as their ids. Taking one out lets the unpin run for it again. The whole list is replaced.",
                key: StudioSidebarTab.integrationUnpinAppliedPreferenceKey, kind: .stringList, absent: [String]()
            ),
        ]
    }

    // MARK: Reader and Docs

    @MainActor
    private static func readerAndDocSettingEntries() -> [AppSettingEntry] {
        let fraction = AppSettingEntry.Kind.number(min: 0, max: 1, step: nil)
        return [
            preferenceEntry(
                id: "reader.youtube_transcript_beside_video", pane: "Reader › Videos (no pane)", title: "Transcript beside the video",
                detail: "Whether a video's transcript sits beside it rather than below it.",
                key: "reader.youtubeTranscriptBesideVideo", kind: .boolean, absent: true
            ),
            preferenceEntry(
                id: "reader.youtube_video_pane_fraction", pane: "Reader › Videos (no pane)", title: "Video share of the pane",
                detail: "The video's share of the reader pane when the transcript is below it, from 0 to 1; 0 means automatic.",
                key: "reader.youtubeVideoPaneFraction", kind: fraction, absent: 0.0
            ),
            preferenceEntry(
                id: "reader.youtube_video_pane_width_fraction", pane: "Reader › Videos (no pane)", title: "Video share of the pane's width",
                detail: "The video's share of the reader pane's width when the transcript is beside it, from 0 to 1; 0 means automatic.",
                key: "reader.youtubeVideoPaneWidthFraction", kind: fraction, absent: 0.0
            ),
            preferenceEntry(
                id: "reader.meeting_video_pane_fraction", pane: "Reader › Meetings (no pane)", title: "Meeting recording share of the pane",
                detail: "A meeting recording's share of the reader pane, from 0 to 1; 0 means automatic.",
                key: "reader.meetingVideoPaneFraction", kind: fraction, absent: 0.0
            ),
            preferenceEntry(
                id: "reader.meeting_transcript_beside_video", pane: "Reader › Meetings (no pane)", title: "Meeting transcript beside the recording",
                detail: "Whether a meeting's transcript sits beside its recording rather than below it. Off by default.",
                key: "reader.meetingTranscriptBesideVideo", kind: .boolean, absent: false
            ),
            preferenceEntry(
                id: "reader.meeting_video_pane_width_fraction", pane: "Reader › Meetings (no pane)", title: "Meeting recording share of the pane's width",
                detail: "The recording's share of the reader pane's width when the transcript is beside it, from 0 to 1; 0 means automatic.",
                key: "reader.meetingVideoPaneWidthFraction", kind: fraction, absent: 0.0
            ),
            preferenceEntry(
                id: "docs.page_width", pane: "Doc editor (no pane)", title: "Doc page width",
                detail: "How wide a Doc's page is drawn, in points: 760 is Standard, 1040 Wide, and 0 fills the pane (Full Width). Any width from 400 can be set; the learner drags the page's edges for the same.",
                key: ArtifactPageWidth.key, kind: .number(min: 0, max: 4000, step: 1),
                absent: ArtifactPageWidth.standard, integer: true
            ),
        ]
    }

    // MARK: What the app remembers for the learner

    @MainActor
    private static func rememberedStateSettingEntries() -> [AppSettingEntry] {
        [
            preferenceEntry(
                id: "mcp.assistant_integrations_enabled", pane: "MCP", title: "Let assistants reach ForeverLM",
                detail: "Whether assistants may reach ForeverLM over MCP at all. On by default; turning it off closes the connection on every Mac of the account, this call's own connection included, so ask the learner first.",
                key: "studio.assistantIntegrationsEnabled", kind: .boolean, absent: true
            ),
            preferenceEntry(
                id: "getting_started.completed", pane: "Getting Started (no pane)", title: "Getting Started done",
                detail: "Whether Getting Started is done.",
                key: "gettingStarted.completed", kind: .boolean, absent: false
            ),
            preferenceEntry(
                id: "getting_started.dismissed", pane: "Getting Started (no pane)", title: "Getting Started put away",
                detail: "Whether Getting Started was put away.",
                key: "gettingStarted.dismissed", kind: .boolean, absent: false
            ),
            preferenceEntry(
                id: "getting_started.completed_steps", pane: "Getting Started (no pane)", title: "Getting Started steps done",
                detail: "Getting Started's finished steps, one bit each: bit 0 is the first step.",
                key: "gettingStarted.completedSteps", kind: .number(min: 0, max: 1_048_575, step: 1), absent: 0.0, integer: true
            ),
            preferenceEntry(
                id: "getting_started.ai_subscriptions", pane: "Getting Started (no pane)", title: "AI apps the learner pays for",
                detail: "Which AI apps the learner pays for, as setup asked: a comma-separated list of claude, chatgpt, grok, gemini or other, or none.",
                key: "gettingStarted.aiSubscriptions", kind: .text, absent: ""
            ),
            preferenceEntry(
                id: "background_ai.usage_consented", pane: "Getting Started › Background AI (no pane)", title: "Background AI usage agreed",
                detail: "Whether the learner agreed to background AI usage in Getting Started. It lets background work run on the account's spend, so set it only on the learner's own say-so.",
                key: KeychainService.backgroundAIUsageConsentKey, kind: .boolean, absent: false
            ),
            preferenceEntry(
                id: "chat.slow_free_model_offer_dismissed", pane: "Chat (no pane)", title: "Stop offering to leave a slow free model",
                detail: "Whether the learner chose Don't Ask Again on the offer to leave a slow free chat model. Off brings the offer back.",
                key: SlowFreeModelWait.dismissedKey, kind: .boolean, absent: false
            ),
            preferenceEntry(
                id: "courses.user_names", pane: "Sources sidebar › Courses (no pane)", title: "Course group names",
                detail: "The course group names the learner made, by name. The whole list is replaced.",
                key: "userCourseNames", kind: .stringList, absent: [String]()
            ),
            preferenceEntry(
                id: "meetings.user_group_names", pane: "Sources sidebar › Meetings (no pane)", title: "Meeting group names",
                detail: "The meeting group names the learner made, by name. The whole list is replaced.",
                key: "userMeetingGroupNames", kind: .stringList, absent: [String]()
            ),
            preferenceEntry(
                id: "meetings.removed_group_titles", pane: "Sources sidebar › Meetings (no pane)", title: "Meeting groups deleted, by title",
                detail: "The meeting groups the learner deleted, by title, so an import never brings one back. Taking a title out lets an import make that group again. The whole list is replaced.",
                key: StudioViewModel.removedMeetingGroupTitlesKey, kind: .stringList, absent: [String]()
            ),
            preferenceEntry(
                id: "meetings.removed_group_identities", pane: "Sources sidebar › Meetings (no pane)", title: "Meeting groups deleted, by identity",
                detail: "The meeting groups the learner deleted, by identity. Taking one out lets an import make that group again. The whole list is replaced.",
                key: StudioViewModel.removedMeetingGroupIdentitiesKey, kind: .stringList, absent: [String]()
            ),
        ]
    }

    // MARK: AI choices the model pickers remember

    @MainActor
    private static func aiChoiceSettingEntries() -> [AppSettingEntry] {
        [
            AppSettingEntry(
                id: "chat.your_models",
                pane: "Chat › Your Models",
                title: "Your Models",
                detail: "The models listed at the top of Settings › Chat, as OpenRouter slugs (e.g. anthropic/claude-opus-5.5, openrouter/free), in the order shown. Until the learner first edits it, it is the suggested and free picks. Being on the list is not being offered in the chat picker: set_chat_model_offered does that. A slug OpenRouter does not list, or whose model cannot call tools, is kept but not shown. Pass the whole list; [] empties it.",
                reach: .account,
                kind: .stringList,
                preferenceKeys: [ChatModelShortlist.preferenceKey],
                read: { ChatModelShortlist.current },
                write: { ChatModelShortlist.save(try AppSettingEntry.strings($0, "chat.your_models")) }
            ),
            AppSettingEntry(
                id: "background.your_models_text",
                pane: "Background › Your Models (Text-only and its tasks)",
                title: "Your Models for text work",
                detail: "The models listed at the top of Settings › Background › Text-only, and of each task that reads text, as OpenRouter slugs in the order shown. Until the learner first edits it, it is the suggested and free picks for background work. Being on the list does not pick a model: set_ai_task_settings does that. A slug OpenRouter does not list, or whose model cannot call tools, is kept but not shown. Pass the whole list; [] empties it.",
                reach: .account,
                kind: .stringList,
                preferenceKeys: [ChatModelShortlist.backgroundTextKey],
                read: { ChatModelShortlist.currentBackground(readsImages: false) },
                write: {
                    ChatModelShortlist.save(
                        try AppSettingEntry.strings($0, "background.your_models_text"), key: ChatModelShortlist.backgroundTextKey)
                }
            ),
            AppSettingEntry(
                id: "background.your_models_images",
                pane: "Background › Your Models (Multimodal and its tasks)",
                title: "Your Models for work that reads images",
                detail: "The models listed at the top of Settings › Background › Multimodal, and of each task that reads images, as OpenRouter slugs in the order shown. Until the learner first edits it, it is the suggested and free picks for that work. Being on the list does not pick a model: set_ai_task_settings does that. A slug OpenRouter does not list, or whose model cannot read images or call tools, is kept but not shown. Pass the whole list; [] empties it.",
                reach: .account,
                kind: .stringList,
                preferenceKeys: [ChatModelShortlist.backgroundImagesKey],
                read: { ChatModelShortlist.currentBackground(readsImages: true) },
                write: {
                    ChatModelShortlist.save(
                        try AppSettingEntry.strings($0, "background.your_models_images"), key: ChatModelShortlist.backgroundImagesKey)
                }
            ),
            preferenceEntry(
                id: "chat.default_effort", pane: "Chat › effort control (no pane)", title: "Default chat effort",
                detail: "The effort last chosen from a chat's effort control; a chat with no effort of its own starts on it. none is no reasoning at all. A model that does not offer the effort uses its nearest one.",
                key: AIModelPreferenceKey.defaultChatEffort, kind: .choice, absent: "",
                options: AIEffort.allCases.map { ($0.rawValue, $0.rawValue) }
            ),
            preferenceEntry(
                id: "ai.text_routing_mode", pane: "AI Models (no pane)", title: "Text routing",
                detail: "How text requests are routed. ForeverLM has one router, OpenRouter; the account's managed state sets this, and nothing else is offered.",
                key: AIModelPreferenceKey.textRoutingMode, kind: .choice, absent: AITextRoutingMode.shippedDefault.rawValue,
                options: AITextRoutingMode.allCases.map { ($0.rawValue, $0.rawValue) }
            ),
            preferenceEntry(
                id: "ai.anthropic_model_picked", pane: "AI Models (no pane)", title: "Anthropic model picked by hand",
                detail: "Whether the learner picked Anthropic's model by hand rather than taking the default. Off lets a newer default replace it.",
                key: "anthropic_model_explicitly_picked", kind: .boolean, absent: false
            ),
            preferenceEntry(
                id: "ai.openai_model_picked", pane: "AI Models (no pane)", title: "OpenAI model picked by hand",
                detail: "Whether the learner picked OpenAI's model by hand rather than taking the default. Off lets a newer default replace it.",
                key: "openai_model_explicitly_picked", kind: .boolean, absent: false
            ),
        ]
    }

    // MARK: Speech instructions

    @MainActor
    private static func speechInstructionSettingEntries() -> [AppSettingEntry] {
        [
            preferenceEntry(
                id: "read_aloud.openai_instructions", pane: "Voice › Text to Speech (no pane)", title: "OpenAI speaking instructions",
                detail: "Hand-written speaking instructions sent with each text-to-speech request to OpenAI's voices, such as the pace and tone to read in. Empty sends none.",
                key: MacArticleSpeechSettings.openAIInstructionsDefaultsKey, kind: .text, absent: ""
            ),
            preferenceEntry(
                id: "read_aloud.local_qwen3_instructions", pane: "Voice › Text to Speech (no pane)", title: "Local server speaking instructions",
                detail: "Hand-written speaking instructions sent with each text-to-speech request to the local Qwen3 server. Empty sends none.",
                key: MacArticleSpeechSettings.localQwen3InstructionsDefaultsKey, kind: .text, absent: ""
            ),
            AppSettingEntry(
                id: "read_aloud.apple_model", pane: "Voice › Text to Speech (no pane)", title: "On-device engine model",
                detail: "The on-device text-to-speech engine's model id. AVSpeech is the only engine there is; empty goes back to it.",
                reach: .account, kind: .text, preferenceKeys: [KeychainService.Key.ttsModelApple.rawValue],
                read: { MacArticleSpeechSettings.model(for: .apple) },
                write: { value in
                    MacArticleSpeechSettings.setModel(try AppSettingEntry.string(value, "read_aloud.apple_model"), for: .apple)
                }
            ),
        ]
    }
}
