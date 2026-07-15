import AppKit
import Foundation
import TumoCardCore
import UniformTypeIdentifiers

@MainActor
final class StudioStore: ObservableObject {
    @Published var selectedSection: StudioSection? = .overview
    @Published private(set) var connectionState: StudioConnectionState = .disconnected
    @Published private(set) var readerName: String?
    @Published private(set) var snapshot: CardSnapshot?
    @Published private(set) var timeline: [APDUEvent] = []
    @Published private(set) var history: [TumoCardReport] = []
    @Published var selectedHistoryID: UUID?
    @Published private(set) var historyError: String?

    private let pcsc = PCSCService()
    private let historyStore = SessionHistoryStore()
    private let decoderRegistry = CardDecoderRegistry()
    private var monitorTask: Task<Void, Never>?
    private var scannedCardFingerprint: String?
    private var scanTransportError: String?
    private var currentReport: TumoCardReport?
    private weak var transportCoordinator: TransportCoordinator?
    private let transportOwner = "TumoCard"

    init(transportCoordinator: TransportCoordinator? = nil) {
        self.transportCoordinator = transportCoordinator
    }

    func startMonitoring() {
        guard monitorTask == nil else { return }
        guard transportCoordinator?.acquire(.pcsc, owner: transportOwner) != false else {
            connectionState = .failed(transportCoordinator?.lastConflict ?? "USB CCID is busy")
            return
        }
        Task { await loadHistory() }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .milliseconds(750))
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        Task { await pcsc.disconnect() }
        transportCoordinator?.release(.pcsc, owner: transportOwner)
    }

    func refresh() {
        scannedCardFingerprint = nil
        Task { await poll() }
    }

    func exportJSON() {
        guard let report = currentReport, let data = try? report.jsonData() else { return }
        save(data: data, suggestedName: "tumocard-report.json", allowedType: .json)
    }

    func exportText() {
        guard let report = currentReport else { return }
        save(
            data: Data(report.text().utf8),
            suggestedName: "tumocard-report.txt",
            allowedType: .plainText
        )
    }

    func deleteSelectedHistory() {
        guard let selectedHistoryID else { return }
        Task {
            do {
                try await historyStore.delete(id: selectedHistoryID)
                self.selectedHistoryID = nil
                await loadHistory()
            } catch {
                historyError = error.localizedDescription
            }
        }
    }

    private func poll() async {
        do {
            let readers = try await pcsc.listReaders()
            guard let bridge = preferredBridge(in: readers) else {
                resetForDisconnectedBridge()
                return
            }
            readerName = bridge

            do {
                let connection = try await pcsc.refreshConnection(reader: bridge)
                let fingerprint = connection.atr.hex
                guard scannedCardFingerprint != fingerprint else {
                    if snapshot != nil { connectionState = .cardReady }
                    return
                }
                scannedCardFingerprint = fingerprint
                await scan(connection)
            } catch PCSCServiceError.noCard, PCSCServiceError.cardRemoved {
                resetForRemovedCard()
            }
        } catch PCSCServiceError.noReader {
            resetForDisconnectedBridge()
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }

    private func scan(_ connection: PCSCCardConnection) async {
        connectionState = .scanning
        snapshot = nil
        timeline.removeAll(keepingCapacity: true)
        scanTransportError = nil
        var applications: [CardApplication] = []
        var metadata: [PublicMetadataItem] = []
        var uid: String?

        if let command = try? APDUCommand.getUID(),
           let response = await perform(command),
           response.succeeded,
           !response.payload.isEmpty,
           response.payload.count <= 10 {
            uid = response.payload.hex
        }
        guard scanTransportError == nil else { return }

        if let command = try? APDUCommand.select(
            aid: KnownCardApplication.ppseAID,
            name: "Select payment directory"
        ), let response = await perform(command) {
            applications.append(contentsOf: CardApplicationParser.applications(from: response))
        }
        guard scanTransportError == nil else { return }

        let discoveredAIDs = applications.prefix(16).compactMap { Data(hex: $0.aid) }
        for aid in discoveredAIDs {
            if let command = try? APDUCommand.select(
                aid: aid,
                name: "Select \(KnownCardApplication.name(for: aid))"
            ), let response = await perform(command),
               let application = applications.first(where: { $0.aid == aid.hex }) {
                metadata.append(
                    contentsOf: decoderRegistry.decode(
                        application: application,
                        response: response
                    )
                )
            }
            guard scanTransportError == nil else { return }
        }

        await probeNDEF(applications: &applications, metadata: &metadata)
        guard scanTransportError == nil else { return }
        await probeKnownApplication(
            aid: KnownCardApplication.pivAID,
            name: "PIV",
            applications: &applications
        )
        guard scanTransportError == nil else { return }

        var seen = Set<String>()
        applications = applications.filter { seen.insert($0.aid).inserted }
        snapshot = CardSnapshot(
            readerName: connection.readerName,
            protocolName: connection.protocolName,
            atr: connection.atr.hex,
            uid: uid,
            applications: applications,
            metadata: deduplicatedMetadata(metadata)
        )
        connectionState = .cardReady
        if let snapshot {
            let report = TumoCardReport(card: snapshot, events: timeline)
            currentReport = report
            do {
                try await historyStore.save(report)
                await loadHistory()
            } catch {
                historyError = error.localizedDescription
            }
        }
    }

    private func probeNDEF(
        applications: inout [CardApplication],
        metadata: inout [PublicMetadataItem]
    ) async {
        let aid = KnownCardApplication.ndefAID
        guard !applications.contains(where: { $0.aid == aid.hex }),
              let selectApplication = try? APDUCommand.select(
                  aid: aid,
                  name: "Select NFC Forum Type 4 / NDEF"
              ),
              let selectResponse = await perform(selectApplication),
              selectResponse.succeeded else {
            return
        }

        applications.append(
            CardApplication(aid: aid.hex, name: "NFC Forum Type 4 / NDEF", source: "Direct probe")
        )
        guard let selectCC = try? APDUCommand.selectFile(
            id: 0xE103,
            name: "Select NDEF capability container"
        ), let selectCCResponse = await perform(selectCC), selectCCResponse.succeeded,
              let readCC = try? APDUCommand.readBinary(
                  offset: 0,
                  length: 15,
                  name: "Read NDEF capability container"
              ), let ccResponse = await perform(readCC), ccResponse.succeeded,
              let capability = try? NDEFType4CapabilityContainer.parse(ccResponse.payload) else {
            return
        }

        metadata.append(
            PublicMetadataItem(
                category: "NDEF",
                label: "Mapping version",
                value: String(format: "%d.%d", capability.mappingVersion >> 4, capability.mappingVersion & 0x0F)
            )
        )
        metadata.append(
            PublicMetadataItem(
                category: "NDEF",
                label: "Maximum size",
                value: "\(capability.maximumNDEFSize) bytes"
            )
        )

        guard capability.readAccess == 0x00,
              let selectNDEF = try? APDUCommand.selectFile(
                  id: capability.ndefFileID,
                  name: "Select NDEF data file"
              ), let selectNDEFResponse = await perform(selectNDEF), selectNDEFResponse.succeeded,
              let readLength = try? APDUCommand.readBinary(
                  offset: 0,
                  length: 2,
                  name: "Read NDEF message length"
              ), let lengthResponse = await perform(readLength), lengthResponse.succeeded,
              lengthResponse.payload.count >= 2 else {
            return
        }

        let ndefLength = Int(UInt16(lengthResponse.payload[0]) << 8 | UInt16(lengthResponse.payload[1]))
        guard ndefLength > 0,
              ndefLength <= min(Int(capability.maximumNDEFSize), 4096) else {
            return
        }

        var message = Data()
        var offset = 2
        while message.count < ndefLength {
            let remaining = ndefLength - message.count
            let chunkLength = UInt8(min(remaining, 0xFF))
            guard let readChunk = try? APDUCommand.readBinary(
                offset: UInt16(offset),
                length: chunkLength,
                name: "Read NDEF data"
            ), let chunkResponse = await perform(readChunk), chunkResponse.succeeded,
                  !chunkResponse.payload.isEmpty else {
                return
            }
            let accepted = chunkResponse.payload.prefix(remaining)
            message.append(accepted)
            offset += accepted.count
        }

        if let summaries = try? NDEFMessageParser.summaries(from: message) {
            metadata.append(
                PublicMetadataItem(
                    category: "NDEF",
                    label: "Records",
                    value: String(summaries.count)
                )
            )
            metadata.append(contentsOf: summaries.flatMap(\.metadata))
        }
    }

    private func probeKnownApplication(
        aid: Data,
        name: String,
        applications: inout [CardApplication]
    ) async {
        guard !applications.contains(where: { $0.aid == aid.hex }),
              let command = try? APDUCommand.select(aid: aid, name: "Select \(name)"),
              let response = await perform(command),
              response.succeeded else {
            return
        }
        applications.append(CardApplication(aid: aid.hex, name: name, source: "Direct probe"))
    }

    private func perform(_ command: APDUCommand) async -> APDUResponse? {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let response = try await pcsc.transmit(command)
            let elapsed = start.duration(to: clock.now)
            timeline.append(
                APDUEvent(
                    command: command,
                    response: response,
                    transportError: nil,
                    durationMilliseconds: elapsed.milliseconds
                )
            )
            return response
        } catch {
            let elapsed = start.duration(to: clock.now)
            timeline.append(
                APDUEvent(
                    command: command,
                    response: nil,
                    transportError: error.localizedDescription,
                    durationMilliseconds: elapsed.milliseconds
                )
            )
            scanTransportError = error.localizedDescription
            scannedCardFingerprint = nil
            connectionState = .failed(error.localizedDescription)
            await pcsc.disconnect()
            return nil
        }
    }

    private func preferredBridge(in readers: [String]) -> String? {
        readers.first { $0.localizedCaseInsensitiveContains("NFC CCID Bridge") } ??
            readers.first { $0.localizedCaseInsensitiveContains("Generic USB Smart Card Reader") }
    }

    private func resetForDisconnectedBridge() {
        connectionState = .disconnected
        readerName = nil
        snapshot = nil
        timeline = []
        scannedCardFingerprint = nil
        currentReport = nil
    }

    private func resetForRemovedCard() {
        connectionState = .readerReady
        snapshot = nil
        timeline = []
        scannedCardFingerprint = nil
        currentReport = nil
    }

    private func loadHistory() async {
        do {
            history = try await historyStore.load()
            historyError = nil
        } catch {
            historyError = error.localizedDescription
        }
    }

    private func deduplicatedMetadata(
        _ items: [PublicMetadataItem]
    ) -> [PublicMetadataItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    private func save(data: Data, suggestedName: String, allowedType: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [allowedType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            connectionState = .failed("Export failed: \(error.localizedDescription)")
        }
    }
}

private extension Duration {
    var milliseconds: Int {
        let components = self.components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
