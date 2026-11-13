import Foundation
import RRCore

let version = "0.1.0"
let usage = """
rr: say a reminder in one sentence, check the schedule, accept or reject.

Usage:
  rr "pay rent on the 1st of every month, remind me 2 days before"
  rr --dry-run "..."     show the interpretation without touching Reminders
  rr --intent FILE       use an intent JSON file instead of asking the model
  rr --show-intent "..." also print the JSON the model returned
  rr --lists             print your Reminders lists
  rr --config            print the settings in effect
  rr --set-key           store the API key in the macOS Keychain
  rr --version | --help

Nothing is created until you answer y.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("rr: " + message + "\n").utf8))
    exit(1)
}

@main
struct Command {
    // An explicit async entry point: top-level async code in main.swift crashed in release builds.
    static func main() async {
        var dryRun = false, showIntent = false, showLists = false, showConfig = false, setKey = false
        var intentFile: String?
        var words: [String] = []
        var arguments = Array(CommandLine.arguments.dropFirst())
        while !arguments.isEmpty {
            let arg = arguments.removeFirst()
            switch arg {
            case "--dry-run", "-n": dryRun = true
            case "--show-intent": showIntent = true
            case "--lists": showLists = true
            case "--config": showConfig = true
            case "--set-key": setKey = true
            case "--intent":
                guard !arguments.isEmpty else { fail("--intent needs a file") }
                intentFile = arguments.removeFirst()
            case "--version": print(version); exit(0)
            case "--help", "-h": print(usage); exit(0)
            default:
                if arg.hasPrefix("--") { fail("unknown option \(arg)\n\n\(usage)") }
                words.append(arg)
            }
        }
        let sentence = words.joined(separator: " ")

        do {
            let config = try Config.load()
            if setKey {
                print("Paste the API key for \(config.provider.rawValue) (stored as \(config.apiKeyEnv)); it is not shown.")
                guard APIKey.store(config: config) else { fail("the key was not stored") }
                print("Stored in the Keychain.")
                exit(0)
            }
            if showConfig {
                let keySource = APIKey.find(config: config)?.source.rawValue
                print("""
                config file: \(config.path)\(FileManager.default.fileExists(atPath: config.path) ? "" : " (not present; defaults)")
                provider:    \(config.provider.rawValue)
                model:       \(config.model)
                endpoint:    \(config.endpoint)
                api key:     \(keySource.map { "from the \($0)" } ?? "not set") ($\(config.apiKeyEnv), or `rr --set-key`)
                effort:      \(config.effort.isEmpty ? "(not sent)" : config.effort)
                default due time: \(config.defaultTime)
                """)
                exit(0)
            }

            // A dry run never opens Reminders, so it needs no permission and knows no list names.
            let store = dryRun ? nil : Store()
            try await store?.requestAccess()
            let lists = store?.listNames ?? []
            if showLists {
                guard store != nil else { fail("--lists cannot be combined with --dry-run") }
                print(lists.joined(separator: "\n"))
                exit(0)
            }
            guard intentFile != nil || !sentence.isEmpty else { print(usage); exit(64) }

            let now = Now()
            let intent: Intent
            if let intentFile {
                guard let data = FileManager.default.contents(atPath: intentFile) else { fail("cannot read \(intentFile)") }
                intent = try Intent.decode(json: data)
            } else {
                intent = try await extractIntent(sentence: sentence, lists: lists, today: now.day, config: config)
            }
            if showIntent {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(intent), as: UTF8.self))
            }

            let plan = try Plan(intent, now: now, defaultTime: config.defaultTime)
            let list = try store?.list(named: plan.list)
            let listName = list?.title ?? plan.list ?? "(default list)"
            print(plan.preview(listName: listName, currentYear: now.day.year, count: config.previewCount))

            guard let store, let list else { exit(0) }
            print("Create? [y/n] ", terminator: "")
            let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard answer == "y" || answer == "yes" else {
                print("Not created.")
                exit(0)
            }
            try store.create(plan, in: list)
            print("Created in \(list.title).")
        } catch {
            fail("\(error)")
        }
    }
}
