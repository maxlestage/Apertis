import XCTest
@testable import ApertisCore

final class ColorGradeProcessorTests: XCTestCase {
    private let samples: [RGB] = [
        RGB(0, 0, 0), RGB(1, 1, 1), RGB(0.46, 0.46, 0.46), RGB(0.8, 0.2, 0.1), RGB(0.1, 0.5, 0.9), RGB(0.3, 0.7, 0.2),
    ]

    private func assertClose(_ a: RGB, _ b: RGB, _ accuracy: Float = 1e-5, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, file: file, line: line)
    }

    func testNeutralSettingsAreIdentity() {
        let processor = ColorGradeProcessor(settings: .neutral)
        XCTAssertTrue(processor.isIdentity)
        for c in samples { assertClose(processor.apply(c), c) }
    }

    func testNeutralCubeIsIdentityLattice() {
        let cube = ColorGradeProcessor(settings: .neutral).makeCube(dimension: 4)
        XCTAssertEqual(cube.count, 4 * 4 * 4 * 4)
        // Entrée (r=1, g=0, b=0) → index 1, rouge le plus rapide.
        XCTAssertEqual(cube[4], 1.0 / 3, accuracy: 1e-6)
        XCTAssertEqual(Array(cube[5..<8]), [0, 0, 1])
    }

    func testContrastKeepsMiddleGreyAndSpreadsTones() {
        var s = DevelopSettings()
        s.contrast = 50
        let p = ColorGradeProcessor(settings: s)
        let grey = RGB(repeating: ColorMath.middleGrey)
        assertClose(p.apply(grey), grey)
        XCTAssertLessThan(p.apply(RGB(repeating: 0.2)).x, 0.2)
        XCTAssertGreaterThan(p.apply(RGB(repeating: 0.7)).x, 0.7)
    }

    func testBlacksAndWhites() {
        var s = DevelopSettings()
        s.blacks = 100
        XCTAssertGreaterThan(ColorGradeProcessor(settings: s).apply(.zero).x, 0.05)
        s = DevelopSettings()
        s.whites = 100
        XCTAssertEqual(ColorGradeProcessor(settings: s).apply(RGB(repeating: 0.9)).x, 1, accuracy: 1e-5)
    }

    func testSaturationMinus100GivesGrey() {
        var s = DevelopSettings()
        s.saturation = -100
        let out = ColorGradeProcessor(settings: s).apply(RGB(0.8, 0.2, 0.1))
        XCTAssertEqual(out.x, out.y, accuracy: 1e-5)
        XCTAssertEqual(out.y, out.z, accuracy: 1e-5)
    }

    func testVibranceAffectsMutedColorsMore() {
        var s = DevelopSettings()
        s.vibrance = 100
        let p = ColorGradeProcessor(settings: s)
        func chroma(_ c: RGB) -> Float { max(c.x, c.y, c.z) - min(c.x, c.y, c.z) }
        let muted = RGB(0.5, 0.45, 0.4)
        let vivid = RGB(0.9, 0.1, 0.1)
        let mutedGain = chroma(p.apply(muted)) / chroma(muted)
        let vividGain = chroma(p.apply(vivid)) / chroma(vivid)
        XCTAssertGreaterThan(mutedGain, vividGain)
    }

    func testHSLLeavesGreysUntouchedAndTargetsHue() {
        var s = DevelopSettings()
        for range in HSLRange.allCases {
            s.hsl[range] = HSLBand(hue: 40, saturation: -60, luminance: 80)
        }
        let all = ColorGradeProcessor(settings: s)
        assertClose(all.apply(RGB(repeating: 0.5)), RGB(repeating: 0.5))

        s = DevelopSettings()
        s.hsl[.blue] = HSLBand(saturation: -100)
        let p = ColorGradeProcessor(settings: s)
        let blue = p.apply(RGB(0.1, 0.2, 0.9))
        XCTAssertEqual(blue.x, blue.z, accuracy: 0.05, "les bleus doivent être désaturés")
        assertClose(p.apply(RGB(0.9, 0.2, 0.1)), RGB(0.9, 0.2, 0.1), 1e-4)
    }

    func testCurveIsApplied() {
        var s = DevelopSettings()
        s.curves.master = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.75), CurvePoint(x: 1, y: 1)]
        XCTAssertEqual(ColorGradeProcessor(settings: s).apply(RGB(repeating: 0.5)).x, 0.75, accuracy: 2e-3)
    }

    func testGradingTintsShadowsMoreThanHighlights() {
        var s = DevelopSettings()
        s.grading.shadows = GradeWheel(hue: 220, saturation: 100)
        let p = ColorGradeProcessor(settings: s)
        let dark = p.apply(RGB(repeating: 0.1))
        let bright = p.apply(RGB(repeating: 0.9))
        XCTAssertGreaterThan(dark.z - dark.x, bright.z - bright.x)
    }

    func testLUTIntensity() throws {
        let invert = try CubeLUT(size: 2, values: (0..<8).flatMap { i -> [Float] in
            [1 - Float(i & 1), 1 - Float((i >> 1) & 1), 1 - Float((i >> 2) & 1)]
        })
        var s = DevelopSettings()
        s.lut = LUTReference(identifier: "invert", intensity: 50)
        assertClose(ColorGradeProcessor(settings: s, lut: invert).apply(RGB(0.2, 0.2, 0.2)), RGB(repeating: 0.5))
        s.lut?.intensity = 0
        XCTAssertTrue(ColorGradeProcessor(settings: s, lut: invert).isIdentity)
        // Sans LUT résolue, la référence est ignorée.
        s.lut?.intensity = 100
        XCTAssertTrue(ColorGradeProcessor(settings: s, lut: nil).isIdentity)
    }

    func testOutputAlwaysInRange() {
        var s = DevelopSettings()
        s.contrast = 100
        s.saturation = 100
        s.vibrance = 100
        s.highlights = 100
        s.grading.highlights = GradeWheel(hue: 30, saturation: 100, luminance: 100)
        let p = ColorGradeProcessor(settings: s)
        for c in samples + [RGB(2, -1, 0.5)] {
            let out = p.apply(c)
            for v in [out.x, out.y, out.z] { XCTAssertTrue((0...1).contains(v)) }
        }
    }

    func testClampedSanitizesValues() {
        var s = DevelopSettings()
        s.exposure = 42
        s.contrast = .nan
        s.grain = -5
        let c = s.clamped()
        XCTAssertEqual(c.exposure, 5)
        XCTAssertEqual(c.contrast, 0)
        XCTAssertEqual(c.grain, 0)
    }
}

