import Foundation
import Combine
import AppKit
import MarauderKit

enum ConnMode { case unknown, marauder, flipperCLI }

/// Состояние приложения: держит Dataset, raw-терминал, аудит и подключение.
/// Все мутации — на главном потоке (callbacks SerialPort приходят на main).
@MainActor
final class LiveStore: ObservableObject {
    // Терминал
    @Published var rawLines: [String] = []
    // Инвентарь / аудит (перестраиваются по таймеру при изменениях)
    @Published var aps: [AccessPoint] = []
    @Published var stations: [Station] = []
    @Published var findings: [Finding] = []
    @Published var risk: Severity = .low
    @Published var riskScore: Int = 0
    // Счётчики
    @Published var apCount = 0
    @Published var stationCount = 0
    @Published var probeCount = 0
    @Published var deauthCount = 0
    @Published var lineCount = 0
    // Подключение
    @Published var ports: [PortInfo] = []
    @Published var selectedPort: String = ""
    @Published var connected = false
    @Published var statusMessage = ""
    @Published var demoRunning = false
    @Published var connMode: ConnMode = .unknown
    @Published var presetRunning = false
    @Published var presetStep = ""
    @Published var monitoring = false
    @Published var alerts: [String] = []
    @Published var eapolSeen = 0            // счётчик EAPOL из serial во время захвата
    @Published var handshakesCaptured = 0   // Complete EAPOL — подтверждённые рукопожатия

    var autoReconnect = true
    private var monitorTask: Task<Void, Never>?
    private var knownBSSIDs = Set<String>()
    private var alertedFindings = Set<String>()
    private var lastDeauthCount = 0
    private var launchHistory = Set<String>()   // BSSID, виденные в прошлые сессии (снимок)

    /// Сеть впервые встречается (не была в прошлых сессиях).
    func isNewNetwork(_ id: String) -> Bool { !launchHistory.contains(id) }
    private func saveHistory() {
        defaults.set(Array(launchHistory.union(ds.aps.keys)), forKey: "historyBSSIDs")
    }

    private var ds = Dataset()
    private var dirty = false
    private let serial = SerialPort()
    private var timer: Timer?
    private var demoTimer: Timer?
    private var demoIdx = 0
    private let maxRaw = 800
    private let defaults = UserDefaults.standard
    private var wantConnected = false
    private var reconnectAttempts = 0
    private weak var transportCoordinator: TransportCoordinator?
    private let transportOwner = "Network Lab"

