import AppKit
import SwiftUI
import Testing
@testable import ForeverLM

@Suite("Review slash commands")
struct ReviewSlashCommandTests {
    @Test("Learning workflow commands are discoverable")
    func learningCommandsAreDiscoverable() {
        let names = Set(ReviewSlashCommand.all.map(\.name))

        #expect(names.isSuperset(of: ["goal", "source", "today", "plan", "review", "notebook", "new"]))
        #expect(!names.contains("provider"))
        #expect(!names.contains("billing"))
    }

    /// Billing is the plan alone since 2026-09-28; usage, credits and the key
    /// are AI Usage.
    @Test("/settings sends the plan to Billing and spend to AI Usage")
    func settingsCommandSplitsBillingFromUsage() {
        #expect(ReviewSlashCommandParser.parseSettingsPane("billing") == .aiBilling)
        #expect(ReviewSlashCommandParser.parseSettingsPane("subscription") == .aiBilling)
        #expect(ReviewSlashCommandParser.parseSettingsPane("Usage") == .aiUsage)
        #expect(ReviewSlashCommandParser.parseSettingsPane("credits") == .aiUsage)
        #expect(ReviewSlashCommandParser.parseSettingsPane("key") == .aiUsage)
    }

    /// Plugins left Settings for a place of their own on 2026-10-13: /settings
    /// plugins opens that place, and names no Settings pane.
    @Test("/settings plugins names the Plugins place, not a Settings pane")
    func settingsCommandSendsPluginsToTheirPlace() {
        for token in ["plugins", "Plugin", "connectors", "external"] {
            #expect(ReviewSlashCommandParser.namesPlugins(token))
            #expect(ReviewSlashCommandParser.parseSettingsPane(token) == nil)
        }
        #expect(!ReviewSlashCommandParser.namesPlugins("billing"))
    }

    @Test("Commands preserve a multiword argument")
    func parsesMultiwordArgument() throws {
        let parsed = try #require(ReviewSlashCommandParser.parse("/goal quantum field theory"))

        #expect(parsed.command.kind == .goal)
        #expect(parsed.argument == "quantum field theory")
    }

    @Test("Command prefix excludes the free-form argument")
    func commandPrefixExcludesArgument() throws {
        let text = "/goal mitochondrial transplantation"
        let prefix = try #require(ReviewSlashCommandParser.commandPrefix(in: text))

        #expect(prefix.command.kind == .goal)
        #expect(String(text[prefix.range]) == "/goal")
    }

    @Test("Dynamic Notebook suggestions match the full title prefix")
    func notebookSuggestionsMatchFullTitlePrefix() throws {
        let notebook = try #require(ReviewSlashCommand.all.first { $0.kind == .notebook })
        let commands = ReviewSlashCommand.all.map { command in
            command.kind == .notebook
                ? command.withArguments([
                    .init(value: "Quantum Field Theory", display: "Switch to this notebook"),
                    .init(value: "Roman History", display: "Switch to this notebook"),
                ])
                : command
        }

        let suggestions = ReviewSlashCommandParser.suggestions(
            for: "/notebook Quantum F",
            commands: commands
        )

        #expect(notebook.name == "notebook")
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.completionText == "/notebook Quantum Field Theory")
    }

    @Test("Unknown slash text remains a normal chat message")
    func unknownCommandIsNotIntercepted() {
        #expect(ReviewSlashCommandParser.parse("/does-not-exist") == nil)
    }

    @Test("/site-prompt is offered beside /site, parses its hyphenated name and keeps the focus")
    func sitePromptIsDiscoverableAndParses() throws {
        func commandNames(_ text: String) -> [String] {
            ReviewSlashCommandParser.suggestions(for: text).compactMap { suggestion -> String? in
                guard case .command(let command) = suggestion.payload else { return nil }
                return command.name
            }
        }
        #expect(commandNames("/site") == ["site", "site-prompt"])
        #expect(commandNames("/site-") == ["site-prompt"])

        let parsed = try #require(ReviewSlashCommandParser.parse("/site-prompt the measurement tools"))
        #expect(parsed.command.kind == .sitePrompt)
        #expect(parsed.argument == "the measurement tools")
        #expect(ReviewSlashCommandParser.parse("/site-prompt")?.argument == nil)

        let text = "/site-prompt Anderson's measurement philosophy"
        let prefix = try #require(ReviewSlashCommandParser.commandPrefix(in: text))
        #expect(prefix.command.kind == .sitePrompt)
        #expect(String(text[prefix.range]) == "/site-prompt")

        // A completed command waits for the focus rather than running on Return.
        let row = try #require(ReviewSlashCommandParser.suggestions(for: "/site-p").first)
        #expect(row.completionText == "/site-prompt ")
        #expect(!row.runsImmediately)
        // The command is not a library search, so no rows are asked for after its name.
        #expect(ReviewSlashCommandParser.liveArgumentQuery(in: "/site-prompt mito") == nil)
    }

    @Test("The site prompt request names the plugin, save_site, the source-link form, the focus and the Notebook")
    func sitePromptRequestShape() {
        let bare = ReviewSlashCommandParser.sitePromptRequest(focus: nil, notebookTitle: nil)
        #expect(bare.contains("Use the ForeverLM plugin to make a ForeverLM site that explains"))
        #expect(bare.contains("save_site"))
        #expect(!bare.contains("publish_site"), "sites are not put on the web")
        #expect(bare.contains("[Title](foreverlm://source/SOURCE_ID)"))
        #expect(bare.contains("get_source_content"))
        #expect(bare.contains("fenced code block"))
        #expect(bare.contains("stays in my ForeverLM library"))
        #expect(!bare.contains("focused on"))
        #expect(!bare.contains("filed under"))

        let focused = ReviewSlashCommandParser.sitePromptRequest(
            focus: "  the measurement tools ",
            notebookTitle: "Mito Phenotyping"
        )
        #expect(focused.contains("focused on the measurement tools."))
        #expect(focused.contains("filed under my Notebook \u{201C}Mito Phenotyping\u{201D}"))
        #expect(focused.contains("home_notebook_id"))

        // Whitespace-only values count as absent.
        let blank = ReviewSlashCommandParser.sitePromptRequest(focus: "   ", notebookTitle: " ")
        #expect(blank == bare)
    }
}

