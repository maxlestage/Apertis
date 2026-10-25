import Foundation

// Fonctions de prise de vue qu'Apertis ajoute à l'appareil photo d'Apple : bracketing,
// pose longue, intervallomètre, balance des blancs sur charte grise, cellule, cadres,
// réglages personnalisés. Calculs purs, testés hors d'iOS.

/// Mode d'entraînement, comme la molette d'un boîtier.
public enum DriveMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case single, bracketing, longExposure, intervalometer

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .single: return "Vue par vue"
        case .bracketing: return "Bracketing"
        case .longExposure: return "Pose longue"
        case .intervalometer: return "Intervalles"
        }
    }

    public var symbol: String {
        switch self {
        case .single: return "square"
        case .bracketing: return "square.stack.3d.down.right"
        case .longExposure: return "timer"
        case .intervalometer: return "clock.arrow.2.circlepath"
        }
    }
}

/// Bracketing d'exposition : plusieurs vues décalées autour de l'exposition mesurée, pour
/// la fusion HDR ou pour garantir une vue bien exposée.
public struct Bracketing: Codable, Equatable, Sendable {
    /// Nombre de vues (3, 5, 7…), impair.
    public var count: Int
    /// Écart entre deux vues, en IL.
    public var step: Float

    public init(count: Int = 3, step: Float = 1) {
        self.count = count
        self.step = step
    }

    public static let steps: [Float] = [1.0 / 3, 2.0 / 3, 1, 2]
    public static let counts = [3, 5, 7, 9]

    /// Corrections de chaque vue, de la plus sombre à la plus claire, limitées à ce que
    /// l'appareil accepte : nombre de vues maximal et plage de correction.
    public func biases(maxCount: Int, range: ClosedRange<Float>) -> [Float] {
        guard maxCount >= 2 else { return [0] }
        var n = min(count, maxCount)
        if n % 2 == 0 { n -= 1 }
        n = max(n, 1)
        let half = n / 2
        return (-half...half).map { min(max(Float($0) * step, range.lowerBound), range.upperBound) }
    }

    /// « 3 vues · ±1 IL ».
    public var label: String { "\(count) vues · ±\(CameraFormat.ev(step)) IL" }
}

/// Pose longue calculée : les images du capteur sont empilées pendant la durée choisie.
public enum LongExposureStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Moyenne : eau et nuages filés, foule effacée (comme un filtre ND).
    case motionBlur
    /// Maximum : traînées lumineuses (phares, étoiles, light painting).
    case lightTrails

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .motionBlur: return "Filé (filtre ND)"
        case .lightTrails: return "Traînées lumineuses"
        }
    }
}

public struct LongExposure: Codable, Equatable, Sendable {
    public var style: LongExposureStyle
    /// Durée de la pose, en secondes.
    public var duration: Double

    public init(style: LongExposureStyle = .motionBlur, duration: Double = 2) {
        self.style = style
        self.duration = duration
    }

    public static let durations: [Double] = [0.5, 1, 2, 4, 8, 15, 30]

    /// Nombre d'images à empiler à la cadence du capteur (au moins deux).
    public func frameCount(frameRate: Double) -> Int {
        max(2, Int((duration * frameRate).rounded()))
    }

    /// Équivalent en densité neutre : une pose de `duration` au lieu de `frameDuration`.
    /// Par exemple 2 s à 1/30 s ≈ ND 6 IL.
    public func equivalentNDStops(frameDuration: Double) -> Double {
        log2(duration / max(frameDuration, 1e-6))
    }
}

/// Intervallomètre : une photo toutes les `interval` secondes, `count` fois (0 = sans limite).
public struct Intervalometer: Codable, Equatable, Sendable {
    public var interval: Double
    public var count: Int

    public init(interval: Double = 5, count: Int = 100) {
        self.interval = interval
        self.count = count
    }

    public static let intervals: [Double] = [1, 2, 5, 10, 30, 60, 300]
    public static let counts = [10, 50, 100, 300, 1000, 0]

    /// Durée totale de la série, en secondes (nil : sans limite).
    public var totalDuration: Double? { count > 0 ? Double(max(count - 1, 0)) * interval : nil }

    /// Durée d'un timelapse lu à `playbackRate` images par seconde.
    public func playbackDuration(playbackRate: Double = 25) -> Double? {
        count > 0 ? Double(count) / playbackRate : nil
    }
}

/// Gains de balance des blancs (rouge, vert, bleu), comme `AVCaptureDevice.WhiteBalanceGains`.
public struct WhiteBalanceGains: Equatable, Sendable {
    public var red: Float
    public var green: Float
    public var blue: Float

