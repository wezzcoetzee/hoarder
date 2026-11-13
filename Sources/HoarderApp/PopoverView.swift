import AppKit
import HoarderCore
import SwiftUI

enum Theme {
    static let dim = Color(red: 0.55, green: 0.57, blue: 0.61)
    static let amber = Color(red: 0.95, green: 0.72, blue: 0.29)
    static let green = Color(red: 0.37, green: 0.88, blue: 0.54)
    static let red = Color(red: 1.0, green: 0.42, blue: 0.40)
    static let keep = Color(red: 0.36, green: 0.38, blue: 0.44)
    static let line = Color(white: 0.15)
    static let hover = Color(white: 0.1)
    /// Darker tints for the menu bar label when the menu bar is light.
    static let amberOnLight = Color(red: 0.6, green: 0.38, blue: 0.0)
    static let redOnLight = Color(red: 0.75, green: 0.13, blue: 0.1)

    static func color(_ verdict: Verdict) -> Color {
        switch verdict {
        case .reclaimable: green
        case .review: amber
        case .keep: keep
        }
    }
}

extension Verdict {
    /// How VoiceOver and the header name a verdict.
    var spoken: String {
        switch self {
        case .reclaimable: "safe to clean"
        case .review: "to review"
        case .keep: "in use"
        }
    }
}

/// Text buttons with a hit area larger than their glyphs.
struct TextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Layout A (one ledger grouped by category) with C's free-space heading and snooze.
struct PopoverView: View {
    let monitor: Monitor
    @State private var hovered: Finding.ID?
    @State private var confirming: Finding.ID?
    @State private var expanded: Set<HoarderCore.Category> = []
    @State private var listHeight: CGFloat = 0
    private let listCap: CGFloat

    /// The optional arguments set the starting state, for `--snapshot`.
    init(monitor: Monitor, hovered: Finding.ID? = nil, confirming: Finding.ID? = nil,
         expanded: Set<HoarderCore.Category> = [], listCap: CGFloat = 470) {
        self.monitor = monitor
        self.listCap = listCap
        _hovered = State(initialValue: hovered)
        _confirming = State(initialValue: confirming)
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Theme.line.frame(height: 1)
            if let report = monitor.report {
                // A menu bar window sizes to its content, and a ScrollView has no height of its own,
                // so the list is measured and the scroll area takes that height, up to a cap.
                ScrollViewReader { proxy in
                    ScrollView {
                        sections(report)
                            .padding(.vertical, 6)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                    }
                    .frame(height: min(listHeight, listCap))
                    .onChange(of: confirming, initial: true) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
                Theme.line.frame(height: 1)
            }
            footer
        }
        .frame(width: 370)
        .background(Color.black)
        .foregroundStyle(.white)
        .font(.system(size: 13))
        .preferredColorScheme(.dark)
        // Closing the popover drops a half-finished confirm, so it never reopens armed.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            hovered = nil
            confirming = nil
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(monitor.isCritical ? Theme.red : monitor.isLow ? Theme.amber : .white)
            if let report = monitor.report {
                let totals = [Verdict.reclaimable, .review].map { ($0, report.total($0)) }.filter { $0.1 > 0 }
                if totals.isEmpty {
                    Text("Nothing to clean").foregroundStyle(Theme.dim)
                } else {
                    HStack(spacing: 12) {
                        ForEach(totals, id: \.0) { verdict, bytes in
                            HStack(spacing: 5) {
                                Dot(verdict: verdict)
                                Text("\(formatBytes(bytes)) \(Text(verdict.spoken).foregroundStyle(Theme.dim))").monospacedDigit()
                            }
                        }
                    }
                }
            } else {
                Text("The first scan takes about a minute.").foregroundStyle(Theme.dim)
            }
            if let lastCleaned = monitor.lastCleaned {
                Text(lastCleaned).foregroundStyle(Theme.green)
            }
            if let snoozedUntil = monitor.alertState.snoozedUntil, monitor.alertState.isSnoozed() {
                Text("Alert snoozed until \(snoozedUntil.formatted(date: .omitted, time: .shortened)) tomorrow")
                    .foregroundStyle(Theme.dim)
            }
            if let appError = monitor.appError {
                Text(appError).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(monitor.report?.notes ?? [], id: \.self) {
                Text($0).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12))
        .padding(12)
    }