@Suite("Review slash library rows")
struct ReviewSlashLibraryRowTests {
    private var sourceCommand: ReviewSlashCommand {
        ReviewSlashCommand.all.first { $0.kind == .source }!
    }

    @Test("/source, /doc and /site search the library rather than a fixed list")
    func libraryCommandsSearch() {
        let byName = Dictionary(uniqueKeysWithValues: ReviewSlashCommand.all.map { ($0.name, $0) })
        #expect(byName["source"]?.searchesArguments == true)
        #expect(byName["page"]?.searchesArguments == true)
        #expect(byName["page"]?.kind == .doc)
        // /doc is what /page was called while the feature was named Docs; it
        // still works, and it runs the same command.
        #expect(byName["doc"]?.searchesArguments == true)
        #expect(byName["doc"]?.kind == .doc)
        #expect(byName["site"]?.searchesArguments == true)
        #expect(byName["site"]?.kind == .site)
        #expect(byName["site"]?.takesArgument == true)
        #expect(byName["notebook"]?.searchesArguments == false)
    }

    @Test("/page adds one of the learner's Pages, and /doc still does")
    func pageIsTheCommandAndDocItsAlias() throws {
        let page = try #require(ReviewSlashCommandParser.parse("/page Mito notes"))
        #expect(page.command.kind == .doc)
        #expect(page.argument == "Mito notes")
        let doc = try #require(ReviewSlashCommandParser.parse("/doc Mito notes"))
        #expect(doc.command.kind == .doc)
        #expect(doc.argument == "Mito notes")
        #expect(ReviewSlashCommand.all.first { $0.name == "page" }?.summary == "Add one of your Pages to this chat")
        let names = ReviewSlashCommandParser.suggestions(for: "/pa").compactMap { suggestion -> String? in
            guard case .command(let command) = suggestion.payload else { return nil }
            return command.name
        }
        #expect(names == ["page"])
        #expect(SkillRecord.reservedNames.isSuperset(of: ["page", "doc"]))
    }

    @Test("/site is offered beside /source and /settings while its name is typed")
    func siteIsDiscoverable() {
        let names = ReviewSlashCommandParser.suggestions(for: "/s").compactMap { suggestion -> String? in
            guard case .command(let command) = suggestion.payload else { return nil }
            return command.name
        }
        #expect(names.contains("site"))
        #expect(names.contains("source"))
        #expect(ReviewSlashCommandParser.liveArgumentQuery(in: "/site mito")?.query == "mito")
        #expect(ReviewSlashCommandParser.parse("/site")?.command.kind == .site)
    }

    @Test("/video takes the concept as free text and never searches the library")
    func videoTakesConcept() throws {
        let byName = Dictionary(uniqueKeysWithValues: ReviewSlashCommand.all.map { ($0.name, $0) })
        #expect(byName["video"]?.kind == .video)
        #expect(byName["video"]?.takesArgument == true)
        #expect(byName["video"]?.searchesArguments == false)
        let parsed = try #require(ReviewSlashCommandParser.parse("/video why ATP synthase spins"))
        #expect(parsed.command.kind == .video)
        #expect(parsed.argument == "why ATP synthase spins")
        #expect(ReviewSlashCommandParser.parse("/video")?.command.kind == .video)
        let names = ReviewSlashCommandParser.suggestions(for: "/vi").compactMap { suggestion -> String? in
            guard case .command(let command) = suggestion.payload else { return nil }
            return command.name
        }
        #expect(names == ["video"])
    }

    @Test("A search command asks for the text after its name")
    func liveQueryIsTextAfterCommand() throws {
        let live = try #require(ReviewSlashCommandParser.liveArgumentQuery(in: "/source  bla "))
        #expect(live.command.kind == .source)
        #expect(live.query == "bla")

        #expect(ReviewSlashCommandParser.liveArgumentQuery(in: "/source") == nil)
        #expect(ReviewSlashCommandParser.liveArgumentQuery(in: "/notebook Qu") == nil)
        #expect(ReviewSlashCommandParser.liveArgumentQuery(in: "/page ")?.query == "")
        #expect(ReviewSlashCommandParser.liveArgumentQuery(in: "/page mito")?.command.kind == .doc)
        #expect(ReviewSlashCommandParser.liveArgumentQuery(in: "/doc ")?.query == "")
    }

    @Test("Library rows show only while they answer the current draft")
    func liveRowsMustMatchDraft() {
        let rows = ReviewSlashLiveArguments(
            commandName: "source",
            query: "bla",
            arguments: [
                .init(value: "Black holes", display: "Paper · Hawking", reference: "source:a"),
                .init(value: "Black holes", display: "Article · Wikipedia", reference: "source:b"),
            ]
        )

        let shown = ReviewSlashCommandParser.suggestions(for: "/source bla", liveArguments: rows)
        #expect(shown.count == 2)
        // Two sources sharing a title stay two rows, told apart by identity.
        #expect(Set(shown.map(\.id)).count == 2)
        #expect(shown.first?.reference?.reference == "source:a")
        #expect(shown.first?.isLibraryRow == true)

        // A keystroke later, the previous answer is stale and stays hidden.
        #expect(ReviewSlashCommandParser.suggestions(for: "/source blac", liveArguments: rows).isEmpty)
        // Rows for one command never leak into another.
        #expect(ReviewSlashCommandParser.suggestions(for: "/page bla", liveArguments: rows).isEmpty)
        #expect(ReviewSlashCommandParser.suggestions(for: "/doc bla", liveArguments: rows).isEmpty)
        // Without a search result there is nothing to show yet.
        #expect(ReviewSlashCommandParser.suggestions(for: "/source bla").isEmpty)
    }

