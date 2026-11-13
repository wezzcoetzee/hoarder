import AppKit
import HoarderCore
import SwiftUI

enum Theme {
    static let dim = Color(red: 0.55, green: 0.57, blue: 0.61)
    static let amber = Color(red: 0.95, green: 0.72, blue: 0.29)
    static let green = Color(red: 0.37, green: 0.88, blue: 0.54)
    static let red = Color(red: 1.0, green: 0.42, blue: 0.40)
    static let keep = Color(red: 0.45, green: 0.47, blue: 0.52)
    static let keptTitle = Color(white: 0.72)
    static let command = Color(white: 0.8)
    static let line = Color(white: 0.15)
    static let hover = Color(white: 0.07)
    static let panel = Color(white: 0.12)
    /// Darker tints for the menu bar label when the menu bar is light.
    static let amberOnLight = Color(red: 0.5, green: 0.3, blue: 0.0)
    static let redOnLight = Color(red: 0.62, green: 0.08, blue: 0.06)

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

/// Text buttons with a hit area larger than their glyphs, at least 24pt tall.
struct TextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Layout A (one ledger grouped by category) with C's free-space heading and snooze.
struct PopoverView: View {
    let monitor: Monitor
    @State private var hovered: Finding.ID?
    @State private var confirming: Finding.ID?
    /// The open row's verdict and command when it was opened, to notice a scan changing them.
    @State private var confirmedAs: String?
    @State private var expanded: Set<HoarderCore.Category> = []
    @State private var showingKept: Set<HoarderCore.Category> = []
    @State private var listHeight: CGFloat = 0
    private let listCap: CGFloat

    /// Rows a section shows before "N more".
    private static let visibleRows = 5

