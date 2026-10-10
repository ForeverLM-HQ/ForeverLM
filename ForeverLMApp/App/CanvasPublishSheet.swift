#if os(macOS)
import AppKit
import SwiftUI

/// The canvas menu's **Publish…** (docs/knowledge-map-design.md, "Versions,
/// export and publishing"): the canvas as a page on sites.foreverlm.com, the
/// canvas drawn as a picture with the list of its cards under it. Private
/// unless the learner says public, as every site is; once it is up, **Publish
/// Changes** renders it over again, **Unpublish** takes the page down, and the
/// canvas stays as it is. Esc or × closes it.
struct CanvasPublishSheet: View {
    @Environment(StudioViewModel.self) private var vm

    let canvasID: String
    let onClose: () -> Void

    @State private var visibility: SitePublishingAccess.Visibility = .privateSite
    @State private var isWorking = false
    @State private var workingLabel = ""
    @State private var errorText: String?

    private var status: PublishedSiteStatus? { vm.publishedCanvasStatus(canvasID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                if let status {
                    publishedBody(status)
                } else {
                    unpublishedBody
                }
                if let errorText {
                    Text(errorText)
                        .zoomedSystemFont(size: 11.5)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task { await vm.refreshPublishedSiteStatuses() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Publish")
                .zoomedSystemFont(size: 14, weight: .semibold)
            Text(vm.canvasDisplayName(canvasID))
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close")
            .accessibilityIdentifier("canvas.publish.close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var unpublishedBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Puts this canvas on the web as a page: the canvas drawn as a picture, and under it the list of its cards, each with a link where it has a public address. The page is a site in your library, named after the canvas; the canvas itself stays as it is.")
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Who can open it", selection: $visibility) {
                Text("Private — you, signed in").tag(SitePublishingAccess.Visibility.privateSite)
                Text("Public — anyone with the link").tag(SitePublishingAccess.Visibility.publicSite)
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("canvas.publish.visibility")
            HStack(spacing: 10) {
                Button {
                    run("Publishing…") { try await vm.publishCanvas(canvasID: canvasID, visibility: visibility) }
                } label: {
                    HStack(spacing: 6) {
                        if isWorking { ProgressView().controlSize(.small) }
                        Text(isWorking ? workingLabel : "Publish")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || !ManagedAI.isSignedIn)
                .accessibilityIdentifier("canvas.publish.publish")
                if !ManagedAI.isSignedIn {
                    Text("Sign in with Apple in Settings › Billing to publish.")
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func publishedBody(_ status: PublishedSiteStatus) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Published")
                    .zoomedSystemFont(size: 12.5, weight: .semibold)
                Text(status.url.absoluteString)
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(status.access?.visibility == .publicSite ? "Anyone with the link can open it." : "Only you can open it, signed in.")
                    .zoomedSystemFont(size: 11.5)
                    .foregroundStyle(.secondary)
                Text("Updated \(PageVersionLabel.when(status.updatedAt))")
                    .zoomedSystemFont(size: 11.5)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    run("Publishing…") { try await vm.publishCanvas(canvasID: canvasID) }
                } label: {
                    HStack(spacing: 6) {
                        if isWorking { ProgressView().controlSize(.small) }
                        Text(isWorking ? workingLabel : "Publish Changes")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
                .help("Draw the canvas again and update the page")
                .accessibilityIdentifier("canvas.publish.changes")
                Button("Open Page") { NSWorkspace.shared.open(status.url) }
                    .disabled(isWorking)
                    .accessibilityIdentifier("canvas.publish.open")
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(status.url.absoluteString, forType: .string)
                    vm.showToast("Link copied")
                }
                .disabled(isWorking)
                .accessibilityIdentifier("canvas.publish.copy")
                Spacer(minLength: 0)
                Button("Unpublish", role: .destructive) {
                    run("Unpublishing…") {
                        try await vm.unpublishCanvas(canvasID: canvasID)
                    }
                }
                .disabled(isWorking)
                .help("Take the page off the web; its link stops working")
                .accessibilityIdentifier("canvas.publish.unpublish")
            }
        }
    }

    private func run<Result>(_ label: String, _ work: @escaping () async throws -> Result) {
        guard !isWorking else { return }
        isWorking = true
        workingLabel = label
        errorText = nil
        Task {
            do {
                _ = try await work()
            } catch {
                errorText = error.localizedDescription
            }
            isWorking = false
        }
    }
}
#endif
