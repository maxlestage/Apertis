@preconcurrency import AVFoundation
@preconcurrency import CoreImage
import UIKit
import ApertisCore

// Les outils qui font d'Apertis un appareil photo pro, absents de l'appareil photo d'Apple :
// aides à la visée (peaking, zébras, fausses couleurs, loupe), cellule, bracketing,
// pose longue par empilement, intervallomètre, balance des blancs sur charte grise,
// traitement minimal, priorités de l'automatisme, cadres de visée, réglages C1 à C3.

/// Image calculée hors du fil principal et affichée par SwiftUI.
struct OverlayImage: @unchecked Sendable, Equatable {
    let image: CGImage
    static func == (a: OverlayImage, b: OverlayImage) -> Bool { a.image === b.image }
}

/// Aides à la visée affichées par-dessus le viseur.
struct AssistSettings: Equatable, Sendable {
    var focusPeaking = false
    /// Sensibilité du peaking : seuil de contraste des contours (plus bas = plus de contours).
    var peakingThreshold: Float = 0.22
    var zebras = false
    /// Niveau des zébras, en part de la luminance (0,95 ≈ 95 IRE).
    var zebraLevel: Float = 0.95
    var falseColor = false
    /// Loupe de mise au point : grossissement d'une zone autour du point touché.
    var loupe = false

    var needsOverlay: Bool { focusPeaking || zebras || falseColor }
}

/// Ce que lit l'analyse du viseur sur `histogramQueue`.
struct AnalysisConfig: @unchecked Sendable {
    var assist = AssistSettings()
    var device: AVCaptureDevice?
    /// Centre de la loupe dans le viseur (0…1, origine en haut à gauche).
    var loupeCenter = CGPoint(x: 0.5, y: 0.5)
    /// Mesure du blanc demandée à cet endroit du viseur.
    var whitePoint: CGPoint?
}

/// Priorités de l'automatisme d'exposition (iOS 27, `AVCaptureDeviceExposureSignal`).
enum ExposureSignalOption: String, CaseIterable, Identifiable, Sendable, Hashable {
    case flicker, starburst, subjectMotion, groupPhoto, document

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flicker: return "Anti-scintillement"
        case .starburst: return "Sans étoiles de diffraction"
        case .subjectMotion: return "Sujet en mouvement"
        case .groupPhoto: return "Photo de groupe"
        case .document: return "Document"
        }
    }

    var detail: String {
        switch self {
        case .flicker: return "Évite les bandes sous les éclairages artificiels."
        case .starburst: return "Ouvre le diaphragme pour adoucir les points lumineux."
        case .subjectMotion: return "Ferme ou raccourcit la pose pour figer le mouvement."
        case .groupPhoto: return "Ferme le diaphragme pour que tous les visages soient nets."
        case .document: return "Ferme le diaphragme pour la netteté des textes."
        }
    }
}

/// Réglages personnels C1 à C3, conservés sur l'appareil.
enum CameraPresetStore {
    private static let key = "camera.presets"

    static func load() -> [CameraPreset] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let presets = try? JSONDecoder().decode([CameraPreset].self, from: data) else { return [] }
        return presets.sorted { $0.slot < $1.slot }
    }

    static func save(_ presets: [CameraPreset]) {
        if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: key) }
    }
}

extension CameraController {
    // MARK: Réglages des outils (fil principal)

    func setDrive(_ mode: DriveMode) {
        guard intervalShots == nil, longExposureProgress == nil else { return }
        drive = mode
    }

    func setBracketing(_ value: Bracketing) { bracketing = value }
    func setLongExposure(_ value: LongExposure) { longExposure = value }
    func setIntervalometer(_ value: Intervalometer) { intervalometer = value }
    func setMinimalProcessing(_ value: Bool) { minimalProcessing = value }
    func setFrameGuide(_ aspect: Int) { frameGuide = aspect }

    func setAssist(_ value: AssistSettings) {
        assist = value
        analysisLock.withLock { analysisConfig.assist = value }
        if !value.needsOverlay { assistOverlay = nil }
        if !value.loupe { loupe = nil }
    }

    /// Le prochain toucher dans le viseur mesure le blanc (charte grise, mur blanc, feuille).
    func beginWhiteMeasurement() { measuringWhite = true }
    func cancelWhiteMeasurement() { measuringWhite = false }

