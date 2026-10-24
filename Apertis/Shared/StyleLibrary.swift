import Foundation
import ApertisCore

/// Styles enregistrés par l'utilisateur (« Mes styles »), communs à la photo et à la vidéo.
/// Un fichier JSON dans Application Support, écrit de façon atomique.
@MainActor
final class StyleLibrary: ObservableObject {
    static let shared = StyleLibrary()

    @Published private(set) var styles: [Preset] = []
    private let url: URL

    private init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apertis", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("styles.json")
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([Preset].self, from: data) {
            styles = decoded
        }
    }

    @discardableResult
    func save(_ settings: DevelopSettings, name: String) -> Preset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = Preset.capture(from: settings, name: trimmed.isEmpty ? "Mon style \(styles.count + 1)" : trimmed)
        styles.append(preset)
        persist()
        return preset
    }

    func rename(_ id: String, to name: String) {
        guard let i = styles.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        styles[i].name = name
        persist()
    }

    func delete(_ id: String) {
        styles.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(styles).write(to: url, options: .atomic)
    }
}
