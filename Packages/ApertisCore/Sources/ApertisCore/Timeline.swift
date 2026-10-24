import Foundation

public enum TrackKind: String, Codable, Sendable {
    case video
    case audio
}

public struct Track: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: TrackKind
    public var name: String
    public var isMuted: Bool = false

    public init(id: UUID = UUID(), kind: TrackKind, name: String) {
        self.id = id
        self.kind = kind
        self.name = name
    }
}

/// Plan placé sur la timeline. Tous les temps sont exacts et alignés sur les images du projet.
public struct Clip: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Identifiant du média source dans le projet.
    public var mediaID: String
    public var trackID: UUID
    /// Position du plan sur la timeline.
    public var start: Rational
    /// Durée du plan sur la timeline.
    public var duration: Rational
    /// Point d'entrée dans le média source.
    public var sourceIn: Rational
    /// Vitesse de lecture : 2 = accéléré ×2, 1/2 = ralenti ×0,5.
    public var speed: Rational
    /// Étalonnage propre au plan.
    public var grade: DevelopSettings
    /// Volume linéaire, 0 … 2.
    public var volume: Double

    public init(id: UUID = UUID(), mediaID: String, trackID: UUID, start: Rational, duration: Rational,
                sourceIn: Rational = .zero, speed: Rational = .one, grade: DevelopSettings = .neutral,
                volume: Double = 1) {
        self.id = id
        self.mediaID = mediaID
        self.trackID = trackID
        self.start = start
        self.duration = duration
        self.sourceIn = sourceIn
        self.speed = speed
        self.grade = grade
        self.volume = volume
    }

    public var end: Rational { start + duration }
    /// Durée consommée dans le média source.
    public var sourceDuration: Rational { duration * speed }
    public var sourceOut: Rational { sourceIn + sourceDuration }

    /// Temps source correspondant à un temps de la timeline.
    public func sourceTime(at time: Rational) -> Rational {
        sourceIn + (time - start) * speed
    }

    public func contains(_ time: Rational) -> Bool { start <= time && time < end }
}

public enum TimelineError: Error, Equatable, LocalizedError {
    case unknownTrack
    case unknownClip
    case notFrameAligned
    case invalidDuration
    case negativeTime
    case invalidSpeed
    case overlap(UUID)
    case splitOutsideClip

    public var errorDescription: String? {
        switch self {
        case .unknownTrack: return "Piste introuvable."
        case .unknownClip: return "Plan introuvable."
        case .notFrameAligned: return "Le temps n'est pas aligné sur une image."
        case .invalidDuration: return "Durée invalide."
        case .negativeTime: return "Temps négatif."
        case .invalidSpeed: return "Vitesse invalide."
        case .overlap: return "Le plan chevauche un autre plan de la piste."
        case .splitOutsideClip: return "Le point de coupe doit être à l'intérieur du plan."
        }
    }
}

/// Timeline multipiste non destructive, indépendante de l'interface et d'AVFoundation.
/// Toutes les mutations sont validées : un état invalide ne peut pas être enregistré.
public struct Timeline: Codable, Equatable, Sendable {
    /// Cadence du projet, en images par seconde (ex. 30000/1001).
    public let frameRate: Rational
    public private(set) var tracks: [Track]
    public private(set) var clips: [Clip]

    public init(frameRate: Rational) {
        precondition(frameRate > .zero, "cadence invalide")
        self.frameRate = frameRate
        tracks = [Track(kind: .video, name: "V1"), Track(kind: .audio, name: "A1")]
        clips = []
    }

