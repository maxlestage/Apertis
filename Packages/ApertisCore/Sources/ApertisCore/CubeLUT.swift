import Foundation

public enum CubeLUTError: Error, Equatable, LocalizedError {
    case missingSize
    case unsupported(String)
    case invalidSize(Int)
    case invalidLine(Int)
    case wrongEntryCount(expected: Int, found: Int)

    public var errorDescription: String? {
        switch self {
        case .missingSize: return "LUT_3D_SIZE absent du fichier."
        case .unsupported(let what): return "Fonction non prise en charge : \(what)."
        case .invalidSize(let n): return "Taille de LUT invalide : \(n)."
        case .invalidLine(let line): return "Ligne \(line) illisible."
        case .wrongEntryCount(let expected, let found):
            return "La LUT contient \(found) entrées au lieu de \(expected)."
        }
    }
}

/// LUT 3D au format Adobe/Resolve .cube, interpolée de façon trilinéaire.
public struct CubeLUT: Equatable, Sendable {
    public let title: String
    public let size: Int
    public let domainMin: RGB
    public let domainMax: RGB
    /// Entrées RVB, le rouge varie le plus vite.
    public let values: [Float]

    public init(title: String = "", size: Int, domainMin: RGB = .zero, domainMax: RGB = .one, values: [Float]) throws {
        guard (2...256).contains(size) else { throw CubeLUTError.invalidSize(size) }
        guard values.count == size * size * size * 3 else {
            throw CubeLUTError.wrongEntryCount(expected: size * size * size, found: values.count / 3)
        }
        self.title = title
        self.size = size
        self.domainMin = domainMin
        self.domainMax = domainMax
        self.values = values
    }

    public static func identity(size: Int) -> CubeLUT {
        var values: [Float] = []
        values.reserveCapacity(size * size * size * 3)
        let scale = Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    values += [Float(r) / scale, Float(g) / scale, Float(b) / scale]
                }
            }
        }
        return try! CubeLUT(title: "Identité", size: size, values: values)
    }

    public init(contentsOf url: URL) throws {
        try self.init(parsing: try String(contentsOf: url, encoding: .utf8))
    }

    public init(parsing text: String) throws {
        var title = ""
        var size: Int?
        var domainMin = RGB.zero
        var domainMax = RGB.one
        var values: [Float] = []

        func floats(_ parts: [Substring], line: Int) throws -> [Float] {
            // Float(String) est indépendant de la locale (point décimal).
            try parts.map { part in
                guard let v = Float(part), v.isFinite else { throw CubeLUTError.invalidLine(line) }
                return v
            }
        }

        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let lineNumber = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            switch parts[0] {
            case "TITLE":
                title = line.dropFirst("TITLE".count).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "LUT_3D_SIZE":
                guard parts.count == 2, let n = Int(parts[1]) else { throw CubeLUTError.invalidLine(lineNumber) }
                guard (2...256).contains(n) else { throw CubeLUTError.invalidSize(n) }
                size = n
                values.reserveCapacity(n * n * n * 3)
            case "LUT_1D_SIZE":
                throw CubeLUTError.unsupported("LUT 1D")
            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard parts.count == 4 else { throw CubeLUTError.invalidLine(lineNumber) }
                let v = try floats(Array(parts[1...3]), line: lineNumber)
                if parts[0] == "DOMAIN_MIN" { domainMin = RGB(v[0], v[1], v[2]) } else { domainMax = RGB(v[0], v[1], v[2]) }
            case "LUT_3D_INPUT_RANGE":
                guard parts.count == 3 else { throw CubeLUTError.invalidLine(lineNumber) }
                let v = try floats(Array(parts[1...2]), line: lineNumber)
                domainMin = RGB(repeating: v[0])
                domainMax = RGB(repeating: v[1])
            default:
                guard parts.count == 3 else { throw CubeLUTError.invalidLine(lineNumber) }
                values += try floats(parts, line: lineNumber)
            }
        }
        guard let size else { throw CubeLUTError.missingSize }
        try self.init(title: title, size: size, domainMin: domainMin, domainMax: domainMax, values: values)
    }

    /// Applique la LUT (interpolation trilinéaire). Les entrées hors domaine sont bornées.
    public func apply(_ c: RGB) -> RGB {
        let range = domainMax - domainMin
        var p = (c - domainMin) / range
        p = simd_clamp01(p) * Float(size - 1)
        let i0 = SIMD3<Int>(Int(p.x), Int(p.y), Int(p.z))
        let i1 = SIMD3<Int>(min(i0.x + 1, size - 1), min(i0.y + 1, size - 1), min(i0.z + 1, size - 1))
        let f = p - RGB(Float(i0.x), Float(i0.y), Float(i0.z))

        func at(_ r: Int, _ g: Int, _ b: Int) -> RGB {
            let i = (r + g * size + b * size * size) * 3
            return RGB(values[i], values[i + 1], values[i + 2])
        }
        let c00 = at(i0.x, i0.y, i0.z) * (1 - f.x) + at(i1.x, i0.y, i0.z) * f.x
        let c10 = at(i0.x, i1.y, i0.z) * (1 - f.x) + at(i1.x, i1.y, i0.z) * f.x
        let c01 = at(i0.x, i0.y, i1.z) * (1 - f.x) + at(i1.x, i0.y, i1.z) * f.x
        let c11 = at(i0.x, i1.y, i1.z) * (1 - f.x) + at(i1.x, i1.y, i1.z) * f.x
        let c0 = c00 * (1 - f.y) + c10 * f.y
        let c1 = c01 * (1 - f.y) + c11 * f.y
        return c0 * (1 - f.z) + c1 * f.z
    }
}
