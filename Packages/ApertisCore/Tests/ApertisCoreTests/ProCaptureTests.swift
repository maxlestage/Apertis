import XCTest
@testable import ApertisCore

final class ProCaptureTests: XCTestCase {
    func testBracketingIsCenteredAndLimitedByTheCamera() {
        XCTAssertEqual(Bracketing(count: 3, step: 1).biases(maxCount: 9, range: -8...8), [-1, 0, 1])
        XCTAssertEqual(Bracketing(count: 5, step: 2).biases(maxCount: 9, range: -3...3), [-3, -2, 0, 2, 3])
        // L'appareil n'accepte que 4 vues : on garde 3 vues centrées.
        XCTAssertEqual(Bracketing(count: 7, step: 1).biases(maxCount: 4, range: -8...8), [-1, 0, 1])
        XCTAssertEqual(Bracketing(count: 3, step: 1).biases(maxCount: 0, range: -8...8), [0])
        XCTAssertEqual(Bracketing(count: 5, step: 2.0 / 3).label, "5 vues · ±⅔ IL")
    }

    func testLongExposure() {
        let pose = LongExposure(style: .motionBlur, duration: 2)
        XCTAssertEqual(pose.frameCount(frameRate: 30), 60)
        XCTAssertEqual(LongExposure(duration: 0.01).frameCount(frameRate: 30), 2)
        XCTAssertEqual(pose.equivalentNDStops(frameDuration: 1.0 / 32), 6, accuracy: 1e-9)
    }

    func testIntervalometer() {
        XCTAssertEqual(Intervalometer(interval: 5, count: 100).totalDuration, 495)
        XCTAssertNil(Intervalometer(interval: 5, count: 0).totalDuration)
        XCTAssertEqual(Intervalometer(interval: 5, count: 250).playbackDuration(), 10)
    }

    func testGrayCardNeutralizesTheMeasuredCast() throws {
        // Une charte grise vue trop chaude (rouge fort, bleu faible).
        let current = WhiteBalanceGains(red: 2, green: 1, blue: 1.5)
        let gains = try XCTUnwrap(WhiteBalanceGains.neutralizing((r: 0.6, g: 0.4, b: 0.2), current: current, maxGain: 4))
        // Après correction, le gris mesuré doit devenir neutre : r·(g'/g) = g = b·(b'/b).
        let r = 0.6 * gains.red / current.red, g = 0.4 * gains.green / current.green, b = 0.2 * gains.blue / current.blue
        XCTAssertEqual(r / g, 1, accuracy: 1e-5)
        XCTAssertEqual(b / g, 1, accuracy: 1e-5)
        XCTAssertEqual(min(gains.red, gains.green, gains.blue), 1, accuracy: 1e-6)
        XCTAssertNil(WhiteBalanceGains.neutralizing((r: 0, g: 0.4, b: 0.2), current: current, maxGain: 4))
        let clamped = try XCTUnwrap(WhiteBalanceGains.neutralizing((r: 0.01, g: 0.5, b: 0.5), current: current, maxGain: 4))
        XCTAssertEqual(clamped.red, 4)
    }

    func testMeterReadsInThirds() {
        XCTAssertEqual(ExposureMeter.needle(offset: 0.4), 1.0 / 3, accuracy: 1e-6)
        XCTAssertEqual(ExposureMeter.needle(offset: -7), -3)
        XCTAssertEqual(ExposureMeter.label(offset: 1.3), "+1⅓")
        XCTAssertEqual(ExposureMeter.label(offset: -0.7), "−⅔")
        XCTAssertEqual(ExposureMeter.label(offset: 0.05), "0")
    }

    func testFrameGuidesAreCinemaFormatsOfTheSharedEngine() {
        let labels = FrameGuide.options.dropFirst().map { CropSettings.aspects[$0].label }
        XCTAssertEqual(Array(labels.prefix(3)), ["2,39:1", "1,85:1", "65:24"])
        let scope = FrameGuide.rect(aspect: 7, width: 4032, height: 3024)
        XCTAssertEqual(scope.width, 4032)
        XCTAssertEqual(scope.height, 4032 / 2.39, accuracy: 1e-6)
        XCTAssertEqual(scope.y, (3024 - 4032 / 2.39) / 2, accuracy: 1e-6)
        let none = FrameGuide.rect(aspect: 0, width: 400, height: 300)
        XCTAssertEqual(none.width, 400)
    }

    func testPresetSummary() {
        let preset = CameraPreset(slot: 1, name: "Rue", program: .manual, aperture: 2.8, shutter: 1.0 / 250, iso: 200,
                                  isoAuto: false, exposureBias: 0, manualWhiteBalance: true, kelvin: 5600, tint: 0,
                                  rawMode: "RAW", megapixels: 48, focalLength: 48, drive: .single, frameGuide: 0,
                                  minimalProcessing: true)
        XCTAssertEqual(preset.badge, "C1")
        XCTAssertEqual(preset.summary, "M · ƒ/2.8 · 1/250 · ISO 200 · 5600 K · RAW")
        let data = try? JSONEncoder().encode(preset)
        XCTAssertEqual(data.flatMap { try? JSONDecoder().decode(CameraPreset.self, from: $0) }, preset)
    }
}
