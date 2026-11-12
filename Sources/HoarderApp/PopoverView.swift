import AppKit
import HoarderCore
import SwiftUI

enum Theme {
    static let dim = Color(red: 0.55, green: 0.57, blue: 0.61)
    static let amber = Color(red: 0.95, green: 0.72, blue: 0.29)
    static let green = Color(red: 0.37, green: 0.88, blue: 0.54)
    static let keep = Color(red: 0.36, green: 0.38, blue: 0.44)
    static let line = Color(white: 0.15)
    static let hover = Color(white: 0.1)

    static func color(_ verdict: Verdict) -> Color {
        switch verdict {
        case .reclaimable: green
        case .review: amber
        case .keep: keep
        }
    }
}

/// Layout A (one ledger grouped by category) with C's free-space heading and snooze.
struct PopoverView: View {
    let monitor: Monitor
    @State private var hovered: Finding.ID?
    @State private var confirming: Finding.ID?
    @State private var expanded: Set<HoarderCore.Category> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Theme.line.frame(height: 1)
            if let report = monitor.report {
                ScrollView { sections(report).padding(.vertical, 6) }
                    .frame(maxHeight: 470)
            }
            Theme.line.frame(height: 1)
            footer
        }
        .frame(width: 370)
        .background(Color.black)
        .foregroundStyle(.white)
        .font(.system(size: 13))
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(monitor.isLow ? Theme.amber : .white)
            if let report = monitor.report {
                HStack(spacing: 12) {
                    total(report.total(.reclaimable), "safe to clean", .reclaimable)
                    total(report.total(.review), "to review", .review)
                }
            } else {
                Text("Scanning. The first scan takes about a minute.").foregroundStyle(Theme.dim)
            }
            if let snoozedUntil = monitor.alertState.snoozedUntil, monitor.alertState.isSnoozed() {
                Text("Alert snoozed until \(snoozedUntil.formatted(date: .omitted, time: .shortened)) tomorrow")
                    .foregroundStyle(Theme.dim)
            }
            ForEach(problems, id: \.self) { Text($0).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true) }
        }
        .font(.system(size: 12))
        .padding(12)
    }

    private var heading: String {
        guard let disk = monitor.disk else { return "Free space unknown" }
        let free = "\(gigabytes(disk.free)) free"
        return monitor.isLow ? "\(free), under your \(monitor.config.alertBelowGB) GB limit" : free
    }

    private var problems: [String] {
        [monitor.configError, monitor.cleanError].compactMap { $0 } + (monitor.report?.notes ?? [])
    }

    private func total(_ bytes: Int64, _ label: String, _ verdict: Verdict) -> some View {
        HStack(spacing: 5) {
            Dot(verdict: verdict)
            Text("\(formatBytes(bytes)) \(Text(label).foregroundStyle(Theme.dim))").monospacedDigit()
        }
    }

    // MARK: Sections

    private func sections(_ report: Report) -> some View {
        let categories = HoarderCore.Category.allCases
            .map { ($0, actionableBytes(report, $0)) }
            .filter { category, _ in report.findings.contains { $0.category == category } }
            .sorted { $0.1 > $1.1 }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(categories, id: \.0) { category, bytes in
                section(report, category, bytes)
            }
        }
    }

    private func actionableBytes(_ report: Report, _ category: HoarderCore.Category) -> Int64 {
        report.total(.reclaimable, in: category) + report.total(.review, in: category)
    }

    @ViewBuilder
    private func section(_ report: Report, _ category: HoarderCore.Category, _ bytes: Int64) -> some View {
        let rows = report.findings.filter { $0.category == category }
        let actionable = rows.filter { $0.verdict != .keep }
        let kept = rows.filter { $0.verdict == .keep }
        let visible = expanded.contains(category) ? actionable : Array(actionable.prefix(5))

        HStack {
            Text(category.label).font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(formatBytes(bytes)).font(.system(size: 12)).foregroundStyle(Theme.dim).monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 3)

        ForEach(visible) { finding in
            FindingRow(finding: finding,
                       hovered: hovered == finding.id,
                       confirming: confirming == finding.id,
                       cleaning: monitor.cleaning.contains(finding.id),
                       onAsk: { confirming = finding.id },
                       onRun: {
                           confirming = nil
                           Task { await monitor.clean(finding) }
                       },
                       onCancel: { confirming = nil })
                .onHover { inside in
                    if inside { hovered = finding.id } else if hovered == finding.id { hovered = nil }
                }
        }

        if actionable.count > visible.count {
            Button("\(actionable.count - visible.count) more") { expanded.insert(category) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.dim)
                .font(.system(size: 12))
                .padding(.horizontal, 30)
                .padding(.vertical, 3)
        }

        if !kept.isEmpty {
            HStack(spacing: 8) {
                Dot(verdict: .keep)
                Text(kept.count == 1 ? kept[0].title : "\(kept.count) in use").lineLimit(1)
                Spacer()
                Text(formatBytes(report.total(.keep, in: category))).monospacedDigit()
            }
            .foregroundStyle(Theme.dim)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(scannedLabel(now: context.date)).foregroundStyle(Theme.dim)
            }
            Spacer()
            if monitor.isLow && !monitor.alertState.isSnoozed() {
                Button("Snooze alert 1 day") { monitor.snooze() }
            }
            Button(monitor.scanning ? "Scanning" : "Rescan") { Task { await monitor.scan() } }
                .disabled(monitor.scanning)
            Menu {
                Toggle("Open at login", isOn: Binding(get: { monitor.opensAtLogin }, set: { monitor.setOpensAtLogin($0) }))
                Button("Edit config") { monitor.editConfig() }
                Divider()
                Button("Quit Hoarder") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func scannedLabel(now: Date) -> String {
        guard let report = monitor.report else { return "Scanning" }
        if monitor.scanning { return "Rescanning" }
        if now.timeIntervalSince(report.scannedAt) < 60 { return "Scanned just now" }
        return "Scanned " + RelativeDateTimeFormatter().localizedString(for: report.scannedAt, relativeTo: now)
    }
}

struct Dot: View {
    let verdict: Verdict

    var body: some View {
        Circle().fill(Theme.color(verdict)).frame(width: 7, height: 7)
    }
}

/// One finding. Hover shows the action; clicking it asks for confirmation with the exact command
/// before anything runs.
struct FindingRow: View {
    let finding: Finding
    let hovered: Bool
    let confirming: Bool
    let cleaning: Bool
    let onAsk: () -> Void
    let onRun: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Dot(verdict: finding.verdict)
                Text("\(finding.title)  \(Text(finding.detail).font(.system(size: 11.5)).foregroundStyle(Theme.dim))")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                trailing
            }
            if confirming { confirmation }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(hovered || confirming ? Theme.hover : .clear)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var trailing: some View {
        let size = formatBytes(finding.bytes)
        if cleaning {
            Text("Cleaning").foregroundStyle(Theme.dim)
        } else if hovered && !confirming {
            if finding.cleanup != nil {
                Button("Clean \(size)", action: onAsk).buttonStyle(.plain).foregroundStyle(Theme.green)
            } else {
                Button("Show", action: reveal).buttonStyle(.plain).foregroundStyle(Theme.green)
            }
        } else {
            Text(size).monospacedDigit()
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let command = finding.cleanup {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            HStack(spacing: 14) {
                Button("Run", action: onRun).foregroundStyle(finding.verdict == .review ? Theme.amber : Theme.green)
                Button("Cancel", action: onCancel)
                if !finding.paths.isEmpty { Button("Show in Finder", action: reveal) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
        }
        .padding(.leading, 15)
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting(finding.paths.map { URL(fileURLWithPath: $0) })
    }
}
