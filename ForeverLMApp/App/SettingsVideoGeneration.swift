#if os(macOS)
import Foundation
import SwiftUI

/// Account preferences for generated video.
///
/// Video models are media, so they are chosen here rather than in the `AITask`
/// list: that list resolves models from the text router's catalog, which has
/// nothing that films. The same split `MacImageGenerationSettings` makes for
/// pictures and `MacArticleSpeechSettings` for voices. The storyboard a video
/// starts from is written by the Explainer Writing route, which stays in that
/// list.
enum MacVideoGenerationSettings {
    static let modelKey = Prefs.Imaging.videoModel.name
    static let resolutionKey = Prefs.Imaging.videoResolution.name

    /// The stored choice. Before OpenRouter's directory has been read this
    /// launch it is a stand-in named by its slug, and a read starts; filming
    /// resolves it either way (`VideoGenerationDirectory.resolve`).
    static var model: VideoGenerationModel {
        VideoGenerationDirectory.warm()
        return VideoGenerationCatalog.resolvedModel(id: Preferences.value(Prefs.Imaging.videoModel))
    }

    /// Stores a model OpenRouter's last directory read lists.
    static func setModel(_ id: String) {
        guard let model = VideoGenerationCatalog.model(id: id) else { return }
        Preferences.set(model.id, for: Prefs.Imaging.videoModel)
    }

    static var resolution: VideoGenerationCatalog.Resolution {
        VideoGenerationCatalog.resolvedResolution(Preferences.value(Prefs.Imaging.videoResolution), for: model)
    }

    static func setResolution(_ resolution: VideoGenerationCatalog.Resolution) {
        Preferences.set(resolution.rawValue, for: Prefs.Imaging.videoResolution)
    }
}

/// Settings › Videos: which model films an explainer, and at what resolution.
/// Laid out as Settings › Chat (product owner, 2026-09-28): a Suggested list, one
/// model per maker (`VideoGenerationCatalog.suggestedModelIDs`), then every
/// model OpenRouter's video API serves, by maker, with a search. The models
/// are read when the pane opens (product owner, 2026-09-27: "why don't we have all
/// of them shown here?").
struct VideoGenerationSettingsDetailView: View {
    @PreferenceStorage(Prefs.Imaging.videoModel, default: VideoGenerationCatalog.defaultModelID)
    private var modelID: String
    @PreferenceStorage(Prefs.Imaging.videoResolution, default: VideoGenerationCatalog.Resolution.hd.rawValue)
    private var resolutionID: String
    @State private var models: [VideoGenerationModel] = VideoGenerationDirectory.snapshot
    /// OpenRouter's promotions, by lowercased slug: the video directory
    /// carries none, its catalog does (`OpenRouterPromotions`).
    @State private var promotions = OpenRouterPromotions.current
    @State private var isLoading = false
    @State private var loadError: String?
    /// The model the pane opened on, once the directory named it: listed
    /// above Suggested for the visit when Suggested does not show it.
    @State private var openedOnID: String?

    private var model: VideoGenerationModel {
        VideoGenerationCatalog.resolvedModel(id: modelID, in: models)
    }

