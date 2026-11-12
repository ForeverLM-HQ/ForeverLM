import SwiftUI
import AppKit

// MARK: - Every model pane's browser

/// "All models on OpenRouter" as every AI Models pane draws it (product owner,
/// 2026-09-28: the Chat pane's "setup with suggested models and then all at
/// the bottom" for Voice, Images, Videos and Background too, and "all of them
/// need to have also a search under the all models on OpenRouter section").
///
/// A search field, a row of maker tiles, each with its logo and how many of
/// its models it holds, and under them the picked maker's models. A search
/// narrows the tiles to the makers with a match and lists every match at
/// once, each row naming its maker; a tile picked while searching narrows
/// the matches to that maker. The pane supplies the rows, so a pick means
/// what it means there: offered in the chat's picker, or the model a task
/// runs on.
struct OpenRouterModelBrowser<Model: Identifiable, Row: View, Accessory: View>: View {
    let makers: [ModelBrowserMaker<Model>]
    let state: ModelBrowserState
    /// "image models": what the loading line and the empty line name.
    let subject: String
    let retry: () -> Void
    /// Lists every maker's models at once until a tile is picked, as a
    /// search does: a browser with Free or Discounted on.
    var listsEveryMaker = false
    /// The text a search is matched against, besides the maker's name.
    let searchFields: (Model) -> [String]
    /// Controls at the trailing end of the title line.
    @ViewBuilder let accessory: () -> Accessory
    /// One model's row; the Bool says whether it should name its maker,
    /// which it must when makers are mixed.
    @ViewBuilder let row: (Model, Bool) -> Row

    @State private var selectedMakerID: String?
    @State private var query = ""