    @Test("Fixed-list commands ignore library rows")
    func fixedCommandsIgnoreLiveRows() {
        let rows = ReviewSlashLiveArguments(commandName: "settings", query: "a", arguments: [
            .init(value: "zzz", display: "never shown", reference: "x"),
        ])
        let shown = ReviewSlashCommandParser.suggestions(for: "/settings a", liveArguments: rows)
        // "a" names both AI panes: "ai" by value, "usage" by its display, AI Usage.
        #expect(shown.map(\.title) == ["ai", "usage"])
        #expect(shown.first?.isLibraryRow == false)
    }

    @Test("Command rows and fixed tokens carry no reference")
    func plainRowsHaveNoReference() {
        let commands = ReviewSlashCommandParser.suggestions(for: "/so")
        #expect(commands.count == 1)
        #expect(commands.first?.reference == nil)
        #expect(commands.first?.completionText == "/source ")
    }
}

/// The popup's rows for `/source` and `/doc` come from a search the pane runs,
/// carried to the popup through `ReviewComposerDraft`. This hosts the overlay
/// the way the chat does and types, so the whole route — draft, search task,
/// stamped result, rendered rows — is exercised rather than the parser alone.
@Suite("Review slash library popup")
struct ReviewSlashLibraryPopupTests {
    @MainActor
    @Test("typing after /source runs the search and shows its rows; a new query replaces them")
    func typedQueryReachesThePopup() async {
        let composer = ReviewComposerDraft()
        composer.text = "/source bla"
        @MainActor final class QueryLog { var seen: [String] = [] }
        let log = QueryLog()

        let overlay = ReviewSlashSuggestionsOverlay(
            composer: composer,
            slashCommands: ReviewSlashCommand.all,
            mentions: [],
            resolveLiveArguments: { command, query in
                await MainActor.run { log.seen.append("\(command.name):\(query)") }
                guard query == "bla" else { return [] }
                return [
                    .init(value: "Black holes", display: "Paper · Hawking", reference: "source:a"),
                    .init(value: "Blast furnaces", display: "Article · Britannica", reference: "source:b"),
                ]
            },
            onSelect: { _ in }
        )
        .frame(width: 480, height: 300)

        let hosting = NSHostingView(rootView: overlay)
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 300)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        func settle() async {
            for _ in 0..<12 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                window.displayIfNeeded()
                await Task.yield()
            }
        }

        await settle()
        #expect(log.seen == ["source:bla"])
        let shown = ReviewSlashCommandParser.suggestions(
            for: composer.text,
            liveArguments: composer.liveArguments
        )
        #expect(shown.map(\.title) == ["Black holes", "Blast furnaces"])

        let labels = AccessibilityWalk.withAssistiveClient {
            AccessibilityWalk.elements(under: hosting)
        }.flatMap { $0.spokenStrings }
        #expect(labels.contains { $0.contains("Black holes") }, "popup rows not rendered: \(labels)")

        // Another keystroke: the old rows go stale at once and the new answer lands.
        composer.text = "/source blaz"
        #expect(ReviewSlashCommandParser.suggestions(for: composer.text, liveArguments: composer.liveArguments).isEmpty)
        await settle()
        #expect(log.seen == ["source:bla", "source:blaz"])
        #expect(composer.liveArguments?.query == "blaz")
        #expect(composer.liveArguments?.arguments.isEmpty == true)

        // Leaving the command clears the carried rows.
        composer.text = "plain text"
        await settle()
        #expect(composer.liveArguments == nil)
    }

    @Test("picker tokens resolve to source ids once each, books through their chapters")
    func tokensResolveToSourceIDs() {
        let ids = ReviewSlashCommandParser.sourceIDs(
            fromTokens: ["source:a", "b", "book:shelf", "a", " ", "book:empty"],
            chapterIDs: { $0 == "shelf" ? ["c1", "b", "c2"] : [] }
        )
        #expect(ids == ["a", "b", "c1", "c2"])
    }
}

/// `@slack`, `@linear` and `@github` are offered per connected plugin, and
/// only where the chat's mode carries the plugin's tools; the learner's
/// message goes as typed with the plugin's mark beside it.
@Suite("Chat plugin mentions")
struct ChatPluginMentionTests {
    typealias Mention = ChatPluginRequest.Mention

    @Test("A plugin is offered only where the chat's tool surface can answer it")
    func availabilityFollowsToolSurface() {
        #expect(ChatPlugin.availablePlugins(for: .assistant) == [.slack, .linear, .github, .notion])
        // Study chats carry the Slack tools (a reading group announces papers
        // there) but not Linear, GitHub or Notion.
        #expect(ChatPlugin.availablePlugins(for: .review) == [.slack])
        #expect(ChatPlugin.availablePlugins(for: .deepResearch) == [.slack])
        #expect(ChatPlugin.availablePlugins(for: .summarize) == [.slack])
    }

    @Test("Presence offers the connected plugins the mode can use, and keeps an unanswered one as it was")
    @MainActor
    func presenceFoldsGatewayAnswers() {
        let first = ChatPluginPresence.apply(
            slack: .connected(workspaces: [.init(name: "Acme Lab", channelCount: 4), .init(name: "Bench Lab", channelCount: nil)]),
            linear: .notConnected,
            github: .connected(.init(login: "robinvale", installations: [.init(installationID: 1, account: "ForeverLM-HQ", accountType: "Organization")])),
            notion: .connected(workspace: "Bench Lab", user: nil),
            to: (connected: [], slackWorkspaces: [])
        )
        #expect(first.connected == [.slack, .github, .notion])
        #expect(first.slackWorkspaces == ["Acme Lab", "Bench Lab"])

        // A gateway that could not be reached (nil) changes nothing; a definite
        // answer does.
        let second = ChatPluginPresence.apply(slack: nil, linear: .connected(workspace: "Bench Lab", user: nil), github: .notConnected, notion: nil, to: first)
        #expect(second.connected == [.slack, .linear, .notion])
        #expect(second.slackWorkspaces == ["Acme Lab", "Bench Lab"])

        // Signed out, every plugin reads as gone.
        let third = ChatPluginPresence.apply(slack: .signedOut, linear: .signedOut, github: .signedOut, notion: .signedOut, to: second)
        #expect(third.connected.isEmpty)
        #expect(third.slackWorkspaces.isEmpty)
    }

