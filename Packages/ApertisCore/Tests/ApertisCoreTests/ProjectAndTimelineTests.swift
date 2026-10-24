import XCTest
@testable import ApertisCore

final class RationalTests: XCTestCase {
    func testArithmeticIsExact() {
        let frame = Rational(1001, 30000)
        var t = Rational.zero
        for _ in 0..<30000 { t = t + frame }
        XCTAssertEqual(t, Rational(1001))
        XCTAssertEqual(Rational(2, 4), Rational(1, 2))
        XCTAssertEqual(Rational(1, -2), Rational(-1, 2))
        XCTAssertEqual(Rational(-3, 2).floor, -2)
        XCTAssertEqual(Rational(5, 2).rounded, 3)
        XCTAssertLessThan(Rational(1, 3), Rational(1, 2))
        XCTAssertLessThan(Rational(Int64.max / 2, 3), Rational(Int64.max / 2, 2))
    }

    func testCodableAsString() throws {
        let data = try JSONEncoder().encode([Rational(30000, 1001)])
        XCTAssertEqual(String(data: data, encoding: .utf8), "[\"30000\\/1001\"]")
        XCTAssertEqual(try JSONDecoder().decode([Rational].self, from: data), [Rational(30000, 1001)])
        XCTAssertThrowsError(try JSONDecoder().decode([Rational].self, from: Data("[\"1/0\"]".utf8)))
    }
}

final class TimelineTests: XCTestCase {
    private let ntsc = Rational(30000, 1001)

    func testAppendIsContiguousAndFrameAligned() throws {
        var timeline = Timeline(frameRate: ntsc)
        let a = try timeline.append(mediaID: "a", duration: Rational(2))
        let b = try timeline.append(mediaID: "b", duration: Rational(3))
        XCTAssertEqual(b.start, a.end)
        XCTAssertTrue(timeline.isFrameAligned(a.duration))
        XCTAssertEqual(timeline.duration, a.duration + b.duration)
    }

    func testRejectsMisalignedAndOverlappingClips() throws {
        var timeline = Timeline(frameRate: Rational(25))
        let track = timeline.mainVideoTrack.id
        try timeline.insert(Clip(mediaID: "a", trackID: track, start: .zero, duration: Rational(2)))
        XCTAssertThrowsError(try timeline.insert(Clip(mediaID: "b", trackID: track, start: Rational(1), duration: Rational(2)))) {
            guard case .overlap = $0 as? TimelineError else { return XCTFail("chevauchement attendu") }
        }
        XCTAssertThrowsError(try timeline.insert(Clip(mediaID: "c", trackID: track, start: Rational(2), duration: Rational(1, 30)))) {
            XCTAssertEqual($0 as? TimelineError, .notFrameAligned)
        }
        XCTAssertThrowsError(try timeline.insert(Clip(mediaID: "d", trackID: UUID(), start: .zero, duration: Rational(1)))) {
            XCTAssertEqual($0 as? TimelineError, .unknownTrack)
        }
        // Une autre piste accepte le même intervalle.
        let v2 = timeline.addTrack(kind: .video)
        XCTAssertNoThrow(try timeline.insert(Clip(mediaID: "e", trackID: v2.id, start: Rational(1), duration: Rational(1))))
    }

    func testSplitPreservesSourceMapping() throws {
        var timeline = Timeline(frameRate: Rational(24))
        let track = timeline.mainVideoTrack.id
        let clip = Clip(mediaID: "a", trackID: track, start: Rational(1), duration: Rational(4), sourceIn: Rational(10),
                        speed: Rational(2))
        try timeline.insert(clip)
        let secondID = try timeline.split(clip.id, at: Rational(3))
        let first = try XCTUnwrap(timeline.clip(clip.id))
        let second = try XCTUnwrap(timeline.clip(secondID))
        XCTAssertEqual(first.duration, Rational(2))
        XCTAssertEqual(second.start, Rational(3))
        XCTAssertEqual(second.duration, Rational(2))
        XCTAssertEqual(second.sourceIn, Rational(14))  // 10 + (3 - 1) × 2
        XCTAssertEqual(second.sourceTime(at: Rational(4)), clip.sourceTime(at: Rational(4)))
        XCTAssertThrowsError(try timeline.split(clip.id, at: Rational(1)))
        XCTAssertThrowsError(try timeline.split(secondID, at: Rational(7, 2 * 24 + 1)))
    }

