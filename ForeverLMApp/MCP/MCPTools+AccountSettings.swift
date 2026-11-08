import Foundation
import AppKit

// MARK: - Account controls of the Settings window, from a chat
//
// The Settings controls that act on the learner's account rather than on a
// plain preference: the Teams panes (rename, delete, leave, open a team's
// library, the invitation link), the AI Models pane's chat model list (which
// models the chat picker offers), and the AI Usage pane's monthly spending
// limit. Each tool goes through the exact call the pane's own control makes,
// so the window and a chat cannot accept different things.
//
// What stays in the window: unlocking MCP (Stripe Checkout),
// and managing team members (Apple's sharing sheet). Those are refused here
// with a pointer to `open_settings`. Balance is no longer sold (retired
// 2026-09-25), so there is nothing to add or top up.
//
// Gathered by `settingsParityToolDefs` / `executeSettingsParityTool` in
// MCPTools+AppSettings.swift.

extension MCPToolRegistry {

    static var accountSettingsToolDefs: [MCPToolDef] {
        [
            MCPToolDef(
                name: "rename_team",
                description: "Rename a team this account owns — Settings › Data & Privacy › Teams › the team's ⋯ menu › Rename…, or Team General's name field. The new name is what every member sees and what an invitee sees on the invitation before accepting; it syncs to every member through iCloud. Only the owner can rename (a member's pane says so), and this refuses a member's team the same way. team_id comes from list_teams. Returns the team.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "team_id": ["type": "string", "description": "The team's id from list_teams."],
                        "name": ["type": "string", "description": "The new name; leading and trailing spaces are trimmed and it cannot be empty."],
                    ],
                    "required": ["team_id", "name"],
                ]
            ),
            MCPToolDef(
                name: "delete_team",
                description: "Delete a team this account owns — Settings › Data & Privacy › Teams › Delete Team. The team's iCloud zone is deleted, so the team and every copy in it disappear for every member at once; everyone's originals stay in their own My Library. This cannot be undone. Only the owner can delete; a member is refused and pointed at leave_team. Always ask the learner first, naming the team and saying that it goes for every member. If the team's library is open in ForeverLM, the Studio goes back to My Library.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "team_id": ["type": "string", "description": "The team's id from list_teams. Must be a team whose role is owner."],
                    ],
                    "required": ["team_id"],
                ]
            ),
            MCPToolDef(
                name: "leave_team",
                description: "Leave a team someone else owns — Settings › Data & Privacy › Teams › Leave Team. This account stops being a member: the team's copies are removed from this account's devices, and its own sources, Notebooks, Docs and chats stay in My Library. Rejoining needs a new invitation from the owner. The owner cannot leave their own team (delete_team instead). Ask the learner first. If the team's library is open in ForeverLM, the Studio goes back to My Library.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "team_id": ["type": "string", "description": "The team's id from list_teams. Must be a team whose role is member."],
                    ],
                    "required": ["team_id"],
                ]
            ),
            MCPToolDef(
                name: "open_team_library",
                description: "Switch the ForeverLM Studio on this Mac to a team's library, or back to My Library — Settings › Data & Privacy › Teams › Open Library, and the library switcher in the account menu. Everything on screen (sources, Notebooks, Docs, chats) is then the chosen library's; selections pointing into the previous library are dropped. Changes only this Mac's window, not the account. Omit team_id for My Library. Needs a Studio window open.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "team_id": ["type": "string", "description": "The team's id from list_teams. Omit (or pass an empty string) for My Library."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "get_team_invitation_link",
                description: "Get a team's invitation link — Settings › Data & Privacy › Teams › Copy Invitation Link — and put it on this Mac's clipboard as the button does. For a team this account owns, this opens the team's iCloud share to anyone with the link, at read and write, exactly as the owner's Copy Link does: whoever gets the link can join the team and edit its library. Ask the owner before calling it unless they just asked for the link. For a member, the link is returned as it stands (only people the owner admitted can open it). Adding or removing named members is Apple's sharing sheet, which stays in the window (open_settings team_members).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "team_id": ["type": "string", "description": "The team's id from list_teams."],
                    ],
                    "required": ["team_id"],
                ]
            ),
            MCPToolDef(
                name: "get_chat_models_offered",
                description: "Read Settings › Chat › Models as it stands: the models the chat picker offers (the ticked cards), each with its provider, model id, name, whether it is the Default Model, and whether the learner added it from the OpenRouter directory (user_added). This is the account's list and syncs across the learner's devices. The full catalogue, with prices, is in get_ai_task_settings (catalogue, enabled_for_chat); set_chat_model_offered changes the list.",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
            MCPToolDef(
                name: "set_chat_model_offered",
                description: "Offer a model in the chat picker or stop offering it — Settings › Chat › Models, the same as tapping the model's card. provider and model are as get_ai_task_settings lists them in catalogue (provider id such as anthropic, openai, gemini, openrouter; the model id). offered true ticks the card; a model OpenRouter's directory lists that the catalogue does not yet carry is added to the catalogue and offered, as the pane's directory browser does (it must accept tools, since chat always sends them). offered false unticks it; the Default Model cannot be unticked — pick another default first (set_ai_task_settings target default_model). remove_from_catalog true (with offered false) also removes a user-added model from the catalogue, the card's Remove from catalog. Changes the account's list, synced across the learner's devices; any open chat picker updates at once, and a chat currently on an unticked model goes back to the default. Ask before changing the list unasked. Returns the resulting offered list.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "provider": ["type": "string", "description": "The provider id, e.g. anthropic, openai, gemini, openrouter."],
                        "model": ["type": "string", "description": "The model id, e.g. claude-sonnet-5 or deepseek/deepseek-v4-pro."],
                        "offered": ["type": "boolean", "description": "true to offer the model in the chat picker, false to stop offering it."],
                        "remove_from_catalog": ["type": "boolean", "description": "Only with offered false, and only for a user_added model: also remove it from the catalogue."],
                    ],
                    "required": ["provider", "model", "offered"],
                ]
            ),
            MCPToolDef(
                name: "get_billing_settings",
                description: "Read the ForeverLM account behind Settings › Billing (unlocking MCP) and AI Usage (the key and the monthly spending limit), freshly fetched from the account server as those panes do when they open. The app is free; MCP, the assistant connection, is the paid part: 7 free days begin at the first sign-in, and then MCP is paid once (the Early user deal), with no subscription; an account that has not paid by then has MCP locked until it does, and nothing else changes and nothing in the library is deleted. No monthly plan is sold; one bought before still counts as paid while it is active. AI is never part of the price and never locked: the learner's own OpenRouter API key pays for every model, billed by OpenRouter at cost, and ForeverLM adds nothing. OpenRouter is the only supported provider. Returns whether the learner is signed in; the plan (state free_days, paid_once, monthly, comped, family or locked; whether MCP is unlocked, when the free days end, how many are left and how many an account gets; a monthly plan's renewal and price) and the plans on sale with the account server's prices (once, the Early user deal, recommended); a summary of the learner's own router key (details in get_own_router_key); any balance left over from before prepaid balance was retired, which still pays for requests sent without the key until it runs out and cannot be added to; and the monthly spending limit (current value, what has been spent this month, whether it is reached, when it resets, and the options the pane's picker offers, including no_limit). This is account state, the same on every device.",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
            MCPToolDef(
                name: "set_billing_settings",
                description: "Change the monthly spending limit in AI Usage › Spending exactly as the pane's picker does. monthly_spending_limit takes one of the picker's values: no_limit, or a dollar amount from monthly_spending_limit.options in get_billing_settings (5, 10, 20, 50, 100, 250). When the month's AI spend reaches the limit, AI pauses until the month resets; a limit below what has already been spent pauses AI at once. That changes whether AI keeps working, so ask the learner first. Unlocking MCP goes through Stripe Checkout, which only the learner can complete: use open_settings billing. The own OpenRouter key is set with set_own_router_key. Returns what get_billing_settings returns, after the change.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "monthly_spending_limit": ["description": "no_limit, or one of the picker's dollar amounts: 5, 10, 20, 50, 100, 250."],
                    ],
                    "required": ["monthly_spending_limit"],
                ]
            ),
        ]
    }

    static let accountSettingsReadOnlyToolNames: Set<String> = [
        "get_chat_models_offered",
        "get_billing_settings",
    ]
}