    static func supportedSignals(of device: AVCaptureDevice) -> [ExposureSignalOption] {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            let supported = device.supportedExposureSignals
            return ExposureSignalOption.allCases.filter { supported.contains($0.signal) }
        }
        #endif
        return []
    }

    /// `nil` : l'automatisme choisit seul ; sinon la liste exacte des priorités (sessionQueue).
    func applyExposureSignals(_ signals: Set<ExposureSignalOption>?, to device: AVCaptureDevice) {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *), !device.supportedExposureSignals.isEmpty {
            if let signals {
                device.automaticallyEnablesExposureSignals = false
                device.enabledExposureSignals = Set(signals.map(\.signal)).intersection(device.supportedExposureSignals)
            } else {
                device.automaticallyEnablesExposureSignals = true
            }
        }
        #endif
    }

    // MARK: Bracketing

    /// Plusieurs vues décalées autour de l'exposition : RAW si choisi (sinon HEIF), une
    /// photo par vue. En manuel, la vitesse varie ; sinon la correction d'exposition.
    func captureBracket() {
        let angle = captureRotationAngle
        let raw = rawMode
        let guide = frameGuide
        let manual = program == .manual
        let (shutter, iso, bracket) = (self.shutter, self.iso, self.bracketing)
        sessionQueue.async {
            let output = self.photoOutput
            guard let device = self.videoInput?.device, output.maxBracketedCapturePhotoCount > 1 else {
                self.publish { self.status = .failed("Le bracketing n'est pas disponible avec cet objectif.") }
                return
            }
            let biases = bracket.biases(maxCount: output.maxBracketedCapturePhotoCount,
                                        range: device.minExposureTargetBias...device.maxExposureTargetBias)
            let format = device.activeFormat
            let items: [AVCaptureBracketedStillImageSettings] = biases.map { bias in
                if manual {
                    let seconds = min(max(shutter * Double(exp2(bias)), format.minExposureDuration.seconds), format.maxExposureDuration.seconds)
                    return AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(
                        exposureDuration: CMTime(seconds: seconds, preferredTimescale: 1_000_000),
                        iso: min(max(iso, format.minISO), format.maxISO))
                }
                return AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(exposureTargetBias: bias)
            }
            // Le bracketing accepte le RAW Bayer, pas le ProRAW : on retombe sur le HEIF.
            let bayer = raw == .off ? nil : output.availableRawPhotoPixelFormatTypes.first(where: AVCapturePhotoOutput.isBayerRAWPixelFormat)
            let processed: [String: Any]? = bayer == nil
                ? (output.availablePhotoCodecTypes.contains(.hevc) ? [AVVideoCodecKey: AVVideoCodecType.hevc] : [AVVideoCodecKey: AVVideoCodecType.jpeg])
                : nil
            let settings = AVCapturePhotoBracketSettings(rawPixelFormatType: bayer ?? 0, processedFormat: processed,
                                                         bracketedSettings: items)
            settings.isLensStabilizationEnabled = output.isLensStabilizationDuringBracketedCaptureSupported
            if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            let id = settings.uniqueID
            let notes = biases.map { "Bracketing " + ($0 == 0 ? "0 IL" : ExposureMeter.label(offset: $0) + " IL") }
            let delegate = BracketCaptureDelegate(notes: notes, cropAspect: guide,
                                                  processedExtension: processed?[AVVideoCodecKey] as? AVVideoCodecType == .hevc ? "heic" : "jpg") { photos in
                self.sessionQueue.async { self.bracketDelegates[id] = nil }
                DispatchQueue.main.async {
                    if photos.isEmpty { self.status = .failed("Le bracketing a échoué.") }
                    for photo in photos { self.onPhotoCaptured?(photo) }
                }
            }
            self.bracketDelegates[id] = delegate
            output.capturePhoto(with: settings, delegate: delegate)
        }
    }

    // MARK: Pose longue

    /// Empile les images du capteur pendant la durée choisie. L'exposition est verrouillée
    /// pendant la pose pour que chaque image ait le même rendu.
    func startLongExposure() {
        guard longExposureProgress == nil, mode == .photo else { return }
        longExposureProgress = 0
        let pose = longExposure
        let guide = frameGuide
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            if (try? device.lockForConfiguration()) != nil {
                if device.isExposureModeSupported(.locked), device.exposureMode != .custom { device.exposureMode = .locked }
                device.unlockForConfiguration()
            }
            let frameRate = 1 / max(device.activeVideoMinFrameDuration.seconds, 1.0 / 240)
            let count = pose.frameCount(frameRate: frameRate)
            self.histogramQueue.async {
                self.stack = LongExposureStack(style: pose.style, frameCount: count, cropAspect: guide,
                                               note: "Pose longue \(CameraFormat.shutter(pose.duration))")
            }
        }
    }

    /// Fin de l'empilement (histogramQueue) : enregistre la photo et rend l'exposition.
    func finishLongExposure(_ stack: LongExposureStack) {
        let capture = stack.render()
        sessionQueue.async { self.applyHardware() }
        publish {
            self.longExposureProgress = nil
            if let capture { self.onPhotoCaptured?(capture) } else { self.status = .failed("La pose longue a échoué.") }
        }
    }

    // MARK: Intervallomètre

    @MainActor
    func startIntervalometer() {
        guard intervalShots == nil else { return }
        let plan = intervalometer
        intervalShots = 0
        UIApplication.shared.isIdleTimerDisabled = true
        capturePhoto()
        intervalShots = 1
        intervalTimer = Timer.scheduledTimer(withTimeInterval: plan.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let shots = self.intervalShots else { return }
                if plan.count > 0 && shots >= plan.count {
                    self.stopIntervalometer()
                    return
                }
                // Une photo encore en traitement : on attend l'intervalle suivant plutôt que de la perdre.
                guard !self.isCaptureBlocked else { return }
                self.capturePhoto()
                self.intervalShots = shots + 1
            }
        }
    }

    @MainActor
    func stopIntervalometer() {
        intervalTimer?.invalidate()
        intervalTimer = nil
        intervalShots = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: Réglages personnels

    func savePreset(slot: Int, name: String) {
        let preset = CameraPreset(slot: slot, name: name.isEmpty ? "C\(slot)" : name, program: program, aperture: aperture,
                                  shutter: shutter, iso: iso, isoAuto: isoAuto, exposureBias: exposureBias,
                                  manualWhiteBalance: manualWhiteBalance, kelvin: kelvin, tint: whiteBalanceTint,
                                  rawMode: rawMode.rawValue, megapixels: photoResolution.map { Int($0.megapixels.rounded()) },
                                  focalLength: focalStops.first { $0.lens == lens && abs($0.zoom - zoomFactor) < 0.05 }?.focalLength,
                                  drive: drive, frameGuide: frameGuide, minimalProcessing: minimalProcessing)
        presets.removeAll { $0.slot == slot }
        presets.append(preset)
        presets.sort { $0.slot < $1.slot }
        CameraPresetStore.save(presets)
    }

    func deletePreset(slot: Int) {
        presets.removeAll { $0.slot == slot }
        CameraPresetStore.save(presets)
    }

    /// Rappelle un réglage : ce que l'objectif actuel ne sait pas faire est ignoré.
    func applyPreset(_ preset: CameraPreset) {
        if let stop = focalStops.first(where: { $0.focalLength == preset.focalLength }) { selectFocal(stop) }
        if let raw = RAWMode(rawValue: preset.rawMode) { setRAWMode(raw) }
        if let mp = preset.megapixels, let resolution = photoResolutions.first(where: { Int($0.megapixels.rounded()) == mp }) {
            setPhotoResolution(resolution)
        }
        drive = preset.drive
        frameGuide = preset.frameGuide
        minimalProcessing = preset.minimalProcessing
        let program = programs.contains(preset.program) ? preset.program : .program
        updateHardware {
            $0.program = program
            $0.aperture = preset.aperture
            $0.shutter = preset.shutter
            $0.iso = preset.iso
            $0.isoAuto = preset.isoAuto
            $0.bias = preset.exposureBias
            $0.manualWhiteBalance = preset.manualWhiteBalance
            $0.kelvin = preset.kelvin
            $0.tint = preset.tint
        }
    }
}

