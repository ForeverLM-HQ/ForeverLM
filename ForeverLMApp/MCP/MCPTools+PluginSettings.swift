import Foundation

// MARK: - Plugins, calendars and feeds, from a chat
//
// The plugin rows, the Mac's Calendar pane and Settings › Feeds, each
// tool doing exactly what the pane's own button, toggle or checkbox does —
// the same service call, the same follow-up refresh, the same
// `.pluginConnectionChanged` announcement — so a chat and the window can never
// drift apart. Connecting a plugin stays in the window: it is the provider's
// consent page, which only the learner can answer (`open_settings`).
//
// Gathered by `settingsParityToolDefs` / `executeSettingsParityTool` in
// MCPTools+AppSettings.swift.

extension MCPToolRegistry {

    static var pluginSettingsReadOnlyToolNames: Set<String> {
        let names: Set<String> = ["get_plugin_connections", "get_calendar_settings", "list_journal_feeds"]
        return JournalWatch.isEnabled ? names : names.subtracting(journalFeedToolNames)
    }

    /// The Settings › Feeds tools, withheld while `JournalWatch.isEnabled` is off.
    static let journalFeedToolNames: Set<String> = [
        "list_journal_feeds", "follow_journal_feed", "unfollow_journal_feed",
    ]

    static var pluginSettingsToolDefs: [MCPToolDef] {
        allPluginSettingsToolDefs.filter { JournalWatch.isEnabled || !journalFeedToolNames.contains($0.name) }
    }

    private static var allPluginSettingsToolDefs: [MCPToolDef] {
        [
            MCPToolDef(
                name: "get_plugin_connections",
                description: "Read the Plugins place as the learner sees it: for each plugin whether it is connected, which account(s), and what connecting would take. X (each connected account with its user id, @username, whether it needs reconnecting, can post, last sync); YouTube (every connected account — channel title and id, whether its grant still works, which import source it follows — liked videos or the ForeverLM playlist — and its liked-import choice; automatic import on/off, the channels followed with their group_id, hidden channels); Google Drive (connected accounts with id and email, the meeting folders each reads); Calendar, the Mac's own (on/off, macOS permission) — the learner's day; Slack (workspaces with team_id, and each workspace's channels with id, name and whether ForeverLM may read it); GitHub (the account and the organisations the App is installed on); Linear and Notion (every connected workspace with its id); and the learner's own Build Your Own plugins (id, name, health, sources added). Every entry names its open_settings pane and the tool that disconnects it. Connecting any plugin needs the provider's consent page, so it cannot be done from a chat: offer open_settings with the pane named here. The Slack channel lists cost one Slack call per workspace; pass include_slack_channels false to skip them.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "include_slack_channels": ["type": "boolean", "description": "Optional, default true: list every connected Slack workspace's channels with their on/off state."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "disconnect_plugin",
                description: "Do exactly what a plugin pane's Disconnect / Turn Off / Remove Access button does. x: disconnects one X account (account_id is its user id or @username from get_plugin_connections; optional when only one is connected); its bookmark sync stops, imported posts stay. youtube: disconnects one YouTube account (account_id from get_plugin_connections, a channel title works too; optional when only one is connected); that account stops importing, followed channels and imported videos stay. google_drive: disconnects one Google account (account_id from get_plugin_connections; optional when only one is connected); its meeting folders stop importing, meetings already imported stay. apple_calendar: turns the Mac's Calendar off for ForeverLM (the macOS permission itself stays; the learner revokes that in System Settings) and forgets the calendar choice; the events stay in the calendar. slack: revokes one workspace's Slack tokens (account_id is its team_id; optional when only one). github: revokes ForeverLM's GitHub token (the GitHub App stays installed on the organisations). linear / notion: revokes one workspace's grant (account_id is its id, or its name; optional when only one). user_plugin: removes a Build Your Own plugin's access at once (account_id is its id or name); the sources it added stay — remove_connector_sources removes those. Google accounts, Slack, GitHub, Linear, Notion and user plugins follow the learner's account on every device; X, YouTube and Calendar are this Mac's. Reconnecting needs the provider's consent page again, so ALWAYS ask the learner before disconnecting anything.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "plugin": [
                            "type": "string",
                            "enum": MCPDataStore.disconnectablePlugins,
                            "description": "Which plugin to disconnect.",
                        ],
                        "account_id": ["type": "string", "description": "x: the X user id or @username; google_drive: the account id (or email); youtube: the account id (or channel title); slack: the workspace team_id (or name); linear: the workspace id, URL key or name; notion: the workspace id or name; user_plugin: the plugin id (or name). Optional when only one is connected."],
                    ],
                    "required": ["plugin"],
                ]
            ),
            MCPToolDef(
                name: "set_slack_channel_enabled",
                description: "Plugins › Slack: flip one channel's switch — whether ForeverLM may read that channel (read_slack_channel, search_slack_messages). Stored on the gateway against the learner's account, so it holds on every device. In a workspace read through the ForeverLM bot, a channel can only be switched on after the learner invites @ForeverLM to it (visible to everyone in the channel); such a channel is refused with that explanation. Get team_id and channel ids from get_plugin_connections. Letting ForeverLM read a channel the learner did not name is their call: ask before switching one on.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "team_id": ["type": "string", "description": "The workspace's team_id (or name). Optional when only one workspace is connected."],
                        "channel_id": ["type": "string", "description": "The channel's Slack id, e.g. C0123ABCD, or its name (#general)."],
                        "enabled": ["type": "boolean", "description": "true lets ForeverLM read the channel; false stops it."],
                    ],
                    "required": ["channel_id", "enabled"],
                ]
            ),
            MCPToolDef(
                name: "get_calendar_settings",
                description: "Read Plugins › Calendar — the Mac's Calendar app, which is the learner's day: whether it is on for ForeverLM, whether macOS granted access or refused it, every calendar the Mac holds (iCloud, Google, Exchange, subscriptions) with its id, title, account, whether it takes new events (writable) and whether it is shown (on_day: its events are what get_calendar_events reads and the Now chip shows), and new_events_calendar — the calendar create_calendar_event writes into unless told otherwise (the learner's choice, or the Calendar app's own default). selection_is_default true means the learner never narrowed the shown list, so every calendar but Birthdays is shown. The choice is this Mac's. Change with set_calendar_settings.",
                inputSchema: [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "set_calendar_settings",
                description: "Change Plugins › Calendar as its controls do, then return get_calendar_settings. apple_calendar_enabled: the pane's Turn On / Turn Off. Turning it on the first time makes macOS show its Calendar permission prompt on the learner's Mac, which only they can answer — tell them to look for it; if they refused before, it fails and they allow ForeverLM in System Settings › Privacy & Security › Calendars. Turning it off forgets the calendar choice; the macOS grant and every event stay. apple_calendar_ids: the whole list of calendars the day is read from (ids or titles from get_calendar_settings); every other calendar the Mac holds now is left off, and an account signed in afterwards (say Exchange, added in System Settings › Internet Accounts) has its calendars shown until a later list leaves them out. new_events_calendar_id: the calendar new events go to (an id or title of a writable calendar), or \"\" for the Calendar app's own default. Ask before removing calendars the learner did not mention.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "apple_calendar_enabled": ["type": "boolean", "description": "Optional: turn the Mac's Calendar on or off for ForeverLM."],
                        "apple_calendar_ids": ["type": "array", "items": ["type": "string"], "description": "Optional: every calendar to show, by id or title. Needs Calendar on."],
                        "new_events_calendar_id": ["type": "string", "description": "Optional: the writable calendar new events go to, by id or title; \"\" for the Calendar app's default. Needs Calendar on."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "follow_youtube_channel",
                description: "Plugins › YouTube › Followed channels › Follow: resolve a channel from its address or @handle, import its newest \(StudioViewModel.youtubeChannelFollowImportCount) uploads into a Videos group named after it, and keep importing every new upload in the background (this turns YouTube's automatic import on). Needs YouTube connected. The group follows the learner's library on every device. For a channel's older back catalog, add its playlist as a course instead. Returns the group_id (unfollow_youtube_channel takes it) and how many videos the group now holds.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "channel": ["type": "string", "description": "The channel's address (youtube.com/@handle, youtube.com/channel/UC…) or its @handle."],
                    ],
                    "required": ["channel"],
                ]
            ),
            MCPToolDef(
                name: "unfollow_youtube_channel",
                description: "Plugins › YouTube › Followed channels › Stop Following: stop importing a followed channel's new uploads. The videos already imported, and the group holding them, stay. group_id comes from get_plugin_connections (youtube.followed_channels); the channel's name works too. The liked-videos / ForeverLM-playlist import source is not a channel: switch it with follow_youtube_liked_videos or follow_youtube_foreverlm_playlist.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "group_id": ["type": "string", "description": "The followed channel's group id, or its name."],
                    ],
                    "required": ["group_id"],
                ]
            ),
            MCPToolDef(
                name: "list_journal_feeds",
                description: "Read Settings › Feeds: every feed this Mac follows — journals, blogs, newsletters, preprint listings — with its feed_id, title, feed and site address, when it was last checked, the last error if the check failed, and how many articles it has announced; plus the last check's summary and when the next check is due. New articles are matched to the learner's Notebooks and offered in each Notebook's sources. Feeds are this Mac's alone and do not sync. Check now is run_settings_action check_feeds_now; the match notification is set_app_setting feeds.notify_on_match.",
                inputSchema: [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "follow_journal_feed",
                description: "Settings › Feeds › Follow: follow a feed from a site's home page or its RSS/Atom link. The address is resolved to its feed (a journal's home page advertises one), stored on this Mac, and checked at once: its current articles are matched against the learner's Notebooks with the background AI model, which is billed like any background task. Several addresses may be given one per line. Returns the feeds added, the addresses that could not be followed and why, and any that were already followed.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "A home page or feed address; several may be separated by new lines."],
                    ],
                    "required": ["url"],
                ]
            ),
            MCPToolDef(
                name: "unfollow_journal_feed",
                description: "Settings › Feeds › the ✕ beside a feed: stop following it on this Mac. feed_id comes from list_journal_feeds; the feed's address works too. Pending suggestions it already made stay until the learner answers them. Ask before unfollowing a feed the learner did not name.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "feed_id": ["type": "string", "description": "The feed's id from list_journal_feeds, or its feed address."],
                    ],
                    "required": ["feed_id"],
                ]
            ),
        ]
    }
}

