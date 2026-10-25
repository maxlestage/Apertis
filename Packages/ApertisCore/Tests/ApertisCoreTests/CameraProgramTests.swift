import XCTest
@testable import ApertisCore

final class CameraProgramTests: XCTestCase {
    func testProgramsFollowTheLens() {
        XCTAssertEqual(ExposureProgram.available(variableAperture: true, customExposure: true).map(\.letter), ["P", "A", "S", "M"])
        XCTAssertEqual(ExposureProgram.available(variableAperture: false, customExposure: true).map(\.letter), ["P", "S", "M"])
        XCTAssertEqual(ExposureProgram.available(variableAperture: false, customExposure: false), [.program])
        XCTAssertEqual(ExposureProgram.available(variableAperture: false, customExposure: true, priorityModes: false), [.program, .manual])
    }

    func testRequestsLeaveTheRightParametersToTheCamera() {
        func make(_ p: ExposureProgram, variable: Bool = true, isoAuto: Bool = false) -> ExposureRequest {
            .make(p, aperture: 2.8, duration: 1.0 / 250, iso: 400, isoAuto: isoAuto, variableAperture: variable)
        }
        XCTAssertTrue(make(.program).isFullyAutomatic)
        XCTAssertEqual(make(.aperturePriority), ExposureRequest(aperture: 2.8))
        XCTAssertEqual(make(.shutterPriority), ExposureRequest(duration: 1.0 / 250, iso: 400))
        XCTAssertEqual(make(.shutterPriority, isoAuto: true), ExposureRequest(duration: 1.0 / 250))
        XCTAssertEqual(make(.manual), ExposureRequest(aperture: 2.8, duration: 1.0 / 250, iso: 400))
        // Sans diaphragme variable, l'ouverture n'est jamais imposée.
        XCTAssertEqual(make(.manual, variable: false), ExposureRequest(duration: 1.0 / 250, iso: 400))
        XCTAssertTrue(make(.aperturePriority, variable: false).isFullyAutomatic)
    }

    func testRequestIsClampedToTheLens() {
        let r = ExposureRequest(aperture: 8, duration: 30, iso: 10).clamped(aperture: 1.48...4, duration: (1.0 / 8000)...1, iso: 25...6400)
        XCTAssertEqual(r, ExposureRequest(aperture: 4, duration: 1, iso: 25))
    }

    func testIPhone18ProFocalStops() {
        // Objectifs de l'iPhone 18 Pro (fiche technique Apple) : 13, 24 et 100 mm, tous en 48 Mpx.
        let lenses = [
            LensDescription(kind: .telephoto, focalLength: 100, maxMegapixels: 48, maxZoom: 10),
            LensDescription(kind: .ultraWide, focalLength: 13, maxMegapixels: 48, maxZoom: 10),
            LensDescription(kind: .wide, focalLength: 24, maxMegapixels: 48, maxZoom: 10),
        ]
        let stops = FocalStops.make(lenses)
        XCTAssertEqual(stops.map(\.focalLength), [13, 24, 48, 100, 200])
        XCTAssertEqual(stops.map { $0.magnification(mainFocalLength: 24) }, ["0,5×", "1×", "2×", "4×", "8×"])
        XCTAssertEqual(stops.filter(\.isOpticalQualityCrop).map(\.lens), [.wide, .telephoto])
        XCTAssertEqual(stops.last?.zoom, 2)
    }

    func testTwelveMegapixelTelephotoHasNoCrop() {
        let lenses = [
            LensDescription(kind: .wide, focalLength: 26, maxMegapixels: 48, maxZoom: 10),
            LensDescription(kind: .telephoto, focalLength: 52, maxMegapixels: 12, maxZoom: 10),
        ]
        // Le 2× du grand-angle ferait doublon avec le téléobjectif 52 mm.
        XCTAssertEqual(FocalStops.make(lenses).map(\.focalLength), [26, 52])
    }

    func testResolutionsAndFormatting() {
        let sizes = [PhotoResolution(width: 8064, height: 6048), PhotoResolution(width: 4032, height: 3024),
                     PhotoResolution(width: 5712, height: 4284), PhotoResolution(width: 4032, height: 3024)]
        XCTAssertEqual(PhotoResolution.options(sizes).map(\.label), ["12 Mpx", "24 Mpx", "49 Mpx"])
        XCTAssertEqual(CameraFormat.aperture(1.48), "ƒ/1.48")
        XCTAssertEqual(CameraFormat.aperture(4), "ƒ/4")
        XCTAssertEqual(CameraFormat.aperture(2.8), "ƒ/2.8")
        XCTAssertEqual(CameraFormat.shutter(1.0 / 250), "1/250")
        XCTAssertEqual(CameraFormat.shutter(0.5), "0,5 s")
        XCTAssertEqual(CameraFormat.shutter(2), "2 s")
        XCTAssertEqual(CameraFormat.exposureValue(aperture: 1, duration: 1, iso: 100), 0, accuracy: 1e-9)
    }
}
