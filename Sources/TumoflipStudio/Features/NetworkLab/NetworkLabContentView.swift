import SwiftUI
import AppKit
import MarauderKit

/// Скопировать строку в системный буфер обмена.
func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

struct NetworkLabView: View {
    @EnvironmentObject var store: LiveStore
    @EnvironmentObject var crack: CrackStore
    @State private var section = 0

    var body: some View {
        VStack(spacing: 0) {
            StudioPageHeader(
                title: "Network Lab",
                subtitle: "Module One capture, inspection and authorized audit tools",
                systemImage: "wifi.router"
            ) {
                Picker("Workspace", selection: $section) {
                    Label("Live", systemImage: "antenna.radiowaves.left.and.right").tag(0)
                    Label("Capture Analysis", systemImage: "key.fill").tag(1)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 300)
            }

            Divider()

            Group {
                if section == 0 {
                    LiveView()
                } else {
                    PasswordView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(Theme.accent)
        .onAppear {
            // при найденном пароле — авто-отчёт HTML (end-to-end)
            crack.onCracked = { [weak store] _ in _ = store?.exportReportHTML() }
        }
    }
}

// MARK: - Live

struct LiveView: View {
    @EnvironmentObject var store: LiveStore

    var body: some View {
        VStack(spacing: 12) {
            ConnectionBar()
            StatsRow()
            CommandBar()
            VSplitView {
                HSplitView {
                    TerminalPanel().frame(minWidth: 240, minHeight: 150)
                    FindingsPanel().frame(minWidth: 200, minHeight: 150)
                }
                .frame(minHeight: 170)
                TablesPanel().frame(minHeight: 200)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Панель подключения

private struct ConnectionBar: View {
    @EnvironmentObject var store: LiveStore
    var body: some View {
        Card(padding: 10) {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Circle().fill(store.connected ? .green : .red)
                            .frame(width: 9, height: 9)
                            .shadow(color: store.connected ? .green : .clear, radius: 4)
                        Text(store.connected ? "Connected" : "Disconnected")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Spacer()
                    Picker("", selection: $store.selectedPort) {
                        if store.ports.isEmpty { Text("No ports").tag("") }
                        ForEach(store.ports) { p in Text(p.label).tag(p.device) }
                    }
                    .labelsHidden().frame(width: 290).disabled(store.connected)
                    Button { store.refreshPorts() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh serial ports")
                    Button(store.connected ? "Disconnect" : "Connect") { store.toggleConnection() }
                        .buttonStyle(.borderedProminent).tint(store.connected ? .gray : Theme.accent)
                        .disabled(store.demoRunning)
                    Button(store.demoRunning ? "Stop Demo" : "Run Demo") { store.toggleDemo() }
                        .tint(.orange).disabled(store.connected)
                        .help("Replay sample data without hardware")
                }
                if store.selectedIsFlipper && !store.connected && !store.demoRunning {
                    hintRow("Flipper port selected. Enable ESP32 mode and USB-UART Bridge at 115200 baud.")
                }
                if store.connected && store.connMode == .flipperCLI {
                    hintRow("Flipper CLI detected instead of Marauder. Switch Module One to ESP32 mode.")
                }
                if !store.statusMessage.isEmpty {
                    HStack { Text(store.statusMessage).font(.caption2).foregroundStyle(Theme.textDim); Spacer() }
                }
                if !store.alerts.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "bell.fill").foregroundStyle(.red).font(.caption2)
                        Text("\(store.alerts.count): \(store.alerts.first ?? "")")
                            .font(.caption2).foregroundStyle(.red.opacity(0.9)).lineLimit(1)
                        Spacer()
                        Button("Clear") { store.alerts.removeAll() }
                            .buttonStyle(.plain).font(.caption2).foregroundStyle(Theme.accent)
                    }
                }
            }
        }
    }
    private func hintRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
            Text(text).font(.caption2).foregroundStyle(.orange.opacity(0.9))
            Spacer()
        }
    }
}

// MARK: Метрики

private struct StatsRow: View {
    @EnvironmentObject var store: LiveStore
    var body: some View {
        HStack(spacing: 10) {
            StatCard(label: "Access Points", value: "\(store.apCount)", icon: "wifi", color: Theme.accent)
            StatCard(label: "Clients", value: "\(store.stationCount)", icon: "laptopcomputer", color: .cyan)
            StatCard(label: "Probe", value: "\(store.probeCount)", icon: "dot.radiowaves.right", color: .mint)
            StatCard(label: "Deauth", value: "\(store.deauthCount)", icon: "bolt.horizontal", color: .red)
            StatCard(label: "Risk (\(store.riskScore))", value: store.risk.rawValue,
                     icon: "shield.lefthalf.filled", color: Theme.severity(store.risk))
        }
    }
}

// MARK: Командная строка

private struct CommandBar: View {
    @EnvironmentObject var store: LiveStore
    @State private var command = ""
    private let quick = ["scanall", "sniffprobe", "sniffdeauth", "list -a", "stopscan", "help"]

