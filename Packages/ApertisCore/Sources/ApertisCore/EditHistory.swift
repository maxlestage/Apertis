import Foundation

/// Historique non destructif : chaque étape est un instantané complet des réglages.
/// Les réglages pèsent quelques kilo-octets ; les instantanés rendent l'annulation triviale et sûre.
public struct EditHistory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var label: String
        public var settings: DevelopSettings
        public var date: Date

        public init(label: String, settings: DevelopSettings, date: Date = Date()) {
            self.label = label
            self.settings = settings
            self.date = date
        }
    }

    public static let maximumEntries = 200

    public private(set) var entries: [Entry]
    public private(set) var index: Int

    public init(initial: DevelopSettings = .neutral) {
        entries = [Entry(label: "Original", settings: initial)]
        index = 0
    }

    public var current: DevelopSettings { entries[index].settings }
    public var canUndo: Bool { index > 0 }
    public var canRedo: Bool { index < entries.count - 1 }

    /// Enregistre une nouvelle étape. Supprime les étapes « rétablissables ».
    /// Sans effet si les réglages sont identiques à l'étape courante.
    public mutating func commit(_ settings: DevelopSettings, label: String) {
        guard settings != current else { return }
        entries.removeSubrange((index + 1)...)
        entries.append(Entry(label: label, settings: settings))
        if entries.count > EditHistory.maximumEntries {
            // On conserve toujours l'original en première position.
            entries.remove(at: 1)
        }
        index = entries.count - 1
    }

    @discardableResult
    public mutating func undo() -> DevelopSettings {
        if canUndo { index -= 1 }
        return current
    }

    @discardableResult
    public mutating func redo() -> DevelopSettings {
        if canRedo { index += 1 }
        return current
    }

    /// Revient à une étape précise (sans supprimer les suivantes).
    public mutating func jump(to newIndex: Int) {
        index = min(max(newIndex, 0), entries.count - 1)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try c.decode([Entry].self, forKey: .entries)
        guard !decoded.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .entries, in: c, debugDescription: "Historique vide")
        }
        entries = decoded
        index = min(max(try c.decode(Int.self, forKey: .index), 0), decoded.count - 1)
    }
}
