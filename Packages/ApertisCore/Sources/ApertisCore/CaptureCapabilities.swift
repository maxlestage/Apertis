import Foundation

public enum LensKind: String, Codable, CaseIterable, Comparable, Sendable {
    case ultraWide, wide, telephoto, front, external

    public var label: String {
        switch self {
        case .ultraWide: return "0,5×"
        case .wide: return "1×"
        case .telephoto: return "Télé"
        case .front: return "Avant"
        case .external: return "Externe"
        }
    }

    public static func < (a: LensKind, b: LensKind) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

public enum VideoColorProfile: String, Codable, CaseIterable, Comparable, Sendable {
    /// Rec. 709 / sRGB, 8 bits.
    case sdr
    /// HDR HLG Rec. 2020, 10 bits.
    case hlg
    /// Apple Log : profil logarithmique destiné à l'étalonnage.
    case appleLog

    public var label: String {
        switch self {
        case .sdr: return "SDR"
        case .hlg: return "HDR"
        case .appleLog: return "Log"
        }
    }

    public static func < (a: VideoColorProfile, b: VideoColorProfile) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case h264, hevc, proRes422, proRes422HQ

    public var label: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .proRes422: return "ProRes 422"
        case .proRes422HQ: return "ProRes 422 HQ"
        }
    }
}

public struct Resolution: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var pixelCount: Int { width * height }

    public var description: String {
        switch max(width, height) {
        case 3840...: return "4K"
        case 2560..<3840: return "\(min(width, height))p"
        case 1920: return "1080p"
        case 1280: return "720p"
        default: return "\(width)×\(height)"
        }
    }

    public static func < (a: Resolution, b: Resolution) -> Bool { a.pixelCount < b.pixelCount }
}

/// Combinaison d'enregistrement réellement prise en charge par l'appareil.
public struct VideoMode: Codable, Hashable, Sendable {
    public var lens: LensKind
    public var resolution: Resolution
    public var frameRate: Int
    public var profile: VideoColorProfile

    public init(lens: LensKind, resolution: Resolution, frameRate: Int, profile: VideoColorProfile) {
        self.lens = lens
        self.resolution = resolution
        self.frameRate = frameRate
        self.profile = profile
    }
}

/// Filtre partiel : un champ nil accepte toutes les valeurs.
public struct VideoModeQuery: Equatable, Sendable {
    public var lens: LensKind?
    public var resolution: Resolution?
    public var frameRate: Int?
    public var profile: VideoColorProfile?

    public init(lens: LensKind? = nil, resolution: Resolution? = nil, frameRate: Int? = nil,
                profile: VideoColorProfile? = nil) {
        self.lens = lens
        self.resolution = resolution
        self.frameRate = frameRate
        self.profile = profile
    }

    public func matches(_ mode: VideoMode) -> Bool {
        (lens == nil || lens == mode.lens)
            && (resolution == nil || resolution == mode.resolution)
            && (frameRate == nil || frameRate == mode.frameRate)
            && (profile == nil || profile == mode.profile)
    }
}

public struct PhotoCapabilities: Codable, Equatable, Sendable {
    public var bayerRAW: Bool
    public var appleProRAW: Bool
    public var heif: Bool
    public var lenses: [LensKind]

    public init(bayerRAW: Bool = false, appleProRAW: Bool = false, heif: Bool = true, lenses: [LensKind] = []) {
        self.bayerRAW = bayerRAW
        self.appleProRAW = appleProRAW
        self.heif = heif
        self.lenses = lenses
    }
}

/// Profil des capacités de capture de l'appareil, construit au lancement à partir des API système.
///
/// L'interface ne propose que des valeurs issues de ce profil : une combinaison impossible
/// (par exemple 4K 240 i/s en Log) n'apparaît jamais comme disponible.
public struct CaptureCapabilities: Codable, Equatable, Sendable {
    public var photo: PhotoCapabilities
    public var videoModes: Set<VideoMode>
    public var videoCodecs: [VideoCodec]

    public init(photo: PhotoCapabilities = PhotoCapabilities(), videoModes: Set<VideoMode> = [],
                videoCodecs: [VideoCodec] = []) {
        self.photo = photo
        self.videoModes = videoModes
        self.videoCodecs = videoCodecs
    }

    public func supports(_ mode: VideoMode) -> Bool { videoModes.contains(mode) }

    public func modes(matching query: VideoModeQuery) -> [VideoMode] {
        videoModes.filter(query.matches).sorted {
            ($0.lens, $0.resolution, $0.frameRate, $0.profile) < ($1.lens, $1.resolution, $1.frameRate, $1.profile)
        }
    }

    /// Valeurs distinctes disponibles pour un champ, compte tenu des autres choix.
    public func options<T: Hashable & Comparable>(_ field: KeyPath<VideoMode, T>, matching query: VideoModeQuery) -> [T] {
        Array(Set(videoModes.filter(query.matches).map { $0[keyPath: field] })).sorted()
    }

    /// Mode valide le plus proche de la demande.
    ///
    /// Les contraintes sont relâchées de la moins importante à la plus importante :
    /// profil, puis cadence, puis résolution, puis objectif.
    public func resolve(_ query: VideoModeQuery) -> VideoMode? {
        var relaxed = query
        let steps: [(inout VideoModeQuery) -> Void] = [
            { _ in },
            { $0.profile = nil },
            { $0.frameRate = nil },
            { $0.resolution = nil },
            { $0.lens = nil },
        ]
        for relax in steps {
            relax(&relaxed)
            let candidates = videoModes.filter(relaxed.matches)
            if candidates.isEmpty { continue }
            return candidates.min { a, b in
                score(a, query) < score(b, query)
            }
        }
        return nil
    }

    /// Plus petit = plus proche de la demande.
    private func score(_ mode: VideoMode, _ query: VideoModeQuery) -> (Int, Int, Int, Int, Int) {
        let lensPenalty = query.lens.map { $0 == mode.lens ? 0 : 1 } ?? 0
        let resolutionPenalty = query.resolution.map { abs($0.pixelCount - mode.resolution.pixelCount) }
            ?? -mode.resolution.pixelCount
        let ratePenalty = query.frameRate.map { abs($0 - mode.frameRate) } ?? -mode.frameRate
        let profilePenalty = query.profile.map { $0 == mode.profile ? 0 : 1 } ?? (mode.profile == .sdr ? 0 : 1)
        return (lensPenalty, resolutionPenalty, ratePenalty, profilePenalty, mode.lens == .wide ? 0 : 1)
    }
}