extension MCPDataStore {

    func executeAccountSettingsTool(name: String, arguments: [String: Any]) async throws -> String? {
        switch name {
        case "rename_team":
            return try await renameTeamTool(teamID: arguments["team_id"] as? String, name: arguments["name"] as? String)
        case "delete_team":
            return try await deleteTeamTool(teamID: arguments["team_id"] as? String)
        case "leave_team":
            return try await leaveTeamTool(teamID: arguments["team_id"] as? String)
        case "open_team_library":
            return try await openTeamLibraryTool(teamID: arguments["team_id"] as? String)
        case "get_team_invitation_link":
            return try await teamInvitationLinkTool(teamID: arguments["team_id"] as? String)
        case "get_chat_models_offered":
            let offered = await Self.offeredChatModels()
            return try jsonString([
                "settings_pane": "Settings › Chat › Models",
                "reach": "account",
                "count": offered.count,
                "offered": offered,
                "guidance": "set_chat_model_offered ticks or unticks one; get_ai_task_settings has the whole catalogue with prices.",
            ] as [String: Any])
        case "set_chat_model_offered":
            return try await setChatModelOffered(
                provider: arguments["provider"] as? String,
                model: arguments["model"] as? String,
                offered: arguments["offered"],
                removeFromCatalog: arguments["remove_from_catalog"]
            )
        case "get_billing_settings":
            let payload = try await Self.billingSettingsPayload(refresh: true)
            return try jsonString(payload)
        case "set_billing_settings":
            return try await setBillingSettings(monthlySpendingLimit: arguments["monthly_spending_limit"])
        default:
            return nil
        }
    }