extension MCPDataStore {

    static let disconnectablePlugins = [
        "x", "youtube", "google_drive", "apple_calendar", "slack", "github", "linear", "notion", "user_plugin",
    ]

    /// The dispatch for `pluginSettingsToolDefs`; nil for any other name.
    func executePluginSettingsTool(name: String, arguments: [String: Any]) async throws -> String? {
        if !JournalWatch.isEnabled, MCPToolRegistry.journalFeedToolNames.contains(name) { return nil }
        switch name {
        case "get_plugin_connections":
            let includeChannels = try Self.pluginOptionalBool(arguments["include_slack_channels"], "include_slack_channels") ?? true
            return try await getPluginConnections(includeSlackChannels: includeChannels)
        case "disconnect_plugin":
            return try await disconnectPlugin(
                plugin: Self.pluginTrimmed(arguments["plugin"]),
                accountID: Self.pluginTrimmed(arguments["account_id"])
            )
        case "set_slack_channel_enabled":
            guard let enabled = try Self.pluginOptionalBool(arguments["enabled"], "enabled") else {
                throw MCPError.invalidInput("Pass enabled: true to let ForeverLM read the channel, false to stop it.")
            }
            return try await setSlackChannelEnabled(
                teamID: Self.pluginTrimmed(arguments["team_id"]),
                channel: Self.pluginTrimmed(arguments["channel_id"]),
                enabled: enabled
            )
        case "get_calendar_settings":
            return try jsonString(await calendarSettingsPayload())
        case "set_calendar_settings":
            return try await setCalendarSettings(arguments: arguments)
        case "follow_youtube_channel":
            return try await followYouTubeChannelMCP(channel: Self.pluginTrimmed(arguments["channel"]))
        case "unfollow_youtube_channel":
            return try await unfollowYouTubeChannelMCP(group: Self.pluginTrimmed(arguments["group_id"]))
        case "list_journal_feeds":
            return try jsonString(await Self.pluginJournalFeedsPayload(reload: true))
        case "follow_journal_feed":
            return try await followJournalFeed(text: arguments["url"] as? String)
        case "unfollow_journal_feed":
            return try await unfollowJournalFeed(feed: Self.pluginTrimmed(arguments["feed_id"]))
        default:
            return nil
        }
    }

    // MARK: - Argument helpers

    fileprivate static func pluginTrimmed(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    fileprivate static func pluginOptionalBool(_ value: Any?, _ name: String) throws -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        return try AppSettingEntry.bool(value, name)
    }