    var body: some View {
        let terms = ModelSearch.terms(query)
        let shown = ModelSearch.narrowed(makers, to: terms, fields: searchFields)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("All models on OpenRouter")
                    .font(.subheadline.weight(.semibold))
                if state == .loading {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                accessory()
            }
            switch state {
            case .failed(let message):
                ModelBrowserFailure(message: message, retry: retry)
            case .loading where makers.isEmpty:
                Text("Reading OpenRouter's \(subject)…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            default:
                if makers.isEmpty {
                    Text("OpenRouter lists no \(subject) ForeverLM can use right now.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ModelSearchField(text: $query, prompt: "Search \(subject)")
                    if shown.isEmpty {
                        Text("No model matches “\(query.trimmingCharacters(in: .whitespaces))”.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        FlowLayout(spacing: 6) {
                            ForEach(shown) { maker in
                                makerTile(maker)
                            }
                        }
                        rows(shown, searching: !terms.isEmpty)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rows(_ shown: [ModelBrowserMaker<Model>], searching: Bool) -> some View {
        if let maker = shown.first(where: { $0.id == selectedMakerID }) {
            LazyVStack(spacing: 6) {
                ForEach(maker.models) { model in
                    row(model, false)
                }
            }
            .padding(.top, 4)
        } else if searching || listsEveryMaker {
            LazyVStack(spacing: 6) {
                ForEach(shown.flatMap(\.models)) { model in
                    row(model, true)
                }
            }
            .padding(.top, 4)
        }
    }

    private func makerTile(_ maker: ModelBrowserMaker<Model>) -> some View {
        let isSelected = selectedMakerID == maker.id
        return Button {
            selectedMakerID = isSelected ? nil : maker.id
        } label: {
            HStack(spacing: 6) {
                OpenRouterMakerLogo(bundled: maker.identity.logo, openRouterSlug: maker.identity.vendor, fallbackSymbol: "sparkles")
                    .frame(width: 16, height: 16)
                Text(maker.identity.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Text("\(maker.models.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.fill.quaternary))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0, opacity: 0.10))
        .help(isSelected ? "Hide \(maker.identity.name)'s models" : "Show \(maker.identity.name)'s models")
        .accessibilityLabel("\(maker.identity.name), \(maker.models.count) models")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension OpenRouterModelBrowser where Accessory == EmptyView {
    init(
        makers: [ModelBrowserMaker<Model>],
        state: ModelBrowserState,
        subject: String,
        retry: @escaping () -> Void,
        searchFields: @escaping (Model) -> [String],
        @ViewBuilder row: @escaping (Model, Bool) -> Row
    ) {
        self.init(
            makers: makers,
            state: state,
            subject: subject,
            retry: retry,
            searchFields: searchFields,
            accessory: { EmptyView() },
            row: row
        )
    }
}

// MARK: - Sort by cost

/// What a model costs, for the table that lists by price.
enum ModelCostOrder {
    /// What a model costs per million tokens, blended 3 input to 1 output,
    /// the mix a chat or a reading task runs at. Nil when either price is
    /// unknown.
    static func blended(input: Double?, output: Double?) -> Double? {
        guard let input, let output else { return nil }
        return (3 * input + output) / 4
    }
}

// MARK: - Free and discounted

/// What a browser can be narrowed to: Settings › Chat's, Voice's, Images'
/// and Videos' (the product owner, 2026-09-29: "for chat models we
/// have filters for free and discounted; i also want those for voice, images
/// and video"). Both on list either kind: a free model has no price to cut,
/// so asking for both at once can only mean "free or discounted".
enum ModelBrowserFilter: String, CaseIterable, Identifiable, Hashable {
    case free
    case discounted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "Free"
        case .discounted: return "Discounted"
        }
    }

    var symbol: String {
        switch self {
        case .free: return "gift"
        case .discounted: return "tag"
        }
    }

    /// Free is the price OpenRouter lists today; discounted is a promotion it
    /// runs on the model.
    func matches(isFree: Bool, isDiscounted: Bool) -> Bool {
        switch self {
        case .free: return isFree
        case .discounted: return isDiscounted
        }
    }

    /// "free", "discounted", or "free or discounted".
    static func phrase(_ filters: Set<ModelBrowserFilter>) -> String {
        allCases.filter(filters.contains).map { $0.title.lowercased() }.joined(separator: " or ")
    }

    /// "image models", or "free image models" with Free on: what the
    /// browser's loading, empty and search lines name.
    static func subject(_ noun: String, filters: Set<ModelBrowserFilter>) -> String {
        filters.isEmpty ? noun : "\(phrase(filters)) \(noun)"
    }
}

/// A browser's Free and Discounted chips, at the trailing end of its title
/// line, each with how many models it would list. A chip with nothing to list
/// stays off.
struct ModelBrowserFilterChips: View {
    @Binding var filters: Set<ModelBrowserFilter>
    let counts: [ModelBrowserFilter: Int]

    var body: some View {
        ForEach(ModelBrowserFilter.allCases) { filter in
            chip(filter)
        }
    }

    private func chip(_ filter: ModelBrowserFilter) -> some View {
        let isOn = filters.contains(filter)
        let count = counts[filter] ?? 0
        return Button {
            if isOn {
                filters.remove(filter)
            } else {
                filters.insert(filter)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: filter.symbol)
                    .zoomedSystemFont(size: 10, weight: .semibold)
                Text(filter.title)
                    .font(.caption.weight(.medium))
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(isOn ? Color.accentColor : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isOn ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.fill.quaternary))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isOn ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.hoverWash(in: Capsule(), inset: 0, opacity: 0.10))
        .disabled(count == 0 && !isOn)
        .help(isOn ? "Show every model" : "Show only \(filter.title.lowercased()) models")
        .accessibilityLabel("\(filter.title), \(count) models")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A voice, image or video pane's "All models on OpenRouter": the browser over
/// the pane's models, with Free and Discounted chips as Settings › Chat has.
/// With one on, only the models it lets through are listed, every maker's at
/// once until a tile is picked.
struct MediaModelBrowser<Model: Identifiable, Row: View>: View {
    let models: [Model]
    let state: ModelBrowserState
    /// "image models".
    let subject: String
    let retry: () -> Void
    let slug: (Model) -> String
    let makerName: (Model) -> String
    let searchFields: (Model) -> [String]
    let isFree: (Model) -> Bool
    let isDiscounted: (Model) -> Bool
    @ViewBuilder let row: (Model, Bool) -> Row

    @State private var filters: Set<ModelBrowserFilter> = []

    var body: some View {
        let shown = MediaModelLists.filtered(models, by: filters, isFree: isFree, isDiscounted: isDiscounted)
        OpenRouterModelBrowser(
            makers: MediaModelLists.makers(shown, slug: slug, makerName: makerName),
            state: state,
            subject: ModelBrowserFilter.subject(subject, filters: filters),
            retry: retry,
            listsEveryMaker: !filters.isEmpty,
            searchFields: searchFields,
            accessory: {
                ModelBrowserFilterChips(
                    filters: $filters,
                    counts: MediaModelLists.filterCounts(models, isFree: isFree, isDiscounted: isDiscounted)
                )
            },
            row: row
        )
    }
}

/// Where the directory behind a browser stands.
enum ModelBrowserState: Equatable {
    /// Being read. A browser with rows from an earlier read keeps them.
    case loading
    case loaded
    /// The read failed, and why.
    case failed(String)
}

/// One maker's models in a browser, in the order its tile lists them.
struct ModelBrowserMaker<Model: Identifiable>: Identifiable {
    /// "maker:anthropic" for a maker the chat catalog knows, else the vendor.
    let id: String
    let identity: ChatModelLists.MakerIdentity
    let models: [Model]
}

/// Why a browser's directory could not be read, with a way to try again.
struct ModelBrowserFailure: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry", action: retry)
                .buttonStyle(.hoverWash(tint: Color(nsColor: .linkColor)))
                .font(.caption)
        }
    }
}

/// The search field under a browser's title, drawn as Settings' own.
struct ModelSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .zoomedSystemFont(size: 12, weight: .medium)
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .accessibilityIdentifier("settings.models.browser.search")
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.hoverWash)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
    }
}

// MARK: - Search

/// How a browser's search matches: every word of the query must turn up in
/// the model's name, its slug or its maker's name, ignoring case, accents and
/// punctuation, so "gpt 6", "gpt-6" and "gpt6" all find GPT-6 Astra, and
/// "3.8 flash" finds Gemini 3.8 Flash without finding every Flash.
enum ModelSearch {
    /// The query's words, folded; empty for a blank query.
    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }.filter { !$0.isEmpty }
    }

    static func matches(terms: [String], fields: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let haystack = self.haystack(fields)
        return terms.allSatisfy { haystack.contains($0) }
    }

    /// Each maker cut to the models that match, less the makers left with
    /// none; every maker, whole, for no terms.
    static func narrowed<Model>(
        _ makers: [ModelBrowserMaker<Model>],
        to terms: [String],
        fields: (Model) -> [String]
    ) -> [ModelBrowserMaker<Model>] {
        guard !terms.isEmpty else { return makers }
        return makers.compactMap { maker in
            let hits = maker.models.filter { matches(terms: terms, fields: fields($0) + [maker.identity.name]) }
            return hits.isEmpty ? nil : ModelBrowserMaker(id: maker.id, identity: maker.identity, models: hits)
        }
    }

    /// The fields as written, with their punctuation read as spaces, and run
    /// together: a word matches any of the three.
    private static func haystack(_ fields: [String]) -> String {
        let written = fold(fields.joined(separator: " "))
        let spaced = String(written.map { $0.isLetter || $0.isNumber ? $0 : " " })
        let compact = String(written.filter { $0.isLetter || $0.isNumber })
        return [written, spaced, compact].joined(separator: "\n")
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

// MARK: - Grouping

/// The media panes' lists, worked out as pure functions so a test can pin
/// them: the Suggested rows and the directory by maker.
enum MediaModelLists {
    /// The suggested slugs OpenRouter's directory still lists, in the list's
    /// order, each as the newest release of its family the directory lists
    /// (`AIModelCatalog.newestReleases`). A suggestion the directory dropped
    /// is left out, not guessed at.
    static func suggestions<Model>(
        _ slugs: [String],
        in models: [Model],
        slug: (Model) -> String,
        listedAt: (Model) -> Date?
    ) -> [Model] {
        var bySlug: [String: Model] = [:]
        for model in models {
            let key = slug(model).lowercased()
            if bySlug[key] == nil { bySlug[key] = model }
        }
        let listed = AIModelCatalog.listingDates(models, slug: slug, listedAt: listedAt)
        return AIModelCatalog.newestReleases(of: slugs, listed: listed).compactMap { bySlug[$0.lowercased()] }
    }

    /// The model the pane opened on, when the Suggested rows do not already
    /// show it: listed above them for the whole visit, so a model picked in
    /// the browser does not push the browser down under the pointer.
    static func pinned<Model>(
        openedOn id: String?,
        in models: [Model],
        suggested: [Model],
        slug: (Model) -> String
    ) -> Model? {
        guard let id = id?.lowercased(), !id.isEmpty,
              !suggested.contains(where: { slug($0).lowercased() == id }) else { return nil }
        return models.first { slug($0).lowercased() == id }
    }

    /// The directory by maker, as Settings › Chat groups its own: the chat
    /// catalog's makers first, in its order, then the rest by how many models
    /// they list, then by name. Within a maker the models keep the order
    /// given. A maker is named as the chat names it where the chat knows it,
    /// else as OpenRouter names it most often.
    static func makers<Model: Identifiable>(
        _ models: [Model],
        slug: (Model) -> String,
        makerName: (Model) -> String
    ) -> [ModelBrowserMaker<Model>] {
        var counts: [String: [String: Int]] = [:]
        for model in models {
            let name = makerName(model)
            guard !name.isEmpty else { continue }
            counts[ChatModelLists.vendor(ofSlug: slug(model)), default: [:]][name, default: 0] += 1
        }
        let makerNames = counts.mapValues { names in
            names.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? ""
        }.filter { !$0.value.isEmpty }

        var identities: [String: ChatModelLists.MakerIdentity] = [:]
        var grouped: [String: [Model]] = [:]
        for model in models {
            let identity = ChatModelLists.identity(ofSlug: slug(model), makerNames: makerNames)
            let key = identity.logo.map { "maker:\($0.rawValue)" } ?? identity.vendor
            identities[key] = identities[key] ?? identity
            grouped[key, default: []].append(model)
        }
        let catalogOrder = AIModelMaker.allCases.filter { $0 != .other }
        func rank(_ key: String) -> Int {
            identities[key]?.logo.flatMap { catalogOrder.firstIndex(of: $0) } ?? catalogOrder.count
        }
        let keys = grouped.keys.sorted { lhs, rhs in
            let (l, r) = (rank(lhs), rank(rhs))
            if l != r { return l < r }
            let (lc, rc) = (grouped[lhs]?.count ?? 0, grouped[rhs]?.count ?? 0)
            if lc != rc { return lc > rc }
            return (identities[lhs]?.name ?? lhs).localizedCaseInsensitiveCompare(identities[rhs]?.name ?? rhs) == .orderedAscending
        }
        return keys.compactMap { key in
            guard let identity = identities[key], let models = grouped[key] else { return nil }
            return ModelBrowserMaker(id: key, identity: identity, models: models)
        }
    }

    /// The models a browser's filters let through, in the order given; all
    /// of them with none on.
    static func filtered<Model>(
        _ models: [Model],
        by filters: Set<ModelBrowserFilter>,
        isFree: (Model) -> Bool,
        isDiscounted: (Model) -> Bool
    ) -> [Model] {
        guard !filters.isEmpty else { return models }
        return models.filter { model in
            let (free, discounted) = (isFree(model), isDiscounted(model))
            return filters.contains { $0.matches(isFree: free, isDiscounted: discounted) }
        }
    }

    /// How many of the models each filter would list.
    static func filterCounts<Model>(
        _ models: [Model],
        isFree: (Model) -> Bool,
        isDiscounted: (Model) -> Bool
    ) -> [ModelBrowserFilter: Int] {
        var counts: [ModelBrowserFilter: Int] = [:]
        for filter in ModelBrowserFilter.allCases {
            counts[filter] = filtered(models, by: [filter], isFree: isFree, isDiscounted: isDiscounted).count
        }
        return counts
    }

    /// The maker a slug is drawn under, by the directory's own names.
    static func identity<Model>(
        ofSlug slug: String,
        in makers: [ModelBrowserMaker<Model>]
    ) -> ChatModelLists.MakerIdentity {
        let vendor = ChatModelLists.vendor(ofSlug: slug)
        if let maker = makers.first(where: { $0.identity.vendor == vendor }) {
            return maker.identity
        }
        return ChatModelLists.identity(ofSlug: slug, makerNames: [:])
    }
}

// MARK: - Lists

/// A titled list of model rows in a pane's top card: Suggested, Your model.
struct SettingsModelListSection<Rows: View>: View {
    let title: String
    /// Why the rows cannot be used yet, when they cannot.
    var caption: String? = nil
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                rows
            }
        }
    }
}

/// A short word beside a model's name ("Silent", "Default").
struct ModelRowBadge: Hashable {
    enum Tint: Hashable { case secondary, accent, orange, green }

    let text: String
    var tint: Tint = .secondary

    var color: Color {
        switch tint {
        case .secondary: return .secondary
        case .accent: return .accentColor
        case .orange: return .orange
        case .green: return .green
        }
    }
}

/// One voice, image or video model as a banner across its pane, drawn as
/// Settings › Chat draws a chat model: the maker's logo, the model's name and
/// badges, its price and what else the pane says of it, a link to its
/// OpenRouter page, and a check on the model in use. The whole row picks it.
struct MediaModelRow: View {
    let name: String
    /// OpenRouter's slug, whose page the row links to.
    let slug: String
    let maker: ChatModelLists.MakerIdentity
    /// The maker's logo and name lead the row. A browser listing one maker
    /// leaves them out.
    let showsMaker: Bool
    /// "$0.04 per image": the row's figures, after the maker's name.
    let detail: String
    /// The list figure a promotion cuts ("$0.10"), struck through ahead of
    /// `detail` as Settings › Chat strikes its own, so nobody has to guess
    /// whether "15% off" is still to come.
    var listPrice: String? = nil
    let isSelected: Bool
    var badges: [ModelRowBadge] = []
    var help: String? = nil
    let action: () -> Void

    private var openRouterURL: URL? { OpenRouterModelPage.url(slug: slug) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if showsMaker {
                    ModelRowLogoTile(maker: maker)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        ForEach(badges, id: \.self) { badge in
                            Text(badge.text)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(badge.color)
                        }
                    }
                    subtitle
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Color.clear
                    .frame(width: openRouterURL == nil ? 0 : 20, height: 1)
                Group {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .zoomedSystemFont(size: 14, weight: .regular)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(width: 16)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, showsMaker ? 10 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.10)) : AnyShapeStyle(.fill.quaternary))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.hoverWash(cornerRadius: 12, inset: 0, opacity: 0.10))
        .help(help ?? name)
        .accessibilityLabel(
            "\(name), \(detail)"
                + (listPrice.map { ", down from \($0)" } ?? "")
                + (isSelected ? ", selected" : "")
        )
        // Over the row, not inside its label: a link nested in the row's
        // Button would hand its click to the row. Left of the check: the
        // row's padding, the check's width and the spacing before it.
        .overlay(alignment: .trailing) {
            if let openRouterURL {
                Link(destination: openRouterURL) {
                    Image(systemName: "arrow.up.right.square")
                        .zoomedSystemFont(size: 11, weight: .regular)
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash(cornerRadius: 4, inset: -1))
                .help("Read about \(name) on OpenRouter")
                .accessibilityLabel("\(name) on OpenRouter")
                .padding(.trailing, 14 + 16 + 12)
            }
        }
    }

    /// "Alibaba · ~~$0.10~~ $0.085 a second at 720p".
    private var subtitle: Text {
        var price = Text(detail)
        if let listPrice {
            price = Text(listPrice).strikethrough().foregroundStyle(.tertiary) + Text(verbatim: " ") + price
        }
        return showsMaker ? Text(maker.name) + Text(verbatim: " · ") + price : price
    }
}

/// The maker's logo on a small tile, leading a model's row.
struct ModelRowLogoTile: View {
    let maker: ChatModelLists.MakerIdentity

    var body: some View {
        OpenRouterMakerLogo(bundled: maker.logo, openRouterSlug: maker.vendor, fallbackSymbol: "sparkles")
            .frame(width: 18, height: 18)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}
