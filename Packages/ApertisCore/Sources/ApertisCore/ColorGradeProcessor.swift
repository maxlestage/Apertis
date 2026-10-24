import Foundation

/// Étape « tonalité et couleur » du pipeline de développement, en espace sRGB encodé [0, 1].
///
/// Le pipeline complet est découpé en trois étapes :
/// 1. **Linéaire** (Core Image / CIRAWFilter) : dématriçage, balance des blancs, exposition.
/// 2. **Tonalité et couleur** (ce type) : points noir et blanc, contraste, hautes lumières,
///    ombres, courbe paramétrique, courbes à points, TSL, vibrance, saturation, étalonnage
///    3 voies, fondu et LUT créative. Fonction pure couleur → couleur, « cuite » dans un cube
///    3D (`makeCube`) appliqué sur le GPU : aperçu, export photo et vidéo font le même calcul.
/// 3. **Effets** (Core Image) : réduction du bruit, netteté, vignette, grain, cadrage.
///
/// Les calculs reproduisent exactement ceux du laboratoire du site (`site/src/grade.rs`,
/// fonction `develop`) : un style ou une recette donne le même rendu dans l'app et en ligne.
/// Les courbes à points, la luminosité des roues d'étalonnage et la LUT créative sont propres
/// à l'app et s'ajoutent sans rien changer quand elles sont neutres.
public struct ColorGradeProcessor: Sendable {
    public let settings: DevelopSettings
    private let lut: CubeLUT?
    private let lutIntensity: Float

    private let toneActive: Bool
    private let blackPoint: Float
    private let whitePoint: Float
    private let contrast: Float
    private let highlights: Float
    private let shadows: Float
    private let parametric: [Float]
    private let masterCurve: ToneCurve
    private let redCurve: ToneCurve
    private let greenCurve: ToneCurve
    private let blueCurve: ToneCurve
    private let hslActive: Bool
    private let hslBands: [HSLBand]
    private let vibrance: Float
    private let saturation: Float
    private let gradeHues: [Float]
    private let gradeAmounts: [Float]
    private let gradeLuminance: [Float]
    private let gradingActive: Bool
    private let fade: Float

    /// - Parameter lut: la LUT résolue correspondant à `settings.lut` (ignorée si `settings.lut` est nil).
    public init(settings rawSettings: DevelopSettings, lut: CubeLUT? = nil) {
        let s = rawSettings.clamped()
        settings = s
        blackPoint = Float(-s.blacks / 100 * 0.08)
        whitePoint = Float(1 - s.whites / 100 * 0.12)
        contrast = Float(s.contrast)
        highlights = Float(s.highlights)
        shadows = Float(s.shadows)
        parametric = s.parametricCurve.map(Float.init)
        toneActive = s.blacks != 0 || s.whites != 0 || s.contrast != 0 || s.highlights != 0 || s.shadows != 0
            || parametric.contains { $0 != 0 }
        masterCurve = ToneCurve(points: s.curves.master)
        redCurve = ToneCurve(points: s.curves.red)
        greenCurve = ToneCurve(points: s.curves.green)
        blueCurve = ToneCurve(points: s.curves.blue)
        hslActive = !s.hsl.isNeutral
        hslBands = s.hsl.bands
        vibrance = Float(s.vibrance)
        saturation = Float(s.saturation)
        let wheels = [s.grading.shadows, s.grading.midtones, s.grading.highlights]
        gradeHues = wheels.map { Float($0.hue) }
        gradeAmounts = wheels.map { Float($0.saturation / 100) }
        gradeLuminance = wheels.map { Float($0.luminance / 100) }
        gradingActive = !s.grading.isNeutral
        fade = Float(s.fade / 100) * 0.14
        if let reference = s.lut, let lut {
            self.lut = lut
            lutIntensity = Float(reference.intensity / 100)
        } else {
            self.lut = nil
            lutIntensity = 0
        }
    }

    /// Vrai si l'étape n'a aucun effet : le moteur peut alors l'omettre.
    public var isIdentity: Bool {
        !toneActive && masterCurve.isIdentity && redCurve.isIdentity && greenCurve.isIdentity && blueCurve.isIdentity
            && !hslActive && vibrance == 0 && saturation == 0 && !gradingActive && fade == 0
            && (lut == nil || lutIntensity == 0)
    }

    // MARK: Tonalité (identique à `tone` et `parametric` du site)

    private func tone(_ input: Float) -> Float {
        var x = min(max((input - blackPoint) / (whitePoint - blackPoint), 0), 1)
        if contrast != 0 {
            let k = exp2(contrast / 100 * 1.2)
            let pivot: Float = 0.46
            x = x < pivot ? pivot * pow(x / pivot, k) : 1 - (1 - pivot) * pow((1 - x) / (1 - pivot), k)
        }
        if highlights != 0 {
            x += highlights / 100 * 0.3 * ColorMath.smoothstep(0.5, 1, x) * (highlights < 0 ? 1 : 1 - x * 0.5)
        }
        if shadows != 0 {
            let w = x * (1 - x) * (1 - x) * 6.75 * (1 - ColorMath.smoothstep(0.6, 1, x))
            x += shadows / 100 * 0.14 * w
        }
        return min(max(x, 0), 1)
    }

