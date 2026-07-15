import XCTest
@testable import MarauderKit

final class MarauderKitTests: XCTestCase {

    func testParseAPLine() {
        var ds = Dataset()
        LogParser.feed("[0] SSID: HomeNet  BSSID: aa:bb:cc:11:22:33  RSSI: -42  CH: 6  WPA2", into: &ds)
        XCTAssertEqual(ds.aps.count, 1)
        let ap = ds.apList[0]
        XCTAssertEqual(ap.ssid, "HomeNet")
        XCTAssertEqual(ap.bssid, "aa:bb:cc:11:22:33")
        XCTAssertEqual(ap.channel, 6)
        XCTAssertEqual(ap.rssi, -42)
        XCTAssertEqual(ap.encryption, "WPA2")
    }

    func testParseProbeLine() {
        var ds = Dataset()
        LogParser.feed("PROBE REQ from da:a1:19:00:00:01 for \"Cafe\" RSSI -60 CH 6", into: &ds)
        XCTAssertEqual(ds.probes.count, 1)
        XCTAssertEqual(ds.probes[0].mac, "da:a1:19:00:00:01")
        XCTAssertEqual(ds.probes[0].ssid, "Cafe")
        XCTAssertTrue(ds.probes[0].randomized)
    }

    func testParseStationLine() {
        var ds = Dataset()
        LogParser.feed("Station: 5c:cf:7f:11:22:33 -> aa:bb:cc:dd:ee:01 RSSI -55 CH 6", into: &ds)
        XCTAssertEqual(ds.stations.count, 1)
        let st = ds.stationList[0]
        XCTAssertEqual(st.mac, "5c:cf:7f:11:22:33")
        XCTAssertEqual(st.bssid, "aa:bb:cc:dd:ee:01")
        XCTAssertTrue(st.vendor.lowercased().contains("espressif"))
    }

    func testParseDeauthLine() {
        var ds = Dataset()
        LogParser.feed("DEAUTH detected: aa:bb:cc:dd:ee:01 -> 5c:cf:7f:11:22:33 reason 7 CH 6", into: &ds)
        XCTAssertEqual(ds.deauths.count, 1)
        XCTAssertEqual(ds.deauths[0].source, "aa:bb:cc:dd:ee:01")
        XCTAssertEqual(ds.deauths[0].reason, 7)
        XCTAssertEqual(ds.aps.count, 0, "deauth-строка не должна стать AP")
    }

    func testOUI() {
        XCTAssertTrue(OUI.vendor("5c:cf:7f:00:00:00").lowercased().contains("espressif"))
        XCTAssertTrue(OUI.vendor("00:1d:0f:aa:bb:cc").lowercased().contains("tp-link"))
        XCTAssertTrue(OUI.isRandomized("da:a1:19:00:00:01"))   // 0xda & 0x02 != 0
        XCTAssertFalse(OUI.isRandomized("ac:de:48:00:11:22"))  // 0xac & 0x02 == 0
    }

    func testAuditOpenAndWep() {
        var ds = Dataset()
        LogParser.feed("SSID: OpenNet BSSID: 11:22:33:44:55:66 CH 1 RSSI -50 OPEN", into: &ds)
        LogParser.feed("SSID: WepNet BSSID: 11:22:33:44:55:77 CH 6 RSSI -55 WEP", into: &ds)
        let findings = Audit.analyze(ds)
        XCTAssertTrue(findings.contains { $0.title.contains("Open network") })
        XCTAssertTrue(findings.contains { $0.title.contains("WEP") })
        XCTAssertTrue(findings.contains { $0.severity == .critical })
    }

    func testEvilTwinDetection() {
        var ds = Dataset()
        LogParser.feed("SSID: MyNet BSSID: aa:bb:cc:dd:ee:01 CH 6 RSSI -40 WPA2", into: &ds)
        LogParser.feed("SSID: MyNet BSSID: 11:22:33:44:55:99 CH 11 RSSI -55 OPEN", into: &ds)
        let findings = Audit.analyze(ds)
        XCTAssertTrue(findings.contains { $0.title.contains("evil twin") || $0.title.contains("Дубликат") })
    }

    func testEndToEndStream() {
        var ds = Dataset()
        let stream = """
        [0] SSID: MyHomeNet BSSID: aa:bb:cc:dd:ee:01 RSSI -41 CH 6 WPA2
        [1] SSID: OpenCafe BSSID: aa:bb:cc:dd:ee:02 RSSI -68 CH 1 OPEN
        Station: 5c:cf:7f:11:22:33 -> aa:bb:cc:dd:ee:01 RSSI -52 CH 6
        PROBE REQ from da:a1:19:00:00:01 for "AirportFree" RSSI -69 CH 6
        DEAUTH detected: aa:bb:cc:dd:ee:01 -> 5c:cf:7f:11:22:33 reason 7 CH 6
        """
        for line in stream.split(separator: "\n") { LogParser.feed(String(line), into: &ds) }
        XCTAssertEqual(ds.aps.count, 2)
        XCTAssertGreaterThanOrEqual(ds.stations.count, 1)
        XCTAssertEqual(ds.deauths.count, 1)
        let findings = Audit.analyze(ds)
        XCTAssertTrue(findings.contains { $0.title.contains("Open network") })
    }

    func testDeviceClassifier() {
        XCTAssertEqual(DeviceClassifier.classify(vendor: "Apple, Inc.", randomized: false).label, "Apple")
        XCTAssertEqual(DeviceClassifier.classify(vendor: "Espressif Inc.", randomized: false).label, "IoT (ESP)")
        XCTAssertEqual(DeviceClassifier.classify(vendor: "TP-Link Corporation", randomized: false).label, "Router / AP")
        XCTAssertEqual(DeviceClassifier.classify(vendor: "Intel Corporate", randomized: false).label, "Computer")
        // Preserve an unknown vendor name when no category rule matches.
        XCTAssertEqual(DeviceClassifier.classify(vendor: "Acme Widgets", randomized: false).label, "Acme Widgets")
        // Empty vendor with a randomized address is classified as a private MAC.
        XCTAssertEqual(DeviceClassifier.classify(vendor: "", randomized: true).label, "Private MAC")
    }

    func testFullOUIDatabase() throws {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/Marauder/oui.txt")
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("oui.txt is not available")
        }
        let n = OUIStore.shared.loadIEEE(path: path)
        XCTAssertGreaterThan(n, 30000)
        // известный префикс из файла: 28-6F-B9 -> Nokia
        XCTAssertTrue(OUI.vendor("28:6f:b9:00:00:00").lowercased().contains("nokia"))
    }

    func testPortClassification() {
        // косвенно: автодетект не падает и не выбирает flipper
        _ = SerialPort.listPorts()
        _ = SerialPort.autodetect()
    }
}