    var body: some View {
        Card(padding: 10) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal").foregroundStyle(Theme.textDim)
                    TextField("Marauder command", text: $command).textFieldStyle(.roundedBorder)
                        .onSubmit(sendCmd)
                    Button("Send", action: sendCmd).disabled(command.isEmpty)
                    Divider().frame(height: 18)
                    if store.presetRunning {
                        Button { store.cancelPreset() } label: { Label("Stop: \(store.presetStep)", systemImage: "stop.fill") }
                            .tint(.orange)
                        ProgressView().scaleEffect(0.5)
                    } else {
                        Button { store.runFullAudit() } label: { Label("Full Audit", systemImage: "wand.and.stars") }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                            .disabled(!store.connected || store.monitoring)
                    }
                    Button { store.toggleMonitoring() } label: {
                        Label(store.monitoring ? "Stop Monitoring" : "Monitor",
                              systemImage: store.monitoring ? "stop.circle" : "scope")
                    }
                    .tint(store.monitoring ? .orange : Theme.accent)
                    .disabled(!store.connected || store.presetRunning)
                    Button {
                        _ = store.exportReportHTML(); store.statusMessage = "HTML report saved to Desktop"
                    } label: { Label("HTML Report", systemImage: "doc.richtext") }
                }
                HStack(spacing: 6) {
                    ForEach(quick, id: \.self) { c in
                        Button(c) { store.send(c) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .fixedSize()
                            .disabled(!store.connected)
                    }
                    Spacer()
                    Button { store.clearTerminal() } label: { Image(systemName: "trash") }
                        .help("Clear terminal")
                    Button { store.clearData() } label: { Image(systemName: "arrow.counterclockwise") }
                        .help("Reset collected data")
                    Button {
                        if let url = store.exportSession() { store.statusMessage = "Saved: \(url.lastPathComponent)" }
                    } label: { Image(systemName: "square.and.arrow.up") }
                        .help("Export CSV")
                }
            }
        }
    }
    private func sendCmd() { store.send(command); command = "" }
}

// MARK: Терминал

private struct TerminalPanel: View {
    @EnvironmentObject var store: LiveStore
    var body: some View {
        Card(padding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "Terminal", systemImage: "text.alignleft",
                             trailing: AnyView(Text("\(store.lineCount) lines").font(.caption2).foregroundStyle(Theme.textDim)))
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(store.rawLines.enumerated()), id: \.offset) { i, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(lineColor(line))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(i)
                            }
                        }.padding(8)
                    }
                    .background(Theme.consoleBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .onChange(of: store.lineCount) { _, _ in
                        if let last = store.rawLines.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
    }
    private func lineColor(_ s: String) -> Color {
        if s.hasPrefix(">> ") { return .green }
        if s.hasPrefix("[!]") { return .orange }
        return Theme.consoleText
    }
}

// MARK: Аудит