    fileprivate static func pluginOptionalStrings(_ value: Any?, _ name: String) throws -> [String]? {
        guard let value, !(value is NSNull) else { return nil }
        return try AppSettingEntry.strings(value, name)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    fileprivate static func pluginISO(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// One of several connected accounts: the one `requested` names by id or
    /// label, or the only one when nothing is named.
    static func pluginPick<T>(
        _ items: [T],
        requested: String?,
        id: (T) -> String,
        label: (T) -> String,
        what: String,
        argument: String = "account_id"
    ) throws -> T {
        if let requested {
            if let match = items.first(where: { id($0) == requested }) { return match }
            let loose = items.filter {
                id($0).caseInsensitiveCompare(requested) == .orderedSame
                    || label($0).caseInsensitiveCompare(requested) == .orderedSame
            }
            if loose.count == 1 { return loose[0] }
            let known = items.map { "\(id($0)) (\(label($0)))" }.joined(separator: ", ")
            throw MCPError.notFound("No connected \(what) \(requested). Connected: \(known.isEmpty ? "none" : known).")
        }
        guard items.count == 1 else {
            let known = items.map { "\(id($0)) (\(label($0)))" }.joined(separator: ", ")
            throw MCPError.invalidInput("More than one \(what) is connected; pass \(argument) as one of: \(known).")
        }
        return items[0]
    }

    /// The card's Disconnect: the window releases the groups no account reads
    /// any more; with no window open the grant is simply forgotten.
    private static func disconnectYouTubeAccountLikeThePane(_ accountID: String) async {
        if let studio = await AppModelBridge.studio {
            await studio.disconnectYouTubeAccount(accountID)
        } else {
            YouTubeService.shared.signOut(accountID: accountID)
        }
    }

    @MainActor
    fileprivate static func announcePluginConnectionChanged() {
        NotificationCenter.default.post(name: .pluginConnectionChanged, object: nil)
    }

    // MARK: - get_plugin_connections

    func getPluginConnections(includeSlackChannels: Bool) async throws -> String {
        async let slackAnswer = Self.slackWorkspaceConnection()
        async let githubAnswer = Self.githubConnection()
        async let linearAnswer = Self.linearConnection()
        async let notionAnswer = Self.notionConnection()

        var plugins: [[String: Any]] = []
        plugins.append(Self.xConnectionPayload())
        plugins.append(await youTubeConnectionPayload())
        plugins.append(await Self.googleDriveConnectionPayload())
        plugins.append(Self.appleCalendarConnectionPayload())
        plugins.append(await Self.slackConnectionPayload(await slackAnswer, includeChannels: includeSlackChannels))
        plugins.append(Self.githubConnectionPayload(await githubAnswer))
        plugins.append(Self.linearConnectionPayload(await linearAnswer))
        plugins.append(Self.notionConnectionPayload(await notionAnswer))
        plugins.append(await userPluginsPayload())

        return try jsonString([
            "plugins": plugins,
            "guidance": "Connecting a plugin needs the provider's consent page, which only the learner can answer: offer open_settings with the entry's open_settings pane. disconnect_plugin disconnects (ask first); set_slack_channel_enabled flips a Slack channel; follow_youtube_channel / unfollow_youtube_channel, set_connector_auto_import and set_youtube_channel_hidden manage YouTube; get_calendar_settings / set_calendar_settings choose the day's calendars, and get_calendar_events / create_calendar_event read and write the day.",
        ] as [String: Any])
    }

    private static func xConnectionPayload() -> [String: Any] {
        let service = XBookmarkService.shared
        let accounts = service.accounts
        return [
            "plugin": "x",
            "name": "X",
            "connected": !accounts.isEmpty,
            "needs_reconnect": accounts.contains { service.needsReauthentication(accountID: $0.id) },
            "reach": "this_mac",
            "open_settings": "x",
            "connect_requires": "Signing in to X in the sheet ForeverLM opens from Plugins › X › Connect (Add Another Account for a further one).",
            "imports": "The learner's X bookmarks, from every connected account. run_settings_action sync_x_bookmarks syncs them now. create_x_post posts as one account; pass account when several are connected.",
            "disconnect": "disconnect_plugin with plugin x and account_id",
            "accounts": accounts.map { account -> [String: Any] in
                var entry: [String: Any] = [
                    "id": account.id,
                    "needs_reconnect": service.needsReauthentication(accountID: account.id),
                    "can_post": service.canPost(accountID: account.id),
                ]
                if let username = account.username { entry["username"] = username }
                if let lastSync = service.lastSyncDate(accountID: account.id) {
                    entry["last_synced_at"] = pluginISO(lastSync)
                }
                return entry
            },
        ]
    }

    private func youTubeConnectionPayload() async -> [String: Any] {
        var row: [String: Any] = [
            "plugin": "youtube",
            "name": "YouTube",
            "connected": YouTubeService.shared.isSignedIn,
            "can_connect": YouTubeService.shared.canConnect,
            "automatic_import": StudioViewModel.isYouTubeAutoImportEnabled,
            "reach": "this_mac",
            "open_settings": "youtube",
            "connect_requires": "Google's consent page for youtube.readonly, opened from Plugins › YouTube › Connect.",
            "disconnect": "disconnect_plugin with plugin youtube and account_id when more than one account is connected",
            "tools": "set_connector_auto_import (automatic import), follow_youtube_liked_videos / follow_youtube_foreverlm_playlist (an account's import source; account when several are connected), follow_youtube_channel / unfollow_youtube_channel, set_youtube_channel_hidden, refresh_youtube_sources",
        ]
        let snapshot = YouTubeService.shared.snapshot()
        row["accounts"] = snapshot.accounts.map { account -> [String: Any] in
            var entry: [String: Any] = [
                "account_id": account.id,
                "name": account.title,
                "connected": !snapshot.disconnectedIDs.contains(account.id),
                "import_source": account.choices.source?.rawValue ?? "none",
                "liked_import_policy": account.choices.likedPolicy.rawValue,
            ]
            if let source = account.choices.source { entry["import_source_name"] = source.displayName }
            if let cutoff = account.choices.likedCutoff { entry["liked_import_cutoff"] = Self.pluginISO(cutoff) }
            return entry
        }
        row["needs_reconnect"] = !snapshot.disconnectedIDs.isEmpty
        do {
            let store = try knowledgeStore()
            let groups = try store.loadVideoPlaylistGroups()
            row["followed_channels"] = groups
                .filter { $0.value.autoImport && $0.value.connectorKind == StudioViewModel.youtubeChannelPluginKind }
                .sorted { $0.value.title.localizedCaseInsensitiveCompare($1.value.title) == .orderedAscending }
                .map { entry -> [String: Any] in
                    let metadata = entry.value
                    var channel: [String: Any] = [
                        "group_id": entry.key,
                        "title": metadata.title.isEmpty ? entry.key : metadata.title,
                        "uploads_playlist_url": metadata.playlistURL,
                    ]
                    if let refreshed = metadata.lastRefreshedAt { channel["last_refreshed_at"] = Self.pluginISO(refreshed) }
                    return channel
                }
            row["hidden_channels"] = try store.loadHiddenYouTubeChannels()
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
            row["library_error"] = error.localizedDescription
        }
        return row
    }

    private static func googleDriveConnectionPayload() async -> [String: Any] {
        // What the pane does on appear: an older build's single grant becomes
        // a named account first, so the list shows the address.
        _ = try? await GoogleDriveService.shared.adoptLegacyAccountIfNeeded()
        let service = GoogleDriveService.shared
        let accounts = service.connectedAccounts.sorted {
            $0.displayLabel.localizedCaseInsensitiveCompare($1.displayLabel) == .orderedAscending
        }
        let defaultAccountID = KeychainService.googleDriveDefaultAccountID
        let folders = await googleDriveFolders(accountIDs: accounts.map(\.id), defaultAccountID: defaultAccountID)
        var row: [String: Any] = [
            "plugin": "google_drive",
            "name": "Google Drive",
            "connected": service.isSignedIn,
            "has_folder_read_access": service.hasFolderReadAccess,
            "can_connect": service.canConnect,
            "reach": "account",
            "open_settings": "google_drive",
            "connect_requires": "Google's consent page and Drive's folder picker, from Plugins › Google Drive › Connect and Choose Folder (also how a folder is added).",
            "disconnect": "disconnect_plugin with plugin google_drive and account_id",
            "accounts": accounts.map { account -> [String: Any] in
                [
                    "id": account.id,
                    "email": account.email,
                    "display_name": account.displayName,
                    "label": account.displayLabel,
                    "is_default": account.id == defaultAccountID,
                    "meeting_folders": folders?.byAccount[account.id] ?? [],
                ]
            },
        ]
        if accounts.isEmpty, service.hasLegacyConnection {
            row["legacy_connection"] = true
        }
        if let strays = folders?.unattributed, !strays.isEmpty {
            row["folders_without_connected_account"] = strays
        }
        return row
    }

    @MainActor
    private static func googleDriveFolders(
        accountIDs: [String],
        defaultAccountID: String?
    ) -> (byAccount: [String: [[String: Any]]], unattributed: [[String: Any]])? {
        guard let studio = AppModelBridge.studio else { return nil }
        let attribution = GoogleDriveFolderAttribution(
            metadata: studio.meetingMetadata,
            accountIDs: accountIDs,
            defaultAccountID: defaultAccountID
        )
        func rows(_ folders: [GoogleDriveFolderAttribution.Folder]) -> [[String: Any]] {
            folders.map { folder in
                var row: [String: Any] = ["group_id": folder.groupID, "title": folder.title]
                if let url = folder.url { row["url"] = url.absoluteString }
                return row
            }
        }
        var byAccount: [String: [[String: Any]]] = [:]
        for id in accountIDs { byAccount[id] = rows(attribution.folders(for: id)) }
        return (byAccount, rows(attribution.unattributed))
    }

    private static func appleCalendarConnectionPayload() -> [String: Any] {
        let service = AppleCalendarService.shared
        return [
            "plugin": "apple_calendar",
            "name": "Calendar",
            "enabled": service.isEnabled,
            "connected": service.isConnected,
            "has_macos_access": service.hasFullAccess,
            "blocked_by_macos": service.isBlockedBySystem,
            "reach": "this_mac",
            "open_settings": "apple_calendar",
            "connect_requires": service.isBlockedBySystem
                ? "macOS refused Calendar access; the learner allows ForeverLM in System Settings › Privacy & Security › Calendars, then turns it on."
                : "Nothing but the learner's answer to macOS's Calendar prompt: set_calendar_settings with apple_calendar_enabled true turns it on.",
            "disconnect": "disconnect_plugin with plugin apple_calendar (or set_calendar_settings apple_calendar_enabled false)",
            "add_account": "macOS signs in to Microsoft Exchange (and Microsoft 365) and every other calendar account itself: the learner presses Add Exchange Account… in Plugins › Calendar (open_settings apple_calendar), which opens System Settings › Internet Accounts. The new account's calendars are shown as the day until the learner unticks them.",
            "calendars": "get_calendar_settings / set_calendar_settings",
            "day": "get_calendar_events, create_calendar_event, update_calendar_event, delete_calendar_event",
        ]
    }

    private static func slackConnectionPayload(_ answer: SlackWorkspaceConnection?, includeChannels: Bool) async -> [String: Any] {
        var row: [String: Any] = [
            "plugin": "slack",
            "name": "Slack",
            "reach": "account",
            "open_settings": "slack",
            "connect_requires": "Sign in with Apple in ForeverLM, then Slack's consent page from Plugins › Slack › Connect Slack… (more than one workspace can be connected).",
            "disconnect": "disconnect_plugin with plugin slack and account_id (the team_id)",
        ]
        switch answer {
        case .connected(let workspaces)?:
            row["status"] = "connected"
            row["connected"] = true
            var rows: [[String: Any]] = []
            for workspace in workspaces {
                var entry: [String: Any] = ["name": workspace.name]
                if let count = workspace.channelCount { entry["enabled_channel_count"] = count }
                if let teamID = workspace.teamID {
                    entry["team_id"] = teamID
                    if includeChannels {
                        do {
                            let picker = try await slackWorkspaceChannels(teamID: teamID)
                            entry["reads_without_joining"] = picker.readsWithoutJoining
                            entry["channels"] = picker.channels.map { slackChannelPayload($0, readsWithoutJoining: picker.readsWithoutJoining) }
                        } catch {
                            entry["channels_error"] = error.localizedDescription
                        }
                    }
                }
                rows.append(entry)
            }
            row["workspaces"] = rows
        case .notConnected?:
            row["status"] = "not_connected"
            row["connected"] = false
        case .signedOut?:
            row["status"] = "signed_out"
            row["connected"] = false
        case nil:
            row["status"] = "unknown"
            row["note"] = "The ForeverLM gateway did not answer; try again."
        }
        return row
    }

    fileprivate static func slackChannelPayload(_ channel: SlackChannelChoice, readsWithoutJoining: Bool) -> [String: Any] {
        [
            "id": channel.id,
            "name": channel.name,
            "is_private": channel.isPrivate,
            "is_member": channel.isMember,
            "enabled": channel.enabled,
            "can_enable": readsWithoutJoining || channel.isMember,
        ]
    }

    private static func githubConnectionPayload(_ answer: GitHubConnection?) -> [String: Any] {
        var row: [String: Any] = [
            "plugin": "github",
            "name": "GitHub",
            "reach": "account",
            "open_settings": "github",
            "connect_requires": "Connecting on the ForeverLM GitHub page (https://app.foreverlm.com/github-connect) in a browser, and installing the ForeverLM GitHub App on the organisations to read.",
            "disconnect": "disconnect_plugin with plugin github",
        ]
        switch answer {
        case .connected(let account)?:
            row["status"] = "connected"
            row["connected"] = true
            if let login = account.login { row["login"] = login }
            if let name = account.name { row["account_name"] = name }
            row["reconnect_required"] = account.reconnectRequired
            row["installations"] = account.installations.map { installation -> [String: Any] in
                var entry: [String: Any] = ["account": installation.account, "is_organization": installation.isOrganization]
                if let type = installation.accountType { entry["account_type"] = type }
                if let id = installation.installationID { entry["installation_id"] = id }
                return entry
            }
            if let error = account.installationsError { row["installations_error"] = error }
        case .notConnected?:
            row["status"] = "not_connected"
            row["connected"] = false
        case .signedOut?:
            row["status"] = "signed_out"
            row["connected"] = false
        case nil:
            row["status"] = "unknown"
        }
        return row
    }

    private static func linearConnectionPayload(_ answer: LinearConnection?) -> [String: Any] {
        var row: [String: Any] = [
            "plugin": "linear",
            "name": "Linear",
            "reach": "account",
            "open_settings": "linear",
            "connect_requires": "Plugins › Linear › Connect opens Linear's consent page in a sheet; connect again for each further workspace.",
            "disconnect": "disconnect_plugin with plugin linear and account_id (the workspace id, URL key or name) when more than one is connected",
        ]
        switch answer {
        case .connected(let workspaces)?:
            row["status"] = "connected"
            row["connected"] = true
            row["workspaces"] = workspaces.map { workspace -> [String: Any] in
                var entry: [String: Any] = ["id": workspace.id]
                if let name = workspace.name { entry["name"] = name }
                if let urlKey = workspace.urlKey { entry["url_key"] = urlKey }
                if let user = workspace.user { entry["user"] = user }
                return entry
            }
        case .notConnected?:
            row["status"] = "not_connected"
            row["connected"] = false
        case .signedOut?:
            row["status"] = "signed_out"
            row["connected"] = false
        case nil:
            row["status"] = "unknown"
        }
        return row
    }

    private static func notionConnectionPayload(_ answer: NotionConnection?) -> [String: Any] {
        var row: [String: Any] = [
            "plugin": "notion",
            "name": "Notion",
            "reach": "account",
            "open_settings": "notion",
            "connect_requires": "Plugins › Notion › Connect opens Notion's consent page in a sheet; connect again for each further workspace.",
            "disconnect": "disconnect_plugin with plugin notion and account_id (the workspace id or name) when more than one is connected",
        ]
        switch answer {
        case .connected(let workspaces)?:
            row["status"] = "connected"
            row["connected"] = true
            row["workspaces"] = workspaces.map { workspace -> [String: Any] in
                var entry: [String: Any] = ["id": workspace.id]
                if let name = workspace.name { entry["name"] = name }
                if let user = workspace.user { entry["user"] = user }
                return entry
            }
        case .notConnected?:
            row["status"] = "not_connected"
            row["connected"] = false
        case .signedOut?:
            row["status"] = "signed_out"
            row["connected"] = false
        case nil:
            row["status"] = "unknown"
        }
        return row
    }

    private func userPluginsPayload() async -> [String: Any] {
        let provider = await MCPOAuthProvider.sharedProvider()
        let summaries = await provider.userPluginSummaries()
        let counts = (try? knowledgeStore().activePluginSourceCounts()) ?? [:]
        return [
            "plugin": "user_plugin",
            "name": "Build Your Own",
            "reach": "this_mac",
            "open_settings": "build_your_own_plugin",
            "connect_requires": "The learner pastes the setup prompt from Plugins › Build Your Own into a coding assistant and approves the plugin once in ForeverLM.",
            "disconnect": "disconnect_plugin with plugin user_plugin and account_id (Remove Access); remove_connector_sources with connector_label removes its sources",
            "plugins": summaries.map { plugin -> [String: Any] in
                var row: [String: Any] = [
                    "id": plugin.id,
                    "name": plugin.name,
                    "sources_added": counts[plugin.name] ?? 0,
                    "needs_attention": plugin.needsAttention,
                ]
                if let state = plugin.reportedState { row["reported_state"] = state.rawValue }
                if let trouble = plugin.attentionSummary { row["attention"] = trouble }
                if let seen = plugin.lastSeenAt { row["last_seen_at"] = Self.pluginISO(seen) }
                if let synced = plugin.lastSuccessfulSyncAt { row["last_synced_at"] = Self.pluginISO(synced) }
                return row
            },
        ]
    }

    // MARK: - disconnect_plugin

    func disconnectPlugin(plugin rawPlugin: String?, accountID: String?) async throws -> String {
        guard let plugin = rawPlugin?.lowercased() else {
            throw MCPError.invalidInput("Pass plugin, one of: \(Self.disconnectablePlugins.joined(separator: ", ")).")
        }
        var result: [String: Any] = ["plugin": plugin]
        switch plugin {
        case "x":
            guard let account = try await Self.signOutOfXLikeThePane(requested: accountID) else {
                result["disconnected"] = false
                result["message"] = "X was not connected."
                break
            }
            result["disconnected"] = true
            result["account_id"] = account.id
            result["message"] = "Disconnected \(account.displayLabel) from X. Its bookmark sync stops; imported posts stay."

        case "youtube":
            let accounts = YouTubeService.shared.accounts
            guard !accounts.isEmpty else {
                result["disconnected"] = false
                result["message"] = "YouTube was not connected."
                break
            }
            let account = try Self.pluginPick(accounts, requested: accountID, id: \.id, label: \.title, what: "YouTube account")
            // The pane's Disconnect on that account's card.
            await Self.disconnectYouTubeAccountLikeThePane(account.id)
            result["disconnected"] = true
            result["account_id"] = account.id
            result["message"] = "Disconnected \(account.title) from YouTube. It stops importing; followed channels and imported videos stay."

        case "google_drive":
            _ = try? await GoogleDriveService.shared.adoptLegacyAccountIfNeeded()
            let service = GoogleDriveService.shared
            let accounts = service.connectedAccounts
            if accounts.isEmpty {
                guard service.hasLegacyConnection else {
                    result["disconnected"] = false
                    result["message"] = "No Google Drive account is connected."
                    break
                }
                // The pane's legacy-connection Disconnect.
                service.signOut()
                result["disconnected"] = true
                result["message"] = "Disconnected the Google Drive account."
                break
            }
            let account = try Self.pluginPick(accounts, requested: accountID, id: \.id, label: \.displayLabel, what: "Google Drive account")
            await service.signOut(accountID: account.id)
            result["disconnected"] = true
            result["account_id"] = account.id
            result["message"] = "Disconnected \(account.displayLabel) from Google Drive. Its meeting folders stop importing; meetings already imported stay."

        case "apple_calendar":
            let service = AppleCalendarService.shared
            guard service.isEnabled else {
                result["disconnected"] = false
                result["message"] = "Calendar was already off for ForeverLM."
                break
            }
            // The pane's Turn Off; disconnect announces the change.
            service.disconnect()
            result["disconnected"] = true
            result["message"] = "Turned the Mac's Calendar off for ForeverLM and forgot the calendar choice. The macOS permission stays, and so does every event."

        case "slack":
            guard case .connected(let workspaces)? = await Self.slackWorkspaceConnection() else {
                result["disconnected"] = false
                result["message"] = "No Slack workspace is connected (or the ForeverLM gateway did not answer)."
                break
            }
            let identified = workspaces.filter { $0.teamID != nil }
            let workspace = try Self.pluginPick(identified, requested: accountID, id: { $0.teamID ?? "" }, label: \.name, what: "Slack workspace")
            guard let teamID = workspace.teamID else { break }
            let stillConnected = try await Self.disconnectSlackWorkspace(teamID: teamID)
            if let answer = await Self.slackWorkspaceConnection() {
                await MainActor.run { GatewayPluginState.shared.slack = answer }
            }
            await Self.announcePluginConnectionChanged()
            result["disconnected"] = true
            result["team_id"] = teamID
            result["any_workspace_still_connected"] = stillConnected
            result["message"] = "Disconnected \(workspace.name). ForeverLM stops reading it and its Slack tokens are revoked."

        case "github":
            guard case .connected(let account)? = await Self.githubConnection() else {
                result["disconnected"] = false
                result["message"] = "GitHub is not connected (or the ForeverLM gateway did not answer)."
                break
            }
            let stillConnected = try await Self.disconnectGitHub()
            if let answer = await Self.githubConnection() {
                await MainActor.run { GatewayPluginState.shared.github = answer }
            }
            await Self.announcePluginConnectionChanged()
            result["disconnected"] = !stillConnected
            result["message"] = "Disconnected GitHub\(account.login.map { " (@\($0))" } ?? ""). Its token is revoked; the ForeverLM App stays installed on the organisations."

        case "linear":
            guard case .connected(let workspaces)? = await Self.linearConnection() else {
                result["disconnected"] = false
                result["message"] = "No Linear workspace is connected (or the ForeverLM gateway did not answer)."
                break
            }
            let workspace = try Self.pluginPick(
                workspaces,
                requested: accountID,
                id: \.id,
                label: { $0.label },
                what: "Linear workspace"
            )
            let stillConnected = try await Self.disconnectLinearWorkspace(id: workspace.id)
            if let answer = await Self.linearConnection() {
                await MainActor.run { GatewayPluginState.shared.linear = answer }
            }
            await Self.announcePluginConnectionChanged()
            result["disconnected"] = true
            result["workspace_id"] = workspace.id
            result["any_workspace_still_connected"] = stillConnected
            result["message"] = "Disconnected \(workspace.label). ForeverLM stops reading it and its Linear grant is revoked."

        case "notion":
            guard case .connected(let workspaces)? = await Self.notionConnection() else {
                result["disconnected"] = false
                result["message"] = "No Notion workspace is connected (or the ForeverLM gateway did not answer)."
                break
            }
            let workspace = try Self.pluginPick(
                workspaces,
                requested: accountID,
                id: \.id,
                label: { $0.label },
                what: "Notion workspace"
            )
            let stillConnected = try await Self.disconnectNotionWorkspace(id: workspace.id)
            if let answer = await Self.notionConnection() {
                await MainActor.run { GatewayPluginState.shared.notion = answer }
            }
            await Self.announcePluginConnectionChanged()
            result["disconnected"] = true
            result["workspace_id"] = workspace.id
            result["any_workspace_still_connected"] = stillConnected
            result["message"] = "Disconnected \(workspace.label). ForeverLM stops reading it and its Notion connection is revoked."

        case "user_plugin":
            let provider = await MCPOAuthProvider.sharedProvider()
            let plugins = await provider.userPluginSummaries()
            guard !plugins.isEmpty else {
                result["disconnected"] = false
                result["message"] = "No Build Your Own plugin is connected."
                break
            }
            let plugin = try Self.pluginPick(plugins, requested: accountID, id: \.id, label: \.name, what: "plugin")
            await provider.revokeClient(plugin.id)
            result["disconnected"] = true
            result["plugin_id"] = plugin.id
            result["message"] = "Removed \(plugin.name)'s access. It would need the learner's approval to reconnect; the sources it added stay (remove_connector_sources with connector_label \(plugin.name) removes them)."

        default:
            throw MCPError.invalidInput("plugin takes one of: \(Self.disconnectablePlugins.joined(separator: ", ")).")
        }
        return try jsonString(result)
    }

    /// Plugins › X › an account's Disconnect. Nil when no X account was
    /// connected; otherwise the account that was disconnected.
    @MainActor
    private static func signOutOfXLikeThePane(requested: String?) throws -> XAccount? {
        let studio = try AppModelBridge.requireStudio()
        let accounts = XBookmarkService.shared.accounts
        guard !accounts.isEmpty else { return nil }
        let bare = requested.map { $0.hasPrefix("@") ? String($0.dropFirst()) : $0 }
        let account = try pluginPick(accounts, requested: bare, id: \.id, label: { $0.username ?? $0.id }, what: "X account")
        studio.signOutOfX(accountID: account.id)
        return account
    }

    // MARK: - set_slack_channel_enabled

    func setSlackChannelEnabled(teamID requestedTeam: String?, channel requestedChannel: String?, enabled: Bool) async throws -> String {
        guard let requestedChannel else {
            throw MCPError.invalidInput("Pass channel_id, the Slack channel's id (or #name) from get_plugin_connections.")
        }
        guard case .connected(let workspaces)? = await Self.slackWorkspaceConnection() else {
            throw MCPError.invalidInput("No Slack workspace is connected (or the ForeverLM gateway did not answer). Connect one in Plugins › Slack (open_settings slack).")
        }
        let workspace = try Self.pluginPick(
            workspaces.filter { $0.teamID != nil },
            requested: requestedTeam,
            id: { $0.teamID ?? "" },
            label: \.name,
            what: "Slack workspace",
            argument: "team_id"
        )
        guard let teamID = workspace.teamID else {
            throw MCPError.invalidInput("That workspace has no team id.")
        }
        let picker = try await Self.slackWorkspaceChannels(teamID: teamID)
        let bareName = requestedChannel.hasPrefix("#") ? String(requestedChannel.dropFirst()) : requestedChannel
        guard let channel = picker.channels.first(where: { $0.id == requestedChannel })
            ?? picker.channels.first(where: { $0.name.caseInsensitiveCompare(bareName) == .orderedSame }) else {
            throw MCPError.notFound("\(workspace.name) has no channel \(requestedChannel) this account can see. get_plugin_connections lists them.")
        }
        if enabled, !picker.readsWithoutJoining, !channel.isMember {
            throw MCPError.invalidInput("\(workspace.name) is read through the ForeverLM bot: the learner has to invite @ForeverLM to #\(channel.name) first (the invitation is visible to everyone in the channel), then it can be switched on.")
        }
        var payload: [String: Any] = ["team_id": teamID, "workspace": picker.teamName ?? workspace.name]
        if channel.enabled == enabled {
            payload["changed"] = false
            payload["channel"] = Self.slackChannelPayload(channel, readsWithoutJoining: picker.readsWithoutJoining)
            return try jsonString(payload)
        }
        try await Self.setSlackChannel(teamID: teamID, channelID: channel.id, enabled: enabled)
        // The plugins list's row counts enabled channels; tell it the count moved.
        if let answer = await Self.slackWorkspaceConnection() {
            await MainActor.run { GatewayPluginState.shared.slack = answer }
        }
        await Self.announcePluginConnectionChanged()
        var updated = channel
        updated.enabled = enabled
        payload["changed"] = true
        payload["channel"] = Self.slackChannelPayload(updated, readsWithoutJoining: picker.readsWithoutJoining)
        payload["message"] = enabled
            ? "ForeverLM may now read #\(channel.name)."
            : "ForeverLM no longer reads #\(channel.name)."
        return try jsonString(payload)
    }

    // MARK: - Calendars

    func calendarSettingsPayload() async -> [String: Any] {
        let apple = AppleCalendarService.shared
        let appleSelection = apple.selectedIDs
        var applePayload: [String: Any] = [
            "pane": "Plugins › Calendar",
            "open_settings": "apple_calendar",
            "reach": "this_mac",
            "enabled": apple.isEnabled,
            "connected": apple.isConnected,
            "has_macos_access": apple.hasFullAccess,
            "blocked_by_macos": apple.isBlockedBySystem,
            "selection_is_default": appleSelection == nil,
            "new_events_calendar_is_default": apple.newEventsCalendarID == nil,
        ]
        if apple.isConnected {
            do {
                let calendars = try await apple.calendars()
                let target = try await apple.newEventsCalendar()
                let shown = Set(AppleCalendarService.shown(
                    from: calendars,
                    selectedIDs: appleSelection,
                    knownAccountIDs: apple.knownAccountIDs,
                    newEventsCalendarID: target?.id
                ).map(\.id))
                applePayload["calendars"] = calendars.map { calendar -> [String: Any] in
                    [
                        "id": calendar.id,
                        "title": calendar.title,
                        "account": calendar.account,
                        "is_birthdays": calendar.isBirthdays,
                        "is_subscribed": calendar.isSubscribed,
                        "writable": calendar.allowsModifications,
                        "on_day": shown.contains(calendar.id),
                    ]
                }
                if let target {
                    applePayload["new_events_calendar"] = ["id": target.id, "title": target.title, "account": target.account]
                }
            } catch {
                applePayload["calendars_error"] = error.localizedDescription
            }
        }
        return [
            "apple_calendar": applePayload,
            "how_to_change": "set_calendar_settings: apple_calendar_enabled, apple_calendar_ids (whole list), new_events_calendar_id.",
        ]
    }

    /// Each requested calendar by id, or by a title only one calendar has.
    private static func resolveCalendarIDs(
        _ requested: [String],
        in calendars: [(id: String, title: String)],
        what: String
    ) throws -> Set<String> {
        var resolved = Set<String>()
        var unknown: [String] = []
        for entry in requested {
            if calendars.contains(where: { $0.id == entry }) {
                resolved.insert(entry)
                continue
            }
            let byTitle = calendars.filter { $0.title.caseInsensitiveCompare(entry) == .orderedSame }
            if byTitle.count == 1 {
                resolved.insert(byTitle[0].id)
            } else {
                unknown.append(entry)
            }
        }
        guard unknown.isEmpty else {
            let known = calendars.map { "\($0.title) [\($0.id)]" }.joined(separator: ", ")
            throw MCPError.notFound("No single \(what) calendar matches \(unknown.joined(separator: ", ")). Calendars: \(known.isEmpty ? "none" : known).")
        }
        return resolved
    }

    func setCalendarSettings(arguments: [String: Any]) async throws -> String {
        let appleEnabled = try Self.pluginOptionalBool(arguments["apple_calendar_enabled"], "apple_calendar_enabled")
        let appleIDs = try Self.pluginOptionalStrings(arguments["apple_calendar_ids"], "apple_calendar_ids")
        let newEventsCalendar = (arguments["new_events_calendar_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard appleEnabled != nil || appleIDs != nil || newEventsCalendar != nil else {
            throw MCPError.invalidInput("Pass at least one of apple_calendar_enabled, apple_calendar_ids, new_events_calendar_id.")
        }
        if appleEnabled == false, appleIDs != nil || newEventsCalendar != nil {
            throw MCPError.invalidInput("apple_calendar_ids and new_events_calendar_id need Calendar on; don't pass them with apple_calendar_enabled false.")
        }
        var changes: [String] = []
        let apple = AppleCalendarService.shared

        if let appleEnabled {
            if appleEnabled {
                if !apple.isConnected {
                    // The pane's Turn On. The first time, macOS asks the
                    // learner for Calendar access.
                    do {
                        try await apple.connect()
                    } catch {
                        let hint = apple.isBlockedBySystem
                            ? " The learner allows ForeverLM in System Settings › Privacy & Security › Calendars, then tries again."
                            : ""
                        throw MCPError.invalidInput("Calendar could not be turned on: \(error.localizedDescription)\(hint)")
                    }
                    changes.append("Turned the Mac's Calendar on for ForeverLM.")
                }
            } else if apple.isEnabled {
                // The pane's Turn Off.
                apple.disconnect()
                changes.append("Turned the Mac's Calendar off for ForeverLM.")
            }
        }

        if appleIDs != nil || newEventsCalendar != nil {
            guard apple.isConnected else {
                throw MCPError.invalidInput("Calendar is off for ForeverLM; pass apple_calendar_enabled true first.")
            }
            let calendars = try await apple.calendars()
            var chosenIDs: Set<String>?
            if let appleIDs {
                let chosen = try Self.resolveCalendarIDs(appleIDs, in: calendars.map { (id: $0.id, title: $0.title) }, what: "Mac")
                // The checkbox's write: the whole list, in the pane's order.
                let ids = calendars.map(\.id).filter { chosen.contains($0) }
                apple.setSelectedIDs(ids, among: calendars)
                changes.append("Showing \(ids.count) calendar\(ids.count == 1 ? "" : "s") as the day.")
                chosenIDs = chosen
            }
            if let newEventsCalendar {
                if newEventsCalendar.isEmpty {
                    apple.setNewEventsCalendarID(nil)
                    changes.append("New events go to the Calendar app's default calendar.")
                } else {
                    let writable = calendars.filter(\.allowsModifications)
                    guard let id = try Self.resolveCalendarIDs([newEventsCalendar], in: writable.map { (id: $0.id, title: $0.title) }, what: "writable").first else {
                        throw MCPError.notFound("No writable calendar matches \(newEventsCalendar).")
                    }
                    apple.setNewEventsCalendarID(id)
                    changes.append("New events go to \(writable.first { $0.id == id }?.title ?? id).")
                }
            }
            // The calendar new events go to is in the day whatever the
            // choice (`AppleCalendarService.shown`).
            if let chosenIDs, let target = try await apple.newEventsCalendar(), !chosenIDs.contains(target.id) {
                changes.append("“\(target.title)” stays in the day too: new events go to it.")
            }
        }

        var payload = await calendarSettingsPayload()
        payload["changes"] = changes.isEmpty ? ["Nothing changed."] : changes
        return try jsonString(payload)
    }

    // MARK: - YouTube channels

    func followYouTubeChannelMCP(channel: String?) async throws -> String {
        guard let channel else {
            throw MCPError.invalidInput("Pass channel: the channel's address (youtube.com/@handle) or its @handle.")
        }
        guard YouTubeService.shared.isSignedIn else {
            throw MCPError.invalidInput("YouTube is not connected. The learner connects it in Plugins › YouTube (open_settings youtube).")
        }
        return try jsonString(try await Self.followYouTubeChannelLikeThePane(channel))
    }

    @MainActor
    private static func followYouTubeChannelLikeThePane(_ input: String) async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        let before = Set(studio.followedYouTubeChannelGroupIDs)
        guard let groupID = await studio.followYouTubeChannel(input) else {
            throw MCPError.invalidInput(studio.errorMessage ?? "Couldn’t follow that channel.")
        }
        var payload: [String: Any] = [
            "group_id": groupID,
            "channel": studio.videoPlaylistDisplayName(groupID),
            "already_followed": before.contains(groupID),
            "following": studio.followedYouTubeChannelGroupIDs.contains(groupID),
            "videos_in_group": studio.articles.filter { $0.parentGroup == groupID }.count,
            "automatic_import": StudioViewModel.isYouTubeAutoImportEnabled,
            "message": "Following \(studio.videoPlaylistDisplayName(groupID)): its newest uploads are in the Videos tab and every new one will be imported.",
        ]
        if let url = studio.videoPlaylistMetadata[groupID]?.playlistURL { payload["uploads_playlist_url"] = url }
        return payload
    }

    func unfollowYouTubeChannelMCP(group: String?) async throws -> String {
        guard let group else {
            throw MCPError.invalidInput("Pass group_id, a followed channel's group id from get_plugin_connections.")
        }
        var payload = try await Self.unfollowYouTubeChannelLikeThePane(group)
        // The view model only logs a failed save; read the library back.
        if let groupID = payload["group_id"] as? String,
           let stored = try? knowledgeStore().loadVideoPlaylistGroups()[groupID] {
            payload["still_following"] = stored.autoImport && stored.connectorKind == StudioViewModel.youtubeChannelPluginKind
        }
        return try jsonString(payload)
    }

    @MainActor
    private static func unfollowYouTubeChannelLikeThePane(_ requested: String) async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        let followed = studio.followedYouTubeChannelGroupIDs
        let groupID: String
        if followed.contains(requested) {
            groupID = requested
        } else {
            let byName = followed.filter { studio.videoPlaylistDisplayName($0).caseInsensitiveCompare(requested) == .orderedSame }
            guard byName.count == 1 else {
                let known = followed.map { "\(studio.videoPlaylistDisplayName($0)) [\($0)]" }.joined(separator: ", ")
                throw MCPError.notFound("No followed channel \(requested). Followed channels: \(known.isEmpty ? "none" : known).")
            }
            groupID = byName[0]
        }
        let title = studio.videoPlaylistDisplayName(groupID)
        await studio.unfollowYouTubePluginPlaylist(groupID)
        return [
            "group_id": groupID,
            "channel": title,
            "message": "Stopped following \(title). The videos already imported stay.",
        ]
    }

    // MARK: - Feeds

    @MainActor
    private static func pluginJournalFeedsPayload(reload: Bool) async -> [String: Any] {
        let runner = JournalWatchRunner.shared
        if reload { await runner.reload() }
        var payload: [String: Any] = [
            "pane": "Settings › Feeds",
            "reach": "this_mac",
            "count": runner.feeds.count,
            "feeds": runner.feeds.map { feed -> [String: Any] in
                var row: [String: Any] = [
                    "feed_id": feed.id,
                    "title": feed.title,
                    "feed_url": feed.feedURL,
                    "host": feed.host,
                    "added_at": pluginISO(feed.addedAt),
                    "article_count": feed.itemCount,
                ]
                if let site = feed.siteURL { row["site_url"] = site }
                if let checked = feed.lastCheckedAt { row["last_checked_at"] = pluginISO(checked) }
                if let succeeded = feed.lastSucceededAt { row["last_succeeded_at"] = pluginISO(succeeded) }
                if let error = feed.lastError { row["last_error"] = error }
                if runner.checkingFeedIDs.contains(feed.id) { row["checking"] = true }
                return row
            },
            "is_checking": runner.isChecking,
            "notify_on_match": UserDefaults.standard.bool(forKey: JournalWatch.notifyOnMatchKey),
            "tools": "follow_journal_feed, unfollow_journal_feed, run_settings_action check_feeds_now, set_app_setting feeds.notify_on_match",
        ]
        if let summary = runner.lastCheckSummary { payload["last_check_summary"] = summary }
        if let next = runner.nextCheckAt { payload["next_check_at"] = pluginISO(next) }
        return payload
    }

    func followJournalFeed(text: String?) async throws -> String {
        let input = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            throw MCPError.invalidInput("Pass url: a site's home page or its RSS link.")
        }
        guard !JournalWatch.candidateURLStrings(in: input).isEmpty else {
            throw MCPError.invalidInput("No web address in \(input). Pass a home page or feed link such as https://www.nature.com/nature.")
        }
        return try jsonString(try await Self.followJournalFeedLikeThePane(input))
    }

