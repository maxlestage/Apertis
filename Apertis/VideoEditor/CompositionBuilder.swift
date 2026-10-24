@preconcurrency import AVFoundation
@preconcurrency import CoreImage
import ApertisCore

/// Étalonnages par plan, lus par le compositeur pendant la lecture. Modifiable en direct :
/// un curseur d'étalonnage n'oblige pas à reconstruire la composition.
final class GradeTable: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(start: CMTime, end: CMTime, grade: DevelopSettings)] = []
    private var bypass = false

    /// Avant / après : sans étalonnage pendant la comparaison.
    func setBypass(_ value: Bool) {
        lock.lock()
        bypass = value
        lock.unlock()
    }

    func set(_ clips: [Clip]) {
        lock.lock()
        entries = clips.map { ($0.start.cmTime, $0.end.cmTime, $0.grade) }
        lock.unlock()
    }

    func grade(at time: CMTime) -> DevelopSettings? {
        lock.lock()
        defer { lock.unlock() }
        if bypass { return nil }
        return entries.first { $0.start <= time && time < $0.end }?.grade
    }
}

struct BuiltComposition {
    let composition: AVComposition
    let videoComposition: AVVideoComposition?
    let audioMix: AVAudioMix
}

enum VideoExportPreset: String, CaseIterable, Identifiable {
    case hevcHighest, hevc4K, hevc1080, h264_1080

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hevcHighest: return "HEVC qualité maximale"
        case .hevc4K: return "4K HEVC"
        case .hevc1080: return "1080p HEVC"
        case .h264_1080: return "1080p H.264 (compatibilité)"
        }
    }

    var presetName: String {
        switch self {
        case .hevcHighest: return AVAssetExportPresetHEVCHighestQuality
        case .hevc4K: return AVAssetExportPresetHEVC3840x2160
        case .hevc1080: return AVAssetExportPresetHEVC1920x1080
        case .h264_1080: return AVAssetExportPreset1920x1080
        }
    }

    var fileType: AVFileType { self == .h264_1080 ? .mp4 : .mov }
}

enum CompositionError: LocalizedError {
    case cannotCreateTrack
    case exportUnavailable
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotCreateTrack: return "Impossible de préparer la composition."
        case .exportUnavailable: return "Ce préréglage d'export n'est pas disponible pour ce projet."
        case .exportFailed(let reason): return "Échec de l'export : \(reason)"
        }
    }
}

/// Traduit une `Timeline` (modèle indépendant) en composition AVFoundation.
///
/// Limites actuelles : la piste vidéo principale est composée (les pistes vidéo supérieures
/// demanderont un compositeur personnalisé) et l'orientation du premier plan s'applique à tous.
enum CompositionBuilder {
    static func build(_ project: VideoProject, store: MediaStore, grades: GradeTable, cubeDimension: Int) async throws -> BuiltComposition {
        let composition = AVMutableComposition()
        let timeline = project.timeline
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let clipAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw CompositionError.cannotCreateTrack }

        let clipAudio = AVMutableAudioMixInputParameters(track: clipAudioTrack)
        var transform: CGAffineTransform?
        let mainClips = timeline.clips(on: timeline.mainVideoTrack.id)

        for clip in mainClips {
            guard let reference = project.media[clip.mediaID] else { continue }
            let asset = AVURLAsset(url: store.url(for: reference))
            let sourceRange = CMTimeRange(start: clip.sourceIn.cmTime, duration: clip.sourceDuration.cmTime)
            let at = clip.start.cmTime
            if let source = try await asset.loadTracks(withMediaType: .video).first {
                try videoTrack.insertTimeRange(sourceRange, of: source, at: at)
                if transform == nil { transform = try await source.load(.preferredTransform) }
            }
            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                try clipAudioTrack.insertTimeRange(sourceRange, of: sourceAudio, at: at)
                clipAudio.setVolume(Float(clip.volume), at: at)
            }
            if clip.speed != .one {
                composition.scaleTimeRange(CMTimeRange(start: at, duration: sourceRange.duration), toDuration: clip.duration.cmTime)
            }
        }
        videoTrack.preferredTransform = transform ?? .identity

        var parameters = [clipAudio]
        for track in timeline.tracks where track.kind == .audio && !track.isMuted {
            let clips = timeline.clips(on: track.id)
            guard !clips.isEmpty,
                  let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let params = AVMutableAudioMixInputParameters(track: audioTrack)
            for clip in clips {
                guard let reference = project.media[clip.mediaID],
                      let source = try await AVURLAsset(url: store.url(for: reference)).loadTracks(withMediaType: .audio).first
                else { continue }
                let range = CMTimeRange(start: clip.sourceIn.cmTime, duration: clip.sourceDuration.cmTime)
                try audioTrack.insertTimeRange(range, of: source, at: clip.start.cmTime)
                params.setVolume(Float(clip.volume), at: clip.start.cmTime)
            }
            parameters.append(params)
        }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = parameters

        grades.set(mainClips)
        // Format du film : celui du premier plan, appliqué à tout le montage (comme le laboratoire du site).
        let filmAspect = mainClips.first?.grade.crop.aspect ?? 0
        var videoComposition: AVVideoComposition?
        if !mainClips.isEmpty {
            let mutable = AVMutableVideoComposition(asset: composition) { request in
                let source = request.sourceImage
                let renderSize = request.renderSize
                guard let grade = grades.grade(at: request.compositionTime), !grade.isNeutral || filmAspect != 0 else {
                    request.finish(with: source, context: nil)
                    return
                }
                var videoGrade = grade
                // Un plan garde son redressement ; rotation et miroir ne s'appliquent qu'aux photos.
                videoGrade.crop = CropSettings(aspect: filmAspect, angle: grade.crop.angle)
                let graded = GradeRenderer.shared.apply(videoGrade, to: source, source: .developed, cubeDimension: cubeDimension)
                // Le cadre redressé est plus petit que l'image : on le ramène à la taille du film.
                let extent = graded.extent
                let scale = max(renderSize.width / max(extent.width, 1), renderSize.height / max(extent.height, 1))
                let output = graded.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .cropped(to: CGRect(origin: .zero, size: renderSize))
                request.finish(with: output, context: nil)
            }
            mutable.frameDuration = timeline.frameDuration.cmTime
            if filmAspect != 0 {
                let natural = mutable.renderSize
                let frame = FrameGeometry(crop: CropSettings(aspect: filmAspect),
                                          sourceWidth: natural.width, sourceHeight: natural.height)
                // Dimensions paires, exigées par les encodeurs vidéo.
                mutable.renderSize = CGSize(width: frame.width / 2 * 2, height: frame.height / 2 * 2)
            }
            videoComposition = mutable
        }
        return BuiltComposition(composition: composition, videoComposition: videoComposition, audioMix: audioMix)
    }

    static func export(_ built: BuiltComposition, preset: VideoExportPreset, to url: URL,
                       progress: @escaping (Float) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: built.composition, presetName: preset.presetName) else {
            throw CompositionError.exportUnavailable
        }
        session.outputURL = url
        session.outputFileType = preset.fileType
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        session.shouldOptimizeForNetworkUse = true

        let poll = Task {
            while !Task.isCancelled {
                progress(session.progress)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        poll.cancel()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw CompositionError.exportFailed(session.error?.localizedDescription ?? "statut \(session.status.rawValue)")
        }
        progress(1)
    }
}
