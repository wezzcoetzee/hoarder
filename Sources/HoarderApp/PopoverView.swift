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
    /// "Clean all safe" was pressed and waits for Run.
    @State private var confirmingSafe = false
    /// The open row's verdict and command when it was opened, to notice a scan changing them.
    @State private var confirmedAs: String?
    /// A panel just opened and should be scrolled into view once the list has grown to fit it.
    @State private var revealPending = false
    /// A section header to scroll back to after "Show fewer" collapses a long section.
    @State private var scrollTarget: String?
    @State private var expanded: Set<HoarderCore.Category> = []
    @State private var showingKept: Set<HoarderCore.Category> = []
    @State private var listHeight: CGFloat = 0
    private let listCap: CGFloat

    /// Rows a section shows before "N more".
    private static let visibleRows = 5

    /// The optional arguments set the starting state, for `--snapshot`.
    init(monitor: Monitor, hovered: Finding.ID? = nil, confirming: Finding.ID? = nil, confirmingSafe: Bool = false,
         expanded: Set<HoarderCore.Category> = [], showingKept: Set<HoarderCore.Category> = [],
         listCap: CGFloat = 470) {
        self.monitor = monitor
        self.listCap = listCap
        _hovered = State(initialValue: hovered)
        _confirming = State(initialValue: confirming)
        _confirmingSafe = State(initialValue: confirmingSafe)
        _revealPending = State(initialValue: confirming != nil)
        _expanded = State(initialValue: expanded)
        _showingKept = State(initialValue: showingKept)
    }

    /// The device the popover shows. With no devices configured it is always this Mac and the strip
    /// is hidden, so the popover looks as it did before devices existed.
    private var machine: Machine { monitor.selected }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if monitor.machines.count > 1 {
                deviceStrip
                Theme.line.frame(height: 1)
            }
            header
            Theme.line.frame(height: 1)
            if let report = machine.report {
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
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else { return }
                        proxy.scrollTo(target, anchor: .top)
                        scrollTarget = nil
                    }
                    // And once more when the list has grown by the panel, which is when its height is
                    // final. Only once, so expanding a section later never jumps back to the panel.
                    .onChange(of: listHeight) {
                        guard revealPending, let confirming else { return }
                        proxy.scrollTo(confirming)
                        revealPending = false
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
            confirmingSafe = false
            monitor.dismissCleaned()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading)
                .font(.system(size: 16, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
                .foregroundStyle(machine.isCritical ? Theme.red : machine.isLow ? Theme.amber : .white)
            if let report = machine.report {
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
                                    .fixedSize()
                            }
                        }
                        Spacer(minLength: 0)
                        cleanSafeButton
                    }
                    cleanSafeConfirm
                }
            } else {
                Text("The first scan takes about a minute").foregroundStyle(Theme.dim)
            }
            ForEach(machine.cleaning.values.sorted(), id: \.self) {
                Text("Cleaning \($0)").foregroundStyle(Theme.dim)
            }
            if let lastCleaned = machine.lastCleaned {
                Text(lastCleaned).foregroundStyle(Theme.green)
            }
            if let lastFailed = machine.lastFailed {
                Text(lastFailed).foregroundStyle(Theme.red)
            }
            if let snoozedUntil = machine.alertState.snoozedUntil, machine.alertState.isSnoozed() {
                let day = Calendar.current.isDateInToday(snoozedUntil) ? "today" : "tomorrow"
                HStack(spacing: 0) {
                    Text("Alert snoozed until \(snoozedUntil.formatted(date: .omitted, time: .shortened)) \(day)")
                        .foregroundStyle(Theme.dim)
                    // ⌘S, like Snooze, which takes its place again once unsnoozed.
                    Button("Unsnooze") { machine.unsnooze() }
                        .buttonStyle(TextButtonStyle())
                        .keyboardShortcut("s")
                        .help("Unsnooze the low-disk alert (⌘S)")
                        .accessibilityLabel("Unsnooze low-disk alert")
                }
                .padding(.vertical, -5)
            }
            if machine.isLow && monitor.notificationsOff {
                HStack(spacing: 0) {
                    Text("Notifications are off").foregroundStyle(Theme.dim)
                    Button("Open Settings") { NSWorkspace.shared.open(Notifier.settingsURL) }
                        .buttonStyle(TextButtonStyle())
                }
                .padding(.vertical, -5)
            }
            ForEach([machine.problem, monitor.configError, monitor.loginError].compactMap { $0 }, id: \.self) {
                Text($0).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(machine.report?.notes ?? [], id: \.self) {
                Text($0).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12))
        .padding(12)
    }

    /// "Clean all safe" beside the totals, then a line under them saying what Run does. Hidden while
    /// anything is cleaning.
    @ViewBuilder
    private var cleanSafeButton: some View {
        if !confirmingSafe && !machine.safeToClean.isEmpty && machine.cleaning.isEmpty {
            Button {
                confirming = nil
                confirmingSafe = true
            } label: {
                // The totals keep their line; the label shortens when they are wide.
                ViewThatFits { Text("Clean all safe"); Text("Clean safe") }
            }
            .buttonStyle(TextButtonStyle())
            .foregroundStyle(Theme.green)
            .accessibilityHint("Asks before running \(machine.safeToClean.count) cleanups")
            .padding(.vertical, -5)
            .padding(.trailing, -6)
        }
    }

    @ViewBuilder
    private var cleanSafeConfirm: some View {
        let count = machine.safeToClean.count
        if confirmingSafe && count > 0 && machine.cleaning.isEmpty {
            HStack(spacing: 0) {
                Text("Runs all \(count) green rows, one at a time").foregroundStyle(Theme.dim)
                Spacer(minLength: 8)
                Button {
                    confirmingSafe = false
                    Task { await machine.cleanSafe() }
                } label: { Text("Run \(Image(systemName: "return"))") }
                    .foregroundStyle(Theme.green)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Run all \(count) safe cleanups")
                Button("Cancel") { confirmingSafe = false }
                    .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(TextButtonStyle())
            .padding(.vertical, -5)
            .padding(.trailing, -6)
        }
    }

    // MARK: Devices

    /// One cell per machine, each with its free space. ⌘1 to ⌘9 pick them in order.
    private var deviceStrip: some View {
        HStack(spacing: 0) {
            ForEach(Array(monitor.machines.enumerated()), id: \.element.id) { index, device in
                let on = device.id == machine.id
                if index > 0 { Theme.line.frame(width: 1) }
                Button { select(device) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Text(Self.status(device)).foregroundStyle(Self.statusColor(device)).monospacedDigit().lineLimit(1)
                    }
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(on ? Theme.panel : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)"))) : nil)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityLabel("\(device.name), \(Self.status(device))")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A device that answered once keeps its last free space, in red while its header says what is wrong.
    private static func status(_ device: Machine) -> String {
        guard let disk = device.disk else {
            return device.problem != nil ? "unreachable" : device.scanning ? "connecting" : "checking"
        }
        return "\(gigabytes(disk.free)) free"
    }

    private static func statusColor(_ device: Machine) -> Color {
        if device.problem != nil || device.isCritical { return Theme.red }
        return device.isLow ? Theme.amber : Theme.dim
    }

    /// Open panels, hover and expanded sections belong to the device they were opened on.
    private func select(_ device: Machine) {
        guard device.id != monitor.selectedID else { return }
        monitor.selectedID = device.id
        hovered = nil
        confirming = nil
        confirmingSafe = false
        expanded = []
        showingKept = []
    }

    private var heading: String {
        guard let disk = machine.disk else { return "Free space unknown" }
        return freeSpace(disk.free, limitGB: machine.alertBelowGB, low: machine.isLow)
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
        let hiddenBytes = actionable.dropFirst(Self.visibleRows).reduce(0) { $0 + $1.bytes }

        HStack {
            Text(category.label).font(.system(size: 13, weight: .semibold))
            Spacer()
            if bytes > 0 {
                Text(formatBytes(bytes)).foregroundStyle(Theme.dim).monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 3)
        .accessibilityAddTraits(.isHeader)
        .id(Self.sectionID(category))

        ForEach(visible) { row($0) }

        if actionable.count > Self.visibleRows {
            Button {
                if isExpanded {
                    expanded.remove(category)
                    let shown = Set(actionable.prefix(Self.visibleRows).map(\.id))
                    if let confirming, !shown.contains(confirming), actionable.contains(where: { $0.id == confirming }) {
                        self.confirming = nil
                    }
                    scrollTarget = Self.sectionID(category)
                } else {
                    expanded.insert(category)
                }
            } label: {
                HStack {
                    Text(isExpanded ? "Show fewer" : "\(actionable.count - visible.count) more")
                    Spacer()
                    if !isExpanded { Text(formatBytes(hiddenBytes)).monospacedDigit() }
                }
            }
            .buttonStyle(TextButtonStyle())
            .foregroundStyle(Theme.dim)
            .padding(.leading, FindingRow.textInset - 6)
            .padding(.trailing, 6)
            .accessibilityLabel(isExpanded ? "Show fewer in \(category.label)"
                                : "\(actionable.count - visible.count) more in \(category.label), \(formatBytes(hiddenBytes))")
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
                   host: machine.host,
                   dockerInVM: machine.dockerInVM,
                   hovered: hovered == finding.id,
                   confirming: confirming == finding.id,
                   cleaning: machine.cleaning[finding.id] != nil,
                   failure: machine.failures[finding.id],
                   onActivate: {
                       if confirming == finding.id {
                           confirming = nil
                       } else {
                           confirming = finding.id
                           confirmingSafe = false
                           confirmedAs = Self.signature(finding)
                           revealPending = true
                       }
                   },
                   onRun: {
                       confirming = nil
                       Task { await machine.clean(finding) }
                   },
                   onCancel: { confirming = nil })
            .id(finding.id)
            .onHover { inside in
                if inside { hovered = finding.id } else if hovered == finding.id { hovered = nil }
            }
    }

    private static func sectionID(_ category: HoarderCore.Category) -> String { "section-\(category.rawValue)" }

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
            if machine.isLow && machine.alertState.alerted && !machine.alertState.isSnoozed() && !monitor.notificationsOff {
                Button("Snooze 1 day") { machine.snooze() }
                    .keyboardShortcut("s")
                    .help("Snooze the low-disk alert for 1 day (⌘S)")
                    .accessibilityLabel("Snooze low-disk alert for 1 day")
                    .accessibilityInputLabels(["Snooze"])
            }
            // "Scanning" takes Rescan's slot, so nothing slides under the cursor.
            ZStack {
                Button("Rescan") { Task { await monitor.scan() } }
                    .keyboardShortcut("r")
                    .help("Rescan (⌘R)")
                    .opacity(machine.scanning ? 0 : 1)
                    .disabled(machine.scanning)
                    .accessibilityHidden(machine.scanning)
                Text("Scanning")
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .opacity(machine.scanning ? 1 : 0)
                    .accessibilityHidden(!machine.scanning)
            }
            Menu {
                Button("Alert under \(machine.alertBelowGB) GB") {}.disabled(true)
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
        guard let report = machine.report else { return "" }
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

/// One finding. Clicking it opens a panel with the full reason, and for a row with a command the exact
/// command and Run; hover shows "Clean" on those rows. Kept rows can be cleaned too: grey when nothing
/// is lost, red with a warning when the command forces past uncommitted changes or a lock.
struct FindingRow: View {
    /// Where row text starts: horizontal padding, dot, spacing. Lines below the title align to it.
    static let textInset: CGFloat = 12 + 7 + 8
    private static let commandCap: CGFloat = 120

    let finding: Finding
    /// The device the command runs on over SSH; nil for this Mac.
    let host: String?
    let dockerInVM: Bool
    let hovered: Bool
    let confirming: Bool
    let cleaning: Bool
    let failure: String?
    let onActivate: () -> Void
    let onRun: () -> Void
    let onCancel: () -> Void

    @AccessibilityFocusState private var panelFocused: Bool
    @AccessibilityFocusState private var rowFocused: Bool

    private var cleanable: Bool { finding.cleanup != nil }
    private var kept: Bool { finding.verdict == .keep }

    /// Another device's command, as the SSH hop that runs it there.
    private var displayedCommand: String? {
        guard let command = finding.cleanup else { return nil }
        return host.map { "ssh \($0) \(shellQuote(command))" } ?? command
    }

    /// What forcing loses, when the command forces git past what made the row kept.
    private var forceWarning: String? {
        guard let command = finding.cleanup else { return nil }
        if command.contains("worktree remove -f -f") { return "Ignores the lock and deletes any uncommitted changes; not undoable" }
        if command.contains("worktree remove --force") { return "Deletes the uncommitted changes; not undoable" }
        return nil
    }

    /// Clean and Run: the verdict's colour, grey on a kept row, red when the command forces.
    private var actionColor: Color {
        forceWarning != nil ? Theme.red : kept ? Theme.keptTitle : Theme.color(finding.verdict)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onActivate) { line }
                .buttonStyle(.plain)
                .allowsHitTesting(!cleaning)
                .help("\(finding.title)\n\(finding.detail)")
                .accessibilityLabel("\(finding.title), \(finding.verdict.spoken), \(formatBytes(finding.bytes)), \(finding.detail)")
                .accessibilityValue(cleaning ? "cleaning" : failure.map { "not cleaned, \($0)" } ?? "")
                .accessibilityHint(cleanable ? "Shows the cleanup command" : "Shows where it is")
                .accessibilityFocused($rowFocused)

            if let failure {
                Text("Not cleaned: \(failure)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(failure)
                    .accessibilityHidden(true)
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
                    // Open: the closed two-line layout, title wrapping, so the reason stays with it.
                    VStack(alignment: .leading, spacing: 1) {
                        title.lineLimit(2)
                        reason.fixedSize(horizontal: false, vertical: true)
                    }
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
            .foregroundStyle(cleaning ? Theme.color(finding.verdict) : Theme.dim)
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
                Text("Clean").foregroundStyle(actionColor).opacity(showAction ? 1 : 0)
            }
        }
        .accessibilityHidden(true)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if cleanable, finding.cleanup?.hasPrefix("docker volume prune") == true {
                Text("Deletes the volumes' data; not undoable")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.amber)
            }
            if cleanable, let forceWarning {
                Text(forceWarning)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if cleanable, finding.category == .worktree, finding.cleanup?.contains("worktree remove") == true {
                Text("Removes the folder; the branch and its commits stay")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
            }
            if cleanable, finding.category == .docker, dockerInVM {
                Text("Frees space in Docker's disk; the Mac gets it back later")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if cleanable, let command = displayedCommand {
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
                    Button(action: onRun) { Text("Run \(Image(systemName: "return"))") }
                        .foregroundStyle(actionColor)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel("Run cleanup for \(finding.title)")
                        .accessibilityInputLabels(["Run", "Run cleanup"])
                        .accessibilityFocused($panelFocused)
                    Button("Cancel", action: close)
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Close", action: close)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityFocused($panelFocused)
                }
                // Orphaned worktrees list folders that are already gone, and another device's paths are not here.
                if host == nil, let first = finding.paths.first, exists(atPath: first) {
                    Button("Show in Finder", action: reveal)
                }
            }
            .buttonStyle(TextButtonStyle())
            .font(.system(size: 12))
            .padding(.leading, -6)
            .padding(.top, -3)
        }
        .padding(.leading, Self.textInset)
        .padding(.trailing, 12)
        .padding(.bottom, 4)
        .onAppear { panelFocused = true }
    }

    /// VoiceOver goes back to the row only when the user closes its panel, not when opening another
    /// row closes it, so two rows never ask for focus at once.
    private func close() {
        onCancel()
        rowFocused = true
    }

    private func exists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private func reveal() {
        // One item: a many-folder row would otherwise open a Finder window per folder.
        guard let first = finding.paths.first else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first)])
    }
}
