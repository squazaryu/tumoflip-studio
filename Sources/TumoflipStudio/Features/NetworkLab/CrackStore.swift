import Foundation
import Combine
import AppKit

/// Подбор пароля Wi-Fi по словарю (для СВОИХ / авторизованных сетей).
///
/// Конвейер: захваченный .pcap (handshake/PMKID c Marauder: sniffpmkid / sniffpwn)
///   → hcxpcapngtool → .hc22000 → hashcat -m 22000 -a 0 <словарь> → пароль.
///
/// Этический гейт: запуск возможен только при включённом «Это моя сеть / есть
/// разрешение». Перебор чужих сетей — неправомерный доступ.
@MainActor
final class CrackStore: ObservableObject {
    @Published var capturePath: String = ""      // .pcap/.pcapng или .hc22000
    @Published var wordlistPath: String = "" { didSet { defaults.set(wordlistPath, forKey: "wordlistPath") } }
    @Published var scopeBSSID: String = ""        // опц. ограничение по BSSID
    @Published var authorized = false
    @Published var running = false
    @Published var log: [String] = []
    @Published var recovered: [String] = []       // "ESSID : пароль"
    @Published var tools = Tools()
    // авто-импорт .pcap из папки (куда кладёшь файл с SD модуля)
    @Published var watchFolder: String = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop") {
        didSet { defaults.set(watchFolder, forKey: "watchFolder") }
    }
    @Published var watching = false
    @Published var lastImported = ""
    @Published var autoCrack = true        // авто-извлечение+перебор при импорте
    @Published var smartStrategy = true    // быстрый список дефолтов (+ словарь)
    @Published var tryDigitMask = false    // тяжёлая маска 8 цифр — только по явному выбору
    @Published var downloading = false
    @Published var targetSSID = "" { didSet { defaults.set(targetSSID, forKey: "targetSSID") } }
    var onCracked: ((String) -> Void)?     // вызывается при найденном пароле (для авто-отчёта)
    private var watchTimer: Timer?
    private var watchStart = Date()
    private let defaults = UserDefaults.standard

    struct Tools {
        var hashcat: String? = nil
        var hcx: String? = nil
        var aircrack: String? = nil
        var python: String? = nil
        var ready: Bool { hashcat != nil && (hcx != nil || python != nil) }
    }

    private var proc: Process?
    private let toolDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    // python-движок marauder_analyzer как запасной экстрактор hc22000
    private let pyAnalyzerDir = ProcessInfo.processInfo.environment["TUMOFLIP_MARAUDER_ANALYZER"]
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/Flipper/marauder_analyzer", isDirectory: true).path

    @Published var autoImportSD = true     // авто-импорт .pcap при монтировании SD

    init() {
        detectTools()
        // словарь: сохранённый, иначе авто-подхват rockyou из Application Support
        let savedWL = defaults.string(forKey: "wordlistPath")
        if let w = savedWL, !w.isEmpty, FileManager.default.fileExists(atPath: w) {
            wordlistPath = w
        } else {
            let rk = (NSHomeDirectory() as NSString)
                .appendingPathComponent("Library/Application Support/Marauder/rockyou.txt")
            if FileManager.default.fileExists(atPath: rk) { wordlistPath = rk }
        }
        if let f = defaults.string(forKey: "watchFolder"), !f.isEmpty { watchFolder = f }
        if let s = defaults.string(forKey: "targetSSID") { targetSSID = s }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            if let path = note.userInfo?["NSDevicePath"] as? String {
                Task { @MainActor in self?.onVolumeMounted(path) }
            }
        }
        // fail-safe: выход из приложения гарантированно убивает перебор (освобождает GPU)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.terminateCurrentProcess() }
        }
    }

    private func onVolumeMounted(_ volume: String) {
        guard autoImportSD else { return }
        add("[info] Mounted volume: \(volume). Searching for .pcap files.")
        guard let pcap = newestPcap(under: volume) else {
            add("No .pcap files found on this volume."); return
        }
        lastImported = pcap
        capturePath = pcap
        notify("Imported from SD: \((pcap as NSString).lastPathComponent)")
        if autoCrack && authorized && tools.ready && !running && (smartStrategy || tryDigitMask || !wordlistPath.isEmpty) {
            add("[info] Automatic recovery enabled. Starting analysis."); run()
        }
    }

    /// Найти самый свежий .pcap на томе (приоритет — папки marauder), ограниченный обход.
    private func newestPcap(under root: String) -> String? {
        let fm = FileManager.default
        let preferred = ["apps_data/marauder/pcaps", "apps_data/marauder", "marauder/pcaps", "marauder"]
        var dirs = preferred.map { (root as NSString).appendingPathComponent($0) }
        dirs.append(root)
        var best: (String, Date)? = nil
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in items where name.lowercased().hasSuffix(".pcap") || name.lowercased().hasSuffix(".pcapng") {
                let p = (dir as NSString).appendingPathComponent(name)
                if let m = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date,
                   best == nil || m > best!.1 { best = (p, m) }
            }
        }
        return best?.0
    }

    /// Уведомить пользователя (док прыгает + системный звук + лог).
    private func notify(_ message: String, sound: String = "Glass") {
        NSApp.requestUserAttention(.criticalRequest)
        NSSound(named: sound)?.play()
        add("🔔 \(message)")
    }

    func detectTools() {
        func find(_ name: String) -> String? {
            for d in toolDirs {
                let p = "\(d)/\(name)"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
            return nil
        }
        var t = Tools()
        t.hashcat = find("hashcat")
        t.hcx = find("hcxpcapngtool")
        t.aircrack = find("aircrack-ng")
        let py = "\(pyAnalyzerDir)/.venv/bin/python"
        if FileManager.default.isExecutableFile(atPath: py) { t.python = py }
        tools = t
    }

    private func add(_ s: String) {
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            log.append(String(line))
        }
        if log.count > 1500 { log.removeFirst(log.count - 1500) }
    }

    func stop() {
        proc?.terminate()
        proc = nil
        running = false
        add("[stopped by user]")
    }

    // MARK: - слежение за папкой (авто-импорт .pcap)
    func toggleWatch() { watching ? stopWatch() : startWatch() }

    func startWatch() {
        guard !watchFolder.isEmpty else { add("No watched folder selected."); return }
        watching = true
        watchStart = Date()
        add("[info] Watching folder: \(watchFolder)")
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanFolder() }
        }
    }

    func stopWatch() {
        watching = false
        watchTimer?.invalidate(); watchTimer = nil
        add("Folder watch stopped")
    }

    private func scanFolder() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: watchFolder) else { return }
        var newest: (path: String, date: Date)? = nil
        for name in items where name.lowercased().hasSuffix(".pcap") || name.lowercased().hasSuffix(".pcapng") {
            let p = (watchFolder as NSString).appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: p),
                  let m = attrs[.modificationDate] as? Date else { continue }
            if m > watchStart, newest == nil || m > newest!.date { newest = (p, m) }
        }
        if let n = newest, n.path != lastImported {
            lastImported = n.path
            capturePath = n.path
            notify("Imported capture: \((n.path as NSString).lastPathComponent)")
            if autoCrack {
                if authorized && tools.ready && !running && (smartStrategy || tryDigitMask || !wordlistPath.isEmpty) {
                    add("[info] Automatic recovery enabled. Starting analysis.")
                    run()
                } else if !authorized {
                    add("Authorization confirmation is required before recovery can start.")
                }
            }
        }
    }

    /// Найти папку с захватами на подключённой карте модуля (или watch-папке).
    func findCaptureDir() -> String? {
        let fm = FileManager.default
        let subs = ["", "apps_data/marauder/pcaps", "apps_data/marauder", "marauder/pcaps", "marauder"]
        for v in (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? [] {
            let base = "/Volumes/\(v)"
            for sub in subs {
                let dir = sub.isEmpty ? base : (base as NSString).appendingPathComponent(sub)
                if let items = try? fm.contentsOfDirectory(atPath: dir),
                   items.contains(where: { $0.lowercased().hasSuffix(".pcap") || $0.lowercased().hasSuffix(".pcapng") }) {
                    return dir
                }
            }
        }
        if let items = try? fm.contentsOfDirectory(atPath: watchFolder),
           items.contains(where: { $0.lowercased().hasSuffix(".pcap") || $0.lowercased().hasSuffix(".pcapng") }) {
            return watchFolder
        }
        return nil
    }

    /// ОДНА КНОПКА: найти карту → все pcap → извлечь (подробный лог) → умный крек → отчёт.
    func crackFromCard() {
        guard !running else { return }
        log = []
        recovered = []
        add("[info] Searching the Module One SD card for captures.")
        guard let dir = findCaptureDir() else {
            add("[error] No .pcap files found. Mount the Module One SD card or select a watched folder.")
            return
        }
        let pcaps = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.lowercased().hasSuffix(".pcap") || $0.lowercased().hasSuffix(".pcapng") }
        guard let first = pcaps.first else { add("[error] The selected folder has no .pcap files."); return }
        add("Capture folder: \(dir); \(pcaps.count) file(s)")
        capturePath = (dir as NSString).appendingPathComponent(first)
        run()   // extraction просканит всю папку, затем умный крек + отчёт (onCracked)
    }

    func run() {
        guard !running else { return }
        guard authorized else {
            add("[error] Confirm that you own the network or have permission to test it.")
            return
        }
        guard !capturePath.isEmpty else { add("Select a capture file (.pcap or .hc22000)."); return }
        guard smartStrategy || tryDigitMask || !wordlistPath.isEmpty else {
            add("Select a wordlist or enable the common-password strategy."); return
        }
        guard let hashcat = tools.hashcat else {
            add("hashcat was not found. Install it with: brew install hashcat hcxtools")
            return
        }
        running = true
        recovered = []
        log = []
        add("[info] Starting authorized password recovery")

        Task.detached { [weak self] in
            await self?.pipeline(hashcat: hashcat)
        }
    }

    private nonisolated func pipeline(hashcat: String) async {
        let (capture, wordlist, scope, hcx, python, pyDir) = await MainActor.run {
            (capturePath, wordlistPath, scopeBSSID.lowercased().replacingOccurrences(of: ":", with: ""),
             tools.hcx, tools.python, pyAnalyzerDir)
        }

        // 1) получить .hc22000
        var hcPath = capture
        if !capture.lowercased().hasSuffix(".hc22000") {
            let out = NSTemporaryDirectory() + "marauder_\(UUID().uuidString).hc22000"
            await log("Extracting handshake or PMKID to hc22000")
            let ok: Bool
            if let hcx {
                // Скармливаем ВСЕ .pcap из папки захватов (а не один файл) — на карте
                // модуля рукопожатие может лежать в eapol_*/pwnagotchi_*, а не в самом свежем.
                var inputs = [capture]
                let dir = (capture as NSString).deletingLastPathComponent
                if let items = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                    let pcaps = items.filter { let l = $0.lowercased(); return l.hasSuffix(".pcap") || l.hasSuffix(".pcapng") }
                        .map { (dir as NSString).appendingPathComponent($0) }
                    if pcaps.count > 1 { inputs = pcaps; await self.log("Scanning all \(pcaps.count) .pcap files in the capture folder") }
                }
                ok = await self.runTool(hcx, ["-o", out] + inputs, tag: "hcx")
            } else if let python {
                ok = await self.runTool(python, ["-m", "analyzer", "handshakes", capture, "-o", out],
                                        tag: "extract", cwd: pyDir)
            } else {
                await self.log("[error] No extractor found. Install hcxtools with: brew install hcxtools")
                await self.finish(); return
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: out))?[.size] as? Int) ?? 0
            if !ok || size == 0 {
                await self.log("[error] The capture contains no complete handshake or PMKID.")
                await self.log("Capture while a client is connected to the authorized network and allow 10-30 seconds after the test deauth.")
                await self.finish(); return
            }
            await self.log("Extracted \(((try? String(contentsOfFile: out, encoding: .utf8))?.split(separator: "\n").count) ?? 0) hc22000 record(s)")
            hcPath = out
        }

        // 2) проверка scope (если задан BSSID)
        if !scope.isEmpty, let content = try? String(contentsOfFile: hcPath, encoding: .utf8) {
            let macs = content.split(separator: "\n").compactMap { line -> String? in
                let p = line.split(separator: "*"); return p.count > 3 ? String(p[3]).lowercased() : nil
            }
            if !macs.isEmpty && !macs.contains(scope) {
                await self.log("[error] Capture does not contain scoped BSSID \(scope). Recovery stopped.")
                await self.finish(); return
            }
        }

        // 3) стадии подбора
        let pot = hcPath + ".pot"
        let (smart, mask) = await MainActor.run { (self.smartStrategy, self.tryDigitMask) }
        var stages: [(label: String, args: [String])] = []
        if smart {
            let common = NSTemporaryDirectory() + "marauder_common_\(UUID().uuidString).txt"
            try? CommonPasswords.list.joined(separator: "\n").write(toFile: common, atomically: true, encoding: .utf8)
            stages.append(("common and default passwords (\(CommonPasswords.list.count))", ["-a", "0", hcPath, common]))
        }
        if mask {
            stages.append(("eight-digit mask (?d x 8)", ["-a", "3", hcPath, "?d?d?d?d?d?d?d?d"]))
        }
        if !wordlist.isEmpty {
            stages.append(("wordlist \((wordlist as NSString).lastPathComponent)", ["-a", "0", hcPath, wordlist]))
        }
        guard !stages.isEmpty else {
            await self.log("[error] No recovery stage selected. Enable a strategy or choose a wordlist.")
            await self.finish(); return
        }

        var found: [String] = []
        for (i, stage) in stages.enumerated() {
            if await MainActor.run(body: { !self.running }) { break }
            await self.log("Stage \(i + 1)/\(stages.count): \(stage.label)")
            // -w 1 (low) = щадящий режим: Mac остаётся отзывчивым во время перебора
            let args = ["-m", "22000"] + stage.args
                + ["--potfile-path", pot, "--status", "--status-timer", "5", "-w", "1"]
            _ = await self.runTool(hashcat, args, tag: "hashcat")
            found = await self.checkCracked(hashcat: hashcat, hc: hcPath, pot: pot)
            if !found.isEmpty { break }
            await self.log("No match in this stage")
        }

        let tried = stages.map { $0.label }.joined(separator: ", ")
        let results = found
        await MainActor.run {
            self.recovered = results
            if results.isEmpty {
                self.add("No password recovered after \(tried) attempt(s).")
                self.add("The credential may be strong or absent from the selected wordlists.")
            }
            else {
                results.forEach { self.add("[ok] Recovered \($0)") }
                self.notify("Password recovered: \(results.first ?? "")", sound: "Hero")
                self.onCracked?(results.first ?? "")
            }
        }
        await self.finish()
    }

    private nonisolated func checkCracked(hashcat: String, hc: String, pot: String) async -> [String] {
        let show = await self.capture(hashcat, ["-m", "22000", hc, "--show", "--potfile-path", pot])
        var found: [String] = []
        for line in show.split(separator: "\n") {
            let parts = line.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count >= 5, let pwd = parts.last, !pwd.isEmpty else { continue }
            found.append("\(String(parts[parts.count - 2])) : \(pwd)")
        }
        return found
    }

    /// Скачать словарь rockyou и выбрать его (curl, в Application Support).
    func downloadWordlist() {
        guard !downloading else { return }
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Marauder")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dest = (dir as NSString).appendingPathComponent("rockyou.txt")
        if FileManager.default.fileExists(atPath: dest) {
            wordlistPath = dest; add("Wordlist is already available: \(dest)"); return
        }
        downloading = true
        add("[info] Downloading rockyou.txt (about 134 MB)")
        let url = "https://github.com/brannondorsey/naive-hashcat/releases/download/data/rockyou.txt"
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.runTool("/usr/bin/curl", ["-L", "--fail", "-o", dest, url], tag: "curl")
            self.downloading = false
            if ok && FileManager.default.fileExists(atPath: dest) {
                self.wordlistPath = dest
                self.add("[ok] Wordlist downloaded and selected")
            } else {
                self.add("[error] Wordlist download failed")
            }
        }
    }

    private func terminateCurrentProcess() {
        proc?.terminate()
        if let pid = proc?.processIdentifier { kill(pid, SIGKILL) }
    }

    // MARK: - запуск внешних процессов

    private nonisolated func runTool(_ path: String, _ args: [String], tag: String,
                                     cwd: String? = nil) async -> Bool {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.qualityOfService = .background   // фоновый приоритет CPU/GPU — дисплей не залипнет
            if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor [weak self] in self?.add(s.trimmingCharacters(in: .newlines)) }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: proc.terminationStatus == 0)
            }
            Task { @MainActor [weak self] in self?.proc = p }
            do { try p.run() } catch {
                Task { @MainActor [weak self] in self?.add("[\(tag)] launch failed: \(error.localizedDescription)") }
                cont.resume(returning: false)
            }
        }
    }

    private nonisolated func capture(_ path: String, _ args: [String]) async -> String {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            do { try p.run() } catch { cont.resume(returning: ""); return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
        }
    }

    private func log(_ s: String) { add(s) }
    private func finish() { running = false; proc = nil }
}