    func testClipsAtFollowsTrackOrderAndMute() throws {
        var timeline = Timeline(frameRate: Rational(30))
        let v1 = timeline.mainVideoTrack.id
        let v2 = timeline.addTrack(kind: .video).id
        try timeline.insert(Clip(mediaID: "base", trackID: v1, start: .zero, duration: Rational(10)))
        try timeline.insert(Clip(mediaID: "titre", trackID: v2, start: Rational(2), duration: Rational(3)))
        XCTAssertEqual(timeline.clips(at: Rational(1), kind: .video).map(\.mediaID), ["base"])
        XCTAssertEqual(timeline.clips(at: Rational(3), kind: .video).map(\.mediaID), ["base", "titre"])
        XCTAssertEqual(timeline.clips(at: Rational(5), kind: .video).map(\.mediaID), ["base"])
        try timeline.setTrackMuted(v2, true)
        XCTAssertEqual(timeline.clips(at: Rational(3), kind: .video).map(\.mediaID), ["base"])
    }

    func testRippleDeleteAndCopyGrade() throws {
        var timeline = Timeline(frameRate: Rational(25))
        let a = try timeline.append(mediaID: "a", duration: Rational(2))
        let b = try timeline.append(mediaID: "b", duration: Rational(2))
        let c = try timeline.append(mediaID: "c", duration: Rational(2))
        var graded = a
        graded.grade.exposure = 0.7
        try timeline.update(graded)
        try timeline.copyGrade(from: a.id, to: [c.id])
        XCTAssertEqual(timeline.clip(c.id)?.grade.exposure, 0.7)
        timeline.rippleDelete(b.id)
        XCTAssertEqual(timeline.clip(c.id)?.start, Rational(2))
        XCTAssertEqual(timeline.duration, Rational(4))
    }

    func testDecodingValidatesClips() throws {
        var timeline = Timeline(frameRate: Rational(25))
        try timeline.append(mediaID: "a", duration: Rational(2))
        let data = try JSONEncoder().encode(timeline)
        XCTAssertEqual(try JSONDecoder().decode(Timeline.self, from: data), timeline)
        let corrupted = String(data: data, encoding: .utf8)!.replacingOccurrences(of: "\"duration\":\"2\"", with: "\"duration\":\"-1\"")
        XCTAssertNotEqual(corrupted, String(data: data, encoding: .utf8)!)
        XCTAssertThrowsError(try JSONDecoder().decode(Timeline.self, from: Data(corrupted.utf8)))
    }
}

