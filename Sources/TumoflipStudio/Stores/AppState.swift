import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var selection: WorkspaceSection? = .overview

    let log: ActivityLogStore
    let transport: TransportCoordinator
    let aiRadar: AIRadarStore
    let card: StudioStore
    let network: LiveStore
    let crack: CrackStore
    let developer: DeveloperStore

    private var started = false

    init() {
        let log = ActivityLogStore()
        let transport = TransportCoordinator(log: log)

        self.log = log
        self.transport = transport
        self.aiRadar = AIRadarStore()
        self.card = StudioStore(transportCoordinator: transport)
        self.network = LiveStore(transportCoordinator: transport)
        self.crack = CrackStore()
        self.developer = DeveloperStore(transportCoordinator: transport, activityLog: log)
    }

    func start() {
        guard !started else { return }
        started = true
        transport.refreshDevices()
        _ = transport.acquire(.bluetooth, owner: "AI Relay")
        _ = transport.acquire(.localHTTP, owner: "AI Relay")
        aiRadar.start()
        log.append("Tumoflip Studio started", source: "Application")
    }

    func stop() {
        guard started else { return }
        card.stopMonitoring()
        if network.connected { network.disconnect() }
        aiRadar.stop()
        transport.releaseAll(owner: "AI Relay")
        transport.releaseAll(owner: "TumoCard")
        transport.releaseAll(owner: "Network Lab")
        transport.releaseAll(owner: "FAP Builder")
        log.append("Tumoflip Studio stopped", source: "Application")
        started = false
    }
}
