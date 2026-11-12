import Foundation
import OSLog

// MARK: - The member's course focus under generation 2 (docs/cloudkit-schema-design.md §3.5.12)

extension KnowledgeStore {
    /// Every focus the member wrote, by course: what `CourseEnrollmentStore` holds in memory.
    func courseFocusSnapshot() throws -> [String: String] {
        var focus: [String: String] = [:]
        try query("SELECT course_id, focus FROM course_enrollments WHERE focus IS NOT NULL AND focus <> ''", []) { row in
            if let course = row.text(0), let text = row.text(1) { focus[course] = text }
        }
        return focus
    }

    /// Writes what the member wants from a course into their Enrollment, which the write makes when there
    /// is none (an explicit act, §3.5.12); a blank focus clears it and keeps the Enrollment. Opening a
    /// course writes nothing. Generation 2 only.
    func setCourseFocus(courseID: String, focus: String) throws {
        let text = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        try inDerivationTransaction { store in
            let held = try CourseEnrollmentRow.load(courseID, connection: store)
            guard held != nil || !text.isEmpty else { return }
            var row = held ?? CourseEnrollmentRow(courseID: courseID)
            row.focus = text.isEmpty ? nil : text
            guard row != held else { return }
            try row.save(store)
        }
    }
}

/// The focus the Mac's course surfaces read synchronously under generation 2, as generation 1 reads its
/// `course.focus.<courseID>` rows from `UserDefaults` (`LearnerProfile`). A write lands in memory at once
/// and in `course_enrollments` off the main actor, in call order; the snapshot is then read back and the
/// surfaces are told, as for a preference that changed remotely. A test binds its own snapshot
/// (`override`), and while bound nothing reaches the store.
enum CourseEnrollmentStore {
    private static let lock = AppLock()
    nonisolated(unsafe) private static var snapshot: [String: String] = [:]
    nonisolated(unsafe) private static var loaded = false
    nonisolated(unsafe) private static var tail: Task<Void, Never>?
    private static let storage = StorageService()
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "CourseEnrollmentStore")

    /// A test's own snapshot, bound for the task that runs it.
    @TaskLocal static var override: Box? = nil

    final class Box: @unchecked Sendable {
        var focus: [String: String]
        init(_ focus: [String: String] = [:]) { self.focus = focus }
    }

    static func focus(courseID: String) -> String {
        if let override { return override.focus[courseID] ?? "" }
        lock.lock()
        let value = snapshot[courseID] ?? ""
        let needsLoad = !loaded
        loaded = true
        lock.unlock()
        if needsLoad { enqueue { _ in } }
        return value
    }

    static func setFocus(_ text: String, courseID: String) {
        if let override {
            override.focus[courseID] = text.isEmpty ? nil : text
            return
        }
        lock.lock()
        snapshot[courseID] = text.isEmpty ? nil : text
        lock.unlock()
        enqueue { try $0.setCourseFocus(courseID: courseID, focus: text) }
    }

    /// Reloads after an inbound Enrollment.
    static func reload() { enqueue { _ in } }

    /// Takes a snapshot read back from the store; whether it differs from the one held.
    private static func replace(with fresh: [String: String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let changed = fresh != snapshot
        snapshot = fresh
        return changed
    }

    /// Runs `write`, then reloads the snapshot, after every write enqueued before it.
    private static func enqueue(_ write: @escaping @Sendable (KnowledgeStore) throws -> Void) {
        guard override == nil else { return }
        lock.lock()
        let predecessor = tail
        let next = Task.detached(priority: .utility) {
            await predecessor?.value
            do {
                let fresh = try await storage.writingCourseEnrollment(write)
                if replace(with: fresh) {
                    await MainActor.run {
                        NotificationCenter.default.post(name: PreferenceStore.didChangeRemotely, object: nil, userInfo: [PreferenceStore.changedKeysKey: Set<String>()])
                    }
                }
            } catch {
                logger.error("Could not keep the course focus: \(error.localizedDescription, privacy: .public)")
            }
        }
        tail = next
        lock.unlock()
    }
}

extension StorageService {
    /// Runs a course-enrollment write, then reads every focus back, on the storage actor.
    func writingCourseEnrollment(_ write: (KnowledgeStore) throws -> Void) throws -> [String: String] {
        var fresh: [String: String] = [:]
        try performSync { store in
            try write(store)
            fresh = try store.courseFocusSnapshot()
        }
        return fresh
    }
}
