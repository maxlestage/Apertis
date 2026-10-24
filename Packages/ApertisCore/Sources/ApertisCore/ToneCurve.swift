import Foundation

/// Point de contrôle d'une courbe, coordonnées dans [0, 1].
public struct CurvePoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Courbe de tonalité évaluée par interpolation cubique monotone (Fritsch–Carlson) :
/// pas de dépassement entre deux points, contrairement à une spline naturelle.
public struct ToneCurve: Sendable {
    public static let resolution = 1024

    public let isIdentity: Bool
    private let table: [Float]

    public init(points: [CurvePoint]) {
        let sorted = ToneCurve.normalized(points)
        isIdentity = sorted.count < 2 || sorted.allSatisfy { abs($0.x - $0.y) < 1e-9 }
            && sorted.first!.x <= 1e-9 && sorted.last!.x >= 1 - 1e-9
        if isIdentity {
            table = []
        } else {
            let n = ToneCurve.resolution
            table = (0..<n).map { i in
                Float(ToneCurve.interpolate(sorted, at: Double(i) / Double(n - 1)))
            }
        }
    }

    /// Évalue la courbe pour une entrée dans [0, 1] (les valeurs hors plage sont bornées).
    public func evaluate(_ x: Float) -> Float {
        if isIdentity { return x }
        let n = table.count
        let position = min(max(x, 0), 1) * Float(n - 1)
        let i0 = Int(position)
        let i1 = min(i0 + 1, n - 1)
        let f = position - Float(i0)
        return table[i0] + (table[i1] - table[i0]) * f
    }

    /// Trie, borne et dédoublonne les points.
    static func normalized(_ points: [CurvePoint]) -> [CurvePoint] {
        var result: [CurvePoint] = []
        for p in points.sorted(by: { $0.x < $1.x }) {
            let clamped = CurvePoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
            if let last = result.last, abs(last.x - clamped.x) < 1e-6 {
                result[result.count - 1] = clamped
            } else {
                result.append(clamped)
            }
        }
        return result
    }

    /// Interpolation cubique d'Hermite avec tangentes de Fritsch–Carlson.
    /// En dehors des points extrêmes, la courbe est constante.
    public static func interpolate(_ points: [CurvePoint], at x: Double) -> Double {
        let p = normalized(points)
        guard p.count >= 2 else { return x }
        if x <= p[0].x { return p[0].y }
        if x >= p[p.count - 1].x { return p[p.count - 1].y }

        let n = p.count
        var secants = [Double](repeating: 0, count: n - 1)
        for k in 0..<(n - 1) {
            secants[k] = (p[k + 1].y - p[k].y) / (p[k + 1].x - p[k].x)
        }
        var tangents = [Double](repeating: 0, count: n)
        tangents[0] = secants[0]
        tangents[n - 1] = secants[n - 2]
        for k in 1..<(n - 1) {
            tangents[k] = secants[k - 1] * secants[k] <= 0 ? 0 : (secants[k - 1] + secants[k]) / 2
        }
        for k in 0..<(n - 1) {
            if secants[k] == 0 {
                tangents[k] = 0
                tangents[k + 1] = 0
                continue
            }
            let a = tangents[k] / secants[k]
            let b = tangents[k + 1] / secants[k]
            if a < 0 { tangents[k] = 0 }
            if b < 0 { tangents[k + 1] = 0 }
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                tangents[k] = t * a * secants[k]
                tangents[k + 1] = t * b * secants[k]
            }
        }

        var k = 0
        while k < n - 2 && x > p[k + 1].x { k += 1 }
        let h = p[k + 1].x - p[k].x
        let t = (x - p[k].x) / h
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return h00 * p[k].y + h10 * h * tangents[k] + h01 * p[k + 1].y + h11 * h * tangents[k + 1]
    }
}

/// Courbe générale et courbes par canal.
public struct CurveSet: Codable, Equatable, Sendable {
    public var master: [CurvePoint] = []
    public var red: [CurvePoint] = []
    public var green: [CurvePoint] = []
    public var blue: [CurvePoint] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        master = try c.decodeIfPresent([CurvePoint].self, forKey: .master) ?? []
        red = try c.decodeIfPresent([CurvePoint].self, forKey: .red) ?? []
        green = try c.decodeIfPresent([CurvePoint].self, forKey: .green) ?? []
        blue = try c.decodeIfPresent([CurvePoint].self, forKey: .blue) ?? []
    }
}