private struct FindingsPanel: View {
    @EnvironmentObject var store: LiveStore
    var body: some View {
        Card(padding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "Security Findings", systemImage: "shield.lefthalf.filled",
                             trailing: AnyView(
                                Text(store.risk.rawValue).font(.caption2).bold().foregroundStyle(.white)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Theme.severity(store.risk)).clipShape(Capsule())))
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(store.findings) { f in
                            HStack(alignment: .top, spacing: 8) {
                                RoundedRectangle(cornerRadius: 2).fill(Theme.severity(f.severity)).frame(width: 3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(f.title).font(.caption).bold().foregroundStyle(Theme.textPrimary)
                                    if let s = f.ssid, !s.isEmpty {
                                        Text(s).font(.caption2).foregroundStyle(Theme.textDim)
                                    }
                                    Text(f.remediation).font(.caption2).foregroundStyle(Theme.textDim)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Theme.panel2)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        if store.findings.isEmpty {
                            Text("No findings yet. Run a scan or start Demo.")
                                .font(.caption).foregroundStyle(Theme.textDim).padding(.top, 4)
                        }
                    }
                }
            }
        }
    }
}

// MARK: Таблицы AP / Клиенты

private struct TablesPanel: View {
    @EnvironmentObject var store: LiveStore
    @EnvironmentObject var crack: CrackStore
    @State private var tab = 0
    @State private var query = ""
    @State private var apSort = [KeyPathComparator(\AccessPoint.rssiSort, order: .reverse)]
    @State private var staSort = [KeyPathComparator(\Station.countSeen, order: .reverse)]
    @State private var apSel = Set<AccessPoint.ID>()
    @State private var staSel = Set<Station.ID>()

    private var aps: [AccessPoint] {
        store.aps.filter { query.isEmpty
            || ($0.ssid ?? "").localizedCaseInsensitiveContains(query)
            || ($0.bssid ?? "").localizedCaseInsensitiveContains(query)
            || $0.vendor.localizedCaseInsensitiveContains(query)
        }.sorted(using: apSort)
    }
    private var stations: [Station] {
        store.stations.filter { query.isEmpty
            || ($0.mac ?? "").localizedCaseInsensitiveContains(query)
            || ($0.bssid ?? "").localizedCaseInsensitiveContains(query)
            || $0.probes.joined(separator: " ").localizedCaseInsensitiveContains(query)
        }.sorted(using: staSort)
    }