final class ProjectTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("apertis-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sampleProject() -> PhotoProject {
        var project = PhotoProject(source: MediaReference(fileName: "IMG_0001.dng", originalFileName: "IMG_0001.DNG",
                                                          kind: .proRAW, byteSize: 4),
                                   date: Date(timeIntervalSince1970: 1_800_000_000))
        var s = DevelopSettings()
        s.exposure = 0.3
        s.curves.red = [CurvePoint(x: 0, y: 0.05), CurvePoint(x: 1, y: 0.95)]
        s.hsl[.orange] = HSLBand(hue: -10, saturation: 15, luminance: 5)
        s.grading.highlights = GradeWheel(hue: 45, saturation: 20)
        s.lut = LUTReference(identifier: "portra.cube", intensity: 70)
        project.history.commit(s, label: "Réglages")
        return project
    }

    func testRoundTrip() throws {
        let project = sampleProject()
        let decoded = try ProjectIO.decode(PhotoProject.self, from: ProjectIO.encode(project))
        // Les dates ISO 8601 sont à la seconde : on compare les réglages et l'historique.
        XCTAssertEqual(decoded.settings, project.settings)
        XCTAssertEqual(decoded.history.entries.map(\.label), project.history.entries.map(\.label))
        XCTAssertEqual(decoded.source, project.source)
    }

    func testOldProjectWithMissingKeysUsesDefaults() throws {
        let json = #"{"exposure": 1.5}"#
        let settings = try JSONDecoder().decode(DevelopSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.exposure, 1.5)
        XCTAssertEqual(settings.hsl, HSLAdjustments())
        XCTAssertNil(settings.lut)
    }

    func testRejectsNewerVersionAndWrongFormat() throws {
        var text = String(data: try ProjectIO.encode(sampleProject()), encoding: .utf8)!
        text = text.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 99")
        XCTAssertThrowsError(try ProjectIO.decode(PhotoProject.self, from: Data(text.utf8))) {
            XCTAssertEqual($0 as? ProjectError, .newerVersion(99))
        }
        let video = VideoProject(name: "Film", frameRate: Rational(24))
        XCTAssertThrowsError(try ProjectIO.decode(PhotoProject.self, from: ProjectIO.encode(video))) {
            XCTAssertEqual($0 as? ProjectError, .wrongFormat(VideoProject.formatIdentifier))
        }
    }

    func testSaveLoadAndSourceStatus() throws {
        let originals = directory.appendingPathComponent("Originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let project = sampleProject()
        XCTAssertEqual(project.source.status(in: originals), .missing)
        try Data([1, 2, 3, 4]).write(to: originals.appendingPathComponent("IMG_0001.dng"))
        XCTAssertEqual(project.source.status(in: originals), .available)
        try Data([1, 2]).write(to: originals.appendingPathComponent("IMG_0001.dng"))
        XCTAssertEqual(project.source.status(in: originals), .modified)

        let url = directory.appendingPathComponent("Projects/\(project.id).apertis")
        try ProjectIO.save(project, to: url)
        XCTAssertEqual(try ProjectIO.load(PhotoProject.self, from: url).settings, project.settings)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, [url.lastPathComponent])
    }

    func testVideoProjectReportsMissingMedia() throws {
        var project = VideoProject(name: "Film", frameRate: Rational(25))
        try project.timeline.append(mediaID: "clip1", duration: Rational(2))
        try project.timeline.append(mediaID: "clip2", duration: Rational(2))
        project.media["clip1"] = MediaReference(fileName: "clip1.mov", originalFileName: "clip1.mov", kind: .video, byteSize: 1)
        try Data([0]).write(to: directory.appendingPathComponent("clip1.mov"))
        XCTAssertEqual(project.unavailableMedia(in: directory), ["clip2"])
        let decoded = try ProjectIO.decode(VideoProject.self, from: ProjectIO.encode(project))
        XCTAssertEqual(decoded.timeline, project.timeline)
    }
}

final class CaptureCapabilitiesTests: XCTestCase {
    private let uhd = Resolution(width: 3840, height: 2160)
    private let hd = Resolution(width: 1920, height: 1080)

    private var capabilities: CaptureCapabilities {
        var modes: Set<VideoMode> = []
        for fps in [24, 25, 30, 60] {
            for profile in VideoColorProfile.allCases {
                modes.insert(VideoMode(lens: .wide, resolution: uhd, frameRate: fps, profile: profile))
            }
        }
        for fps in [30, 60, 120, 240] {
            modes.insert(VideoMode(lens: .wide, resolution: hd, frameRate: fps, profile: .sdr))
        }
        modes.insert(VideoMode(lens: .ultraWide, resolution: hd, frameRate: 30, profile: .sdr))
        return CaptureCapabilities(photo: PhotoCapabilities(bayerRAW: true, appleProRAW: true, lenses: [.wide, .ultraWide]),
                                   videoModes: modes, videoCodecs: [.hevc, .h264])
    }

