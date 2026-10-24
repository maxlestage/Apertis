@preconcurrency import AVFoundation
import SwiftUI
import ApertisCore

/// État du studio vidéo. La timeline est la source de vérité ; la composition AVFoundation
/// est reconstruite après chaque modification de montage.
final class VideoEditorModel: ObservableObject {
    @Published private(set) var project: VideoProject
    @Published var selectedClipID: UUID?
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isBuilding = false
    @Published private(set) var exportProgress: Float?
    @Published private(set) var thumbnails: [String: CGImage] = [:]
    @Published var message: String?

    let player = AVPlayer()
    let store: MediaStore
    private let grades = GradeTable()
    private var rebuildTask: Task<Void, Never>?
    private var timeObserver: Any?

    init(project: VideoProject, store: MediaStore) {
        self.project = project
        self.store = store
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            self?.currentTime = time.seconds
        }
        let missing = project.unavailableMedia(in: store.originals)
        if !missing.isEmpty { message = "\(missing.count) média(s) introuvable(s) ou modifié(s)." }
        rebuild()
        loadThumbnails()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    var timeline: Timeline { project.timeline }
    var mainClips: [Clip] { timeline.clips(on: timeline.mainVideoTrack.id) }
    var audioClips: [Clip] { timeline.tracks.filter { $0.kind == .audio }.flatMap { timeline.clips(on: $0.id) } }
    var selectedClip: Clip? { selectedClipID.flatMap { timeline.clip($0) } }
    var duration: Double { timeline.duration.seconds }

    // MARK: Montage

    private func edit(_ change: (inout Timeline) throws -> Void) {
        var t = project.timeline
        do {
            try change(&t)
            project.timeline = t
            save()
            rebuild()
        } catch {
            message = error.localizedDescription
        }
    }

    private func save() {
        do { try store.save(project) } catch { message = "Enregistrement impossible : \(error.localizedDescription)" }
    }

    func importMedia(_ urls: [URL], asMusic: Bool) {
        Task {
            for url in urls {
                do {
                    let reference = try await store.importTimeBasedMedia(from: url)
                    await MainActor.run {
                        let id = reference.fileName
                        project.media[id] = reference
                        let duration = reference.duration ?? Rational(1)
                        edit { t in
                            let track = asMusic ? t.tracks.first { $0.kind == .audio }?.id : nil
                            try t.append(mediaID: id, duration: duration, trackID: track)
                        }
                        loadThumbnails()
                    }
                } catch {
                    await MainActor.run { message = "Import impossible : \(error.localizedDescription)" }
                }
            }
        }
    }

    /// Ajuste les points d'entrée et de sortie (en secondes dans le média source).
    func trim(_ clipID: UUID, sourceIn: Double, sourceOut: Double) {
        guard var clip = timeline.clip(clipID), sourceOut > sourceIn else { return }
        edit { t in
            clip.sourceIn = Rational(seconds: sourceIn, timescale: 600)
            clip.duration = t.snapToFrame(Rational(seconds: sourceOut - sourceIn, timescale: 600) / clip.speed)
            try Self.replace(clip, in: &t)
        }
    }

    func setSpeed(_ clipID: UUID, _ speed: Rational) {
        guard var clip = timeline.clip(clipID), speed > .zero else { return }
        edit { t in
            clip.duration = t.snapToFrame(clip.sourceDuration / speed)
            clip.speed = speed
            try Self.replace(clip, in: &t)
        }
    }

    /// Remplace un plan dont la durée a changé, puis referme la piste sans trou ni chevauchement.
    private static func replace(_ clip: Clip, in t: inout Timeline) throws {
        guard clip.duration > .zero else { throw TimelineError.invalidDuration }
        let order = t.clips(on: clip.trackID).map(\.id)
        t.remove(clip.id)
        var parked = clip
        parked.start = t.duration  // placé provisoirement à la fin de la timeline
        try t.insert(parked)
        try t.arrangeSequentially(order, on: clip.trackID)
    }

    func setVolume(_ clipID: UUID, _ volume: Double) {
        guard var clip = timeline.clip(clipID) else { return }
        clip.volume = min(max(volume, 0), 2)
        edit { try $0.update(clip) }
    }

