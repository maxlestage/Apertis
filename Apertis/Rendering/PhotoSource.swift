@preconcurrency import CoreImage
import ImageIO
import UniformTypeIdentifiers
import ApertisCore

/// Original photo ouvert pour le développement. Ne modifie jamais le fichier.
///
/// Les RAW passent par `CIRAWFilter` : exposition, balance des blancs et réduction du bruit
/// sont appliquées au dématriçage, là où l'information du capteur est encore disponible.
/// Les autres images sont décodées une fois ; l'aperçu réduit est mis en cache en demi-flottants
/// pour conserver la plage dynamique (HEIF HDR).
final class PhotoSource: @unchecked Sendable {
    let url: URL
    let kind: MediaKind
    /// Métadonnées de l'original (EXIF, TIFF, GPS…).
    let properties: [String: Any]

    private let rawFilter: CIRAWFilter?
    private let baseTemperature: Float
    private let baseTint: Float
    /// Taille de l'image développée et orientée, en pixels.
    let size: CGSize
    private var developedImage: CIImage?
    private var previewCache: (maxDimension: CGFloat, image: CIImage)?
    private let lock = NSLock()

    enum LoadError: LocalizedError {
        case unreadable
        var errorDescription: String? { "Impossible de lire ce fichier image." }
    }

    init(url: URL, kind: MediaKind) throws {
        self.url = url
        self.kind = kind
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            properties = props
        } else {
            properties = [:]
        }
        if kind == .raw || kind == .proRAW, let filter = CIRAWFilter(imageURL: url) {
            rawFilter = filter
            baseTemperature = filter.neutralTemperature
            baseTint = filter.neutralTint
            size = filter.outputImage?.extent.size ?? filter.nativeSize
            developedImage = nil
        } else {
            rawFilter = nil
            baseTemperature = 0
            baseTint = 0
            guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .expandToHDR: true]) else {
                throw LoadError.unreadable
            }
            developedImage = image
            size = image.extent.size
        }
    }

    var isRAW: Bool { rawFilter != nil }

    /// Image de base (avant les étapes couleur et spatiale), éventuellement réduite.
    func baseImage(settings: DevelopSettings, maxDimension: CGFloat?) -> (CIImage, GradeRenderer.SourceKind)? {
        lock.lock()
        defer { lock.unlock() }
        if let rawFilter {
            let s = settings.clamped()
            rawFilter.exposure = Float(s.exposure)
            rawFilter.neutralTemperature = baseTemperature + Float(s.temperature) * 30
            rawFilter.neutralTint = baseTint + Float(s.tint) * 1.5
            if rawFilter.isLuminanceNoiseReductionSupported {
                rawFilter.luminanceNoiseReductionAmount = Float(s.noiseReduction / 100)
            }
            let native = rawFilter.nativeSize
            if let maxDimension, max(native.width, native.height) > maxDimension {
                rawFilter.scaleFactor = Float(maxDimension / max(native.width, native.height))
            } else {
                rawFilter.scaleFactor = 1
            }
            guard let output = rawFilter.outputImage else { return nil }
            return (output, .raw)
        }

        guard let image = developedImage else { return nil }
        guard let maxDimension, max(image.extent.width, image.extent.height) > maxDimension else {
            return (image, .developed)
        }
        if let cached = previewCache, cached.maxDimension == maxDimension {
            return (cached.image, .developed)
        }
        let scale = maxDimension / max(image.extent.width, image.extent.height)
        let scaled = image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1,
        ])
        // On fige l'aperçu réduit en mémoire pour ne pas redécoder l'original à chaque curseur.
        let context = GradeRenderer.shared.context
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        guard let baked = context.createCGImage(scaled, from: scaled.extent, format: .RGBAh, colorSpace: linear) else {
            return (scaled, .developed)
        }
        let result = CIImage(cgImage: baked)
        previewCache = (maxDimension, result)
        return (result, .developed)
    }

    /// Image développée finale.
    func render(settings: DevelopSettings, maxDimension: CGFloat?, cubeDimension: Int = 33) -> CIImage? {
        guard let base = baseImage(settings: settings, maxDimension: maxDimension) else { return nil }
        let options = GradeRenderer.Options(cubeDimension: cubeDimension, fullResolutionDimension: max(size.width, size.height))
        return GradeRenderer.shared.apply(settings, to: base.0, source: base.1, options: options)
    }

    /// Vignette d'un style : l'aperçu en cache, réduit à `dimension` avant le développement.
    func thumbnail(settings: DevelopSettings, previewDimension: CGFloat, dimension: CGFloat) -> CIImage? {
        guard let base = baseImage(settings: settings, maxDimension: previewDimension) else { return nil }
        let extent = base.0.extent
        let scale = min(1, dimension / max(extent.width, extent.height))
        let small = base.0.transformed(by: CGAffineTransform(scaleX: scale, y: scale), highQualityDownsample: true)
        let options = GradeRenderer.Options(cubeDimension: 17, fullResolutionDimension: max(size.width, size.height))
        return GradeRenderer.shared.apply(settings, to: small, source: base.1, options: options)
    }

    /// Métadonnées à écrire dans un export : l'orientation est réinitialisée (les pixels sont
    /// déjà orientés) et la localisation peut être retirée.
    func exportProperties(removeLocation: Bool) -> [String: Any] {
        var props = properties
        props[kCGImagePropertyOrientation as String] = 1
        props.removeValue(forKey: kCGImagePropertyPixelWidth as String)
        props.removeValue(forKey: kCGImagePropertyPixelHeight as String)
        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            tiff[kCGImagePropertyTIFFSoftware as String] = "Apertis"
            props[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if removeLocation {
            props.removeValue(forKey: kCGImagePropertyGPSDictionary as String)
        }
        return props
    }

    static func mediaKind(for url: URL) -> MediaKind {
        if let type = UTType(filenameExtension: url.pathExtension) {
            if type.conforms(to: .rawImage) { return .raw }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
            if type.conforms(to: .audio) { return .audio }
        }
        let rawExtensions: Set<String> = ["dng", "cr2", "cr3", "nef", "nrw", "arw", "raf", "orf", "rw2", "pef", "srw", "3fr", "iiq"]
        return rawExtensions.contains(url.pathExtension.lowercased()) ? .raw : .photo
    }
}
