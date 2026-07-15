import Foundation

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case overview
    case aiRadar
    case cards
    case network
    case developer
    case logs

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .aiRadar: "AI & Relay"
        case .cards: "TumoCard"
        case .network: "Network Lab"
        case .developer: "FAP Developer"
        case .logs: "Activity"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .aiRadar: "antenna.radiowaves.left.and.right"
        case .cards: "creditcard"
        case .network: "wifi.router"
        case .developer: "hammer"
        case .logs: "text.alignleft"
        }
    }
}