    var body: some View {
        Card(padding: 10) {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Picker("", selection: $tab) {
                        Text("Access Points (\(store.aps.count))").tag(0)
                        Text("Clients (\(store.stations.count))").tag(1)
                    }.pickerStyle(.segmented).frame(width: 320)
                    Spacer()
                    if store.ouiVendors > 100 {
                        Text("\(store.ouiVendors) vendors").font(.caption2).foregroundStyle(Theme.textDim)
                    }
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textDim)
                    TextField("Search", text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
                    Text("Right-click for actions").font(.caption2).foregroundStyle(Theme.textDim)
                }
                if tab == 0 { apTable } else { staTable }
            }
        }
    }

    private var apTable: some View {
        Table(aps, selection: $apSel, sortOrder: $apSort) {
            TableColumn("SSID", value: \.displaySSID) { ap in
                HStack(spacing: 4) {
                    if store.isNewNetwork(ap.id) {
                        Text("NEW").font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Theme.accent).foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Text(ap.displaySSID).textSelection(.enabled)
                }
            }
            TableColumn("BSSID", value: \.bssidDisplay) {
                Text($0.bssidDisplay).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            TableColumn("Ch", value: \.channelSort) { Text($0.channel.map(String.init) ?? "") }.width(42)
            TableColumn("RSSI", value: \.rssiSort) {
                Text($0.rssi.map(String.init) ?? "").foregroundStyle(Theme.rssi($0.rssi))
            }.width(52)
            TableColumn("Security", value: \.encDisplay) { Text($0.encDisplay) }.width(90)
            TableColumn("Vendor", value: \.vendor) { Text($0.vendor).foregroundStyle(Theme.textDim) }
            TableColumn("Clients") { ap in
                let n = store.clientCount(forBSSID: ap.bssid)
                Text(n > 0 ? "\(n)" : "").foregroundStyle(n > 0 ? .cyan : Theme.textDim)
            }.width(70)
            TableColumn("×", value: \.countSeen) { Text("\($0.countSeen)") }.width(40)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel2)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contextMenu(forSelectionType: AccessPoint.ID.self) { ids in
            if let ap = store.aps.first(where: { ids.contains($0.id) }) {
                Button("Capture PMKID") { captureAP(ap, deauth: false) }
                Button("Capture handshake with deauth") { captureAP(ap, deauth: true) }
                Divider()
                if let b = ap.bssid, !b.isEmpty {
                    Button("Copy BSSID") { copyToPasteboard(b) }
                    Button("Use BSSID for capture analysis") {
                        crack.scopeBSSID = b; store.statusMessage = "Capture analysis limited to BSSID \(b)"
                    }
                }
                if let s = ap.ssid, !s.isEmpty { Button("Copy SSID") { copyToPasteboard(s) } }
            }
        } primaryAction: { ids in
            if let ap = store.aps.first(where: { ids.contains($0.id) }), let b = ap.bssid {
                copyToPasteboard(b); store.statusMessage = "Copied BSSID: \(b)"
            }
        }
    }

    private func captureAP(_ ap: AccessPoint, deauth: Bool) {
        if let b = ap.bssid { crack.scopeBSSID = b }
        if !crack.watching { crack.startWatch() }
        store.targetCapture(ssid: ap.ssid, channel: ap.channel, deauth: deauth)
        store.statusMessage = "Capturing \(ap.displaySSID). Monitor the Capture Analysis workspace."
    }

    private var staTable: some View {
        Table(stations, selection: $staSel, sortOrder: $staSort) {
            TableColumn("MAC", value: \.macDisplay) {
                Text($0.macDisplay).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            TableColumn("Router") { st in
                let name = store.routerSSID(forBSSID: st.bssid)
                if !name.isEmpty {
                    Text(name)
                } else if let b = st.bssid, !b.isEmpty {
                    Text("Not listed").foregroundStyle(Theme.textDim)
                } else {
                    Text("Not associated").foregroundStyle(Theme.textDim)
                }
            }
            TableColumn("AP (BSSID)", value: \.apDisplay) {
                Text($0.apDisplay).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            TableColumn("Vendor", value: \.vendor) { Text($0.vendor).foregroundStyle(Theme.textDim) }
            TableColumn("Estimated Type", value: \.deviceType) { Text($0.deviceType) }
            TableColumn("Rnd") { Text($0.randomized ? "Yes" : "").foregroundStyle(.orange) }.width(40)
            TableColumn("RSSI", value: \.rssiSort) {
                Text($0.rssi.map(String.init) ?? "").foregroundStyle(Theme.rssi($0.rssi))
            }.width(52)
            TableColumn("Probe SSID") { Text($0.probesDisplay).foregroundStyle(Theme.textDim) }
            TableColumn("×", value: \.countSeen) { Text("\($0.countSeen)") }.width(40)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel2)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contextMenu(forSelectionType: Station.ID.self) { ids in
            if let st = store.stations.first(where: { ids.contains($0.id) }) {
                Button("Copy MAC") { copyToPasteboard(st.mac ?? "") }
                if let b = st.bssid, !b.isEmpty { Button("Copy AP BSSID") { copyToPasteboard(b) } }
                if let p = st.probes.first { Button("Copy probe SSID") { copyToPasteboard(p) } }
            }
        } primaryAction: { ids in
            if let st = store.stations.first(where: { ids.contains($0.id) }), let m = st.mac {
                copyToPasteboard(m); store.statusMessage = "Copied MAC: \(m)"
            }
        }
    }
}