    private func parametricCurve(_ x: Float) -> Float {
        let centers: [Float] = [0.12, 0.37, 0.63, 0.88]
        var y = x
        for (i, center) in centers.enumerated() {
            let a = parametric[i] / 100
            if a != 0 {
                let d = min(max((x - center) / 0.25, -1), 1)
                y += a * 0.1 * 0.5 * (1 + cos(d * .pi))
            }
        }
        return min(max(y, 0), 1)
    }

    /// Applique l'étape à une couleur sRGB encodée.
    public func apply(_ input: RGB) -> RGB {
        var c = simd_clamp01(input)

        // Tonalité sur la luminance, teinte conservée.
        if toneActive {
            let l = ColorMath.luminance(c)
            let tl = parametricCurve(tone(l))
            if l > 1e-5 {
                c *= tl / l
                // Les couleurs qui dépasseraient le blanc se rapprochent du blanc au lieu d'écrêter.
                let m = max(c.x, c.y, c.z)
                if m > 1 {
                    let t = min((m - 1) / m, 1)
                    let n = c / m
                    c = n + RGB(repeating: t) * (RGB(repeating: 1) - n)
                    let l2 = ColorMath.luminance(c)
                    if l2 > 1e-5 {
                        let k2 = min(tl / l2, 1 / max(max(c.x, c.y, c.z), 1e-5))
                        c *= k2
                    }
                }
            } else {
                c = RGB(repeating: tl)
            }
            c = simd_clamp01(c)
        }

        // Courbes à points (propres à l'app).
        if !masterCurve.isIdentity {
            c = RGB(masterCurve.evaluate(c.x), masterCurve.evaluate(c.y), masterCurve.evaluate(c.z))
        }
        c = RGB(redCurve.evaluate(c.x), greenCurve.evaluate(c.y), blueCurve.evaluate(c.z))

        if hslActive { c = applyHSL(c) }

        if vibrance != 0 || saturation != 0 {
            let l = ColorMath.luminance(c)
            let chroma = max(c.x, c.y, c.z) - min(c.x, c.y, c.z)
            let factor = (1 + vibrance / 100 * (1 - chroma)) * (1 + saturation / 100)
            c = simd_clamp01(RGB(repeating: l) + (c - RGB(repeating: l)) * factor)
        }

        if gradingActive {
            let l = min(max(ColorMath.luminance(c), 0), 1)
            let weights: [Float] = [(1 - l) * (1 - l), 2 * l * (1 - l), l * l]
            for zone in 0..<3 {
                if gradeAmounts[zone] > 0 {
                    let tint = ColorMath.hslToRgb(h: gradeHues[zone], s: 1, l: 0.5)
                    c += (tint - RGB(repeating: 0.5)) * (gradeAmounts[zone] * 0.22 * weights[zone])
                }
                if gradeLuminance[zone] != 0 {
                    c += RGB(repeating: gradeLuminance[zone] * 0.2 * weights[zone])
                }
            }
            c = simd_clamp01(c)
        }

        if fade > 0 {
            c = RGB(fade + c.x * (1 - fade), fade + c.y * (1 - fade * 0.6), fade + c.z * (1 - fade * 0.3))
        }

        if let lut, lutIntensity > 0 {
            let graded = lut.apply(c)
            c = c + (graded - c) * lutIntensity
        }
        return simd_clamp01(c)
    }

    private func applyHSL(_ c: RGB) -> RGB {
        var (h, s, l) = ColorMath.rgbToHsl(c)
        guard s > 1e-5 else { return c }

        // Interpolation douce entre les deux plages qui encadrent la teinte.
        let ranges = HSLRange.allCases
        var lower = ranges.count - 1
        for (i, range) in ranges.enumerated() where range.centerHue <= h { lower = i }
        let upper = (lower + 1) % ranges.count
        let lowerHue = ranges[lower].centerHue
        var upperHue = ranges[upper].centerHue
        if upperHue <= lowerHue { upperHue += 360 }
        let hh = h < lowerHue ? h + 360 : h
        let f = ColorMath.smoothstep(0, 1, (hh - lowerHue) / (upperHue - lowerHue))
        let a = hslBands[lower]
        let b = hslBands[upper]
        let hueShift = Float(a.hue) * (1 - f) + Float(b.hue) * f
        let satShift = Float(a.saturation) * (1 - f) + Float(b.saturation) * f
        let lumShift = Float(a.luminance) * (1 - f) + Float(b.luminance) * f

        h += hueShift / 100 * 30
        let originalSaturation = s
        s = min(max(s * (1 + satShift / 100), 0), 1)
        l = min(max(l + lumShift / 100 * 0.25 * originalSaturation, 0), 1)
        return ColorMath.hslToRgb(h: h, s: s, l: l)
    }

    /// Cube 3D RGBA (rouge le plus rapide), au format attendu par `CIColorCubeWithColorSpace`.
    public func makeCube(dimension: Int) -> [Float] {
        precondition((2...128).contains(dimension), "dimension de cube invalide")
        var data = [Float]()
        data.reserveCapacity(dimension * dimension * dimension * 4)
        let scale = 1 / Float(dimension - 1)
        for b in 0..<dimension {
            for g in 0..<dimension {
                for r in 0..<dimension {
                    let out = apply(RGB(Float(r) * scale, Float(g) * scale, Float(b) * scale))
                    data.append(out.x)
                    data.append(out.y)
                    data.append(out.z)
                    data.append(1)
                }
            }
        }
        return data
    }
}
