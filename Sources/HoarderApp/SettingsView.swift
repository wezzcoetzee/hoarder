import AppKit
import HoarderCore
import SwiftUI

/// The Settings window: General, then one page per machine, this Mac first. Every control writes
/// config.json straight away through `Monitor.updateConfig`, so there is no Save, and hand edits to the
/// file still apply within a minute.
struct SettingsView: View {
    enum Page: Hashable {
        case general
        case machine(Machine.ID)
    }

    let monitor: Monitor
    @State private var page: Page
    /// "Add by name" was pressed and shows its field.
    @State private var addingName: String?
    @State private var peers: [Tailnet.Peer]?

    init(monitor: Monitor, page: Page = .general) {
        self.monitor = monitor
        _page = State(initialValue: page)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 200)
            Theme.line.frame(width: 1)
            ScrollView {
                detail
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 700, height: 460)
        .background(Color.black)
        .foregroundStyle(.white)
        .font(.system(size: 13))
        .preferredColorScheme(.dark)
        .task { peers = await Tailnet.peers() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            item(.general) { Text("General") }
            Text("MACHINES")
                .font(.system(size: 11))
                .kerning(0.5)
                .foregroundStyle(Theme.dim)
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 3)
            ForEach(monitor.machines) { machine in
                item(.machine(machine.id)) {
                    Text(machine.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(sidebarStatus(machine))
                        .font(.system(size: 12))
                        .foregroundStyle(statusColor(machine))
                        .monospacedDigit()
                }
                .contextMenu {
                    if let host = machine.host {
                        Button("Remove \(host)") { remove(host) }
                    }
                }
            }
            addDevice.padding(.top, 8)
            Spacer()
        }
        .padding(8)
        .disabled(monitor.configInvalid)
    }

    private func item(_ target: Page, @ViewBuilder _ label: () -> some View) -> some View {
        Button { page = target } label: {
            HStack(spacing: 0) { label() }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(page == target ? Theme.panel : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(page == target ? .isSelected : [])
    }

    /// Tailnet peers that can run hoarder and are not added yet, then typing a name for anything else,
    /// such as a Host from ~/.ssh/config.
    @ViewBuilder
    private var addDevice: some View {
        if let name = addingName {
            TextField("box or box.tailnet.ts.net", text: Binding(get: { name }, set: { addingName = $0 }))
                .textFieldStyle(.roundedBorder)
                .onSubmit { add(name) }
                .onExitCommand { addingName = nil }
                .padding(.horizontal, 6)
        } else {
            let added = Set(monitor.config.devices.map(\.host))
            let offered = (peers ?? []).filter { $0.canScan && !added.contains($0.name) }
            Menu("Add from tailnet") {
                if peers == nil {
                    Text("Tailscale is not running")
                } else if offered.isEmpty {
                    Text("Every Linux and Mac peer is added")
                }
                ForEach(offered, id: \.name) { peer in
                    Button("\(peer.name)\(peer.online ? "" : " (offline)")") { add(peer.name) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 10)
            Button("Add by name") { addingName = "" }
                .buttonStyle(TextButtonStyle())
                .padding(.horizontal, 4)
        }
    }

    private func remove(_ host: String) {
        monitor.removeDevice(host)
        if page == .machine(host) { page = .general }
    }

    private func add(_ host: String) {
        addingName = nil
        let before = Set(monitor.config.devices.map(\.host))
        monitor.addDevice(host)
        if let added = monitor.config.devices.first(where: { !before.contains($0.host) }) { page = .machine(added.host) }
    }

    // MARK: Pages

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if monitor.configInvalid, let error = monitor.configError {
                HStack(spacing: 0) {
                    Text("\(error). Fix the file to change settings here.").foregroundStyle(Theme.red)
                    Button("Open config.json") { monitor.editConfig() }.buttonStyle(TextButtonStyle())
                }
            }
            switch page {
            case .general:
                GeneralPage(monitor: monitor)
            case .machine(let id):
                if let machine = monitor.machines.first(where: { $0.id == id }) {
                    MachinePage(monitor: monitor, machine: machine) { page = .general }
                        .id(machine.id)
                }
            }
        }
        .disabled(monitor.configInvalid)
    }

    private func sidebarStatus(_ machine: Machine) -> String {
        guard let disk = machine.disk else { return machine.problem != nil ? "unreachable" : "" }
        return gigabytes(disk.free)
    }

    private func statusColor(_ machine: Machine) -> Color {
        if machine.problem != nil || machine.isCritical { return Theme.red }
        return machine.isLow ? Theme.amber : Theme.dim
    }
}

// MARK: General

private struct GeneralPage: View {
    let monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingRow("Open at login") {
                Toggle("", isOn: Binding(get: { monitor.opensAtLogin }, set: { monitor.setOpensAtLogin($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            if let loginError = monitor.loginError {
                SettingRow("") { Text(loginError).foregroundStyle(Theme.red) }
            }
            SettingRow("Notifications") {
                Text(monitor.notificationsOff ? "Off" : "On")
                    .foregroundStyle(monitor.notificationsOff ? Theme.amber : Theme.green)
                Button("Open System Settings") { NSWorkspace.shared.open(Notifier.settingsURL) }
                    .buttonStyle(TextButtonStyle())
            }
            Theme.line.frame(height: 1)
            SettingRow("Full scan every") {
                NumberField(value: monitor.config.scanEveryMinutes, unit: "min", range: 5...1440) { value in
                    monitor.updateConfig { $0.scanEveryMinutes = value }
                }
            }
            SettingRow("Worktree stale after") {
                NumberField(value: monitor.config.staleWorktreeDays, unit: "days", range: 1...365) { value in
                    monitor.updateConfig { $0.staleWorktreeDays = value }
                }
            }
            SettingRow("node_modules idle after") {
                NumberField(value: monitor.config.idleNodeModulesDays, unit: "days", range: 1...365) { value in
                    monitor.updateConfig { $0.idleNodeModulesDays = value }
                }
            }
            Text("The free-space limit and folders are set per machine, on the left.")
                .foregroundStyle(Theme.dim)
            Theme.line.frame(height: 1)
            HStack(spacing: 0) {
                Text("Saved to ~/.config/hoarder/config.json").foregroundStyle(Theme.dim)
                Button("Open config.json") { monitor.editConfig() }.buttonStyle(TextButtonStyle())
            }
            .font(.system(size: 12))
        }
    }
}

// MARK: Machine

/// The same page for every machine. This Mac's limit and folders are the config's top-level ones; a
/// device's override them, and with none set it uses its own config.json.
private struct MachinePage: View {
    let monitor: Monitor
    let machine: Machine
    let onRemove: () -> Void
    @State private var resolved: String?
    @State private var testing = false
    @State private var confirmingRemove = false
    @State private var newPath: String?

    private var device: Device? { monitor.config.devices.first { $0.host == machine.host } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(machine.name).font(.system(size: 16, weight: .semibold))
            SettingRow("Status") { status }
            if let problem = machine.problem {
                SettingRow("") { Text(problem).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
            }
            if let host = machine.host {
                SettingRow("Host") {
                    Text(host).font(.system(size: 12, design: .monospaced))
                    if let resolved {
                        Text("connects to \(resolved) via ~/.ssh/config").foregroundStyle(Theme.dim)
                    }
                }
            }
            SettingRow("Alert below") { limit }
            SettingRow("Project folders") { folders }
            if machine.host != nil {
                Theme.line.frame(height: 1)
                actions
            }
        }
        .task { resolved = await machine.resolvedHostName() }
    }

    private var status: some View {
        let parts = [
            machine.disk.map { "\(gigabytes($0.free)) free of \(gigabytes($0.total))" },
            machine.platform?.label,
            machine.report.map { "scanned \(scannedAgo($0.scannedAt))" },
        ].compactMap { $0 }
        return Text(parts.isEmpty ? (machine.scanning ? "Connecting" : "Not checked yet") : parts.joined(separator: " · "))
            .foregroundStyle(machine.problem != nil ? Theme.red : machine.isLow ? Theme.amber : Theme.dim)
            .monospacedDigit()
    }

    @ViewBuilder
    private var limit: some View {
        if let host = machine.host {
            let own = device?.alertBelowGB
            Toggle("Own limit", isOn: Binding(get: { own != nil }, set: { on in
                monitor.updateDevice(host) { $0.alertBelowGB = on ? monitor.config.alertBelowGB : nil }
            }))
            .toggleStyle(.switch).controlSize(.small)
            if let own {
                NumberField(value: own, unit: "GB", range: 1...10_000) { value in
                    monitor.updateDevice(host) { $0.alertBelowGB = value }
                }
            } else {
                Text("same as This Mac, \(monitor.config.alertBelowGB) GB").foregroundStyle(Theme.dim)
            }
        } else {
            NumberField(value: monitor.config.alertBelowGB, unit: "GB", range: 1...10_000) { value in
                monitor.updateConfig { $0.alertBelowGB = value }
            }
        }
    }

    /// This Mac's folders are picked in Finder; a device's are typed, since they are paths on that
    /// machine. A folder this Mac cannot find is dimmed, since scans skip it.
    private var folders: some View {
        let roots = machine.host == nil ? monitor.config.projectRoots : device?.projectRoots ?? []
        return VStack(alignment: .leading, spacing: 4) {
            if roots.isEmpty, let host = machine.host {
                Text("Uses \(host)'s own config.json").foregroundStyle(Theme.dim)
            }
            ForEach(Array(roots.enumerated()), id: \.offset) { index, root in
                let missing = machine.host == nil && !FileManager.default.fileExists(atPath: (root as NSString).expandingTildeInPath)
                HStack(spacing: 8) {
                    Text(root).font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(missing ? Theme.dim : .white)
                    if missing { Text("not found").foregroundStyle(Theme.dim) }
                    Spacer(minLength: 0)
                    Button("Remove") { setRoots(roots.enumerated().filter { $0.offset != index }.map(\.element)) }
                        .buttonStyle(TextButtonStyle())
                        .foregroundStyle(Theme.dim)
                        .accessibilityLabel("Remove \(root)")
                }
            }
            if let path = newPath {
                TextField("~/folder on \(machine.name)", text: Binding(get: { path }, set: { newPath = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit {
                        let trimmed = path.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty, !roots.contains(trimmed) { setRoots(roots + [trimmed]) }
                        newPath = nil
                    }
                    .onExitCommand { newPath = nil }
            } else {
                Button("Add folder") { machine.host == nil ? pickFolder(roots) : (newPath = "") }
                    .buttonStyle(TextButtonStyle())
                    .foregroundStyle(Theme.green)
                    .padding(.leading, -6)
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    private func setRoots(_ roots: [String]) {
        if let host = machine.host {
            monitor.updateDevice(host) { $0.projectRoots = roots }
        } else {
            monitor.updateConfig { $0.projectRoots = roots }
        }
    }

    /// Stored with ~ for the home folder, like the defaults, so the file reads the same on every Mac.
    private func pickFolder(_ roots: [String]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
        if !roots.contains(path) { setRoots(roots + [path]) }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            Button(testing ? "Testing" : "Test connection") {
                testing = true
                Task {
                    await machine.testConnection()
                    testing = false
                }
            }
            .disabled(testing)
            Spacer(minLength: 12)
            if confirmingRemove {
                Text("Stop watching?").foregroundStyle(Theme.dim)
                Button("Remove") {
                    if let host = machine.host { monitor.removeDevice(host) }
                    onRemove()
                }
                .foregroundStyle(Theme.red)
                Button("Cancel") { confirmingRemove = false }
            } else {
                Button("Remove device") { confirmingRemove = true }
                    .foregroundStyle(Theme.red)
            }
        }
        .buttonStyle(TextButtonStyle())
        .padding(.leading, -6)
    }

    private func scannedAgo(_ date: Date) -> String {
        let minutes = Int(Date.now.timeIntervalSince(date) / 60)
        switch minutes {
        case ..<1: return "just now"
        case ..<60: return "\(minutes) min ago"
        case ..<1440: return "\(minutes / 60) h ago"
        default: return "\(minutes / 1440) d ago"
        }
    }
}

// MARK: Controls

/// A dim label in a fixed column, then the control, so every page's values line up.
private struct SettingRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).foregroundStyle(Theme.dim).frame(width: 150, alignment: .trailing)
            HStack(alignment: .firstTextBaseline, spacing: 8) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A whole number typed or stepped, clamped to its range, saved on Return, focus loss, or a step.
private struct NumberField: View {
    let value: Int
    let unit: String
    let range: ClosedRange<Int>
    let onChange: (Int) -> Void

    var body: some View {
        let binding = Binding(get: { value }, set: { new in
            let clamped = min(max(new, range.lowerBound), range.upperBound)
            if clamped != value { onChange(clamped) }
        })
        HStack(spacing: 6) {
            TextField("", value: binding, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 60)
            Stepper("", value: binding, in: range).labelsHidden()
            Text(unit).foregroundStyle(Theme.dim)
        }
    }
}