    // MARK: - Teams

    private func requireTeamRecord(_ rawTeamID: String?) async throws -> TeamRecord {
        let teamID = (rawTeamID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !teamID.isEmpty else {
            throw MCPError.invalidInput("team_id is required. Use list_teams to find it.")
        }
        guard let team = try await notebookFileStorage.loadTeam(teamID) else {
            throw MCPError.notFound("No team with id \(teamID) on this Mac. Use list_teams.")
        }
        return team
    }

    func renameTeamTool(teamID rawTeamID: String?, name: String?) async throws -> String {
        let team = try await requireTeamRecord(rawTeamID)
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPError.invalidInput("A team needs a name.")
        }
        guard team.role == .owner else {
            throw MCPError.invalidInput("Only the owner can rename ‘\(team.name)’; this account is a member.")
        }
        let previous = team.name
        if trimmed != previous {
            do {
                try await notebookFileStorage.renameTeam(team.id, name: trimmed)
            } catch let error as KnowledgeStoreError {
                throw MCPError.invalidInput(error.localizedDescription)
            }
            await Self.postTeamRosterDidChange(teamID: team.id)
        }
        let renamed = try await notebookFileStorage.loadTeam(team.id) ?? team
        let members = try await notebookFileStorage.loadTeamMembers(teamID: team.id)
        return try jsonString([
            "team": teamPayload(renamed, members: members),
            "changed": trimmed != previous,
            "previous_name": previous,
            "settings_pane": "Settings › Data & Privacy › Teams",
            "message": trimmed == previous
                ? "‘\(previous)’ already has that name."
                : "Renamed ‘\(previous)’ to ‘\(renamed.name)’. Every member sees the new name once iCloud syncs.",
        ] as [String: Any])
    }

    func deleteTeamTool(teamID rawTeamID: String?) async throws -> String {
        let team = try await requireTeamRecord(rawTeamID)
        guard team.role == .owner else {
            throw MCPError.invalidInput("Only the owner can delete ‘\(team.name)’; this account is a member. leave_team removes it from this account instead.")
        }
        do {
            try await notebookFileStorage.deleteTeam(team.id)
        } catch {
            throw MCPError.invalidInput("Could not delete ‘\(team.name)’: \(error.localizedDescription)")
        }
        await Self.teamLeftThisAccount(teamID: team.id)
        return try jsonString([
            "deleted": true,
            "team_id": team.id,
            "team_name": team.name,
            "settings_pane": "Settings › Data & Privacy › Teams",
            "message": "Deleted ‘\(team.name)’. The team and its copies are gone for every member; everyone's originals stay in their own library.",
        ] as [String: Any])
    }

