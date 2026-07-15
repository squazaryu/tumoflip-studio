import Foundation

/// OUI -> vendor. По умолчанию компактный встроенный набор; при загрузке полной
/// базы IEEE (`OUIStore.shared.loadIEEE`) — ~39 тыс. вендоров.
public enum OUI {
    static let builtin: [String: String] = [
        "00:00:0c": "Cisco", "00:1a:11": "Google", "00:1b:63": "Apple",
        "00:1d:0f": "TP-Link", "00:25:9c": "Cisco-Linksys", "3c:5a:b4": "Google",
        "5c:cf:7f": "Espressif", "24:0a:c4": "Espressif", "7c:9e:bd": "Espressif",
        "a4:cf:12": "Espressif", "dc:a6:32": "Raspberry Pi", "b8:27:eb": "Raspberry Pi",
        "e4:5f:01": "Raspberry Pi", "f0:9f:c2": "Ubiquiti", "fc:ec:da": "Ubiquiti",
        "00:50:f2": "Microsoft", "ac:de:48": "Apple", "d8:eb:97": "TRENDnet",
        "ec:08:6b": "TP-Link", "50:c7:bf": "TP-Link", "c0:25:e9": "TP-Link",
        "90:9a:4a": "TP-Link", "00:0e:8e": "SparkLAN", "20:34:fb": "Xiaomi",
        "28:6c:07": "Xiaomi", "34:ce:00": "Xiaomi", "00:24:36": "Apple",
        "f4:f5:d8": "Google", "44:07:0b": "Google",
    ]

    public static func vendor(_ mac: String?) -> String {
        guard let mac, mac.count >= 8 else { return "" }
        return OUIStore.shared.vendor(String(mac.lowercased().prefix(8))) ?? ""
    }

    /// MAC локально-администрируемый (рандомизированный приватный)?
    public static func isRandomized(_ mac: String?) -> Bool {
        guard let mac, mac.count >= 2,
              let first = UInt8(mac.prefix(2), radix: 16) else { return false }
        return (first & 0x02) != 0
    }
}

/// Хранилище таблицы OUI с возможностью подгрузить полную базу IEEE.
public final class OUIStore: @unchecked Sendable {
    public static let shared = OUIStore()
    private var table: [String: String]
    private let lock = NSLock()

    private init() { table = OUI.builtin }

    public func vendor(_ prefix: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return table[prefix]
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return table.count }

    /// Распарсить IEEE oui.txt (строки вида "28-6F-B9   (hex)\t\tVendor"). Вернуть число записей.
    @discardableResult
    public func loadIEEE(path: String) -> Int {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        var t = OUI.builtin
        content.enumerateLines { line, _ in
            guard let r = line.range(of: "(hex)") else { return }
            let pfx = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let name = line[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            let key = pfx.replacingOccurrences(of: "-", with: ":").lowercased()
            if key.count == 8 && !name.isEmpty { t[key] = name }
        }
        lock.lock(); table = t; lock.unlock()
        return t.count
    }
}