    @Test("An @ at the start of a word is a mention; an address or a stranger's name is text")
    func mentionsAreFound() throws {
        let connected: [ChatPlugin] = [.slack, .github]

        let leading = try #require(Mention.first(in: "@slack what did #general discuss today", plugins: connected))
        #expect(leading.plugin == .slack)
        #expect(Mention.removing(leading.range, from: "@slack what did #general discuss today") == "what did #general discuss today")

        // Anywhere in the text, in any case, and punctuation may follow it.
        let inline = try #require(Mention.first(in: "summarize @GitHub, newest first", plugins: connected))
        #expect(inline.plugin == .github)
        #expect(Mention.removing(inline.range, from: "summarize @GitHub, newest first") == "summarize , newest first")

        // The mention alone: nothing is left, so the default question is asked.
        let bare = try #require(Mention.first(in: "@slack", plugins: connected))
        #expect(Mention.removing(bare.range, from: "@slack").isEmpty)

        // An email address is not a mention, and neither is a plugin that is
        // not connected — its name goes to the tutor as typed.
        #expect(Mention.first(in: "mail robin@slack.com about it", plugins: connected) == nil)
        #expect(Mention.first(in: "@linear OXP-5", plugins: connected) == nil)
        #expect(Mention.first(in: "@slacker", plugins: connected) == nil)
        #expect(Mention.first(in: "@slack", plugins: []) == nil)
    }

    @Test("The popup offers every connected plugin after a bare @ and narrows as the name is typed")
    func mentionSuggestions() throws {
        let mentions = [
            ChatPlugin.slack.mention(slackWorkspaces: ["Acme Lab"]),
            ChatPlugin.github.mention(slackWorkspaces: []),
        ]

        let all = ReviewSlashCommandParser.suggestions(for: "tell me @", mentions: mentions)
        #expect(all.map(\.title) == ["@slack", "@github"])
        #expect(all.first?.subtitle == "Ask Slack · Acme Lab")
        #expect(all.first?.mentionedPlugin == .slack)
        #expect(all.first?.runsImmediately == false)
        #expect(all.first?.isLibraryRow == false)

        // Accepting replaces only the token being typed, keeps what came
        // before, and leaves the caret after a space.
        let narrowed = ReviewSlashCommandParser.suggestions(for: "tell me @Gi", mentions: mentions)
        #expect(narrowed.map(\.title) == ["@github"])
        #expect(narrowed.first?.completionText == "tell me @github ")

        // A complete mention, an address, an unknown name and a `/` draft
        // offer no mention rows; nothing connected offers none either.
        #expect(ReviewSlashCommandParser.suggestions(for: "@slack ", mentions: mentions).isEmpty)
        #expect(ReviewSlashCommandParser.suggestions(for: "robin@", mentions: mentions).isEmpty)
        #expect(ReviewSlashCommandParser.suggestions(for: "@lin", mentions: mentions).isEmpty)
        #expect(ReviewSlashCommandParser.suggestions(for: "@", mentions: []).isEmpty)
        #expect(ReviewSlashCommandParser.suggestions(for: "/g", mentions: mentions).map(\.title) == ["/goal [topic]"])

        // Plugins are no longer `/` commands.
        #expect(ReviewSlashCommandParser.parse("/slack what did #general discuss") == nil)
    }

    @Test("A bare @github asks about the Notebook's repository when there is one")
    func defaultRequests() {
        #expect(ChatPlugin.github.defaultRequest(repository: "ForeverLM-HQ/ForeverLM").contains("ForeverLM-HQ/ForeverLM"))
        #expect(ChatPlugin.github.defaultRequest(repository: "  ").contains("repositories I can read"))
        #expect(ChatPlugin.slack.defaultRequest(repository: nil).contains("Slack channels"))
        #expect(ChatPlugin.linear.defaultRequest(repository: nil).contains("Linear issues"))
    }

    @Test("The mark rides beside the message and reads back; content without it passes through whole")
    func markRoundTrips() {
        let context = ChatPluginRequest.contextContent(for: .linear)
        #expect(context == "<flm_connector name=\"linear\"/>")
        let parsed = ChatPluginRequest.parse(contextContent: context)
        #expect(parsed == .init(plugin: .linear, remainder: nil))

        // A quoted passage under the mark stays reference material.
        let withReference = ChatPluginRequest.contextContent(for: .slack, referenceContext: "Quoted: mitophagy")
        let both = ChatPluginRequest.parse(contextContent: withReference)
        #expect(both.plugin == .slack)
        #expect(both.remainder == "Quoted: mitophagy")

        // A side question sent to a plugin keeps both marks: the plugin's
        // first, the side question whole underneath it.
        let sideQuestion = ChatSideQuestion.contextContent(openQuestion: "What is ROS?")
        let stacked = ChatPluginRequest.parse(
            contextContent: ChatPluginRequest.contextContent(for: .slack, referenceContext: sideQuestion)
        )
        #expect(stacked.plugin == .slack)
        #expect(ChatSideQuestion.parse(contextContent: stacked.remainder).isSideQuestion)

        // Contexts written before the mark existed come back untouched.
        let untouched = ChatPluginRequest.parse(contextContent: sideQuestion)
        #expect(untouched.plugin == nil)
        #expect(untouched.remainder == sideQuestion)
        #expect(ChatPluginRequest.parse(contextContent: nil) == .init(plugin: nil, remainder: nil))
        #expect(ChatPluginRequest.parse(contextContent: "   ") == .init(plugin: nil, remainder: nil))

        // A plugin message is not a side question, and the mark never
        // reaches the bubble; the learner's words do, mention included.
        let message = ReviewSessionManager.Message(role: .user, content: "@slack what did #general discuss", contextualContent: context)
        #expect(message.isSideQuestion == false)
        #expect(message.content == "@slack what did #general discuss")

        // What the model is told names the mention and the tools that answer it.
        for plugin in ChatPlugin.allCases {
            let framing = ChatPluginRequest.framing(for: plugin)
            #expect(framing.contains("addressed this message to \(plugin.mentionToken)"))
            #expect(framing.contains(plugin.requiredToolName))
            #expect(framing.contains("not from the library"))
        }
    }