    /// The optional arguments set the starting state, for `--snapshot`.
    init(monitor: Monitor, hovered: Finding.ID? = nil, confirming: Finding.ID? = nil,
         expanded: Set<HoarderCore.Category> = [], showingKept: Set<HoarderCore.Category> = [],
         listCap: CGFloat = 470) {
        self.monitor = monitor
        self.listCap = listCap
        _hovered = State(initialValue: hovered)
        _confirming = State(initialValue: confirming)
        _expanded = State(initialValue: expanded)
        _showingKept = State(initialValue: showingKept)
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
                        // On the next turn, once the panel has its height, so Run lands in view.
                        if let id { DispatchQueue.main.async { proxy.scrollTo(id) } }
                    }
                    // And again once the list has grown by the panel, which is when its height is final.
                    .onChange(of: listHeight) {
                        if let confirming { proxy.scrollTo(confirming) }
                    }
                    // A new scan can drop the row a panel was opened on, or change its verdict or
                    // command; close the panel then, so Run never acts on what was not shown.
                    .onChange(of: report.scannedAt) {
                        let row = report.findings.first { $0.id == confirming }
                        if row.map(Self.signature) != confirmedAs { confirming = nil }
                    }
                }
                Theme.line.frame(height: 1)
            }
            footer
        }
        .frame(width: 400)
        .background(Color.black)
        .foregroundStyle(.white)
        .font(.system(size: 13))
        .preferredColorScheme(.dark)
        // Closing the popover drops a half-finished confirm, so it never reopens armed, and retires
        // the success line, which has been seen.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            hovered = nil
            confirming = nil
            monitor.dismissCleaned()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading)
                .font(.system(size: 16, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
                .foregroundStyle(monitor.isCritical ? Theme.red : monitor.isLow ? Theme.amber : .white)
            if let report = monitor.report {
                let totals = [Verdict.reclaimable, .review].map { ($0, report.total($0)) }.filter { $0.1 > 0 }
                if totals.isEmpty {
                    Text("Nothing to clean").foregroundStyle(Theme.dim)
                } else {
                    HStack(spacing: 12) {
                        ForEach(totals, id: \.0) { verdict, bytes in
                            HStack(spacing: 8) {
                                Dot(verdict: verdict)
                                Text("\(Text(formatBytes(bytes)).font(.system(size: 13))) \(Text(verdict.spoken).foregroundStyle(Theme.dim))")
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            } else {
                Text("The first scan takes about a minute").foregroundStyle(Theme.dim)
            }
            if let lastCleaned = monitor.lastCleaned {
                Text(lastCleaned).foregroundStyle(Theme.green)
            }
            if monitor.isLow, let snoozedUntil = monitor.alertState.snoozedUntil, monitor.alertState.isSnoozed() {
                let day = Calendar.current.isDateInToday(snoozedUntil) ? "today" : "tomorrow"
                Text("Alert snoozed until \(snoozedUntil.formatted(date: .omitted, time: .shortened)) \(day)")
                    .foregroundStyle(Theme.dim)
            }
            if monitor.isLow && monitor.notificationsOff {
                HStack(spacing: 0) {
                    Text("Notifications are off").foregroundStyle(Theme.dim)
                    Button("Open Settings") { NSWorkspace.shared.open(Notifier.settingsURL) }
                        .buttonStyle(TextButtonStyle())
                }
                .padding(.vertical, -5)
            }
            ForEach([monitor.configError, monitor.loginError].compactMap { $0 }, id: \.self) {
                Text($0).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
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
        return freeSpace(disk.free, limitGB: monitor.config.alertBelowGB, low: monitor.isLow)
    }

    // MARK: Sections

    /// Sections with the most that is safe to clean come first, so the top section is where to start.
    /// Docker goes last: its prunes free space inside Docker's disk, not on the Mac right away.
    private func sections(_ report: Report) -> some View {
        let categories = HoarderCore.Category.allCases
            .filter { category in report.findings.contains { $0.category == category } }
            .map { ($0, report.total(.reclaimable, in: $0), report.total(.review, in: $0)) }
            .sorted { ($0.0 == .docker ? 0 : 1, $0.1, $0.2) > ($1.0 == .docker ? 0 : 1, $1.1, $1.2) }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(categories, id: \.0) { category, safe, review in
                section(report, category, safe + review)
            }
        }
    }

    @ViewBuilder
    private func section(_ report: Report, _ category: HoarderCore.Category, _ bytes: Int64) -> some View {
        let rows = report.findings.filter { $0.category == category }
        let actionable = rows.filter { $0.verdict != .keep }
        let kept = rows.filter { $0.verdict == .keep }
        let isExpanded = expanded.contains(category)
        let visible = isExpanded ? actionable : Array(actionable.prefix(Self.visibleRows))

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

        ForEach(visible) { row($0) }

        if actionable.count > Self.visibleRows {
            Button {
                if isExpanded {
                    expanded.remove(category)
                    let shown = Set(actionable.prefix(Self.visibleRows).map(\.id))
                    if let confirming, !shown.contains(confirming), actionable.contains(where: { $0.id == confirming }) {
                        self.confirming = nil
                    }
                } else {
                    expanded.insert(category)
                }
            } label: {
                Text(isExpanded ? "Show fewer" : "\(actionable.count - visible.count) more")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(TextButtonStyle())
            .foregroundStyle(Theme.dim)
            .padding(.leading, FindingRow.textInset - 6)
            .accessibilityLabel(isExpanded ? "Show fewer in \(category.label)" : "\(actionable.count - visible.count) more in \(category.label)")
        }

        if kept.count == 1 {
            row(kept[0])
        } else if !kept.isEmpty {
            keptSummary(report, category, count: kept.count)
            if showingKept.contains(category) { ForEach(kept) { row($0) } }
        }
    }

    private func row(_ finding: Finding) -> some View {
        FindingRow(finding: finding,
                   hovered: hovered == finding.id,
                   confirming: confirming == finding.id,
                   cleaning: monitor.cleaning.contains(finding.id),
                   failure: monitor.failures[finding.id],
                   onActivate: {
                       if confirming == finding.id {
                           confirming = nil
                       } else {
                           confirming = finding.id
                           confirmedAs = Self.signature(finding)
                       }
                   },
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

    private static func signature(_ finding: Finding) -> String {
        "\(finding.verdict.rawValue)|\(finding.cleanup ?? "")"
    }

    /// "5 in use" with their total. Clicking lists them, each with why it is kept.
    private func keptSummary(_ report: Report, _ category: HoarderCore.Category, count: Int) -> some View {
        let showing = showingKept.contains(category)
        return Button {
            if showing { showingKept.remove(category) } else { showingKept.insert(category) }
        } label: {
            HStack(spacing: 8) {
                Text(showing ? "Hide \(count) in use" : "\(count) in use").lineLimit(1)
                Spacer()
                Text(formatBytes(report.total(.keep, in: category))).monospacedDigit()
            }
            .foregroundStyle(Theme.dim)
            .padding(.leading, FindingRow.textInset)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) in use in \(category.label), \(formatBytes(report.total(.keep, in: category)))")
        .accessibilityHint(showing ? "Hides them" : "Lists them with why each is kept")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(scannedLabel(now: context.date)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            .padding(.leading, 6)
            Spacer(minLength: 8)
            // Only once an alert was sent: before that there is nothing to snooze.
            if monitor.isLow && monitor.alertState.alerted && !monitor.alertState.isSnoozed() && !monitor.notificationsOff {
                Button("Snooze 1 day") { monitor.snooze() }
                    .accessibilityLabel("Snooze low-disk alert for 1 day")
                    .accessibilityInputLabels(["Snooze"])
            }
            // "Scanning" takes Rescan's slot, so nothing slides under the cursor.
            ZStack {
                Button("Rescan") { Task { await monitor.scan() } }
                    .keyboardShortcut("r")
                    .opacity(monitor.scanning ? 0 : 1)
                    .disabled(monitor.scanning)
                    .accessibilityHidden(monitor.scanning)
                Text("Scanning")
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .opacity(monitor.scanning ? 1 : 0)
                    .accessibilityHidden(!monitor.scanning)
            }
            Menu {
                Button("Alert under \(monitor.config.alertBelowGB) GB") {}.disabled(true)
                Toggle("Open at login", isOn: Binding(get: { monitor.opensAtLogin }, set: { monitor.setOpensAtLogin($0) }))
                Button("Edit config") { monitor.editConfig() }
                Divider()
                Button("Quit Hoarder") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Settings")
        }
        .buttonStyle(TextButtonStyle())
        .font(.system(size: 12))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private func scannedLabel(now: Date) -> String {
        guard let report = monitor.report else { return "" }
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

/// One finding. Clicking it opens a panel with the full reason, and for a cleanable row the exact
/// command and Run; hover shows "Clean" on rows that can be cleaned. Kept rows never offer cleaning.
struct FindingRow: View {
    /// Where row text starts: horizontal padding, dot, spacing. Lines below the title align to it.
    static let textInset: CGFloat = 12 + 7 + 8
    private static let commandCap: CGFloat = 120

    let finding: Finding
    let hovered: Bool
    let confirming: Bool
    let cleaning: Bool
    let failure: String?
    let onActivate: () -> Void
    let onRun: () -> Void
    let onCancel: () -> Void

    @AccessibilityFocusState private var panelFocused: Bool

    private var cleanable: Bool { finding.verdict != .keep && finding.cleanup != nil }
    private var kept: Bool { finding.verdict == .keep }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onActivate) { line }
                .buttonStyle(.plain)
                .allowsHitTesting(!cleaning)
                .help("\(finding.title)\n\(finding.detail)")
                .accessibilityLabel("\(finding.title), \(finding.verdict.spoken), \(formatBytes(finding.bytes)), \(finding.detail)")
                .accessibilityValue(cleaning ? "cleaning" : failure.map { "not cleaned, \($0)" } ?? "")
                .accessibilityHint(cleanable ? "Shows the cleanup command" : "Shows where it is")

            if let failure {
                Text("Not cleaned: \(failure)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(failure)
                    .padding(.leading, Self.textInset)
                    .padding(.trailing, 12)
                    .padding(.bottom, 4)
            }
            if confirming { panel }
        }
        .background(confirming ? Theme.panel : hovered ? Theme.hover : .clear)
    }

    private var line: some View {
        HStack(alignment: .top, spacing: 8) {
            Dot(verdict: finding.verdict).padding(.top, 5)
            Group {
                if confirming {
                    title.lineLimit(2)
                } else {
                    // The reason shows whole: beside the title when it fits, otherwise under it.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            title.fixedSize()
                            reason.fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            title.lineLimit(1)
                            reason.fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// The title gives way in the middle, so a branch keeps its distinctive end.
    private var title: some View {
        Text(finding.title)
            .foregroundStyle(kept ? Theme.keptTitle : .white)
            .truncationMode(.middle)
    }

    /// While cleaning, the reason's place says so, and the size stays put.
    private var reason: some View {
        Text(cleaning ? "Cleaning" : finding.detail)
            .font(.system(size: 12))
            .foregroundStyle(Theme.dim)
    }

    /// The size, or "Clean" on hover over a cleanable row, laid out under the size so the row never
    /// reflows.
    private var trailing: some View {
        let showAction = cleanable && hovered && !confirming && !cleaning
        return ZStack(alignment: .trailing) {
            Text(formatBytes(finding.bytes))
                .monospacedDigit()
                .foregroundStyle(cleaning || kept || finding.bytes == 0 ? Theme.dim : .white)
                .opacity(showAction ? 0 : 1)
            if cleanable {
                Text("Clean").foregroundStyle(Theme.color(finding.verdict)).opacity(showAction ? 1 : 0)
            }
        }
        .accessibilityHidden(true)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(finding.detail)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            if cleanable, finding.category == .worktree, finding.cleanup?.contains("worktree remove") == true {
                Text("Removes the folder; the branch and its commits stay")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
            }
            if cleanable, finding.category == .docker {
                Text("Frees space inside Docker's disk; the Mac gets it back as the VM trims")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if cleanable, let command = finding.cleanup {
                // A many-folder command scrolls in a capped box, so Run stays in view. A hidden copy
                // sizes the box in the same layout pass; the scroll view is laid over it.
                let text = Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                text.hidden()
                    .frame(maxHeight: Self.commandCap, alignment: .top)
                    .overlay {
                        ScrollView { text.foregroundStyle(Theme.command).textSelection(.enabled) }
                    }
            }
            HStack(spacing: 0) {
                if cleanable && !cleaning {
                    Button("Run ↩", action: onRun)
                        .foregroundStyle(Theme.color(finding.verdict))
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel("Run cleanup for \(finding.title)")
                        .accessibilityInputLabels(["Run", "Run cleanup"])
                        .accessibilityFocused($panelFocused)
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Close", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityFocused($panelFocused)
                }
                if !finding.paths.isEmpty { Button("Show in Finder", action: reveal) }
            }
            .buttonStyle(TextButtonStyle())
            .font(.system(size: 12))
            .padding(.leading, -6)
        }
        .padding(.leading, Self.textInset)
        .padding(.trailing, 12)
        .padding(.bottom, 8)
        .onAppear { panelFocused = true }
    }

    private func reveal() {
        // One item: a many-folder row would otherwise open a Finder window per folder.
        guard let first = finding.paths.first else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first)])
    }
}