    init(transportCoordinator: TransportCoordinator? = nil) {
        self.transportCoordinator = transportCoordinator
        serial.onLine = { [weak self] line in self?.handle(line) }
        serial.onStatus = { [weak self] up, port in
            Task { @MainActor in self?.onStatus(up, port) }
        }
        selectedPort = defaults.string(forKey: "selectedPort") ?? ""
        launchHistory = Set(defaults.stringArray(forKey: "historyBSSIDs") ?? [])
        loadOUI()
        refreshPorts()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rebuildIfDirty() }
        }
        if CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.async { [weak self] in self?.startDemo() }
        }
    }

    func refreshPorts() {
        ports = SerialPort.listPorts()
        // Приоритет: прямой ESP32 → порт Flipper (devboard в GPIO) → пусто.
        if selectedPort.isEmpty || !ports.contains(where: { $0.device == selectedPort }) {
            selectedPort = SerialPort.autodetect()
                ?? ports.first(where: { $0.isESP32 })?.device
                ?? ports.first(where: { $0.isFlipper })?.device
                ?? ""
        }
        if ports.isEmpty {
            statusMessage = "No USB serial ports found. Connect Flipper or run Demo."
        }
    }

    /// Выбран порт Flipper (плата в GPIO) — нужен USB-UART Bridge на флиппере.
    var selectedIsFlipper: Bool {
        ports.first(where: { $0.device == selectedPort })?.isFlipper ?? false
    }

    func toggleConnection() {
        if connected { disconnect() } else { connect() }
    }

    func connect() {
        guard transportCoordinator?.acquire(.serial, owner: transportOwner) != false else {
            statusMessage = transportCoordinator?.lastConflict ?? "USB serial is busy"
            return
        }
        let port = selectedPort.isEmpty ? (SerialPort.autodetect() ?? "") : selectedPort
        guard !port.isEmpty else {
            statusMessage = "ESP32 not found. Connect Module One and refresh ports."
            transportCoordinator?.release(.serial, owner: transportOwner)
            return
        }
        defaults.set(port, forKey: "selectedPort")
        connMode = .unknown
        wantConnected = true
        switch serial.open(path: port, baud: 115200) {
        case .success:
            statusMessage = "Connecting to \(port)"
        case .failure(let e):
            statusMessage = e.description
            appendRaw("[!] \(e.description)")
            wantConnected = false
            transportCoordinator?.release(.serial, owner: transportOwner)
        }
    }

    func disconnect() {
        wantConnected = false
        reconnectAttempts = 0
        cancelPreset()
        serial.send("stopscan")
        serial.close()
        connMode = .unknown
        saveHistory()
        statusMessage = "Disconnected"
        transportCoordinator?.release(.serial, owner: transportOwner)
    }

    private func onStatus(_ up: Bool, _ port: String) {
        connected = up
        if up {
            reconnectAttempts = 0
            statusMessage = "Connected to \(port)"
        } else if wantConnected && autoReconnect && !demoRunning && reconnectAttempts < 6 {
            reconnectAttempts += 1
            statusMessage = "Connection lost. Reconnecting (\(reconnectAttempts))."
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if self.wantConnected && !self.connected { self.connect() }
            }
        } else if !wantConnected {
            transportCoordinator?.release(.serial, owner: transportOwner)
        }
    }

    /// Распознать, что на том конце: Marauder или CLI флиппера.
    private func detectMode(_ line: String) {
        guard connMode != .marauder else { return }
        let l = line.lowercased()
        if l.contains("flipper zero command line") || l.contains("docs.flipper.net")
            || line.trimmingCharacters(in: .whitespaces) == ">:" {
            connMode = .flipperCLI
        } else if l.contains("marauder") || line.contains("Commands =") || line.hasPrefix("Starting")
            || l.contains("sniff") || (line.hasPrefix("[") && l.contains("ch")) {
            connMode = .marauder
        }
    }

    func clearData() {
        ds = Dataset()
        aps = []; stations = []; findings = []
        apCount = 0; stationCount = 0; probeCount = 0; deauthCount = 0
        risk = .low; riskScore = 0
        statusMessage = "Collected data cleared"
    }

    func clearTerminal() { rawLines = [] }

    /// Имя роутера (SSID) по BSSID, к которому подключён клиент — из инвентаря AP.
    func routerSSID(forBSSID bssid: String?) -> String {
        guard let b = bssid, !b.isEmpty else { return "" }
        if let ap = ds.aps[b.lowercased()], let s = ap.ssid, !s.isEmpty { return s }
        return ""   // AP не в списке или скрытый — имя неизвестно
    }

    /// Сколько клиентов ассоциировано с данным AP (обратная связь).
    func clientCount(forBSSID bssid: String?) -> Int {
        guard let b = bssid?.lowercased() else { return 0 }
        return ds.stations.values.filter { ($0.bssid ?? "").lowercased() == b }.count
    }

    // MARK: - база вендоров (IEEE OUI)
    @Published var ouiVendors = 0
    private var ouiPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Marauder/oui.txt")
    }
    private func loadOUI() {
        let path = ouiPath
        if FileManager.default.fileExists(atPath: path) {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let n = OUIStore.shared.loadIEEE(path: path)
                DispatchQueue.main.async { self?.ouiVendors = n }
            }
        } else {
            downloadOUI()
        }
    }
    /// Скачать полную базу IEEE OUI и подгрузить (curl, в Application Support).
    func downloadOUI() {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Marauder")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dest = ouiPath
        statusMessage = "Downloading IEEE vendor database"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["-L", "--fail", "--max-time", "120", "-o", dest,
                           "https://standards-oui.ieee.org/oui/oui.txt"]
            try? p.run(); p.waitUntilExit()
            let n = OUIStore.shared.loadIEEE(path: dest)
            DispatchQueue.main.async {
                self?.ouiVendors = n
                if n > 100 { self?.statusMessage = "Loaded \(n) vendor records" }
            }
        }
    }

    func send(_ cmd: String) {
        let c = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        if !serial.send(c) {
            statusMessage = demoRunning
                ? "Demo is running; commands are not sent to ESP32"
                : "Not connected. Connect to ESP32 or run Demo."
            appendRaw("[!] \(statusMessage)")
        }
    }

    // MARK: - демо-режим (поток встроенного примера без железа)
    func toggleDemo() { demoRunning ? stopDemo() : startDemo() }

    func startDemo() {
        guard !connected else { statusMessage = "Disconnect ESP32 before starting Demo"; return }
        demoRunning = true
        demoIdx = 0
        statusMessage = "Demo mode is replaying sample Marauder data"
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.demoStep() }
        }
    }

    func stopDemo() {
        demoRunning = false
        demoTimer?.invalidate(); demoTimer = nil
        statusMessage = "Demo stopped"
    }

    private func demoStep() {
        guard demoRunning else { return }
        if demoIdx >= Self.demoStream.count { stopDemo(); return }
        handle(Self.demoStream[demoIdx])
        demoIdx += 1
    }

    private static let demoStream: [String] = [
        ">> scanall",
        "[0] SSID: MyHomeNet  BSSID: aa:bb:cc:dd:ee:01  RSSI: -41  CH: 6  WPA2",
        "[1] SSID: OpenCafe  BSSID: aa:bb:cc:dd:ee:02  RSSI: -68  CH: 1  OPEN",
        "[2] SSID: OldRouter  BSSID: 00:1d:0f:aa:bb:cc  RSSI: -72  CH: 11  WEP",
        "[3] SSID: Net6  BSSID: 00:11:22:33:44:06  RSSI: -64  CH: 6  WPA2",
        "[4] SSID: MyHomeNet  BSSID: 11:22:33:44:55:99  RSSI: -57  CH: 11  OPEN",
        "[5] SSID: Guest-WiFi  BSSID: f0:9f:c2:00:11:22  RSSI: -59  CH: 1  WPA2",
        ">> sniffprobe",
        "Station: 5c:cf:7f:11:22:33 -> aa:bb:cc:dd:ee:01 RSSI -52 CH 6",
        "Station: dc:a6:32:aa:bb:cc -> aa:bb:cc:dd:ee:01 RSSI -61 CH 6",
        "PROBE REQ from da:a1:19:00:00:01 for \"AirportFree\" RSSI -69 CH 6",
        "PROBE REQ from da:a1:19:00:00:01 for \"MyHomeNet\" RSSI -68 CH 6",
        "PROBE REQ from 5c:cf:7f:11:22:33 for \"CoffeeWiFi\" RSSI -50 CH 6",
        "[0] SSID: MyHomeNet  BSSID: aa:bb:cc:dd:ee:01  RSSI: -39  CH: 6  WPA2",
        "DEAUTH detected: aa:bb:cc:dd:ee:01 -> 5c:cf:7f:11:22:33 reason 7 CH 6",
        "DEAUTH detected: aa:bb:cc:dd:ee:01 -> 5c:cf:7f:11:22:33 reason 7 CH 6",
        "DEAUTH detected: aa:bb:cc:dd:ee:01 -> ff:ff:ff:ff:ff:ff reason 7 CH 6",
        "Station: dc:a6:32:aa:bb:cc -> aa:bb:cc:dd:ee:01 RSSI -58 CH 6",
        ">> stopscan",
        "Scan stopped.",
    ]

    func exportSession() -> URL? {
        let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("marauder-session-\(stamp).csv")
        var csv = "type,ssid,bssid,mac,channel,rssi,encryption,vendor,probes\n"
        for a in ds.apList {
            csv += "AP,\(a.ssid ?? ""),\(a.bssid ?? ""),,\(a.channel.map(String.init) ?? ""),"
            csv += "\(a.rssi.map(String.init) ?? ""),\(a.encryption ?? ""),\(a.vendor),\n"
        }
        for s in ds.stationList {
            csv += "STA,,\(s.bssid ?? ""),\(s.mac ?? ""),\(s.channel.map(String.init) ?? ""),"
            csv += "\(s.rssi.map(String.init) ?? ""),,\(s.vendor),\(s.probes.joined(separator: ";"))\n"
        }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - пресет «Полный аудит» (scanall → sniffprobe → sniffdeauth)
    func runFullAudit() {
        guard connected, !presetRunning else {
            if !connected { statusMessage = "Connect to ESP32 before running an audit" }
            return
        }
        presetRunning = true
        let steps: [(cmd: String, label: String, secs: Double)] = [
            ("scanall", "Scanning networks", 9),
            ("sniffprobe", "Collecting probes and clients", 8),
            ("sniffdeauth", "Detecting deauthentication frames", 6),
        ]
        Task { @MainActor in
            for s in steps {
                if !presetRunning { break }
                presetStep = s.label
                statusMessage = "Full Audit: \(s.label)"
                send(s.cmd)
                try? await Task.sleep(for: .seconds(s.secs))
                send("stopscan")
                try? await Task.sleep(for: .seconds(1))
            }
            presetStep = ""
            presetRunning = false
            if connected { statusMessage = "Full Audit complete" }
        }
    }

    func cancelPreset() {
        if presetRunning { send("stopscan") }
        presetRunning = false
        presetStep = ""
    }

    // MARK: - непрерывный мониторинг + алерты
    func toggleMonitoring() { monitoring ? stopMonitoring() : startMonitoring() }

    func startMonitoring() {
        guard connected else { statusMessage = "Connect to ESP32 before starting monitoring"; return }
        monitoring = true
        knownBSSIDs = Set(ds.aps.keys)          // базовая линия — не алертим текущие
        lastDeauthCount = ds.deauths.count
        statusMessage = "Continuous monitoring started"
        monitorTask = Task { @MainActor in
            while monitoring {
                presetStep = "Network scan"; send("scanall")
                try? await Task.sleep(for: .seconds(20))
                if !monitoring { break }
                send("stopscan"); try? await Task.sleep(for: .seconds(1))
                presetStep = "Deauth detection"; send("sniffdeauth")
                try? await Task.sleep(for: .seconds(10))
                if !monitoring { break }
                send("stopscan"); try? await Task.sleep(for: .seconds(1))
            }
            presetStep = ""
        }
    }

    func stopMonitoring() {
        monitoring = false
        monitorTask?.cancel(); monitorTask = nil
        send("stopscan")
        statusMessage = "Monitoring stopped"
    }

    private func pushAlert(_ msg: String) {
        alerts.insert(msg, at: 0)
        if alerts.count > 50 { alerts.removeLast(alerts.count - 50) }
        NSApp.requestUserAttention(.criticalRequest)
        NSSound(named: "Submarine")?.play()
        appendRaw("🔔 \(msg)")
    }

    private func detectAlerts() {
        guard monitoring else { return }
        for ap in ds.aps.values where !knownBSSIDs.contains(ap.id) {
            pushAlert("New network: \(ap.displaySSID) (\(ap.bssid ?? "?"))")
        }
        let d = ds.deauths.count
        if d - lastDeauthCount >= 5 { pushAlert("Deauth activity: +\(d - lastDeauthCount) frames") }
        lastDeauthCount = d
        for f in findings where f.severity == .critical || f.severity == .high {
            let key = f.id + f.title
            if !alertedFindings.contains(key) {
                alertedFindings.insert(key)
                pushAlert("⚠️ \(f.title) \(f.ssid ?? "")")
            }
        }
        knownBSSIDs.formUnion(ds.aps.keys)
    }

    /// Одно-кликовый таргет-захват PMKID/handshake.
    /// deauth=true → sniffpmkid -d (выбивает клиента, чтобы поймать рукопожатие).
    /// Перед этим пытаемся прицелиться по SSID (select), чтобы deauth бил по нужной
    /// сети, а не по всему каналу.
    func targetCapture(ssid: String?, channel: Int?, deauth: Bool) {
        guard connected else { statusMessage = "ESP32 is not connected"; return }
        eapolSeen = 0; handshakesCaptured = 0   // сброс перед новым захватом
        if !deauth {
            // пассивный PMKID (клиентский деаут не нужен)
            var cmd = "sniffpmkid"; if let ch = channel { cmd += " -c \(ch)" }
            send(cmd)
            statusMessage = "Passive PMKID capture" + (channel.map { " on channel \($0)" } ?? "") + ". Monitor the SD card."
            return
        }
        // Рабочий рецепт (проверен на железе): deauth НЕ через sniffpmkid -d, а
        // отдельной командой attack -t deauth (выбить клиента) → затем sniffpmkid
        // ловит переподключение и пишет рукопожатие на SD.
        Task { @MainActor in
            if let s = ssid, !s.isEmpty, s != "Hidden network" {
                send("select -a -f \"contains \(s.split(separator: " ").first.map(String.init) ?? s)\"")
                try? await Task.sleep(for: .seconds(1))
            }
            if let ch = channel { send("channel -s \(ch)"); try? await Task.sleep(for: .seconds(1)) }
            statusMessage = "1/2 Sending authorized deauth test to \(ssid ?? "target network")"
            send("attack -t deauth")
            try? await Task.sleep(for: .seconds(8))
            send("stopscan")
            try? await Task.sleep(for: .seconds(1))
            statusMessage = "2/2 Capturing handshake\(channel.map { " on channel \($0)" } ?? ""). Allow 20-30 seconds, then import the SD capture."
            send(channel.map { "sniffpmkid -c \($0)" } ?? "sniffpmkid")
        }
    }

    // MARK: - HTML-отчёт сессии
    func exportReportHTML() -> URL? {
        let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("marauder-report-\(stamp).html")
        let html = ReportBuilder.html(aps: ds.apList, stations: ds.stationList,
                                      findings: Audit.analyze(ds),
                                      risk: risk, score: riskScore,
                                      probes: probeCount, deauths: deauthCount)
        try? html.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(url)
        return url
    }

    // MARK: - приём строк
    private func handle(_ line: String) {
        appendRaw(line)
        lineCount += 1
        detectMode(line)
        parseCaptureCounters(line)
        if LogParser.feed(line, into: &ds) { dirty = true }
    }

    /// Считываем счётчики EAPOL/Complete EAPOL из вывода sniffpmkid — подтверждение захвата.
    private func parseCaptureCounters(_ line: String) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if let m = t.range(of: #"^Complete EAPOL:\s*(\d+)"#, options: .regularExpression),
           let n = Int(t[m].replacingOccurrences(of: "Complete EAPOL:", with: "").trimmingCharacters(in: .whitespaces)) {
            if n > handshakesCaptured {
                handshakesCaptured = n
                statusMessage = "Handshake captured (\(n)). Import the SD capture to analyze it."
                NSApp.requestUserAttention(.criticalRequest)
                NSSound(named: "Hero")?.play()
                appendRaw("[ok] Handshake captured; complete EAPOL: \(n)")
            }
        } else if t.hasPrefix("EAPOL:"), let n = Int(t.dropFirst(6).trimmingCharacters(in: .whitespaces)) {
            eapolSeen = max(eapolSeen, n)
        }
    }

    private func appendRaw(_ line: String) {
        rawLines.append(line)
        if rawLines.count > maxRaw { rawLines.removeFirst(rawLines.count - maxRaw) }
    }

    private func rebuildIfDirty() {
        guard dirty else { return }
        dirty = false
        aps = ds.apList
        stations = ds.stationList
        findings = Audit.analyze(ds)
        riskScore = Audit.riskScore(findings)
        risk = Audit.riskLevel(riskScore)
        apCount = ds.aps.count
        stationCount = ds.stations.count
        probeCount = ds.probes.count
        deauthCount = ds.deauths.count
        detectAlerts()
    }
}
