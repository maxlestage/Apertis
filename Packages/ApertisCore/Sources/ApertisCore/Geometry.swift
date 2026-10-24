import Foundation

/// Transformation affine 2D, mêmes conventions que `CGAffineTransform` :
/// (x, y) → (a·x + c·y + tx, b·x + d·y + ty).
public struct Affine2D: Equatable, Sendable {
    public var a, b, c, d, tx, ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public func apply(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        (a * x + c * y + tx, b * x + d * y + ty)
    }

    public var inverted: Affine2D {
        let det = a * d - b * c
        guard abs(det) > 1e-12 else { return self }
        return Affine2D(a: d / det, b: -b / det, c: -c / det, d: a / det,
                        tx: (c * ty - d * tx) / det, ty: (b * tx - a * ty) / det)
    }
}

/// Cadrage final : rotation par quarts de tour, miroir, format centré et redressement.
/// Reprend exactement la fonction `geometry` du laboratoire du site.
public struct FrameGeometry: Equatable, Sendable {
    /// Taille de l'image de sortie, en pixels.
    public let width: Int
    public let height: Int
    /// Matrice 3×3 en colonnes : coordonnées de la source (u, v ∈ [0, 1], origine en haut
    /// à gauche) = M · (u, v, 1) de la sortie.
    public let matrix: [Double]

    public init(crop rawCrop: CropSettings, sourceWidth w: Double, sourceHeight h: Double) {
        let crop = Self.clamped(rawCrop)
        let quarter = crop.rotation
        let (rw, rh) = quarter % 2 == 1 ? (h, w) : (w, h)
        let ratio = CropSettings.aspects[crop.aspect].ratio
        var (cw, ch) = (rw, rh)
        if ratio > 0 {
            if rw / rh > ratio { cw = rh * ratio } else { ch = rw / ratio }
        }
        // Le cadre redressé doit rester dans l'image : on le réduit.
        let theta = crop.angle * .pi / 180
        let (sinA, cosA) = (abs(sin(theta)), abs(cos(theta)))
        let need = max((cosA * cw + sinA * ch) / rw, (sinA * cw + cosA * ch) / rh)
        let k = need > 1 ? 1 / need : 1
        cw *= k
        ch *= k

        let (st, ct) = (sin(theta), cos(theta))
        let a = [ct * cw / rw, st * cw / rh]
        let b = [-st * ch / rw, ct * ch / rh]
        let o = [0.5 - 0.5 * (a[0] + b[0]), 0.5 - 0.5 * (a[1] + b[1])]
        let rot: [[Double]]
        let rotO: [Double]
        switch quarter {
        case 0: (rot, rotO) = ([[1, 0], [0, 1]], [0, 0])
        case 1: (rot, rotO) = ([[0, -1], [1, 0]], [0, 1])
        case 2: (rot, rotO) = ([[-1, 0], [0, -1]], [1, 1])
        default: (rot, rotO) = ([[0, 1], [-1, 0]], [1, 0])
        }
        func compose(_ v: [Double]) -> [Double] {
            [rot[0][0] * v[0] + rot[1][0] * v[1], rot[0][1] * v[0] + rot[1][1] * v[1]]
        }
        var ca = compose(a)
        let cb = compose(b)
        let co0 = compose(o)
        var co = [co0[0] + rotO[0], co0[1] + rotO[1]]
        if crop.flip {
            co = [co[0] + ca[0], co[1] + ca[1]]
            ca = [-ca[0], -ca[1]]
        }
        width = max(Int(cw.rounded()), 1)
        height = max(Int(ch.rounded()), 1)
        matrix = [ca[0], ca[1], 0, cb[0], cb[1], 0, co[0], co[1], 1]
    }

    private static func clamped(_ crop: CropSettings) -> CropSettings {
        var s = DevelopSettings()
        s.crop = crop
        return s.clamped().crop
    }

    /// Point de la source (u, v normalisés, origine en haut à gauche) pour un point de la sortie.
    public func map(_ u: Double, _ v: Double) -> (u: Double, v: Double) {
        (matrix[0] * u + matrix[3] * v + matrix[6], matrix[1] * u + matrix[4] * v + matrix[7])
    }

    /// Vrai si la sortie est la source telle quelle.
    public var isIdentity: Bool {
        matrix == [1, 0, 0, 0, 1, 0, 0, 0, 1]
    }

    /// Transformation à appliquer à l'image source, en pixels Core Image (origine en bas à
    /// gauche, source de `sourceWidth × sourceHeight` à l'origine) : elle place la partie
    /// cadrée dans le rectangle (0, 0, width, height).
    public func sourceToOutput(sourceWidth W: Double, sourceHeight H: Double) -> Affine2D {
        let m = matrix
        let w = Double(width), h = Double(height)
        let outputToSource = Affine2D(a: W * m[0] / w, b: -H * m[1] / w, c: -W * m[3] / h, d: H * m[4] / h,
                                      tx: W * (m[3] + m[6]), ty: H * (1 - m[4] - m[7]))
        return outputToSource.inverted
    }
}
