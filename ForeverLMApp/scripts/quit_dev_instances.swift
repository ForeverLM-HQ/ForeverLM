#!/usr/bin/env swift
import AppKit

// Quit every running ForeverLM Dev instance — installed, DerivedData, or worktree —
// before build_dev.sh launches the freshly installed copy. Otherwise `open` would
// only bring an old instance forward, and each verification run would leave one
// more Dev app in the Dock. The Dock's own Quit is sent first (a quit Apple Event
// through NSRunningApplication.terminate), so the app goes through its normal
// termination and saves nothing that would restore a pile of windows on the next
// launch; a copy that ignores it for `timeout` seconds is force-terminated.
//
// Usage: swift quit_dev_instances.swift [bundle-id] [timeout-seconds]

let bundleID = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "com.foreverlm.dev"
let timeout = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 15 : 15

var running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
guard !running.isEmpty else { exit(0) }

for app in running {
    let path = app.bundleURL?.path ?? "?"
    print("  quitting pid \(app.processIdentifier) \(path)")
    app.terminate()
}

let deadline = Date().addingTimeInterval(timeout)
while Date() < deadline {
    running.removeAll { $0.isTerminated }
    if running.isEmpty { exit(0) }
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
}

for app in running where !app.isTerminated {
    print("  pid \(app.processIdentifier) ignored Quit for \(Int(timeout))s; force-terminating")
    app.forceTerminate()
}
RunLoop.current.run(until: Date().addingTimeInterval(1))
exit(running.allSatisfy { $0.isTerminated } ? 0 : 1)