// MARK: - Analyse du viseur

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Contexte sans gestion des couleurs : les aides lisent les valeurs affichées.
    static let assistContext = CIContext(options: [
        .workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false,
    ])

    private static let assistKernel: CIColorKernel? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? CIColorKernel(functionName: "apertisAssist", fromMetalLibraryData: data)
    }()

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Pose longue : chaque image compte.
        if let stack {
            let done = stack.add(buffer)
            let progress = stack.progress
            publish { self.longExposureProgress = progress }
            if done {
                self.stack = nil
                finishLongExposure(stack)
            }
            return
        }
        analysisFrame += 1
        let config = analysisLock.withLock { () -> AnalysisConfig in
            let current = analysisConfig
            analysisConfig.whitePoint = nil
            return current
        }
        if analysisFrame % 5 == 0 {
            let histogram = Histogram(bgra: buffer)
            publish { self.liveHistogram = histogram }
        }
        let needsImage = config.assist.needsOverlay || config.assist.loupe || config.whitePoint != nil
        let image = needsImage ? CIImage(cvPixelBuffer: buffer) : nil
        if let image, config.assist.needsOverlay, analysisFrame % 2 == 0 {
            let overlay = Self.assistOverlay(for: image, settings: config.assist)
            publish { self.assistOverlay = overlay }
        }
        if let image, config.assist.loupe, analysisFrame % 2 == 1 {
            let loupe = Self.loupe(of: image, center: config.loupeCenter)
            publish { self.loupe = loupe }
        }
        if let image, let point = config.whitePoint { measureWhite(in: image, at: point) }
        if analysisFrame % 6 == 0, let device = config.device { updateMeter(device) }
    }

    /// Fausses couleurs, zébras et peaking sur une image réduite du viseur.
    static func assistOverlay(for image: CIImage, settings: AssistSettings) -> OverlayImage? {
        guard let kernel = assistKernel else { return nil }
        let scale = min(1, 720 / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Bords prolongés : sans cela, le cadre de l'image serait pris pour un contour.
        let edges = small.clampedToExtent().applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 3]).cropped(to: small.extent)
        let options = CIVector(x: settings.falseColor ? 1 : 0,
                               y: CGFloat(settings.zebras ? settings.zebraLevel : 0),
                               z: CGFloat(settings.focusPeaking ? settings.peakingThreshold : 0),
                               w: 4)
        guard let output = kernel.apply(extent: small.extent, arguments: [small, edges, options]),
              let cg = assistContext.createCGImage(output, from: small.extent, format: .RGBA8,
                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        return OverlayImage(image: cg)
    }

    /// Loupe : un sixième du cadre autour du point de mise au point, grossi.
    private static func loupe(of image: CIImage, center: CGPoint) -> OverlayImage? {
        let extent = image.extent
        let side = min(extent.width, extent.height) / 6
        let x = min(max(extent.minX + center.x * extent.width - side / 2, extent.minX), extent.maxX - side)
        let y = min(max(extent.minY + (1 - center.y) * extent.height - side / 2, extent.minY), extent.maxY - side)
        let rect = CGRect(x: x, y: y, width: side, height: side)
        guard let cg = assistContext.createCGImage(image.cropped(to: rect), from: rect, format: .RGBA8,
                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        return OverlayImage(image: cg)
    }

    /// Balance des blancs sur charte grise : la zone touchée devient neutre.
    private func measureWhite(in image: CIImage, at point: CGPoint) {
        let extent = image.extent
        let side = max(8, min(extent.width, extent.height) * 0.04)
        let rect = CGRect(x: extent.minX + point.x * extent.width - side / 2,
                          y: extent.minY + (1 - point.y) * extent.height - side / 2, width: side, height: side)
            .intersection(extent)
        var pixel = [Float](repeating: 0, count: 4)
        let average = image.cropped(to: rect).applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
        Self.assistContext.render(average, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                  format: .RGBAf, colorSpace: nil)
        // Valeurs affichées (sRGB, BGRA déjà converti par Core Image) → lumière linéaire.
        let measured = (r: ColorMath.srgbToLinear(pixel[0]), g: ColorMath.srgbToLinear(pixel[1]), b: ColorMath.srgbToLinear(pixel[2]))
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            let current = device.deviceWhiteBalanceGains
            guard let gains = WhiteBalanceGains.neutralizing(measured, current: WhiteBalanceGains(red: current.redGain, green: current.greenGain,
                                                                                                  blue: current.blueGain),
                                                             maxGain: device.maxWhiteBalanceGain) else {
                self.publish { self.status = .failed("Mesure du blanc impossible : visez une surface grise ou blanche bien éclairée.") }
                return
            }
            let values = device.temperatureAndTintValues(for: AVCaptureDevice.WhiteBalanceGains(redGain: gains.red, greenGain: gains.green,
                                                                                               blueGain: gains.blue))
            self.publish { self.setManualWhiteBalance(true, kelvin: values.temperature, tint: values.tint) }
        }
    }

    /// Cellule : écart de mesure et indice de lumination de la scène.
    private func updateMeter(_ device: AVCaptureDevice) {
        let offset = device.exposureTargetOffset
        let duration = device.exposureDuration.seconds
        let iso = device.iso
        let aperture = device.lensAperture
        guard duration > 0, iso > 0, offset.isFinite else { return }
        let ev = CameraFormat.exposureValue(aperture: aperture, duration: duration, iso: iso) + Double(offset)
        publish {
            self.meterOffset = offset
            self.sceneEV = ev
        }
    }
}

