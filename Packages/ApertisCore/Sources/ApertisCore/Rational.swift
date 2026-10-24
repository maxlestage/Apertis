import Foundation

/// Nombre rationnel exact, utilisé pour les temps et les cadences.
///
/// Les temps vidéo ne doivent jamais être stockés en `Double` : 1/29,97 s n'est pas
/// représentable exactement et les erreurs s'accumulent jusqu'à décaler une coupe d'une image.
/// Sur iOS, un `Rational` se convertit directement en `CMTime`.
public struct Rational: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let numerator: Int64
    public let denominator: Int64

    public init(_ numerator: Int64, _ denominator: Int64 = 1) {
        precondition(denominator != 0, "dénominateur nul")
        let sign: Int64 = denominator < 0 ? -1 : 1
        let g = Rational.gcd(numerator, denominator)
        self.numerator = sign * numerator / g
        self.denominator = sign * denominator / g
    }

    /// Valeur la plus proche avec le dénominateur donné.
    public init(seconds: Double, timescale: Int64) {
        self.init(Int64((seconds * Double(timescale)).rounded()), timescale)
    }

    public static let zero = Rational(0)
    public static let one = Rational(1)

    public var seconds: Double { Double(numerator) / Double(denominator) }
    public var isInteger: Bool { denominator == 1 }

    /// Partie entière par défaut (vers -∞).
    public var floor: Int64 {
        let q = numerator / denominator
        return (numerator % denominator != 0 && numerator < 0) ? q - 1 : q
    }

    /// Entier le plus proche (demi vers +∞).
    public var rounded: Int64 { (self + Rational(1, 2)).floor }

    public var description: String { denominator == 1 ? "\(numerator)" : "\(numerator)/\(denominator)" }

    static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var x = a.magnitude
        var y = b.magnitude
        while y != 0 { (x, y) = (y, x % y) }
        return x == 0 ? 1 : Int64(x)
    }

    public static func + (a: Rational, b: Rational) -> Rational {
        let g = gcd(a.denominator, b.denominator)
        return Rational(a.numerator * (b.denominator / g) + b.numerator * (a.denominator / g),
                        a.denominator / g * b.denominator)
    }

    public static prefix func - (a: Rational) -> Rational { Rational(-a.numerator, a.denominator) }
    public static func - (a: Rational, b: Rational) -> Rational { a + (-b) }

    public static func * (a: Rational, b: Rational) -> Rational {
        let g1 = gcd(a.numerator, b.denominator)
        let g2 = gcd(b.numerator, a.denominator)
        return Rational((a.numerator / g1) * (b.numerator / g2), (a.denominator / g2) * (b.denominator / g1))
    }

    public static func / (a: Rational, b: Rational) -> Rational {
        precondition(b.numerator != 0, "division par zéro")
        return a * Rational(b.denominator, b.numerator)
    }

    public static func < (a: Rational, b: Rational) -> Bool {
        // Produits en double largeur : pas de dépassement possible.
        let left = a.numerator.multipliedFullWidth(by: b.denominator)
        let right = b.numerator.multipliedFullWidth(by: a.denominator)
        return left.high != right.high ? left.high < right.high : left.low < right.low
    }
}

extension Rational: Codable {
    /// Encodé sous forme de chaîne « num/den » : lisible et sans perte de précision.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        let parts = text.split(separator: "/")
        guard (1...2).contains(parts.count),
              let n = Int64(parts[0]),
              let d = parts.count == 2 ? Int64(parts[1]) : 1,
              d != 0
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Rationnel invalide : \(text)")
        }
        self.init(n, d)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