    func testOptionsOnlyShowSupportedCombinations() {
        XCTAssertEqual(capabilities.options(\.frameRate, matching: VideoModeQuery(lens: .wide, resolution: uhd)), [24, 25, 30, 60])
        XCTAssertEqual(capabilities.options(\.frameRate, matching: VideoModeQuery(lens: .wide, resolution: hd)), [30, 60, 120, 240])
        XCTAssertEqual(capabilities.options(\.profile, matching: VideoModeQuery(resolution: hd)), [.sdr])
        XCTAssertEqual(capabilities.options(\.lens, matching: VideoModeQuery()), [.ultraWide, .wide])
        XCTAssertFalse(capabilities.supports(VideoMode(lens: .wide, resolution: uhd, frameRate: 240, profile: .appleLog)))
    }

    func testResolveFindsNearestValidMode() {
        // 4K 120 i/s Log n'existe pas : on garde la 4K Log et on prend la cadence la plus proche.
        let resolved = capabilities.resolve(VideoModeQuery(lens: .wide, resolution: uhd, frameRate: 120, profile: .appleLog))
        XCTAssertEqual(resolved, VideoMode(lens: .wide, resolution: uhd, frameRate: 60, profile: .appleLog))
        // L'ultra grand-angle ne fait pas de 4K : on garde l'objectif.
        let ultra = capabilities.resolve(VideoModeQuery(lens: .ultraWide, resolution: uhd, frameRate: 60))
        XCTAssertEqual(ultra, VideoMode(lens: .ultraWide, resolution: hd, frameRate: 30, profile: .sdr))
        XCTAssertNil(CaptureCapabilities().resolve(VideoModeQuery()))
    }
}

final class ArrangeAndPresetTests: XCTestCase {
    func testArrangeSequentiallyReordersWithoutGaps() throws {
        var timeline = Timeline(frameRate: Rational(25))
        let a = try timeline.append(mediaID: "a", duration: Rational(1))
        let b = try timeline.append(mediaID: "b", duration: Rational(2))
        let c = try timeline.append(mediaID: "c", duration: Rational(3))
        let track = timeline.mainVideoTrack.id
        try timeline.arrangeSequentially([c.id, a.id], on: track)
        XCTAssertEqual(timeline.clips(on: track).map(\.mediaID), ["c", "a", "b"])
        XCTAssertEqual(timeline.clip(a.id)?.start, Rational(3))
        XCTAssertEqual(timeline.clip(b.id)?.start, Rational(4))
        XCTAssertEqual(timeline.duration, Rational(6))
    }

    func testPresetKeepsPhotoSpecificSettings() {
        var base = DevelopSettings()
        base.exposure = 0.8
        base.temperature = 12
        base.crop.angle = 3
        base.contrast = 50
        let styled = BuiltInPresets.blackAndWhite.apply(to: base)
        XCTAssertEqual(styled.exposure, 0.8)
        XCTAssertEqual(styled.temperature, 12)
        XCTAssertEqual(styled.crop.angle, 3)
        XCTAssertEqual(styled.saturation, -100)
        XCTAssertEqual(styled.contrast, BuiltInPresets.blackAndWhite.settings.contrast)
    }

    func testBuiltInPresetsAreValidAndDistinct() {
        XCTAssertEqual(Set(BuiltInPresets.all.map(\.id)).count, BuiltInPresets.all.count)
        for preset in BuiltInPresets.all {
            XCTAssertEqual(preset.settings, preset.settings.clamped(), preset.name)
            XCTAssertFalse(ColorGradeProcessor(settings: preset.settings).isIdentity, preset.name)
        }
    }
}
