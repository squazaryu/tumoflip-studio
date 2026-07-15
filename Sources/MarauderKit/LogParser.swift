import Foundation

/// Толерантный парсер текстового вывода ESP32 Marauder (порт logs.py).
/// Нераспознанные строки игнорируются — разбор не падает.
public enum LogParser {

    // Предкомпилированные шаблоны (inline-флаг (?i) — регистронезависимо).
    static let macRE = try! Regex(#"\b([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})\b"#)
    static let rssiRE = try! Regex(#"(?i)(?:RSSI|rssi)[:\s]*(-?\d{1,3})"#)
    static let rssiDbmRE = try! Regex(#"(-\d{2,3})\b"#)
    static let chRE = try! Regex(#"(?i)(?:Ch(?:annel)?|CH)[:\s]*?(\d{1,3})\b"#)
    static let ssidRE = try! Regex(#"(?i)(?:ESSID|SSID)[:\s]+(.+?)\s*(?:\bBSSID\b|\bRSSI\b|\bCh(?:annel)?\b|\bCH\b|\||\s{2,}|$)"#)
    static let encRE = try! Regex(#"(?i)\b(WPA3|WPA2/WPA3|WPA2|WPA/WPA2|WPA|WEP|OPEN|OWE|ENTERPRISE)\b"#)
    static let probeSsidRE = try! Regex(#"(?i)(?:for|->)\s*["“]?(.+?)["”]?\s*(?:RSSI|CH|$)"#)
    static let deauthRE = try! Regex(#"(?i)deauth|disassoc"#)
    static let stationRE = try! Regex(#"(?i)\bstation\b|\bsta\b|->"#)
    static let probeRE = try! Regex(#"(?i)probe"#)
    static let reasonRE = try! Regex(#"(?i)reason[:\s]*(\d{1,3})"#)

    static func group(_ re: Regex<AnyRegexOutput>, _ s: String, _ i: Int = 1) -> String? {
        guard let m = try? re.firstMatch(in: s), i < m.output.count,
              let sub = m.output[i].substring else { return nil }
        return String(sub)
    }

    static func matched(_ re: Regex<AnyRegexOutput>, _ s: String) -> Bool {
        ((try? re.firstMatch(in: s)) ?? nil) != nil
    }

    static func macs(_ s: String) -> [String] {
        s.matches(of: macRE).compactMap { m in
            m.output[1].substring.map { String($0).lowercased() }
        }
    }

    static func rssi(_ s: String) -> Int? {
        if let g = group(rssiRE, s), let v = Int(g) { return v }
        for m in s.matches(of: rssiDbmRE) {
            if let sub = m.output[1].substring, let v = Int(sub), v >= -100, v <= -10 { return v }
        }
        return nil
    }

    static func channel(_ s: String) -> Int? {
        guard let g = group(chRE, s), let v = Int(g), v >= 1, v <= 196 else { return nil }
        return v
    }

    static func enc(_ s: String) -> String? {
        group(encRE, s).map { $0.uppercased() }
    }

    public static func parseAP(_ line: String) -> AccessPoint? {
        let m = macs(line)
        guard let bssid = m.first else { return nil }
        var ssid = group(ssidRE, line)?.trimmingCharacters(in: .whitespaces)
        ssid = ssid?.replacingOccurrences(of: "|", with: "").trimmingCharacters(in: .whitespaces)
        let hidden = (ssid == nil) || ssid!.isEmpty ||
            ["(hidden)", "<hidden>", "hidden"].contains(ssid!.lowercased())
        return AccessPoint(
            ssid: hidden ? nil : ssid, bssid: bssid, channel: channel(line),
            rssi: rssi(line), encryption: enc(line), vendor: OUI.vendor(bssid),
            hidden: hidden, countSeen: 1)
    }

    public static func parseStation(_ line: String) -> Station? {
        guard matched(stationRE, line) else { return nil }
        let m = macs(line)
        guard let mac = m.first else { return nil }
        let bssid = m.count > 1 ? m[1] : nil
        return Station(mac: mac, bssid: bssid, rssi: rssi(line), channel: channel(line),
                       vendor: OUI.vendor(mac), randomized: OUI.isRandomized(mac), countSeen: 1)
    }

    public static func parseProbe(_ line: String) -> ProbeRequest? {
        guard matched(probeRE, line) else { return nil }
        let m = macs(line)
        guard let mac = m.first else { return nil }
        var ssid = group(probeSsidRE, line)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) ?? ""
        if ["broadcast", "any", "*", "wildcard"].contains(ssid.lowercased()) { ssid = "" }
        return ProbeRequest(mac: mac, ssid: ssid, rssi: rssi(line), channel: channel(line),
                            vendor: OUI.vendor(mac), randomized: OUI.isRandomized(mac))
    }

    public static func parseDeauth(_ line: String) -> DeauthEvent? {
        guard matched(deauthRE, line) else { return nil }
        let m = macs(line)
        let src = m.first
        let dst = m.count > 1 ? m[1] : nil
        let reason = group(reasonRE, line).flatMap { Int($0) }
        return DeauthEvent(bssid: src, source: src, dest: dst, reason: reason, channel: channel(line))
    }

    /// Разобрать строку и применить к Dataset (порядок как в logs.py).
    /// Возвращает true, если строка изменила инвентарь (для триггера UI-обновления).
    @discardableResult
    public static func feed(_ rawLine: String, into ds: inout Dataset) -> Bool {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return false }
        if let d = parseDeauth(line) { ds.add(d); return true }
        if let p = parseProbe(line) { ds.add(p); return true }
        if let s = parseStation(line) { ds.upsert(s); return true }
        if let a = parseAP(line) { ds.upsert(a); return true }
        return false
    }
}