    func leaveTeamTool(teamID rawTeamID: String?) async throws -> String {
        let team = try await requireTeamRecord(rawTeamID)
        guard team.role == .member else {
            throw MCPError.invalidInput("This account owns ‘\(team.name)’, and an owner cannot leave their own team. delete_team removes it for everyone.")
        }
        do {
            try await notebookFileStorage.leaveTeam(team.id)
        } catch {
            throw MCPError.invalidInput("Could not leave ‘\(team.name)’: \(error.localizedDescription)")
        }
        await Self.teamLeftThisAccount(teamID: team.id)
        return try jsonString([
            "left": true,
            "team_id": team.id,
            "team_name": team.name,
            "settings_pane": "Settings › Data & Privacy › Teams",
            "message": "Left ‘\(team.name)’. The team's copies are removed from this account's devices; its own sources, Notebooks, Docs and chats stay in My Library. Rejoining needs a new invitation from the owner.",
        ] as [String: Any])
    }

    func openTeamLibraryTool(teamID rawTeamID: String?) async throws -> String {
        let teamID = (rawTeamID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var team: TeamRecord?
        if !teamID.isEmpty {
            team = try await requireTeamRecord(teamID)
        }
        let active = try await Self.setActiveLibrary(teamID: team?.id)
        if let team {
            guard active == team.id else {
                throw MCPError.invalidInput("ForeverLM could not open ‘\(team.name)’; the Studio does not list that team yet. Try again in a moment.")
            }
        }
        let library: [String: Any]
        if let team {
            library = ["team_id": team.id, "name": team.name]
        } else {
            library = ["team_id": NSNull(), "name": "My Library"]
        }
        return try jsonString([
            "active_library": library,
            "reach": "this_mac",
            "message": "The Studio now shows \(team.map { "‘\($0.name)’" } ?? "My Library").",
        ] as [String: Any])
    }

    func teamInvitationLinkTool(teamID rawTeamID: String?) async throws -> String {
        let team = try await requireTeamRecord(rawTeamID)
        guard let link = team.shareURL, let shareURL = URL(string: link) else {
            throw MCPError.invalidInput("‘\(team.name)’ has no invitation link yet; it appears once iCloud has shared the team. Try again shortly.")
        }
        let url: URL
        let openedToAnyone: Bool
        if team.role == .owner {
            do {
                url = try await notebookFileStorage.openTeamShareToAnyoneWithLink(team)
            } catch {
                throw MCPError.invalidInput("Could not open ‘\(team.name)’ to the link: \(error.localizedDescription)")
            }
            openedToAnyone = true
        } else {
            url = shareURL
            openedToAnyone = false
        }
        await Self.copyToPasteboard(url.absoluteString)
        return try jsonString([
            "team_id": team.id,
            "team_name": team.name,
            "url": url.absoluteString,
            "copied_to_clipboard": true,
            "anyone_with_link_can_join": openedToAnyone,
            "message": openedToAnyone
                ? "Copied the invitation link for ‘\(team.name)’. Anyone with it can join the team and edit its library."
                : "Copied the invitation link for ‘\(team.name)’. Only people the owner admitted can open it.",
        ] as [String: Any])
    }

    @MainActor
    private static func postTeamRosterDidChange(teamID: String?) {
        NotificationCenter.default.post(name: TeamSharingService.teamRosterDidChange, object: teamID)
    }

    /// What `StudioViewModel.deleteTeam` / `leaveTeam` do after the storage
    /// call; without a Studio window, the roster notification tells Settings
    /// and the rail to reload.
    @MainActor
    private static func teamLeftThisAccount(teamID: String) async {
        if let studio = AppModelBridge.studio {
            await studio.teamWasRemoved(teamID)
            await studio.loadTeams()
        } else {
            NotificationCenter.default.post(name: TeamSharingService.teamRosterDidChange, object: nil)
        }
    }

    /// Returns the library the Studio shows afterwards (nil for My Library).
    @MainActor
    private static func setActiveLibrary(teamID: String?) async throws -> String? {
        let studio = try AppModelBridge.requireStudio()
        if let teamID, studio.team(id: teamID) == nil {
            // A team created or joined moments ago may not be in the
            // Studio's list yet; `setActiveTeam` only opens listed teams.
            await studio.loadTeams()
        }
        await studio.setActiveTeam(teamID)
        return studio.activeTeamID
    }

    @MainActor
    private static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Chat model list

    @MainActor
    static func offeredChatModels() -> [[String: Any]] {
        let enabled = AIModelCatalog.enabledIDs
        let defaultID = AIModelCatalog.defaultEntry?.id
        return AIModelCatalog.allEntries
            .filter { enabled.contains($0.id) }
            .map { entry in
                [
                    "id": entry.id,
                    "provider": aiProviderJSON(entry.provider),
                    "model": entry.modelID,
                    "name": entry.displayName,
                    "is_default": entry.id == defaultID,
                    "user_added": AIModelCatalog.isCustom(entry),
                    "selectable": AIProvider.activeChatProviders.contains(entry.provider)
                        && !AIModelDefaults.isRetiredChatModel(provider: entry.provider, model: entry.modelID),
                ] as [String: Any]
            }
    }

    func setChatModelOffered(provider rawProvider: String?, model rawModel: String?, offered rawOffered: Any?, removeFromCatalog rawRemove: Any?) async throws -> String {
        guard let rawOffered, !(rawOffered is NSNull) else {
            throw MCPError.invalidInput("Pass offered: true to offer the model in the chat picker, false to stop offering it.")
        }
        let offered = try AppSettingEntry.bool(rawOffered, "offered")
        let remove: Bool
        if let rawRemove, !(rawRemove is NSNull) {
            remove = try AppSettingEntry.bool(rawRemove, "remove_from_catalog")
        } else {
            remove = false
        }
        if remove, offered {
            throw MCPError.invalidInput("remove_from_catalog goes with offered false.")
        }
        var payload = try await Self.applyChatModelOffered(
            provider: rawProvider ?? "",
            model: rawModel ?? "",
            offered: offered,
            removeFromCatalog: remove
        )
        await PreferenceStore.flushPendingWrites()
        let list = await Self.offeredChatModels()
        payload["offered_models"] = list
        payload["offered_count"] = list.count
        payload["settings_pane"] = "Settings › Chat › Models"
        payload["reach"] = "account"
        return try jsonString(payload)
    }

    /// The card tap, the directory browser's add, and Remove from catalog, in
    /// the pane's order: a directory model is added (which ticks it), and the
    /// default can neither be unticked nor removed.
    @MainActor
    private static func applyChatModelOffered(provider rawProvider: String, model rawModel: String, offered: Bool, removeFromCatalog: Bool) async throws -> [String: Any] {
        let providerText = rawProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerText.isEmpty, !modelID.isEmpty else {
            throw MCPError.invalidInput("Pass provider and model together, as get_ai_task_settings lists them in catalogue.")
        }
        guard let provider = aiProvider(named: providerText) else {
            throw MCPError.invalidInput("Unknown provider \(providerText). Providers: \(AIProvider.activeChatProviders.map(\.slashToken).joined(separator: ", ")).")
        }
        var result: [String: Any] = [
            "provider": aiProviderJSON(provider),
            "model": modelID,
            "offered": offered,
        ]

        if !offered {
            guard let entry = AIModelCatalog.entry(provider: provider, modelID: modelID) else {
                // Nothing in the catalogue means nothing in the picker.
                result["changed"] = false
                result["message"] = "\(modelID) is not in the \(provider.shortName) catalogue, so the chat picker does not offer it."
                return result
            }
            if AIModelCatalog.isDefault(entry) {
                throw MCPError.invalidInput("\(entry.displayName) is the Default Model, which the chat picker always offers. Pick another default first (set_ai_task_settings target default_model), then untick this one.")
            }
            if removeFromCatalog {
                guard AIModelCatalog.isCustom(entry) else {
                    throw MCPError.invalidInput("\(entry.displayName) is part of ForeverLM's own catalogue; only a model the learner added from a directory can be removed. Pass offered false alone to untick it.")
                }
                switch entry.provider {
                case .openRouter: AIModelCatalog.removeCustomOpenRouterModel(id: entry.modelID)
                default: break
                }
                result["changed"] = true
                result["removed_from_catalog"] = true
                result["message"] = "Removed \(entry.displayName) from the catalogue; the chat picker no longer offers it."
                return result
            }
            let wasOffered = AIModelCatalog.isEnabled(entry)
            if wasOffered {
                AIModelCatalog.setEnabled(false, for: entry)
            }
            result["changed"] = wasOffered
            result["name"] = entry.displayName
            result["message"] = wasOffered
                ? "The chat picker no longer offers \(entry.displayName)."
                : "The chat picker already did not offer \(entry.displayName)."
            return result
        }

        // offered true
        guard AIProvider.activeChatProviders.contains(provider) else {
            throw MCPError.invalidInput("\(provider.shortName) is not offered on this account right now. Providers: \(AIProvider.activeChatProviders.map(\.slashToken).joined(separator: ", ")).")
        }
        if AIModelCatalog.hidesTrainingModels, AIModelDefaults.trainsOnInputs(provider: provider, model: modelID) {
            throw MCPError.invalidInput("\(AIModelCatalog.displayName(provider: provider, modelID: modelID)) trains on what is sent to it, and “\(AIDataPolicy.switchTitle)” is on under \(AIDataPolicy.settingsLocation). Turn it off first (set_ai_task_settings target data_privacy, hide_training_models false).")
        }
        if AIModelDefaults.isRetiredChatModel(provider: provider, model: modelID) {
            throw MCPError.invalidInput("\(AIModelCatalog.displayName(provider: provider, modelID: modelID)) is retired and cannot be offered.")
        }

        if let entry = AIModelCatalog.entry(provider: provider, modelID: modelID) {
            let wasOffered = AIModelCatalog.isEnabled(entry)
            if !wasOffered {
                AIModelCatalog.setEnabled(true, for: entry)
            }
            result["changed"] = !wasOffered
            result["name"] = entry.displayName
            result["message"] = wasOffered
                ? "The chat picker already offers \(entry.displayName)."
                : "The chat picker now offers \(entry.displayName)."
            return result
        }

        // Not in the catalogue yet: a directory model the learner adds.
        switch provider {
        case .openRouter:
            let directory: [OpenRouterDirectoryModel]
            do {
                directory = try await OpenRouterCatalogAvailability.shared.models()
            } catch {
                throw MCPError.invalidInput("Could not read OpenRouter's model directory: \(error.localizedDescription)")
            }
            guard let model = directory.first(where: { $0.id.caseInsensitiveCompare(modelID) == .orderedSame }) else {
                throw MCPError.invalidInput("OpenRouter's directory has no model \(modelID). Use the slug OpenRouter lists, e.g. deepseek/deepseek-v4-pro.")
            }
            guard model.supportsTools else {
                throw MCPError.invalidInput("\(model.name) does not accept tools, and chat always sends them, so it cannot be offered.")
            }
            if AIModelCatalog.cataloguedOpenRouterSlugs.contains(model.id.lowercased()) || AIModelCatalog.cataloguedOpenRouterSlugs.contains(model.id) {
                throw MCPError.invalidInput("\(model.name) is already in the catalogue under its own provider. Find it in get_ai_task_settings' catalogue and pass that provider and model.")
            }
            if AIModelCatalog.hidesTrainingModels, AIModelDefaults.trainsOnInputs(provider: .openRouter, model: model.id) {
                throw MCPError.invalidInput("\(model.name) trains on what is sent to it, and “\(AIDataPolicy.switchTitle)” is on under \(AIDataPolicy.settingsLocation).")
            }
            AIModelCatalog.addCustomOpenRouterModel(
                AIModelCatalog.CustomOpenRouterModel(
                    id: model.id,
                    name: model.name,
                    inputUSDPerMTokens: model.inputUSDPerMTokens,
                    outputUSDPerMTokens: model.outputUSDPerMTokens,
                    contextLength: model.contextLength,
                    supportsTools: model.supportsTools,
                    supportsTemperature: model.supportsTemperature,
                    supportsVision: model.supportsVision
                )
            )
            guard let added = AIModelCatalog.entry(provider: .openRouter, modelID: model.id), AIModelCatalog.isEnabled(added) else {
                throw MCPError.invalidInput("ForeverLM did not add \(model.name) to the catalogue.")
            }
            result["model"] = model.id
            result["changed"] = true
            result["added_to_catalog"] = true
            result["name"] = added.displayName
            result["message"] = "Added \(added.displayName) from OpenRouter's directory; the chat picker now offers it."
            return result
        default:
            throw MCPError.invalidInput("\(modelID) is not in the \(provider.shortName) catalogue. Pick a model from get_ai_task_settings' catalogue; only OpenRouter's directory can add models beyond it.")
        }
    }

    // MARK: - Billing

    /// The Billing and AI Usage panes' account state as data. `refresh` re-reads the balance from the
    /// account server first, as the pane does when it appears.
    @MainActor
    static func billingSettingsPayload(refresh: Bool) async throws -> [String: Any] {
        let account = try AppModelBridge.requireAccount()
        if refresh {
            await account.refresh()
        }
        var payload: [String: Any] = [
            "settings_pane": "Settings › Billing for unlocking MCP; AI Usage for the key and the monthly spending limit",
            "reach": "account",
            "signed_in": account.isSignedIn,
        ]
        if let own = account.ownKey {
            payload["own_key"] = [
                "router": own.router.rawValue,
                "label": own.router.label,
                "last_four": own.suffix,
                "details": "get_own_router_key",
            ] as [String: Any]
        } else {
            payload["own_key"] = NSNull()
        }
        payload["ai_billing"] = "Bring your own key: the learner's own OpenRouter API key pays for every model, billed by OpenRouter at cost, and ForeverLM adds nothing. OpenRouter is the only supported provider. The key runs for every signed-in account: the app is free, and only MCP is paid for."
        // MCP is the paid part (product owner, 2026-10-10, 2026-10-11 and
        // 2026-10-16): 7 days free, then the Early user deal, paid once, and
        // nothing else on sale (`AppAccess.plansOnSale`). Prices and the count
        // of free days are the account server's.
        let prices = account.planPrices
        let onSale = account.appAccess?.plansOnSale ?? ManagedAI.AppAccess.paidAppPlans
        payload["plans"] = onSale.map { plan -> [String: Any] in
            switch plan {
            case .once:
                return [
                    "id": plan.rawValue, "name": EarlyUserDealOffer.title,
                    "price_usd": prices.onceCents.map { Double($0) / 100 } ?? NSNull(),
                    "billed": "once, no subscription", "recommended": true,
                ]
            }
        }
        if let access = account.appAccess {
            payload["plan"] = [
                "state": access.state.rawValue,
                "plan": access.plan ?? NSNull(),
                "unlocked": access.unlocked,
                "locked": account.isMCPLocked,
                "free_until": access.freeUntil.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
                "free_days_left": account.freeDaysLeft.map { $0 as Any } ?? NSNull(),
                "free_days_total": access.freeDaysTotal.map { $0 as Any } ?? NSNull(),
                "founding": access.founding,
                "renews_at": access.renewsAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
                "price_usd": access.subscriptionPriceCents.map { Double($0) / 100 } ?? NSNull(),
                "cancel_at_period_end": access.cancelAtPeriodEnd,
                "payment_failed": access.paymentFailed,
                "trialing": access.trialing,
            ] as [String: Any]
        } else {
            payload["plan"] = NSNull()
        }
        payload["only_in_the_settings_window"] = [
            "Unlock MCP through Stripe Checkout (the Early user deal, paid once), switch a monthly plan bought before to paid once, or cancel it: Cancel Plan… (which asks why) and the billing portal (open_settings billing). Only the learner can complete a checkout.",
            "Sign in with Apple (open_settings billing).",
        ]
        if let message = account.balanceErrorMessage ?? account.errorMessage {
            payload["error"] = message
        }
        guard account.isSignedIn else {
            payload["message"] = "Not signed in to ForeverLM AI, so there is no plan, balance or limit to show. Signing in is the learner's own step (open_settings billing)."
            return payload
        }
        guard let balance = account.balance else {
            payload["message"] = "The balance could not be loaded from the account server; see error."
            return payload
        }

        // The pane shows the balance only while some is left; the figure is
        // reported either way so an assistant can say there is none.
        var balanceJSON: [String: Any] = [
            "remaining_usd": balance.usd,
            "remaining_text": ManagedAI.creditBalanceText(microUSD: balance.microUSD),
            "shown_in_pane": balance.microUSD > 0 || balance.billingExempt || balance.disabled,
            "note": "Left over from before prepaid balance was retired; it pays for requests sent without the own key until it runs out and cannot be added to.",
            "ai_paused_nothing_pays": balance.isEmpty,
            "account_disabled": balance.disabled,
            "usage_comped": account.usageIsComped,
        ]
        if let comp = balance.comp {
            balanceJSON["comp_spent_this_month_usd"] = comp.spentThisMonthUSD
            if let spentToday = comp.spentTodayMicroUSD {
                balanceJSON["comp_spent_today_usd"] = Double(spentToday) / 1_000_000
            }
        }
        payload["balance"] = balanceJSON

        let cap = balance.spendCap
        let capValue: Any = cap.limitUSD.map { Int($0.rounded()) as Any } ?? "no_limit"
        var capJSON: [String: Any] = [
            "value": capValue,
            "limit_usd": cap.limitUSD ?? NSNull(),
            "spent_this_month_usd": cap.spentThisMonthUSD,
            "reached": cap.isReached,
            "resets_at": cap.resetsAt ?? NSNull(),
            "maximum_usd": cap.maximumUSD,
            "options": ["no_limit" as Any] + ManagedAIAccountModel.spendCaps.map { $0 as Any },
        ]
        if let limit = cap.limitUSD, !ManagedAIAccountModel.spendCaps.contains(Int(limit.rounded())) {
            capJSON["note"] = "The current limit is not one of the picker's values; it was set elsewhere."
        }
        payload["monthly_spending_limit"] = capJSON

        return payload
    }

    func setBillingSettings(monthlySpendingLimit rawLimit: Any?) async throws -> String {
        guard let rawLimit, !(rawLimit is NSNull) else {
            // `ManagedAIAccountModel` is @MainActor; so are its statics.
            let spendCaps = await MainActor.run { ManagedAIAccountModel.spendCaps }
            throw MCPError.invalidInput("Pass monthly_spending_limit: no_limit or one of \(spendCaps.map(String.init).joined(separator: ", ")). Paying for ForeverLM needs Stripe Checkout: open_settings billing.")
        }
        let limitChange = try await Self.spendCapChoice(rawLimit)
        let changed = try await Self.applyBillingSettings(limitChange: limitChange)
        var payload = try await Self.billingSettingsPayload(refresh: false)
        payload["changed"] = changed
        return try jsonString(payload)
    }

    /// nil is "No limit"; otherwise one of the picker's amounts.
    @MainActor
    private static func spendCapChoice(_ value: Any) throws -> Int? {
        let options = ManagedAIAccountModel.spendCaps
        let refusal = MCPError.invalidInput("monthly_spending_limit takes no_limit or one of: \(options.map(String.init).joined(separator: ", ")).")
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["no_limit", "no limit", "none", "off"].contains(trimmed) { return nil }
            let digits = trimmed.hasPrefix("$") ? String(trimmed.dropFirst()) : trimmed
            guard let number = Double(digits), let amount = Int(exactly: number), options.contains(amount) else { throw refusal }
            return amount
        }
        if let number = value as? NSNumber, !(value is Bool) {
            let double = number.doubleValue
            guard let amount = Int(exactly: double), options.contains(amount) else { throw refusal }
            return amount
        }
        throw refusal
    }

    /// Through `setSpendCap`, the pane's own call. It reports failure in
    /// `errorMessage` rather than throwing; that sentence is what the learner
    /// would have read under the pane.
    @MainActor
    private static func applyBillingSettings(limitChange: Int?) async throws -> [String] {
        let account = try AppModelBridge.requireAccount()
        await account.refresh()
        guard account.isSignedIn else {
            throw MCPError.invalidInput("Not signed in to ForeverLM AI. Signing in is the learner's own step: open_settings billing.")
        }
        guard let balance = account.balance else {
            throw MCPError.invalidInput(account.balanceErrorMessage ?? "The Billing settings could not be loaded from the account server; try again.")
        }
        var changed: [String] = []
        let current = balance.spendCap.limitUSD.map { Int($0.rounded()) }
        if current != limitChange {
            guard !account.spendCapInFlight else {
                throw MCPError.invalidInput("A spending-limit change is already on its way; read get_billing_settings in a moment.")
            }
            await account.setSpendCap(monthlyLimitUSD: limitChange.map(Double.init))
            if let message = account.errorMessage {
                throw MCPError.invalidInput(message)
            }
            changed.append("monthly_spending_limit")
        }
        return changed
    }
}
