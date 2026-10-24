import CoreImage
import XCTest
import ApertisCore
@testable import Apertis

/// Vérifie le rendu iOS réel (Core Image et noyau Metal) sur le simulateur.
final class RenderingTests: XCTestCase {
    private let renderer = GradeRenderer.shared

    /// Image unie en sRGB encodé.
    private func flat(_ value: CGFloat, width: CGFloat = 120, height: CGFloat = 80) -> CIImage {
        let color = CIColor(red: value, green: value, blue: value, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Pixels RGBA 8 bits sRGB, première ligne en haut.
    private func pixels(_ image: CIImage) -> (data: [UInt8], width: Int, height: Int) {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        renderer.context.render(image, toBitmap: &data, rowBytes: width * 4, bounds: image.extent, format: .RGBA8,
                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (data, width, height)
    }

    private func pixel(_ p: (data: [UInt8], width: Int, height: Int), _ x: Int, _ y: Int) -> [Float] {
        let i = (y * p.width + x) * 4
        return [Float(p.data[i]) / 255, Float(p.data[i + 1]) / 255, Float(p.data[i + 2]) / 255]
    }

    func testEffectsKernelIsLoaded() {
        XCTAssertTrue(renderer.hasEffectsKernel, "default.metallib ou apertisEffects introuvable")
    }

    func testNeutralSettingsKeepTheImage() {
        let out = pixels(renderer.apply(.neutral, to: flat(0.5), source: .developed))
        XCTAssertEqual(pixel(out, 10, 10)[1], 0.5, accuracy: 0.01)
    }

    func testColorStageMatchesTheSharedEngine() {
        for preset in BuiltInPresets.all {
            let out = pixels(renderer.apply(preset.settings.withoutEffects, to: flat(0.4), source: .developed, cubeDimension: 64))
            let expected = ColorGradeProcessor(settings: preset.settings).apply(RGB(repeating: 0.4))
            let got = pixel(out, 60, 40)
            XCTAssertEqual(got[0], expected.x, accuracy: 0.015, preset.name)
            XCTAssertEqual(got[1], expected.y, accuracy: 0.015, preset.name)
            XCTAssertEqual(got[2], expected.z, accuracy: 0.015, preset.name)
        }
    }

    func testVignetteDarkensCornersOnly() {
        var s = DevelopSettings()
        s.vignette = 100
        let out = pixels(renderer.apply(s, to: flat(0.6), source: .developed))
        XCTAssertEqual(pixel(out, 60, 40)[1], 0.6, accuracy: 0.02)
        XCTAssertLessThan(pixel(out, 0, 0)[1], 0.3)
    }

    func testGrainAddsNoise() {
        var s = DevelopSettings()
        s.grain = 100
        let out = pixels(renderer.apply(s, to: flat(0.45), source: .developed))
        let values = (0..<40).map { pixel(out, $0, 20)[1] }
        XCTAssertGreaterThan((values.max() ?? 0) - (values.min() ?? 0), 0.05)
    }

    func testClippingOverlayMarksBurntWhites() {
        let out = pixels(renderer.clippingOverlay(flat(1)))
        let p = pixel(out, 5, 5)
        XCTAssertGreaterThan(p[0], 0.9)
        XCTAssertLessThan(p[1], 0.3)
    }

    func testGeometryRotatesAndCrops() {
        var s = DevelopSettings()
        s.crop.rotation = 1
        XCTAssertEqual(renderer.apply(s, to: flat(0.5, width: 120, height: 80), source: .developed).extent.size,
                       CGSize(width: 80, height: 120))
        s.crop = CropSettings(aspect: 1)
        let square = renderer.apply(s, to: flat(0.5, width: 120, height: 80), source: .developed)
        XCTAssertEqual(square.extent, CGRect(x: 0, y: 0, width: 80, height: 80))
        // Le cadre redressé reste dans l'image : aucun pixel transparent ou noir aux bords.
        s.crop = CropSettings(angle: 12)
        let straightened = pixels(renderer.apply(s, to: flat(0.5), source: .developed))
        XCTAssertEqual(pixel(straightened, 0, 0)[1], 0.5, accuracy: 0.02)
    }

    func testRecipeFromTheSiteRendersLikeTheStyle() throws {
        let recipe = Recipe.encode(BuiltInPresets.cinema.settings)
        let decoded = try XCTUnwrap(Recipe.decode(recipe))
        XCTAssertEqual(decoded, BuiltInPresets.cinema.settings)
    }
}

private extension DevelopSettings {
    /// Sans vignette ni grain : seule l'étape couleur est comparée.
    var withoutEffects: DevelopSettings {
        var s = self
        s.vignette = 0
        s.grain = 0
        return s
    }
}
