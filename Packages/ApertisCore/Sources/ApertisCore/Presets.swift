import Foundation

/// Style réutilisable. Un style remplace le rendu (tonalité, couleur, effets) et conserve
/// ce qui est propre à la photo : exposition, balance des blancs, détails et cadrage.
public struct Preset: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var settings: DevelopSettings

    public init(id: String, name: String, settings: DevelopSettings) {
        self.id = id
        self.name = name
        self.settings = settings
    }

    /// Même règle que le site (`apply_preset`).
    public func apply(to base: DevelopSettings) -> DevelopSettings {
        var s = settings
        s.exposure = base.exposure
        s.temperature = base.temperature
        s.tint = base.tint
        s.sharpness = base.sharpness
        s.noiseReduction = base.noiseReduction
        s.crop = base.crop
        return s
    }

    /// Crée un style à partir des réglages actuels d'une photo.
    public static func capture(from settings: DevelopSettings, name: String) -> Preset {
        Preset(id: "user.\(UUID().uuidString)", name: name, settings: Preset(id: "", name: "", settings: settings).apply(to: .neutral))
    }

    public var isBuiltIn: Bool { id.hasPrefix("builtin.") }
}

/// Les styles d'Apertis, identiques à ceux du laboratoire du site (même identifiant,
/// même nom, même rendu).
public enum BuiltInPresets {
    public static let all: [Preset] = [original, naturel, portra, kodachrome, cinema, nordique, dore, nb, nbDoux]

    /// Les styles inclus dans la formule gratuite.
    public static let free: Set<String> = ["builtin.original", "builtin.naturel", "builtin.nb"]

    public static func preset(siteID: String) -> Preset? {
        all.first { $0.id == "builtin.\(siteID)" }
    }

    private static func make(_ id: String, _ name: String, _ edit: (inout DevelopSettings) -> Void) -> Preset {
        var s = DevelopSettings()
        edit(&s)
        return Preset(id: "builtin.\(id)", name: name, settings: s)
    }

    private static func grade(_ s: inout DevelopSettings, hues: [Double], amounts: [Double]) {
        s.grading.shadows = GradeWheel(hue: hues[0], saturation: amounts[0])
        s.grading.midtones = GradeWheel(hue: hues[1], saturation: amounts[1])
        s.grading.highlights = GradeWheel(hue: hues[2], saturation: amounts[2])
    }

    public static let original = make("original", "Original") { _ in }

    public static let naturel = make("naturel", "Naturel") { s in
        s.contrast = 10
        s.vibrance = 18
        s.shadows = 12
        s.highlights = -10
    }

    public static let portra = make("portra", "Portra") { s in
        s.contrast = -18
        s.saturation = -15
        s.fade = 35
        s.grain = 18
        s.highlights = -25
        s.shadows = 15
        s.hsl[.orange] = HSLBand(saturation: -10, luminance: 15)
        s.hsl[.green] = HSLBand(hue: -20)
        grade(&s, hues: [190, 30, 40], amounts: [18, 10, 35])
    }

    public static let kodachrome = make("kodachrome", "Kodachrome") { s in
        s.contrast = 38
        s.saturation = 22
        s.vibrance = 15
        s.blacks = -20
        s.hsl[.blue] = HSLBand(hue: -12)
        s.hsl[.red] = HSLBand(saturation: 12)
        grade(&s, hues: [220, 0, 40], amounts: [10, 0, 14])
        s.grain = 10
    }

    public static let cinema = make("cinema", "Cinéma") { s in
        s.contrast = 18
        s.saturation = -10
        s.highlights = -20
        grade(&s, hues: [190, 0, 35], amounts: [35, 0, 30])
        s.hsl[.orange] = HSLBand(saturation: 10)
        s.hsl[.blue] = HSLBand(hue: -15)
        s.vignette = 22
    }

    public static let nordique = make("nordique", "Nordique") { s in
        s.contrast = -10
        s.saturation = -45
        s.fade = 22
        s.whites = 15
        grade(&s, hues: [210, 200, 190], amounts: [25, 15, 10])
    }

    public static let dore = make("dore", "Heure dorée") { s in
        s.contrast = 12
        s.vibrance = 30
        s.shadows = 20
        grade(&s, hues: [20, 35, 45], amounts: [20, 25, 45])
        s.hsl[.yellow] = HSLBand(luminance: 10)
    }

    public static let nb = make("nb", "Noir et blanc") { s in
        s.saturation = -100
        s.contrast = 30
        s.grain = 22
        s.parametricCurve = [-20, -5, 10, 15]
    }

    public static let nbDoux = make("nb-doux", "N&B doux") { s in
        s.saturation = -100
        s.contrast = -15
        s.fade = 30
        s.grain = 30
        grade(&s, hues: [30, 0, 40], amounts: [8, 0, 8])
    }
}
