// Goals grouped by deadline for the Goals tab.

import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

extension StudioViewModel {

    /// The timebound Goals belonging to a given Notebook, nearest deadline first.
    func goals(inNotebook notebookID: String) -> [LearningGoalRecord] {
        learningGoals
            .filter { $0.isNotebookGoal && $0.parentNotebookID == notebookID }
            .sorted { $0.endAt < $1.endAt }
    }

    /// Every Goal the learner has set, nearest deadline first — the ones tagged
    /// to a Notebook and the ones standing alone alike. This is what the Goals
    /// tab lists; a Notebook's inspector still asks for its own with
    /// `goals(inNotebook:)`.
    ///
    /// Team-scoped the way `notebooks` is: a Goal tagged to a team's Notebook
    /// belongs to that library. An untagged Goal carries no team and is the
    /// learner's own, so it shows in My Library only.
    ///
    /// In the order the learner made (`LearningGoalRecord.listOrder`): the
    /// Goals placed by hand first, then the rest by deadline.
    var allGoals: [LearningGoalRecord] {
        learningGoals
            .filter { goal in
                guard goal.isGoal,
                      screenRecordScope?.allowsItem(createdAt: goal.createdAt, notebookIDs: [goal.parentNotebookID]) ?? true
                else { return false }
                return goal.teamID == activeTeamID
            }
            .sorted(by: LearningGoalRecord.listOrder)
    }

    /// The active Goals, split into the ones close enough to be working on and
    /// the ones still over the horizon. Within a band the learner's order
    /// stands; where none was made, an overdue Goal leads the first band,
    /// because a deadline that has passed is the most urgent thing on the
    /// list and `allGoals`' deadline ordering already puts it first.
    func goalBands(now: Date = Date(), calendar: Calendar = .current) -> (inFlight: [LearningGoalRecord], later: [LearningGoalRecord], done: [LearningGoalRecord]) {
        var inFlight: [LearningGoalRecord] = []
        var later: [LearningGoalRecord] = []
        var done: [LearningGoalRecord] = []
        for goal in allGoals {
            if goal.isDone || goal.isArchived {
                done.append(goal)
            } else if (goal.daysRemaining(asOf: now, calendar: calendar) ?? 0) > Self.goalHorizonDays {
                later.append(goal)
            } else {
                inFlight.append(goal)
            }
        }
        // Finished work reads newest first; what is still open reads by deadline.
        done.sort { $0.updatedAt > $1.updatedAt }
        return (inFlight, later, done)
    }

}
