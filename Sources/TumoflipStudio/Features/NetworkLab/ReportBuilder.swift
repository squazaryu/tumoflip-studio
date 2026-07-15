import Foundation
import MarauderKit

/// Сборка автономного HTML-отчёта сессии (тёмная тема, без внешних зависимостей).
enum ReportBuilder {
    private static func esc(_ s: String?) -> String {
        (s ?? "").replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
    private static func sevColor(_ s: Severity) -> String {
        switch s {
        case .critical: return "#bd5bff"; case .high: return "#ff6b6b"
        case .medium: return "#ffb454"; case .low: return "#7bd88f"
        }
    }

    static func html(aps: [AccessPoint], stations: [Station], findings: [Finding],
                     risk: Severity, score: Int, probes: Int, deauths: Int) -> String {
        let when = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)

        let apRows = aps.map { a in
            "<tr><td>\(esc(a.displaySSID))</td><td class=mono>\(esc(a.bssid))</td>"
            + "<td>\(a.channel.map(String.init) ?? "")</td>"
            + "<td style='color:\(rssiColor(a.rssi))'>\(a.rssi.map(String.init) ?? "")</td>"
            + "<td>\(esc(a.encryption))</td><td>\(esc(a.vendor))</td><td>\(a.countSeen)</td></tr>"
        }.joined()

        let staRows = stations.map { s in
            "<tr><td class=mono>\(esc(s.mac))</td><td class=mono>\(esc(s.bssid))</td>"
            + "<td>\(esc(s.vendor))</td><td>\(s.randomized ? "Yes" : "")</td>"
            + "<td style='color:\(rssiColor(s.rssi))'>\(s.rssi.map(String.init) ?? "")</td>"
            + "<td>\(esc(s.probes.prefix(5).joined(separator: "; ")))</td></tr>"
        }.joined()

        let findRows = findings.map { f in
            "<tr><td><span class=badge style='background:\(sevColor(f.severity))'>\(f.severity.rawValue)</span></td>"
            + "<td>\(esc(f.title))</td><td>\(esc(f.ssid)) \(esc(f.bssid))</td><td>\(esc(f.remediation))</td></tr>"
        }.joined()

        return """
        <!doctype html><html lang=en><head><meta charset=utf-8>
        <title>Tumoflip Studio Network Lab Report</title><style>
        body{font-family:-apple-system,Segoe UI,Roboto,sans-serif;margin:0;background:#0e1116;color:#e6e6e6}
        header{background:#161d28;padding:18px 26px;border-bottom:2px solid #4f8cff}
        h1{margin:0;font-size:20px} h2{color:#7fb3ff;margin:26px 0 8px;font-size:15px}
        .wrap{max-width:1150px;margin:0 auto;padding:0 22px 50px}
        .kpis{display:flex;gap:12px;flex-wrap:wrap;margin:16px 0}
        .kpi{background:#161d28;border:1px solid #ffffff14;border-radius:10px;padding:12px 16px;min-width:90px}
        .kpi .n{font-size:22px;font-weight:700}.kpi .l{color:#9bb0c9;font-size:11px}
        table{width:100%;border-collapse:collapse;font-size:13px;background:#141b24;border-radius:8px;overflow:hidden;margin-top:6px}
        th,td{padding:7px 10px;text-align:left;border-bottom:1px solid #243041}
        th{background:#22303f;color:#cfe0f5}.mono{font-family:ui-monospace,Menlo,monospace}
        .badge{color:#fff;border-radius:5px;padding:1px 8px;font-size:11px}
        .risk{font-weight:700;color:#fff;padding:5px 12px;border-radius:8px;background:\(sevColor(risk))}
        </style></head><body>
        <header><h1>Tumoflip Studio Network Lab Report</h1>
        <div style='color:#9bb0c9;font-size:12px;margin-top:5px'>\(when) · authorized network audit only</div></header>
        <div class=wrap>
          <div class=kpis>
            <div class=kpi><div class=n>\(aps.count)</div><div class=l>Access Points</div></div>
            <div class=kpi><div class=n>\(stations.count)</div><div class=l>Clients</div></div>
            <div class=kpi><div class=n>\(probes)</div><div class=l>Probe</div></div>
            <div class=kpi><div class=n>\(deauths)</div><div class=l>Deauth</div></div>
            <div class=kpi><div class=n><span class=risk>\(risk.rawValue)</span></div><div class=l>Risk (\(score))</div></div>
          </div>
          <h2>Security Findings</h2>
          <table><thead><tr><th>Severity</th><th>Finding</th><th>Target</th><th>Recommendation</th></tr></thead><tbody>\(findRows)</tbody></table>
          <h2>Access Points</h2>
          <table><thead><tr><th>SSID</th><th>BSSID</th><th>Ch</th><th>RSSI</th><th>Security</th><th>Vendor</th><th>Seen</th></tr></thead><tbody>\(apRows)</tbody></table>
          <h2>Clients</h2>
          <table><thead><tr><th>MAC</th><th>AP</th><th>Vendor</th><th>Rnd</th><th>RSSI</th><th>Probe SSID</th></tr></thead><tbody>\(staRows)</tbody></table>
        </div></body></html>
        """
    }

    private static func rssiColor(_ v: Int?) -> String {
        guard let v else { return "#9bb0c9" }
        if v >= -55 { return "#7bd88f" }; if v >= -75 { return "#ffb454" }; return "#ff6b6b"
    }
}