    @Test("The popup row for a mention shows the plugin's mark, its name and what it reads")
    @MainActor
    func popupRendersMentionRow() {
        let mentions = [ChatPlugin.slack.mention(slackWorkspaces: ["Acme Lab"])]
        let suggestions = ReviewSlashCommandParser.suggestions(for: "@", mentions: mentions)
        var picked: [ReviewSlashSuggestion] = []
        let popup = ReviewSlashCommandPopup(suggestions: suggestions, selectedIndex: 0) { picked.append($0) }
            .frame(width: 380, height: 60)

        let hosting = NSHostingView(rootView: popup)
        hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 60)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let labels = AccessibilityWalk.withAssistiveClient {
            AccessibilityWalk.elements(under: hosting)
        }.flatMap { $0.spokenStrings }.joined(separator: " | ")
        #expect(labels.contains("@slack"), "mention row not rendered: \(labels)")
        #expect(labels.contains("Ask Slack · Acme Lab"))
        #expect(picked.isEmpty)
    }
}

// MARK: - A missing connection, as the chat reads it off a failed step

@Suite("Chat plugin setup needs")
struct ChatPluginSetupNeedTests {
    typealias Need = ChatPluginRequest.SetupNeed

    @Test("A read that failed for want of a connection names the plugin and what to set up")
    func classifiesTheGatewayAndMacSentences() {
        #expect(ChatPluginRequest.setupNeed(
            toolName: "list_github_repositories",
            error: "No GitHub account is connected to this ForeverLM account. The learner connects one at https://app.foreverlm.com/github-connect."
        ) == Need(plugin: .github, kind: .connect))
        #expect(ChatPluginRequest.setupNeed(
            toolName: "read_github_file",
            error: "GitHub answered not found for /repos/BenchLabBio/mitochondria/contents/sites/index.html: it does not exist, the learner cannot see it, or the ForeverLM GitHub App is not installed for that repository's owner — add it at https://github.com/apps/foreverlm-app/installations/new."
        ) == Need(plugin: .github, kind: .installOrganisation))
        #expect(ChatPluginRequest.setupNeed(
            toolName: "list_github_files",
            error: "ForeverLM's GitHub connection is no longer valid. Reconnect GitHub at https://app.foreverlm.com/github-connect and try again."
        ) == Need(plugin: .github, kind: .reconnect))
        #expect(ChatPluginRequest.setupNeed(
            toolName: "search_github_code",
            error: "Sign in with Apple in ForeverLM to read GitHub. ForeverLM reads GitHub as you, through your own ForeverLM account, so a signed-out Mac has nothing to read with."
        ) == Need(plugin: .github, kind: .signIn))
        #expect(ChatPluginRequest.setupNeed(
            toolName: "save_site",
            error: "No GitHub account is connected to this ForeverLM account. The learner connects one at https://app.foreverlm.com/github-connect."
        ) == Need(plugin: .github, kind: .connect), "save_site reads GitHub when it is given a repository")
        #expect(ChatPluginRequest.setupNeed(
            toolName: "search_linear_issues",
            error: "No Linear workspace is connected to this ForeverLM account. The learner connects one at https://app.foreverlm.com/linear-connect."
        ) == Need(plugin: .linear, kind: .connect))
        #expect(ChatPluginRequest.setupNeed(
            toolName: "search_notion",
            error: "ForeverLM's Notion connection is no longer valid. Reconnect Notion at https://app.foreverlm.com/notion-connect and try again."
        ) == Need(plugin: .notion, kind: .reconnect))
        #expect(ChatPluginRequest.setupNeed(
            toolName: "read_slack_channel",
            error: "No Slack workspace is connected to this ForeverLM account."
        ) == Need(plugin: .slack, kind: .connect))
        #expect(ChatPluginRequest.setupNeed(
            toolName: "search_slack_messages",
            error: "ForeverLM's Slack connection was made before it could search, so search_slack_messages cannot run yet. Reconnect the workspace once at https://app.foreverlm.com/slack-connect (it asks for the search:read permission) and try again; until then read_slack_channel still works."
        ) == Need(plugin: .slack, kind: .reconnect))
    }

    @Test("Other failures, and other tools, are not setup needs")
    func leavesOtherFailuresAlone() {
        #expect(ChatPluginRequest.setupNeed(
            toolName: "read_github_file",
            error: "path is required: the file's path within the repository, such as src/main.swift, from list_github_files."
        ) == nil)
        #expect(ChatPluginRequest.setupNeed(
            toolName: "save_site",
            error: "Pass the site's files: html for a one-page site, files for several, or repository to read them from GitHub."
        ) == nil, "a GitHub mention in an argument error is not a missing connection")
        #expect(ChatPluginRequest.setupNeed(
            toolName: "search_sources_semantic",
            error: "No GitHub account is connected to this ForeverLM account."
        ) == nil, "a tool that does not read a plugin cannot need one")
        #expect(ChatPluginRequest.setupNeed(toolName: "browser_open", error: "Sign in with Apple in ForeverLM") == nil)
    }

    @Test("A turn's failures add up to one card per plugin, keeping the latest word on each")
    func oneCardPerPlugin() {
        let notInstalled = "GitHub answered not found for /repos/a/b: it does not exist, the learner cannot see it, or the ForeverLM GitHub App is not installed for that repository's owner."
        let needs = ChatPluginRequest.setupNeeds(in: [
            (toolName: "list_github_repositories", error: nil),
            (toolName: "list_github_files", error: "No GitHub account is connected to this ForeverLM account."),
            (toolName: "read_github_file", error: notInstalled),
            (toolName: "search_linear_issues", error: "No Linear workspace is connected to this ForeverLM account."),
            (toolName: "save_site", error: "Pass either the files (html, files) or a repository to read them from, not both."),
        ])
        #expect(needs == [Need(plugin: .github, kind: .installOrganisation), Need(plugin: .linear, kind: .connect)])
        #expect(ChatPluginRequest.setupNeeds(in: [(toolName: "read_github_file", error: nil)]).isEmpty)
    }

    // MARK: - /plan is the day

    @Test("/plan plans the day into the calendar")
    func planIsTheDay() throws {
        let byName = Dictionary(uniqueKeysWithValues: ReviewSlashCommand.all.map { ($0.name, $0) })
        let plan = try #require(byName["plan"])
        #expect(plan.kind == .plan)
        #expect(plan.summary == "Plan a day into the calendar")
        #expect(plan.arguments.map(\.value) == ["today", "tomorrow"])
        #expect(plan.argumentSource == .fixed, "the days are a fixed pair, not a library search")

        // /today is the day's question, not the Schedule's: what the calendar
        // holds now.
        #expect(byName["today"]?.summary == "What is on the calendar right now")
        #expect(byName["today"]?.takesArgument == false)
    }

    @Test("Which day /plan means is decided by the clock, and free text is passed through")
    func planDayRequestPicksTheDay() throws {
        func at(_ hour: Int) -> Date {
            var components = DateComponents()
            components.year = 2026; components.month = 9; components.day = 18
            components.hour = hour; components.minute = 0
            return Calendar.current.date(from: components) ?? Date()
        }
        // Before the afternoon an unplanned today is still worth planning.
        #expect(ReviewSlashCommandParser.planDayRequest(nil, now: at(9)).hasPrefix("Plan today on my clock."))
        // After it the day is half spent, and planning the night before is the
        // habit the Planner is trying to build.
        #expect(ReviewSlashCommandParser.planDayRequest(nil, now: at(16)).hasPrefix("Plan tomorrow on my clock."))
        #expect(ReviewSlashCommandParser.planDayRequest("", now: at(21)).hasPrefix("Plan tomorrow on my clock."))
        // Said outright, the clock does not get a vote.
        #expect(ReviewSlashCommandParser.planDayRequest("today", now: at(21)).hasPrefix("Plan today on my clock."))
        #expect(ReviewSlashCommandParser.planDayRequest("Tomorrow", now: at(9)).hasPrefix("Plan tomorrow on my clock."))
        // Anything else is the learner's own words, carried through.
        let free = ReviewSlashCommandParser.planDayRequest("monday, I'm out until 11", now: at(9))
        #expect(free.hasPrefix("Plan my clock. monday, I'm out until 11"))
    }

    @Test("The /plan request reads the calendar first, proposes the day without asking first, and writes the agreed day into the calendar")
    func planDayRequestCarriesTheRules() {
        let request = ReviewSlashCommandParser.planDayRequest("today")
        // Read before planning: the calendar, the Goals, and how recent days went.
        #expect(request.contains("Mac's Calendar"))
        #expect(request.contains("get_calendar_events"))
        #expect(request.contains("get_schedule"))
        #expect(request.contains("list_goals"))
        #expect(request.contains("get_day_activity"))
        // The running log leads; Goals follow from it. It is background
        // memory, read through the working-note tool, never a Doc.
        #expect(request.contains("list_working_notes"))
        #expect(!request.contains("read_doc"))
        #expect(!request.contains(WorkingLog.id))
        // Meetings with other people stay put.
        #expect(request.contains("meetings with other people stay where they are"))
        // A draft at once, revised in conversation, and only then the calendar.
        #expect(request.contains("do not ask me a question first"))
        #expect(request.contains("Keep going until I say it is right"))
        #expect(!request.contains("ONE short question"))
        #expect(request.contains("Only then, add each block"))
        #expect(request.contains("create_calendar_event"))
        // It is not only learning.
        #expect(request.contains("calls"))
        #expect(!request.contains("revise_day_plan"))
    }
}