    /// Coupe le plan sous la tête de lecture.
    func splitAtPlayhead() {
        let time = timeline.snapToFrame(Rational(seconds: currentTime, timescale: 600))
        guard let clip = timeline.clips(at: time, kind: .video).first else { return }
        edit { _ = try $0.split(clip.id, at: time) }
    }

    func delete(_ clipID: UUID) {
        if selectedClipID == clipID { selectedClipID = nil }
        edit { $0.rippleDelete(clipID) }
    }

    func move(_ clipID: UUID, by offset: Int) {
        guard let clip = timeline.clip(clipID) else { return }
        var order = timeline.clips(on: clip.trackID).map(\.id)
        guard let index = order.firstIndex(of: clipID) else { return }
        let target = min(max(index + offset, 0), order.count - 1)
        order.remove(at: index)
        order.insert(clipID, at: target)
        edit { try $0.arrangeSequentially(order, on: clip.trackID) }
    }

    func setMuted(_ trackID: UUID, _ muted: Bool) {
        edit { try $0.setTrackMuted(trackID, muted) }
    }

    // MARK: Étalonnage

    /// Modification en direct : pas de reconstruction, le compositeur lit la nouvelle valeur.
    func updateGrade(_ clipID: UUID, _ change: (inout DevelopSettings) -> Void) {
        guard var clip = timeline.clip(clipID) else { return }
        change(&clip.grade)
        var t = project.timeline
        guard (try? t.update(clip)) != nil else { return }
        project.timeline = t
        grades.set(mainClips)
        refreshFrame()
    }

    func commitGrade() { save() }

    func applyGradeToAllClips(from clipID: UUID) {
        edit { t in try t.copyGrade(from: clipID, to: t.clips.filter { $0.trackID == t.mainVideoTrack.id }.map(\.id)) }
    }

    private func refreshFrame() {
        guard let item = player.currentItem, let composition = item.videoComposition?.mutableCopy() as? AVVideoComposition else { return }
        item.videoComposition = composition
        if player.rate == 0 {
            player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Composition

    private func rebuild() {
        rebuildTask?.cancel()
        isBuilding = true
        let snapshot = project
        rebuildTask = Task {
            do {
                let built = try await CompositionBuilder.build(snapshot, store: store, grades: grades, cubeDimension: 25)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    let item = AVPlayerItem(asset: built.composition)
                    item.videoComposition = built.videoComposition
                    item.audioMix = built.audioMix
                    let time = player.currentTime()
                    player.replaceCurrentItem(with: item)
                    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                    isBuilding = false
                }
            } catch {
                await MainActor.run {
                    isBuilding = false
                    message = error.localizedDescription
                }
            }
        }
    }

    func export(_ preset: VideoExportPreset, saveToPhotos: Bool) {
        guard exportProgress == nil, !mainClips.isEmpty else { return }
        exportProgress = 0
        player.pause()
        let snapshot = project
        let url = store.exportURL(baseName: snapshot.name, fileExtension: preset.fileType == .mp4 ? "mp4" : "mov")
        Task {
            do {
                // Export : composition reconstruite avec un cube de couleur haute précision.
                let built = try await CompositionBuilder.build(snapshot, store: store, grades: GradeTable(), cubeDimension: 64)
                try await CompositionBuilder.export(built, preset: preset, to: url) { value in
                    DispatchQueue.main.async { self.exportProgress = value }
                }
                if saveToPhotos { PhotoLibrarySaver.saveVideo(at: url) }
                await MainActor.run {
                    exportProgress = nil
                    message = "Exporté : \(url.lastPathComponent)" + (saveToPhotos ? " (et ajouté à Photos)" : "")
                }
            } catch {
                await MainActor.run {
                    exportProgress = nil
                    message = error.localizedDescription
                }
            }
        }
    }

    private func loadThumbnails() {
        for (id, reference) in project.media where thumbnails[id] == nil && reference.kind == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: store.url(for: reference)))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            Task {
                guard let image = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image else { return }
                await MainActor.run { thumbnails[id] = image }
            }
        }
    }
}