#if compiler(>=6.4)
@available(iOS 27.0, *)
extension ExposureSignalOption {
    var signal: AVCaptureDeviceExposureSignal {
        switch self {
        case .flicker: return .flicker
        case .starburst: return .starburst
        case .subjectMotion: return .subjectMotion
        case .groupPhoto: return .groupPhoto
        case .document: return .document
        }
    }
}
#endif

/// Empilement des images d'une pose longue, en lumière linéaire et en demi-flottants.
final class LongExposureStack: @unchecked Sendable {
    let style: LongExposureStyle
    let frameCount: Int
    let cropAspect: Int
    let note: String
    private var accumulator: CIImageAccumulator?
    private var added = 0

    init(style: LongExposureStyle, frameCount: Int, cropAspect: Int, note: String) {
        self.style = style
        self.frameCount = frameCount
        self.cropAspect = cropAspect
        self.note = note
    }

    var progress: Double { Double(added) / Double(frameCount) }

    /// Ajoute une image ; renvoie vrai quand la pose est complète.
    func add(_ buffer: CVPixelBuffer) -> Bool {
        let frame = CIImage(cvPixelBuffer: buffer)
        if accumulator == nil {
            accumulator = CIImageAccumulator(extent: frame.extent, format: .RGBAh)
            accumulator?.setImage(frame)
        } else if let accumulator {
            let filter = style == .motionBlur ? "CIAdditionCompositing" : "CIMaximumCompositing"
            accumulator.setImage(frame.applyingFilter(filter, parameters: [kCIInputBackgroundImageKey: accumulator.image()]))
        }
        added += 1
        return added >= frameCount
    }

