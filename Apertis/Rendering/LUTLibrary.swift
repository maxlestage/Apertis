import Foundation
import ApertisCore

/// Bibliothèque des LUT 3D importées (.cube), stockées dans le dossier LUTs de l'application.
final class LUTLibrary: ObservableObject, @unchecked Sendable {
    static let shared = LUTLibrary()

    struct Entry: Identifiable, Hashable {
        var id: String { identifier }
        let identifier: String
        let title: String
    }

    @Published private(set) var entries: [Entry] = []

    private let lock = NSLock()
    private var cache: [String: CubeLUT] = [:]
    private(set) var directory: URL = FileManager.default.temporaryDirectory

    func configure(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let found = files.filter { $0.pathExtension.lowercased() == "cube" }.compactMap { url -> Entry? in
            guard let lut = lut(for: url.lastPathComponent) else { return nil }
            let title = lut.title.isEmpty ? url.deletingPathExtension().lastPathComponent : lut.title
            return Entry(identifier: url.lastPathComponent, title: title)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        DispatchQueue.main.async { self.entries = found }
    }

    /// Valide puis copie une LUT dans la bibliothèque. L'identifiant est le nom du fichier.
    @discardableResult
    func importLUT(from url: URL) throws -> Entry {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let lut = try CubeLUT(contentsOf: url)
        var name = url.lastPathComponent
        var destination = directory.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            name = "\(url.deletingPathExtension().lastPathComponent) \(counter).cube"
            destination = directory.appendingPathComponent(name)
            counter += 1
        }
        try FileManager.default.copyItem(at: url, to: destination)
        lock.lock()
        cache[name] = lut
        lock.unlock()
        reload()
        return Entry(identifier: name, title: lut.title.isEmpty ? url.deletingPathExtension().lastPathComponent : lut.title)
    }

    func lut(for identifier: String) -> CubeLUT? {
        lock.lock()
        if let hit = cache[identifier] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        guard let lut = try? CubeLUT(contentsOf: directory.appendingPathComponent(identifier)) else { return nil }
        lock.lock()
        cache[identifier] = lut
        lock.unlock()
        return lut
    }
}
