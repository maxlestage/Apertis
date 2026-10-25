@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Photos
import ApertisCore

/// Bibliothèque locale : originaux, projets, exports et LUT.
///
/// Arborescence (dans Documents, visible dans l'app Fichiers) :
/// ```
/// Apertis/
/// ├── Originals/   fichiers sources, jamais modifiés
/// ├── Projects/    projets .apertis (photo) et .apertisvideo (vidéo)
/// ├── Exports/
/// └── LUTs/
/// ```
final class MediaStore: ObservableObject, @unchecked Sendable {
    @Published private(set) var photoProjects: [PhotoProject] = []
    @Published private(set) var videoProjects: [VideoProject] = []
    /// Projets illisibles (fichier corrompu ou version plus récente) : signalés, jamais supprimés.
    @Published private(set) var unreadableProjects: [String] = []

    let root: URL
    let originals: URL
    let projects: URL
    let exports: URL
    let luts: URL

    /// Enregistrer aussi les prises de vue dans Photos.
    var saveCapturesToPhotos: Bool {
        get { UserDefaults.standard.object(forKey: "saveCapturesToPhotos") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "saveCapturesToPhotos") }
    }

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("Apertis", isDirectory: true)
        originals = root.appendingPathComponent("Originals", isDirectory: true)
        projects = root.appendingPathComponent("Projects", isDirectory: true)
        exports = root.appendingPathComponent("Exports", isDirectory: true)
        luts = root.appendingPathComponent("LUTs", isDirectory: true)
        for directory in [originals, projects, exports, luts] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        LUTLibrary.shared.configure(directory: luts)
        reload()
    }

    func url(for reference: MediaReference) -> URL {
        originals.appendingPathComponent(reference.fileName)
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        var photos: [PhotoProject] = []
        var videos: [VideoProject] = []
        var unreadable: [String] = []
        for file in files {
            switch file.pathExtension {
            case "apertis":
                if let p = try? ProjectIO.load(PhotoProject.self, from: file) { photos.append(p) } else { unreadable.append(file.lastPathComponent) }
            case "apertisvideo":
                if let p = try? ProjectIO.load(VideoProject.self, from: file) { videos.append(p) } else { unreadable.append(file.lastPathComponent) }
            default:
                continue
            }
        }
        photoProjects = photos.sorted { $0.createdAt > $1.createdAt }
        videoProjects = videos.sorted { $0.modifiedAt > $1.modifiedAt }
        unreadableProjects = unreadable
    }

    // MARK: - Originaux

    /// Copie un fichier dans les originaux sous un nom unique.
    func storeOriginal(copying source: URL, kind: MediaKind? = nil) throws -> MediaReference {
        let ext = source.pathExtension.lowercased()
        let fileName = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
        let destination = originals.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: source, to: destination)
        return MediaReference(fileName: fileName, originalFileName: source.lastPathComponent,
                              kind: kind ?? PhotoSource.mediaKind(for: source), byteSize: try fileSize(destination))
    }

    func storeOriginal(data: Data, fileExtension: String, originalName: String, kind: MediaKind) throws -> MediaReference {
        let fileName = UUID().uuidString + ".\(fileExtension)"
        let destination = originals.appendingPathComponent(fileName)
        try data.write(to: destination, options: [.atomic])
        return MediaReference(fileName: fileName, originalFileName: originalName, kind: kind, byteSize: Int64(data.count))
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Photos

    @discardableResult
    func importPhoto(from url: URL) throws -> PhotoProject {
        let reference = try storeOriginal(copying: url)
        let project = PhotoProject(source: reference)
        try save(project)
        return project
    }

    @discardableResult
    func addCapturedPhoto(_ capture: CapturedPhoto) throws -> PhotoProject {
        let reference: MediaReference
        let stamp = Self.captureName()
        if let raw = capture.rawData {
            reference = try storeOriginal(data: raw, fileExtension: "dng", originalName: "\(stamp).dng",
                                          kind: capture.isProRAW ? .proRAW : .raw)
        } else if let processed = capture.processedData {
            reference = try storeOriginal(data: processed, fileExtension: capture.processedExtension,
                                          originalName: "\(stamp).\(capture.processedExtension)", kind: .photo)
        } else {
            throw CocoaError(.fileWriteUnknown)
        }
        let project = PhotoProject(source: reference)
        try save(project)
        if saveCapturesToPhotos { PhotoLibrarySaver.save(capture) }
        return project
    }

    func save(_ project: PhotoProject) throws {
        var p = project
        p.modifiedAt = Date()
        try ProjectIO.save(p, to: projects.appendingPathComponent("\(p.id.uuidString).apertis"))
        let update = { [self] in
            if let i = photoProjects.firstIndex(where: { $0.id == p.id }) { photoProjects[i] = p } else { photoProjects.insert(p, at: 0) }
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }

    /// Supprime le projet. L'original n'est supprimé que si `removeOriginal` est vrai.
    func delete(_ project: PhotoProject, removeOriginal: Bool) {
        try? FileManager.default.removeItem(at: projects.appendingPathComponent("\(project.id.uuidString).apertis"))
        if removeOriginal { try? FileManager.default.removeItem(at: url(for: project.source)) }
        photoProjects.removeAll { $0.id == project.id }
    }

    // MARK: - Vidéo

    func createVideoProject(name: String, frameRate: Rational) throws -> VideoProject {
        let project = VideoProject(name: name, frameRate: frameRate)
        try save(project)
        return project
    }

    func save(_ project: VideoProject) throws {
        var p = project
        p.modifiedAt = Date()
        try ProjectIO.save(p, to: projects.appendingPathComponent("\(p.id.uuidString).apertisvideo"))
        let update = { [self] in
            if let i = videoProjects.firstIndex(where: { $0.id == p.id }) { videoProjects[i] = p } else { videoProjects.insert(p, at: 0) }
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }

    func delete(_ project: VideoProject) {
        try? FileManager.default.removeItem(at: projects.appendingPathComponent("\(project.id.uuidString).apertisvideo"))
        videoProjects.removeAll { $0.id == project.id }
    }

    /// Copie une vidéo ou un son dans les originaux et lit sa durée.
    func importTimeBasedMedia(from url: URL) async throws -> MediaReference {
        var reference = try storeOriginal(copying: url)
        let asset = AVURLAsset(url: self.url(for: reference))
        let duration = try await asset.load(.duration)
        reference.duration = Rational(duration)
        return reference
    }

    /// Enregistre une vidéo filmée : originaux + Photos si l'option est active.
    func addRecordedMovie(at url: URL) async throws -> MediaReference {
        let reference = try await importTimeBasedMedia(from: url)
        if saveCapturesToPhotos {
            PhotoLibrarySaver.saveVideo(at: self.url(for: reference))
        }
        try? FileManager.default.removeItem(at: url)
        return reference
    }

    func exportURL(baseName: String, fileExtension: String) -> URL {
        var url = exports.appendingPathComponent("\(baseName).\(fileExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = exports.appendingPathComponent("\(baseName) \(counter).\(fileExtension)")
            counter += 1
        }
        return url
    }

    static func captureName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "APT-" + formatter.string(from: Date())
    }
}

/// Photo issue de la caméra : RAW (DNG) et/ou image traitée (HEIF ou JPEG).
struct CapturedPhoto {
    var rawData: Data?
    var processedData: Data?
    var processedExtension: String = "heic"
    var isProRAW: Bool = false
}

/// Enregistrement dans la photothèque système (autorisation « ajout uniquement »).
enum PhotoLibrarySaver {
    static func save(_ capture: CapturedPhoto) {
        withAddPermission {
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                switch (capture.processedData, capture.rawData) {
                case let (processed?, raw?):
                    request.addResource(with: .photo, data: processed, options: nil)
                    request.addResource(with: .alternatePhoto, data: raw, options: nil)
                case let (processed?, nil):
                    request.addResource(with: .photo, data: processed, options: nil)
                case let (nil, raw?):
                    request.addResource(with: .photo, data: raw, options: nil)
                case (nil, nil):
                    break
                }
            }
        }
    }

    static func saveImage(at url: URL) {
        withAddPermission {
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
            }
        }
    }

    static func saveVideo(at url: URL) {
        withAddPermission {
            PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: options)
            }
        }
    }

    private static func withAddPermission(_ work: @escaping () -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            if status == .authorized || status == .limited { work() }
        }
    }
}
