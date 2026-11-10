// Settings views for the Google Drive, Apple Calendar, calendar-group and YouTube connections.
import SwiftUI
import AppKit
import AuthenticationServices
import Combine
import UniformTypeIdentifiers
import EventKit

struct GoogleDriveConnectionSettingsView: View {
    @Environment(StudioViewModel.self) private var vm
    // Placeholders; `.onAppear` fills them in off-main (synced Keychain keys
    // are securityd IPC on every read, and `@State` inits re-run per re-init).
    @State private var isSignedIn = false
    @State private var hasFolderReadAccess = false
    @State private var connectedAccounts: [GoogleDriveAccount] = []
    /// The account an untagged folder is read through, from the Keychain.
    @State private var defaultAccountID: String?
    @State private var isWorking = false
    @State private var statusMessage: String?
    @SyncedStorage(StudioViewModel.meetingOwnTranscriptionEnabledKey)
    private var ownTranscriptionEnabled = false

    /// The meeting folders each connected account reads, by account id.
    private var foldersByAccount: GoogleDriveFolderAttribution {
        GoogleDriveFolderAttribution(
            metadata: vm.meetingMetadata,
            accountIDs: connectedAccounts.map(\.id),
            defaultAccountID: defaultAccountID
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if connectedAccounts.isEmpty {
                SettingsCard {
                    HStack(spacing: 12) {
                        driveGlyph
                        Text("No Google account connected")
                            .font(.headline)
                        Spacer(minLength: 12)
                    }
                }
            }

            // One card per Google account, the way Slack draws a workspace: any
            // number of accounts, and under each any number of folders.
            let attribution = foldersByAccount
            ForEach(connectedAccounts) { account in
                accountCard(account, folders: attribution.folders(for: account.id))
            }
            let strays = attribution.unattributed
            if !strays.isEmpty {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Account no longer connected")
                            .font(.callout.weight(.medium))
                        folderList(strays)
                    }
                }
            }

            addRow

            if isSignedIn {
                SettingsCard {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Transcribe recordings Google didn't")
                            Text("Each recording is a paid speech-to-text run.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Toggle("", isOn: $ownTranscriptionEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                .settingsFocusRow(.driveTranscribeRecordings)
            }

            notice
        }
        .onAppear {
            Task {
                await refreshConnectionState()
            }
        }
    }