    private var resolution: VideoGenerationCatalog.Resolution {
        VideoGenerationCatalog.resolvedResolution(resolutionID, for: model)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection(
                    title: "Model",
                    description: "Films explainer videos scene by scene. The price is OpenRouter's, and it is asked before a video is made."
                ) {
                    modelLists
                }

                if model.isResolved {
                    SettingsSection(title: "Resolution") {
                        SettingsCard {
                            if model.resolutions.count > 1 {
                                Picker("Resolution", selection: Binding(
                                    get: { resolution.rawValue },
                                    set: { resolutionID = $0 }
                                )) {
                                    ForEach(model.resolutions) { option in
                                        Text(option.displayName).tag(option.rawValue)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                            }

                            Text(priceLines)
                                .zoomedSystemFont(size: 11)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Videos")
        .task { await load() }
        .task { await loadPromotions() }
    }

    @ViewBuilder
    private var modelLists: some View {
        if models.isEmpty {
            SettingsCard {
                MediaDirectoryStatus(
                    subject: "video models",
                    error: loadError,
                    retry: { Task { await load(forceRefresh: true) } }
                )
            }
        } else {
            let makers = MediaModelLists.makers(models, slug: \.id, makerName: \.maker)
            let suggested = MediaModelLists.suggestions(VideoGenerationCatalog.suggestedModelIDs, in: models, slug: \.id, listedAt: \.createdAt)
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
                    subject: "video models",
                    retry: { Task { await load(forceRefresh: true) } },
                    slug: \.id,
                    makerName: \.maker,
                    searchFields: { [$0.name, $0.id] },
                    isFree: \.isFree,
                    isDiscounted: { promotion(for: $0) != nil },
                    row: { option, showsMaker in
                        row(option, makers: makers, showsMaker: showsMaker)
                    }
                )
            }
        }
    }

    private func row(_ option: VideoGenerationModel, makers: [ModelBrowserMaker<VideoGenerationModel>], showsMaker: Bool) -> some View {
        let promotion = self.promotion(for: option)
        var badges: [ModelRowBadge] = []
        if let promotion { badges.append(ModelRowBadge(text: promotion.label, tint: .accent)) }
        if option.makesSound == false { badges.append(ModelRowBadge(text: "Silent")) }
        let rate = rateLabels(for: option, promotion: promotion)
        return MediaModelRow(
            name: option.name,
            slug: option.id,
            maker: MediaModelLists.identity(ofSlug: option.id, in: makers),
            showsMaker: showsMaker,
            detail: rate.detail,
            listPrice: rate.list,
            isSelected: option.id == model.id,
            badges: badges,
            help: helpText(for: option)
        ) {
            modelID = option.id
        }
    }

    /// The promotion OpenRouter runs on the model; none on a free one, which
    /// has no price to cut.
    private func promotion(for model: VideoGenerationModel) -> RouterModelPromotion? {
        guard !model.isFree else { return nil }
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
            models = try await VideoGenerationDirectory.models(forceRefresh: forceRefresh)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        // Settles which model the pane opened on, once: the first time the
        // directory is in hand.
        if openedOnID == nil, !models.isEmpty {
            openedOnID = model.id
        }
    }

    /// "$0.15 a second at 720p": the row's rate at the chosen resolution, or
    /// at the resolution that model would film at. Under a promotion it is
    /// the rate billed, and `list` the directory's rate it cuts ("$0.10"
    /// ahead of "$0.085 a second at 720p").
    private func rateLabels(
        for option: VideoGenerationModel,
        promotion: RouterModelPromotion?
    ) -> (detail: String, list: String?) {
        let at = VideoGenerationCatalog.resolvedResolution(resolution.rawValue, for: option)
        guard let perSecond = option.usdPerSecond(at: at) else {
            return (option.pricedByTokens ? "Priced by video tokens" : "No published price", nil)
        }
        let list = VideoGenerationCatalog.rateLabel(perSecond)
        let billed = promotion.map { VideoGenerationCatalog.rateLabel($0.effectiveRate(fromList: perSecond)) } ?? list
        return ("\(billed) a second at \(at.displayName)", billed == list ? nil : list)
    }

    private func helpText(for option: VideoGenerationModel) -> String {
        var parts: [String] = []
        if !option.detail.isEmpty { parts.append(option.detail) }
        switch option.makesSound {
        case true?: parts.append("Speaks the narration inside each clip.")
        case false?: parts.append("Makes no sound, so its explainer has no narration.")
        case nil: parts.append("OpenRouter does not say whether it makes sound.")
        }
        if option.clipSeconds != VideoGenerationCatalog.clipSeconds {
            parts.append("Makes \(option.clipSeconds)-second clips, so each scene runs \(option.clipSeconds) seconds.")
        }
        parts.append("Films at \(option.resolutions.map(\.displayName).joined(separator: ", ")).")
        return parts.joined(separator: " ")
    }

    /// The published per-second rate, then the three lengths the composer
    /// offers at that rate — the figures the cost question repeats.
    private var priceLines: String {
        guard let perSecond = model.usdPerSecond(at: resolution) else {
            if model.pricedByTokens {
                return "OpenRouter prices \(model.name) by video tokens, so a clip's cost is known only once it is made; the cost question says so before a video starts."
            }
            return "OpenRouter publishes no per-second price for \(model.name) at \(resolution.displayName)."
        }
        let lengths = ExplainerVideoLength.allCases.compactMap { length -> String? in
            guard let cost = GeneratedExplainerVideo.estimatedCostUSD(length: length, model: model, resolution: resolution) else { return nil }
            return "\(length.displayName.lowercased()) \(length.seconds(clipSeconds: model.clipSeconds)) s \(VideoGenerationCatalog.costLabel(cost))"
        }
        // The cost question quotes the directory's rate, so these figures are
        // the ones before a promotion; the charge is what OpenRouter reports.
        let source = promotion(for: model).map { "OpenRouter's price before its \($0.label)" } ?? "OpenRouter's price"
        return "\(VideoGenerationCatalog.rateLabel(perSecond)) a second of video (\(source)). A video: \(lengths.joined(separator: " · "))."
    }
}
#endif
