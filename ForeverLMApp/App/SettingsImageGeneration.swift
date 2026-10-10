#if os(macOS)
import AppKit
import Foundation
import SwiftUI

/// Account preferences for generated imagery.
///
/// Image models are media, so they are chosen here rather than in the `AITask`
/// list: that list resolves models from the text router's catalog, which has
/// nothing that draws. This is the same split `MacArticleSpeechSettings` makes
/// for voices.
enum MacImageGenerationSettings {
    /// Whether ForeverLM may pay to draw anything at all. Off until asked for:
    /// every other way a source gets its thumbnail is free, and this one is not.
    static let enabledKey = "images.generateIcons"
    /// Whether a meeting imported from now on gets an icon without being asked.
    /// Meaningless while `enabledKey` is false.
    static let automaticForNewMeetingsKey = "images.generateIcons.automatic"
    /// Whether a course quiz gets its picture as soon as it is written.
    /// Independent of `enabledKey`, which governs meeting icons; a quiz's
    /// picture was always drawn on the learner's request, and writing the
    /// quiz is that request.
    static let automaticForNewQuizzesKey = "images.drawQuizPictures.automatic"
    /// Whether a notebook made one at a time gets its cover drawn without
    /// being asked, and whether the one-time cover backfill runs (schema v2
    /// D53, §5.9). Generation 2 only: generation 1 has no cover to write.
    static let automaticForNewNotebooksKey = "images.drawNotebookCovers.automatic"
    static let modelKey = "images.model"
    static let styleKey = "images.style"
    static let sourceKey = "images.source"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool) {
        PreferenceStore.set(enabled, forKey: enabledKey)
    }

    /// Defaults to true so that turning the feature on is one decision rather
    /// than two. It only takes effect once the feature is on.
    static var generatesForNewMeetings: Bool {
        guard UserDefaults.standard.object(forKey: automaticForNewMeetingsKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: automaticForNewMeetingsKey)
    }

    static func setGeneratesForNewMeetings(_ enabled: Bool) {
        PreferenceStore.set(enabled, forKey: automaticForNewMeetingsKey)
    }

    /// Defaults to true (product owner, 2026-09-26: quizzes between lectures get
    /// their picture without a second ask). Free mode draws nothing: an image
    /// model is never free, so the proxy would only refuse each one.
    static var drawsForNewQuizzes: Bool {
        guard UserDefaults.standard.object(forKey: automaticForNewQuizzesKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: automaticForNewQuizzesKey)
    }

    static func setDrawsForNewQuizzes(_ enabled: Bool) {
        PreferenceStore.set(enabled, forKey: automaticForNewQuizzesKey)
    }

    /// What a quiz run should do once it has written its quizzes.
    static var drawsPicturesAfterWritingQuizzes: Bool {
        drawsForNewQuizzes && !AIFreeMode.isOn
    }

    /// Defaults to true (product owner, 2026-10-03: "rather than emojis; can we use
    /// the ai generated icons? from a cheap image model"). Free mode draws
    /// nothing, as for quiz pictures.
    static var drawsNotebookCovers: Bool {
        guard UserDefaults.standard.object(forKey: automaticForNewNotebooksKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: automaticForNewNotebooksKey)
    }

    static func setDrawsNotebookCovers(_ enabled: Bool) {
        PreferenceStore.set(enabled, forKey: automaticForNewNotebooksKey)
    }

    /// Whether covers are drawn without being asked now: generation 2, the
    /// Setting on and Free mode off.
    static var drawsNotebookCoversAutomatically: Bool {
        ForeverLMRuntimeIdentity.syncGeneration == .two && drawsNotebookCovers && !AIFreeMode.isOn
    }

    /// The stored choice. Before OpenRouter's directory has been read this
    /// launch it is a stand-in that names the model by its slug, and a read
    /// starts; drawing resolves it either way (`ImageGenerationDirectory.resolve`).
    static var model: ImageGenerationModel {
        ImageGenerationDirectory.warm()
        return ImageGenerationCatalog.resolvedModel(id: UserDefaults.standard.string(forKey: modelKey))
    }

    /// Stores a model OpenRouter's last directory read lists.
    static func setModel(_ id: String) {
        guard let model = ImageGenerationCatalog.model(id: id) else { return }
        PreferenceStore.set(model.id, forKey: modelKey)
    }

    /// Defaults to preferring a real thumbnail: it is the free answer, and the
    /// one a learner who never opens this pane is better served by.
    static var source: ImageGenerationCatalog.Source {
        UserDefaults.standard.string(forKey: sourceKey)
            .flatMap(ImageGenerationCatalog.Source.init(rawValue:)) ?? .preferThumbnail
    }

    static func setSource(_ source: ImageGenerationCatalog.Source) {
        PreferenceStore.set(source.rawValue, forKey: sourceKey)
    }

    /// What the acquisition path should actually do. A drawing preference means
    /// nothing while drawing is off, so it is resolved here rather than at every
    /// call site.
    static var effectiveSource: ImageGenerationCatalog.Source {
        isEnabled ? source : .preferThumbnail
    }

    static var style: ImageGenerationCatalog.Style {
        UserDefaults.standard.string(forKey: styleKey)
            .flatMap(ImageGenerationCatalog.Style.init(rawValue:)) ?? .emblem
    }

    static func setStyle(_ style: ImageGenerationCatalog.Style) {
        PreferenceStore.set(style.rawValue, forKey: styleKey)
    }
}