    /// Photo finale en HEIF : moyenne (filé) ou maximum (traînées lumineuses).
    func render() -> CapturedPhoto? {
        guard let accumulator, added > 0 else { return nil }
        var image = accumulator.image()
        if style == .motionBlur {
            let k = CGFloat(1) / CGFloat(added)
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        }
        guard let p3 = CGColorSpace(name: CGColorSpace.displayP3),
              let data = GradeRenderer.shared.context.heifRepresentation(of: image, format: .RGBA8, colorSpace: p3,
                                                                         options: [:]) else { return nil }
        return CapturedPhoto(processedData: data, processedExtension: "heic", cropAspect: cropAspect, note: note)
    }
}

/// Reçoit les vues d'un bracketing : une photo enregistrée par vue.
final class BracketCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let notes: [String]
    private let cropAspect: Int
    private let processedExtension: String
    private var photos: [CapturedPhoto] = []
    private let completion: ([CapturedPhoto]) -> Void

    init(notes: [String], cropAspect: Int, processedExtension: String, completion: @escaping ([CapturedPhoto]) -> Void) {
        self.notes = notes
        self.cropAspect = cropAspect
        self.processedExtension = processedExtension
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        let index = photo.photoCount - 1
        var capture = CapturedPhoto(processedExtension: processedExtension, cropAspect: cropAspect,
                                    note: notes.indices.contains(index) ? notes[index] : "Bracketing")
        if photo.isRawPhoto { capture.rawData = data } else { capture.processedData = data }
        photos.append(capture)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        completion(photos)
    }
}
