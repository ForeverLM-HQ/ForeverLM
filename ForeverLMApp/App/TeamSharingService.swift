import AppKit
import CloudKit
import Foundation
import OSLog

/// Presents Apple's sharing sheet for a team's zone-wide share, so the owner
/// adds members by name or email and iCloud resolves them, and announces an
/// accepted invitation to the app. Modelled on `ArtifactSharingService`, with
/// the difference that the share already exists: `createTeam` made it, so the
/// sheet manages participants rather than creating a share.
@MainActor
final class TeamSharingService: NSObject, @preconcurrency NSCloudSharingServiceDelegate {
    static let shared = TeamSharingService()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Teams")
    private var activeProvider: NSItemProvider?
    private var activeService: NSSharingService?
    private var activeTeamID: String?

    /// Posted after the sharing sheet closes with the team id in `object`, and
    /// after an invitation is accepted, so Settings and the rail refresh.
    static let teamRosterDidChange = Notification.Name("TeamRosterDidChange")

    func presentMembers(for team: TeamRecord) {
        let provider = NSItemProvider()
        provider.registerCloudKitShare { [team] completion in
            Task {
                do {
                    // A team is a space of the library container (§9.7).
                    guard let coordinator = SyncCoordinator.current else { throw SpaceServiceError.syncNotRunning }
                    guard let space = try await SpaceService(coordinator: coordinator).list().first(where: { $0.localTeamID == team.id && $0.gone == nil }) else {
                        throw TeamError.shareUnavailable(team.name)
                    }
                    completion(try await SpaceShareSheet.share(of: space.zone, in: coordinator.container), coordinator.container, nil)
                } catch {
                    completion(nil, nil, error)
                }
            }
        }
        guard let service = NSSharingService(named: .cloudSharing) else { return }
        service.delegate = self
        activeProvider = provider
        activeService = service
        activeTeamID = team.id
        service.perform(withItems: [provider])
    }

    func options(
        for sharingService: NSSharingService,
        share shareProvider: NSItemProvider
    ) -> NSSharingService.CloudKitOptions {
        // `.allowPublic` is what makes the sheet's Copy Link work: a copied
        // link has no invitee, so the service saves the share with a public
        // permission and only then puts the URL on the pasteboard. Without it
        // the save is refused and Share does nothing visible.
        [.allowPublic, .allowPrivate, .allowReadOnly, .allowReadWrite]
    }

    func sharingService(
        _ sharingService: NSSharingService,
        didCompleteForItems items: [Any],
        error: (any Error)?
    ) {
        if let error {
            logger.error("Team sharing sheet ended with an error: \(error.localizedDescription, privacy: .public)")
        }
        let teamID = activeTeamID
        activeProvider = nil
        activeService = nil
        activeTeamID = nil
        guard let teamID else { return }
        Task {
            do {
                _ = try await StorageService().refreshTeamMembers(teamID: teamID)
            } catch {
                self.logger.error("Refreshing the team roster failed: \(error.localizedDescription, privacy: .public)")
            }
            await MainActor.run {
                NotificationCenter.default.post(name: Self.teamRosterDidChange, object: teamID)
            }
        }
    }

    func sharingService(_ sharingService: NSSharingService, didSave share: CKShare) {
        guard let teamID = activeTeamID else { return }
        Task {
            do {
                _ = try await StorageService().refreshTeamMembers(teamID: teamID)
            } catch {
                self.logger.error("Refreshing the team roster failed: \(error.localizedDescription, privacy: .public)")
            }
            await MainActor.run {
                NotificationCenter.default.post(name: Self.teamRosterDidChange, object: teamID)
            }
        }
    }

    func sharingService(_ sharingService: NSSharingService, didStopSharing share: CKShare) {
        guard let teamID = activeTeamID else { return }
        Task {
            do {
                _ = try await StorageService().refreshTeamMembers(teamID: teamID)
            } catch {
                self.logger.error("Refreshing the team roster failed: \(error.localizedDescription, privacy: .public)")
            }
            await MainActor.run {
                NotificationCenter.default.post(name: Self.teamRosterDidChange, object: teamID)
            }
        }
    }

    /// Copy Link: anyone who has the link can join. A share whose public
    /// permission is `.none` hands out a URL only named participants can open,
    /// so the owner's copy opens the share first, after asking whether the
    /// link may edit or only view (view is the default: a link gets forwarded;
    /// security audit, 2026-11-12). A member copies the URL as it stands.
    /// `toast` reports the outcome.
    func copyInvitationLink(for team: TeamRecord, toast: @escaping @MainActor (String) -> Void) {
        guard let link = team.shareURL, let url = URL(string: link) else {
            toast("The link appears once iCloud has shared the team.")
            return
        }
        guard team.role == .owner else {
            Self.copyToPasteboard(url)
            toast("Invitation link copied")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Let anyone with the link join “\(team.name)”?"
        alert.informativeText = "Whoever has the link can join the team, even if it is forwarded. A view-only link lets them read the team's library; an editing link also lets them change it."
        alert.addButton(withTitle: "Copy View-Only Link")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Copy Editing Link")
        let canEdit: Bool
        switch alert.runModal() {
        case .alertFirstButtonReturn: canEdit = false
        case .alertThirdButtonReturn: canEdit = true
        default: return
        }
        Task {
            do {
                let opened = try await StorageService().openTeamShareToAnyoneWithLink(team, canEdit: canEdit)
                Self.copyToPasteboard(opened)
                toast(canEdit
                    ? "Invitation link copied — anyone with it can join and edit"
                    : "Invitation link copied — anyone with it can join and read")
            } catch {
                logger.error("Opening the team share to the link failed: \(error.localizedDescription, privacy: .public)")
                toast("Could not open the link: \(error.localizedDescription)")
            }
        }
    }

    private static func copyToPasteboard(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}
