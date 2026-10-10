import SwiftUI

/// Teammates' open requests for sources this Mac holds, on the Docs home: who
/// asked for what, in which team, with Share and Decline for each and Share
/// All for the lot. A request is made from a card on a team Doc that could not
/// add its source (docs/teams-design.md, decision 14); it reaches every member
/// through the team zone, and this banner shows only the ones My Library can
/// answer, so it is empty for a member who does not hold the paper.
struct ShareRequestsBanner: View {
    @Environment(StudioViewModel.self) private var vm
    @State private var isReviewing = false

    private var items: [StorageService.FulfillableShareRequest] { vm.fulfillableShareRequests }

    var body: some View {
        if !items.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.up")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .zoomedSystemFont(size: 13, weight: .semibold)
                    Text(detail)
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("Review…") { isReviewing = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .popover(isPresented: $isReviewing, arrowEdge: .bottom) {
                        ShareRequestsReviewList(items: items) { isReviewing = false }
                            .frame(width: 420)
                    }
                Button(items.count == 1 ? "Share" : "Share All") {
                    // Answering copies sources into the team: the first time,
                    // the learner affirms they may share them.
                    SharingRightsPrompt.shared.askIfNeeded {
                        Task { await vm.fulfilAllShareRequests() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Copy every requested source you hold into the team that asked, files included")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("docs.shareRequestsBanner")
        }
    }

    private var headline: String {
        let requesters = Set(items.compactMap { $0.request.requestedByDisplayName }).sorted()
        let who: String
        switch requesters.count {
        case 0: who = "A teammate"
        case 1: who = requesters[0]
        case 2: who = "\(requesters[0]) and \(requesters[1])"
        default: who = "\(requesters[0]) and \(requesters.count - 1) others"
        }
        let what = items.count == 1 ? "a source you hold" : "\(items.count) sources you hold"
        return "\(who) asked for \(what)"
    }

    private var detail: String {
        let teams = Set(items.map(\.request.teamID)).compactMap { vm.team(id: $0)?.name }.sorted()
        let titles = items.prefix(3).map { $0.request.title ?? Self.host(of: $0.request.url) }
        let more = items.count > 3 ? " and \(items.count - 3) more" : ""
        return "\(titles.joined(separator: ", "))\(more) · \(teams.joined(separator: ", "))"
    }

    static func host(of url: String) -> String {
        URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url
    }
}

/// One row per request: what, who, which team; Share copies this Mac's row
/// into the team, Decline closes the request for everyone.
struct ShareRequestsReviewList: View {
    @Environment(StudioViewModel.self) private var vm
    let items: [StorageService.FulfillableShareRequest]
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Requested sources")
                .zoomedSystemFont(size: 13, weight: .semibold)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items, id: \.request.id) { item in
                        row(item)
                        if item.request.id != items.last?.request.id { Divider().padding(.leading, 14) }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .onChange(of: items.isEmpty) { _, empty in if empty { dismiss() } }
    }

    private func row(_ item: StorageService.FulfillableShareRequest) -> some View {
        let request = item.request
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title ?? ShareRequestsBanner.host(of: request.url))
                    .zoomedSystemFont(size: 13)
                    .lineLimit(2)
                Text("\(request.requestedByDisplayName ?? "A teammate") · \(vm.team(id: request.teamID)?.name ?? "Team") · \(request.createdAt.formatted(.relative(presentation: .named)))")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button("Decline") { Task { await vm.declineShareRequest(request.id) } }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("Share") {
                // Before you share asks in the window's sheet, which this
                // popover makes way for.
                if SharingRightsRow.needsAsking { dismiss() }
                SharingRightsPrompt.shared.askIfNeeded {
                    Task { await vm.fulfilShareRequest(request.id) }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