    /// Décodage avec validation complète : un fichier modifié ou corrompu ne peut pas
    /// produire une timeline incohérente.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frameRate = try c.decode(Rational.self, forKey: .frameRate)
        guard frameRate > .zero else {
            throw DecodingError.dataCorruptedError(forKey: .frameRate, in: c, debugDescription: "Cadence invalide")
        }
        tracks = try c.decode([Track].self, forKey: .tracks)
        clips = []
        for clip in try c.decode([Clip].self, forKey: .clips) {
            try insert(clip)
        }
    }

    public var frameDuration: Rational { .one / frameRate }

    public var duration: Rational { clips.map(\.end).max() ?? .zero }

    public var mainVideoTrack: Track { tracks.first { $0.kind == .video }! }

    public func isFrameAligned(_ time: Rational) -> Bool { (time * frameRate).isInteger }

    /// Image la plus proche.
    public func snapToFrame(_ time: Rational) -> Rational {
        Rational((time * frameRate).rounded) * frameDuration
    }

    public func frame(at time: Rational) -> Int64 { (time * frameRate).floor }
    public func time(ofFrame frame: Int64) -> Rational { Rational(frame) * frameDuration }

    public func clip(_ id: UUID) -> Clip? { clips.first { $0.id == id } }

    public func clips(on trackID: UUID) -> [Clip] {
        clips.filter { $0.trackID == trackID }.sorted { $0.start < $1.start }
    }

    /// Plans actifs à un instant donné, dans l'ordre des pistes (la première piste est dessous).
    public func clips(at time: Rational, kind: TrackKind) -> [Clip] {
        tracks.filter { $0.kind == kind && !$0.isMuted }.compactMap { track in
            clips.first { $0.trackID == track.id && $0.contains(time) }
        }
    }

    // MARK: - Mutations

    @discardableResult
    public mutating func addTrack(kind: TrackKind) -> Track {
        let count = tracks.filter { $0.kind == kind }.count
        let track = Track(kind: kind, name: (kind == .video ? "V" : "A") + "\(count + 1)")
        tracks.append(track)
        return track
    }

    public mutating func setTrackMuted(_ trackID: UUID, _ muted: Bool) throws {
        guard let i = tracks.firstIndex(where: { $0.id == trackID }) else { throw TimelineError.unknownTrack }
        tracks[i].isMuted = muted
    }

    public mutating func insert(_ clip: Clip) throws {
        try validate(clip, ignoring: nil)
        clips.append(clip)
    }

    /// Ajoute un plan à la fin d'une piste (par défaut la piste vidéo principale).
    @discardableResult
    public mutating func append(mediaID: String, sourceIn: Rational = .zero, duration: Rational,
                                trackID: UUID? = nil) throws -> Clip {
        let track = trackID ?? mainVideoTrack.id
        let start = clips(on: track).last?.end ?? .zero
        let clip = Clip(mediaID: mediaID, trackID: track, start: start, duration: snapToFrame(duration),
                        sourceIn: sourceIn)
        try insert(clip)
        return clip
    }

    public mutating func remove(_ clipID: UUID) {
        clips.removeAll { $0.id == clipID }
    }

    /// Supprime un plan et referme le trou en décalant les plans suivants de la piste.
    public mutating func rippleDelete(_ clipID: UUID) {
        guard let removed = clip(clipID) else { return }
        remove(clipID)
        for i in clips.indices where clips[i].trackID == removed.trackID && clips[i].start >= removed.end {
            clips[i].start = clips[i].start - removed.duration
        }
    }

    public mutating func update(_ clip: Clip) throws {
        guard let i = clips.firstIndex(where: { $0.id == clip.id }) else { throw TimelineError.unknownClip }
        try validate(clip, ignoring: clip.id)
        clips[i] = clip
    }

    public mutating func move(_ clipID: UUID, to start: Rational, trackID: UUID? = nil) throws {
        guard var clip = clip(clipID) else { throw TimelineError.unknownClip }
        clip.start = start
        if let trackID { clip.trackID = trackID }
        try update(clip)
    }

    public mutating func trim(_ clipID: UUID, sourceIn: Rational, duration: Rational) throws {
        guard var clip = clip(clipID) else { throw TimelineError.unknownClip }
        clip.sourceIn = sourceIn
        clip.duration = duration
        try update(clip)
    }

    /// Coupe un plan en deux à `time`. Renvoie l'identifiant du second plan.
    @discardableResult
    public mutating func split(_ clipID: UUID, at time: Rational) throws -> UUID {
        guard let i = clips.firstIndex(where: { $0.id == clipID }) else { throw TimelineError.unknownClip }
        let original = clips[i]
        guard isFrameAligned(time) else { throw TimelineError.notFrameAligned }
        guard original.start < time && time < original.end else { throw TimelineError.splitOutsideClip }
        var second = original
        second.id = UUID()
        second.start = time
        second.duration = original.end - time
        second.sourceIn = original.sourceTime(at: time)
        clips[i].duration = time - original.start
        clips.append(second)
        return second.id
    }

    /// Place les plans d'une piste bout à bout, dans l'ordre donné, à partir de zéro.
    /// Les plans de la piste absents de `order` sont placés à la suite, dans leur ordre actuel.
    public mutating func arrangeSequentially(_ order: [UUID], on trackID: UUID) throws {
        guard tracks.contains(where: { $0.id == trackID }) else { throw TimelineError.unknownTrack }
        let current = clips(on: trackID)
        let ordered = order.compactMap { id in current.first { $0.id == id } }
            + current.filter { !order.contains($0.id) }
        var position = Rational.zero
        for clip in ordered {
            let i = clips.firstIndex { $0.id == clip.id }!
            clips[i].start = position
            position = position + clip.duration
        }
    }

    /// Étalonnage par plan : copie l'étalonnage d'un plan vers d'autres plans.
    public mutating func copyGrade(from sourceID: UUID, to targetIDs: [UUID]) throws {
        guard let source = clip(sourceID) else { throw TimelineError.unknownClip }
        for i in clips.indices where targetIDs.contains(clips[i].id) {
            clips[i].grade = source.grade
        }
    }

    private func validate(_ clip: Clip, ignoring ignoredID: UUID?) throws {
        guard tracks.contains(where: { $0.id == clip.trackID }) else { throw TimelineError.unknownTrack }
        guard clip.duration > .zero else { throw TimelineError.invalidDuration }
        guard clip.start >= .zero, clip.sourceIn >= .zero else { throw TimelineError.negativeTime }
        guard clip.speed > .zero else { throw TimelineError.invalidSpeed }
        guard isFrameAligned(clip.start), isFrameAligned(clip.duration) else { throw TimelineError.notFrameAligned }
        for other in clips where other.id != ignoredID && other.id != clip.id && other.trackID == clip.trackID {
            if clip.start < other.end && other.start < clip.end { throw TimelineError.overlap(other.id) }
        }
    }
}
