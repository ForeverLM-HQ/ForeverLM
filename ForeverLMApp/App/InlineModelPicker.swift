import SwiftUI
import AppKit

/// Shared chrome for the app's small text controls: the composer's model
/// picker and its "+" menu, and the slow free model offer's Ask a paid model.
///
/// Quiet by design: plain text at rest, with a soft chip materializing under the
/// pointer. The chip is a squared-off rounded rectangle rather than a capsule —
/// a capsule around a short word reads as a lozenge badge, while the softened
/// square reads as a control, which is what these are.
///
/// This is a `ButtonStyle`, not a modifier on the label, and for a `Menu` it
/// only works together with `.menuStyle(.button)` — use `pickerPillMenu()`.
/// The chrome used to live inside the Menu's label under
/// `.menuStyle(.borderlessButton)`, and never drew: that style is an AppKit
/// popup button (`SwiftUIPopupButton`) which takes the label's image and text
/// and lays them out itself as `NSButtonImageView` and `NSButtonTextField`,
/// discarding the label view — padding, frame, fill and border with it.
/// Measured on an offscreen window on 2026-09-01: an `HStack { Image; Text }`
/// label came out as a bare 121×17 native title, whether or not the label
/// carried a chip or the Menu had `.fixedSize()`, and so did the composer's
/// `ViewThatFits` label and the chat-mode picker's `Label`. Under `.button`
/// with this style the same Menu is pure SwiftUI at the chip's own 144×24, so
/// the fill, the border and the hit region are one rectangle again.
struct PickerPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PickerPill(isPressed: configuration.isPressed, content: configuration.label)
    }
}

/// The chip itself. Owns the hover state so a control gets the wash by taking
/// the style, with no `isHovering` plumbing to forget.
private struct PickerPill<Content: View>: View {
    let isPressed: Bool
    let content: Content

    @State private var isHovering = false

    /// Sized against the 24pt control height: enough curve to feel soft, far
    /// enough from 12 (a capsule at this height) to read as square.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
    }

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            // The control's full height belongs to the chip, not just to the
            // text box inside it: when the height came from a `.frame` applied
            // *after* this chrome, the outer band was painted by nobody and
            // hit-tested by nobody, so clicks near the top or bottom edge of
            // what looks like the control quietly did nothing.
            .frame(minHeight: 24)
            .background(
                shape.fill(isHovering ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear))
            )
            .overlay(
                shape.strokeBorder(.primary.opacity(isHovering ? 0.14 : 0), lineWidth: 1)
            )
            .contentShape(shape)
            .opacity(isPressed ? 0.6 : 1)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovering = hovering
                }
            }
    }
}

extension ButtonStyle where Self == PickerPillButtonStyle {
    /// The small-text-control chip, for a plain `Button` (`UpwardMenuChip`).
    static var pickerPill: PickerPillButtonStyle { PickerPillButtonStyle() }
}

extension View {
    /// Makes a `Menu` draw as the small-text-control chip. Apply it to the
    /// Menu, with any width frame *inside* the label, so the fill, the border
    /// and the hit region are the same rectangle. `.menuStyle(.button)` is what
    /// lets the button style see the label at all; see `PickerPillButtonStyle`.
    func pickerPillMenu() -> some View {
        self
            .menuStyle(.button)
            .buttonStyle(.pickerPill)
            .menuIndicator(.hidden)
    }
}

/// Compact model selector showing the current model, with a one-click menu to switch.
/// The menu is model-first: picking a model implies its provider, so the user never
/// has to choose a provider separately. Which models appear is controlled by the
/// "Chat" toggles in Settings; providers outside the managed rail are hidden.
///
/// One control for the model and its effort, as ChatGPT's composer names both
/// on one chip ("GPT-5.6 Sol High ▾"; the product owner, 2026-10-06: "make the app more
/// slick; kind of like the chatgpt app"): the label reads "<model> · <effort>"
/// for a model that takes an effort, and the menu's Effort submenu sets it.
/// The separate Effort pill and its Faster ↔ Smarter slider went that day.
struct InlineModelPicker: View {
    // Safe placeholders only. Keychain and catalog work is loaded off-main by
    // `syncSelectionFromStorage`; a SwiftUI state initializer runs on the main
    // actor and used to synchronously build and price the entire catalog.
    @State private var selectedProvider: AIProvider = .openRouter
    @State private var selectedModel: String = AIModelDefaults.defaultOpenRouter
    @State private var selectedEffort: AIEffort?
    @State private var selectedSpeed: AISpeed?
    /// A model picked for the first time is tested before it is selected
    /// (`AIModelQualification`). The chip shows it meanwhile as if chosen,
    /// with no word about the test (product owner, 2026-09-27), and goes back to
    /// the previous model only if it fails.
    @State private var pendingEntry: AIModelCatalogEntry?
    @State private var pickRefusal: String?
    /// Providers ready to use through the current managed session.
    /// Held in @State (refreshed via `.aiProviderDidChange`) so adding a key in
    /// Settings updates the menu without reopening the view.
    @State private var configuredProviders: [AIProvider] = UITestConfiguration.isUITesting
        ? [.openRouter]
        : []
    /// Menu contents: enabled catalog models across configured providers, in
    /// catalog (maker) order but shown as one flat list — the maker grouping
    /// already lives in Settings. Refreshed alongside `configuredProviders` so
    /// toggling a model in Settings updates an already-visible picker.
    @State private var menuEntries: [AIModelCatalogEntry] = []
    /// Starts from the stored account policy rather than the shipped default.
    /// The policy read is a UserDefaults lookup, not a Keychain read.
    @State private var routingMode: AITextRoutingMode = KeychainService.textRoutingMode
    /// OpenRouter's directory rows, for the promotion label beside a price on
    /// the OpenRouter route. The price itself already includes the promotion —
    /// the pricing table's remote overlay comes from this same directory — so
    /// this only names the discount the learner is already getting.
    @State private var openRouterDirectory: [OpenRouterDirectoryModel] = []
    /// Endpoint tiers this picker last fetched for the selected model. The
    /// menu reads the process-wide `OpenRouterEndpointTierCatalog` cache for
    /// both the Speed submenu's presence and its prices — one source, so the
    /// two can never disagree — and this copy exists so the body re-renders
    /// when the fetch lands, and as the fallback when the cache was cleared.
    @State private var speedTiers: [OpenRouterEndpointTier] = []
    /// OpenRouter's measured endpoint speeds for the selected model, keyed by
    /// lowercased slug. Read through `endpointSpeeds(slug:)`, cache first.
    @State private var speedsBySlug: [String: [OpenRouterEndpointSpeed]] = [:]
    /// The models and efforts last chosen for chats, newest first, for the
    /// menu's Recent models (`ChatRecentModels`). Read off-main with the rest
    /// of the selection.
    @State private var recentModels: [ChatRecentModels.Entry] = []
    let task: AITask?