    @MainActor
    private static func followJournalFeedLikeThePane(_ text: String) async throws -> [String: Any] {
        let runner = JournalWatchRunner.shared
        await runner.reload()
        let before = Set(runner.feeds.map(\.id))
        let failures = await runner.addJournals(from: text)
        let added = runner.feeds.filter { !before.contains($0.id) }
        let attempted = JournalWatch.candidateURLStrings(in: text).count
        let alreadyFollowed = max(0, attempted - added.count - failures.count)
        var payload = await pluginJournalFeedsPayload(reload: false)
        payload["added"] = added.map { ["feed_id": $0.id, "title": $0.title, "feed_url": $0.feedURL] as [String: Any] }
        payload["failures"] = failures
        payload["already_followed_count"] = alreadyFollowed
        if added.isEmpty, !failures.isEmpty {
            throw MCPError.invalidInput("Could not follow: \(failures.joined(separator: "; "))")
        }
        payload["message"] = added.isEmpty
            ? "Already following \(attempted == 1 ? "that feed" : "those feeds")."
            : "Following \(added.map(\.title).joined(separator: ", ")); its articles are being matched to the learner's Notebooks."
        return payload
    }

    func unfollowJournalFeed(feed requested: String?) async throws -> String {
        guard let requested else {
            throw MCPError.invalidInput("Pass feed_id from list_journal_feeds.")
        }
        return try jsonString(try await Self.unfollowJournalFeedLikeThePane(requested))
    }

    @MainActor
    private static func unfollowJournalFeedLikeThePane(_ requested: String) async throws -> [String: Any] {
        let runner = JournalWatchRunner.shared
        await runner.reload()
        guard let feed = runner.feeds.first(where: { $0.id == requested })
            ?? runner.feeds.first(where: { $0.feedURL.caseInsensitiveCompare(requested) == .orderedSame })
            ?? runner.feeds.first(where: { ($0.siteURL ?? "").caseInsensitiveCompare(requested) == .orderedSame }) else {
            let known = runner.feeds.map { "\($0.title) [\($0.id)]" }.joined(separator: ", ")
            throw MCPError.notFound("No followed feed \(requested). Feeds: \(known.isEmpty ? "none" : known).")
        }
        await runner.removeFeed(feed.id)
        let gone = !runner.feeds.contains { $0.id == feed.id }
        guard gone else {
            throw MCPError.invalidInput("\(feed.title) could not be unfollowed; the library did not accept the change. Try again.")
        }
        var payload = await pluginJournalFeedsPayload(reload: false)
        payload["removed"] = ["feed_id": feed.id, "title": feed.title, "feed_url": feed.feedURL]
        payload["message"] = "Stopped following \(feed.title)."
        return payload
    }
}
