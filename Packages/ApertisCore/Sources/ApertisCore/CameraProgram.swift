import Foundation

/// Programme d'exposition, comme sur un boîtier : le photographe fixe certains paramètres,
/// l'automatisme de l'appareil gère les autres.
///
/// L'ouverture n'est réglable que sur un objectif à diaphragme variable (iPhone 18 Pro,
/// iOS 27) ; sur les autres, A se comporte comme P et M ne règle que vitesse et ISO.
public enum ExposureProgram: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Programme : tout est automatique (correction d'exposition possible).
    case program
    /// Priorité ouverture : ouverture fixée, vitesse et ISO automatiques.
    case aperturePriority
    /// Priorité vitesse : vitesse fixée, ouverture et ISO automatiques.
    case shutterPriority
    /// Manuel : ouverture, vitesse et ISO fixés.
    case manual

    public var id: String { rawValue }

    /// Lettre affichée sur la molette, comme sur un boîtier.
    public var letter: String {
        switch self {
        case .program: return "P"
        case .aperturePriority: return "A"
        case .shutterPriority: return "S"
        case .manual: return "M"
        }
    }

    public var label: String {
        switch self {
        case .program: return "Programme"
        case .aperturePriority: return "Priorité ouverture"
        case .shutterPriority: return "Priorité vitesse"
        case .manual: return "Manuel"
        }
    }

    /// La correction d'exposition n'a de sens que si l'automatisme garde un paramètre.
    public var usesExposureBias: Bool { self != .manual }

    /// Programmes proposés selon l'objectif et le système.
    ///
    /// - Parameter priorityModes: iOS 27 et plus, où l'automatisme peut garder un paramètre
    ///   (`autoISO`, `autoLensAperture`…). Avant, seule l'exposition manuelle complète existe.
    public static func available(variableAperture: Bool, customExposure: Bool, priorityModes: Bool = true) -> [ExposureProgram] {
        guard customExposure else { return [.program] }
        guard priorityModes else { return [.program, .manual] }
        return variableAperture ? [.program, .aperturePriority, .shutterPriority, .manual] : [.program, .shutterPriority, .manual]
    }
}

/// Paramètres à transmettre à `setExposureModeCustom(lensAperture:duration:iso:)` :
/// `nil` signifie « laissé à l'automatisme » (`autoLensAperture`, `autoExposureDuration`, `autoISO`).
public struct ExposureRequest: Equatable, Sendable {
    public var aperture: Float?
    public var duration: Double?
    public var iso: Float?

    public init(aperture: Float? = nil, duration: Double? = nil, iso: Float? = nil) {
        self.aperture = aperture
        self.duration = duration
        self.iso = iso
    }

    /// Vrai si tout est automatique : l'exposition continue suffit.
    public var isFullyAutomatic: Bool { aperture == nil && duration == nil && iso == nil }

    /// Construit la demande d'un programme. Sans diaphragme variable, l'ouverture reste fixe.
    ///
    /// - Parameter isoAuto: en S et en M, laisse l'ISO à l'automatisme (« ISO auto » des boîtiers).
    public static func make(_ program: ExposureProgram, aperture: Float, duration: Double, iso: Float,
                            isoAuto: Bool = false, variableAperture: Bool) -> ExposureRequest {
        let fixedAperture: Float? = variableAperture ? aperture : nil
        switch program {
        case .program:
            return ExposureRequest()
        case .aperturePriority:
            return ExposureRequest(aperture: fixedAperture)
        case .shutterPriority:
            return ExposureRequest(duration: duration, iso: isoAuto ? nil : iso)
        case .manual:
            return ExposureRequest(aperture: fixedAperture, duration: duration, iso: isoAuto ? nil : iso)
        }
    }

    /// Bornée aux valeurs que l'objectif accepte.
    public func clamped(aperture apertureRange: ClosedRange<Float>, duration durationRange: ClosedRange<Double>,
                        iso isoRange: ClosedRange<Float>) -> ExposureRequest {
        ExposureRequest(aperture: aperture.map { min(max($0, apertureRange.lowerBound), apertureRange.upperBound) },
                        duration: duration.map { min(max($0, durationRange.lowerBound), durationRange.upperBound) },
                        iso: iso.map { min(max($0, isoRange.lowerBound), isoRange.upperBound) })
    }
}

/// Une focale proposée sur le bouton de zoom : un objectif et un facteur de recadrage.
public struct FocalStop: Hashable, Codable, Sendable, Identifiable {
    public var lens: LensKind
    /// Facteur de zoom appliqué à l'objectif (1 = focale native).
    public var zoom: Double
    /// Focale équivalente 24×36, en millimètres.
    public var focalLength: Double
    /// Recadrage du capteur 48 Mpx sans interpolation (« qualité optique »).
    public var isOpticalQualityCrop: Bool