    init(task: AITask? = nil) {
        self.task = task
    }

    /// Only the chat has an effort and a speed of its own; any other task the
    /// picker serves (the card answer check) runs on a model of its own
    /// (`KeychainService.setOwnRoute`) and takes neither.
    private var tunesEffortAndSpeed: Bool { task == .chat }

    private var currentModelDisplay: String {
        guard showsSelectedModel else { return "Set Up AI" }
        if let pendingEntry {
            return AIModelCatalog.pickerName(provider: pendingEntry.provider, modelID: pendingEntry.modelID)
        }
        return AIModelCatalog.pickerName(provider: selectedProvider, modelID: selectedModel)
    }

    /// Logo for the current selection: the model maker's mark when the model
    /// is in the catalog (a Nemotron model shows NVIDIA's logo even though
    /// OpenRouter serves it), else the host provider's mark.
    private var selectedMark: (iconName: String, fallback: String) {
        if let pendingEntry { return (pendingEntry.maker.iconName, pendingEntry.maker.systemImageFallback) }
        if let entry = AIModelCatalog.entry(provider: selectedProvider, modelID: selectedModel) {
            return (entry.maker.iconName, entry.maker.systemImageFallback)
        }
        return (selectedProvider.iconName, selectedProvider.systemImageFallback)
    }

    @ViewBuilder
    private var providerMark: some View {
        if showsSelectedModel {
            // Some makers have no bundled logo asset; fall back to their
            // SF Symbol so the mark never renders blank.
            if let image = sizedProviderMark(named: selectedMark.iconName) {
                Image(nsImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: selectedMark.fallback)
                    .zoomedSystemFont(size: 10, weight: .medium)
                    .foregroundStyle(.secondary)
            }
        } else {
            Image(systemName: "key.fill")
                .zoomedSystemFont(size: 10, weight: .medium)
                .foregroundStyle(Color.accentColor)
        }
    }

