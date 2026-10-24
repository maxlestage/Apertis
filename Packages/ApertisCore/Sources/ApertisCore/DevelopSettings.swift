import Foundation

/// Réglage TSL d'une plage de teintes. Valeurs dans -100 … +100.
public struct HSLBand: Codable, Equatable, Sendable {
    public var hue: Double = 0
    public var saturation: Double = 0
    public var luminance: Double = 0

    public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hue = hue
        self.saturation = saturation
        self.luminance = luminance
    }

    public var isNeutral: Bool { hue == 0 && saturation == 0 && luminance == 0 }
}

/// Les huit plages de teintes du réglage TSL.
public enum HSLRange: Int, CaseIterable, Sendable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    /// Teinte centrale de la plage, en degrés.
    public var centerHue: Float {
        [0, 30, 60, 120, 180, 240, 270, 300][rawValue]
    }

    public var label: String {
        ["Rouges", "Oranges", "Jaunes", "Verts", "Cyans", "Bleus", "Violets", "Magentas"][rawValue]
    }
}

public struct HSLAdjustments: Codable, Equatable, Sendable {
    public private(set) var bands: [HSLBand] = Array(repeating: HSLBand(), count: HSLRange.allCases.count)

    public init() {}

    public subscript(range: HSLRange) -> HSLBand {
        get { bands[range.rawValue] }
        set { bands[range.rawValue] = newValue }
    }

    public var isNeutral: Bool { bands.allSatisfy(\.isNeutral) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var decoded = try c.decodeIfPresent([HSLBand].self, forKey: .bands) ?? []
        // Tolère un nombre de plages différent (ancienne ou future version du format).
        decoded = Array(decoded.prefix(HSLRange.allCases.count))
        decoded += Array(repeating: HSLBand(), count: HSLRange.allCases.count - decoded.count)
        bands = decoded
    }
}

/// Roue d'étalonnage (ombres, tons moyens ou hautes lumières).
public struct GradeWheel: Codable, Equatable, Sendable {
    /// Teinte en degrés, 0 … 360.
    public var hue: Double = 0
    /// Intensité de la teinte, 0 … 100.
    public var saturation: Double = 0
    /// Décalage de luminosité, -100 … +100.
    public var luminance: Double = 0

    public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hue = hue
        self.saturation = saturation
        self.luminance = luminance
    }

    public var isNeutral: Bool { saturation == 0 && luminance == 0 }
}

public struct ColorGrading: Codable, Equatable, Sendable {
    // Teintes par défaut : bleu dans les ombres, chaud dans les hautes lumières (comme le site).
    public var shadows = GradeWheel(hue: 210)
    public var midtones = GradeWheel()
    public var highlights = GradeWheel(hue: 40)

    public init() {}

    public var isNeutral: Bool { shadows.isNeutral && midtones.isNeutral && highlights.isNeutral }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shadows = try c.decodeIfPresent(GradeWheel.self, forKey: .shadows) ?? GradeWheel(hue: 210)
        midtones = try c.decodeIfPresent(GradeWheel.self, forKey: .midtones) ?? GradeWheel()
        highlights = try c.decodeIfPresent(GradeWheel.self, forKey: .highlights) ?? GradeWheel(hue: 40)
    }
}

/// Référence vers une LUT 3D (.cube) de la bibliothèque.
public struct LUTReference: Codable, Equatable, Sendable {
    public var identifier: String
    /// Intensité 0 … 100.
    public var intensity: Double

    public init(identifier: String, intensity: Double = 100) {
        self.identifier = identifier
        self.intensity = intensity
    }
}

/// Cadrage : format (recadrage centré), quarts de tour, miroir et redressement.
/// Même modèle que le laboratoire du site, pour que les recettes passent de l'un à l'autre.
public struct CropSettings: Codable, Equatable, Sendable {
    /// Formats proposés : libellé, largeur / hauteur (0 = format d'origine).
    public static let aspects: [(label: String, ratio: Double)] = [
        ("Original", 0), ("1:1", 1), ("4:5", 0.8), ("3:2", 1.5), ("4:3", 4.0 / 3.0), ("16:9", 16.0 / 9.0), ("9:16", 9.0 / 16.0),
    ]

    /// Index dans `aspects`.
    public var aspect: Int = 0
    /// Quarts de tour dans le sens horaire, 0 … 3.
    public var rotation: Int = 0
    /// Miroir horizontal.
    public var flip: Bool = false
    /// Redressement en degrés, -45 … +45.
    public var angle: Double = 0

    public init(aspect: Int = 0, rotation: Int = 0, flip: Bool = false, angle: Double = 0) {
        self.aspect = aspect
        self.rotation = rotation
        self.flip = flip
        self.angle = angle
    }

    public var isNeutral: Bool { self == CropSettings() }

    /// Décodage tolérant (les clés inconnues ou absentes sont ignorées).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aspect = try c.decodeIfPresent(Int.self, forKey: .aspect) ?? 0
        rotation = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        flip = try c.decodeIfPresent(Bool.self, forKey: .flip) ?? false
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0
    }
}

