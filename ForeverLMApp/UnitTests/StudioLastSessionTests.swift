import Testing
import Foundation
import AppKit
@testable import ForeverLM

/// Reopening the windows the last session left behind.
///
/// Lives in its own file rather than in `StudioViewModelTests`: the workspace
/// coordinator is a singleton several suites reach for, and a shared test file
/// is also where two people editing the same checkout collide.
@Suite("Studio Last Session")
@MainActor
struct StudioLastSessionTests {
    @Test("the last session's windows come back, and one window changes nothing")
    func lastSessionRestoresEveryWindow() {
        let saved = UserDefaults.standard.data(forKey: StudioLastSessionStore.preferenceKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: StudioLastSessionStore.preferenceKey)
            } else {
                StudioLastSessionStore.clear()
            }
        }

        let firstSnapshot = StudioWindowState.Snapshot(
            centerTabGroups: ["notebooks*", "reader*"],
            navigationRailVisible: false
        )
        let secondSnapshot = StudioWindowState.Snapshot(
            centerTabGroups: ["chat*", "notepad*"],
            navigationRailVisible: true
        )

        StudioLastSessionStore.save([
            .init(snapshot: firstSnapshot, placement: nil),
            .init(snapshot: secondSnapshot, placement: nil),
        ])
        #expect(StudioLastSessionStore.load().count == 2)

        let coordinator = StudioWorkspaceWindowCoordinator()
        coordinator.armLastSessionRestore()
        let firstState = StudioWindowState()
        let secondState = StudioWindowState()
        let window = { NSWindow(
            contentRect: NSRect(x: 40, y: 50, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        ) }
        defer {
            coordinator.unregister(state: firstState)
            coordinator.unregister(state: secondState)
        }

        // With only the window SwiftUI always opens registered, one more is
        // needed; the answer is given out once so a second window asking
        // cannot open a third.
        coordinator.register(state: firstState, window: window())
        #expect(firstState.snapshot == StudioWindowState(snapshot: firstSnapshot).snapshot)
        #expect(firstState.workspaceRestoreOverridesSceneSnapshot)
        #expect(coordinator.reconcileLastSessionWindows() == .init(windowsToOpen: 1, windowsToClose: 0))
        #expect(coordinator.reconcileLastSessionWindows() == .init(windowsToOpen: 0, windowsToClose: 0))

        coordinator.register(state: secondState, window: window())
        #expect(secondState.snapshot == StudioWindowState(snapshot: secondSnapshot).snapshot)

        // A single saved window is left to SwiftUI: it already restores one
        // window's frame, and its panes come from SceneStorage.
        StudioLastSessionStore.save([.init(snapshot: firstSnapshot, placement: nil)])
        let single = StudioWorkspaceWindowCoordinator()
        single.armLastSessionRestore()
        let singleState = StudioWindowState()
        single.register(state: singleState, window: window())
        defer { single.unregister(state: singleState) }
        #expect(single.reconcileLastSessionWindows() == .init(windowsToOpen: 0, windowsToClose: 0))

        // Unarmed, a coordinator never pulls a stored arrangement in: only a
        // launch restores, and registering windows must not imply one.
        StudioLastSessionStore.save([
            .init(snapshot: firstSnapshot, placement: nil),
            .init(snapshot: secondSnapshot, placement: nil),
        ])
        let unarmed = StudioWorkspaceWindowCoordinator()
        let untouched = StudioWindowState()
        let before = untouched.snapshot
        unarmed.register(state: untouched, window: window())
        defer { unarmed.unregister(state: untouched) }
        #expect(unarmed.reconcileLastSessionWindows() == .init(windowsToOpen: 0, windowsToClose: 0))
        #expect(untouched.snapshot == before)
        #expect(!untouched.workspaceRestoreOverridesSceneSnapshot)
    }

    @Test("a relaunch the app asked for brings every window's content back, once")
    func relaunchRestoresContent() {
        let saved = UserDefaults.standard.data(forKey: StudioLastSessionStore.preferenceKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: StudioLastSessionStore.preferenceKey)
            } else {
                StudioLastSessionStore.clear()
            }
            UserDefaults.standard.removeObject(forKey: StudioLastSessionStore.resumeContentKey)
        }
        let window = { NSWindow(
            contentRect: NSRect(x: 40, y: 50, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        ) }
        let snapshot = StudioWindowState.Snapshot(
            centerTabGroups: ["chat*", "notepad*"],
            navigationRailVisible: false
        )
        let content = StudioWindowContent(
            readerSourceID: "source-1",
            chatSessionID: "session-1",
            artifactID: "doc-1",
            sidebarTab: StudioSidebarTab.papers.rawValue
        )

        // The store keeps the content, and a record written before content
        // existed still decodes.
        StudioLastSessionStore.save([.init(snapshot: snapshot, placement: nil, content: content)])
        #expect(StudioLastSessionStore.load().first?.content == content)
        let legacy = try? JSONDecoder().decode(
            StudioSavedWorkspaceWindow.self,
            from: Data(#"{"snapshot":{"centerTabGroups":["chat*"],"showSourcesPanel":true,"collapsedPanelIDs":[],"navigationRailVisible":true}}"#.utf8)
        )
        #expect(legacy?.content == nil)

        // An ordinary launch with one saved window leaves the window to
        // SwiftUI, content included.
        let ordinary = StudioWorkspaceWindowCoordinator()
        ordinary.armLastSessionRestore()
        let ordinaryState = StudioWindowState()
        ordinary.register(state: ordinaryState, window: window())
        defer { ordinary.unregister(state: ordinaryState) }
        #expect(ordinaryState.pendingResumeContent == nil)
        #expect(!ordinaryState.workspaceRestoreOverridesSceneSnapshot)

        // After Restart, the single window gets its layout and its content.
        StudioLastSessionStore.requestContentResume()
        let relaunched = StudioWorkspaceWindowCoordinator()
        relaunched.armLastSessionRestore()
        let relaunchedState = StudioWindowState()
        relaunched.register(state: relaunchedState, window: window())
        defer { relaunched.unregister(state: relaunchedState) }
        #expect(relaunchedState.pendingResumeContent == content)
        #expect(relaunchedState.snapshot == StudioWindowState(snapshot: snapshot).snapshot)
        #expect(relaunchedState.workspaceRestoreOverridesSceneSnapshot)
        #expect(relaunched.reconcileLastSessionWindows() == .init(windowsToOpen: 0, windowsToClose: 0))
        // The request is answered once: the launch after this one is ordinary.
        #expect(UserDefaults.standard.object(forKey: StudioLastSessionStore.resumeContentKey) == nil)

        // Two saved windows on an ordinary launch: the arrangement comes
        // back, as before, and nothing that was open does. (Distinct records:
        // the store folds exact copies into one window.)
        let otherSnapshot = StudioWindowState.Snapshot(
            centerTabGroups: ["notebooks*", "reader*"],
            navigationRailVisible: true
        )
        StudioLastSessionStore.save([
            .init(snapshot: snapshot, placement: nil, content: content),
            .init(snapshot: otherSnapshot, placement: nil, content: content),
        ])
        let twoWindows = StudioWorkspaceWindowCoordinator()
        twoWindows.armLastSessionRestore()
        let first = StudioWindowState()
        twoWindows.register(state: first, window: window())
        defer { twoWindows.unregister(state: first) }
        #expect(first.workspaceRestoreOverridesSceneSnapshot)
        #expect(first.pendingResumeContent == nil)
    }

    @Test("the capture names what each window shows only when asked")
    func captureIncludesContentOnRequest() {
        let coordinator = StudioWorkspaceWindowCoordinator()
        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 50, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let state = StudioWindowState()
        state.readerArticleID = "source-2"
        state.chatSessionID = "session-2"
        state.openArtifactID = "doc-2"
        state.sidebarStore.sidebarTab = .books
        coordinator.register(state: state, window: window)
        defer { coordinator.unregister(state: state) }

        // A named workspace describes an arrangement, not a moment.
        #expect(coordinator.captureWorkspace().first?.content == nil)

        let captured = coordinator.captureWorkspace(includingContent: true).first?.content
        #expect(captured == StudioWindowContent(
            readerSourceID: "source-2",
            chatSessionID: "session-2",
            artifactID: "doc-2",
            sidebarTab: StudioSidebarTab.books.rawValue
        ))

        // A window that never chose a source of its own reports the one its
        // reader is showing from the app-wide selection.
        let following = StudioWindowState()
        following.readerSourceIDsOnScreen = ["source-3"]
        #expect(StudioWorkspaceWindowCoordinator.content(of: following).readerSourceID == "source-3")
    }

    @Test("a pending action runs once, in the next window to register")
    func pendingActionRunsInTheNextRegisteredWindow() {
        let coordinator = StudioWorkspaceWindowCoordinator()
        let window = { NSWindow(
            contentRect: NSRect(x: 40, y: 50, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        ) }
        let first = StudioWindowState()
        let second = StudioWindowState()
        let third = StudioWindowState()
        defer {
            coordinator.unregister(state: first)
            coordinator.unregister(state: second)
            coordinator.unregister(state: third)
        }
        var received: [UUID] = []

        // A later request replaces an earlier one that has not found its window.
        coordinator.performInNextRegisteredWindow { _ in received.append(UUID()) }
        coordinator.performInNextRegisteredWindow { received.append($0.id) }
        coordinator.register(state: first, window: window())
        #expect(received == [first.id])

        // Consumed: the next window is not handed the same source again.
        coordinator.register(state: second, window: window())
        #expect(received == [first.id])

        coordinator.performInNextRegisteredWindow { received.append($0.id) }
        coordinator.register(state: third, window: window())
        #expect(received == [first.id, third.id])
    }

    @Test("windows macOS restored on its own are not opened a second time")
    func restoredWindowsAreDiscounted() {
        let saved = UserDefaults.standard.data(forKey: StudioLastSessionStore.preferenceKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: StudioLastSessionStore.preferenceKey)
            } else {
                StudioLastSessionStore.clear()
            }
        }

        let snapshot = StudioWindowState.Snapshot(
            centerTabGroups: ["chat*"],
            navigationRailVisible: true
        )
        let placement = { (x: Double) in StudioWindowPlacement(
            displayID: "1",
            displayName: "Display",
            displayIndex: 0,
            normalizedX: x,
            normalizedY: 0.1,
            normalizedWidth: 0.5,
            normalizedHeight: 0.5
        ) }
        StudioLastSessionStore.save([
            .init(snapshot: snapshot, placement: placement(0.0)),
            .init(snapshot: snapshot, placement: placement(0.2)),
            .init(snapshot: snapshot, placement: placement(0.4)),
        ])

        // This is the bug of 2026-09-03: SwiftUI restored the last session's
        // windows itself, the count was taken as if only one existed, and the
        // whole saved session was opened again on top. Three registered
        // against three saved means nothing to open.
        let coordinator = StudioWorkspaceWindowCoordinator()
        coordinator.armLastSessionRestore()
        let states = (0..<3).map { _ in StudioWindowState() }
        let window = { NSWindow(
            contentRect: NSRect(x: 40, y: 50, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        ) }
        defer { states.forEach { coordinator.unregister(state: $0) } }
        for state in states {
            coordinator.register(state: state, window: window())
        }
        #expect(coordinator.reconcileLastSessionWindows() == .init(windowsToOpen: 0, windowsToClose: 0))

        // Two restored out of three saved opens exactly the missing one.
        StudioLastSessionStore.save([
            .init(snapshot: snapshot, placement: placement(0.0)),
            .init(snapshot: snapshot, placement: placement(0.2)),
            .init(snapshot: snapshot, placement: placement(0.4)),
        ])
        let partial = StudioWorkspaceWindowCoordinator()
        partial.armLastSessionRestore()
        let partialStates = (0..<2).map { _ in StudioWindowState() }
        defer { partialStates.forEach { partial.unregister(state: $0) } }
        for state in partialStates {
            partial.register(state: state, window: window())
        }
        #expect(partial.reconcileLastSessionWindows() == .init(windowsToOpen: 1, windowsToClose: 0))
    }

    @Test("an inflated session is cut back to the cap, and the surplus windows are closed")
    func inflatedSessionIsRepaired() {
        let saved = UserDefaults.standard.data(forKey: StudioLastSessionStore.preferenceKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: StudioLastSessionStore.preferenceKey)
            } else {
                StudioLastSessionStore.clear()
            }
        }
        let maximum = StudioLastSessionStore.maximumWindows

        // 35 saved records made of two arrangements repeated at ten positions,
        // which is what the runaway Dev library's store looked like.
        let snapshots = [
            StudioWindowState.Snapshot(
                centerTabGroups: ["chat*|tasks", "reader*"],
                navigationRailVisible: false
            ),
            StudioWindowState.Snapshot(
                centerTabGroups: ["notebooks*"],
                navigationRailVisible: true
            ),
        ]
        let inflated: [StudioSavedWorkspaceWindow] = (0..<35).map { index in
            .init(
                snapshot: snapshots[index % 2],
                placement: StudioWindowPlacement(
                    displayID: "1",
                    displayName: "Display",
                    displayIndex: 0,
                    normalizedX: Double(index % 10) / 10,
                    normalizedY: 0.1,
                    normalizedWidth: 0.5,
                    normalizedHeight: 0.5
                )
            )
        }
        let distinct = StudioLastSessionStore.normalized(inflated)
        #expect(distinct.count == min(10, maximum))
        #expect(Set(distinct.map { StudioWindowPlacement.onScreenSortKey($0.placement) }).count == distinct.count)
        // Every exact copy is dropped before the cap is applied, so what is
        // kept is the distinct arrangement, not the first dozen records.
        #expect(distinct == Array(inflated.prefix(min(10, maximum))))

        // Saving writes the normalized set; loading an older, unbounded store
        // caps it too.
        StudioLastSessionStore.save(inflated)
        #expect(StudioLastSessionStore.load() == distinct)
        let unbounded = (0..<(maximum * 3)).map { index in
            StudioSavedWorkspaceWindow(
                snapshot: snapshots[0],
                placement: StudioWindowPlacement(
                    displayID: "1",
                    displayName: "Display",
                    displayIndex: 0,
                    normalizedX: Double(index) / 100,
                    normalizedY: 0,
                    normalizedWidth: 0.5,
                    normalizedHeight: 0.5
                )
            )
        }
        UserDefaults.standard.set(
            try? JSONEncoder().encode(unbounded),
            forKey: StudioLastSessionStore.preferenceKey
        )
        #expect(StudioLastSessionStore.load().count == maximum)

        // The plan alone: a restored set past the cap is closed down to it
        // whatever the store says, and never opened beyond it.
        #expect(StudioLastSessionReconciliation.plan(saved: 35, live: 269, maximum: maximum)
            == .init(windowsToOpen: 0, windowsToClose: 269 - maximum))
        #expect(StudioLastSessionReconciliation.plan(saved: 0, live: maximum + 5, maximum: maximum)
            == .init(windowsToOpen: 0, windowsToClose: 5))
        #expect(StudioLastSessionReconciliation.plan(saved: maximum * 2, live: 1, maximum: maximum)
            == .init(windowsToOpen: maximum - 1, windowsToClose: 0))
        #expect(StudioLastSessionReconciliation.plan(saved: 3, live: 1, maximum: maximum)
            == .init(windowsToOpen: 2, windowsToClose: 0))
        #expect(StudioLastSessionReconciliation.plan(saved: 1, live: 1, maximum: maximum)
            == .init(windowsToOpen: 0, windowsToClose: 0))

        // Against real windows: the latest registered are the ones closed, and
        // they leave the coordinator so the next quit saves the cap, not the
        // inflated set.
        let coordinator = StudioWorkspaceWindowCoordinator()
        coordinator.armLastSessionRestore()
        let states = (0..<(maximum + 3)).map { _ in StudioWindowState() }
        var windows: [NSWindow] = []
        defer { states.forEach { coordinator.unregister(state: $0) } }
        for state in states {
            let window = NSWindow(
                contentRect: NSRect(x: 40, y: 50, width: 700, height: 500),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            // The coordinator closes the surplus below; Swift still holds each
            // window here, so AppKit must not release it too.
            window.isReleasedWhenClosed = false
            windows.append(window)
            coordinator.register(state: state, window: window)
        }
        #expect(coordinator.reconcileLastSessionWindows() == .init(windowsToOpen: 0, windowsToClose: 3))
        #expect(coordinator.captureWorkspace().count == maximum)
        for state in states.prefix(maximum) {
            #expect(coordinator.window(for: state) != nil)
        }
        for state in states.suffix(3) {
            #expect(coordinator.window(for: state) == nil)
        }
    }

    @Test("only windows on screen are recorded at quit")
    func quitRecordsOnlyWindowsOnScreen() {
        let saved = UserDefaults.standard.data(forKey: StudioLastSessionStore.preferenceKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: StudioLastSessionStore.preferenceKey)
            } else {
                StudioLastSessionStore.clear()
            }
        }

        let coordinator = StudioWorkspaceWindowCoordinator()
        let shown = StudioWindowState()
        let hidden = StudioWindowState()
        let window = { NSWindow(
            contentRect: NSRect(x: 40, y: 50, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        ) }
        let shownWindow = window()
        shownWindow.isReleasedWhenClosed = false
        let hiddenWindow = window()
        hiddenWindow.isReleasedWhenClosed = false
        defer {
            shownWindow.orderOut(nil)
            coordinator.unregister(state: shown)
            coordinator.unregister(state: hidden)
        }
        shownWindow.orderFront(nil)
        coordinator.register(state: shown, window: shownWindow)
        coordinator.register(state: hidden, window: hiddenWindow)
        #expect(StudioWorkspaceWindowCoordinator.isOnScreen(shownWindow))
        #expect(!StudioWorkspaceWindowCoordinator.isOnScreen(hiddenWindow))

        // A named workspace still takes every window; the last session takes
        // the ones the learner can see, so a window left ordered out — by a
        // pop-out, or by a driver — does not come back as an extra Studio.
        #expect(coordinator.captureWorkspace().count == 2)
        coordinator.saveLastSession()
        #expect(StudioLastSessionStore.load().count == 1)
    }

    @Test("FOREVERLM_LAST_SESSION=0 turns the record off for a process")
    func environmentTurnsTheRecordOff() {
        #expect(StudioLastSessionStore.isDisabled(by: ["FOREVERLM_LAST_SESSION": "0"]))
        #expect(StudioLastSessionStore.isDisabled(by: ["FOREVERLM_LAST_SESSION": " off "]))
        #expect(StudioLastSessionStore.isDisabled(by: ["FOREVERLM_LAST_SESSION": "false"]))
        #expect(!StudioLastSessionStore.isDisabled(by: ["FOREVERLM_LAST_SESSION": "1"]))
        #expect(!StudioLastSessionStore.isDisabled(by: ["FOREVERLM_LAST_SESSION": ""]))
        #expect(!StudioLastSessionStore.isDisabled(by: [:]))
    }

    @Test("a session with no windows leaves no stale arrangement behind")
    func emptySessionClearsTheStore() {
        let saved = UserDefaults.standard.data(forKey: StudioLastSessionStore.preferenceKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: StudioLastSessionStore.preferenceKey)
            } else {
                StudioLastSessionStore.clear()
            }
        }

        StudioLastSessionStore.save([
            .init(
                snapshot: StudioWindowState.Snapshot(
                    centerTabGroups: ["chat*"],
                    navigationRailVisible: true
                ),
                placement: nil
            ),
        ])
        #expect(!StudioLastSessionStore.load().isEmpty)

        // Quitting with every Studio window already closed must not put the
        // previous quit's arrangement back on the next launch.
        StudioLastSessionStore.save([])
        #expect(StudioLastSessionStore.load().isEmpty)
    }

    @Test("a window's notebook comes back with its layout, without its document, and older records hold none")
    func notebookComesBackWithItsWindow() throws {
        // A scene snapshot an older build wrote has no notebook key: it still
        // decodes, keeps its layout, and the window holds no notebook.
        let legacyJSON = #"{"centerTabGroups":["notebooks*","reader*"],"showSourcesPanel":true,"collapsedPanelIDs":["sources"],"navigationRailVisible":false}"#
        let legacy = try JSONDecoder().decode(StudioWindowState.Snapshot.self, from: Data(legacyJSON.utf8))
        #expect(legacy.notebook == nil)
        #expect(legacy.centerTabGroups == ["notebooks*", "reader*"])
        #expect(legacy.navigationRailVisible == false)
        let restoredLegacy = StudioWindowState()
        restoredLegacy.restore(from: legacyJSON)
        #expect(restoredLegacy.notebook == nil)
        #expect(restoredLegacy.snapshot == StudioWindowState(snapshot: legacy).snapshot)

        // So does a last-session record from before notebooks.
        let legacyRecord = try JSONDecoder().decode(
            StudioSavedWorkspaceWindow.self,
            from: Data(#"{"snapshot":\#(legacyJSON)}"#.utf8)
        )
        #expect(legacyRecord.snapshot == legacy)

        // A newer build's notebook, with a document and a key this build does
        // not know, still reopens, and the window keeps its layout.
        let newerJSON = #"{"centerTabGroups":["chat*"],"showSourcesPanel":true,"collapsedPanelIDs":[],"navigationRailVisible":true,"notebook":{"notebookID":"bio","document":"mindMap","pinnedOutput":"doc-1"}}"#
        let newerSnapshot = try JSONDecoder().decode(StudioWindowState.Snapshot.self, from: Data(newerJSON.utf8))
        #expect(newerSnapshot.notebook == NotebookWorkspace(notebookID: "bio"))
        #expect(newerSnapshot.centerTabGroups == ["chat*"])
        let newer = StudioWindowState()
        newer.restore(from: newerJSON)
        #expect(newer.notebook == NotebookWorkspace(notebookID: "bio"))
        #expect(newer.snapshot == StudioWindowState(snapshot: newerSnapshot).snapshot)

        // The scene snapshot carries the notebook and its arrangement, never
        // the document beside its chat; restoring it reopens the notebook.
        let source = StudioWindowState()
        source.notebook = NotebookWorkspace(
            notebookID: "bio",
            document: .reader,
            sourcesCollapsed: true,
            studioCollapsed: true
        )
        let encoded = source.encodedSnapshot()
        let decoded = try JSONDecoder().decode(StudioWindowState.Snapshot.self, from: Data(encoded.utf8))
        let kept = NotebookWorkspace(notebookID: "bio", sourcesCollapsed: true, studioCollapsed: true)
        #expect(decoded.notebook == kept)
        let relaunched = StudioWindowState()
        relaunched.restore(from: encoded)
        #expect(relaunched.notebook == kept)
        #expect(StudioWindowState(snapshot: decoded).notebook == kept)
    }

    @Test("each window of the last session comes back holding its own notebook")
    func lastSessionReopensEachWindowsNotebook() {
        let saved = UserDefaults.standard.data(forKey: StudioLastSessionStore.preferenceKey)
        // Applying a saved window writes the layout template; put it back.
        let templateKeys = [
            "studio.centerTabGroups.v1", "studio.navigationRailVisible",
        ]
        let template = templateKeys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: StudioLastSessionStore.preferenceKey)
            } else {
                StudioLastSessionStore.clear()
            }
            for (key, value) in zip(templateKeys, template) {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
        let layout = StudioWindowState.Snapshot(
            centerTabGroups: ["notebooks*", "reader*"],
            navigationRailVisible: true
        )
        var bio = layout
        bio.notebook = NotebookWorkspace(notebookID: "bio")
        var neuro = layout
        neuro.notebook = NotebookWorkspace(notebookID: "neuro", studioCollapsed: true)

        // Two windows that differ only in their notebook are two windows,
        // not one window saved twice.
        StudioLastSessionStore.save([
            .init(snapshot: bio, placement: nil),
            .init(snapshot: neuro, placement: nil),
        ])
        #expect(StudioLastSessionStore.load().map(\.snapshot.notebook?.notebookID) == ["bio", "neuro"])

        let coordinator = StudioWorkspaceWindowCoordinator()
        coordinator.armLastSessionRestore()
        let first = StudioWindowState()
        let second = StudioWindowState()
        defer {
            coordinator.unregister(state: first)
            coordinator.unregister(state: second)
        }
        let window = { NSWindow(
            contentRect: NSRect(x: 40, y: 50, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        ) }
        coordinator.register(state: first, window: window())
        coordinator.register(state: second, window: window())
        #expect(first.notebook == NotebookWorkspace(notebookID: "bio"))
        #expect(second.notebook == NotebookWorkspace(notebookID: "neuro", studioCollapsed: true))

        // A record without a notebook closes the one a reused window held.
        first.applyWorkspaceSnapshot(layout)
        #expect(first.notebook == nil)
    }
}
