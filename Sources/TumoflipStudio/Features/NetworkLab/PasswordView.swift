import SwiftUI
import UniformTypeIdentifiers

struct PasswordView: View {
    @EnvironmentObject var crack: CrackStore
    @EnvironmentObject var store: LiveStore
    @State private var showCaptureImporter = false
    @State private var showWordlistImporter = false
    @State private var showFolderImporter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                toolsCard
                oneClickCard
                captureCard
                importCard
                crackCard
            }
            .padding(14)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { crack.detectTools() }
    }

    // Заголовок + дисклеймер
    private var header: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Authorized Password Recovery", systemImage: "key.fill")
                    .font(.system(size: 15, weight: .semibold))
                Text("Analyze a Marauder handshake or PMKID capture with hashcat. "
                   + "Use only on networks you own or are authorized to test.")
                    .font(.caption).foregroundStyle(Theme.textDim)
            }
        }
    }

    private var toolsCard: some View {
        Card(padding: 10) {
            HStack(spacing: 16) {
                toolBadge("hashcat", crack.tools.hashcat != nil)
                toolBadge("hcxtools", crack.tools.hcx != nil)
                toolBadge("aircrack-ng", crack.tools.aircrack != nil)
                Spacer()
                if !crack.tools.ready {
                    Text("brew install hashcat hcxtools").font(.caption2.monospaced()).foregroundStyle(.orange)
                } else {
                    Label("Tools Ready", systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            }
        }
    }

    // Взлом одной кнопкой (с карты модуля)
    private var oneClickCard: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "Analyze Module SD Card", systemImage: "externaldrive")
                Text("Locate captures on a mounted Module One SD card, extract handshakes or PMKIDs, "
                   + "run the selected recovery strategy and generate a report.")
                    .font(.caption2).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: $crack.authorized) {
                    Text("I own this network or have permission to test it").font(.callout)
                }
                .toggleStyle(.checkbox)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((crack.authorized ? Color.green : Color.red).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                HStack(spacing: 10) {
                    Button { crack.crackFromCard() } label: {
                        Label("Analyze SD Card", systemImage: "externaldrive.badge.magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .controlSize(.large)
                    .disabled(crack.running || !crack.authorized || !crack.tools.ready)
                    if crack.running {
                        Button(role: .destructive) { crack.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        ProgressView().scaleEffect(0.6)
                    }
                    Spacer()
                }
                if !crack.tools.ready {
                    Text("Requires hashcat and hcxtools: brew install hashcat hcxtools")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    // 1. Перехват
    private var captureCard: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "1. Capture with Marauder", systemImage: "dot.radiowaves.left.and.right",
                             trailing: AnyView(HStack(spacing: 5) {
                                Circle().fill(store.connected ? .green : .red).frame(width: 8, height: 8)
                                Text(store.connected ? "ESP32 connected" : "Disconnected; open Live")
                                    .font(.caption2).foregroundStyle(Theme.textDim)
                             }))
                HStack(spacing: 8) {
                    Text("Authorized network SSID").font(.caption).foregroundStyle(Theme.textDim)
                    TextField("MyHomeNet", text: $crack.targetSSID)
                        .textFieldStyle(.roundedBorder).frame(width: 180)
                    Button { runMyNetworkAudit() } label: { Label("Start Capture", systemImage: "dot.radiowaves.left.and.right") }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                        .disabled(!store.connected || crack.targetSSID.isEmpty)
                    Spacer()
                }
                Text("Scans for the selected SSID, starts a handshake capture, then waits for the .pcap import.")
                    .font(.caption2).foregroundStyle(Theme.textDim)
                HStack(spacing: 8) {
                    Button("sniffpmkid") { store.send("sniffpmkid") }
                    Button("sniffpwn") { store.send("sniffpwn") }
                    Button("stopscan") { store.send("stopscan") }
                    Spacer()
                }
                .controlSize(.small).disabled(!store.connected)
                Text("Captures are saved to the module SD card, for example /eapol_N.pcap. Mount the card on this Mac to continue.")
                    .font(.caption2).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                if store.handshakesCaptured > 0 {
                    Label("Captured handshakes: \(store.handshakesCaptured). Mount the SD card to analyze them.",
                          systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(.green)
                } else if store.eapolSeen > 0 {
                    Text("EAPOL frames observed: \(store.eapolSeen). Waiting for a complete handshake.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    // 2. Импорт
    private var importCard: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "2. Import Capture", systemImage: "folder")
                HStack {
                    Button("Folder", systemImage: "folder") { showFolderImporter = true }
                    Text((crack.watchFolder as NSString).abbreviatingWithTildeInPath)
                        .font(.caption).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Toggle(crack.watching ? "Watching" : "Watch", isOn: Binding(
                        get: { crack.watching }, set: { _ in crack.toggleWatch() }))
                        .toggleStyle(.switch).controlSize(.small)
                }
                Toggle("Start authorized recovery after import", isOn: $crack.autoCrack)
                    .toggleStyle(.checkbox).font(.caption)
                Toggle("Import automatically when a Module One SD card is mounted", isOn: $crack.autoImportSD)
                    .toggleStyle(.checkbox).font(.caption)
                Divider().overlay(Theme.stroke)
                fileRow(title: "Capture file (.pcap / .pcapng / .hc22000)",
                        value: crack.capturePath, action: { showCaptureImporter = true })
                fileRow(title: "Wordlist, for example rockyou.txt",
                        value: crack.wordlistPath, action: { showWordlistImporter = true })
                HStack {
                    Text("Target BSSID (optional)").font(.caption).foregroundStyle(Theme.textDim)
                    TextField("aa:bb:cc:dd:ee:ff", text: $crack.scopeBSSID)
                        .textFieldStyle(.roundedBorder).frame(width: 190)
                }
            }
        }
        .fileImporter(isPresented: $showCaptureImporter, allowedContentTypes: captureTypes) { res in
            if case .success(let url) = res { crack.capturePath = url.path }
        }
        .fileImporter(isPresented: $showWordlistImporter, allowedContentTypes: [.plainText, .data, .text]) { res in
            if case .success(let url) = res { crack.wordlistPath = url.path }
        }
        .fileImporter(isPresented: $showFolderImporter, allowedContentTypes: [.folder]) { res in
            if case .success(let url) = res { crack.watchFolder = url.path }
        }
    }

    // 3. Подбор
    private var crackCard: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "3. Recovery Strategy", systemImage: "play.circle")
                HStack {
                    Toggle("Common and default passwords plus wordlist", isOn: $crack.smartStrategy)
                        .toggleStyle(.checkbox).font(.caption)
                    Spacer()
                    if crack.downloading {
                        ProgressView().scaleEffect(0.5); Text("Downloading").font(.caption2).foregroundStyle(Theme.textDim)
                    } else {
                        Button("Download rockyou wordlist") { crack.downloadWordlist() }.controlSize(.small)
                    }
                }
                Toggle("Try an eight-digit mask (slow and CPU intensive)", isOn: $crack.tryDigitMask)
                    .toggleStyle(.checkbox).font(.caption).foregroundStyle(.orange)
                Toggle(isOn: $crack.authorized) {
                    Text("I own this network or have permission to test it").font(.callout)
                }
                .toggleStyle(.checkbox)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((crack.authorized ? Color.green : Color.red).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7))

                HStack(spacing: 10) {
                    Button(action: { crack.run() }) {
                        Label("Start Recovery", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(crack.running || !crack.authorized || !crack.tools.ready
                              || crack.capturePath.isEmpty
                              || (!crack.smartStrategy && !crack.tryDigitMask && crack.wordlistPath.isEmpty))
                    if crack.running {
                        Button(role: .destructive) { crack.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        ProgressView().scaleEffect(0.6)
                    }
                    Spacer()
                    DisclosureGroup("Capture workflow") { captureHelp }.font(.caption).frame(width: 300)
                }

                if !crack.recovered.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(crack.recovered, id: \.self) { r in
                            HStack {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                                Text(r).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.15)).clipShape(RoundedRectangle(cornerRadius: 8))
                }

                logView.frame(height: 220)
            }
        }
    }

    private func runMyNetworkAudit() {
        guard store.connected else { return }
        crack.smartStrategy = true
        if !crack.watching { crack.startWatch() }
        crack.autoCrack = true
        let ssid = crack.targetSSID
        store.statusMessage = "Scanning for authorized network \(ssid)"
        Task { @MainActor in
            store.send("scanall")
            try? await Task.sleep(for: .seconds(8))
            store.send("stopscan")
            try? await Task.sleep(for: .seconds(1))
            if let ap = store.aps.first(where: { ($0.ssid ?? "").caseInsensitiveCompare(ssid) == .orderedSame }) {
                if let b = ap.bssid { crack.scopeBSSID = b }
                store.targetCapture(ssid: ap.ssid, channel: ap.channel, deauth: true)
                store.statusMessage = "Capturing \(ap.displaySSID) on channel \(ap.channel.map(String.init) ?? "?"). Import the resulting .pcap to continue."
            } else {
                store.statusMessage = "Network \(ssid) was not found. Move closer and scan again."
            }
        }
    }

    private var captureHelp: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("1. Open Live and connect to Module One in ESP32 mode.")
            Text("2. Select your authorized network and start capture.")
            Text("3. Marauder writes the .pcap to the module SD card.")
            Text("4. Import the .pcap here or use the watched folder.")
        }
        .font(.caption2).foregroundStyle(Theme.textDim)
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(crack.log.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(logColor(line))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }.padding(8)
            }
            .background(Theme.consoleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .onChange(of: crack.log.count) { _, _ in
                if let last = crack.log.indices.last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    // helpers
    private var captureTypes: [UTType] {
        var t: [UTType] = [.data]
        for ext in ["pcap", "pcapng", "hc22000", "cap"] {
            if let u = UTType(filenameExtension: ext) { t.append(u) }
        }
        return t
    }

    private func toolBadge(_ name: String, _ ok: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? .green : Theme.textDim)
            Text(name).font(.caption)
        }
    }

    private func fileRow(title: String, value: String, action: @escaping () -> Void) -> some View {
        HStack {
            Button("Choose", systemImage: "doc") { action() }
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption2).foregroundStyle(Theme.textDim)
                Text(value.isEmpty ? "Not selected" : (value as NSString).lastPathComponent)
                    .font(.caption).foregroundStyle(value.isEmpty ? Theme.textDim : Theme.textPrimary)
            }
            Spacer()
        }
    }

    private func logColor(_ s: String) -> Color {
        if s.hasPrefix("[ok]") { return .green }
        if s.hasPrefix("[error]") { return .red }
        if s.hasPrefix("[info]") { return .blue }
        return Theme.consoleText
    }
}
