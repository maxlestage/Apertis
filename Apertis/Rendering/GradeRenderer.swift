@preconcurrency import CoreImage
import CoreImage.CIFilterBuiltins
import ApertisCore

/// Applique des `DevelopSettings` à une image Core Image, pour la photo comme pour la vidéo.
///
/// Ordre des opérations :
/// 1. géométrie (redressement, recadrage)
/// 2. étape linéaire — balance des blancs et exposition (sauf RAW : faites au dématriçage),
///    hautes lumières négatives et ombres
/// 3. étape couleur — `ColorGradeProcessor` cuit dans un cube 3D appliqué sur le GPU
/// 4. étape spatiale — réduction du bruit (hors RAW), netteté, vignette, grain
///
/// Le moteur est sûr à utiliser depuis plusieurs fils (aperçu, export, rendu vidéo).
final class GradeRenderer: @unchecked Sendable {
    static let shared = GradeRenderer()

    enum SourceKind {
        /// Image déjà développée : l'étape linéaire est appliquée ici.
        case developed
        /// Sortie de CIRAWFilter : exposition, balance des blancs et bruit déjà appliqués.
        case raw
    }

    /// Contexte unique (Metal), espace de travail linéaire étendu.
    let context: CIContext

    private let lock = NSLock()
    private var cubeCache: [(key: DevelopSettings, dimension: Int, data: Data)] = []
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private init() {
        context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
        ])
    }

    func apply(_ rawSettings: DevelopSettings, to input: CIImage, source: SourceKind, cubeDimension: Int = 33) -> CIImage {
        let s = rawSettings.clamped()
        var image = applyGeometry(s.crop, to: input)
        let extent = image.extent

        // Étape linéaire
        if source == .developed {
            if s.temperature != 0 || s.tint != 0 {
                let gains = ColorMath.whiteBalanceGains(temperature: s.temperature, tint: s.tint)
                let f = CIFilter.colorMatrix()
                f.inputImage = image
                f.rVector = CIVector(x: CGFloat(gains.x), y: 0, z: 0, w: 0)
                f.gVector = CIVector(x: 0, y: CGFloat(gains.y), z: 0, w: 0)
                f.bVector = CIVector(x: 0, y: 0, z: CGFloat(gains.z), w: 0)
                image = f.outputImage ?? image
            }
            if s.exposure != 0 {
                let f = CIFilter.exposureAdjust()
                f.inputImage = image
                f.ev = Float(s.exposure)
                image = f.outputImage ?? image
            }
        }
        if s.highlights < 0 || s.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = image
            f.highlightAmount = Float(1 + min(s.highlights, 0) / 100)
            f.shadowAmount = Float(s.shadows / 100)
            // Rayon proportionnel à l'image : l'aperçu réduit et l'export donnent le même rendu.
            f.radius = Float(max(extent.width, extent.height) * 0.004)
            image = f.outputImage ?? image
        }

        // Étape couleur
        if let cube = cubeData(for: s, dimension: cubeDimension) {
            let f = CIFilter.colorCubeWithColorSpace()
            f.inputImage = image
            f.cubeDimension = Float(cubeDimension)
            f.cubeData = cube
            f.colorSpace = sRGB
            image = f.outputImage ?? image
        }

        // Étape spatiale
        if source == .developed && s.noiseReduction > 0 {
            let f = CIFilter.noiseReduction()
            f.inputImage = image
            f.noiseLevel = Float(s.noiseReduction / 100 * 0.06)
            f.sharpness = 0.4
            image = f.outputImage ?? image
        }
        if s.sharpness > 0 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = image
            f.sharpness = Float(s.sharpness / 100)
            f.radius = Float(max(1, max(extent.width, extent.height) / 2000))
            image = f.outputImage ?? image
        }
        if s.vignette != 0 {
            let f = CIFilter.vignetteEffect()
            f.inputImage = image
            f.center = CGPoint(x: extent.midX, y: extent.midY)
            f.radius = Float(hypot(extent.width, extent.height) / 2 * 0.85)
            f.intensity = Float(s.vignette / 100)
            f.falloff = 0.6
            image = f.outputImage ?? image
        }
        if s.grain > 0 {
            image = applyGrain(amount: s.grain / 100, to: image)
        }
        return image.cropped(to: extent)
    }

    /// Cube de l'étape couleur ; nil si elle est neutre. Mis en cache : un curseur qui ne
    /// touche que l'exposition ne recalcule pas le cube.
    func cubeData(for settings: DevelopSettings, dimension: Int) -> Data? {
        let key = Self.colorKey(settings)
        lock.lock()
        if let hit = cubeCache.first(where: { $0.key == key && $0.dimension == dimension }) {
            lock.unlock()
            return hit.data
        }
        lock.unlock()

        let lut = settings.lut.flatMap { LUTLibrary.shared.lut(for: $0.identifier) }
        let processor = ColorGradeProcessor(settings: key, lut: lut)
        guard !processor.isIdentity else { return nil }
        let data = processor.makeCube(dimension: dimension).withUnsafeBufferPointer { Data(buffer: $0) }

        lock.lock()
        cubeCache.insert((key, dimension, data), at: 0)
        if cubeCache.count > 6 { cubeCache.removeLast() }
        lock.unlock()
        return data
    }

    /// Réglages qui influencent uniquement l'étape couleur.
    private static func colorKey(_ s: DevelopSettings) -> DevelopSettings {
        var k = s
        k.temperature = 0
        k.tint = 0
        k.exposure = 0
        k.shadows = 0
        k.highlights = max(s.highlights, 0)
        k.vignette = 0
        k.grain = 0
        k.sharpness = 0
        k.noiseReduction = 0
        k.crop = CropSettings()
        return k
    }

    private func applyGeometry(_ crop: CropSettings, to input: CIImage) -> CIImage {
        var image = input
        let extent = input.extent
        if crop.angle != 0 {
            let f = CIFilter.straighten()
            f.inputImage = image
            f.angle = Float(crop.angle * .pi / 180)
            image = (f.outputImage ?? image).cropped(to: extent)
        }
        guard crop.x != 0 || crop.y != 0 || crop.width != 1 || crop.height != 1 else { return image }
        // Le recadrage est exprimé avec l'origine en haut à gauche ; Core Image a l'origine en bas.
        let rect = CGRect(x: extent.minX + crop.x * extent.width,
                          y: extent.minY + (1 - crop.y - crop.height) * extent.height,
                          width: crop.width * extent.width,
                          height: crop.height * extent.height).integral
        return image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    private func applyGrain(amount: Double, to image: CIImage) -> CIImage {
        guard let noise = CIFilter.randomGenerator().outputImage else { return image }
        let extent = image.extent
        // Grain proportionnel à la taille de l'image, monochrome, centré sur le gris neutre.
        let scale = max(1, max(extent.width, extent.height) / 1800)
        let a = CGFloat(amount * 0.35)
        let mono = CIFilter.colorMatrix()
        mono.inputImage = noise.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        mono.rVector = CIVector(x: 0, y: a, z: 0, w: 0)
        mono.gVector = CIVector(x: 0, y: a, z: 0, w: 0)
        mono.bVector = CIVector(x: 0, y: a, z: 0, w: 0)
        mono.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        mono.biasVector = CIVector(x: 0.5 - a / 2, y: 0.5 - a / 2, z: 0.5 - a / 2, w: 1)
        guard let grain = mono.outputImage?.cropped(to: extent) else { return image }
        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = grain
        blend.backgroundImage = image
        return blend.outputImage ?? image
    }
}
