import Foundation

public enum MediaKind: String, Codable, Sendable {
    /// Photo déjà développée (JPEG, HEIF, PNG, TIFF).
    case photo
    /// RAW Bayer (DNG ou format propriétaire pris en charge par le système).
    case raw
    /// Apple ProRAW (DNG linéaire issu du traitement computationnel).
    case proRAW
    case video
    case audio
}

/// Référence vers un original conservé dans la bibliothèque. L'original n'est jamais réécrit.
public struct MediaReference: Codable, Equatable, Sendable {
    /// Chemin relatif au dossier des originaux.
    public var fileName: String
    public var originalFileName: String
    public var kind: MediaKind
    /// Taille en octets à l'import : sert à détecter un original remplacé ou tronqué.
    public var byteSize: Int64
    /// Durée pour les vidéos et l'audio.
    public var duration: Rational?

    public init(fileName: String, originalFileName: String, kind: MediaKind, byteSize: Int64,
                duration: Rational? = nil) {
        self.fileName = fileName
        self.originalFileName = originalFileName
        self.kind = kind
        self.byteSize = byteSize
        self.duration = duration
    }

    public enum Status: Equatable, Sendable {
        case available
        case missing
        case modified
    }

    public func status(in originalsDirectory: URL) -> Status {
        let url = originalsDirectory.appendingPathComponent(fileName)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return .missing }
        return size.int64Value == byteSize ? .available : .modified
    }
}

/// Document versionné : identifiant de format et version écrits en tête du fichier.
public protocol VersionedDocument: Codable {
    static var formatIdentifier: String { get }
    static var currentVersion: Int { get }
}

public enum ProjectError: Error, Equatable, LocalizedError {
    case wrongFormat(String)
    case newerVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .wrongFormat(let f): return "Ce fichier n'est pas un projet Apertis (\(f))."
        case .newerVersion(let v):
            return "Ce projet a été créé par une version plus récente d'Apertis (format \(v)). Mettez l'application à jour."
        }
    }
}

public struct PhotoProject: VersionedDocument, Equatable, Identifiable, Sendable {
    public static let formatIdentifier = "fr.apertis.photo"
    public static let currentVersion = 1

    public var format: String = PhotoProject.formatIdentifier
    public var version: Int = PhotoProject.currentVersion
    public var id: UUID
    public var createdAt: Date
    public var modifiedAt: Date
    public var source: MediaReference
    public var history: EditHistory
    /// Note de 0 à 5.
    public var rating: Int = 0
    public var isFavorite: Bool = false
    public var keywords: [String] = []

    public init(id: UUID = UUID(), source: MediaReference, date: Date = Date()) {
        self.id = id
        self.source = source
        createdAt = date
        modifiedAt = date
        history = EditHistory()
    }

    public var settings: DevelopSettings { history.current }
}

public struct VideoProject: VersionedDocument, Equatable, Identifiable, Sendable {
    public static let formatIdentifier = "fr.apertis.video"
    public static let currentVersion = 1

    public var format: String = VideoProject.formatIdentifier
    public var version: Int = VideoProject.currentVersion
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var timeline: Timeline
    /// Médias du projet, indexés par `Clip.mediaID`.
    public var media: [String: MediaReference]

    public init(id: UUID = UUID(), name: String, frameRate: Rational, date: Date = Date()) {
        self.id = id
        self.name = name
        createdAt = date
        modifiedAt = date
        timeline = Timeline(frameRate: frameRate)
        media = [:]
    }

    /// Médias utilisés par la timeline mais absents ou modifiés sur le disque.
    public func unavailableMedia(in originalsDirectory: URL) -> [String] {
        Set(timeline.clips.map(\.mediaID)).filter { id in
            guard let reference = media[id] else { return true }
            return reference.status(in: originalsDirectory) != .available
        }.sorted()
    }
}

/// Lecture et écriture des documents.
public enum ProjectIO {
    private struct Header: Decodable {
        var format: String
        var version: Int
    }

    public static func encode<D: VersionedDocument>(_ document: D) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    public static func decode<D: VersionedDocument>(_ type: D.Type, from data: Data) throws -> D {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let header = try decoder.decode(Header.self, from: data)
        guard header.format == D.formatIdentifier else { throw ProjectError.wrongFormat(header.format) }
        guard header.version <= D.currentVersion else { throw ProjectError.newerVersion(header.version) }
        // Les migrations des versions antérieures se brancheront ici.
        return try decoder.decode(D.self, from: data)
    }

    /// Écriture atomique : le fichier est écrit à côté puis renommé. Une coupure pendant
    /// l'enregistrement laisse intact le projet précédent.
    public static func save<D: VersionedDocument>(_ document: D, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(document).write(to: url, options: [.atomic])
    }

    public static func load<D: VersionedDocument>(_ type: D.Type, from url: URL) throws -> D {
        try decode(type, from: Data(contentsOf: url))
    }
}
