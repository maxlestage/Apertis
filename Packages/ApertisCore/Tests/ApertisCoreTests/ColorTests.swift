import XCTest
@testable import ApertisCore

final class ColorMathTests: XCTestCase {
    func testSrgbRoundTrip() {
        for i in 0...100 {
            let v = Float(i) / 100
            XCTAssertEqual(ColorMath.srgbToLinear(ColorMath.linearToSrgb(v)), v, accuracy: 1e-5)
        }
        XCTAssertEqual(ColorMath.linearToSrgb(0.18), ColorMath.middleGrey, accuracy: 1e-3)
    }

    func testHslRoundTrip() {
        let samples: [RGB] = [RGB(1, 0, 0), RGB(0.2, 0.6, 0.3), RGB(0.9, 0.85, 0.1), RGB(0.4, 0.4, 0.4), RGB(0.1, 0.2, 0.9)]
        for c in samples {
            let (h, s, l) = ColorMath.rgbToHsl(c)
            let back = ColorMath.hslToRgb(h: h, s: s, l: l)
            XCTAssertEqual(back.x, c.x, accuracy: 1e-5)
            XCTAssertEqual(back.y, c.y, accuracy: 1e-5)
            XCTAssertEqual(back.z, c.z, accuracy: 1e-5)
        }
    }

    func testWhiteBalanceIsNeutralAtZeroAndKeepsLuminance() {
        XCTAssertEqual(ColorMath.whiteBalanceGains(temperature: 0, tint: 0), RGB(1, 1, 1))
        let warm = ColorMath.whiteBalanceGains(temperature: 60, tint: 0)
        XCTAssertGreaterThan(warm.x, warm.z)
        XCTAssertEqual(ColorMath.luminance(warm), 1, accuracy: 1e-5)
        let magenta = ColorMath.whiteBalanceGains(temperature: 0, tint: 50)
        XCTAssertLessThan(magenta.y, magenta.x)
    }
}

final class ToneCurveTests: XCTestCase {
    func testEmptyAndDiagonalCurvesAreIdentity() {
        XCTAssertTrue(ToneCurve(points: []).isIdentity)
        XCTAssertTrue(ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]).isIdentity)
        XCTAssertFalse(ToneCurve(points: [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 1)]).isIdentity)
    }

    func testPassesThroughControlPoints() {
        let points = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.15), CurvePoint(x: 0.75, y: 0.85), CurvePoint(x: 1, y: 1)]
        let curve = ToneCurve(points: points)
        for p in points {
            XCTAssertEqual(Double(curve.evaluate(Float(p.x))), p.y, accuracy: 2e-3)
        }
    }

    func testMonotoneDataGivesMonotoneCurve() {
        let curve = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.1, y: 0.5), CurvePoint(x: 0.2, y: 0.55),
                                       CurvePoint(x: 1, y: 1)])
        var previous: Float = -1
        for i in 0...1000 {
            let y = curve.evaluate(Float(i) / 1000)
            XCTAssertGreaterThanOrEqual(y, previous - 1e-6)
            XCTAssertLessThanOrEqual(y, 1)
            previous = y
        }
    }

    func testUnsortedAndOutOfRangePointsAreNormalized() {
        let curve = ToneCurve(points: [CurvePoint(x: 1.5, y: 2), CurvePoint(x: -1, y: 0), CurvePoint(x: 0.5, y: 0.7)])
        XCTAssertEqual(curve.evaluate(0), 0, accuracy: 1e-6)
        XCTAssertEqual(curve.evaluate(1), 1, accuracy: 1e-6)
        XCTAssertEqual(curve.evaluate(0.5), 0.7, accuracy: 2e-3)
    }
}

final class CubeLUTTests: XCTestCase {
    private func cubeText(size: Int, transform: (Float, Float, Float) -> (Float, Float, Float)) -> String {
        var lines = ["# commentaire", "TITLE \"Test\"", "LUT_3D_SIZE \(size)"]
        let s = Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let (x, y, z) = transform(Float(r) / s, Float(g) / s, Float(b) / s)
                    lines.append("\(x) \(y) \(z)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    func testIdentityCubeLeavesColorsUnchanged() throws {
        let lut = try CubeLUT(parsing: cubeText(size: 5) { ($0, $1, $2) })
        XCTAssertEqual(lut.title, "Test")
        XCTAssertEqual(lut.size, 5)
        let c = lut.apply(RGB(0.33, 0.61, 0.07))
        XCTAssertEqual(c.x, 0.33, accuracy: 1e-5)
        XCTAssertEqual(c.y, 0.61, accuracy: 1e-5)
        XCTAssertEqual(c.z, 0.07, accuracy: 1e-5)
    }

    func testRedFastestOrdering() throws {
        let lut = try CubeLUT(parsing: cubeText(size: 3) { r, g, b in (b, g, r) })
        let c = lut.apply(RGB(1, 0, 0))
        XCTAssertEqual(c, RGB(0, 0, 1))
    }

    func testErrors() {
        XCTAssertThrowsError(try CubeLUT(parsing: "0 0 0")) { XCTAssertEqual($0 as? CubeLUTError, .missingSize) }
        XCTAssertThrowsError(try CubeLUT(parsing: "LUT_3D_SIZE 2\n0 0 0")) {
            XCTAssertEqual($0 as? CubeLUTError, .wrongEntryCount(expected: 8, found: 1))
        }
        XCTAssertThrowsError(try CubeLUT(parsing: "LUT_1D_SIZE 16")) {
            XCTAssertEqual($0 as? CubeLUTError, .unsupported("LUT 1D"))
        }
        XCTAssertThrowsError(try CubeLUT(parsing: "LUT_3D_SIZE 2\n0,5 0 0")) {
            XCTAssertEqual($0 as? CubeLUTError, .invalidLine(2))
        }
    }

    func testDomain() throws {
        let text = "LUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 2 2 2\n" + (0..<8).map { i in
            "\(Float(i & 1)) \(Float((i >> 1) & 1)) \(Float((i >> 2) & 1))"
        }.joined(separator: "\n")
        let lut = try CubeLUT(parsing: text)
        XCTAssertEqual(lut.apply(RGB(1, 1, 1)).x, 0.5, accuracy: 1e-6)
    }
}
