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

    /// Formats réservés à Apertis Pro.
    var isPro: Bool { self == .heif10 || self == .tiff16 }
}

/// État de l'éditeur photo. Les réglages en cours sont rendus en continu ; une étape
/// d'historique est créée (et le projet enregistré) à la fin de chaque geste.
final class PhotoEditorModel: ObservableObject, @unchecked Sendable {
    @Published private(set) var project: PhotoProject
    @Published var settings: DevelopSettings {
        didSet { if settings != oldValue { scheduleRender() } }
    }
    @Published private(set) var preview: CGImage?
    /// Histogramme RVB de l'aperçu (256 classes par canal, normalisées) et écrêtage.
    @Published private(set) var histogram: Histogram?
    /// Alerte d'écrêtage sur l'aperçu.
    @Published var showClipping = false {
        didSet { if showClipping != oldValue { scheduleRender() } }
    }
    /// Vignettes des styles, par identifiant, calculées sur l'image en cours.
    @Published private(set) var styleThumbnails: [String: CGImage] = [:]
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
                let original = self.render(.neutral, with: source, clipping: false)
                let preview = self.render(initial, with: source, clipping: false)
                DispatchQueue.main.async {
                    self.imageSize = source.size
                    self.original = original?.image
                    self.preview = preview?.image
                    self.histogram = preview?.histogram
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
        let clipping = showClipping
        renderQueue.async {
            let result = self.source.flatMap { self.render(snapshot, with: $0, clipping: clipping) }
            DispatchQueue.main.async {
                if let result {
                    self.preview = result.image
                    self.histogram = result.histogram
                }
                self.renderInFlight = false
                if self.renderPending {
                    self.renderPending = false
                    self.scheduleRender()
                }
            }
        }
    }

    private func render(_ settings: DevelopSettings, with source: PhotoSource, clipping: Bool) -> (image: CGImage, histogram: Histogram?)? {
        guard let image = source.render(settings: settings, maxDimension: previewDimension, cubeDimension: 33) else { return nil }
        let context = GradeRenderer.shared.context
        let shown = clipping ? GradeRenderer.shared.clippingOverlay(image) : image
        guard let cg = context.createCGImage(shown, from: shown.extent, format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.displayP3)) else { return nil }
        // Histogramme en sRGB, comme le site, sur une version réduite de l'image développée.
        let scale = min(1, 320 / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let histogram = context.createCGImage(small, from: small.extent, format: .RGBA8,
                                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)).flatMap(Histogram.init)
        return (cg, histogram)
    }

    /// Calcule les vignettes de tous les styles sur l'image en cours.
    func refreshStyleThumbnails(_ presets: [Preset]) {
        let base = settings
        let previewDimension = previewDimension
        renderQueue.async {
            guard let source = self.source else { return }
            for preset in presets {
                guard let image = source.thumbnail(settings: preset.apply(to: base), previewDimension: previewDimension, dimension: 180),
                      let cg = GradeRenderer.shared.context.createCGImage(image, from: image.extent, format: .RGBA8,
                                                                          colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
                else { continue }
                DispatchQueue.main.async { self.styleThumbnails[preset.id] = cg }
            }
        }
    }

    // MARK: Historique

    func binding(_ keyPath: WritableKeyPath<DevelopSettings, Double> & Sendable) -> Binding<Double> {
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

    // MARK: Cadrage

    /// Format centré, index dans `CropSettings.aspects` (0 = format d'origine).
    func setAspect(_ index: Int) {
        settings.crop.aspect = index
        commit("Format \(CropSettings.aspects[index].label)")
    }

    /// Quart de tour dans le sens horaire.
    func rotateClockwise() {
        settings.crop.rotation = (settings.crop.rotation + 1) % 4
        commit("Rotation")
    }

    func toggleFlip() {
        settings.crop.flip.toggle()
        commit("Miroir")
    }

    /// Taille de l'image après cadrage.
    var outputSize: CGSize {
        imageSize == .zero ? .zero : GradeRenderer.outputSize(settings.crop, source: imageSize)
    }

    // MARK: Recettes et styles personnels

    /// La recette des réglages en cours (même format que le laboratoire du site).
    var recipe: String { Recipe.encode(settings) }

    /// Applique une recette (texte JSON). Renvoie false si le texte n'en est pas une.
    @discardableResult
    func applyRecipe(_ text: String) -> Bool {
        guard let decoded = Recipe.decode(text) else { return false }
        settings = decoded
        commit("Recette")
        return true
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

/// Histogramme RVB d'une image 8 bits, et part des pixels écrêtés.
struct Histogram: Equatable {
    /// Trois canaux de 256 classes, normalisés par le pic (extrémités ignorées, comme le site).
    let channels: [[Float]]
    let clippedHighlights: Bool
    let clippedShadows: Bool

    init?(_ image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var bins = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        var high = 0, low = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            bins[0][r] += 1
            bins[1][g] += 1
            bins[2][b] += 1
            if r >= 254 || g >= 254 || b >= 254 { high += 1 }
            if r <= 1 && g <= 1 && b <= 1 { low += 1 }
        }
        self.init(bins: bins, clippedHighlights: high, clippedShadows: low, total: width * height)
    }

    /// À partir des comptes par classe et du nombre de pixels écrêtés.
    init(bins: [[Int]], clippedHighlights high: Int, clippedShadows low: Int, total: Int) {
        let peak = Float(max(bins.flatMap { $0[2..<254] }.max() ?? 1, 1))
        channels = bins.map { $0.map { min(Float($0) / peak, 1) } }
        clippedHighlights = Float(high) / Float(total) > 0.002
        clippedShadows = Float(low) / Float(total) > 0.002
    }
}