/// Settings › Images: the one image choice a learner makes, which model draws.
/// The meeting-icon switches stay off the window (get_app_settings /
/// set_app_setting, "Images (no pane)"): drawing icons is off until asked for.
/// Laid out as Settings › Chat (product owner, 2026-09-28: the chat's "setup with
/// suggested models and then all at the bottom"): a Suggested list, one model
/// per maker (`ImageGenerationCatalog.suggestedModelIDs`), then every model
/// OpenRouter's Image API serves, by maker, with a search. The models are
/// read when the pane opens (product owner, 2026-09-27: "you have to include way
/// more image models").
struct ImageGenerationSettingsDetailView: View {
    @SyncedStorage(wrappedValue: ImageGenerationCatalog.defaultModelID, MacImageGenerationSettings.modelKey)
    private var modelID: String
    @SyncedStorage(wrappedValue: true, MacImageGenerationSettings.automaticForNewQuizzesKey)
    private var drawsForNewQuizzes: Bool
    @SyncedStorage(wrappedValue: true, MacImageGenerationSettings.automaticForNewNotebooksKey)
    private var drawsNotebookCovers: Bool
    /// Seeded from the last read so a reopened pane draws at once; the
    /// `.task` below refreshes it, then fills in the prices.
    @State private var models: [ImageGenerationModel] = ImageGenerationDirectory.snapshot
    @State private var pricesLoaded = false
    /// OpenRouter's promotions, by lowercased slug: the image directory
    /// carries none, its catalog does (`OpenRouterPromotions`).
    @State private var promotions = OpenRouterPromotions.current
    @State private var isLoading = false
    @State private var loadError: String?
    /// The model the pane opened on, once the directory named it: listed
    /// above Suggested for the visit when Suggested does not show it.
    @State private var openedOnID: String?

