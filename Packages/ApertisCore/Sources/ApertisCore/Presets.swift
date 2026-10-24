import Foundation

/// Style réutilisable. Un style ne touche qu'au rendu (tonalité et couleur, effets) :
/// l'exposition, la balance des blancs, les détails et le recadrage propres à la photo sont conservés.
public struct Preset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let settings: DevelopSettings

    public init(id: String, name: String, settings: DevelopSettings) {
        self.id = id
        self.name = name
        self.settings = settings
    }

    public func apply(to base: DevelopSettings) -> DevelopSettings {
        var s = base
        s.contrast = settings.contrast
        s.whites = settings.whites
        s.blacks = settings.blacks
        s.vibrance = settings.vibrance
        s.saturation = settings.saturation
        s.curves = settings.curves
        s.hsl = settings.hsl
        s.grading = settings.grading
        s.fade = settings.fade
        s.grain = settings.grain
        s.vignette = settings.vignette
        s.lut = settings.lut
        return s
    }

    /// Crée un style à partir des réglages actuels d'une photo.
    public static func capture(from settings: DevelopSettings, name: String) -> Preset {
        Preset(id: UUID().uuidString, name: name, settings: Preset(id: "", name: "", settings: settings).apply(to: .neutral))
    }
}

public enum BuiltInPresets {
    public static let all: [Preset] = [natural, warmFilm, portrait, blackAndWhite, cinematic, faded, vivid]

    public static let natural: Preset = {
        var s = DevelopSettings()
        s.contrast = 8
        s.vibrance = 12
        return Preset(id: "builtin.natural", name: "Naturel", settings: s)
    }()

    public static let warmFilm: Preset = {
        var s = DevelopSettings()
        s.contrast = -10
        s.fade = 35
        s.grain = 25
        s.saturation = -8
        s.curves.master = [CurvePoint(x: 0, y: 0.04), CurvePoint(x: 0.25, y: 0.24), CurvePoint(x: 0.75, y: 0.8),
                           CurvePoint(x: 1, y: 0.96)]
        s.grading.highlights = GradeWheel(hue: 40, saturation: 22)
        s.grading.shadows = GradeWheel(hue: 200, saturation: 10)
        return Preset(id: "builtin.warm-film", name: "Argentique chaud", settings: s)
    }()

    public static let portrait: Preset = {
        var s = DevelopSettings()
        s.contrast = -6
        s.vibrance = 10
        s.saturation = -10
        s.hsl[.orange] = HSLBand(hue: -4, saturation: -12, luminance: 12)
        s.hsl[.red] = HSLBand(saturation: -10)
        s.grading.highlights = GradeWheel(hue: 30, saturation: 10)
        s.fade = 12
        return Preset(id: "builtin.portrait", name: "Portrait doux", settings: s)
    }()

    public static let blackAndWhite: Preset = {
        var s = DevelopSettings()
        s.saturation = -100
        s.contrast = 25
        s.grain = 30
        s.curves.master = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.2), CurvePoint(x: 0.75, y: 0.82),
                           CurvePoint(x: 1, y: 1)]
        return Preset(id: "builtin.bw", name: "Noir et blanc", settings: s)
    }()

    public static let cinematic: Preset = {
        var s = DevelopSettings()
        s.contrast = 15
        s.saturation = -12
        s.grading.shadows = GradeWheel(hue: 190, saturation: 35, luminance: -5)
        s.grading.highlights = GradeWheel(hue: 35, saturation: 30)
        s.hsl[.orange] = HSLBand(saturation: 10)
        s.hsl[.blue] = HSLBand(hue: -15, saturation: -10)
        s.vignette = 20
        return Preset(id: "builtin.cinematic", name: "Cinéma", settings: s)
    }()

    public static let faded: Preset = {
        var s = DevelopSettings()
        s.contrast = -25
        s.fade = 55
        s.saturation = -20
        s.grading.midtones = GradeWheel(hue: 160, saturation: 8)
        return Preset(id: "builtin.faded", name: "Délavé", settings: s)
    }()

    public static let vivid: Preset = {
        var s = DevelopSettings()
        s.contrast = 20
        s.vibrance = 35
        s.saturation = 8
        s.blacks = -10
        return Preset(id: "builtin.vivid", name: "Vif", settings: s)
    }()
}
