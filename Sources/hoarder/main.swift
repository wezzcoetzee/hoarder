import Foundation
import HoarderCore

let arguments = CommandLine.arguments

// `--free` is what the menu bar app asks a device every minute, so it skips the scan and the config.
if arguments.contains("--free") {
    guard let disk = DiskSpace.current() else {
        FileHandle.standardError.write(Data("Could not read free space\n".utf8))
        exit(1)
    }
    print(String(decoding: try JSONEncoder().encode(disk), as: UTF8.self))
    exit(0)
}

var config: Config
do {
    config = try Config.load()
} catch {
    FileHandle.standardError.write(Data("Invalid \(Config.fileURL.path): \(error)\n".utf8))
    exit(1)
}

// Each `--root <folder>` replaces projectRoots, so the app can scan a device's folders without editing
// that device's config.
let roots = arguments.indices.filter { arguments[$0] == "--root" && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
if !roots.isEmpty { config.projectRoots = roots }

let report = await Hoarder.scan(config: config)

if arguments.contains("--json") {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try encoder.encode(report), as: UTF8.self))
    exit(0)
}

let showCommands = arguments.contains("--commands")
let pad = { (text: String, width: Int) in text.padding(toLength: max(width, text.count), withPad: " ", startingAt: 0) }

for verdict in [Verdict.reclaimable, .review, .keep] {
    print("\n\(verdict.rawValue.uppercased())  \(formatBytes(report.total(verdict)))")
    for category in Category.allCases {
        let rows = report.findings.filter { $0.verdict == verdict && $0.category == category }
        guard !rows.isEmpty else { continue }
        print("  \(category.label)  \(formatBytes(report.total(verdict, in: category)))  (\(rows.count))")
        let limit = verdict == .keep ? 5 : 15
        for finding in rows.prefix(limit) {
            print("    \(pad(formatBytes(finding.bytes), 9))  \(pad(finding.title, 52))  \(finding.detail)")
            if showCommands, let cleanup = finding.cleanup { print("               $ \(cleanup)") }
        }
        if rows.count > limit { print("    … \(rows.count - limit) more") }
    }
}

for note in report.notes { print("\nnote: \(note)") }
print(String(format: "\nScanned in %.1fs", report.duration))