    private var model: ImageGenerationModel {
        ImageGenerationCatalog.resolvedModel(id: modelID, in: models)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection(
                    title: "Model",
                    description: "Draws the pictures you ask Chat for, quiz pictures, and meeting icons. The price is OpenRouter's."
                ) {
                    modelLists
                }
                SettingsSection(title: "Course quizzes") {
                    SettingsCard {
                        Toggle(isOn: $drawsForNewQuizzes) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Draw pictures for new quizzes")
                                    .font(.headline)
                                Text("A quiz between lectures gets a picture of its topic as soon as it is written, and up to \(CourseQuizPictures.maximumDrawingsPerQuiz) drawings for questions no slide or figure shows, on the model above. Off, a quiz's menu still has Draw Picture and Add Pictures to Questions.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                }
                // Generation 1 has no cover to write, so it neither shows nor
                // syncs the switch (schema v2 D40, D53).
                if ForeverLMRuntimeIdentity.syncGeneration == .two {
                    SettingsSection(title: "Notebooks") {
                        SettingsCard {
                            Toggle(isOn: $drawsNotebookCovers) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Draw notebook covers")
                                        .font(.headline)
                                    Text("A notebook you make gets a small picture of its subject in place of its emoji, drawn once on the model above when it has a name, and every notebook without one gets one once. Never in Free mode. Off, a notebook keeps its emoji unless you choose Draw Cover With in its menu.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .toggleStyle(.switch)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Images")
        .task { await load() }
        .task { await loadPromotions() }
    }

    @ViewBuilder
    private var modelLists: some View {
        if models.isEmpty {
            SettingsCard {
                MediaDirectoryStatus(
                    subject: "image models",
                    error: loadError,
                    retry: { Task { await load(forceRefresh: true) } }
                )
            }
        } else {
            let makers = MediaModelLists.makers(models, slug: \.id, makerName: \.maker)
            let suggested = MediaModelLists.suggestions(ImageGenerationCatalog.suggestedModelIDs, in: models, slug: \.id, listedAt: \.createdAt)
            let pinned = MediaModelLists.pinned(openedOn: openedOnID, in: models, suggested: suggested, slug: \.id)
            SettingsCard {
                VStack(alignment: .leading, spacing: 18) {
                    if let pinned {
                        SettingsModelListSection(title: "Your model") {
                            row(pinned, makers: makers, showsMaker: true)
                        }
                    }
                    if !suggested.isEmpty {
                        SettingsModelListSection(title: "Suggested") {
                            ForEach(suggested) { option in
                                row(option, makers: makers, showsMaker: true)
                            }
                        }
                    }
                    if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            SettingsCard {
                MediaModelBrowser(
                    models: models,
                    state: isLoading ? .loading : .loaded,
                    subject: "image models",
                    retry: { Task { await load(forceRefresh: true) } },
                    slug: \.id,
                    makerName: \.maker,
                    searchFields: { [$0.name, $0.id] },
                    isFree: { $0.price?.isFree == true },
                    isDiscounted: { promotion(for: $0) != nil },
                    row: { option, showsMaker in
                        row(option, makers: makers, showsMaker: showsMaker)
                    }
                )
            }
        }
    }

    /// A promoted model shows the price it is billed at, the list price
    /// struck through ahead of it.
    private func row(_ option: ImageGenerationModel, makers: [ModelBrowserMaker<ImageGenerationModel>], showsMaker: Bool) -> some View {
        let promotion = self.promotion(for: option)
        let billed = promotion.flatMap { promotion in option.price?.mapped(promotion.effectiveRate(fromList:)) }
        let listPrice = billed.flatMap { billed in
            option.price.map(\.amountLabel).flatMap { $0 == billed.amountLabel ? nil : $0 }
        }
        return MediaModelRow(
            name: option.name,
            slug: option.id,
            maker: MediaModelLists.identity(ofSlug: option.id, in: makers),
            showsMaker: showsMaker,
            detail: priceLabel(for: billed ?? option.price),
            listPrice: listPrice,
            isSelected: option.id == model.id,
            badges: promotion.map { [ModelRowBadge(text: $0.label, tint: .accent)] } ?? [],
            help: helpText(for: option, billed: billed)
        ) {
            modelID = option.id
        }
    }

    /// The promotion OpenRouter runs on the model; none on a free one, which
    /// has no price to cut.
    private func promotion(for model: ImageGenerationModel) -> RouterModelPromotion? {
        guard model.price?.isFree != true else { return nil }
        return promotions[model.id.lowercased()]
    }

    private func loadPromotions() async {
        _ = try? await OpenRouterCatalogAvailability.shared.models()
        promotions = OpenRouterPromotions.current
    }

    private func load(forceRefresh: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        do {
            models = try await ImageGenerationDirectory.models(forceRefresh: forceRefresh)
            loadError = nil
            adoptOpenedOn()
            models = try await ImageGenerationDirectory.modelsWithPrices(forceRefresh: forceRefresh)
            pricesLoaded = true
        } catch {
            loadError = error.localizedDescription
        }
        adoptOpenedOn()
    }

    /// Settles which model the pane opened on, once: the first time the
    /// directory is in hand.
    private func adoptOpenedOn() {
        guard openedOnID == nil, !models.isEmpty else { return }
        openedOnID = model.id
    }

    /// The row's figures: OpenRouter's price for a picture, or its token rate.
    private func priceLabel(for price: ImageGenerationPrice?) -> String {
        if let price { return price.label }
        return pricesLoaded ? "Price not listed" : "Reading the price…"
    }

    /// `billed` is the price a promotion leaves, when one runs.
    private func helpText(for model: ImageGenerationModel, billed: ImageGenerationPrice?) -> String {
        var parts: [String] = []
        if !model.detail.isEmpty { parts.append(model.detail) }
        parts.append(model.revisesPictures ? "Can revise a picture it drew." : "Draws only; cannot revise a picture.")
        if let price = billed ?? model.price { parts.append(price.sentence) }
        if billed != nil, let list = model.price, let promotion = self.promotion(for: model) {
            parts.append("Down from \(list.label) while OpenRouter's \(promotion.label) lasts.")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Media makers

/// A maker's logo as openrouter.ai draws it, for the makers no logo is
/// bundled for (Black Forest Labs, Recraft, Krea, Runway…).
///
/// OpenRouter's API names a model's maker but carries no logo, so this reads
/// the maker's page (`openrouter.ai/black-forest-labs`) and takes the icon its
/// header draws: one OpenRouter hosts (`/images/icons/Recraft.svg`), or
/// Google's favicon of the maker's site, which is what openrouter.ai shows
/// too. Each is read once and kept on disk for a month, so opening Settings
/// does not fetch a page per maker; a maker whose page names no icon keeps the
/// pane's symbol.
enum OpenRouterMakerIcon {
    static let site = URL(string: "https://openrouter.ai")!

    /// The maker's page, from the slug prefix a model id opens with. Nil for
    /// anything but a plain slug, so no id can reach another path.
    static func pageURL(forMaker slug: String) -> URL? {
        let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits).union(CharacterSet(charactersIn: "-_."))
        guard !slug.isEmpty, slug.unicodeScalars.allSatisfy(allowed.contains), slug.contains(where: \.isLetter) else {
            return nil
        }
        return site.appendingPathComponent(slug)
    }

    /// The icon the page's header draws: the first `<img alt="Favicon for
    /// slug">`, resolved against openrouter.ai. Only an https address counts.
    static func iconURL(inPage html: String, maker slug: String) -> URL? {
        let alt = "alt=\"Favicon for \(slug)\""
        var rest = html[...]
        while let open = rest.range(of: "<img ") {
            let tail = rest[open.upperBound...]
            guard let close = tail.firstIndex(of: ">") else { return nil }
            let tag = " " + tail[..<close]
            rest = tail[close...]
            guard tag.contains(alt),
                  let start = tag.range(of: " src=\"")?.upperBound,
                  let end = tag[start...].firstIndex(of: "\"") else { continue }
            let src = tag[start..<end].replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: src, relativeTo: site)?.absoluteURL, url.scheme == "https" else { return nil }
            return url
        }
        return nil
    }

    /// The icon's bytes (PNG or SVG, which `NSImage(data:)` both reads), or
    /// nil when OpenRouter names none or could not be reached.
    static func data(forMaker slug: String) async -> Data? {
        await store.data(forMaker: slug)
    }

    private static let store = Store()

    private actor Store {
        private static let freshness: TimeInterval = 30 * 24 * 60 * 60
        /// Only icons found: a maker that came back empty (OpenRouter
        /// unreachable, say) is asked again the next time a pane opens.
        private var read: [String: Data] = [:]
        private var inFlight: [String: Task<Data?, Never>] = [:]

        func data(forMaker slug: String) async -> Data? {
            if let known = read[slug] { return known }
            if let task = inFlight[slug] { return await task.value }
            let task = Task { await Self.load(slug) }
            inFlight[slug] = task
            let data = await task.value
            inFlight[slug] = nil
            if let data { read[slug] = data }
            return data
        }

        private static func directory() -> URL {
            let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            return root.appendingPathComponent("OpenRouterMakerIcons", isDirectory: true)
        }

        private static func load(_ slug: String) async -> Data? {
            guard let page = OpenRouterMakerIcon.pageURL(forMaker: slug) else { return nil }
            let file = directory().appendingPathComponent(slug)
            let saved = try? Data(contentsOf: file)
            if saved != nil,
               let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               Date().timeIntervalSince(modified) < freshness {
                return saved
            }
            // A month-old copy still beats the symbol when OpenRouter is
            // unreachable or its page has changed shape.
            guard let html = await fetch(page).flatMap({ String(data: $0, encoding: .utf8) }),
                  let icon = OpenRouterMakerIcon.iconURL(inPage: html, maker: slug),
                  let data = await fetch(icon),
                  NSImage(data: data) != nil else {
                return saved
            }
            try? FileManager.default.createDirectory(at: directory(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return data
        }

        private static func fetch(_ url: URL) async -> Data? {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return data
        }
    }
}

/// A maker's logo: the bundled one, else the one openrouter.ai draws
/// (`OpenRouterMakerIcon`), else a symbol. Settings › Images and › Videos
/// head their makers with it, and Settings › Chat's maker picker draws one
/// for every maker OpenRouter lists.
struct OpenRouterMakerLogo: View {
    let bundled: AIModelMaker?
    /// The maker's OpenRouter slug, whose page supplies a logo when none is
    /// bundled.
    let openRouterSlug: String?
    let fallbackSymbol: String

    @State private var fetchedLogo: NSImage?

    var body: some View {
        if let bundled {
            MakerLogo(maker: bundled)
        } else if let fetchedLogo {
            Image(nsImage: fetchedLogo)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            Image(systemName: fallbackSymbol)
                .zoomedSystemFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
                .task(id: openRouterSlug) {
                    guard let slug = openRouterSlug,
                          let data = await OpenRouterMakerIcon.data(forMaker: slug) else { return }
                    fetchedLogo = NSImage(data: data)
                }
        }
    }
}

/// What a media pane shows before OpenRouter's directory has arrived: a
/// spinner while it is read, and the reason with a retry when it could not be.
struct MediaDirectoryStatus: View {
    let subject: String
    let error: String?
    let retry: () -> Void

    var body: some View {
        if let error {
            VStack(alignment: .leading, spacing: 8) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again", action: retry)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading OpenRouter's \(subject)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#endif