@Suite("The working log")
struct WorkingLogTests {
    @Test("An untouched log carries nothing into a prompt")
    func seedIsSilent() {
        #expect(WorkingLog.promptExcerpt(fromMarkdown: WorkingLog.seedMarkdown) == nil)
        #expect(WorkingLog.promptExcerpt(fromMarkdown: "  \n") == nil)
    }

    @Test("A written log is carried, and a long one is cut at a line")
    func writtenLogIsCarried() throws {
        let written = "## Right now\n\nReading NAD+ papers.\n\n## Log\n\n- 2026-10-10 09:50 Read a half-center paper"
        #expect(WorkingLog.promptExcerpt(fromMarkdown: written) == written)

        let long = "## Log\n\n" + (0..<400).map { "- 2026-10-10 09:\($0 % 60) entry number \($0)" }.joined(separator: "\n")
        let cut = try #require(WorkingLog.promptExcerpt(fromMarkdown: long))
        #expect(cut.count <= WorkingLog.promptCharacterLimit + 2)
        #expect(cut.hasSuffix("\n…"))
        #expect(!cut.dropLast(2).hasSuffix("entry number 1"), "cut at a line boundary, not mid-line")
    }
}

/// Codex's thread verbs as slash commands, and `$name` for a skill.
@Suite("Chat thread verbs")
struct ChatThreadVerbTests {
    @Test("/rename, /pin, /hide, /fork and /reasoning are offered and parse their arguments")
    func verbs() throws {
        let names = Set(ReviewSlashCommand.all.map(\.name))
        #expect(names.isSuperset(of: ["rename", "pin", "hide", "fork", "reasoning"]))

        let offered = ReviewSlashCommandParser.suggestions(for: "/re").map(\.title)
        #expect(offered.contains("/rename [title]"))
        #expect(offered.contains("/reasoning <effort>"))
        #expect(offered.contains("/review"))

        let rename = try #require(ReviewSlashCommandParser.parse("/rename  Sleep and memory "))
        #expect(rename.command.kind == .rename)
        #expect(rename.argument == "Sleep and memory")
        #expect(ReviewSlashCommandParser.parse("/rename")?.argument == nil)
        #expect(ReviewSlashCommandParser.parse("/pin")?.command.kind == .pin)
        #expect(ReviewSlashCommandParser.parse("/hide")?.command.kind == .hide)
        #expect(ReviewSlashCommandParser.parse("/fork")?.command.kind == .fork)
        #expect(ReviewSlashCommandParser.parse("/side")?.command.kind == .side)
        // Verbs with no argument run as soon as they are picked.
        let pin = try #require(ReviewSlashCommandParser.suggestions(for: "/pi").first)
        #expect(pin.runsImmediately)
    }

