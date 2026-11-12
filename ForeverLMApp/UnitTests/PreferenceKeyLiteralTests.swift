import Foundation
import Testing
@testable import ForeverLM

#if os(macOS)

/// The ratchet of `scripts/check_preference_keys.sh`, as a test, so a run that
/// skips the build phase still fails: no file may gain a line that reaches
/// defaults by a string key or spells a declared preference key, beyond what
/// `scripts/preference_keys_allowlist.txt` allows it today. The rules here and
/// in the script are the same, line for line; change them together.
@Suite("Preference key literals")
struct PreferenceKeyLiteralTests {

    static var appDirectory: URL { PreferenceRegistryTests.appDirectory }

    static let scannedDirectories = ["App", "Shared", "MCP", "iOS"]

    /// What reaches defaults without a typed key, as the script's awk reads it.
    struct Calls {
        let storage = try! NSRegularExpression(
            pattern: #"UserDefaults\.standard|UserDefaults\(suiteName:|PreferenceStore\.(set|remove|mirrorExternalWrite)\("#
        )
        let wrapper = try! NSRegularExpression(pattern: #"@AppStorage\("#)
        let typedWrapper = try! NSRegularExpression(pattern: #"@AppStorage\(Prefs\."#)
        let defaultsCall = try! NSRegularExpression(
            pattern: #"[Dd]efaults[?!]?\.(set|removeObject|object|string|bool|integer|double|float|data|array|stringArray|dictionary|url)\("#
        )
        let typedKey = try! NSRegularExpression(pattern: #"forKey: Prefs\."#)

        func counts(_ line: String) -> Bool {
            func has(_ regex: NSRegularExpression) -> Bool {
                regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
            }
            return has(storage) || (has(wrapper) && !has(typedWrapper)) || (has(defaultsCall) && !has(typedKey))
        }
    }

    /// The declared names and family prefixes, read out of the sources as the
    /// script reads them (the system's own prefixes are too short to scan for).
    static func declaredNames() throws -> (names: Set<String>, prefixes: [String]) {
        var names: Set<String> = []
        var prefixes: [String] = []
        for file in try PreferenceRegistryTests.declarationFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            names.formUnion(try PreferenceRegistryTests.matches(#"(?:AccountKey|DeviceKey)<[^>]*>(?:\.unread)?\("([^"]*)""#, in: text))
            if file.lastPathComponent == "Prefs+Families.swift" {
                prefixes += try PreferenceRegistryTests.matches(#"prefix: "([^"]*)""#, in: text)
            }
        }
        return (names, prefixes)
    }

    /// Lines of one file that count, by the script's rules.
    static func count(in text: String, calls: Calls, names: Set<String>, prefixes: [String]) -> Int {
        var count = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("//") { continue }
            let string = String(line)
            if calls.counts(string) {
                count += 1
                continue
            }
            guard string.contains("\"") else { continue }
            // A literal is what sits between two quotes: the even pieces of the line split at `"`.
            let pieces = string.components(separatedBy: "\"")
            var index = 1
            while index < pieces.count {
                let piece = pieces[index]
                if names.contains(piece) || prefixes.contains(where: { piece.hasPrefix($0) }) {
                    count += 1
                    break
                }
                index += 2
            }
        }
        return count
    }

    static func allowed() throws -> [String: Int] {
        let list = try String(
            contentsOf: appDirectory.appendingPathComponent("scripts/preference_keys_allowlist.txt"), encoding: .utf8
        )
        var allowed: [String: Int] = [:]
        for line in list.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, let count = Int(fields[0]) else { continue }
            allowed[String(fields[1])] = count
        }
        return allowed
    }

    @Test("No file reaches defaults by a string key more often than the ratchet list allows")
    func noFileGainsAStringKey() throws {
        let declared = try Self.declaredNames()
        #expect(declared.names.count > 300 && declared.prefixes.count > 40, "the declarations were not found from this test's path")
        let calls = Calls()
        let allowed = try Self.allowed()
        #expect(!allowed.isEmpty)

        var over: [String] = []
        var scanned = 0
        // Both sides resolved: under /tmp the walker reports /private/tmp
        // paths, and an unresolved root then cuts every name at the wrong place.
        let root = Self.appDirectory.resolvingSymlinksInPath().path + "/"
        for directory in Self.scannedDirectories {
            let base = Self.appDirectory.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walker where file.pathExtension == "swift" {
                let relative = String(file.resolvingSymlinksInPath().path.dropFirst(root.count))
                if relative.hasPrefix("Shared/Preferences/") { continue }
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                scanned += 1
                let count = Self.count(in: text, calls: calls, names: declared.names, prefixes: declared.prefixes)
                let limit = allowed[relative] ?? 0
                if count > limit {
                    over.append("\(relative): \(count) lines, \(limit) allowed")
                }
            }
        }
        #expect(scanned > 1000, "the app's sources were not found from this test's path")
        #expect(
            over.isEmpty,
            "Preference keys are declared once, under Shared/Preferences (Prefs); use the typed key instead of a string key:\n\(over.sorted().joined(separator: "\n"))"
        )
    }

    @Test("The rules count what they are meant to count")
    func rulesCountTheRightLines() throws {
        let calls = Calls()
        let names: Set<String> = ["studio.hiddenTabs"]
        let prefixes = ["aiTask."]
        func count(_ text: String) -> Int { Self.count(in: text, calls: calls, names: names, prefixes: prefixes) }

        #expect(count(#"let hidden = UserDefaults.standard.stringArray(forKey: key)"#) == 1)
        #expect(count(#"defaults.set(true, forKey: key)"#) == 1)
        #expect(count(#"override.defaults.removeObject(forKey: key)"#) == 1)
        #expect(count(#"@AppStorage(Self.widthKey) private var width = 240.0"#) == 1)
        #expect(count(#"PreferenceStore.set(order, forKey: key)"#) == 1)
        #expect(count(#"static let key = "studio.hiddenTabs""#) == 1)
        #expect(count(#"let key = "aiTask.\(task.rawValue).prompt""#) == 1)
        #expect(count(#"    // UserDefaults.standard is read here"#) == 0, "a comment line does not count")
        #expect(count(#"let title = "studio.hiddenTabs are hidden""#) == 0, "a longer literal is not the key")
        #expect(count(#"Preferences.set(order, for: Prefs.Studio.tabOrder)"#) == 0)
        #expect(count(#"@AppStorage(Prefs.Space.sidebarHidden) var hidden"#) == 0, "a typed wrapper is not a string key")
        #expect(count(#"@AppStorage(Prefs.Planner.activityPaneLayout, default: .bySource) var layout"#) == 0)
        #expect(count(#"@AppStorage(key.name) var hidden = false"#) == 1, "a wrapper on anything but a typed key still counts")
        #expect(count(#"defaults.set(rows, forKey: Prefs.Families.spacesDownloadAll.name(id))"#) == 0, "a typed key on an injected defaults is not a string key")
        #expect(count(#"defaults.set(rows, forKey: key.name)"#) == 1)
        #expect(count(#"UserDefaults.standard.set(rows, forKey: Prefs.Space.sort.name)"#) == 1, "the standard defaults still go through Preferences")
        #expect(count(#"@PreferenceStorage(Prefs.Rail.chatsExpanded) private var chatsExpanded"#) == 0)
        #expect(count("let a = defaults.bool(forKey: k)\nlet b = \"studio.hiddenTabs\"\nlet c = 1") == 2)
    }
}

#endif