    public init(red: Float, green: Float, blue: Float) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Balance des blancs sur charte grise : à partir des gains actuels et de la couleur
    /// mesurée sur une surface neutre (en lumière linéaire), les gains qui rendent cette
    /// surface grise. Le plus petit gain vaut 1, aucun ne dépasse `maxGain`.
    public static func neutralizing(_ measured: (r: Float, g: Float, b: Float), current: WhiteBalanceGains,
                                    maxGain: Float) -> WhiteBalanceGains? {
        guard measured.r > 1e-4, measured.g > 1e-4, measured.b > 1e-4 else { return nil }
        var r = current.red * measured.g / measured.r
        var g = current.green
        var b = current.blue * measured.g / measured.b
        let smallest = min(r, g, b)
        r /= smallest
        g /= smallest
        b /= smallest
        return WhiteBalanceGains(red: min(r, maxGain), green: min(g, maxGain), blue: min(b, maxGain))
    }
}

/// Cellule : lecture de l'exposition comme sur un posemètre.
public enum ExposureMeter {
    /// Position de l'aiguille, de -3 à +3 IL, au tiers d'IL.
    public static func needle(offset: Float) -> Float {
        (min(max(offset, -3), 3) * 3).rounded() / 3
    }

    /// « +1⅓ », « −⅔ », « 0 ».
    public static func label(offset: Float) -> String {
        let n = needle(offset: offset)
        guard abs(n) > 0.01 else { return "0" }
        return (n > 0 ? "+" : "−") + CameraFormat.ev(abs(n))
    }
}

/// Réglages personnels (C1, C2, C3) : l'état complet de l'appareil, rappelé d'un geste.
public struct CameraPreset: Codable, Equatable, Sendable, Identifiable {
    public var slot: Int
    public var name: String
    public var program: ExposureProgram
    public var aperture: Float
    public var shutter: Double
    public var iso: Float
    public var isoAuto: Bool
    public var exposureBias: Float
    public var manualWhiteBalance: Bool
    public var kelvin: Float
    public var tint: Float
    public var rawMode: String
    public var megapixels: Int?
    public var focalLength: Double?
    public var drive: DriveMode
    public var frameGuide: Int
    public var minimalProcessing: Bool

    public var id: Int { slot }

    public init(slot: Int, name: String, program: ExposureProgram, aperture: Float, shutter: Double, iso: Float,
                isoAuto: Bool, exposureBias: Float, manualWhiteBalance: Bool, kelvin: Float, tint: Float,
                rawMode: String, megapixels: Int?, focalLength: Double?, drive: DriveMode, frameGuide: Int,
                minimalProcessing: Bool) {
        self.slot = slot
        self.name = name
        self.program = program
        self.aperture = aperture
        self.shutter = shutter
        self.iso = iso
        self.isoAuto = isoAuto
        self.exposureBias = exposureBias
        self.manualWhiteBalance = manualWhiteBalance
        self.kelvin = kelvin
        self.tint = tint
        self.rawMode = rawMode
        self.megapixels = megapixels
        self.focalLength = focalLength
        self.drive = drive
        self.frameGuide = frameGuide
        self.minimalProcessing = minimalProcessing
    }

    /// « C1 ».
    public var badge: String { "C\(slot)" }

    /// Résumé lisible : « M · ƒ/2.8 · 1/250 · ISO 200 · RAW ».
    public var summary: String {
        var parts = [program.letter]
        if program == .aperturePriority || program == .manual { parts.append(CameraFormat.aperture(aperture)) }
        if program == .shutterPriority || program == .manual {
            parts.append(CameraFormat.shutter(shutter))
            parts.append(isoAuto ? "ISO auto" : "ISO \(Int(iso))")
        }
        if manualWhiteBalance { parts.append("\(Int(kelvin)) K") }
        parts.append(rawMode)
        return parts.joined(separator: " · ")
    }
}

/// Cadre de visée : formats de `CropSettings.aspects`, appliqués comme recadrage
/// non destructif à la photo prise.
public enum FrameGuide {
    /// Index dans `CropSettings.aspects` proposés comme cadres (0 = aucun).
    public static let options: [Int] = [0, 7, 8, 9, 5, 3, 4, 2, 1]

    /// Rectangle du cadre centré dans une image de `width × height`.
    public static func rect(aspect: Int, width: Double, height: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        let ratio = CropSettings.aspects.indices.contains(aspect) ? CropSettings.aspects[aspect].ratio : 0
        guard ratio > 0, width > 0, height > 0 else { return (0, 0, width, height) }
        var w = width, h = height
        if width / height > ratio { w = height * ratio } else { h = width / ratio }
        return ((width - w) / 2, (height - h) / 2, w, h)
    }
}

extension CameraFormat {
    /// « 1 », « ⅓ », « 1⅔ », « 2 ».
    public static func ev(_ value: Float) -> String {
        let thirds = Int((abs(value) * 3).rounded())
        let whole = thirds / 3
        let fraction = ["", "⅓", "⅔"][thirds % 3]
        if whole == 0 { return fraction.isEmpty ? "0" : fraction }
        return "\(whole)\(fraction)"
    }
}
