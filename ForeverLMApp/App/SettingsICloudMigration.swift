import SwiftUI

/// Data & Privacy › iCloud, below the sync card (docs/cloudkit-schema-design.md §13): where the library's
/// upload to the library container stands, "This Mac holds my library", "Upload my library to iCloud
/// again", and the bytes each owned space holds. The upload's progress while it runs
/// is `LibraryMoveSettingsCard` above. The old iCloud library has no
/// card: it stayed with the old Apple team, and no build can read or remove it.
struct ICloudMigrationSettingsView: View {
    @State private var model = ICloudMigrationModel.shared
    @State private var confirmingLibrary = false

    var body: some View {
        Group {
            if let state = model.state, state.isShown {
                content(state)
            }
        }
        .task {
            // Read when the pane opens and every half minute while it stays open.
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    @ViewBuilder
    private func content(_ state: ICloudMigrationState) -> some View {
        let busy = model.work != nil && model.work != .refreshing
        if hasMoveCard(state) {
            SettingsCard {
                if let line = state.moveLine {
                    row(icon: "arrow.triangle.2.circlepath", tint: .blue, line: line)
                }
                if case .offer(let offer) = state.holds {
                    if state.moveLine != nil { Divider().padding(.vertical, 10) }
                    holdsMyLibraryRow(offer, busy: busy)
                }
                if state.snapshot.stop != nil {
                    if state.moveLine != nil || state.holds.offersTheButton { Divider().padding(.vertical, 10) }
                    uploadAgainRow(busy: busy)
                }
            }
            .accessibilityIdentifier("settings.libraryMove.state")
        }

        if let notice = model.notice {
            Text(notice)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }

        detailsCard(state)
    }

    private func hasMoveCard(_ state: ICloudMigrationState) -> Bool {
        state.moveLine != nil || state.holds.offersTheButton || state.snapshot.stop != nil
    }

    // MARK: - Rows

    private func row(icon: String, tint: Color, line: ICloudMigrationLine) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title).font(.headline)
                if let detail = line.detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
        }
    }

    private func holdsMyLibraryRow(_ offer: HoldsMyLibrary.Offer, busy: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.icloud")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 28)
            Text("This Mac's library is not in the new iCloud store yet")
                .font(.headline)
            Spacer(minLength: 16)
            Button("This Mac holds my library") { confirmingLibrary = true }
                .buttonStyle(.bordered)
                .disabled(busy)
        }
        .confirmationDialog("Upload this Mac's library to iCloud?", isPresented: $confirmingLibrary, titleVisibility: .visible) {
            Button("This Mac holds my library") {
                Task { await model.confirmHoldsMyLibrary() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(HoldsMyLibrary.confirmationText(offer))
        }
        .accessibilityIdentifier("settings.holdsMyLibrary")
    }

    private func uploadAgainRow(busy: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 28)
            Text("This library is not in iCloud any more")
                .font(.headline)
            Spacer(minLength: 16)
            Button("Upload my library to iCloud again") {
                Task { await model.uploadAgain() }
            }
            .buttonStyle(.bordered)
            .disabled(busy)
        }
        .accessibilityIdentifier("settings.uploadAgain")
    }

    // MARK: - Details

    @ViewBuilder
    private func detailsCard(_ state: ICloudMigrationState) -> some View {
        SettingsCard {
            DisclosureGroup("Move details") {
                VStack(alignment: .leading, spacing: 6) {
                    if let mode = state.modeLine { Text(mode) }
                    if state.snapshot.libraryBytes > 0 || !state.snapshot.ownedSpaces.isEmpty {
                        Divider().padding(.vertical, 4)
                        Text("Your library: \(Self.format(state.snapshot.libraryBytes))")
                        ForEach(state.snapshot.ownedSpaces) { space in
                            Text("\(space.name): \(Self.format(space.bytes))")
                        }
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
        }
        .accessibilityIdentifier("settings.moveDetails")
    }

    private static func format(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}
