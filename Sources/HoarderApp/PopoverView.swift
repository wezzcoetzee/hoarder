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

/// "a", "a and b", "a, b and c".
func listed(_ items: [String]) -> String {
    guard let last = items.last, items.count > 1 else { return items.first ?? "" }
    return items.dropLast().joined(separator: ", ") + " and " + last
}

extension HoarderCore.Category {
    /// The category mid-sentence, as in the first scan's progress line.
    var inSentence: String {
        switch self {
        case .worktree: "worktrees"
        case .nodeModules: "node_modules"
        case .docker: "Docker"
        case .cache: "caches"
        }
    }

    /// One row's kind, beside its title in Clean safe's checklist.
    var singular: String {
        switch self {
        case .worktree: "worktree"
        case .nodeModules: "node_modules"
        case .docker: "Docker"
        case .cache: "cache"
        }
    }
}

/// Starts Docker Desktop on this Mac, for Open Docker beside "Docker is not running". Nil when it is not
/// installed: OrbStack, colima and the rest start their own way, and no button beats a wrong one.
@MainActor
func openDocker() -> (() -> Void)? {
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.docker.docker") else { return nil }
    return { NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) }
}

/// A command as it runs: another device's goes over SSH.
func runnableCommand(_ command: String, on host: String?) -> String {
    host.map { "ssh \($0) \(shellQuote(command))" } ?? command
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

/// One ledger: the device strip or picker, the balance (free space, the sum, Clean safe), then rows
/// grouped by category. DESIGN.md describes each part.
struct PopoverView: View {
    let monitor: Monitor
    @Environment(\.openSettings) private var openSettings
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
    @State private var checklistHeight: CGFloat = 0
    /// Clean safe's checklist shows each row's command.
    @State private var showingCommands = false
    /// The row the arrow keys last moved to, so the list scrolls it into view; the highlight itself is
    /// `hovered`, the same tone the pointer gives.
    @State private var keyboardRow: Finding.ID?
    @FocusState private var keyboardFocus: Bool
    private let listCap: CGFloat

    /// Rows a section shows before "N more".
    private static let visibleRows = 5

    /// The optional arguments set the starting state, for `--snapshot`.
    init(
        monitor: Monitor, hovered: Finding.ID? = nil, keyboard: Finding.ID? = nil, confirming: Finding.ID? = nil,
        confirmingSafe: Bool = false, showingCommands: Bool = false, expanded: Set<HoarderCore.Category> = [],
        showingKept: Set<HoarderCore.Category> = [], listCap: CGFloat = 470
    ) {
        self.monitor = monitor
        self.listCap = listCap
        _hovered = State(initialValue: keyboard ?? hovered)
        _keyboardRow = State(initialValue: keyboard)
        _confirming = State(initialValue: confirming)
        _confirmingSafe = State(initialValue: confirmingSafe)
        _showingCommands = State(initialValue: showingCommands)
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
            // An empty report has no list, so the header's rule meets the footer's without a gap between.
            if let report = machine.report, !report.findings.isEmpty {
                // A menu bar window sizes to its content, and a ScrollView has no height of its own,
                // so the list is measured and the scroll area takes that height, up to a cap.
                ScrollViewReader { proxy in
                    ScrollView {
                        sections(report)
                            .padding(.vertical, 6)
                            .onGeometryChange(for: CGFloat.self) {
                                $0.size.height
                            } action: {
                                listHeight = $0
                            }
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
                    .onChange(of: keyboardRow) { _, id in
                        if let id { proxy.scrollTo(id) }
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
        // The keyboard path: ↑ and ↓ through the rows, Return to open one and Return again to run it
        // (the panel's Run answers that one), Esc to close. Focus lands here whenever the popover opens.
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocus)
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.return) { openHighlighted() }
        .onAppear { keyboardFocus = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            keyboardFocus = true
        }
        // Closing the popover drops a half-finished confirm, so it never reopens armed, and retires
        // the success line, which has been seen.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            hovered = nil
            confirming = nil
            confirmingSafe = false
            showingCommands = false
            keyboardRow = nil
            monitor.dismissCleaned()
        }
    }

    // MARK: Header

    private var header: some View {
        let balance = balance
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Critical swaps in a warning sign, as the menu bar does, so it differs from low by shape too.
                HStack(spacing: 6) {
                    if machine.isCritical { Image(systemName: "exclamationmark.triangle.fill") }
                    Text(heading(balance))
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(machine.isCritical ? Theme.red : machine.isLow ? Theme.amber : .white)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                cleanSafeButton
            }
            if let report = machine.report {
                if let balance {
                    ledger(balance)
                    safeChecklist
                    cleanSafeConfirm
                } else {
                    // Only kept rows left: say so, rather than "nothing" above a list of them.
                    Text(report.findings.isEmpty ? "Nothing to clean" : "Nothing safe to clean or to review; the rows below are in use")
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(firstScanProgress).foregroundStyle(Theme.dim)
            }
            // While Clean safe runs, its checklist says all of this row by row.
            if machine.batch == nil {
                ForEach(machine.cleaning.values.sorted(), id: \.self) {
                    Text("Cleaning \($0)").foregroundStyle(Theme.dim)
                }
                if let lastCleaned = machine.lastCleaned {
                    Text(lastCleaned).foregroundStyle(Theme.green)
                }
                if let lastFailed = machine.lastFailed {
                    Text(lastFailed).foregroundStyle(Theme.red)
                }
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
            ForEach(machine.report?.notes ?? [], id: \.self) { note in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(note).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                    if note == KnownState.startDocker, machine.host == nil, let open = openDocker() {
                        Button("Open Docker", action: open).buttonStyle(TextButtonStyle())
                    }
                }
                .padding(.vertical, note == KnownState.startDocker ? -5 : 0)
            }
        }
        .font(.system(size: 12))
        .padding(12)
    }

    /// The header's sum. On a Mac, Docker's prunes free space inside its VM disk rather than on the Mac,
    /// so that share is listed apart and left out of what the Mac has after Clean safe.
    private struct Balance {
        let safe: Int64
        let insideDocker: Int64
        let review: Int64
        /// Free space once the safe rows are cleaned; nil when they would not change it.
        let after: Int64?
    }

    /// Nil when there is no report or nothing in it to clean.
    private var balance: Balance? {
        guard let report = machine.report else { return nil }
        let insideDocker = machine.dockerInVM ? report.total(.reclaimable, in: .docker) : 0
        let safe = report.total(.reclaimable) - insideDocker
        let review = report.total(.review)
        guard safe + insideDocker + review > 0 else { return nil }
        let after = safe > 0 ? machine.disk.map { $0.free + safe } : nil
        return Balance(safe: safe, insideDocker: insideDocker, review: review, after: after)
    }

    /// The balance laid out like the rows below: a verdict dot, a label, the size at the trailing
    /// edge, then the sum.
    private func ledger(_ balance: Balance) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if balance.safe > 0 {
                ledgerRow(.reclaimable, "Safe to clean", balance.safe)
            }
            if balance.insideDocker > 0 {
                if balance.safe > 0 {
                    ledgerRow(nil, "plus inside Docker's disk", balance.insideDocker).foregroundStyle(Theme.dim)
                } else {
                    ledgerRow(.reclaimable, "Safe to clean inside Docker's disk", balance.insideDocker)
                }
            }
            if balance.review > 0 {
                ledgerRow(.review, "To review", balance.review)
            }
            if let after = balance.after {
                Theme.line.frame(height: 1).padding(.vertical, 3)
                afterRow(after)
            }
        }
        .padding(.top, 2)
    }

    /// With no verdict the dot's place stays empty, so the label lines up with the rows above it.
    private func ledgerRow(_ verdict: Verdict?, _ label: String, _ bytes: Int64) -> some View {
        HStack(spacing: 8) {
            if let verdict { Dot(verdict: verdict) } else { Color.clear.frame(width: 7, height: 7) }
            Text(label)
            Spacer(minLength: 8)
            Text(formatBytes(bytes)).font(.system(size: 13)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    /// Where Clean safe leaves this machine, against its limit while it is under it now.
    private func afterRow(_ after: Int64) -> some View {
        let limit = machine.isLow ? (machine.isLow(after) ? "still under" : "above") + " your \(machine.alertBelowGB) GB limit" : nil
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("After Clean safe").font(.system(size: 13, weight: .semibold))
            if let limit { Text(limit).foregroundStyle(Theme.dim) }
            Spacer(minLength: 8)
            Text(formatBytes(after)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(machine.isCritical(after) ? Theme.red : machine.isLow(after) ? Theme.amber : .white)
        .accessibilityElement(children: .combine)
    }

    /// What Clean safe will run, then how far it has got: one line per row, in the order they run, with
    /// the commands a click away before it starts. Scrolls past a few hundred points so a long batch
    /// cannot push the list off screen.
    @ViewBuilder
    private var safeChecklist: some View {
        let batch = machine.batch
        let pending = confirmingSafe && machine.cleaning.isEmpty ? machine.safeToClean.map { Batch.Item(finding: $0) } : []
        let items = batch?.items ?? pending
        if !items.isEmpty {
            Theme.line.frame(height: 1).padding(.top, 4).padding(.bottom, 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(items) { checklistRow($0, showingCommand: batch == nil && showingCommands) }
                }
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    checklistHeight = $0
                }
            }
            .frame(height: min(checklistHeight, Self.checklistCap))
            .scrollIndicators(checklistHeight > Self.checklistCap ? .automatic : .never)
            if let batch {
                HStack(spacing: 0) {
                    Text("\(min(batch.finished + 1, items.count)) of \(items.count)").foregroundStyle(Theme.dim).monospacedDigit()
                    Spacer(minLength: 8)
                    // No Esc: a stray key must never interrupt a run.
                    Button(batch.stopping ? "Stopping after this one" : "Stop after this one") { machine.stopCleanSafe() }
                        .buttonStyle(TextButtonStyle())
                        .disabled(batch.stopping)
                }
                .padding(.vertical, -5)
                .padding(.trailing, -6)
            } else {
                Button(showingCommands ? "Hide the commands" : items.count == 1 ? "Show the command" : "Show the \(items.count) commands") {
                    showingCommands.toggle()
                }
                .buttonStyle(TextButtonStyle())
                .foregroundStyle(Theme.dim)
                .padding(.leading, Self.checklistInset - 6)
                .padding(.vertical, -5)
            }
        }
    }

    private static let checklistCap: CGFloat = 240
    /// Lines up with the sum's labels, past the dot column.
    private static let checklistInset: CGFloat = 15

    private func checklistRow(_ item: Batch.Item, showingCommand: Bool) -> some View {
        let (status, color): (String, Color) =
            switch item.status {
            case .pending: (formatBytes(item.finding.bytes), .white)
            case .cleaning: ("cleaning", Theme.green)
            case .done: ("done", Theme.green)
            case .notDone: ("not done", Theme.red)
            }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Text(item.finding.title)) \(Text(item.finding.category.singular).foregroundStyle(Theme.dim))")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(item.status == .done ? Theme.dim : .white)
                Spacer(minLength: 8)
                Text(status).foregroundStyle(color).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            if showingCommand, let command = item.finding.cleanup {
                Text(runnableCommand(command, on: machine.host))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.command)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.leading, Self.checklistInset)
    }

    /// "Clean safe" on the heading's line, then a line under the checklist saying what Run does. Hidden
    /// while anything is cleaning.
    private var canStartCleanSafe: Bool {
        !confirmingSafe && !machine.safeToClean.isEmpty && machine.cleaning.isEmpty
    }

    /// Opens Clean safe's checklist; Run there starts it. The button and the gear menu share this.
    private func startCleanSafe() {
        confirming = nil
        confirmingSafe = true
    }

    @ViewBuilder
    private var cleanSafeButton: some View {
        if canStartCleanSafe {
            Button(action: startCleanSafe) {
                // The same words as the sum's "After Clean safe".
                Text("Clean safe")
            }
            .buttonStyle(TextButtonStyle())
            .foregroundStyle(Theme.green)
            // ⇧⌘C, then Return: Clean safe without the pointer.
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("Lists what it will run first (⇧⌘C)")
            .accessibilityHint("Lists the \(machine.safeToClean.count) cleanups it will run, then asks. Shift-Command-C")
            .padding(.vertical, -5)
            .padding(.trailing, -6)
        }
    }

    @ViewBuilder
    private var cleanSafeConfirm: some View {
        let count = machine.safeToClean.count
        if confirmingSafe && count > 0 && machine.cleaning.isEmpty {
            HStack(spacing: 0) {
                Text(count == 1 ? "Runs this one" : "Runs these \(count), one at a time").foregroundStyle(Theme.dim)
                Spacer(minLength: 8)
                Button {
                    confirmingSafe = false
                    Task { await machine.cleanSafe() }
                } label: {
                    Text("Run \(Image(systemName: "return"))")
                }
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

    /// Past this many machines the tabs would truncate names and free space, so the strip becomes a
    /// picker: one line and a menu.
    private static let tabLimit = 4

    @ViewBuilder
    private var deviceStrip: some View {
        if monitor.machines.count > Self.tabLimit { devicePicker } else { deviceTabs }
    }

    /// One cell per machine, each with its free space. ⌘1 to ⌘9 pick them in order.
    private var deviceTabs: some View {
        HStack(spacing: 0) {
            ForEach(Array(monitor.machines.enumerated()), id: \.element.id) { index, device in
                let on = device.id == machine.id
                if index > 0 { Theme.line.frame(width: 1) }
                Button {
                    select(device)
                } label: {
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
                .keyboardShortcut(Self.shortcut(index))
                .help(index < 9 ? "\(device.name), ⌘\(index + 1)" : device.name)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityLabel("\(device.name), \(Self.statusInWords(device))")
                .accessibilityHint(index < 9 ? "Command-\(index + 1)" : "")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The machine shown, then what needs attention across all of them. Clicking opens a menu of every
    /// machine; ⌘1 to ⌘9 still pick them while it is closed.
    private var devicePicker: some View {
        Button(action: showMachineMenu) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 4) {
                    Text(machine.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.dim)
                }
                Spacer(minLength: 8)
                machineSummary.lineLimit(1).monospacedDigit()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            ZStack {
                ForEach(Array(monitor.machines.prefix(9).enumerated()), id: \.element.id) { index, device in
                    Button("") { select(device) }.keyboardShortcut(Self.shortcut(index))
                }
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
        .accessibilityLabel(
            "\(machine.name), \(Self.statusInWords(machine)). "
                + summaryParts.map(\.text).joined(separator: ", ")
        )
        .accessibilityHint("Opens a menu of every machine")
    }

    /// "2 low · 2 unreachable · 6 machines", each count in words so it does not rest on its color.
    private var summaryParts: [(text: String, color: Color)] {
        let low = monitor.machines.filter { $0.problem == nil && $0.isLow }.count
        let unreachable = monitor.machines.filter { $0.problem != nil }.count
        return [
            low > 0 ? ("\(low) low", Theme.amber) : nil,
            unreachable > 0 ? ("\(unreachable) unreachable", Theme.red) : nil,
            ("\(monitor.machines.count) machines", Theme.dim),
        ].compactMap { $0 }
    }

    private var machineSummary: Text {
        let parts = summaryParts.map { Text($0.text).foregroundStyle($0.color) }
        return parts.dropFirst().reduce(parts[0]) { Text("\($0)\(Text(" · ").foregroundStyle(Theme.dim))\($1)") }
    }

    /// A native menu, the machine shown checked and under the pointer, each with its free space on the
    /// trailing edge and its ⌘ shortcut.
    private func showMachineMenu() {
        let font = NSFont.menuFont(ofSize: 0)
        let rows = monitor.machines.map { ($0, Self.statusInWords($0)) }
        let width = { (text: String) in (text as NSString).size(withAttributes: [.font: font]).width }
        let column = (rows.map { width($0.0.name) + 32 + width($0.1) }.max() ?? 0).rounded(.up)
        let tabs = NSMutableParagraphStyle()
        tabs.tabStops = [NSTextTab(textAlignment: .right, location: column)]

        let menu = NSMenu()
        for (index, (device, status)) in rows.enumerated() {
            let title = NSMutableAttributedString(string: device.name + "\t", attributes: [.font: font, .paragraphStyle: tabs])
            title.append(
                NSAttributedString(
                    string: status,
                    attributes: [
                        .font: font, .paragraphStyle: tabs, .foregroundColor: Self.menuStatusColor(device),
                    ]))
            let item = ClosureMenuItem(title: device.name, keyEquivalent: index < 9 ? "\(index + 1)" : "") { select(device) }
            item.attributedTitle = title
            item.state = device.id == machine.id ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: menu.items.first { $0.state == .on }, at: NSEvent.mouseLocation, in: nil)
    }

    private static func shortcut(_ index: Int) -> KeyboardShortcut? {
        index < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)"))) : nil
    }

    /// A device that answered once keeps its last free space, in red while its header says what is wrong.
    /// "free" is left out: the heading under the strip says it, and the figure must never truncate.
    private static func status(_ device: Machine) -> String {
        guard let disk = device.disk else {
            return device.problem != nil ? "unreachable" : device.scanning ? "connecting" : "checking"
        }
        return gigabytes(disk.free)
    }

    /// The status with its state in words ("8.0 GB, low"), for the menu and VoiceOver, where the color
    /// alone would carry it.
    private static func statusInWords(_ device: Machine) -> String {
        guard device.disk != nil else { return status(device) }
        let state = device.problem != nil ? "unreachable" : device.isCritical ? "critical" : device.isLow ? "low" : nil
        return [status(device), state].compactMap { $0 }.joined(separator: ", ")
    }

    private static func menuStatusColor(_ device: Machine) -> NSColor {
        device.problem != nil || device.isCritical || device.isLow ? NSColor(statusColor(device)) : .secondaryLabelColor
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

    /// How far the first scan has got, by the scanners that finished. They run side by side, so there is
    /// no honest percentage, only which are done. A device's scan is one call, so it never gets past
    /// the first line.
    private var firstScanProgress: String {
        let all = HoarderCore.Category.allCases
        let done = all.filter(machine.scanned.contains), left = all.filter { !machine.scanned.contains($0) }
        guard !done.isEmpty, !left.isEmpty else { return "The first scan takes about a minute" }
        return "Checked \(listed(done.map(\.inSentence))), still checking \(listed(left.map(\.inSentence)))"
    }

    /// The limit is left out when the sum's last line already states it.
    private func heading(_ balance: Balance?) -> String {
        guard let disk = machine.disk else { return "Free space unknown" }
        return freeSpace(
            disk.free, limitGB: machine.alertBelowGB, low: machine.isLow && balance?.after == nil,
            critical: machine.isCritical)
    }

    // MARK: Sections

    /// In `Machine.sectionOrder`: most safe to clean first, Docker last, held still while cleaning.
    private func sections(_ report: Report) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(machine.sectionOrder(report), id: \.self) { category in
                section(report, category, report.total(.reclaimable, in: category) + report.total(.review, in: category))
            }
        }
    }

    /// One section's rows as the list shows them, shared with keyboard navigation so the arrow keys
    /// move through exactly what is on screen.
    private struct SectionRows {
        let actionable: [Finding]
        let kept: [Finding]
        let visible: [Finding]
        /// Kept rows on screen: a lone one always, several once their group is open.
        let keptShown: [Finding]
    }

    private func rows(_ report: Report, _ category: HoarderCore.Category) -> SectionRows {
        let rows = report.findings.filter { $0.category == category }
        // A row refused since the popover opened keeps its place, even once judged in use.
        let staysInList = { (row: Finding) in row.verdict != .keep || machine.refused.contains(row.id) }
        let actionable = rows.filter(staysInList)
        let kept = rows.filter { !staysInList($0) }
        let visible = expanded.contains(category) ? actionable : Array(actionable.prefix(Self.visibleRows))
        let keptShown = kept.count == 1 || showingKept.contains(category) ? kept : []
        return SectionRows(actionable: actionable, kept: kept, visible: visible, keptShown: keptShown)
    }

    /// Every row on screen, top to bottom, for the arrow keys.
    private func rowsOnScreen(_ report: Report) -> [Finding.ID] {
        machine.sectionOrder(report).flatMap { category in
            let section = rows(report, category)
            return (section.visible + section.keptShown).map(\.id)
        }
    }

    @ViewBuilder
    private func section(_ report: Report, _ category: HoarderCore.Category, _ bytes: Int64) -> some View {
        let shown = rows(report, category)
        let actionable = shown.actionable, kept = shown.kept, visible = shown.visible
        let isExpanded = expanded.contains(category)
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
            .accessibilityLabel(
                isExpanded
                    ? "Show fewer in \(category.label)"
                    : "\(actionable.count - visible.count) more in \(category.label), \(formatBytes(hiddenBytes))")
        }

        if kept.count > 1 { keptSummary(report, category, count: kept.count) }
        ForEach(shown.keptShown) { row($0) }
    }

    private func row(_ finding: Finding) -> some View {
        FindingRow(
            finding: finding,
            host: machine.host,
            dockerInVM: machine.dockerInVM,
            hovered: hovered == finding.id,
            keyboardFocused: keyboardRow == finding.id,
            confirming: confirming == finding.id,
            cleaning: machine.cleaning[finding.id] != nil,
            rechecking: machine.rechecking.contains(finding.id),
            failure: machine.failures[finding.id],
            onActivate: { toggle(finding) },
            onRun: {
                confirming = nil
                Task { await machine.clean(finding) }
            },
            onCancel: { confirming = nil }
        )
        .id(finding.id)
        .onHover { inside in
            // The pointer takes over from the arrow keys, so only one highlight shows.
            if inside {
                hovered = finding.id
                keyboardRow = nil
            } else if hovered == finding.id {
                hovered = nil
            }
        }
    }

    /// Opens a row's panel, or closes it if it is the one open: a click or Return.
    private func toggle(_ finding: Finding) {
        if confirming == finding.id {
            confirming = nil
        } else {
            confirming = finding.id
            confirmingSafe = false
            confirmedAs = Self.signature(finding)
            revealPending = true
        }
    }

    /// ↑ and ↓ move the highlight through the rows on screen, from the open or highlighted row, and
    /// close any open panel on the way.
    private func move(_ step: Int) -> KeyPress.Result {
        guard let report = machine.report else { return .ignored }
        let ids = rowsOnScreen(report)
        guard !ids.isEmpty else { return .ignored }
        let from = (hovered ?? confirming).flatMap(ids.firstIndex(of:))
        let next = from.map { min(max($0 + step, 0), ids.count - 1) } ?? (step > 0 ? 0 : ids.count - 1)
        confirming = nil
        confirmingSafe = false
        hovered = ids[next]
        keyboardRow = ids[next]
        return .handled
    }

    /// Return opens the highlighted row. Once a panel is open its Run answers Return, so this only
    /// handles the first press.
    private func openHighlighted() -> KeyPress.Result {
        guard confirming == nil, !confirmingSafe, let id = hovered,
            let finding = machine.report?.findings.first(where: { $0.id == id })
        else { return .ignored }
        toggle(finding)
        return .handled
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

    /// Only once an alert was sent: before that there is nothing to snooze.
    private var canSnooze: Bool {
        machine.isLow && machine.alertState.alerted && !machine.alertState.isSnoozed() && !monitor.notificationsOff
    }

    private var footer: some View {
        HStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(scannedLabel(now: context.date)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            .padding(.leading, 6)
            Spacer(minLength: 8)
            if canSnooze {
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
                // The popover's actions with their shortcuts, where a Mac user looks for them.
                Button("Clean safe…", action: startCleanSafe)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(!canStartCleanSafe)
                Button("Rescan") { Task { await monitor.scan() } }
                    .keyboardShortcut("r")
                    .disabled(machine.scanning)
                Button("Snooze 1 day") { machine.snooze() }
                    .keyboardShortcut("s")
                    .disabled(!canSnooze)
                Divider()
                // A menu bar app is never frontmost, so the window would open behind the others.
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                .keyboardShortcut(",")
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
    /// The arrow keys put the highlight here; it gets a ring, since the hover tone alone is too faint
    /// to find (1.1:1 on black).
    let keyboardFocused: Bool
    let confirming: Bool
    let cleaning: Bool
    /// Refused on a device and waiting for its rescan; the verdict shown may be out of date.
    let rechecking: Bool
    let failure: Failure?
    let onActivate: () -> Void
    let onRun: () -> Void
    let onCancel: () -> Void

    @AccessibilityFocusState private var panelFocused: Bool
    @AccessibilityFocusState private var rowFocused: Bool
    /// A failed row's panel shows the command's own output, which is otherwise only the tooltip.
    @State private var showingOutput = false

    private var cleanable: Bool { finding.cleanup != nil }
    private var kept: Bool { finding.verdict == .keep }

    /// Another device's command, as the SSH hop that runs it there.
    private var displayedCommand: String? {
        finding.cleanup.map { runnableCommand($0, on: host) }
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
                .accessibilityValue(cleaning ? "cleaning" : failure.map { "not cleaned, \($0.reason)" } ?? "")
                .accessibilityHint(cleanable ? "Shows the cleanup command" : "Shows where it is")
                .accessibilityFocused($rowFocused)

            // The plain reason; the command's own output is on hover, for when the reason is not enough.
            if let failure {
                Text("Not cleaned: \(failure.reason)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(failure.output)
                    .accessibilityHidden(true)
                    .padding(.leading, Self.textInset)
                    .padding(.trailing, 12)
                    .padding(.bottom, 4)
            }
            if confirming { panel }
        }
        .background(confirming ? Theme.panel : hovered ? Theme.hover : .clear)
        .overlay {
            if keyboardFocused { Rectangle().strokeBorder(Theme.dim, lineWidth: 1) }
        }
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

    /// While cleaning or checking again, the reason's place says so, and the size stays put.
    private var reason: some View {
        Text(cleaning ? "Cleaning" : rechecking ? "checking again" : finding.detail)
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
            if showingOutput, let failure {
                Text(failure.output.isEmpty ? "The command printed nothing" : failure.output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
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
                if host == nil, failure?.reason == KnownState.dockerNotRunning, let open = openDocker() {
                    Button("Open Docker", action: open)
                }
                if failure != nil {
                    Button(showingOutput ? "Hide output" : "Show output") { showingOutput.toggle() }
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

/// A menu item that runs a closure, for the machine menu built from SwiftUI.
private final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, keyEquivalent: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Not decoded from a nib") }

    @objc private func fire() { run() }
}