    public init(lens: LensKind, zoom: Double, focalLength: Double, isOpticalQualityCrop: Bool = false) {
        self.lens = lens
        self.zoom = zoom
        self.focalLength = focalLength
        self.isOpticalQualityCrop = isOpticalQualityCrop
    }

    public var id: String { "\(lens.rawValue)-\(focalLength)" }

    /// « 24 mm ».
    public var label: String { "\(Int(focalLength.rounded())) mm" }

    /// Grossissement par rapport à l'objectif principal, arrondi comme dans l'app Appareil
    /// photo : « 0,5× », « 1× », « 2× », « 4× », « 8× ».
    public func magnification(mainFocalLength: Double) -> String {
        let m = focalLength / mainFocalLength
        let rounded = m >= 1.5 ? m.rounded() : (m * 10).rounded() / 10
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded).replacingOccurrences(of: ".", with: ",")
        return text + "×"
    }
}

/// Description d'un objectif telle que la donne AVFoundation.
public struct LensDescription: Sendable {
    public var kind: LensKind
    /// `nominalFocalLengthIn35mmFilm` (iOS 26) ou, à défaut, valeur estimée.
    public var focalLength: Double
    /// Plus grande photo du format actif, en mégapixels.
    public var maxMegapixels: Double
    /// `maxAvailableVideoZoomFactor` du format actif.
    public var maxZoom: Double

    public init(kind: LensKind, focalLength: Double, maxMegapixels: Double, maxZoom: Double) {
        self.kind = kind
        self.focalLength = focalLength
        self.maxMegapixels = maxMegapixels
        self.maxZoom = maxZoom
    }
}

public enum FocalStops {
    /// Focales proposées à l'arrière : chaque objectif, plus le recadrage 2× sans perte des
    /// capteurs 48 Mpx du grand-angle et du téléobjectif. Sur iPhone 18 Pro (13, 24, 100 mm) :
    /// 13, 24, 48, 100 et 200 mm, soit 0,5× à 8×.
    public static func make(_ lenses: [LensDescription]) -> [FocalStop] {
        var stops: [FocalStop] = []
        for lens in lenses.sorted(by: { $0.focalLength < $1.focalLength }) where lens.kind != .front && lens.kind != .external {
            stops.append(FocalStop(lens: lens.kind, zoom: 1, focalLength: lens.focalLength))
            let crop = lens.focalLength * 2
            let alreadyCovered = lenses.contains { $0.kind != lens.kind && abs($0.focalLength - crop) / crop < 0.15 }
            if (lens.kind == .wide || lens.kind == .telephoto), lens.maxMegapixels >= 40, lens.maxZoom >= 2, !alreadyCovered {
                stops.append(FocalStop(lens: lens.kind, zoom: 2, focalLength: crop, isOpticalQualityCrop: true))
            }
        }
        return stops.sorted { $0.focalLength < $1.focalLength }
    }

    /// Focale équivalente estimée quand le système ne la donne pas.
    public static func estimatedFocalLength(_ kind: LensKind) -> Double {
        switch kind {
        case .ultraWide: return 13
        case .wide: return 24
        case .telephoto: return 77
        case .front, .external: return 26
        }
    }
}

/// Définition photo : les tailles maximales proposées par le format actif.
public struct PhotoResolution: Hashable, Sendable, Identifiable, Comparable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var id: String { "\(width)x\(height)" }
    public var megapixels: Double { Double(width * height) / 1_000_000 }

    /// « 12 Mpx », « 24 Mpx », « 48 Mpx ».
    public var label: String { "\(Int(megapixels.rounded())) Mpx" }

    public static func < (a: PhotoResolution, b: PhotoResolution) -> Bool { a.megapixels < b.megapixels }

    /// Une entrée par définition, de la plus petite à la plus grande.
    public static func options(_ sizes: [PhotoResolution]) -> [PhotoResolution] {
        var seen = Set<Int>()
        return sizes.sorted().filter { seen.insert(Int($0.megapixels.rounded())).inserted }
    }
}

public enum CameraFormat {
    /// « ƒ/1.48 », « ƒ/2.8 », « ƒ/4 ».
    public static func aperture(_ f: Float) -> String {
        let value = (f * 100).rounded() / 100
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "ƒ/" + text
    }

    /// « 1/250 », « 0,5 s », « 2 s ».
    public static func shutter(_ seconds: Double) -> String {
        if seconds >= 0.4 {
            let text = seconds >= 1 && seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.1f", seconds)
            return text.replacingOccurrences(of: ".", with: ",") + " s"
        }
        return "1/\(Int((1 / seconds).rounded()))"
    }

    /// Indice de lumination d'une exposition, ramené à 100 ISO : EV = log2(N² / t) − log2(ISO / 100).
    public static func exposureValue(aperture: Float, duration: Double, iso: Float) -> Double {
        log2(Double(aperture * aperture) / duration) - log2(Double(iso) / 100)
    }
}