    @Test("/reasoning offers every effort and reads it however it is written")
    func reasoning() throws {
        let rows = ReviewSlashCommandParser.suggestions(for: "/reasoning ")
        #expect(rows.map(\.title) == AIEffort.allCases.map(\.rawValue))
        #expect(rows.first?.subtitle == "None")
        let high = try #require(ReviewSlashCommandParser.suggestions(for: "/reasoning hi").first)
        #expect(high.completionText == "/reasoning high")
        #expect(high.runsImmediately)

        #expect(ReviewSlashCommandParser.effort(named: "High") == .high)
        #expect(ReviewSlashCommandParser.effort(named: "xhigh") == .extraHigh)
        #expect(ReviewSlashCommandParser.effort(named: "Extra High") == .extraHigh)
        #expect(ReviewSlashCommandParser.effort(named: "extra-high") == .extraHigh)
        #expect(ReviewSlashCommandParser.effort(named: "none") == .noReasoning)
        #expect(ReviewSlashCommandParser.effort(named: "MAX") == .max)
        #expect(ReviewSlashCommandParser.effort(named: "hard") == nil)
        #expect(ReviewSlashCommandParser.effort(named: " ") == nil)
    }

    @Test("$name asks for a skill as /name does; $ names nothing else")
    func dollarSkills() throws {
        let skill = SkillRecord(name: "walk", description: "Walk through a paper", instructions: "Body")
        let commands = ReviewSlashCommand.all + [.skill(skill)]

        let offered = ReviewSlashCommandParser.suggestions(for: "$", commands: commands)
        #expect(offered.map(\.title) == ["$walk [request]"])
        let row = try #require(ReviewSlashCommandParser.suggestions(for: "$wa", commands: commands).first)
        #expect(row.completionText == "$walk ")
        #expect(!row.runsImmediately)
        // Built-in commands are `/` only.
        #expect(ReviewSlashCommandParser.suggestions(for: "$ne", commands: commands).isEmpty)

        let parsed = try #require(ReviewSlashCommandParser.parseSkillInvocation("$walk the MitoSpace paper", commands: commands))
        #expect(parsed.command.kind == .skill)
        #expect(parsed.argument == "the MitoSpace paper")
        #expect(ReviewSlashCommandParser.parseSkillInvocation("$new", commands: commands) == nil)
        #expect(ReviewSlashCommandParser.parseSkillInvocation("$5 a month", commands: commands) == nil)
        #expect(ReviewSlashCommandParser.parse("$walk", commands: commands) == nil)

        // The composer paints `$walk` as it paints `/walk`.
        let prefix = try #require(ReviewSlashCommandParser.commandPrefix(in: "$walk it", commands: commands))
        #expect(prefix.command.name == "walk")
        #expect(ReviewSlashCommandParser.commandPrefix(in: "$new", commands: commands) == nil)
    }
}

/// `@` finds the learner's sources, Pages, Sites, chats and notebooks as
/// Codex's `@` finds files, chats and pages, with the plugins kept under All.
@Suite("Chat library mentions")
struct ChatLibraryMentionTests {
    private static let found: [ChatMention.Item] = [
        .init(kind: .source, reference: "source:s1", title: "Neural circuits of fear", subtitle: "Paper · Zara Holt"),
        .init(kind: .source, reference: "source:s2", title: "Neurons, a primer", subtitle: "Article"),
        .init(kind: .source, reference: "book:b1", title: "Neuroscience", subtitle: "Book"),
        .init(kind: .source, reference: "source:s3", title: "Neuromodulation", subtitle: "Podcast"),
        .init(kind: .page, reference: "doc-1", title: "Neuro notes", subtitle: "Page · edited today"),
        .init(kind: .site, reference: "site-1", title: "Neuro site", subtitle: "Published page"),
        .init(kind: .chat, reference: "chat-1", title: "Neurons and memory", subtitle: "Acme Lab · yesterday"),
        .init(kind: .notebook, reference: "nb-1", title: "Neuroscience", subtitle: "12 sources"),
    ]

    @Test("An @ that starts a word is a query up to the end of the draft; an address or a finished word is not")
    func pendingQueries() throws {
        #expect(ChatMention.pendingQuery(in: "what does @neur")?.query == "neur")
        #expect(ChatMention.pendingQuery(in: "@")?.query == "")
        #expect(ChatMention.pendingQuery(in: "see @Über")?.query == "Über")
        #expect(ChatMention.pendingQuery(in: "mail zara@example") == nil)
        #expect(ChatMention.pendingQuery(in: "@neuro ") == nil)
        #expect(ChatMention.pendingQuery(in: "@a@b") == nil)
        #expect(ChatMention.pendingQuery(in: "/source @neuro") == nil)
        #expect(ChatMention.pendingQuery(in: "") == nil)

        // Choosing a row takes the `@` and its query out and keeps the rest.
        #expect(ChatMention.removingPending(from: "what does @neur") == "what does ")
        #expect(ChatMention.removingPending(from: "@neur") == "")
        #expect(ChatMention.removingPending(from: "plain text") == "plain text")
    }