    /// Borderless macOS menus may extract an Image from a custom SwiftUI label
    /// and lay out the native NSImage directly, bypassing the label's frame.
    /// Give AppKit a correctly sized copy so even a stale/fallback asset with a
    /// large intrinsic bitmap can never expand the whole composer.
    private func sizedProviderMark(named name: String, side: CGFloat = 13) -> NSImage? {
        guard let source = NSImage(named: name),
              let copy = source.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: side, height: side)
        return copy
    }

    /// A menu row's title with the model maker's logo in the item's icon
    /// column, where Choose Models… keeps its icon (`MenuItemIcons` shows them).
    private func menuRowLabel(for entry: AIModelCatalogEntry) -> some View {
        Label {
            Text(AIModelCatalog.pickerName(provider: entry.provider, modelID: entry.modelID))
        } icon: {
            sizedProviderMark(named: entry.maker.iconName, side: 14)
                .map { Image(nsImage: $0) }
                ?? Image(systemName: entry.maker.systemImageFallback)
        }
    }

    private var hasConfiguredProviders: Bool {
        !configuredProviders.isEmpty
    }

    private var showsSelectedModel: Bool {
        hasConfiguredProviders
    }

    nonisolated private static func loadConfiguredProviders() -> [AIProvider] {
        // Retired hosts stay out even if their key is still stored; their
        // models are served via OpenRouter now.
        AIProvider.activeChatProviders.filter { provider in
            KeychainService.hasUsableTextProviderCredentials(for: provider)
        }
    }

    /// The models the menu lists. Blocking (it may read the Keychain), so
    /// callers run it off the main actor; the slow free model offer lists the
    /// paid ones among them.
    nonisolated static func loadMenuEntries(task: AITask?) -> [AIModelCatalogEntry] {
        let configured = Set(loadConfiguredProviders())
        // Snapshot once: enabledIDs also reconciles the stored default, which
        // may consult Keychain. Never repeat that synchronous read per card.
        let enabledIDs = AIModelCatalog.enabledIDs
        // A model that failed a test run stays offered: picking it tests it
        // again (`AIModelQualification`).
        let sourceGroups = AIModelCatalog.makerGroups
        let entries = menuEntries(
            groups: sourceGroups,
            enabledIDs: enabledIDs,
            configuredProviders: configured
        )
        if !entries.isEmpty { return entries }
        // If the user disabled every model of every configured provider, fall back
        // to the full curated lists so the picker never dead-ends.
        return sourceGroups.flatMap { group in
            group.entries.filter { configured.contains($0.provider) }
        }
    }

    nonisolated static func menuEntries(
        groups: [AIModelCatalog.MakerGroup],
        enabledIDs: Set<String>,
        configuredProviders: Set<AIProvider>
    ) -> [AIModelCatalogEntry] {
        groups.flatMap { group in
            group.entries.filter { entry in
                enabledIDs.contains(entry.id) && configuredProviders.contains(entry.provider)
            }
        }
    }

    static func isEntryAvailable(
        _ entry: AIModelCatalogEntry,
        configuredProviders: Set<AIProvider>
    ) -> Bool {
        return configuredProviders.contains(entry.provider)
    }

    private func isEntryAvailable(_ entry: AIModelCatalogEntry) -> Bool {
        Self.isEntryAvailable(
            entry,
            configuredProviders: Set(configuredProviders)
        )
    }

    private func displayedRates(
        for entry: AIModelCatalogEntry
    ) -> (input: Double, output: Double)? {
        AIModelListPrice.rates(for: entry)
    }

    private func isCurrent(_ entry: AIModelCatalogEntry) -> Bool {
        entry.provider == selectedProvider && entry.modelID == selectedModel
    }

    /// The gray line under a model's name: "$2/$10", input then output per
    /// million tokens, which the menu's section header says once instead of
    /// every row spelling out "in" and "out" (product owner, 2026-09-22). On a route
    /// where OpenRouter is running a promotion, the pair is led by the pair
    /// before the cut, struck through — "$̶4̶/̶$̶2̶0̶ $2/$10 · 50% off" — so nobody
    /// has to guess whether "50% off" is still to be applied to the numbers
    /// beside it (product owner, 2026-09-21). Pure so a test can pin that the
    /// discount is named and shown, never applied twice.
    ///
    /// The strike is drawn with the combining long stroke overlay (U+0336) on
    /// every character, not with `Text.strikethrough()`: in a macOS menu
    /// SwiftUI hands the second `Text` to `NSMenuItem.subtitle`, a plain
    /// string, and every attribute is dropped on the way — verified
    /// 2026-09-21 with a harness menu where the attributed and concatenated
    /// variants both drew as plain digits while the overlay drew as a strike.
    /// A list pair that rounds to the same label as the effective one is not
    /// struck: "$̶0̶.̶0̶1̶/̶$̶1̶ $0.01/$1" says nothing.
    static func menuSubtitle(
        rates: (input: Double, output: Double),
        promotion: RouterModelPromotion?
    ) -> String {
        let input = AIModelListPrice.dollars(rates.input)
        let output = AIModelListPrice.dollars(rates.output)
        let pair = "\(input)/\(output)"
        guard let promotion, !promotion.label.isEmpty else { return pair }
        var pricePart = pair
        if promotion.discountBasisPoints > 0, promotion.discountBasisPoints < 10_000 {
            let listInput = AIModelListPrice.dollars(promotion.listRate(fromEffective: rates.input))
            let listOutput = AIModelListPrice.dollars(promotion.listRate(fromEffective: rates.output))
            let listPair = "\(listInput)/\(listOutput)"
            if listPair != pair { pricePart = "\(struckThrough(listPair)) \(pair)" }
        }
        return "\(pricePart) · \(promotion.label)"
    }

    /// Header over the model rows, naming the unit of the bare "$2/$10"
    /// pairs under it. The rows carry no speed (product owner, 2026-09-23): the
    /// Speed submenu is where a speed decides the pick.
    static let priceUnitHeader = "Price per million tokens, input/output"

    /// Header over the Speed submenu's rows, which also name what the
    /// "61 tok/s" after each price measures.
    static let speedPriceUnitHeader = "\(priceUnitHeader) · output speed"

    /// "$4" → "$̶4̶": the string with a combining long stroke overlay after
    /// every character, the only strikethrough a macOS menu subtitle keeps.
    static func struckThrough(_ text: String) -> String {
        text.map { "\($0)\u{0336}" }.joined()
    }

    /// OpenRouter's promotion for an entry, on routes where the price shown is
    /// OpenRouter's.
    static func promotion(
        for entry: AIModelCatalogEntry,
        routingMode: AITextRoutingMode,
        directory: [OpenRouterDirectoryModel]
    ) -> RouterModelPromotion? {
        guard AIRequestOptionSupport.openRouterSpeedSlug(
            provider: entry.provider, model: entry.modelID, routingMode: routingMode
        ) != nil else { return nil }
        let slug = OpenRouterModelID.slug(provider: entry.provider, model: entry.modelID).lowercased()
        return directory.first { $0.id.lowercased() == slug }?.promotion
    }

    /// What the Speed submenu prints under one speed: the price and, when the
    /// row carries one, OpenRouter's promotion on it.
    struct SpeedQuote: Equatable {
        let input: Double
        let output: Double
        let promotion: RouterModelPromotion?
        /// OpenRouter's measured output speed for this tier; nil until the
        /// statistics have arrived or when the tier has too little traffic.
        var tokensPerSecond: Double? = nil

        /// The price and promotion alone, as the model row quotes it.
        var priceLine: String {
            InlineModelPicker.menuSubtitle(rates: (input, output), promotion: promotion)
        }

        /// The Speed submenu's line: the price with the measured speed after it.
        var subtitle: String {
            InlineModelPicker.appendingSpeed(tokensPerSecond, to: priceLine)
        }
    }

    /// "$2/$10 · 61 tok/s": the price line with the measured speed after it.
    static func appendingSpeed(_ tokensPerSecond: Double?, to line: String) -> String {
        guard let tokensPerSecond else { return line }
        return "\(line) · \(OpenRouterModelSpeed.label(tokensPerSecond: tokensPerSecond))"
    }

    /// The price quoted beside a speed: the lab's endpoint row for that tier
    /// from OpenRouter, falling back to the model's own list price for
    /// Standard when the endpoint list has no bare-vendor row. Flex and Fast
    /// have no fallback — with no tier row there is no such option at all.
    static func speedRates(
        for speed: AISpeed,
        slug: String,
        tiers: [OpenRouterEndpointTier],
        standardFallback: (input: Double, output: Double)?,
        standardFallbackPromotion: RouterModelPromotion? = nil,
        speeds: [OpenRouterEndpointSpeed] = []
    ) -> SpeedQuote? {
        let tokensPerSecond = OpenRouterModelSpeed.tokensPerSecond(for: speed, slug: slug, in: speeds)
        if let tier = OpenRouterSpeedTier.tier(for: speed, slug: slug, in: tiers) {
            return SpeedQuote(
                input: tier.inputUSDPerMTokens,
                output: tier.outputUSDPerMTokens,
                promotion: OpenRouterSpeedTier.promotion(discount: tier.discount),
                tokensPerSecond: tokensPerSecond
            )
        }
        guard speed == .standard, let standardFallback else { return nil }
        return SpeedQuote(
            input: standardFallback.input,
            output: standardFallback.output,
            promotion: standardFallbackPromotion,
            tokensPerSecond: tokensPerSecond
        )
    }

    /// The gray line under a model row. The selected model, on a route with
    /// speed tiers, is priced from the endpoint row of the speed it is set to
    /// — the same figure the Speed submenu puts a checkmark beside — so the
    /// two lines can never disagree. Every other row quotes the directory's
    /// model-level price. No speed: that is the Speed submenu's. Nil when
    /// neither source has a price.
    static func modelRowSubtitle(
        rates: (input: Double, output: Double)?,
        promotion: RouterModelPromotion?,
        currentSpeedQuote: SpeedQuote?,
        isRecommended: Bool = false
    ) -> String? {
        let priceLine: String?
        if let currentSpeedQuote {
            priceLine = currentSpeedQuote.priceLine
        } else if let rates {
            priceLine = menuSubtitle(rates: rates, promotion: promotion)
        } else {
            priceLine = nil
        }
        // OpenRouter's Free Models Router is the free pick to reach for. No
        // row says whether its host trains on prompts: that is OpenRouter's
        // to say (product owner, 2026-10-07).
        guard isRecommended else { return priceLine }
        return ([priceLine].compactMap { $0 } + ["Recommended"]).joined(separator: " · ")
    }

    /// The price of the speed the selected model is set to, from the shared
    /// tier cache; nil off the OpenRouter route or before the endpoint list
    /// has arrived (the row then falls back to the directory price, as the
    /// Speed submenu's Standard row does).
    private var currentSpeedQuote: SpeedQuote? {
        guard tunesEffortAndSpeed, let slug = speedSlug else { return nil }
        let tiers = OpenRouterEndpointTierCatalog.cachedTiers(slug: slug) ?? speedTiers
        guard !tiers.isEmpty,
              let entry = AIModelCatalog.entry(provider: selectedProvider, modelID: selectedModel)
        else { return nil }
        return Self.speedRates(
            for: currentSpeed, slug: slug, tiers: tiers,
            standardFallback: displayedRates(for: entry),
            standardFallbackPromotion: Self.promotion(
                for: entry, routingMode: routingMode, directory: openRouterDirectory),
            speeds: endpointSpeeds(slug: slug)
        )
    }

    /// The shared cache first, the view's copy as the fallback — the same
    /// arrangement as `speedTiers`, and the copy is what re-renders the menu.
    private func endpointSpeeds(slug: String) -> [OpenRouterEndpointSpeed] {
        OpenRouterModelSpeedCatalog.cachedSpeeds(slug: slug) ?? speedsBySlug[slug.lowercased()] ?? []
    }

    /// The selected model's speeds, for the Speed submenu — the only place
    /// the picker quotes one.
    @MainActor
    private func loadEndpointSpeeds() async {
        guard let slug = speedSlug?.lowercased() else { return }
        // A failed fetch keeps whatever the submenu showed before rather
        // than blanking it.
        guard let speeds = try? await OpenRouterModelSpeedCatalog.shared.speeds(for: slug),
              !Task.isCancelled else { return }
        speedsBySlug[slug] = speeds
    }

    /// Slug whose endpoint list drives the Speed submenu for the current pick.
    private var speedSlug: String? {
        AIRequestOptionSupport.openRouterSpeedSlug(
            provider: selectedProvider, model: selectedModel, routingMode: routingMode)
    }

    private var supportedSpeeds: [AISpeed] {
        AIRequestOptionSupport.supportedSpeeds(
            provider: selectedProvider, model: selectedModel, routingMode: routingMode)
    }

    private var currentSpeed: AISpeed { selectedSpeed ?? .standard }

    /// The speed the chip names: the one the Speed submenu checks, for a model
    /// that submenu is offered on; none otherwise.
    private var chipSpeed: AISpeed? {
        guard tunesEffortAndSpeed, showsSelectedModel, isEntryAvailableForCurrentSelection,
              speedSlug != nil, !supportedSpeeds.isEmpty else { return nil }
        return currentSpeed
    }

    /// The efforts the current model takes, fastest first; empty for a model
    /// with no effort parameter, or a picker that is not task-scoped, where
    /// the chip names the model alone and the menu has no Effort submenu.
    private var supportedEfforts: [AIEffort] {
        guard tunesEffortAndSpeed, showsSelectedModel, isEntryAvailableForCurrentSelection else { return [] }
        return AIRequestOptionSupport.supportedEfforts(provider: selectedProvider, model: selectedModel)
    }

    /// The effort a request is sent with when none is picked: the model's own.
    private var defaultEffort: AIEffort {
        AIRequestOptionSupport.displayDefaultEffort(provider: selectedProvider, model: selectedModel) ?? .medium
    }

    /// The effort the chip names and the Effort submenu checks.
    private var currentEffort: AIEffort? {
        Self.chipEffort(selected: selectedEffort, supported: supportedEfforts, modelDefault: defaultEffort)
    }

    /// The effort the chip names: the pick, else the model's default, as the
    /// Effort pill beside the chip showed it until 2026-10-06; none for a
    /// model that takes no effort. Pure so a test can pin it.
    static func chipEffort(selected: AIEffort?, supported: [AIEffort], modelDefault: AIEffort) -> AIEffort? {
        guard !supported.isEmpty else { return nil }
        if let selected, supported.contains(selected) { return selected }
        return modelDefault
    }

    @MainActor
    private func loadSpeedTiers() async {
        guard let slug = speedSlug else {
            speedTiers = []
            return
        }
        // A failed fetch is not an answer: the cache and this copy keep what
        // they had, and a stored pick stands until OpenRouter has actually
        // said the tier is gone. Clearing it on a network blip demoted a
        // learner's Fast pick to Standard without a word.
        guard let tiers = try? await OpenRouterEndpointTierCatalog.shared.tiers(for: slug) else { return }
        guard !Task.isCancelled, speedSlug == slug else { return }
        speedTiers = tiers
        // A pick stored for a model whose tier OpenRouter no longer lists must
        // not keep its checkmark: nothing would honour it.
        if let speed = selectedSpeed, speed != .standard,
           OpenRouterSpeedTier.tier(for: speed, slug: slug, in: tiers) == nil, let task, tunesEffortAndSpeed {
            KeychainService.setTaskSpeed(nil, for: task)
            selectedSpeed = nil
        }
    }

    @MainActor
    private func loadOpenRouterDirectory() async {
        let models = (try? await OpenRouterCatalogAvailability.shared.models()) ?? []
        guard !Task.isCancelled else { return }
        openRouterDirectory = models
    }

    var body: some View {
        modelMenu
        .alert(
            "Model not selected",
            isPresented: Binding(get: { pickRefusal != nil }, set: { if !$0 { pickRefusal = nil } })
        ) {
            Button("OK", role: .cancel) { pickRefusal = nil }
        } message: {
            Text(pickRefusal ?? "")
        }
        .task {
            await syncSelectionFromStorage()
            AIModelPriceRefresher.refreshIfStale()
        }
        .task(id: routingMode) {
            await loadOpenRouterDirectory()
        }
        .task(id: "\(routingMode.rawValue)|\(selectedProvider.rawValue)|\(selectedModel)") {
            await loadSpeedTiers()
        }
        .task(id: "\(routingMode.rawValue)|\(speedSlug ?? "")") {
            await loadEndpointSpeeds()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .aiProviderDidChange)
                .receive(on: RunLoop.main)
        ) { _ in
            // Stay in sync when the model is changed elsewhere (Settings, `/provider`,
            // `/model`) or managed-session availability changes while the picker is visible.
            Task { await syncSelectionFromStorage() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                .receive(on: RunLoop.main)
        ) { _ in
            // Promotions may begin while the app is in the background. The
            // shared five-minute caches keep this event-driven refresh cheap.
            AIModelPriceRefresher.refreshIfStale()
            Task { await loadEndpointSpeeds() }
        }
    }

    /// The model chip. On macOS 14.4 and later its menu opens *above* the
    /// chip: the composer sits at the foot of the chat, and a SwiftUI `Menu`
    /// always drops down, so its list ran off the bottom of the window unless
    /// the screen edge happened to push it up (2026-09-25). A SwiftUI `Menu`
    /// takes no direction, so the items go into an `NSHostingMenu` that an
    /// AppKit anchor pops above the chip (`UpwardMenuAnchor`).
    @ViewBuilder
    private var modelMenu: some View {
        if #available(macOS 14.4, *) {
            // ⌃⇧M opens the chat's chip, Codex's key for its model picker.
            UpwardMenuChip(opensOn: task == .chat ? .openChatModelPicker : nil) {
                modelMenuItems
            } label: {
                modelMenuLabel
            }
            .modifier(modelMenuChrome)
        } else {
            Menu {
                modelMenuItems
            } label: {
                modelMenuLabel
            }
            // The chip is the button style, not label chrome: under
            // `.borderlessButton` AppKit rebuilt the label from its image and text
            // and the chip never drew. See `PickerPillButtonStyle`.
            .pickerPillMenu()
            .modifier(modelMenuChrome)
        }
    }

    private var modelMenuChrome: ModelMenuChrome {
        let subject = task != .chat && task != nil
            ? "Model that checks the answer"
            : currentEffort == nil ? "Model used for this chat" : "Model and effort for this chat"
        return ModelMenuChrome(
            help: currentSpeed != .standard && !supportedSpeeds.isEmpty
                ? "\(subject) — \(currentSpeed.displayName): the lab's \(currentSpeed.displayName.lowercased()) endpoint, at its own price"
                : subject,
            value: showsSelectedModel
                ? "\(selectedProvider.shortName), \(currentModelDisplay)"
                    + (currentEffort.map { ", \($0.displayName) effort" } ?? "")
                    + (currentSpeed != .standard && !supportedSpeeds.isEmpty ? ", \(currentSpeed.displayName)" : "")
                : currentModelDisplay
        )
    }

    /// Recent models the menu leads with: the chat's last picks other than
    /// the one on the chip, each still on the menu's list.
    private var recentMenuRows: [RecentMenuRow] {
        guard task == .chat else { return [] }
        return recentModels.compactMap { recent in
            guard !(recent.provider == selectedProvider.rawValue && recent.model == selectedModel),
                  let entry = menuEntries.first(where: {
                      $0.provider.rawValue == recent.provider && $0.modelID == recent.model
                  }),
                  isEntryAvailable(entry) else { return nil }
            return RecentMenuRow(recent: recent, entry: entry)
        }
    }

    private struct RecentMenuRow {
        let recent: ChatRecentModels.Entry
        let entry: AIModelCatalogEntry
    }

    @ViewBuilder
    private var modelMenuItems: some View {
        // Codex's model picker leads with Recent models: the combinations
        // chosen lately, one press back to each (composer.recentModelConfigurations).
        let recents = recentMenuRows
        if !recents.isEmpty {
            Section("Recent models") {
                ForEach(recents, id: \.recent) { row in
                    Button {
                        selectRecent(row.recent, entry: row.entry)
                    } label: {
                        menuRowLabel(for: row.entry)
                        if let effort = row.recent.effort.flatMap(AIEffort.init(rawValue:)) {
                            Text(effort.displayName)
                        }
                    }
                }
            }
            Divider()
        }
        if !menuEntries.isEmpty {
            // One flat item per model — picking a model also picks its
            // serving host, and the maker grouping already lives in
            // Settings. Only entries on usable hosts appear.
            let currentSpeedQuote = currentSpeedQuote
            Section(Self.priceUnitHeader) {
                ForEach(menuEntries) { entry in
                    // A Toggle, so the item's own state column shows which
                    // model is current; the icon column holds the maker's logo.
                    Toggle(isOn: Binding(
                        get: { isCurrent(entry) },
                        set: { _ in select(entry) }
                    )) {
                        // Flat siblings, not an HStack: in a macOS menu SwiftUI
                        // maps the first Text to the item title and the second
                        // to the small gray subtitle line.
                        menuRowLabel(for: entry)
                        if let subtitle = Self.modelRowSubtitle(
                            rates: displayedRates(for: entry),
                            promotion: Self.promotion(
                                for: entry, routingMode: routingMode, directory: openRouterDirectory),
                            currentSpeedQuote: isCurrent(entry) ? currentSpeedQuote : nil,
                            isRecommended: entry.provider == .openRouter && FreeModelsSetup.isRecommended(entry.modelID)
                        ) {
                            Text(subtitle)
                        }
                    }
                    .disabled(!isEntryAvailable(entry))
                }
            }

            // Effort for the current model, the chip's second word. A pick
            // writes what the composer's Effort pill wrote until 2026-10-06:
            // the chat's own effort, and the effort every later chat starts
            // on (`selectEffort`).
            let efforts = supportedEfforts
            if !efforts.isEmpty {
                let current = currentEffort
                let modelDefault = defaultEffort
                Divider()
                Menu {
                    // Fastest first. A Toggle for the state column, as the
                    // model rows.
                    ForEach(efforts) { effort in
                        Toggle(isOn: Binding(
                            get: { effort == current },
                            set: { _ in selectEffort(effort) }
                        )) {
                            Text(effort.displayName)
                            if effort == modelDefault {
                                Text("The model's default")
                            }
                        }
                    }
                } label: {
                    Text("Effort: \((current ?? modelDefault).displayName)")
                }
            }

            // Speed submenu for the current model, offered only on a route
            // where OpenRouter lists a tier endpoint (Flex or Fast) for it.
            // Each speed is priced from its own endpoint row, so the
            // learner sees what a tier costs before picking it. Presence
            // and prices both come from the shared tier cache: the view's
            // own copy is only the fallback. Task-scoped like the model
            // pick.
            if tunesEffortAndSpeed, isEntryAvailableForCurrentSelection, let slug = speedSlug {
                let speeds = supportedSpeeds
                if !speeds.isEmpty {
                    let tiers = OpenRouterEndpointTierCatalog.cachedTiers(slug: slug) ?? speedTiers
                    let currentEntry = AIModelCatalog.entry(provider: selectedProvider, modelID: selectedModel)
                    let standardRates = currentEntry.flatMap { displayedRates(for: $0) }
                    let standardPromotion = currentEntry.flatMap {
                        Self.promotion(for: $0, routingMode: routingMode, directory: openRouterDirectory)
                    }
                    // Under Effort when the model takes one: the two tune
                    // the same model, so they share a group.
                    if efforts.isEmpty { Divider() }
                    Menu {
                        Section(Self.speedPriceUnitHeader) {
                            ForEach(speeds) { speed in
                                Button {
                                    selectSpeed(speed)
                                } label: {
                                    // Flat siblings again: title, price
                                    // subtitle, state column.
                                    Text(speed.displayName)
                                    if let quote = Self.speedRates(
                                        for: speed, slug: slug, tiers: tiers,
                                        standardFallback: standardRates,
                                        standardFallbackPromotion: standardPromotion,
                                        speeds: endpointSpeeds(slug: slug)
                                    ) {
                                        Text(quote.subtitle)
                                    }
                                    if speed == currentSpeed {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Text("Speed: \(currentSpeed.displayName)")
                    }
                }
            }

            Divider()
        } else {
            Text(Self.emptyMenuNotice(
                hasConfiguredProviders: !configuredProviders.isEmpty
            ).text)
        }

        Button {
            ModelPickerSheetRequest.open(.chat)
        } label: {
            Label("Choose Models…", systemImage: "square.grid.2x2")
        }
    }

    private var modelMenuLabel: some View {
        HStack(spacing: 5) {
            providerMark
                .frame(width: 13, height: 13)
            Text(currentModelDisplay)
                .zoomedSystemFont(size: 11, weight: .medium)
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)
            // The effort, ChatGPT's "GPT-5.6 Sol High": the picker's second
            // word. A model whose Speed submenu exists names its speed as the
            // third ("Opus 5.5 · Low · Fast"; product owner, 2026-10-29: "for
            // models where speed is supported, that should also be shown
            // here"), as the menu's Speed row checks it.
            if let effort = currentEffort {
                Text("\u{00B7} \(effort.displayName)")
                    .zoomedSystemFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let speed = chipSpeed {
                Text("\u{00B7} \(speed.displayName)")
                    .zoomedSystemFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        // Sizing goes *inside* the chip, so the fill, the border and the
        // hit region are all the same rectangle. The chip always shows the
        // model's whole name, at full size: it used to stop at 110pt and
        // then fall back to a shortened name, which cut "Nemotron 3 Ultra
        // (free)" to "Nemotron…ltra (free)" (product owner, 2026-09-25).
        .frame(minWidth: 46, alignment: .leading)
        .fixedSize()
    }

    /// A model not yet tried for this work, or one that failed before, is
    /// tested on the spot and selected only if it passes.
    private func select(_ entry: AIModelCatalogEntry) {
        guard isEntryAvailable(entry), pendingEntry == nil else { return }
        let role = task?.qualificationRole ?? .chat
        if AIModelQualification.isPassed(provider: entry.provider, model: entry.modelID, role: role) {
            apply(entry)
            return
        }
        pendingEntry = entry
        Task {
            let verdict = await Task.detached(priority: .userInitiated) {
                await AIModelQualification.testBeforeSelecting(provider: entry.provider, model: entry.modelID, role: role)
            }.value
            pendingEntry = nil
            if verdict == .go {
                apply(entry)
            } else {
                pickRefusal = AIModelQualification.refusalText(name: entry.displayName, role: role, verdict: verdict)
                await syncSelectionFromStorage()
            }
        }
    }

    private func apply(_ entry: AIModelCatalogEntry) {
        selectedProvider = entry.provider
        selectedModel = entry.modelID

        if let task, tunesEffortAndSpeed {
            KeychainService.setTaskRoute(provider: entry.provider, model: entry.modelID, for: task)
            dropUnsupportedTuning(for: task)
            rememberRecentChoice()
        } else if let task {
            // A task other than the chat keeps its model as its own route; the
            // chat's setter ignores it, and the chip fell back to Background's
            // (the Free Models Router) on the next read.
            KeychainService.setOwnRoute(AITaskModelRoute(provider: entry.provider, model: entry.modelID), for: task)
        } else {
            KeychainService.setDefaultChatRoute(provider: entry.provider, model: entry.modelID)
        }
    }

    private func selectEffort(_ effort: AIEffort?) {
        selectedEffort = effort
        if let task, tunesEffortAndSpeed {
            KeychainService.setTaskEffort(effort, for: task)
            // The next chat starts on this effort too (`taskEffort`).
            if let effort { KeychainService.chosenChatEffort = effort }
            rememberRecentChoice()
        }
    }

    /// A Recent models row: its model, then the effort it was used with
    /// when the model still takes it. A model not yet tried is tested first,
    /// and its effort waits for the next pick.
    private func selectRecent(_ recent: ChatRecentModels.Entry, entry: AIModelCatalogEntry) {
        select(entry)
        guard isCurrent(entry) else { return }
        if let effort = recent.effort.flatMap(AIEffort.init(rawValue:)), supportedEfforts.contains(effort) {
            selectEffort(effort)
        }
    }

    /// Files the chat's model and effort as the newest Recent models row.
    private func rememberRecentChoice() {
        guard task == .chat else { return }
        recentModels = ChatRecentModels.record(
            .init(provider: selectedProvider.rawValue, model: selectedModel, effort: currentEffort?.rawValue)
        )
    }

    private func selectSpeed(_ speed: AISpeed) {
        selectedSpeed = speed == .standard ? nil : speed
        if let task, tunesEffortAndSpeed {
            KeychainService.setTaskSpeed(speed == .standard ? nil : speed, for: task)
        }
    }

    /// Clear an effort/speed pick the newly selected model can't honor, so the
    /// menu never shows a checkmark on an option that won't be sent.
    private func dropUnsupportedTuning(for task: AITask) {
        if let effort = KeychainService.taskEffort(task),
           !AIRequestOptionSupport.supportedEfforts(provider: selectedProvider, model: selectedModel).contains(effort) {
            KeychainService.setTaskEffort(nil, for: task)
            selectedEffort = nil
        }
        // Speed is judged on the tiers already fetched for the new model. A
        // route with no OpenRouter slug can never honour a tier, so the pick
        // goes; a cold cache is not "unsupported" — `loadSpeedTiers` drops a
        // stale pick itself once OpenRouter has answered.
        if let speed = KeychainService.taskSpeed(task), speed != .standard {
            let stillSupported: Bool
            if let slug = speedSlug {
                if let tiers = OpenRouterEndpointTierCatalog.cachedTiers(slug: slug) {
                    stillSupported = OpenRouterSpeedTier.tier(for: speed, slug: slug, in: tiers) != nil
                } else {
                    stillSupported = true
                }
            } else {
                stillSupported = false
            }
            if !stillSupported {
                KeychainService.setTaskSpeed(nil, for: task)
                selectedSpeed = nil
            }
        }
    }

    private struct StoredSelectionSnapshot: Sendable {
        let routingMode: AITextRoutingMode
        let configuredProviders: [AIProvider]
        let menuEntries: [AIModelCatalogEntry]
        let provider: AIProvider
        let model: String
        let effort: AIEffort?
        let speed: AISpeed?
        let recentModels: [ChatRecentModels.Entry]
    }

    @MainActor
    private func syncSelectionFromStorage() async {
        guard !UITestConfiguration.isUITesting else { return }
        let task = task
        let snapshot = await Task.detached(priority: .userInitiated) {
            let routingMode = KeychainService.textRoutingMode
            let configuredProviders = Self.loadConfiguredProviders()
            let menuEntries = Self.loadMenuEntries(task: task)
            if let task {
                let selection = KeychainService.resolvedSelection(for: task)
                return StoredSelectionSnapshot(
                    routingMode: routingMode,
                    configuredProviders: configuredProviders,
                    menuEntries: menuEntries,
                    provider: selection.provider,
                    model: selection.model,
                    effort: KeychainService.taskEffort(task),
                    speed: KeychainService.taskSpeed(task),
                    recentModels: task == .chat ? ChatRecentModels.load() : []
                )
            }
            let provider = KeychainService.aiProvider
            return StoredSelectionSnapshot(
                routingMode: routingMode,
                configuredProviders: configuredProviders,
                menuEntries: menuEntries,
                provider: provider,
                model: KeychainService.model(for: provider),
                effort: nil,
                speed: nil,
                recentModels: []
            )
        }.value
        guard !Task.isCancelled else { return }
        routingMode = snapshot.routingMode
        configuredProviders = snapshot.configuredProviders
        menuEntries = snapshot.menuEntries
        selectedProvider = snapshot.provider
        selectedModel = snapshot.model
        selectedEffort = snapshot.effort
        selectedSpeed = snapshot.speed
        recentModels = snapshot.recentModels
        // Load the tiers for the synced selection here as well as from the
        // selection-keyed task: seen live, the first menu open otherwise built
        // its items before the restarted task had fetched them, and the popup
        // had no Speed entry until the next open.
        await loadSpeedTiers()
    }

    private var isEntryAvailableForCurrentSelection: Bool {
        guard let entry = AIModelCatalog.entry(
            provider: selectedProvider,
            modelID: selectedModel
        ) else { return false }
        return isEntryAvailable(entry)
    }

    /// What the menu says when it has no model to list. Kept pure so a test
    /// can pin the one distinction that matters: a signed-in account whose
    /// list is empty is never told to sign in.
    enum EmptyMenuNotice: Equatable {
        case signInRequired
        case noModelsAvailable

        var text: String {
            switch self {
            case .signInRequired: return "Sign in with Apple to choose a model"
            case .noModelsAvailable: return "No models available right now"
            }
        }
    }

    static func emptyMenuNotice(hasConfiguredProviders: Bool) -> EmptyMenuNotice {
        // No usable provider means no managed session on this Mac: the only
        // case where signing in is the remedy.
        if !hasConfiguredProviders { return .signInRequired }
        return .noModelsAvailable
    }
}

/// The model chip's help and accessibility, shared by both menu routes.
private struct ModelMenuChrome: ViewModifier {
    let help: String
    let value: String

    func body(content: Content) -> some View {
        content
            .help(help)
            .accessibilityLabel("Chat model")
            .accessibilityValue(value)
    }
}

/// A pill chip whose menu opens above it. The items are authored in SwiftUI
/// and built into a fresh `NSHostingMenu` on each press, so they reflect the
/// current selection; an AppKit view behind the chip pops the menu with its
/// bottom edge just over the chip's top edge. AppKit still moves a menu that
/// would leave the screen, so a chip near the top of a display gets it below.
@available(macOS 14.4, *)
struct UpwardMenuChip<Items: View, Label: View>: View {
    /// A request that opens the menu as a press would, answered by the chip in
    /// the key window (the model chip's ⌃⇧M). The request's object is a token
    /// one chip takes, so two chats side by side open one menu, not two.
    var opensOn: Notification.Name? = nil
    @ViewBuilder var items: () -> Items
    @ViewBuilder var label: () -> Label

    @State private var anchor = UpwardMenuAnchor()

    var body: some View {
        Button {
            anchor.present(NSHostingMenu(rootView: items()))
        } label: {
            label()
        }
        .buttonStyle(.pickerPill)
        .background(UpwardMenuAnchorView(anchor: anchor))
        .onReceive(NotificationCenter.default.publisher(for: opensOn ?? .upwardMenuChipNeverOpens)) { note in
            guard opensOn != nil, anchor.view?.window?.isKeyWindow == true,
                  let token = note.object as? UUID, UpwardMenuAnchor.claim(token) else { return }
            anchor.present(NSHostingMenu(rootView: items()))
        }
    }
}

extension Notification.Name {
    /// Opens the chat's model chip in the key window (⌃⇧M); the object is a
    /// fresh `UUID` per press.
    static let openChatModelPicker = Notification.Name("openChatModelPicker")
    /// Never posted: what a chip with no `opensOn` listens to.
    static let upwardMenuChipNeverOpens = Notification.Name("upwardMenuChipNeverOpens")
}

/// The models and efforts chosen lately for chats, newest first: the model
/// chip's Recent models, as Codex's picker has (composer.recentModelConfigurations,
/// "Open recently used model, effort, and speed combinations"). One row per
/// model, with the effort it was last used at. This Mac's convenience, kept in
/// its defaults: what a learner switches between here is not a setting.
enum ChatRecentModels {
    struct Entry: Codable, Equatable, Hashable, Sendable {
        let provider: String
        let model: String
        let effort: String?
    }

    static let defaultsKey = "chat.recentModels"
    /// Rows kept; the chip's own model is one of them and is not listed.
    static let limit = 4

    /// `entry` at the head of `list`, replacing that model's older row,
    /// with no more than `limit` rows.
    static func adding(_ entry: Entry, to list: [Entry]) -> [Entry] {
        let rest = list.filter { !($0.provider == entry.provider && $0.model == entry.model) }
        return Array(([entry] + rest).prefix(limit))
    }

    static func load(defaults: UserDefaults = .standard) -> [Entry] {
        guard let data = defaults.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return list
    }

    /// Files `entry` as the newest row and returns the list as stored.
    @discardableResult
    static func record(_ entry: Entry, defaults: UserDefaults = .standard) -> [Entry] {
        let list = adding(entry, to: load(defaults: defaults))
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: defaultsKey)
        }
        return list
    }
}

/// Weak handle from the SwiftUI chip to the AppKit view it pops the menu from.
/// Not observable on purpose: nothing renders from it.
final class UpwardMenuAnchor {
    weak var view: NSView?

    /// The gap between the chip's top edge and the menu's bottom edge.
    static let gap: CGFloat = 4

    /// The point `NSMenu.popUp(positioning: nil, at:in:)` takes as the menu's
    /// top-left corner, in `bounds` of a view flipped or not, so the menu of
    /// `menuHeight` ends `gap` above the view.
    static func origin(in bounds: NSRect, isFlipped: Bool, menuHeight: CGFloat) -> NSPoint {
        let y = isFlipped
            ? bounds.minY - gap - menuHeight
            : bounds.maxY + gap + menuHeight
        return NSPoint(x: bounds.minX, y: y)
    }

    /// Tokens of open requests a chip has answered; see `UpwardMenuChip.opensOn`.
    @MainActor private static var claimedTokens: [UUID] = []

    /// True for the first chip to claim `token`.
    @MainActor
    static func claim(_ token: UUID) -> Bool {
        guard !claimedTokens.contains(token) else { return false }
        claimedTokens = Array((claimedTokens + [token]).suffix(8))
        return true
    }

    @MainActor
    func present(_ menu: NSMenu) {
        guard let view else { return }
        menu.popUp(
            positioning: nil,
            at: Self.origin(in: view.bounds, isFlipped: view.isFlipped, menuHeight: menu.size.height),
            in: view
        )
    }
}

private struct UpwardMenuAnchorView: NSViewRepresentable {
    let anchor: UpwardMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

// MARK: - Docs model menu

/// The menu under the ForeverLM mark in a Doc's Edit with AI panel: the model
/// Docs run on (product owner, 2026-09-29: "for rewrites; let me choose a model",
/// then "give the foreverlm logo to click and then we can select models
/// there"). It lists the models the chat's own picker offers, after the
/// Default Model that Docs follow until one is picked. The pick is
/// `KeychainService.docsRoute`, synced, so every doc on every Mac uses it; a
/// chat's own pick never reaches it. A model not yet tried for chat is tested
/// first, as the chat's picker does, and a refusal is said in the panel.
enum DocsModelMenu {
    /// Everything the menu shows, read off the main actor: the catalog and
    /// the stored routes can reach `KeychainService.load`.
    struct Snapshot: Sendable {
        let docsRoute: AITaskModelRoute?
        let defaultRoute: AITaskModelRoute
        let entries: [AIModelCatalogEntry]
        let configuredProviders: Set<AIProvider>
    }

    static func load() -> Snapshot {
        let provider = KeychainService.aiProvider
        return Snapshot(
            docsRoute: KeychainService.docsRoute,
            defaultRoute: AITaskModelRoute(provider: provider, model: KeychainService.model(for: provider)),
            entries: InlineModelPicker.loadMenuEntries(task: .chat),
            configuredProviders: Set(AIProvider.activeChatProviders.filter {
                KeychainService.hasUsableTextProviderCredentials(for: $0)
            })
        )
    }

    /// What the mark's tooltip names: the model an edit runs on now. Reaches
    /// `KeychainService`; call it off the main actor.
    static func currentModelName() -> String {
        let route = KeychainService.displayedDocsRoute
        return AIModelCatalog.pickerName(provider: route.provider, modelID: route.model)
    }

    /// Pops the menu with its top-left corner just under `rect`, a rectangle
    /// in `view`'s top-down coordinates (the web page's own, for the editor).
    /// `refuse` hears why a picked model was not applied.
    @MainActor
    static func present(in view: NSView, below rect: CGRect, refuse: @escaping @MainActor (String) -> Void) async {
        let snapshot = await Task.detached(priority: .userInitiated) { load() }.value
        let menu = makeMenu(snapshot, refuse: refuse)
        let top = rect.maxY + 4
        let point = NSPoint(x: rect.minX, y: view.isFlipped ? top : view.bounds.height - top)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    @MainActor
    static func makeMenu(_ snapshot: Snapshot, refuse: @escaping @MainActor (String) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let defaultName = AIModelCatalog.pickerName(
            provider: snapshot.defaultRoute.provider, modelID: snapshot.defaultRoute.model)
        menu.addItem(ActionMenuItem(title: "Default Model (\(defaultName))", isOn: snapshot.docsRoute == nil) {
            Task.detached(priority: .userInitiated) { KeychainService.setDocsRoute(nil) }
        })
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: InlineModelPicker.priceUnitHeader))
        var entries = snapshot.entries
        // A Docs model the chat no longer offers stays listed, and checked,
        // so the menu never hides what the edits run on.
        if let docs = snapshot.docsRoute, !entries.contains(where: { isSame($0, docs) }) {
            entries.insert(
                AIModelCatalog.entry(provider: docs.provider, modelID: docs.model)
                    ?? AIModelCatalogEntry(maker: .other, provider: docs.provider, modelID: docs.model),
                at: 0
            )
        }
        for entry in entries {
            let item = ActionMenuItem(
                title: AIModelCatalog.pickerName(provider: entry.provider, modelID: entry.modelID),
                isOn: snapshot.docsRoute.map { isSame(entry, $0) } ?? false
            ) {
                pick(entry, refuse: refuse)
            }
            item.image = mark(for: entry)
            if #available(macOS 14.4, *) {
                item.subtitle = InlineModelPicker.modelRowSubtitle(
                    rates: AIModelListPrice.rates(for: entry),
                    promotion: nil,
                    currentSpeedQuote: nil,
                    isRecommended: entry.provider == .openRouter && FreeModelsSetup.isRecommended(entry.modelID)
                )
            }
            item.isEnabled = snapshot.configuredProviders.contains(entry.provider)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let choose = ActionMenuItem(title: "Choose Models…", isOn: false) {
            ModelPickerSheetRequest.open(.chat)
        }
        choose.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        menu.addItem(choose)
        return menu
    }

    /// One model under two hosts' names is one pick.
    private static func isSame(_ entry: AIModelCatalogEntry, _ route: AITaskModelRoute) -> Bool {
        if entry.provider == route.provider, entry.modelID == route.model { return true }
        return OpenRouterModelID.slug(provider: entry.provider, model: entry.modelID).lowercased()
            == OpenRouterModelID.slug(provider: route.provider, model: route.model).lowercased()
    }

    @MainActor
    private static func pick(_ entry: AIModelCatalogEntry, refuse: @escaping @MainActor (String) -> Void) {
        let route = AITaskModelRoute(provider: entry.provider, model: entry.modelID)
        guard !AIModelQualification.isPassed(provider: entry.provider, model: entry.modelID, role: .chat) else {
            Task.detached(priority: .userInitiated) { KeychainService.setDocsRoute(route) }
            return
        }
        Task {
            let verdict = await Task.detached(priority: .userInitiated) {
                await AIModelQualification.testBeforeSelecting(provider: entry.provider, model: entry.modelID, role: .chat)
            }.value
            if verdict == .go {
                await Task.detached(priority: .userInitiated) { KeychainService.setDocsRoute(route) }.value
            } else if let text = AIModelQualification.refusalText(name: entry.displayName, role: .chat, verdict: verdict) {
                refuse(text)
            }
        }
    }

    /// The model maker's logo at menu size, else its symbol.
    @MainActor
    private static func mark(for entry: AIModelCatalogEntry) -> NSImage? {
        if let source = NSImage(named: entry.maker.iconName), let copy = source.copy() as? NSImage {
            copy.size = NSSize(width: 14, height: 14)
            return copy
        }
        return NSImage(systemSymbolName: entry.maker.systemImageFallback, accessibilityDescription: nil)
    }
}

/// A menu item that runs a closure, with a checkmark when `isOn`.
final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, isOn: Bool, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = isOn ? .on : .off
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor @objc private func run() {
        handler()
    }
}