/// Ensemble des réglages de développement d'une photo ou d'un plan vidéo.
///
/// Ce sont des paramètres, jamais des pixels : l'original n'est jamais modifié.
/// Plages : sauf mention contraire, les curseurs vont de -100 à +100 et 0 est neutre.
public struct DevelopSettings: Codable, Equatable, Sendable {
    // Balance des blancs
    public var temperature: Double = 0
    public var tint: Double = 0

    // Lumière
    /// Exposition en IL, -5 … +5.
    public var exposure: Double = 0
    public var contrast: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0
    public var whites: Double = 0
    public var blacks: Double = 0

    // Présence
    public var vibrance: Double = 0
    public var saturation: Double = 0

    // Courbes : paramétrique (ombres profondes, tons sombres, tons clairs, hautes lumières,
    // -100 … +100) et courbes à points par canal.
    public var parametricCurve: [Double] = [0, 0, 0, 0]
    public var curves = CurveSet()
    public var hsl = HSLAdjustments()
    public var grading = ColorGrading()
    public var lut: LUTReference?

    // Effets — 0 … 100 (vignette : -100 … +100)
    public var fade: Double = 0
    public var vignette: Double = 0
    public var grain: Double = 0
    /// Taille du grain, 1 … 4.
    public var grainSize: Double = 1.5

    // Détails — 0 … 100
    public var sharpness: Double = 0
    public var noiseReduction: Double = 0

    // Géométrie
    public var crop = CropSettings()

    public init() {}

    public static let neutral = DevelopSettings()

    public var isNeutral: Bool { self == .neutral }

    /// Copie dont chaque valeur est ramenée dans sa plage valide (fichier ancien ou corrompu).
    public func clamped() -> DevelopSettings {
        func c(_ v: Double, _ lo: Double = -100, _ hi: Double = 100) -> Double {
            v.isFinite ? min(max(v, lo), hi) : 0
        }
        var s = self
        s.temperature = c(temperature)
        s.tint = c(tint)
        s.exposure = c(exposure, -5, 5)
        s.contrast = c(contrast)
        s.highlights = c(highlights)
        s.shadows = c(shadows)
        s.whites = c(whites)
        s.blacks = c(blacks)
        s.vibrance = c(vibrance)
        s.saturation = c(saturation)
        for range in HSLRange.allCases {
            let b = hsl[range]
            s.hsl[range] = HSLBand(hue: c(b.hue), saturation: c(b.saturation), luminance: c(b.luminance))
        }
        for path in [\ColorGrading.shadows, \ColorGrading.midtones, \ColorGrading.highlights] {
            let w = grading[keyPath: path]
            s.grading[keyPath: path] = GradeWheel(hue: c(w.hue, 0, 360), saturation: c(w.saturation, 0, 100),
                                                  luminance: c(w.luminance))
        }
        if var l = lut {
            l.intensity = c(l.intensity, 0, 100)
            s.lut = l
        }
        s.parametricCurve = (0..<4).map { i in c(i < parametricCurve.count ? parametricCurve[i] : 0) }
        s.fade = c(fade, 0, 100)
        s.vignette = c(vignette)
        s.grain = c(grain, 0, 100)
        s.grainSize = grainSize.isFinite ? min(max(grainSize, 1), 4) : 1.5
        s.sharpness = c(sharpness, 0, 100)
        s.noiseReduction = c(noiseReduction, 0, 100)
        s.crop.aspect = min(max(crop.aspect, 0), CropSettings.aspects.count - 1)
        s.crop.rotation = ((crop.rotation % 4) + 4) % 4
        s.crop.angle = c(crop.angle, -45, 45)
        return s
    }

    /// Décodage tolérant : une clé absente prend sa valeur par défaut, ce qui permet
    /// d'ouvrir les projets créés par une version antérieure de l'application.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d(_ key: CodingKeys) throws -> Double { try c.decodeIfPresent(Double.self, forKey: key) ?? 0 }
        temperature = try d(.temperature)
        tint = try d(.tint)
        exposure = try d(.exposure)
        contrast = try d(.contrast)
        highlights = try d(.highlights)
        shadows = try d(.shadows)
        whites = try d(.whites)
        blacks = try d(.blacks)
        vibrance = try d(.vibrance)
        saturation = try d(.saturation)
        parametricCurve = try c.decodeIfPresent([Double].self, forKey: .parametricCurve) ?? [0, 0, 0, 0]
        curves = try c.decodeIfPresent(CurveSet.self, forKey: .curves) ?? CurveSet()
        hsl = try c.decodeIfPresent(HSLAdjustments.self, forKey: .hsl) ?? HSLAdjustments()
        grading = try c.decodeIfPresent(ColorGrading.self, forKey: .grading) ?? ColorGrading()
        lut = try c.decodeIfPresent(LUTReference.self, forKey: .lut)
        fade = try d(.fade)
        vignette = try d(.vignette)
        grain = try d(.grain)
        grainSize = try c.decodeIfPresent(Double.self, forKey: .grainSize) ?? 1.5
        sharpness = try d(.sharpness)
        noiseReduction = try d(.noiseReduction)
        crop = try c.decodeIfPresent(CropSettings.self, forKey: .crop) ?? CropSettings()
    }
}