    @Test("A title that is the query ranks first, then one that starts with it, then a word that does")
    func ranking() {
        #expect(ChatMention.matchRank(title: "Neuroscience", query: "neuroscience") == 0)
        #expect(ChatMention.matchRank(title: "Neuroscience notes", query: "NEURO") == 1)
        #expect(ChatMention.matchRank(title: "The neuroscience of sleep", query: "neuro") == 2)
        #expect(ChatMention.matchRank(title: "Café culture", query: "cafe") == 1)
        #expect(ChatMention.matchRank(title: "Synaptic neurotransmission", query: "trans") == 3)
        #expect(ChatMention.matchRank(title: "Sleep", query: "neuro") == nil)
        #expect(ChatMention.matchRank(title: "Sleep", query: "  ") == nil)

        let titles = ["The neuroscience of sleep", "Sleep", "Neuro basics", "Neuro", "Other neuro talk"]
        // Equal ranks keep the order given (newest first).
        #expect(ChatMention.ranked(titles, query: "neuro", title: { $0 }) == [
            "Neuro", "Neuro basics", "The neuroscience of sleep", "Other neuro talk",
        ])
    }

    @Test("All shows a few of each kind in order, a tab shows more of its own, Pages holds Sites")
    func tabs() {
        let all = ChatMention.rows(Self.found, tab: .all)
        #expect(all.map(\.kind) == [.source, .source, .source, .page, .site, .chat, .notebook])
        #expect(ChatMention.rows(Self.found, tab: .sources).count == 4)
        #expect(ChatMention.rows(Self.found, tab: .pages).map(\.kind) == [.page, .site])
        #expect(ChatMention.rows(Self.found, tab: .chats).map(\.reference) == ["chat-1"])
        #expect(ChatMention.rows(Self.found, tab: .notebooks).map(\.reference) == ["nb-1"])
    }

    @Test("Library rows show only while they answer the query; plugins stay under All; choosing keeps the words")
    func suggestions() throws {
        let mentions = [ChatPlugin.notion.mention(slackWorkspaces: [])]
        let live = ChatMention.LiveResults(query: "neu", items: Self.found)

        let shown = ReviewSlashCommandParser.suggestions(for: "compare @neu", mentions: mentions, liveMentions: live)
        #expect(shown.count == 7)
        #expect(shown.first?.libraryItem?.reference == "source:s1")
        #expect(shown.first?.mentionGroupTitle == "Sources")
        #expect(shown.first?.isLibraryRow == true)
        #expect(shown.first?.runsImmediately == false)
        #expect(shown.first?.completionText == "compare ")
        #expect(shown.first?.subtitle == "Paper · Zara Holt")

        // A stale answer (the previous keystroke's) shows nothing.
        #expect(ReviewSlashCommandParser.suggestions(for: "compare @neur", liveMentions: live).isEmpty)
        // A bare @ offers the plugins and leaves the rest to the hint.
        #expect(ReviewSlashCommandParser.suggestions(for: "@", mentions: mentions, liveMentions: live).map(\.title) == ["@notion"])

        // A plugin matching the query leads All and is not in a kind's tab.
        let notion = ChatMention.LiveResults(query: "no", items: [
            .init(kind: .page, reference: "doc-2", title: "Notes", subtitle: ""),
        ])
        let both = ReviewSlashCommandParser.suggestions(for: "@no", mentions: mentions, liveMentions: notion)
        #expect(both.map(\.title) == ["@notion", "Notes"])
        #expect(both.map(\.mentionGroupTitle) == ["Plugins", "Pages"])
        #expect(both.last?.subtitle == nil)
        let pagesOnly = ReviewSlashCommandParser.suggestions(
            for: "@no", mentions: mentions, liveMentions: notion, mentionTab: .pages
        )
        #expect(pagesOnly.map(\.title) == ["Notes"])
    }

    @Test("The popup says what to type, then that it searches, then that nothing matched")
    func statusLines() {
        #expect(ReviewMentionPopupHeader.statusLine(query: "", tab: .all, hasRows: false, hasAnswer: true)
            == "Type to search sources, Pages, chats and notebooks")
        #expect(ReviewMentionPopupHeader.statusLine(query: "", tab: .chats, hasRows: false, hasAnswer: true)
            == "Type to search chats")
        #expect(ReviewMentionPopupHeader.statusLine(query: "zz", tab: .all, hasRows: false, hasAnswer: false) == "Searching…")
        #expect(ReviewMentionPopupHeader.statusLine(query: "zz", tab: .all, hasRows: false, hasAnswer: true) == "No results")
        #expect(ReviewMentionPopupHeader.statusLine(query: "zz", tab: .all, hasRows: true, hasAnswer: true) == nil)
    }

    @Test("A chat pointed at rides as its transcript, the oldest turns left out when it is long, and names no id")
    func chatReference() {
        let short = ChatMention.chatReferenceContext(
            title: "Neurons and memory",
            turns: [("Learner", "What is LTP?"), ("ForeverLM", "Long-term potentiation is…"), ("Learner", "  ")]
        )
        #expect(short.hasPrefix("Referenced chat \u{201C}Neurons and memory\u{201D}"))
        #expect(short.contains("Learner: What is LTP?"))
        #expect(short.contains("ForeverLM: Long-term potentiation is…"))
        #expect(!short.contains("Earlier turns left out"))
        #expect(!short.contains("chat-1"))

        let turns = (0..<50).map { (speaker: "Learner", text: "Turn \($0) " + String(repeating: "x", count: 100)) }
        let long = ChatMention.chatReferenceContext(title: "Long", turns: turns, characterLimit: 1_000)
        #expect(long.contains("(Earlier turns left out.)"))
        #expect(long.contains("Turn 49"))
        #expect(!long.contains("Turn 0 "))
        #expect(long.count < 1_400)

        let empty = ChatMention.chatReferenceContext(title: " ", turns: [])
        #expect(empty.contains("Untitled chat"))
        #expect(empty.contains("no messages yet"))
    }
}
