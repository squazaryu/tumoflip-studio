import Foundation

/// Эвристическая классификация устройства по вендору (OUI) + признаку рандомизации.
/// MAC даёт только производителя — точную модель определить нельзя, поэтому это
/// оценка категории, а не модель.
public enum DeviceClassifier {

    // (иконка, подписи-маркеры в имени вендора)
    private static let rules: [(icon: String, label: String, keys: [String])] = [
        ("📱", "Apple",        ["apple"]),
        ("📱", "Samsung",      ["samsung"]),
        ("📱", "Smartphone",   ["xiaomi", "huawei", "honor", "oneplus", "oppo", "vivo",
                                "realme", "motorola", "nokia", "sony mobile", "zte",
                                "lenovo mobile", "tecno", "infinix"]),
        ("📡", "Router / AP",  ["tp-link", "netgear", "d-link", "asustek", "asus", "ubiquiti",
                                "mikrotik", "keenetic", "zyxel", "tenda", "mercusys", "ruckus",
                                "aruba", "eero", "cisco", "linksys", "huawei technolog",
                                "sagemcom", "technicolor", "arris", "zte corp"]),
        ("🔌", "IoT (ESP)",    ["espressif"]),
        ("🍓", "Raspberry Pi", ["raspberry"]),
        ("🏠", "Smart Home",   ["tuya", "sonoff", "itead", "shelly", "espressif inc",
                                "nest", "ring", "ecobee", "philips lighting", "signify",
                                "tp-link tech", "broadlink"]),
        ("🔊", "Audio",        ["sonos", "bose", "harman", "yamaha", "marshall", "jbl",
                                "denon", "sennheiser"]),
        ("📺", "TV / Media",   ["roku", "vizio", "hisense", "tcl", "lg electronics",
                                "amlogic", "skyworth", "philips consumer"]),
        ("🔊", "Amazon",       ["amazon"]),
        ("🎮", "Game Console", ["nintendo", "sony interactive", "microsoft"]),
        ("⌚", "Wearable",     ["garmin", "fitbit", "withings", "polar electro"]),
        ("🖨️", "Printer",      ["hewlett", "canon", "epson", "brother", "kyocera", "xerox"]),
        ("💻", "Computer",     ["intel", "realtek", "liteon", "lite-on", "azurewave", "hon hai",
                                "foxconn", "quanta", "compal", "wistron", "qualcomm", "broadcom",
                                "murata", "dell", "micro-star", "msi", "gigabyte", "framework"]),
        ("🔌", "BLE/IoT",      ["texas instrument", "nordic", "silicon lab", "u-blox",
                                "particle", "seeed"]),
    ]

    /// Вернуть (иконка, метка) — оценка типа устройства.
    public static func classify(vendor: String, randomized: Bool) -> (icon: String, label: String) {
        let v = vendor.lowercased()
        if !v.isEmpty {
            for r in rules where r.keys.contains(where: { v.contains($0) }) {
                return (r.icon, r.label)
            }
            return ("🏷️", vendor)              // вендор известен, но категория не определена
        }
        if randomized { return ("🔒", "Private MAC") }
        return ("❔", "Unknown")
    }

    public static func short(vendor: String, randomized: Bool) -> String {
        let c = classify(vendor: vendor, randomized: randomized)
        return "\(c.icon) \(c.label)"
    }
}