    private var driveGlyph: some View {
        Image("GoogleDriveIcon")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: 20, height: 17)
            .frame(width: 34, height: 34)
            .background(Circle().fill(Color.primary.opacity(0.055)))
    }

    /// Connecting never replaces what is there: it adds another account, and
    /// each account takes more folders from its own card.
    @ViewBuilder
    private var addRow: some View {
        HStack(spacing: 10) {
            if isWorking {
                // The browser sends nothing back when its tab is closed,
                // so a bare spinner held this page for ten minutes.
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for Google…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Cancel") {
                    Task { await GoogleDriveService.shared.cancelPendingConnection() }
                }
                .buttonStyle(.hoverWash)
            } else {
                Button {
                    connectAndChooseFolder()
                } label: {
                    Label(
                        isSignedIn && !hasFolderReadAccess
                            ? "Reconnect Google Drive"
                            : (isSignedIn ? "Add Another Account" : "Connect Google Drive"),
                        systemImage: "plus"
                    )
                    .font(.callout.weight(.medium))
                }
                .buttonStyle(.hoverWash)
                .disabled(!GoogleDriveService.shared.canConnect)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var notice: some View {
        if !GoogleDriveService.shared.canConnect {
            Text("This build of ForeverLM has no Google Drive OAuth client configured.")
                .font(.caption)
                .foregroundStyle(.red)
        } else if isSignedIn && !hasFolderReadAccess {
            Text("Reconnect to let ForeverLM read the files inside meeting folders.")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let statusMessage {
            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// One connected Google account: who it is, the meeting folders ForeverLM
    /// reads through it, a way to add another, and its Disconnect.
    @ViewBuilder
    private func accountCard(_ account: GoogleDriveAccount, folders: [GoogleDriveFolderAttribution.Folder]) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    Text(String(account.displayLabel.prefix(1)).uppercased())
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textSelection(.disabled)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.primary.opacity(0.055)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayLabel)
                            .font(.headline)
                            .lineLimit(1)
                        Text(accountSummary(account, folders: folders))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    if !hasFolderReadAccess {
                        Label("Reconnect", systemImage: "exclamationmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                    Button("Disconnect", role: .destructive) {
                        disconnect(accountID: account.id)
                    }
                    .buttonStyle(.hoverWash)
                    .foregroundStyle(.secondary)
                    .disabled(isWorking)
                }
                if !folders.isEmpty {
                    folderList(folders)
                }
                Button {
                    addFolder(to: account)
                } label: {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                        .font(.callout)
                }
                .buttonStyle(.hoverWash)
                .disabled(isWorking)
            }
        }
    }

    /// "Zara Holt · 1 folder." The name is left out when the label
    /// already is the name (an account Google gave no email for).
    private func accountSummary(_ account: GoogleDriveAccount, folders: [GoogleDriveFolderAttribution.Folder]) -> String {
        var parts: [String] = []
        let name = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != account.displayLabel { parts.append(name) }
        switch folders.count {
        case 0: parts.append("No meeting folder yet")
        case 1: parts.append("1 folder")
        default: parts.append("\(folders.count) folders")
        }
        return parts.joined(separator: " · ")
    }

    private func folderList(_ folders: [GoogleDriveFolderAttribution.Folder]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
                if index > 0 { Divider().padding(.leading, 38) }
                GoogleDriveFolderRow(folder: folder)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    /// Another meeting folder through an account that is already connected:
    /// no second sign-in, only the folder chooser.
    private func addFolder(to account: GoogleDriveAccount) {
        guard !isWorking else { return }
        isWorking = true
        statusMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                guard let folder = await GoogleDriveFolderPicker.choose(account: account) else { return }
                vm.pinIntegrationTabsInUse()
                try await vm.importMeetingFolderFromAuthenticatedDrive(
                    folder.webURL,
                    groupTitle: folder.name,
                    silent: false
                )
                await refreshConnectionState()
            } catch is CancellationError {
                return
            } catch {
                await refreshConnectionState()
                statusMessage = error.localizedDescription
            }
        }
    }

    private func connectAndChooseFolder() {
        guard !isWorking else { return }
        isWorking = true
        statusMessage = nil
        Task { @MainActor in
            defer {
                isWorking = false
            }
            do {
                try await vm.connectAndImportGoogleDriveMeetings(
                    reconnectOnly: isSignedIn && !hasFolderReadAccess
                )
                await refreshConnectionState()
                statusMessage = "Google Drive is connected."
            } catch is CancellationError {
                return
            } catch GoogleDriveServiceError.noFolderSelected {
                await refreshConnectionState()
                statusMessage = "Google Drive is connected. Choose a meeting folder to start importing."
            } catch {
                await refreshConnectionState()
                statusMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func refreshConnectionState() async {
        let status = await Task.detached(priority: .userInitiated) {
            (
                signedIn: GoogleDriveService.shared.isSignedIn,
                folder: GoogleDriveService.shared.hasFolderReadAccess,
                accounts: GoogleDriveService.shared.connectedAccounts,
                defaultAccountID: KeychainService.googleDriveDefaultAccountID
            )
        }.value
        isSignedIn = status.signedIn
        hasFolderReadAccess = status.folder
        defaultAccountID = status.defaultAccountID
        connectedAccounts = status.accounts.sorted {
            $0.displayLabel.localizedCaseInsensitiveCompare($1.displayLabel) == .orderedAscending
        }
    }

    private func disconnect(accountID: String) {
        guard !isWorking else { return }
        isWorking = true
        statusMessage = nil
        connectedAccounts.removeAll { $0.id == accountID }
        Task { @MainActor in
            await GoogleDriveService.shared.signOut(accountID: accountID)
            await refreshConnectionState()
            isWorking = false
        }
    }

}

/// Plugins › Calendar: turn the Mac's Calendar app on, choose which
/// of its calendars are the day, and which one new events go to. The system
/// asks for access the first time; the choices are this Mac's, like the grant.
/// An Exchange account is signed in by macOS, so Add Exchange Account… opens
/// Internet Accounts and the list follows Calendar when the learner returns.
/// The day itself is read by `DayModel` and written by the assistant's
/// calendar tools.
struct AppleCalendarConnectionSettingsView: View {
    @State private var isConnected = false
    @State private var isBlockedBySystem = false
    @State private var isConnecting = false
    @State private var statusMessage: String?
    @State private var calendars: [AppleCalendarListEntry] = []
    @State private var isLoadingCalendars = false
    /// The learner's selection, nil while every calendar but Birthdays is
    /// shown. Mirrors `AppleCalendarService.selectedIDs`.
    @State private var selectedIDs: Set<String>?
    /// Mirrors `AppleCalendarService.knownAccountIDs`: calendars of any other
    /// account are ticked until the learner unticks them.
    @State private var knownAccountIDs: [String]?
    /// The calendar new events go to: the learner's choice, or nil for the
    /// Calendar app's own default (`newEventsDefault`).
    @State private var newEventsCalendarID: String?
    /// The calendar the Calendar app itself puts new events on.
    @State private var newEventsDefault: AppleCalendarListEntry?

    var body: some View {
        PluginSettingsCard(
            title: "Calendar",
            subtitle: "The Mac's calendars you choose — from iCloud, Google, Exchange or any account Calendar holds — are your day: the bottom-left chip shows them, and a chat plans the day by adding events to the calendar you pick below.",
            icon: {
                Image("AppleCalendarIcon")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: 18, height: 18)
            },
            status: isConnected ? .connected : (isBlockedBySystem ? .needsAttention : .notConnected)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Access is granted to this Mac by macOS and never leaves it. ForeverLM writes only the events you or the assistant add, and never changes a meeting with other people on it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if isBlockedBySystem {
                        Button("Open Privacy & Security…") {
                            AppleCalendarService.openPrivacySettings()
                        }
                        .accessibilityIdentifier("settings.appleCalendar.privacy")
                    }
                    Button("Add Exchange Account…") {
                        AppleCalendarService.openInternetAccountsSettings()
                    }
                    .help("Opens System Settings › Internet Accounts. Choose Add Account… › Microsoft Exchange and sign in; its calendars appear here and in your day.")
                    .accessibilityIdentifier("settings.appleCalendar.addAccount")
                    Spacer()
                    if isConnected {
                        Button("Turn Off", role: .destructive) {
                            isConnected = false
                            calendars = []
                            selectedIDs = nil
                            knownAccountIDs = nil
                            statusMessage = nil
                            Task.detached(priority: .userInitiated) {
                                AppleCalendarService.shared.disconnect()
                            }
                        }
                        .accessibilityIdentifier("settings.appleCalendar.disconnect")
                    } else {
                        Button {
                            connect()
                        } label: {
                            if isConnecting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Turn On", systemImage: "calendar.badge.checkmark")
                            }
                        }
                        .disabled(isConnecting)
                        .accessibilityIdentifier("settings.appleCalendar.connect")
                    }
                }

                if isConnected {
                    Divider()
                    if isLoadingCalendars && calendars.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                    } else if calendars.isEmpty {
                        Text("The Calendar app holds no calendars on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        newEventsPicker
                        Divider()
                        CalendarGroupsSettingsSection(calendars: calendars, reloadCalendars: loadCalendars)
                        Divider()
                        Text("Calendars in your day")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(calendars) { calendar in
                            let takesNewEvents = calendar.id == newEventsTargetID
                            Toggle(isOn: Binding(
                                get: { isImported(calendar) },
                                set: { setImported($0, calendar) }
                            )) {
                                HStack(spacing: 6) {
                                    Text(calendar.title)
                                        .lineLimit(1)
                                    if !calendar.account.isEmpty {
                                        Text(calendar.account)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    if takesNewEvents {
                                        Text("· new events")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                            // What a chat plans lands here, so it is always
                            // in the day (`AppleCalendarService.shown`).
                            .disabled(takesNewEvents || holdsGroup(calendar))
                            .help(takesNewEvents ? "New events go to this calendar, so it is always in your day." : (holdsGroup(calendar) ? "A group's blocks go to this calendar, so it is always in your day." : ""))
                            .accessibilityIdentifier("settings.appleCalendar.calendar.\(calendar.id)")
                        }
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(isBlockedBySystem ? .red : .secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .pluginConnectionChanged)) { _ in
            refresh()
        }
        // Back from System Settings: a grant given or an account signed in.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        // An account's calendars arrive in Calendar while it syncs.
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            if isConnected { loadCalendars() }
        }
    }

    private func refresh() {
        Task {
            let state = await Task.detached(priority: .userInitiated) {
                (
                    connected: AppleCalendarService.shared.isConnected,
                    blocked: AppleCalendarService.shared.isBlockedBySystem,
                    selected: AppleCalendarService.shared.selectedIDs,
                    known: AppleCalendarService.shared.knownAccountIDs,
                    newEvents: AppleCalendarService.shared.newEventsCalendarID
                )
            }.value
            isConnected = state.connected
            isBlockedBySystem = state.blocked
            selectedIDs = state.selected.map(Set.init)
            knownAccountIDs = state.known
            newEventsCalendarID = state.newEvents
            if state.connected { loadCalendars() }
        }
    }

    /// Where the assistant's new events land: the Calendar app's own default,
    /// or one of the calendars that take events.
    @ViewBuilder
    private var newEventsPicker: some View {
        let writable = calendars.filter(\.allowsModifications)
        HStack(spacing: 8) {
            Text("New events go to")
                .font(.callout.weight(.medium))
            Spacer(minLength: 8)
            Picker("New events go to", selection: Binding(
                get: { newEventsCalendarID ?? "" },
                set: { setNewEventsCalendar($0.isEmpty ? nil : $0) }
            )) {
                Text(newEventsDefault.map { "Calendar's default (\($0.title))" } ?? "Calendar's default").tag("")
                ForEach(writable) { calendar in
                    Text(calendar.account.isEmpty ? calendar.title : "\(calendar.title) · \(calendar.account)").tag(calendar.id)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("settings.appleCalendar.newEvents")
        }
    }

    private func setNewEventsCalendar(_ id: String?) {
        newEventsCalendarID = id
        Task.detached(priority: .userInitiated) {
            AppleCalendarService.shared.setNewEventsCalendarID(id)
        }
    }

    /// The calendar new events land on, the way `AppleCalendarService`
    /// resolves it: the learner's choice while it still takes events, else
    /// the Calendar app's own default.
    private var newEventsTargetID: String? {
        if let newEventsCalendarID,
           calendars.contains(where: { $0.id == newEventsCalendarID && $0.allowsModifications }) {
            return newEventsCalendarID
        }
        return newEventsDefault?.id
    }

    /// Whether `calendar` is in the day: chosen by the learner, from an
    /// account signed in since, or, before any choice, anything but Birthdays;
    /// and the calendar new events go to, always.
    private func isImported(_ calendar: AppleCalendarListEntry) -> Bool {
        !AppleCalendarService.shown(
            from: [calendar],
            selectedIDs: selectedIDs.map(Array.init),
            knownAccountIDs: knownAccountIDs,
            newEventsCalendarID: newEventsTargetID,
            groupCalendarIDs: Set(AppleCalendarService.shared.groups.map(\.calendarID))
        ).isEmpty
    }

    private func holdsGroup(_ calendar: AppleCalendarListEntry) -> Bool {
        AppleCalendarService.shared.groups.contains { $0.calendarID == calendar.id }
    }

    /// The first flip turns what is shown into the learner's own list, and
    /// every account listed now into one the choice covers. The calendar new
    /// events go to joins the list only if the learner's choice already took
    /// it in, so picking another one later does not leave it ticked.
    private func setImported(_ imported: Bool, _ calendar: AppleCalendarListEntry) {
        let selection = selectedIDs.map(Array.init)
        var chosen = Set(calendars.filter {
            AppleCalendarService.isChosen($0, selectedIDs: selection, knownAccountIDs: knownAccountIDs)
        }.map(\.id))
        if imported { chosen.insert(calendar.id) } else { chosen.remove(calendar.id) }
        selectedIDs = chosen
        knownAccountIDs = AppleCalendarService.accountIDs(of: calendars)
        let listed = calendars
        let ids = listed.map(\.id).filter { chosen.contains($0) }
        Task.detached(priority: .userInitiated) {
            // Posts the change the chip and the day model read again on.
            AppleCalendarService.shared.setSelectedIDs(ids, among: listed)
        }
    }

    private func loadCalendars() {
        guard !isLoadingCalendars else { return }
        isLoadingCalendars = true
        Task {
            defer { isLoadingCalendars = false }
            do {
                calendars = try await AppleCalendarService.shared.calendars()
                // Reading them records the accounts an older choice covers.
                knownAccountIDs = AppleCalendarService.shared.knownAccountIDs
                newEventsDefault = try await AppleCalendarService.shared.calendarAppNewEventsCalendar()
                statusMessage = nil
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func connect() {
        guard !isConnecting else { return }
        isConnecting = true
        statusMessage = nil
        Task {
            do {
                try await AppleCalendarService.shared.connect()
                isConnected = AppleCalendarService.shared.isConnected
                isBlockedBySystem = false
                loadCalendars()
            } catch {
                isBlockedBySystem = AppleCalendarService.shared.isBlockedBySystem
                statusMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }
}

/// Plugins › Calendar › Groups: each context of the learner's work on a
/// calendar of its own, so it has one colour everywhere the calendar shows
/// (`CalendarGroup`). A group's calendar is one an account already brings in
/// (the day job's Exchange calendar) or one made for it here, in iCloud.
private struct CalendarGroupsSettingsSection: View {
    let calendars: [AppleCalendarListEntry]
    let reloadCalendars: () -> Void

    @State private var groups: [CalendarGroup] = AppleCalendarService.shared.groups
    @State private var message: String?
    @State private var isWorking = false
    /// What Move Blocks Into Groups would move, while the learner confirms.
    @State private var pendingMoves: [CalendarRegroupMove] = []
    @State private var confirmingMoves = false

    /// The swatches a group's calendar can wear: distinct at a glance in
    /// the Calendar app's light and dark week views.
    private static let swatches: [(name: String, color: CalendarColor)] = [
        ("Red", CalendarColor(red: 0.90, green: 0.22, blue: 0.27)),
        ("Orange", CalendarColor(red: 1.00, green: 0.55, blue: 0.16)),
        ("Yellow", CalendarColor(red: 0.96, green: 0.77, blue: 0.00)),
        ("Green", CalendarColor(red: 0.20, green: 0.66, blue: 0.33)),
        ("Teal", CalendarColor(red: 0.10, green: 0.65, blue: 0.70)),
        ("Blue", CalendarColor(red: 0.12, green: 0.48, blue: 0.95)),
        ("Purple", CalendarColor(red: 0.64, green: 0.35, blue: 0.85)),
        ("Pink", CalendarColor(red: 0.95, green: 0.35, blue: 0.62)),
        ("Brown", CalendarColor(red: 0.62, green: 0.45, blue: 0.30)),
        ("Graphite", CalendarColor(red: 0.50, green: 0.52, blue: 0.56)),
    ]

    private static let newCalendarTag = "foreverlm.newCalendar"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Groups")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Add Group") { addGroup() }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings.appleCalendar.groups.add")
            }
            Text("Each part of your work on a calendar of its own, so it keeps one colour in Calendar, on your phone and in Plan. A block whose title or notes name a group goes onto its calendar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach($groups) { $group in
                row($group)
            }
            if !groups.isEmpty {
                HStack(spacing: 8) {
                    Button("Move Blocks Into Groups…") { previewMoves() }
                        .controlSize(.small)
                        .disabled(isWorking)
                        .help("Moves the blocks of the coming weeks that name a group onto its calendar. Meetings and repeating events stay where they are.")
                        .accessibilityIdentifier("settings.appleCalendar.groups.regroup")
                    if isWorking { ProgressView().controlSize(.small) }
                }
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pluginConnectionChanged)) { _ in
            let stored = AppleCalendarService.shared.groups
            if stored != groups { groups = stored }
        }
        .confirmationDialog(
            pendingMoves.count == 1 ? "Move 1 block into its group?" : "Move \(pendingMoves.count) blocks into their groups?",
            isPresented: $confirmingMoves
        ) {
            Button("Move") { applyMoves() }
            Button("Cancel", role: .cancel) { pendingMoves = [] }
        } message: {
            Text(Self.movesSummary(pendingMoves))
        }
    }

    private func row(_ group: Binding<CalendarGroup>) -> some View {
        let calendar = calendars.first { $0.id == group.wrappedValue.calendarID }
        let writable = calendars.filter(\.allowsModifications)
        return HStack(spacing: 8) {
            Menu {
                ForEach(Self.swatches, id: \.name) { swatch in
                    Button {
                        recolor(group.wrappedValue, swatch.color)
                    } label: {
                        Label {
                            Text(swatch.name)
                        } icon: {
                            Image(nsImage: Self.swatchImage(swatch.color))
                        }
                    }
                }
            } label: {
                Circle()
                    .fill(calendar?.color.map { Color(cgColor: $0.cgColor) } ?? Color.secondary.opacity(0.3))
                    .frame(width: 12, height: 12)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(calendar == nil || calendar?.allowsModifications == false)
            .help(calendar == nil ? "Choose a calendar first" : "Colour of “\(calendar?.title ?? "")”")
            TextField("Name", text: group.name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .onSubmit { save() }
            Picker("Calendar", selection: Binding(
                get: { group.wrappedValue.calendarID },
                set: { choose($0, for: group.wrappedValue) }
            )) {
                if calendar == nil { Text("Choose…").tag(group.wrappedValue.calendarID) }
                ForEach(writable) { entry in
                    Text(entry.account.isEmpty ? entry.title : "\(entry.title) · \(entry.account)").tag(entry.id)
                }
                Divider()
                Text("New Calendar “\(group.wrappedValue.name)”").tag(Self.newCalendarTag)
            }
            .labelsHidden()
            .frame(maxWidth: 200)
            TextField("Also named by…", text: Binding(
                get: { group.wrappedValue.keywords.joined(separator: ", ") },
                set: { group.wrappedValue.keywords = CalendarGroups.keywords(from: $0) }
            ))
            .textFieldStyle(.roundedBorder)
            .onSubmit { save() }
            .help("More words that name this group in a block's title or notes, separated by commas: Grant draft, Widget review")
            Button {
                groups.removeAll { $0.id == group.wrappedValue.id }
                save()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove the group. Its calendar and events stay.")
        }
        .onChange(of: group.wrappedValue.name) { _, _ in saveSoon() }
        .onChange(of: group.wrappedValue.keywords) { _, _ in saveSoon() }
        .accessibilityIdentifier("settings.appleCalendar.group.\(group.wrappedValue.id)")
    }

    // MARK: Changes

    private func addGroup() {
        groups.append(CalendarGroup(name: "New Group", calendarID: ""))
        save()
    }

    @State private var pendingSave: Task<Void, Never>?

    /// Typing saves after a pause, so each keystroke is not a write.
    private func saveSoon() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        pendingSave?.cancel()
        let snapshot = groups
        Task.detached(priority: .userInitiated) {
            AppleCalendarService.shared.setGroups(snapshot)
        }
    }

    private func choose(_ calendarID: String, for group: CalendarGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        guard calendarID == Self.newCalendarTag else {
            groups[index].calendarID = calendarID
            save()
            return
        }
        let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            message = "Name the group first; its new calendar takes the name."
            return
        }
        let taken = Set(groups.compactMap { group in calendars.first { $0.id == group.calendarID }?.color?.hex })
        let color = Self.swatches.map(\.color).first { !taken.contains($0.hex) }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let made = try await AppleCalendarService.shared.createCalendar(title: name, color: color)
                if let index = groups.firstIndex(where: { $0.id == group.id }) {
                    groups[index].calendarID = made.id
                    save()
                }
                message = "Made “\(made.title)” in \(made.account.isEmpty ? "this Mac" : made.account)."
                reloadCalendars()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func recolor(_ group: CalendarGroup, _ color: CalendarColor) {
        Task {
            do {
                try await AppleCalendarService.shared.setColor(color, ofCalendar: group.calendarID)
                reloadCalendars()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func previewMoves() {
        save()
        isWorking = true
        message = nil
        let span = CalendarGroups.regroupSpan()
        Task {
            defer { isWorking = false }
            do {
                // Saved first, so the service reads these groups.
                try? await Task.sleep(for: .milliseconds(100))
                let moves = try await AppleCalendarService.shared.regroupEvents(from: span.start, to: span.end, apply: false)
                if moves.isEmpty {
                    message = "Every block of the coming weeks is already on its group's calendar."
                } else {
                    pendingMoves = moves
                    confirmingMoves = true
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func applyMoves() {
        let span = CalendarGroups.regroupSpan()
        isWorking = true
        Task {
            defer { isWorking = false; pendingMoves = [] }
            do {
                let moved = try await AppleCalendarService.shared.regroupEvents(from: span.start, to: span.end, apply: true)
                message = moved.count == 1 ? "Moved 1 block into its group." : "Moved \(moved.count) blocks into their groups."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    // MARK: Words and pictures

    /// "Day job: 4 blocks · Society: 7 blocks", then the first few blocks.
    static func movesSummary(_ moves: [CalendarRegroupMove]) -> String {
        var counts: [(String, Int)] = []
        for move in moves {
            if let index = counts.firstIndex(where: { $0.0 == move.group }) { counts[index].1 += 1 } else { counts.append((move.group, 1)) }
        }
        let byGroup = counts.map { "\($0.0): \($0.1) \($0.1 == 1 ? "block" : "blocks")" }.joined(separator: " · ")
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMdjmm")
        let first = moves.prefix(6).map { "\(formatter.string(from: $0.start))  \($0.title) → \($0.group)" }
        let more = moves.count > 6 ? ["and \(moves.count - 6) more"] : []
        return ([byGroup, ""] + first + more).joined(separator: "\n")
    }

    /// A menu item's swatch: menus draw an image, not a SwiftUI shape.
    static func swatchImage(_ color: CalendarColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(cgColor: color.cgColor)?.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct YouTubeConnectionSettingsView: View {
    @Environment(StudioViewModel.self) private var vm
    @State private var isConnecting = false
    @State private var statusMessage: String?
    // Placeholders; `.onAppear` fills them in off-main (a synced Keychain read).
    @State private var autoImportEnabled = false
    /// What the stores currently say, so the `.onChange` below can tell the
    /// user flipping the toggle apart from the off-main refresh seeding it.
    @State private var persistedAutoImportEnabled = false
    @State private var setupDialog: YouTubeSetupDialog?
    @State private var configuringAccountID: String?
    @State private var pendingLikedImportPolicy: YouTubeLikedImportPolicy?
    @State private var channelInput = ""
    @State private var isFollowingChannel = false
    @SyncedStorage(StudioViewModel.youtubeLikedTranscriptFormattingKey)
    private var automaticallyFormatLikedVideoTranscripts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if vm.youtubeAccounts.isEmpty {
                SettingsCard {
                    HStack(spacing: 12) {
                        youtubeGlyph
                        Text("No YouTube account connected")
                            .font(.headline)
                        Spacer(minLength: 12)
                    }
                }
            }

            // One card per account, the way Google Drive and Slack draw theirs.
            ForEach(vm.youtubeAccounts) { account in
                accountCard(account)
            }

            if vm.hasConnectedYouTubeAccount {
                learnerCard
            }

            addRow
            notice
        }
        .onAppear {
            // A failed token refresh during a background import drops an
            // account's grant; re-read so a card never shows a stale
            // "Connected" state. Off-main: synced Keychain reads.
            Task {
                await vm.reloadYouTubeAccounts()
                let enabled = await Task.detached(priority: .userInitiated) {
                    StudioViewModel.isYouTubeAutoImportEnabled
                }.value
                persistedAutoImportEnabled = enabled
                autoImportEnabled = enabled
            }
        }
        .confirmationDialog(
            "Import videos from…",
            isPresented: dialogBinding(.importSource),
            titleVisibility: .visible
        ) {
            Button("Liked Videos") {
                showLikedHistoryChoiceAfterCurrentDialog()
            }
            Button("ForeverLM Playlist") {
                if let accountID = setupDialog?.accountID { configureForeverLMPlaylist(accountID: accountID) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The playlist option uses a playlist in this YouTube account named ForeverLM.")
        }
        .confirmationDialog(
            "Import existing liked videos?",
            isPresented: dialogBinding(.likedHistory),
            titleVisibility: .visible
        ) {
            Button("Import Existing and Future Likes") {
                chooseLikedImportPolicy(.importExisting)
            }
            Button("Only Import Future Likes") {
                chooseLikedImportPolicy(.futureOnly)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Nothing is imported until you choose. You can change this later.")
        }
        .confirmationDialog(
            "Format liked-video transcripts with AI?",
            isPresented: dialogBinding(.likedFormatting),
            titleVisibility: .visible
        ) {
            Button("Keep Raw Transcripts") {
                finishLikedVideosSetup(automaticallyFormatTranscripts: false)
            }
            Button("Format Automatically") {
                finishLikedVideosSetup(automaticallyFormatTranscripts: true)
            }
            Button("Cancel", role: .cancel) {
                pendingLikedImportPolicy = nil
            }
        } message: {
            Text("Automatic formatting can spend a lot on AI when importing a large history. Raw transcripts remain readable and searchable.")
        }
    }

    private var youtubeGlyph: some View {
        Image("YouTubeIcon")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: 20, height: 14)
            .frame(width: 34, height: 34)
            .background(Circle().fill(Color.primary.opacity(0.055)))
    }

    // MARK: - Accounts

    /// One connected account: who it is, what it imports, its Disconnect.
    @ViewBuilder
    private func accountCard(_ account: YouTubeAccount) -> some View {
        let disconnected = vm.youtubeDisconnectedAccountIDs.contains(account.id)
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    Text(String(account.title.prefix(1)).uppercased())
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textSelection(.disabled)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.primary.opacity(0.055)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(stateLine(account, disconnected: disconnected))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    if disconnected {
                        Button {
                            connect()
                        } label: {
                            Label("Reconnect", systemImage: "exclamationmark.circle.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.hoverWash)
                        .disabled(isConnecting || !canConnect)
                    }
                    Button("Disconnect", role: .destructive) {
                        // UI first; the synced-Keychain deletes run off the click.
                        Task { await vm.disconnectYouTubeAccount(account.id) }
                    }
                    .buttonStyle(.hoverWash)
                    .foregroundStyle(.secondary)
                }
                if !disconnected {
                    importSourceRows(account)
                    if account.choices.source == .likedVideos {
                        likedImportPolicyRow(account)
                    }
                }
            }
        }
    }

    private func stateLine(_ account: YouTubeAccount, disconnected: Bool) -> String {
        if disconnected { return "Disconnected, import has stopped" }
        return account.choices.source.map { "Imports \($0.displayName)" } ?? "Choose what to import"
    }

    @ViewBuilder
    private func importSourceRows(_ account: YouTubeAccount) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Import from")
                .font(.subheadline.weight(.semibold))
            ForEach(YouTubeImportSource.allCases) { source in
                HStack(spacing: 8) {
                    Image(systemName: source.iconName)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(source.displayName)
                        .font(.callout)
                    Spacer()
                    if account.choices.source == source {
                        Label("Selected", systemImage: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if configuringAccountID == account.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Use") {
                            if source == .likedVideos {
                                setupDialog = YouTubeSetupDialog(kind: .likedHistory, accountID: account.id)
                            } else {
                                configureForeverLMPlaylist(accountID: account.id)
                            }
                        }
                        .buttonStyle(.hoverWash)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func likedImportPolicyRow(_ account: YouTubeAccount) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Liked-video history")
                    .font(.callout)
                Text(account.choices.likedPolicy.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if configuringAccountID == account.id {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Change…") {
                    setupDialog = YouTubeSetupDialog(kind: .likedHistory, accountID: account.id)
                }
                .buttonStyle(.hoverWash)
                .controlSize(.small)
            }
        }
    }

    /// Connecting never replaces what is there: it adds another account.
    @ViewBuilder
    private var addRow: some View {
        HStack(spacing: 10) {
            if isConnecting {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for Google…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    connect()
                } label: {
                    Label(
                        vm.youtubeAccounts.isEmpty ? "Connect YouTube" : "Add Another Account",
                        systemImage: "plus"
                    )
                    .font(.callout.weight(.medium))
                }
                .buttonStyle(.hoverWash)
                .disabled(!canConnect)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var notice: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !canConnect {
                Text("This build of ForeverLM has no YouTube OAuth client configured, so YouTube cannot be connected.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Link("Setup guide", destination: URL(string: "https://docs.foreverlm.com/external-plugins#youtube")!)
                .font(.caption)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - The learner's own

    /// What does not depend on the account: the automatic-import switch and
    /// the channels, which are public follows.
    private var learnerCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Automatically import new videos", isOn: $autoImportEnabled)
                    .onChange(of: autoImportEnabled) { _, enabled in
                        // Seeding from `.onAppear` must not re-persist or
                        // kick an import; only a real user flip does.
                        guard enabled != persistedAutoImportEnabled else { return }
                        persistedAutoImportEnabled = enabled
                        StudioViewModel.setYouTubeAutoImportEnabled(enabled)
                        if enabled { Task { await vm.runYouTubeAutoImportOnce() } }
                    }
                if vm.youtubeAccounts.contains(where: { $0.choices.source == .likedVideos }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(
                            "Format new transcripts automatically",
                            isOn: $automaticallyFormatLikedVideoTranscripts
                        )
                        Text("Billed to your OpenRouter key. Raw transcripts are always imported.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .settingsFocusRow(.youTubeFormatTranscripts)
                }
                Divider()
                followedChannelsSection
                if !vm.hiddenYouTubeChannelNames.isEmpty {
                    Divider()
                    hiddenChannelsSection
                }
            }
        }
    }

    /// Channels the plugin follows, each a group in the YouTube tab, and the
    /// field that adds one. A follow imports the channel's newest uploads and
    /// then every new one; stopping keeps the videos already imported.
    private var followedChannelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Followed channels")
                .font(.subheadline.weight(.semibold))
            ForEach(vm.followedYouTubeChannelGroupIDs, id: \.self) { groupID in
                HStack(spacing: 8) {
                    Image(systemName: "play.rectangle")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(vm.videoPlaylistDisplayName(groupID))
                        .font(.callout)
                        .lineLimit(1)
                    Spacer()
                    Button("Stop Following") {
                        Task { await vm.unfollowYouTubePluginPlaylist(groupID) }
                    }
                    .buttonStyle(.hoverWash)
                    .controlSize(.small)
                }
            }
            HStack(spacing: 8) {
                TextField("Channel address or @handle", text: $channelInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(followChannel)
                    .disabled(isFollowingChannel)
                if isFollowingChannel {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Follow") {
                        followChannel()
                    }
                    .buttonStyle(.hoverWash)
                    .controlSize(.small)
                    .disabled(channelInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text("Imports the newest \(StudioViewModel.youtubeChannelFollowImportCount) videos, then each new upload.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hiddenChannelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hidden channels")
                .font(.subheadline.weight(.semibold))
            ForEach(vm.hiddenYouTubeChannelNames, id: \.self) { channel in
                HStack {
                    Image(systemName: "eye.slash")
                        .foregroundStyle(.secondary)
                    Text(channel)
                        .lineLimit(1)
                    Spacer()
                    Button("Unhide") {
                        Task { await vm.setYouTubeChannelHidden(channel, hidden: false) }
                    }
                    .buttonStyle(.hoverWash)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Actions

    /// Release builds ship ForeverLM's own YouTube OAuth client, so this is
    /// always true for users. It can only be false in a Debug build whose .env
    /// carries no YouTube client.
    private var canConnect: Bool {
        YouTubeService.shared.canConnect
    }

    private func followChannel() {
        let input = channelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isFollowingChannel else { return }
        isFollowingChannel = true
        statusMessage = nil
        Task {
            let groupID = await vm.followYouTubeChannel(input)
            if groupID == nil {
                statusMessage = vm.errorMessage ?? "Couldn’t follow that channel."
            } else {
                channelInput = ""
            }
            autoImportEnabled = StudioViewModel.isYouTubeAutoImportEnabled
            isFollowingChannel = false
        }
    }

    private func connect() {
        guard canConnect else {
            statusMessage = "This build has no YouTube OAuth client configured."
            return
        }
        isConnecting = true
        statusMessage = nil
        Task {
            do {
                let account = try await YouTubeService.shared.authenticate()
                await vm.reloadYouTubeAccounts()
                if vm.youtubeAccount(id: account.id)?.choices.source == nil {
                    setupDialog = YouTubeSetupDialog(kind: .importSource, accountID: account.id)
                }
            } catch {
                statusMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }

    private func configureLikedVideos(
        _ policy: YouTubeLikedImportPolicy,
        accountID: String,
        automaticallyFormatTranscripts: Bool
    ) {
        configuringAccountID = accountID
        statusMessage = nil
        Task {
            let groupID = await vm.configureYouTubeLikedVideos(
                policy,
                accountID: accountID,
                automaticallyFormatTranscripts: automaticallyFormatTranscripts
            )
            if groupID == nil {
                statusMessage = vm.errorMessage ?? "Could not configure Liked videos."
            }
            autoImportEnabled = StudioViewModel.isYouTubeAutoImportEnabled
            configuringAccountID = nil
        }
    }

    private func chooseLikedImportPolicy(_ policy: YouTubeLikedImportPolicy) {
        pendingLikedImportPolicy = policy
        guard let accountID = setupDialog?.accountID else { return }
        setupDialog = nil
        Task { @MainActor in
            await Task.yield()
            setupDialog = YouTubeSetupDialog(kind: .likedFormatting, accountID: accountID)
        }
    }

    private func finishLikedVideosSetup(automaticallyFormatTranscripts: Bool) {
        guard let policy = pendingLikedImportPolicy, let accountID = setupDialog?.accountID else { return }
        pendingLikedImportPolicy = nil
        automaticallyFormatLikedVideoTranscripts = automaticallyFormatTranscripts
        configureLikedVideos(
            policy,
            accountID: accountID,
            automaticallyFormatTranscripts: automaticallyFormatTranscripts
        )
    }

    private func showLikedHistoryChoiceAfterCurrentDialog() {
        guard let accountID = setupDialog?.accountID else { return }
        setupDialog = nil
        Task { @MainActor in
            await Task.yield()
            setupDialog = YouTubeSetupDialog(kind: .likedHistory, accountID: accountID)
        }
    }

    private func configureForeverLMPlaylist(accountID: String) {
        configuringAccountID = accountID
        statusMessage = nil
        Task {
            let groupID = await vm.followYouTubeForeverLMPlaylist(accountID: accountID)
            if groupID == nil {
                statusMessage = vm.errorMessage ?? "Could not find your ForeverLM playlist."
            }
            autoImportEnabled = StudioViewModel.isYouTubeAutoImportEnabled
            configuringAccountID = nil
        }
    }

    private func dialogBinding(_ kind: YouTubeSetupDialog.Kind) -> Binding<Bool> {
        Binding(
            get: { setupDialog?.kind == kind },
            set: { presented in
                if !presented, setupDialog?.kind == kind {
                    setupDialog = nil
                }
            }
        )
    }
}

/// A question the page is asking about one account.
private struct YouTubeSetupDialog: Equatable {
    enum Kind {
        case importSource
        case likedHistory
        case likedFormatting
    }

    let kind: Kind
    let accountID: String
}

/// One meeting folder under a Google account. "Open in Drive" appears on hover.
private struct GoogleDriveFolderRow: View {
    let folder: GoogleDriveFolderAttribution.Folder
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(folder.title)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let url = folder.url {
                Link(destination: url) {
                    Label("Open in Drive", systemImage: "arrow.up.right")
                        .font(.caption)
                }
                .opacity(isHovering ? 1 : 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// Which connected Google account reads which meeting folder. A folder URL
/// carries the account it was chosen through as a query tag; one without a tag
/// predates multi-account and is read through the default account. A folder
/// tagged with an account that is no longer connected is neither — it is
/// listed apart, so the learner sees why it stopped updating.
struct GoogleDriveFolderAttribution: Equatable {
    struct Folder: Equatable, Identifiable {
        /// The meeting group's id, the key in `meetingMetadata`.
        let groupID: String
        /// The group's title, or its id when it has none.
        let title: String
        /// The Drive folder id parsed off the URL, when the URL has one.
        let folderID: String?
        /// The account tag on the URL, when there is one.
        let accountID: String?

        var id: String { groupID }

        /// The folder on Drive, without the account tag ForeverLM added.
        var url: URL? {
            folderID.flatMap { URL(string: "https://drive.google.com/drive/folders/\($0)") }
        }
    }

    private(set) var byAccount: [String: [Folder]] = [:]
    /// Folders tagged with an account that is not connected any more.
    private(set) var unattributed: [Folder] = []

    init(metadata: [String: MeetingMetadata], accountIDs: [String], defaultAccountID: String?) {
        let connected = Set(accountIDs)
        // An untagged folder reads through the default account when it is
        // connected, else through the only account, else through none.
        let fallback: String? = {
            if let defaultAccountID, connected.contains(defaultAccountID) { return defaultAccountID }
            return accountIDs.count == 1 ? accountIDs[0] : nil
        }()
        let folders = metadata
            .compactMap { key, value -> Folder? in
                guard !value.isHidden,
                      Self.trimmed(value.mergedIntoGroupID) == nil,
                      let url = Self.trimmed(value.driveFolderURL) else { return nil }
                let title = Self.trimmed(value.title) ?? key
                guard !title.isEmpty else { return nil }
                return Folder(
                    groupID: key,
                    title: title,
                    folderID: try? StudioViewModel.googleDriveFolderID(from: url),
                    accountID: GoogleDriveService.accountID(from: url)
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        for folder in folders {
            let owner = folder.accountID ?? fallback
            if let owner, connected.contains(owner) {
                byAccount[owner, default: []].append(folder)
            } else {
                unattributed.append(folder)
            }
        }
    }

    func folders(for accountID: String) -> [Folder] { byAccount[accountID] ?? [] }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
