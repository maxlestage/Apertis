@preconcurrency import CoreImage
import SwiftUI
import ApertisCore

enum PhotoExportFormat: String, CaseIterable, Identifiable {
    case jpeg, heif, heif10, tiff16
    var id: String { rawValue }

    var label: String {
        switch self {
        case .jpeg: return "JPEG"
        case .heif: return "HEIF"
        case .heif10: return "HEIF 10 bits"
        case .tiff16: return "TIFF 16 bits"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .heif, .heif10: return "heic"
        case .tiff16: return "tif"
        }
    }

    var isLossy: Bool { self != .tiff16 }
}

/// État de l'éditeur photo. Les réglages en cours sont rendus en continu ; une étape
/// d'historique est créée (et le projet enregistré) à la fin de chaque geste.
final class PhotoEditorModel: ObservableObject {
    @Published private(set) var project: PhotoProject
    @Published var settings: DevelopSettings {
        didSet { if settings != oldValue { scheduleRender() } }
    }
    @Published private(set) var preview: CGImage?
    @Published private(set) var original: CGImage?
    @Published private(set) var imageSize: CGSize = .zero
    @Published private(set) var loadError: String?
    @Published private(set) var isExporting = false
    @Published var exportMessage: String?

    let store: MediaStore
    private let renderQueue = DispatchQueue(label: "fr.apertis.photo.render", qos: .userInitiated)
    /// Accédé uniquement depuis `renderQueue`.
    private var source: PhotoSource?
    private var renderInFlight = false
    private var renderPending = false
    private let previewDimension: CGFloat = 2048

    init(project: PhotoProject, store: MediaStore) {
        self.project = project
        self.store = store
        settings = project.settings
        load()
    }

    var canUndo: Bool { project.history.canUndo }
    var canRedo: Bool { project.history.canRedo }

    private func load() {
        let url = store.url(for: project.source)
        let kind = project.source.kind
        let status = project.source.status(in: store.originals)
        let initial = settings
        renderQueue.async {
            guard status == .available else {
                DispatchQueue.main.async {
                    self.loadError = status == .missing ? "L'original est introuvable." : "L'original a été modifié en dehors d'Apertis."
                }
                return
            }
            do {
                let source = try PhotoSource(url: url, kind: kind)
                self.source = source
                let original = self.render(.neutral, with: source)
                let preview = self.render(initial, with: source)
                DispatchQueue.main.async {
                    self.imageSize = source.size
                    self.original = original
                    self.preview = preview
                }
            } catch {
                DispatchQueue.main.async { self.loadError = error.localizedDescription }
            }
        }
    }

    /// Rendu de l'aperçu, en coalesçant les demandes : pendant un geste, seul le dernier état compte.
    private func scheduleRender() {
        guard !renderInFlight else {
            renderPending = true
            return
        }
        renderInFlight = true
        let snapshot = settings
        renderQueue.async {
            let image = self.source.flatMap { self.render(snapshot, with: $0) }
            DispatchQueue.main.async {
                if let image { self.preview = image }
                self.renderInFlight = false
                if self.renderPending {
                    self.renderPending = false
                    self.scheduleRender()
                }
            }
        }
    }

    private func render(_ settings: DevelopSettings, with source: PhotoSource) -> CGImage? {
        guard let image = source.render(settings: settings, maxDimension: previewDimension, cubeDimension: 33) else { return nil }
        return GradeRenderer.shared.context.createCGImage(image, from: image.extent, format: .RGBA8,
                                                          colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
    }

    // MARK: Historique

    func binding(_ keyPath: WritableKeyPath<DevelopSettings, Double>) -> Binding<Double> {
        Binding(get: { self.settings[keyPath: keyPath] }, set: { self.settings[keyPath: keyPath] = $0 })
    }

    func commit(_ label: String) {
        project.history.commit(settings, label: label)
        persist()
    }

    func undo() {
        settings = project.history.undo()
        persist()
    }

    func redo() {
        settings = project.history.redo()
        persist()
    }

    func reset() {
        settings = .neutral
        commit("Réinitialiser")
    }

    func apply(_ preset: Preset) {
        settings = preset.apply(to: settings)
        commit("Style « \(preset.name) »")
    }

    func setRating(_ rating: Int) {
        project.rating = min(max(rating, 0), 5)
        persist()
    }

    private func persist() {
        do { try store.save(project) } catch { exportMessage = "Enregistrement du projet impossible : \(error.localizedDescription)" }
        objectWillChange.send()
    }

    /// Recadrage centré au rapport largeur/hauteur demandé (nil = image entière).
    func setAspectRatio(_ ratio: Double?) {
        var crop = settings.crop
        guard let ratio, imageSize.width > 0 else {
            crop.x = 0; crop.y = 0; crop.width = 1; crop.height = 1
            settings.crop = crop
            commit("Recadrage")
            return
        }
        let imageRatio = Double(imageSize.width / imageSize.height)
        if ratio > imageRatio {
            crop.width = 1
            crop.height = imageRatio / ratio
        } else {
            crop.height = 1
            crop.width = ratio / imageRatio
        }
        crop.x = (1 - crop.width) / 2
        crop.y = (1 - crop.height) / 2
        settings.crop = crop
        commit("Recadrage")
    }

    // MARK: Export

    /// Rend l'image en pleine résolution, depuis l'original, avec un cube haute précision.
    func export(format: PhotoExportFormat, quality: Double, removeLocation: Bool, saveToPhotos: Bool) {
        guard !isExporting else { return }
        isExporting = true
        let snapshot = settings
        let baseName = (project.source.originalFileName as NSString).deletingPathExtension
        let destination = store.exportURL(baseName: "\(baseName)-apertis", fileExtension: format.fileExtension)
        renderQueue.async {
            let result: Result<URL, Error> = Result {
                guard let source = self.source,
                      let image = source.render(settings: snapshot, maxDimension: nil, cubeDimension: 64)
                else { throw CocoaError(.fileReadCorruptFile) }
                let tagged = image.settingProperties(source.exportProperties(removeLocation: removeLocation))
                let context = GradeRenderer.shared.context
                let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
                let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
                let options: [CIImageRepresentationOption: Any] = format.isLossy
                    ? [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality] : [:]
                let data: Data?
                switch format {
                case .jpeg: data = context.jpegRepresentation(of: tagged, colorSpace: sRGB, options: options)
                case .heif: data = context.heifRepresentation(of: tagged, format: .RGBA8, colorSpace: p3, options: options)
                case .heif10: data = try context.heif10Representation(of: tagged, colorSpace: p3, options: options)
                case .tiff16: data = context.tiffRepresentation(of: tagged, format: .RGBA16, colorSpace: p3, options: options)
                }
                guard let data else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: destination, options: [.atomic])
                return destination
            }
            DispatchQueue.main.async {
                self.isExporting = false
                switch result {
                case .success(let url):
                    if saveToPhotos { PhotoLibrarySaver.saveImage(at: url) }
                    self.exportMessage = "Exporté : \(url.lastPathComponent)" + (saveToPhotos ? " (et ajouté à Photos)" : "")
                case .failure(let error):
                    self.exportMessage = "Échec de l'export : \(error.localizedDescription)"
                }
            }
        }
    }
}
