import Foundation

/// Точка доступа Wi-Fi (агрегированная по BSSID).
public struct AccessPoint: Identifiable, Equatable, Sendable {
    public var id: String { (bssid ?? "ssid:\(ssid ?? "")").lowercased() }
    public var ssid: String?
    public var bssid: String?
    public var channel: Int?
    public var rssi: Int?
    public var encryption: String?
    public var vendor: String = ""
    public var hidden: Bool = false
    public var countSeen: Int = 0
    public var rssiSamples: [Int] = []

    public init(ssid: String? = nil, bssid: String? = nil, channel: Int? = nil,
                rssi: Int? = nil, encryption: String? = nil, vendor: String = "",
                hidden: Bool = false, countSeen: Int = 0) {
        self.ssid = ssid; self.bssid = bssid; self.channel = channel
        self.rssi = rssi; self.encryption = encryption; self.vendor = vendor
        self.hidden = hidden; self.countSeen = countSeen
    }

    // отображение / сортировка
    public var displaySSID: String { (ssid?.isEmpty == false) ? ssid! : "Hidden network" }
    public var bssidDisplay: String { bssid ?? "" }
    public var encDisplay: String { encryption ?? "" }
    public var rssiSort: Int { rssi ?? -127 }
    public var channelSort: Int { channel ?? 0 }
}

/// Клиентское устройство (station).
public struct Station: Identifiable, Equatable, Sendable {
    public var id: String { (mac ?? "").lowercased() }
    public var mac: String?
    public var bssid: String?
    public var rssi: Int?
    public var channel: Int?
    public var vendor: String = ""
    public var randomized: Bool = false
    public var countSeen: Int = 0
    public var probes: [String] = []
    public var rssiSamples: [Int] = []

    public init(mac: String? = nil, bssid: String? = nil, rssi: Int? = nil,
                channel: Int? = nil, vendor: String = "", randomized: Bool = false,
                countSeen: Int = 0, probes: [String] = []) {
        self.mac = mac; self.bssid = bssid; self.rssi = rssi; self.channel = channel
        self.vendor = vendor; self.randomized = randomized
        self.countSeen = countSeen; self.probes = probes
    }

    // отображение / сортировка
    public var macDisplay: String { mac ?? "" }
    public var apDisplay: String { bssid ?? "" }
    public var rssiSort: Int { rssi ?? -127 }
    public var probesDisplay: String { probes.prefix(4).joined(separator: ";") }
    /// Оценка типа устройства по вендору/рандомизации (не точная модель).
    public var deviceType: String { DeviceClassifier.short(vendor: vendor, randomized: randomized) }
}

public struct ProbeRequest: Sendable {
    public var mac: String
    public var ssid: String      // "" = broadcast/wildcard
    public var rssi: Int?
    public var channel: Int?
    public var vendor: String = ""
    public var randomized: Bool = false
    public init(mac: String, ssid: String, rssi: Int? = nil, channel: Int? = nil,
                vendor: String = "", randomized: Bool = false) {
        self.mac = mac; self.ssid = ssid; self.rssi = rssi; self.channel = channel
        self.vendor = vendor; self.randomized = randomized
    }
}

public struct DeauthEvent: Sendable {
    public var bssid: String?
    public var source: String?
    public var dest: String?
    public var reason: Int?
    public var channel: Int?
    public init(bssid: String? = nil, source: String? = nil, dest: String? = nil,
                reason: Int? = nil, channel: Int? = nil) {
        self.bssid = bssid; self.source = source; self.dest = dest
        self.reason = reason; self.channel = channel
    }
}

public enum Severity: String, Sendable, CaseIterable {
    case critical = "Critical", high = "High", medium = "Medium", low = "Low"
    public var weight: Int {
        switch self { case .critical: 12; case .high: 7; case .medium: 3; case .low: 1 }
    }
}

public struct Finding: Identifiable, Sendable {
    public let id: String
    public var severity: Severity
    public var title: String
    public var ssid: String?
    public var bssid: String?
    public var evidence: String
    public var remediation: String
    public init(id: String, severity: Severity, title: String, ssid: String?,
                bssid: String?, evidence: String, remediation: String) {
        self.id = id; self.severity = severity; self.title = title
        self.ssid = ssid; self.bssid = bssid
        self.evidence = evidence; self.remediation = remediation
    }
}

/// Агрегатор наблюдений. Совместим по смыслу с Python Dataset.
public struct Dataset: Sendable {
    public private(set) var aps: [String: AccessPoint] = [:]
    public private(set) var stations: [String: Station] = [:]
    public private(set) var probes: [ProbeRequest] = []
    public private(set) var deauths: [DeauthEvent] = []
    public init() {}

    public mutating func upsert(_ ap: AccessPoint) {
        let key = ap.id
        if var cur = aps[key] {
            cur.ssid = cur.ssid ?? ap.ssid
            if let ch = ap.channel { cur.channel = ch }
            cur.encryption = cur.encryption ?? ap.encryption
            if cur.vendor.isEmpty { cur.vendor = ap.vendor }
            cur.hidden = cur.hidden || ap.hidden
            if let r = ap.rssi { cur.rssi = r; cur.rssiSamples.append(r) }
            cur.countSeen += max(ap.countSeen, 1)
            aps[key] = cur
        } else {
            var a = ap; a.countSeen = max(ap.countSeen, 1)
            if let r = ap.rssi { a.rssiSamples.append(r) }
            aps[key] = a
        }
    }

    public mutating func upsert(_ st: Station) {
        guard let mac = st.mac?.lowercased() else { return }
        if var cur = stations[mac] {
            cur.bssid = cur.bssid ?? st.bssid
            if let ch = st.channel { cur.channel = ch }
            if cur.vendor.isEmpty { cur.vendor = st.vendor }
            cur.randomized = cur.randomized || st.randomized
            if let r = st.rssi { cur.rssi = r; cur.rssiSamples.append(r) }
            cur.countSeen += max(st.countSeen, 1)
            for p in st.probes where !p.isEmpty && !cur.probes.contains(p) { cur.probes.append(p) }
            stations[mac] = cur
        } else {
            var s = st; s.mac = mac; s.countSeen = max(st.countSeen, 1)
            if let r = st.rssi { s.rssiSamples.append(r) }
            stations[mac] = s
        }
    }

    public mutating func add(_ pr: ProbeRequest) {
        probes.append(pr)
        var s = Station(mac: pr.mac, rssi: pr.rssi, channel: pr.channel,
                        vendor: pr.vendor, randomized: pr.randomized,
                        probes: pr.ssid.isEmpty ? [] : [pr.ssid])
        s.bssid = nil
        upsert(s)
    }

    public mutating func add(_ d: DeauthEvent) { deauths.append(d) }

    public var apList: [AccessPoint] {
        aps.values.sorted { ($0.rssi ?? -999) > ($1.rssi ?? -999) }
    }
    public var stationList: [Station] {
        stations.values.sorted { $0.countSeen > $1.countSeen }
    }
}