    private var heading: String {
        guard let disk = monitor.disk else { return "Free space unknown" }
        let free = "\(gigabytes(disk.free)) free"
        return monitor.isLow ? "\(free), under your \(monitor.config.alertBelowGB) GB limit" : free
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
        let isExpanded = expanded.contains(category)
        let visible = isExpanded ? actionable : Array(actionable.prefix(5))

        HStack {
            Text(category.label).font(.system(size: 13, weight: .semibold))
            Spacer()
            if bytes > 0 {
                Text(formatBytes(bytes)).foregroundStyle(Theme.dim).monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 3)
        .accessibilityAddTraits(.isHeader)

        ForEach(visible) { finding in
            FindingRow(finding: finding,
                       hovered: hovered == finding.id,
                       confirming: confirming == finding.id,
                       cleaning: monitor.cleaning.contains(finding.id),
                       failure: monitor.failures[finding.id],
                       onActivate: { confirming = confirming == finding.id ? nil : finding.id },
                       onRun: {
                           confirming = nil
                           Task { await monitor.clean(finding) }
                       },
                       onCancel: { confirming = nil })
                .id(finding.id)
                .onHover { inside in
                    if inside { hovered = finding.id } else if hovered == finding.id { hovered = nil }
                }
        }

        if actionable.count > 5 {
            Button(isExpanded ? "Show fewer" : "\(actionable.count - visible.count) more") {
                if isExpanded { expanded.remove(category) } else { expanded.insert(category) }
            }
            .buttonStyle(TextButtonStyle())
            .foregroundStyle(Theme.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, FindingRow.textInset - 6)
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
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(scannedLabel(now: context.date)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            .padding(.leading, 6)
            Spacer(minLength: 8)
            if monitor.isLow && !monitor.alertState.isSnoozed() {
                Button("Snooze 1 day") { monitor.snooze() }
            }
            if !monitor.scanning {
                Button("Rescan") { Task { await monitor.scan() } }
            }
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
            .padding(.horizontal, 6)
            .accessibilityLabel("Settings")
        }
        .buttonStyle(TextButtonStyle())
        .font(.system(size: 12))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private func scannedLabel(now: Date) -> String {
        guard let report = monitor.report, !monitor.scanning else { return "Scanning" }
        let minutes = Int(now.timeIntervalSince(report.scannedAt) / 60)
        switch minutes {
        case ..<1: return "Scanned just now"
        case ..<60: return "Scanned \(minutes) min ago"
        case ..<1440: return "Scanned \(minutes / 60) h ago"
        default: return "Scanned \(minutes / 1440) d ago"
        }
    }
}

/// Reclaimable is a filled dot, review a ring, keep a small dim dot: the shape carries the verdict too.
struct Dot: View {
    let verdict: Verdict

    var body: some View {
        Group {
            switch verdict {
            case .reclaimable: Circle().fill(Theme.green)
            case .review: Circle().strokeBorder(Theme.amber, lineWidth: 1.6)
            case .keep: Circle().fill(Theme.keep).padding(1)
            }
        }
        .frame(width: 7, height: 7)
        .accessibilityHidden(true)
    }
}

/// One finding. Clicking it (or hovering, which shows the action) opens a confirmation with the reason
/// and the exact command before anything runs. A row with nothing to run reveals its files instead.
struct FindingRow: View {
    /// Where row text starts: horizontal padding, dot, spacing. Lines below the title align to it.
    static let textInset: CGFloat = 12 + 7 + 8

    let finding: Finding
    let hovered: Bool
    let confirming: Bool
    let cleaning: Bool
    let failure: String?
    let onActivate: () -> Void
    let onRun: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: finding.cleanup == nil ? reveal : onActivate) {
                HStack(spacing: 8) {
                    Dot(verdict: finding.verdict)
                    Text("\(finding.title)  \(Text(finding.detail).font(.system(size: 12)).foregroundStyle(Theme.dim))")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    trailing
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(cleaning)
            .help("\(finding.title)\n\(finding.detail)")
            .accessibilityLabel("\(finding.title), \(finding.verdict.spoken), \(formatBytes(finding.bytes))")
            .accessibilityHint(finding.detail)

            if let failure {
                Text("Not cleaned: \(failure)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Self.textInset)
                    .padding(.trailing, 12)
                    .padding(.bottom, 4)
            }
            if confirming { confirmation }
        }
        .background(hovered || confirming ? Theme.hover : .clear)
    }

    @ViewBuilder
    private var trailing: some View {
        let size = formatBytes(finding.bytes)
        if cleaning {
            Text("Cleaning").foregroundStyle(Theme.dim)
        } else if hovered && !confirming {
            Text(finding.cleanup == nil ? "Show in Finder" : "Clean \(size)")
                .foregroundStyle(finding.cleanup == nil ? .white : Theme.green)
        } else {
            Text(size).monospacedDigit()
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(finding.detail)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            if let command = finding.cleanup {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 0) {
                Button("Run", action: onRun)
                    .foregroundStyle(finding.verdict == .review ? Theme.amber : Theme.green)
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if !finding.paths.isEmpty { Button("Show in Finder", action: reveal) }
            }
            .buttonStyle(TextButtonStyle())
            .font(.system(size: 12, weight: .medium))
            .padding(.leading, -6)
        }
        .padding(.leading, Self.textInset)
        .padding(.trailing, 12)
        .padding(.bottom, 8)
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting(finding.paths.map { URL(fileURLWithPath: $0) })
    }
}
