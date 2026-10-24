import Foundation

/// Recette : les réglages d'une photo en JSON plat, au format du laboratoire du site
/// (`{"format":"apertis-recette","version":1,"exposure":0.5,…}`). Une recette exportée
/// par l'app s'ouvre dans le laboratoire en ligne, et inversement.
///
/// Les réglages propres à l'app (réduction du bruit, luminosité des roues d'étalonnage,
/// courbes à points) s'ajoutent sous des clés que le site ignore.
public enum Recipe {
    public static let format = "apertis-recette"
    public static let version = 1

    /// Les clés du site, dans l'ordre d'une recette.
    public static let siteKeys: [String] = {
        var keys = ["exposure", "contrast", "highlights", "shadows", "whites", "blacks", "temperature", "tint",
                    "vibrance", "saturation"]
        keys += (0..<4).map { "curve\($0)" }
        for prefix in ["hsl_h", "hsl_s", "hsl_l"] { keys += (0..<8).map { "\(prefix)\($0)" } }
        for prefix in ["grade_h", "grade_s"] { keys += (0..<3).map { "\(prefix)\($0)" } }
        keys += ["fade", "grain", "grain_size", "vignette", "sharpen", "straighten", "rotate", "flip", "aspect"]
        return keys
    }()

    /// Clés propres à l'app.
    static let appKeys: [String] = ["noise_reduction"] + (0..<3).map { "grade_l\($0)" }

    private static let channels: [(name: String, path: WritableKeyPath<CurveSet, [CurvePoint]>)] = [
        ("m", \.master), ("r", \.red), ("g", \.green), ("b", \.blue),
    ]

    private static let wheels: [WritableKeyPath<ColorGrading, GradeWheel>] = [\.shadows, \.midtones, \.highlights]

    /// Valeur d'un réglage par sa clé de recette.
    public static func value(_ key: String, in s: DevelopSettings) -> Double? {
        switch key {
        case "exposure": return s.exposure
        case "contrast": return s.contrast
        case "highlights": return s.highlights
        case "shadows": return s.shadows
        case "whites": return s.whites
        case "blacks": return s.blacks
        case "temperature": return s.temperature
        case "tint": return s.tint
        case "vibrance": return s.vibrance
        case "saturation": return s.saturation
        case "fade": return s.fade
        case "grain": return s.grain
        case "grain_size": return s.grainSize
        case "vignette": return s.vignette
        case "sharpen": return s.sharpness
        case "straighten": return s.crop.angle
        case "rotate": return Double(s.crop.rotation)
        case "flip": return s.crop.flip ? 1 : 0
        case "aspect": return Double(s.crop.aspect)
        case "noise_reduction": return s.noiseReduction
        default:
            if let i = index(key, "curve", 4) { return s.parametricCurve[i] }
            if let i = index(key, "hsl_h", 8) { return s.hsl.bands[i].hue }
            if let i = index(key, "hsl_s", 8) { return s.hsl.bands[i].saturation }
            if let i = index(key, "hsl_l", 8) { return s.hsl.bands[i].luminance }
            if let i = index(key, "grade_h", 3) { return s.grading[keyPath: wheels[i]].hue }
            if let i = index(key, "grade_s", 3) { return s.grading[keyPath: wheels[i]].saturation }
            if let i = index(key, "grade_l", 3) { return s.grading[keyPath: wheels[i]].luminance }
            return nil
        }
    }

