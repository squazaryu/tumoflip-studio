import Foundation

/// Движок аудита: из Dataset генерирует findings со severity и рекомендациями.
public enum Audit {

    public static func analyze(_ ds: Dataset) -> [Finding] {
        var out: [Finding] = []
        var n = 0
        func add(_ sev: Severity, _ title: String, ssid: String?, bssid: String?,
                 _ evidence: String, _ remediation: String) {
            n += 1
            out.append(Finding(id: String(format: "F%03d", n), severity: sev, title: title,
                               ssid: ssid, bssid: bssid, evidence: evidence, remediation: remediation))
        }

        let aps = Array(ds.aps.values)

        // --- шифрование / скрытые ---
        for ap in aps {
            let enc = (ap.encryption ?? "").uppercased()
            if enc == "OPEN" {
                add(.high, "Open network without encryption", ssid: ap.ssid, bssid: ap.bssid,
                    "encryption=OPEN bssid=\(ap.bssid ?? "?")",
                    "Enable WPA2/WPA3-PSK. Use open networks only with client isolation.")
            } else if enc == "WEP" {
                add(.critical, "Deprecated WEP encryption", ssid: ap.ssid, bssid: ap.bssid,
                    "encryption=WEP bssid=\(ap.bssid ?? "?")",
                    "Migrate to WPA2 or WPA3 immediately.")
            } else if enc.contains("WPA") && !enc.contains("2") && !enc.contains("3") {
                add(.high, "Weak WPA mode using TKIP", ssid: ap.ssid, bssid: ap.bssid,
                    "encryption=\(enc) bssid=\(ap.bssid ?? "?")",
                    "Migrate to WPA2-AES or WPA3.")
            }
            if ap.hidden {
                add(.low, "Hidden SSID", ssid: nil, bssid: ap.bssid,
                    "hidden=true bssid=\(ap.bssid ?? "?")",
                    "SSID hiding is not a security boundary; probe traffic may reveal the name.")
            }
        }

        // --- дубликаты SSID / evil twin ---
        var bySsid: [String: [AccessPoint]] = [:]
        for ap in aps { if let s = ap.ssid { bySsid[s, default: []].append(ap) } }
        for (ssid, group) in bySsid where group.count > 1 {
            let bssids = Set(group.compactMap { $0.bssid }).sorted()
            if bssids.count > 1 {
                let vendors = Set(group.map { $0.vendor }.filter { !$0.isEmpty })
                let encs = Set(group.map { ($0.encryption ?? "").uppercased() })
                let sev: Severity = (vendors.count > 1 || encs.count > 1) ? .high : .medium
                add(sev, sev == .high ? "Possible evil twin or SSID duplicate" : "SSID used by multiple BSSIDs",
                    ssid: ssid, bssid: nil,
                    "ssid=\(ssid) bssids=\(bssids.joined(separator: ","))",
                    "Compare BSSIDs with the authorized inventory and physically locate unknown access points.")
            }
        }

        // --- перегруженные каналы ---
        var chCount: [Int: Int] = [:]
        for ap in aps { if let c = ap.channel { chCount[c, default: 0] += 1 } }
        for (ch, cnt) in chCount where cnt >= 6 {
            add(.low, "Congested channel \(ch)", ssid: nil, bssid: nil,
                "channel=\(ch) aps=\(cnt)",
                "Move 2.4 GHz access points to channels 1, 6 or 11, or use 5 GHz.")
        }

        // --- deauth-активность ---
        if !ds.deauths.isEmpty {
            let sev: Severity = ds.deauths.count >= 10 ? .high : .medium
            add(sev, "Deauthentication or disassociation activity detected", ssid: nil, bssid: nil,
                "deauth_frames=\(ds.deauths.count)",
                "Enable 802.11w PMF and locate the source.")
        }

        // --- probe-активность ---
        if ds.probes.count >= 30 {
            let uniq = Set(ds.probes.map { $0.mac }).count
            add(.low, "High probe request activity", ssid: nil, bssid: nil,
                "probe_requests=\(ds.probes.count) unique_devices=\(uniq)",
                "Compare devices with the authorized inventory and use WIDS where appropriate.")
        }

        if out.isEmpty {
            add(.low, "No obvious issues detected", ssid: nil, bssid: nil,
                "no issues matched",
                "Complete the audit with manual checks of segmentation, credentials and firmware.")
        }
        return out
    }

    public static func riskScore(_ findings: [Finding]) -> Int {
        findings.reduce(0) { $0 + $1.severity.weight }
    }

    public static func riskLevel(_ score: Int) -> Severity {
        if score >= 24 { return .critical }
        if score >= 12 { return .high }
        if score >= 5 { return .medium }
        return .low
    }
}
