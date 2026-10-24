import Foundation

/// Étape « couleur » du pipeline de développement, en espace sRGB encodé [0, 1].
///
/// Le pipeline complet est découpé en trois étapes :
/// 1. **Linéaire** (Core Image / CIRAWFilter) : dématriçage, balance des blancs, exposition,
///    récupération des hautes lumières (`highlights` < 0) et débouchage des ombres.
/// 2. **Couleur** (ce type) : points blanc/noir, contraste, hautes lumières positives, courbes,
///    TSL, vibrance, saturation, étalonnage 3 voies, fondu et LUT créative.
///    Cette étape est une fonction pure couleur → couleur : elle est « cuite » dans un cube 3D
///    (`makeCube`) appliqué sur le GPU par `CIColorCubeWithColorSpace`. L'aperçu, l'export
///    photo et la vidéo utilisent donc exactement le même calcul, vérifié par les tests.
/// 3. **Spatiale** (Core Image) : réduction du bruit, netteté, vignette, grain, recadrage.
public struct ColorGradeProcessor: Sendable {
    public let settings: DevelopSettings
    private let lut: CubeLUT?

    private let levelsActive: Bool
    private let blackPoint: Float
    private let whitePoint: Float
    private let contrastFactor: Float
    private let highlightBoost: Float
    private let masterCurve: ToneCurve
    private let redCurve: ToneCurve
    private let greenCurve: ToneCurve
    private let blueCurve: ToneCurve
    private let hslActive: Bool
    private let hslBands: [HSLBand]
    private let vibrance: Float
    private let saturation: Float
    private let gradeOffsets: (shadows: RGB, midtones: RGB, highlights: RGB)
    private let gradingActive: Bool
    private let fade: Float
    private let lutIntensity: Float

    /// - Parameter lut: la LUT résolue correspondant à `settings.lut` (ignorée si `settings.lut` est nil).
    public init(settings rawSettings: DevelopSettings, lut: CubeLUT? = nil) {
        let s = rawSettings.clamped()
        settings = s
        blackPoint = Float(-s.blacks / 100 * 0.1)
        whitePoint = Float(1 - s.whites / 100 * 0.1)
        levelsActive = s.blacks != 0 || s.whites != 0
        contrastFactor = Float(exp2(s.contrast / 100))
        highlightBoost = Float(max(s.highlights, 0) / 100)
        masterCurve = ToneCurve(points: s.curves.master)
        redCurve = ToneCurve(points: s.curves.red)
        greenCurve = ToneCurve(points: s.curves.green)
        blueCurve = ToneCurve(points: s.curves.blue)
        hslActive = !s.hsl.isNeutral
        hslBands = s.hsl.bands
        vibrance = Float(s.vibrance / 100)
        saturation = Float(s.saturation / 100)
        func offset(_ w: GradeWheel) -> RGB {
            let tint = ColorMath.hslToRgb(h: Float(w.hue), s: 1, l: 0.5) - RGB(repeating: 0.5)
            return tint * Float(w.saturation / 100) * 0.2 + RGB(repeating: Float(w.luminance / 100) * 0.2)
        }
        gradeOffsets = (offset(s.grading.shadows), offset(s.grading.midtones), offset(s.grading.highlights))
        gradingActive = !s.grading.isNeutral
        fade = Float(s.fade / 100) * 0.12
        if let reference = s.lut, let lut {
            self.lut = lut
            lutIntensity = Float(reference.intensity / 100)
        } else {
            self.lut = nil
            lutIntensity = 0
        }
    }

    /// Vrai si l'étape couleur n'a aucun effet : le moteur peut alors l'omettre.
    public var isIdentity: Bool {
        !levelsActive && contrastFactor == 1 && highlightBoost == 0
            && masterCurve.isIdentity && redCurve.isIdentity && greenCurve.isIdentity && blueCurve.isIdentity
            && !hslActive && vibrance == 0 && saturation == 0 && !gradingActive && fade == 0
            && (lut == nil || lutIntensity == 0)
    }

    /// Applique l'étape couleur à une couleur sRGB encodée.
    public func apply(_ input: RGB) -> RGB {
        var c = simd_clamp01(input)

        if levelsActive {
            c = (c - RGB(repeating: blackPoint)) / (whitePoint - blackPoint)
        }
        if contrastFactor != 1 {
            let pivot = RGB(repeating: ColorMath.middleGrey)
            c = pivot + (c - pivot) * contrastFactor
        }
        if highlightBoost > 0 {
            let l = ColorMath.luminance(c)
            c += RGB(repeating: highlightBoost * 0.25 * ColorMath.smoothstep(0.5, 1, l))
        }
        c = simd_clamp01(c)

        if !masterCurve.isIdentity {
            c = RGB(masterCurve.evaluate(c.x), masterCurve.evaluate(c.y), masterCurve.evaluate(c.z))
        }
        c = RGB(redCurve.evaluate(c.x), greenCurve.evaluate(c.y), blueCurve.evaluate(c.z))

        if hslActive { c = applyHSL(c) }

        if vibrance != 0 || saturation != 0 {
            let l = ColorMath.luminance(c)
            let currentSaturation = max(c.x, c.y, c.z) - min(c.x, c.y, c.z)
            let factor = (1 + vibrance * (1 - currentSaturation)) * (1 + saturation)
            c = simd_clamp01(RGB(repeating: l) + (c - RGB(repeating: l)) * factor)
        }

        if gradingActive {
            let l = min(max(ColorMath.luminance(c), 0), 1)
            let ws = (1 - l) * (1 - l)
            let wh = l * l
            let wm = 2 * l * (1 - l)
            c = simd_clamp01(c + gradeOffsets.shadows * ws + gradeOffsets.midtones * wm + gradeOffsets.highlights * wh)
        }

        if fade > 0 {
            c = RGB(repeating: fade) + c * (1 - fade)
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
        var hh = h
        if hh < lowerHue { hh += 360 }
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
