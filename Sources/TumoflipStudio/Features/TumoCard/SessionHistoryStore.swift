import Foundation
import TumoCardCore

actor SessionHistoryStore {
    private let fileManager: FileManager
    private let directory: URL
    private let maximumEntries: Int

    init(fileManager: FileManager = .default, maximumEntries: Int = 100) {
        self.fileManager = fileManager
        self.maximumEntries = maximumEntries
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        directory = applicationSupport
            .appendingPathComponent("TumoCardStudio", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
    }

    func load() throws -> [TumoCardReport] {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let report = try? decoder.decode(TumoCardReport.self, from: data) else {
                return nil
            }
            return report
        }.sorted { $0.generatedAt > $1.generatedAt }
    }

    func save(_ report: TumoCardReport) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(report.id.uuidString).json")
        try report.jsonData().write(to: destination, options: .atomic)
        try trimIfNeeded()
    }

    func delete(id: UUID) throws {
        let target = directory.appendingPathComponent("\(id.uuidString).json")
        guard fileManager.fileExists(atPath: target.path) else { return }
        try fileManager.removeItem(at: target)
    }

    private func trimIfNeeded() throws {
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
        guard entries.count > maximumEntries else { return }

        let ordered = try entries.sorted {
            let lhs = try $0.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
            let rhs = try $1.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
            return lhs > rhs
        }
        for url in ordered.dropFirst(maximumEntries) {
            try fileManager.removeItem(at: url)
        }
    }
}
