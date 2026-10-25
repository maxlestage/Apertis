import CoreImage
import XCTest
import ApertisCore
@testable import Apertis

/// Outils de l'appareil photo, vérifiés sur le simulateur (noyau Metal réel).
final class CameraToolsTests: XCTestCase {
    private func flat(_ v: CGFloat, size: CGFloat = 64) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v)).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    func testZebrasStripeOnlyBrightAreas() throws {
        var settings = AssistSettings()
        settings.zebras = true
        let bright = try XCTUnwrap(CameraController.assistOverlay(for: flat(1), settings: settings))
        let alphaBright = stride(from: 3, to: pixels(bright.image).count, by: 4).map { pixels(bright.image)[$0] }
        XCTAssertGreaterThan(alphaBright.max() ?? 0, 150, "les zébras doivent apparaître sur les blancs")
        let dark = try XCTUnwrap(CameraController.assistOverlay(for: flat(0.4), settings: settings))
        XCTAssertEqual(stride(from: 3, to: pixels(dark.image).count, by: 4).map { pixels(dark.image)[$0] }.max(), 0)
    }

    func testFalseColorMarksMiddleGreyGreen() throws {
        var settings = AssistSettings()
        settings.falseColor = true
        let overlay = try XCTUnwrap(CameraController.assistOverlay(for: flat(0.44), settings: settings))
        let p = pixels(overlay.image)
        let center = (32 * 64 + 32) * 4
        XCTAssertGreaterThan(p[center + 1], p[center])
        XCTAssertGreaterThan(p[center + 1], p[center + 2])
    }

    func testPeakingFindsEdgesNotFlatAreas() throws {
        var settings = AssistSettings()
        settings.focusPeaking = true
        let flatOverlay = try XCTUnwrap(CameraController.assistOverlay(for: flat(0.5), settings: settings))
        XCTAssertEqual(stride(from: 3, to: pixels(flatOverlay.image).count, by: 4).map { pixels(flatOverlay.image)[$0] }.max(), 0)
        // Moitié noire, moitié blanche : un contour net au milieu.
        let split = flat(1).cropped(to: CGRect(x: 32, y: 0, width: 32, height: 64)).composited(over: flat(0))
        let overlay = try XCTUnwrap(CameraController.assistOverlay(for: split, settings: settings))
        XCTAssertGreaterThan(stride(from: 3, to: pixels(overlay.image).count, by: 4).map { pixels(overlay.image)[$0] }.max() ?? 0, 200)
    }

    func testLongExposureAveragesAndKeepsMaximum() throws {
        func buffer(_ value: UInt8) -> CVPixelBuffer {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            memset(CVPixelBufferGetBaseAddress(pb!), Int32(value), CVPixelBufferGetDataSize(pb!))
            CVPixelBufferUnlockBaseAddress(pb!, [])
            return pb!
        }
        let average = LongExposureStack(style: .motionBlur, frameCount: 2, cropAspect: 7, note: "test")
        XCTAssertFalse(average.add(buffer(0)))
        XCTAssertTrue(average.add(buffer(255)))
        let photo = try XCTUnwrap(average.render())
        XCTAssertNotNil(photo.processedData)
        XCTAssertEqual(photo.cropAspect, 7)
        let trails = LongExposureStack(style: .lightTrails, frameCount: 2, cropAspect: 0, note: "test")
        _ = trails.add(buffer(10))
        _ = trails.add(buffer(240))
        XCTAssertNotNil(trails.render()?.processedData)
    }
}
