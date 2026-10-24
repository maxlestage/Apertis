@preconcurrency import CoreImage
import CoreImage.CIFilterBuiltins
import ApertisCore

/// Applique des `DevelopSettings` à une image Core Image, pour la photo comme pour la vidéo.
///
/// Même pipeline que le laboratoire du site, dans le même ordre :
/// 1. géométrie — quarts de tour, miroir, format, redressement (`FrameGeometry`)
/// 2. netteté — masque flou 3×3 identique au shader du site
/// 3. étape linéaire — balance des blancs et exposition (sauf RAW : faites au dématriçage)
/// 4. étape couleur — `ColorGradeProcessor` cuit dans un cube 3D appliqué sur le GPU
/// 5. effets — vignette, grain (noyau Metal `apertisEffects`, copie du shader du site)
///
/// La réduction du bruit, propre à l'app, s'insère avant l'étape couleur.
/// Le moteur est sûr à utiliser depuis plusieurs fils (aperçu, export, rendu vidéo).
final class GradeRenderer: @unchecked Sendable {
    static let shared = GradeRenderer()

    enum SourceKind {
        /// Image déjà développée : l'étape linéaire est appliquée ici.
        case developed
        /// Sortie de CIRAWFilter : exposition, balance des blancs et bruit déjà appliqués.
        case raw
    }

    struct Options {
        /// Taille du cube de couleur (33 pour l'aperçu, 64 pour l'export).
        var cubeDimension = 33
        /// Plus grand côté de l'image en pleine résolution, quand on rend un aperçu réduit :
        /// le grain garde alors la même taille relative qu'à l'export.
        var fullResolutionDimension: CGFloat?
    }

    /// Contexte unique (Metal), espace de travail linéaire étendu.
    let context: CIContext

    private let lock = NSLock()
    private var cubeCache: [(key: DevelopSettings, dimension: Int, data: Data)] = []
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private let effectsKernel: CIColorKernel? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? CIColorKernel(functionName: "apertisEffects", fromMetalLibraryData: data)
    }()

    /// Vrai si le noyau des effets est chargé (vérifié par les tests sur simulateur).
    var hasEffectsKernel: Bool { effectsKernel != nil }

    private init() {
        context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
        ])
    }

    func apply(_ rawSettings: DevelopSettings, to input: CIImage, source: SourceKind, cubeDimension: Int = 33) -> CIImage {
        apply(rawSettings, to: input, source: source, options: Options(cubeDimension: cubeDimension))
    }

    func apply(_ rawSettings: DevelopSettings, to input: CIImage, source: SourceKind, options: Options) -> CIImage {
        let s = rawSettings.clamped()
        var image = applyGeometry(s.crop, to: input)
        let extent = image.extent

        if s.sharpness > 0 {
            // c + k·(c − moyenne des 4 voisins), comme le site.
            let k = CGFloat(s.sharpness / 100 * 1.6)
            let f = CIFilter.convolution3X3()
            f.inputImage = image.clampedToExtent()
            f.weights = CIVector(values: [0, -k / 4, 0, -k / 4, 1 + k, -k / 4, 0, -k / 4, 0], count: 9)
            f.bias = 0
            image = (f.outputImage ?? image).cropped(to: extent)
        }

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
            if s.noiseReduction > 0 {
                let f = CIFilter.noiseReduction()
                f.inputImage = image
                f.noiseLevel = Float(s.noiseReduction / 100 * 0.06)
                f.sharpness = 0.4
                image = f.outputImage ?? image
            }
        }

        // Étape couleur
        if let cube = cubeData(for: s, dimension: options.cubeDimension) {
            let f = CIFilter.colorCubeWithColorSpace()
            f.inputImage = image
            f.cubeDimension = Float(options.cubeDimension)
            f.cubeData = cube
            f.colorSpace = sRGB
            image = f.outputImage ?? image
        }

        // Effets, en sRGB encodé comme sur le site.
        if s.vignette != 0 || s.grain > 0 {
            image = applyEffects(s, to: image, extent: extent, options: options)
        }
        return image.cropped(to: extent)
    }

    private func applyEffects(_ s: DevelopSettings, to image: CIImage, extent: CGRect, options: Options) -> CIImage {
        let longest = max(extent.width, extent.height)
        let full = options.fullResolutionDimension ?? longest
        // Taille du grain en pixels de pleine résolution (règle du site), ramenée à l'aperçu.
        let grainPixels = s.grainSize * max(1, Double(full) / 2400) * Double(longest / max(full, 1))
        return runEffectsKernel(image, extent: extent, vignette: s.vignette / 100, grain: s.grain / 100,
                                grainSize: max(grainPixels, 0.5), clip: false)
    }

    /// Alerte d'écrêtage de l'aperçu : rouge pour les blancs brûlés, bleu pour les noirs bouchés.
    func clippingOverlay(_ image: CIImage) -> CIImage {
        runEffectsKernel(image, extent: image.extent, vignette: 0, grain: 0, grainSize: 1, clip: true)
    }

    private func runEffectsKernel(_ image: CIImage, extent: CGRect, vignette: Double, grain: Double,
                                  grainSize: Double, clip: Bool) -> CIImage {
        guard let kernel = effectsKernel else { return image }
        let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
        let arguments: [Any] = [
            encoded,
            CIVector(x: extent.minX, y: extent.minY, z: extent.width, w: extent.height),
            Float(vignette),
            Float(grain),
            Float(grainSize),
            Float(clip ? 1 : 0),
        ]
        guard let output = kernel.apply(extent: extent, arguments: arguments) else { return image }
        return output.applyingFilter("CISRGBToneCurveToLinear")
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
        k.vignette = 0
        k.grain = 0
        k.grainSize = 1.5
        k.sharpness = 0
        k.noiseReduction = 0
        k.crop = CropSettings()
        return k
    }

    /// Taille de sortie d'un cadrage pour une source de cette taille.
    static func outputSize(_ crop: CropSettings, source: CGSize) -> CGSize {
        let g = FrameGeometry(crop: crop, sourceWidth: source.width, sourceHeight: source.height)
        return CGSize(width: g.width, height: g.height)
    }

    private func applyGeometry(_ crop: CropSettings, to input: CIImage) -> CIImage {
        let extent = input.extent
        let image = input.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        guard !crop.isNeutral else { return image }
        let g = FrameGeometry(crop: crop, sourceWidth: extent.width, sourceHeight: extent.height)
        let t = g.sourceToOutput(sourceWidth: extent.width, sourceHeight: extent.height)
        let transform = CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty)
        // Bords prolongés : l'interpolation ne fait pas entrer de pixels transparents.
        return image.clampedToExtent()
            .transformed(by: transform, highQualityDownsample: true)
            .cropped(to: CGRect(x: 0, y: 0, width: g.width, height: g.height))
    }
}
