import Foundation
import Observation
import OSLog

/// The learner's chat skills as the Mac's windows see them: the chat composer
/// offers each as a `/` or `$` command, and the Plugins place's Skills tab
/// lists, edits, creates and deletes them (`SkillsListView`, `SkillPage`).
///
/// The list is read off-main through `StorageService` and read again when a
/// skill is written here (`skillsDidChange`), by an MCP tool
/// (`foreverLMDataDidChange`), or on the other Mac
/// (`cloudKitSyncRemoteStoreDidChange` naming `skill`). A chat does not read
/// from here: it takes its own snapshot at its first turn so its system
/// prompt stays the same bytes for the whole conversation
/// (`ReviewSessionManager.sessionSkills`).
@MainActor
@Observable
final class SkillLibrary {
    static let shared = SkillLibrary()

    private(set) var skills: [SkillRecord] = []
    private(set) var hasLoaded = false
    /// Why the list could not be read, in the store's words, or nil.
    private(set) var loadError: String?

    @ObservationIgnored private let storage = StorageService()
    @ObservationIgnored private let logger = Logger(subsystem: "ForeverLM", category: "Skills")
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var reloadGeneration = 0

    private init() {
        installObservers()
    }

    /// Read the list the first time something asks for it.
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    /// Reads can overlap (a write here and its notification both ask); only
    /// the newest read publishes, so an older answer never lands last.
    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        do {
            let loaded = try await storage.loadSkills()
            guard generation == reloadGeneration else { return }
            if loaded != skills { skills = loaded }
            loadError = nil
        } catch {
            guard generation == reloadGeneration else { return }
            logger.error("Skills could not be read: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
        }
        hasLoaded = true
    }

    // MARK: - Writes

    @discardableResult
    func create(name: String, description: String, instructions: String) async throws -> SkillRecord {
        let skill = try await storage.createSkill(name: name, description: description, instructions: instructions)
        await reload()
        return skill
    }

    @discardableResult
    func update(_ skillID: String, name: String, description: String, instructions: String) async throws -> SkillRecord {
        let skill = try await storage.updateSkill(skillID, name: name, description: description, instructions: instructions)
        await reload()
        return skill
    }

    func delete(_ skillID: String) async throws {
        try await storage.deleteSkill(skillID)
        await reload()
    }

    // MARK: - Observers

    private func installObservers() {
        let center = NotificationCenter.default
        for name in [Notification.Name.skillsDidChange, .foreverLMDataDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    guard SkillLibrary.shared.hasLoaded else { return }
                    await SkillLibrary.shared.reload()
                }
            })
        }
        observers.append(center.addObserver(forName: .cloudKitSyncRemoteStoreDidChange, object: nil, queue: .main) { notification in
            let rawValues = notification.userInfo?[CloudKitSyncNotificationInfo.affectedEntitiesKey] as? [String] ?? []
            let entities = Set(rawValues.compactMap(CloudKitSyncEntity.init(rawValue:)))
            let requiresFullRefresh = notification.userInfo?[CloudKitSyncNotificationInfo.requiresFullRefreshKey] as? Bool ?? false
            guard requiresFullRefresh || entities.contains(.skill) else { return }
            Task { @MainActor in
                guard SkillLibrary.shared.hasLoaded else { return }
                await SkillLibrary.shared.reload()
            }
        })
    }
}
