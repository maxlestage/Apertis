import Foundation

/// Couleur RVB en virgule flottante.
public typealias RGB = SIMD3<Float>

/// Fonctions colorimétriques de référence.
///
/// Elles servent à la fois au calcul CPU (cubes de couleur, tests) et de
/// spécification pour les implémentations GPU : un shader doit produire le
/// même résultat que ces fonctions, à l'arrondi près.
public enum ColorMath {
    /// Gris moyen (18 %) encodé sRGB : pivot naturel du contraste.
    public static let middleGrey: Float = 0.4613

    /// Courbe de transfert sRGB inverse (encodé → linéaire). Symétrique pour les valeurs négatives.
    public static func srgbToLinear(_ v: Float) -> Float {
        let a = abs(v)
        let l = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
        return v < 0 ? -l : l
    }

    /// Courbe de transfert sRGB (linéaire → encodé). Symétrique pour les valeurs négatives.
    public static func linearToSrgb(_ v: Float) -> Float {
        let a = abs(v)
        let e = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055
        return v < 0 ? -e : e
    }

    /// Luminance relative Rec. 709 / sRGB.
    public static func luminance(_ c: RGB) -> Float {
        0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
    }

    public static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    public static func clamp01(_ c: RGB) -> RGB {
        simd_clamp01(c)
    }

    /// RVB → TSL. Teinte en degrés [0, 360), saturation et luminosité dans [0, 1].
    public static func rgbToHsl(_ c: RGB) -> (h: Float, s: Float, l: Float) {
        let maxC = max(c.x, c.y, c.z)
        let minC = min(c.x, c.y, c.z)
        let l = (maxC + minC) / 2
        let delta = maxC - minC
        guard delta >= 1e-6 else { return (0, 0, l) }
        let s = l > 0.5 ? delta / (2 - maxC - minC) : delta / (maxC + minC)
        var h: Float
        if maxC == c.x {
            h = (c.y - c.z) / delta + (c.y < c.z ? 6 : 0)
        } else if maxC == c.y {
            h = (c.z - c.x) / delta + 2
        } else {
            h = (c.x - c.y) / delta + 4
        }
        h *= 60
        return (h, s, l)
    }

    /// TSL → RVB. Teinte en degrés (n'importe quelle valeur, ramenée dans [0, 360)).
    public static func hslToRgb(h: Float, s: Float, l: Float) -> RGB {
        guard s >= 1e-6 else { return RGB(repeating: l) }
        var hue = h.truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ tIn: Float) -> Float {
            var t = tIn
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        let hn = hue / 360
        return RGB(channel(hn + 1.0 / 3), channel(hn), channel(hn - 1.0 / 3))
    }

    /// Gains de balance des blancs appliqués en espace linéaire aux images déjà développées
    /// (JPEG, HEIF, vidéo). Les RAW utilisent la balance des blancs du dématriçage.
    ///
    /// - Parameters:
    ///   - temperature: -100 (plus froid) … +100 (plus chaud)
    ///   - tint: -100 (plus vert) … +100 (plus magenta)
    /// - Returns: gains R, V, B normalisés pour conserver la luminance d'un blanc neutre.
    public static func whiteBalanceGains(temperature: Double, tint: Double) -> RGB {
        let t = Float(min(max(temperature, -100), 100) / 100)
        let ti = Float(min(max(tint, -100), 100) / 100)
        let gains = RGB(exp2(0.35 * t), exp2(-0.25 * ti), exp2(-0.35 * t))
        return gains / luminance(gains)
    }
}

@inline(__always)
func simd_clamp01(_ c: RGB) -> RGB {
    RGB(min(max(c.x, 0), 1), min(max(c.y, 0), 1), min(max(c.z, 0), 1))
}