    /// Modifie un réglage par sa clé de recette. Renvoie `false` si la clé est inconnue.
    @discardableResult
    public static func set(_ key: String, _ v: Double, in s: inout DevelopSettings) -> Bool {
        guard v.isFinite else { return false }
        switch key {
        case "exposure": s.exposure = v
        case "contrast": s.contrast = v
        case "highlights": s.highlights = v
        case "shadows": s.shadows = v
        case "whites": s.whites = v
        case "blacks": s.blacks = v
        case "temperature": s.temperature = v
        case "tint": s.tint = v
        case "vibrance": s.vibrance = v
        case "saturation": s.saturation = v
        case "fade": s.fade = v
        case "grain": s.grain = v
        case "grain_size": s.grainSize = v
        case "vignette": s.vignette = v
        case "sharpen": s.sharpness = v
        case "straighten": s.crop.angle = v
        case "rotate": s.crop.rotation = Int(v.rounded())
        case "flip": s.crop.flip = v >= 0.5
        case "aspect": s.crop.aspect = Int(max(v.rounded(), 0))
        case "noise_reduction": s.noiseReduction = v
        default:
            if let i = index(key, "curve", 4) { s.parametricCurve[i] = v; return true }
            var band: HSLBand?
            var bandIndex = 0
            if let i = index(key, "hsl_h", 8) { bandIndex = i; band = s.hsl.bands[i]; band?.hue = v }
            else if let i = index(key, "hsl_s", 8) { bandIndex = i; band = s.hsl.bands[i]; band?.saturation = v }
            else if let i = index(key, "hsl_l", 8) { bandIndex = i; band = s.hsl.bands[i]; band?.luminance = v }
            if let band {
                s.hsl[HSLRange(rawValue: bandIndex)!] = band
                return true
            }
            if let i = index(key, "grade_h", 3) { s.grading[keyPath: wheels[i]].hue = v; return true }
            if let i = index(key, "grade_s", 3) { s.grading[keyPath: wheels[i]].saturation = v; return true }
            if let i = index(key, "grade_l", 3) { s.grading[keyPath: wheels[i]].luminance = v; return true }
            return false
        }
        return true
    }

    /// La recette d'un réglage complet.
    public static func encode(_ settings: DevelopSettings) -> String {
        let s = settings.clamped()
        var fields = ["\"format\":\"\(format)\"", "\"version\":\(version)"]
        for key in siteKeys + appKeys {
            fields.append("\"\(key)\":\(number(value(key, in: s) ?? 0))")
        }
        // Courbes à points : une paire de clés par point (`points_m0_x`, `points_m0_y`…).
        for channel in channels where !ToneCurve(points: s.curves[keyPath: channel.path]).isIdentity {
            for (i, p) in s.curves[keyPath: channel.path].enumerated() {
                fields.append("\"points_\(channel.name)\(i)_x\":\(number(p.x))")
                fields.append("\"points_\(channel.name)\(i)_y\":\(number(p.y))")
            }
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// Lit une recette ; les clés inconnues sont ignorées, les absentes restent neutres.
    /// Renvoie nil si le texte n'est pas une recette.
    public static func decode(_ text: String) -> DevelopSettings? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var s = DevelopSettings()
        var known = 0
        var points: [String: [Int: CurvePoint]] = [:]
        for (key, raw) in object {
            let v: Double
            if let n = raw as? NSNumber, !(raw is String) { v = n.doubleValue }
            else if let b = raw as? Bool { v = b ? 1 : 0 }
            else { continue }
            if key.hasPrefix("points_"), let point = pointKey(key) {
                var p = points[point.channel, default: [:]][point.index] ?? CurvePoint(x: 0, y: 0)
                if point.isX { p.x = v } else { p.y = v }
                points[point.channel, default: [:]][point.index] = p
                known += 1
            } else if set(key, v, in: &s) {
                known += 1
            }
        }
        for channel in channels {
            if let list = points[channel.name], !list.isEmpty {
                s.curves[keyPath: channel.path] = list.keys.sorted().compactMap { list[$0] }
            }
        }
        return known > 0 ? s.clamped() : nil
    }

    private static func pointKey(_ key: String) -> (channel: String, index: Int, isX: Bool)? {
        let body = key.dropFirst("points_".count)
        guard let channel = body.first.map(String.init), channels.contains(where: { $0.name == channel }) else { return nil }
        let rest = body.dropFirst()
        let isX: Bool
        if rest.hasSuffix("_x") { isX = true } else if rest.hasSuffix("_y") { isX = false } else { return nil }
        guard let index = Int(rest.dropLast(2)), (0..<64).contains(index) else { return nil }
        return (channel, index, isX)
    }

    private static func index(_ key: String, _ prefix: String, _ count: Int) -> Int? {
        guard key.hasPrefix(prefix), let i = Int(key.dropFirst(prefix.count)), (0..<count).contains(i) else { return nil }
        return i
    }

    /// Même écriture que le site : trois décimales au plus, zéros finaux retirés.
    static func number(_ v: Double) -> String {
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s.isEmpty || s == "-" || s == "-0" ? "0" : s
    }
}
