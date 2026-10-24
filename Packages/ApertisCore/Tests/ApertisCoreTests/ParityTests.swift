import XCTest
@testable import ApertisCore

/// L'app et le laboratoire du site doivent rendre une recette de la même façon.
/// `Resources/parity.json` est produit par le moteur du site (`site/src/grade.rs`).
final class ParityTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Style: Decodable { let id: String; let name: String; let recipe: [String: Value] }
        struct Colors: Decodable { let recipe: [String: Value]; let outputs: [[Float]] }
        struct Frame: Decodable { let recipe: [String: Value]; let source: [Double]; let size: [Int]; let matrix: [Double] }
        let inputs: [[Float]]
        let presets: [Style]
        let colors: [Colors]
        let geometry: [Frame]
    }

    /// Valeur JSON d'une recette (nombre ou texte).
    private enum Value: Decodable {
        case number(Double), text(String)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Double.self) { self = .number(n) } else { self = .text(try c.decode(String.self)) }
        }
        var json: String {
            switch self {
            case .number(let n): return Recipe.number(n)
            case .text(let t): return "\"\(t)\""
            }
        }
    }

    private func load() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "parity", withExtension: "json", subdirectory: "Resources"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func settings(_ recipe: [String: Value]) throws -> DevelopSettings {
        let text = "{" + recipe.map { "\"\($0.key)\":\($0.value.json)" }.joined(separator: ",") + "}"
        return try XCTUnwrap(Recipe.decode(text), text)
    }

    func testColorsMatchTheSite() throws {
        let fixture = try load()
        var worst: Float = 0
        for case_ in fixture.colors {
            let processor = ColorGradeProcessor(settings: try settings(case_.recipe))
            for (input, expected) in zip(fixture.inputs, case_.outputs) {
                let out = processor.apply(RGB(input[0], input[1], input[2]))
                let diff = max(abs(out.x - expected[0]), abs(out.y - expected[1]), abs(out.z - expected[2]))
                worst = max(worst, diff)
                XCTAssertLessThan(diff, 5e-4, "\(case_.recipe.keys.sorted()) \(input) → \(out) au lieu de \(expected)")
            }
        }
        print("écart maximal avec le site : \(worst)")
    }

    func testStylesAreTheSiteStyles() throws {
        let fixture = try load()
        XCTAssertEqual(fixture.presets.map { "builtin.\($0.id)" }, BuiltInPresets.all.map(\.id))
        for style in fixture.presets {
            let preset = try XCTUnwrap(BuiltInPresets.preset(siteID: style.id))
            XCTAssertEqual(preset.name, style.name)
            XCTAssertEqual(preset.settings, try settings(style.recipe), style.id)
        }
    }

    func testGeometryMatchesTheSite() throws {
        for frame in try load().geometry {
            let s = try settings(frame.recipe)
            let g = FrameGeometry(crop: s.crop, sourceWidth: frame.source[0], sourceHeight: frame.source[1])
            XCTAssertEqual([g.width, g.height], frame.size)
            for (a, b) in zip(g.matrix, frame.matrix) { XCTAssertEqual(a, b, accuracy: 1e-5) }
        }
    }

    func testRecipeRoundTripKeepsAppOnlySettings() throws {
        var s = BuiltInPresets.portra.settings
        s.exposure = 0.75
        s.noiseReduction = 30
        s.grading.midtones.luminance = -12
        s.crop = CropSettings(aspect: 2, rotation: 3, flip: true, angle: -4.5)
        s.curves.master = [CurvePoint(x: 0, y: 0.05), CurvePoint(x: 0.5, y: 0.55), CurvePoint(x: 1, y: 1)]
        let text = Recipe.encode(s)
        XCTAssertTrue(text.hasPrefix("{\"format\":\"apertis-recette\",\"version\":1,\"exposure\":0.75,"))
        XCTAssertEqual(Recipe.decode(text), s)
        XCTAssertNil(Recipe.decode("{\"format\":\"autre\"}"))
        XCTAssertNil(Recipe.decode("pas du json"))
    }

    func testCoreImageTransformPlacesTheCropAtTheOrigin() {
        let crop = CropSettings(aspect: 1, rotation: 1, flip: false, angle: 0)
        let g = FrameGeometry(crop: crop, sourceWidth: 400, sourceHeight: 300)
        XCTAssertEqual([g.width, g.height], [300, 300])
        let t = g.sourceToOutput(sourceWidth: 400, sourceHeight: 300)
        // Le coin haut gauche de la sortie vient, après un quart de tour horaire, du bas gauche
        // de la partie cadrée de la source (x = 50 en pixels, y = 0 en Core Image).
        let p = t.apply(50, 0)
        XCTAssertEqual(p.x, 0, accuracy: 1e-6)
        XCTAssertEqual(p.y, 300, accuracy: 1e-6)
        let q = t.inverted.apply(150, 150)
        XCTAssertEqual(q.x, 200, accuracy: 1e-6)
        XCTAssertEqual(q.y, 150, accuracy: 1e-6)
    }
}