final class EditHistoryTests: XCTestCase {
    func testCommitUndoRedo() {
        var history = EditHistory()
        var s = DevelopSettings()
        s.exposure = 1
        history.commit(s, label: "Exposition")
        s.contrast = 20
        history.commit(s, label: "Contraste")
        XCTAssertEqual(history.entries.count, 3)
        XCTAssertEqual(history.undo().contrast, 0)
        XCTAssertEqual(history.current.exposure, 1)
        XCTAssertEqual(history.redo().contrast, 20)
        XCTAssertFalse(history.canRedo)
    }

    func testCommitAfterUndoDropsRedoBranch() {
        var history = EditHistory()
        var s = DevelopSettings()
        s.exposure = 1
        history.commit(s, label: "A")
        history.undo()
        s.exposure = -1
        history.commit(s, label: "B")
        XCTAssertEqual(history.entries.map(\.label), ["Original", "B"])
        XCTAssertFalse(history.canRedo)
    }

    func testIdenticalCommitIsIgnored() {
        var history = EditHistory()
        history.commit(.neutral, label: "Rien")
        XCTAssertEqual(history.entries.count, 1)
    }

    func testHistoryIsBoundedAndKeepsOriginal() {
        var history = EditHistory()
        for i in 1...(EditHistory.maximumEntries + 20) {
            var s = DevelopSettings()
            s.exposure = Double(i) / 1000
            history.commit(s, label: "\(i)")
        }
        XCTAssertEqual(history.entries.count, EditHistory.maximumEntries)
        XCTAssertEqual(history.entries.first?.label, "Original")
        XCTAssertEqual(history.current.exposure, Double(EditHistory.maximumEntries + 20) / 1000)
    }
}
