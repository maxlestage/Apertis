@preconcurrency import AVFoundation
import UIKit
import ApertisCore

/// Pilote la caméra avec AVFoundation, sur iPhone et iPad.
///
/// Toute la configuration matérielle s'exécute sur `sessionQueue` ; les propriétés publiées
/// sont mises à jour sur le fil principal. Les choix proposés à l'interface proviennent des
/// formats réellement exposés par l'appareil : un réglage absent du matériel n'est jamais montré.
///
/// Selon le système : prise de vue réactive et orientation (iOS 17), bouton Commande de
/// l'appareil photo (iOS 18), focale 24×36 et détection d'objectif sale (iOS 26), diaphragme
/// variable de l'iPhone 18 Pro, modes priorité et suivi du sujet (iOS 27).
final class CameraController: NSObject, ObservableObject, @unchecked Sendable {
    enum Mode: String, CaseIterable, Identifiable {
        case photo, video
        var id: String { rawValue }
        var label: String { self == .photo ? "Photo" : "Vidéo" }
    }

    enum RAWMode: String, CaseIterable, Identifiable {
        case off, bayer, proRAW
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "HEIF"
            case .bayer: return "RAW"
            case .proRAW: return "ProRAW"
            }
        }
    }

    enum Status: Equatable {
        case starting, ready, unauthorized, failed(String)
    }

    // MARK: État publié

    @Published var status: Status = .starting
    @Published private(set) var mode: Mode = .photo
    @Published private(set) var capabilities = CaptureCapabilities()
    @Published private(set) var lens: LensKind = .wide
    @Published private(set) var rawMode: RAWMode = .off
    @Published private(set) var videoMode: VideoMode?
    @Published private(set) var codec: VideoCodec = .hevc
    @Published private(set) var isRecording = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    /// Niveau audio moyen en dBFS pendant l'enregistrement.
    @Published private(set) var audioLevel: Float = -160
    /// Vrai tant que l'appareil ne peut pas prendre la photo suivante (prise de vue réactive).
    @Published private(set) var isCaptureBlocked = false

    // Focales et définition
    @Published private(set) var focalStops: [FocalStop] = []
    @Published private(set) var mainFocalLength: Double = 24
    @Published private(set) var zoomFactor: Double = 1
    @Published private(set) var zoomRange: ClosedRange<Double> = 1...1
    @Published private(set) var photoResolutions: [PhotoResolution] = []
    @Published private(set) var photoResolution: PhotoResolution?

    // Exposition
    @Published private(set) var programs: [ExposureProgram] = [.program]
    @Published private(set) var program: ExposureProgram = .program
    @Published private(set) var isoRange: ClosedRange<Float> = 25...3200
    @Published private(set) var shutterRange: ClosedRange<Double> = (1.0 / 8000)...(1.0 / 2)
    @Published private(set) var biasRange: ClosedRange<Float> = -3...3
    @Published private(set) var apertureRange: ClosedRange<Float> = 1.8...1.8
    /// Ouvertures conseillées par le système (iPhone 18 Pro : ƒ/1.48, ƒ/1.8, ƒ/2.8, ƒ/4).
    @Published private(set) var apertureStops: [Float] = []
    @Published private(set) var iso: Float = 100
    @Published private(set) var isoAuto = false
    @Published private(set) var shutter: Double = 1.0 / 60
    @Published private(set) var aperture: Float = 1.8
    @Published private(set) var exposureBias: Float = 0

    // Balance des blancs et mise au point
    @Published private(set) var manualWhiteBalance = false
    @Published private(set) var kelvin: Float = 5500
    @Published private(set) var whiteBalanceTint: Float = 0
    @Published private(set) var supportsManualFocus = false
    @Published private(set) var manualFocus = false
    @Published private(set) var lensPosition: Float = 0.5
    @Published private(set) var supportsSubjectTracking = false
    @Published private(set) var subjectTracking = false
    /// -1 : partie la plus proche du sujet nette, +1 : la plus lointaine.
    @Published private(set) var trackingBias: Float = 0
    @Published private(set) var stabilization = true
    /// Verrouillage exposition + balance des blancs (évite les variations en cours de plan).
    @Published private(set) var aeAwbLocked = false

    // Aides à la prise de vue
    @Published var liveHistogram: Histogram?
    @Published private(set) var isLensSmudged = false
    /// Le bouton Commande de l'appareil photo affiche ses réglages en plein écran.
    @Published private(set) var systemControlsFullscreen = false

    // Outils que l'appareil photo d'Apple ne propose pas
    @Published var drive: DriveMode = .single
    @Published var bracketing = Bracketing()
    @Published var maxBracketCount = 0
    @Published var longExposure = LongExposure()
    /// Avancement de la pose longue en cours (0…1).
    @Published var longExposureProgress: Double?
    @Published var intervalometer = Intervalometer()
    /// Photos prises dans la série d'intervalles en cours.
    @Published var intervalShots: Int?
    /// Sans fusion multi-images (Smart HDR, Deep Fusion) : rendu naturel, plus rapide.
    @Published var minimalProcessing = false
    /// Cadre de visée (index dans `CropSettings.aspects`, 0 = aucun).
    @Published var frameGuide = 0
    @Published var assist = AssistSettings()
    @Published var assistOverlay: OverlayImage?
    @Published var loupe: OverlayImage?
    /// Cellule : écart entre la mesure et l'exposition réglée, en IL.
    @Published var meterOffset: Float = 0
    /// Indice de lumination de la scène (EV à 100 ISO).
    @Published var sceneEV: Double?
    /// Le prochain toucher mesure le blanc sur une charte grise au lieu de faire la mise au point.
    @Published var measuringWhite = false
    /// Priorités de l'automatisme d'exposition (iOS 27) ; nil = choix du système.
    @Published var supportedSignals: [ExposureSignalOption] = []
    @Published var customSignals: Set<ExposureSignalOption>?
    @Published var presets: [CameraPreset] = CameraPresetStore.load()

    /// Outils de boîtier débloqués par Apertis Pro (lu et écrit sur le fil principal).
    private(set) var proUnlocked = false
    /// Appelé sur le fil principal quand un outil Pro est demandé sans abonnement.
    var onProRequired: (@MainActor (ProFeature) -> Void)?

    /// Appelé sur le fil principal pour chaque photo enregistrée.
    var onPhotoCaptured: ((CapturedPhoto) -> Void)?
    /// Appelé sur le fil principal avec le fichier temporaire de la vidéo.
    var onMovieRecorded: ((URL) -> Void)?

    // MARK: AVFoundation

    let session = AVCaptureSession()
    let sessionQueue = DispatchQueue(label: "fr.apertis.camera.session")
    let histogramQueue = DispatchQueue(label: "fr.apertis.camera.histogram", qos: .utility)
    private var devices: [LensKind: AVCaptureDevice] = [:]
    var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let analysisOutput = AVCaptureVideoDataOutput()
    var readiness: AVCapturePhotoOutputReadinessCoordinator?
    var photoDelegates: [Int64: PhotoCaptureDelegate] = [:]
    var bracketDelegates: [Int64: BracketCaptureDelegate] = [:]
    private var bayerRAWSupported = false
    private var recordingTimer: Timer?
    private var recordingStart: Date?
    private var isConfigured = false
    var analysisFrame = 0
    private var observations: [NSKeyValueObservation] = []
    /// État lu par l'analyse du viseur (`histogramQueue`), protégé par `analysisLock`.
    let analysisLock = NSLock()
    var analysisConfig = AnalysisConfig()
    /// Pose longue en cours d'empilement (`histogramQueue` uniquement).
    var stack: LongExposureStack?
    var intervalTimer: Timer?
    private var notificationTokens: [NSObjectProtocol] = []

    /// Orientation de l'aperçu et des photos (fil principal).
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    // MARK: Cycle de vie

    func start() {
        Task {
            guard await Self.requestAccess(for: .video) else {
                await MainActor.run { self.status = .unauthorized }
                return
            }
            _ = await Self.requestAccess(for: .audio)
            sessionQueue.async {
                if !self.isConfigured {
                    self.configureSession()
                    self.isConfigured = true
                }
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
        observeExternalCameras()
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private static func requestAccess(for type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }

    func publish(_ update: @escaping @Sendable () -> Void) {
        DispatchQueue.main.async(execute: update)
    }

    /// Caméras USB-C de l'iPad (et Continuity Camera) : branchées ou débranchées en direct.
    private func observeExternalCameras() {
        guard notificationTokens.isEmpty else { return }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            notificationTokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.sessionQueue.async { self.refreshDevices() }
            })
        }
    }

    // MARK: Configuration (sessionQueue)

    private func configureSession() {
        devices = Self.discoverDevices()
        guard !devices.isEmpty else {
            publish { self.status = .failed("Aucune caméra disponible.") }
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        photoOutput.maxPhotoQualityPrioritization = .quality
        // Prise de vue réactive : la photo suivante peut commencer pendant le traitement de la précédente.
        if photoOutput.isResponsiveCaptureSupported {
            photoOutput.isResponsiveCaptureEnabled = true
            photoOutput.isFastCapturePrioritizationEnabled = photoOutput.isFastCapturePrioritizationSupported
        }
        configureAnalysisOutput()
        let initialLens: LensKind = devices[.wide] != nil ? .wide : devices.keys.sorted().first!
        setInput(lens: initialLens)
        session.commitConfiguration()

        let coordinator = AVCapturePhotoOutputReadinessCoordinator(photoOutput: photoOutput)
        coordinator.delegate = self
        readiness = coordinator
        if #available(iOS 18.0, *) { configureSystemControls() }

        bayerRAWSupported = photoOutput.availableRawPhotoPixelFormatTypes.contains { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
        let capabilities = buildCapabilities()
        let stops = focalStopsForDevices()
        publish {
            self.capabilities = capabilities
            self.focalStops = stops.stops
            self.mainFocalLength = stops.main
            self.lens = initialLens
            self.videoMode = capabilities.resolve(VideoModeQuery(lens: initialLens, resolution: Resolution(width: 3840, height: 2160),
                                                                  frameRate: 30, profile: .sdr))
            self.status = .ready
        }
    }

    /// Analyse de l'image en direct (histogramme), en mode photo uniquement.
    private func configureAnalysisOutput() {
        analysisOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        analysisOutput.alwaysDiscardsLateVideoFrames = true
        analysisOutput.setSampleBufferDelegate(self, queue: histogramQueue)
        if session.canAddOutput(analysisOutput) { session.addOutput(analysisOutput) }
    }

    private static func discoverDevices() -> [LensKind: AVCaptureDevice] {
        // `.external` : caméras USB-C branchées sur un iPad.
        let types: [AVCaptureDevice.DeviceType] = [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera,
                                                   .builtInTrueDepthCamera, .external]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        var result: [LensKind: AVCaptureDevice] = [:]
        for device in discovery.devices {
            switch (device.deviceType, device.position) {
            case (.builtInUltraWideCamera, .back): result[.ultraWide] = device
            case (.builtInWideAngleCamera, .back): result[.wide] = device
            case (.builtInTelephotoCamera, .back): result[.telephoto] = device
            // Caméra avant : grand-angle, sinon ultra grand-angle Center Stage (iPad) ou TrueDepth.
            case (.builtInWideAngleCamera, .front): result[.front] = device
            case (.builtInUltraWideCamera, .front), (.builtInTrueDepthCamera, .front):
                if result[.front] == nil { result[.front] = device }
            case (.external, _):
                if result[.external] == nil { result[.external] = device }
            default: break
            }
        }
        return result
    }

    /// Une caméra externe a été branchée ou débranchée.
    private func refreshDevices() {
        guard isConfigured else { return }
        let found = Self.discoverDevices()
        guard Set(found.keys) != Set(devices.keys) else { return }
        devices = found
        let current = videoInput?.device
        if current == nil || !found.values.contains(current!) {
            session.beginConfiguration()
            setInput(lens: found[.wide] != nil ? .wide : found.keys.sorted().first ?? .wide)
            session.commitConfiguration()
        }
        let capabilities = buildCapabilities()
        let stops = focalStopsForDevices()
        let lens = devices.first { $0.value == videoInput?.device }?.key ?? .wide
        publish {
            self.capabilities = capabilities
            self.focalStops = stops.stops
            self.mainFocalLength = stops.main
            self.lens = lens
        }
        if #available(iOS 18.0, *) { configureSystemControls() }
    }

    private func setInput(lens: LensKind) {
        guard let device = devices[lens], let input = try? AVCaptureDeviceInput(device: device) else { return }
        if let videoInput { session.removeInput(videoInput) }
        if session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
        } else if let videoInput, session.canAddInput(videoInput) {
            session.addInput(videoInput)
            return
        }
        let sizes = device.activeFormat.supportedMaxPhotoDimensions
        if let largest = sizes.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            photoOutput.maxPhotoDimensions = largest
        }
        enableLensSmudgeDetection(device)
        orientAnalysisOutput()
        publishDeviceRanges(device)
        publish { self.attachRotationCoordinator(to: device) }
    }

    private func publishDeviceRanges(_ device: AVCaptureDevice) {
        let format = device.activeFormat
        let iso = format.minISO...format.maxISO
        let shutter = format.minExposureDuration.seconds...min(format.maxExposureDuration.seconds, 1)
        let bias = device.minExposureTargetBias...device.maxExposureTargetBias
        let manualFocus = device.isLockingFocusWithCustomLensPositionSupported
        let custom = device.isExposureModeSupported(.custom)
        let zoom = Double(device.minAvailableVideoZoomFactor)...Double(min(device.maxAvailableVideoZoomFactor, 15))
        let currentZoom = Double(device.videoZoomFactor)
        let resolutions = PhotoResolution.options(format.supportedMaxPhotoDimensions.map {
            PhotoResolution(width: Int($0.width), height: Int($0.height))
        })
        var apertures = Float(device.lensAperture)...Float(device.lensAperture)
        var stops: [Float] = []
        var tracking = false
        var priorityModes = false
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            priorityModes = true
            apertures = format.minLensAperture...max(format.maxLensAperture, format.minLensAperture)
            stops = format.minLensAperture < format.maxLensAperture ? format.recommendedLensApertureStops : []
            tracking = format.isContinuousAutoFocusTrackingSupported
        }
        #endif
        let variable = apertures.lowerBound < apertures.upperBound
        let programs = ExposureProgram.available(variableAperture: variable, customExposure: custom, priorityModes: priorityModes)
        let defaultAperture = apertures.lowerBound
        let (apertureRange, apertureStops, trackingSupported) = (apertures, stops, tracking)
        let bracketCount = photoOutput.maxBracketedCapturePhotoCount
        let signals = Self.supportedSignals(of: device)
        analysisLock.withLock { analysisConfig.device = device }
        publish {
            let (apertures, stops, tracking) = (apertureRange, apertureStops, trackingSupported)
            self.isoRange = iso
            self.shutterRange = shutter
            self.biasRange = bias
            self.supportsManualFocus = manualFocus
            self.zoomRange = zoom
            self.zoomFactor = currentZoom
            self.apertureRange = apertures
            self.apertureStops = stops
            if !variable || !apertures.contains(self.aperture) { self.aperture = defaultAperture }
            self.programs = programs
            if !programs.contains(self.program) { self.program = .program }
            self.supportsSubjectTracking = tracking
            if !tracking { self.subjectTracking = false }
            self.maxBracketCount = bracketCount
            self.supportedSignals = signals
            self.photoResolutions = resolutions
            if let current = self.photoResolution, resolutions.contains(current) {} else { self.photoResolution = resolutions.last }
        }
    }

    /// Focales proposées : chaque objectif et ses recadrages 2× sans perte (capteurs 48 Mpx).
    private func focalStopsForDevices() -> (stops: [FocalStop], main: Double) {
        let lenses = devices.compactMap { kind, device -> LensDescription? in
            guard kind != .front, kind != .external else { return nil }
            var focal = FocalStops.estimatedFocalLength(kind)
            #if compiler(>=6.2)
            if #available(iOS 26.0, *), device.nominalFocalLengthIn35mmFilm > 0 { focal = Double(device.nominalFocalLengthIn35mmFilm) }
            #endif
            let largest = device.activeFormat.supportedMaxPhotoDimensions.map { Double($0.width) * Double($0.height) / 1e6 }.max() ?? 12
            return LensDescription(kind: kind, focalLength: focal, maxMegapixels: largest, maxZoom: Double(device.maxAvailableVideoZoomFactor))
        }
        let main = lenses.first { $0.kind == .wide }?.focalLength ?? 24
        return (FocalStops.make(lenses), main)
    }

    /// Détection d'objectif sale (iOS 26) : un message invite à essuyer la lentille.
    private func enableLensSmudgeDetection(_ device: AVCaptureDevice) {
        observations.removeAll()
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), device.activeFormat.isCameraLensSmudgeDetectionSupported,
           (try? device.lockForConfiguration()) != nil {
            device.setCameraLensSmudgeDetectionEnabled(true, detectionInterval: CMTime(seconds: 10, preferredTimescale: 600))
            device.unlockForConfiguration()
            observations.append(device.observe(\.cameraLensSmudgeDetectionStatus, options: [.initial, .new]) { [weak self] device, _ in
                guard let self else { return }
                let smudged = device.cameraLensSmudgeDetectionStatus == .smudged
                self.publish { self.isLensSmudged = smudged }
            })
            return
        }
        #endif
        publish { self.isLensSmudged = false }
    }

    /// Construit la matrice des capacités à partir des formats exposés par chaque objectif.
    private func buildCapabilities() -> CaptureCapabilities {
        let videoResolutions: Set<Resolution> = [
            Resolution(width: 1280, height: 720), Resolution(width: 1920, height: 1080), Resolution(width: 3840, height: 2160),
        ]
        let candidateRates = [24, 25, 30, 48, 50, 60, 100, 120, 240]
        var modes: Set<VideoMode> = []
        for (lens, device) in devices {
            for format in device.formats {
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let resolution = Resolution(width: Int(dims.width), height: Int(dims.height))
                guard videoResolutions.contains(resolution) else { continue }
                let profiles = Set(format.supportedColorSpaces.compactMap(Self.profile(for:)))
                for fps in candidateRates where format.videoSupportedFrameRateRanges.contains(where: {
                    $0.minFrameRate <= Double(fps) && Double(fps) <= $0.maxFrameRate
                }) {
                    for profile in profiles {
                        modes.insert(VideoMode(lens: lens, resolution: resolution, frameRate: fps, profile: profile))
                    }
                }
            }
        }

        // Les codecs dépendent de la sortie vidéo : on l'ajoute temporairement pour les lire.
        var codecs: [VideoCodec] = [.hevc, .h264]
        session.beginConfiguration()
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
            codecs = movieOutput.availableVideoCodecTypes.compactMap(Self.codec(for:))
            session.removeOutput(movieOutput)
        }
        session.commitConfiguration()

        let photo = PhotoCapabilities(bayerRAW: bayerRAWSupported, appleProRAW: photoOutput.isAppleProRAWSupported,
                                      heif: photoOutput.availablePhotoCodecTypes.contains(.hevc),
                                      lenses: devices.keys.sorted())
        return CaptureCapabilities(photo: photo, videoModes: modes, videoCodecs: codecs)
    }

    private static func profile(for space: AVCaptureColorSpace) -> VideoColorProfile? {
        switch space {
        case .sRGB, .P3_D65: return .sdr
        case .HLG_BT2020: return .hlg
        case .appleLog: return .appleLog
        default: return nil
        }
    }

    private static func colorSpace(for profile: VideoColorProfile) -> AVCaptureColorSpace {
        switch profile {
        case .sdr: return .sRGB
        case .hlg: return .HLG_BT2020
        case .appleLog: return .appleLog
        }
    }

    private static func codec(for type: AVVideoCodecType) -> VideoCodec? {
        switch type {
        case .hevc: return .hevc
        case .h264: return .h264
        case .proRes422: return .proRes422
        case .proRes422HQ: return .proRes422HQ
        default: return nil
        }
    }

    private static func codecType(for codec: VideoCodec) -> AVVideoCodecType {
        switch codec {
        case .hevc: return .hevc
        case .h264: return .h264
        case .proRes422: return .proRes422
        case .proRes422HQ: return .proRes422HQ
        }
    }

    // MARK: Orientation (fil principal)

    /// L'aperçu fournit sa couche : l'orientation suit l'appareil (iPhone et iPad, portrait et paysage).
    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        if let device = videoInput?.device { attachRotationCoordinator(to: device) }
    }

    private func attachRotationCoordinator(to device: AVCaptureDevice) {
        guard let previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            guard let self else { return }
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async { self.applyPreviewAngle(angle) }
        }
    }

    private func applyPreviewAngle(_ angle: CGFloat) {
        if let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        let mirrored = previewLayer?.connection?.isVideoMirrored ?? false
        sessionQueue.async {
            self.analysisOrientation = (angle, mirrored)
            self.orientAnalysisOutput()
        }
    }

    /// L'analyse du viseur reçoit des images orientées comme l'aperçu (aides et loupe superposables).
    private var analysisOrientation: (angle: CGFloat, mirrored: Bool) = (90, false)

    private func orientAnalysisOutput() {
        guard let connection = analysisOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(analysisOrientation.angle) {
            connection.videoRotationAngle = analysisOrientation.angle
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = analysisOrientation.mirrored
        }
    }

    /// Angle de capture à l'horizontale, selon l'orientation réelle de l'appareil.
    var captureRotationAngle: CGFloat {
        rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
    }

    // MARK: Commandes

    func setMode(_ newMode: Mode) {
        guard newMode != mode, !isRecording else { return }
        let target = videoMode
        mode = newMode
        sessionQueue.async {
            self.session.beginConfiguration()
            if newMode == .video {
                // L'analyse en direct ne cohabite pas avec l'enregistrement sur tous les appareils.
                if self.session.outputs.contains(self.analysisOutput) { self.session.removeOutput(self.analysisOutput) }
                self.session.sessionPreset = .inputPriority
                if self.session.canAddOutput(self.movieOutput) { self.session.addOutput(self.movieOutput) }
                if self.audioInput == nil, let mic = AVCaptureDevice.default(for: .audio),
                   let input = try? AVCaptureDeviceInput(device: mic), self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.audioInput = input
                }
            } else {
                if self.session.outputs.contains(self.movieOutput) { self.session.removeOutput(self.movieOutput) }
                if let audio = self.audioInput {
                    self.session.removeInput(audio)
                    self.audioInput = nil
                }
                self.session.sessionPreset = .photo
                if self.session.canAddOutput(self.analysisOutput) { self.session.addOutput(self.analysisOutput) }
            }
            self.session.commitConfiguration()
            if newMode == .photo { self.orientAnalysisOutput() }
            if newMode == .video, let target { self.applyVideoMode(target) }
            if let device = self.videoInput?.device { self.publishDeviceRanges(device) }
            self.publish { if newMode == .video { self.liveHistogram = nil } }
        }
    }

    func selectLens(_ newLens: LensKind) {
        selectFocal(FocalStop(lens: newLens, zoom: 1, focalLength: 0))
    }

    /// Choisit une focale : l'objectif correspondant, puis le recadrage éventuel.
    func selectFocal(_ stop: FocalStop) {
        guard !isRecording, capabilities.photo.lenses.contains(stop.lens) else { return }
        let changesLens = stop.lens != lens
        let currentMode = mode
        let desired = videoMode.map { VideoModeQuery(lens: stop.lens, resolution: $0.resolution, frameRate: $0.frameRate, profile: $0.profile) }
        let resolved = changesLens ? desired.flatMap { capabilities.resolve($0) } : nil
        lens = stop.lens
        if let resolved { videoMode = resolved }
        sessionQueue.async {
            if changesLens {
                self.session.beginConfiguration()
                self.setInput(lens: stop.lens)
                self.session.commitConfiguration()
                if currentMode == .video, let resolved { self.applyVideoMode(resolved) }
                self.applyHardware()
                if #available(iOS 18.0, *) { self.configureSystemControls() }
            }
            self.applyZoom(stop.zoom)
        }
    }

    /// Zoom continu sur l'objectif actif (pincement).
    func setZoom(_ factor: Double) {
        zoomFactor = min(max(factor, zoomRange.lowerBound), zoomRange.upperBound)
        let value = zoomFactor
        sessionQueue.async { self.applyZoom(value) }
    }

    private func applyZoom(_ factor: Double) {
        guard let device = videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
        let clamped = min(max(CGFloat(factor), device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        device.videoZoomFactor = clamped
        device.unlockForConfiguration()
        publish { self.zoomFactor = Double(clamped) }
    }

    func setRAWMode(_ newMode: RAWMode) {
        let photo = capabilities.photo
        guard (newMode == .bayer && photo.bayerRAW) || (newMode == .proRAW && photo.appleProRAW) || newMode == .off else { return }
        rawMode = newMode
        sessionQueue.async {
            let wantsProRAW = newMode == .proRAW
            guard self.photoOutput.isAppleProRAWSupported, self.photoOutput.isAppleProRAWEnabled != wantsProRAW else { return }
            self.session.beginConfiguration()
            self.photoOutput.isAppleProRAWEnabled = wantsProRAW
            self.session.commitConfiguration()
        }
    }

    func setPhotoResolution(_ resolution: PhotoResolution) {
        guard photoResolutions.contains(resolution) else { return }
        photoResolution = resolution
    }

    /// Choisit un mode vidéo ; si la combinaison demandée n'existe pas, le plus proche est retenu.
    func selectVideoMode(_ query: VideoModeQuery) {
        guard !isRecording, let resolved = capabilities.resolve(query) else { return }
        videoMode = resolved
        guard mode == .video else { return }
        sessionQueue.async { self.applyVideoMode(resolved) }
    }

    func selectCodec(_ newCodec: VideoCodec) {
        guard capabilities.videoCodecs.contains(newCodec), !isRecording else { return }
        codec = newCodec
    }

    private func applyVideoMode(_ mode: VideoMode) {
        guard let device = devices[mode.lens] else { return }
        if videoInput?.device != device {
            session.beginConfiguration()
            setInput(lens: mode.lens)
            session.commitConfiguration()
        }
        let space = Self.colorSpace(for: mode.profile)
        let fps = Double(mode.frameRate)
        let candidates = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return Int(dims.width) == mode.resolution.width && Int(dims.height) == mode.resolution.height
                && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
                && (format.supportedColorSpaces.contains(space) || (mode.profile == .sdr && format.supportedColorSpaces.contains(.P3_D65)))
        }
        // En SDR on préfère un format 8 bits ; en HDR/Log le format 10 bits est imposé par l'espace couleur.
        let eightBit: Set<FourCharCode> = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        let format = candidates.first { mode.profile != .sdr || eightBit.contains(CMFormatDescriptionGetMediaSubType($0.formatDescription)) }
            ?? candidates.first
        guard let format else { return }
        do {
            session.beginConfiguration()
            session.automaticallyConfiguresCaptureDeviceForWideColor = false
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeColorSpace = format.supportedColorSpaces.contains(space) ? space : .P3_D65
            let duration = CMTime(value: 1, timescale: CMTimeScale(mode.frameRate))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            session.commitConfiguration()
        } catch {
            session.commitConfiguration()
            publish { self.status = .failed("Impossible d'appliquer le mode vidéo : \(error.localizedDescription)") }
        }
        publishDeviceRanges(device)
        applyHardware()
    }

    // MARK: Réglages manuels

    /// Copie de l'état manuel propre à `sessionQueue` (jamais lue depuis le fil principal).
    struct HardwareState {
        var program: ExposureProgram = .program
        var aperture: Float = 1.8
        var iso: Float = 100
        var isoAuto = false
        var shutter: Double = 1.0 / 60
        var bias: Float = 0
        var manualWhiteBalance = false
        var kelvin: Float = 5500
        var tint: Float = 0
        var manualFocus = false
        var lensPosition: Float = 0.5
        var tracking = false
        var trackingBias: Float = 0
        var locked = false
        var signals: Set<ExposureSignalOption>?
    }

    var hardwareState = HardwareState()

    /// À appeler depuis le fil principal : publie l'état puis l'applique au matériel.
    func updateHardware(_ change: (inout HardwareState) -> Void) {
        var state = HardwareState(program: program, aperture: aperture, iso: iso, isoAuto: isoAuto, shutter: shutter,
                                  bias: exposureBias, manualWhiteBalance: manualWhiteBalance, kelvin: kelvin,
                                  tint: whiteBalanceTint, manualFocus: manualFocus, lensPosition: lensPosition,
                                  tracking: subjectTracking, trackingBias: trackingBias, locked: aeAwbLocked,
                                  signals: customSignals)
        change(&state)
        program = state.program
        aperture = state.aperture
        iso = state.iso
        isoAuto = state.isoAuto
        shutter = state.shutter
        exposureBias = state.bias
        manualWhiteBalance = state.manualWhiteBalance
        kelvin = state.kelvin
        whiteBalanceTint = state.tint
        manualFocus = state.manualFocus
        lensPosition = state.lensPosition
        subjectTracking = state.tracking
        trackingBias = state.trackingBias
        aeAwbLocked = state.locked
        customSignals = state.signals
        let snapshot = state
        sessionQueue.async {
            self.hardwareState = snapshot
            self.applyHardware()
        }
    }

    /// Vrai si l'outil est débloqué ; sinon présente l'abonnement (fil principal).
    func requirePro(_ feature: ProFeature) -> Bool {
        if proUnlocked { return true }
        MainActor.assumeIsolated { onProRequired?(feature) }
        return false
    }

    /// Fin d'abonnement : l'appareil revient aux réglages de la formule gratuite.
    func setProUnlocked(_ unlocked: Bool) {
        proUnlocked = unlocked
        guard !unlocked else { return }
        if program != .program { updateHardware { $0.program = .program; $0.signals = nil } }
        if customSignals != nil { updateHardware { $0.signals = nil } }
        if intervalShots != nil { MainActor.assumeIsolated { stopIntervalometer() } }
        if longExposureProgress == nil { drive = .single }
        setAssist(AssistSettings())
        frameGuide = 0
        minimalProcessing = false
        measuringWhite = false
    }

    func setProgram(_ newProgram: ExposureProgram) {
        guard programs.contains(newProgram) else { return }
        guard newProgram == .program || requirePro(.manualExposure) else { return }
        updateHardware { $0.program = newProgram }
    }

    func setExposure(aperture: Float? = nil, iso: Float? = nil, isoAuto: Bool? = nil, shutter: Double? = nil, bias: Float? = nil) {
        // Seule la correction d'exposition (mode P) fait partie de la formule gratuite.
        if aperture != nil || iso != nil || isoAuto != nil || shutter != nil {
            guard requirePro(.manualExposure) else { return }
        }
        updateHardware {
            if let aperture { $0.aperture = aperture }
            if let iso { $0.iso = iso }
            if let isoAuto { $0.isoAuto = isoAuto }
            if let shutter { $0.shutter = shutter }
            if let bias { $0.bias = bias }
        }
    }

    func setManualWhiteBalance(_ enabled: Bool, kelvin: Float? = nil, tint: Float? = nil) {
        updateHardware {
            $0.manualWhiteBalance = enabled
            if let kelvin { $0.kelvin = kelvin }
            if let tint { $0.tint = tint }
        }
    }

    func setManualFocus(_ enabled: Bool, lensPosition: Float? = nil) {
        updateHardware {
            $0.manualFocus = enabled
            if enabled { $0.tracking = false }
            if let lensPosition { $0.lensPosition = lensPosition }
        }
    }

    /// Suivi du sujet (iOS 27) : la mise au point accompagne le sujet touché dans le cadre.
    func setSubjectTracking(_ enabled: Bool, bias: Float? = nil) {
        guard supportsSubjectTracking else { return }
        updateHardware {
            $0.tracking = enabled
            if enabled { $0.manualFocus = false }
            if let bias { $0.trackingBias = bias }
        }
    }

    func setAEAWBLocked(_ locked: Bool) {
        updateHardware { $0.locked = locked }
    }

    func setStabilization(_ enabled: Bool) {
        stabilization = enabled
    }

    /// Toucher dans le viseur : mise au point et mesure sur ce point (coordonnées capteur 0…1),
    /// ou mesure du blanc sur une charte grise. `viewPoint` : position dans le viseur (0…1).
    func touch(devicePoint: CGPoint, viewPoint: CGPoint) {
        if measuringWhite {
            measuringWhite = false
            analysisLock.withLock { analysisConfig.whitePoint = viewPoint }
            return
        }
        analysisLock.withLock { analysisConfig.loupeCenter = viewPoint }
        focus(at: devicePoint)
    }

    /// Mise au point et mesure sur un point (coordonnées capteur 0…1).
    func focus(at devicePoint: CGPoint) {
        sessionQueue.async {
            let state = self.hardwareState
            guard let device = self.videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusPointOfInterestSupported, !state.manualFocus {
                device.focusPointOfInterest = devicePoint
                device.focusMode = device.isFocusModeSupported(.continuousAutoFocus) ? .continuousAutoFocus : .autoFocus
            }
            if device.isExposurePointOfInterestSupported, state.program != .manual, !state.locked {
                device.exposurePointOfInterest = devicePoint
                if state.program == .program { device.exposureMode = .continuousAutoExposure }
            }
            device.unlockForConfiguration()
        }
    }

    /// Applique `hardwareState` à l'objectif actif (sessionQueue).
    func applyHardware() {
        let state = hardwareState
        guard let device = videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        applyExposureSignals(state.signals, to: device)
        applyExposure(state, to: device)
        applyWhiteBalance(state, to: device)
        applyFocus(state, to: device)
    }

    /// À appeler depuis le fil principal : modifie les priorités de l'automatisme.
    func setExposureSignals(_ signals: Set<ExposureSignalOption>?) {
        guard signals == nil || requirePro(.advancedCapture) else { return }
        updateHardware { $0.signals = signals }
    }

    private func applyExposure(_ state: HardwareState, to device: AVCaptureDevice) {
        let format = device.activeFormat
        let durationRange = format.minExposureDuration.seconds...format.maxExposureDuration.seconds
        let isoRange = format.minISO...format.maxISO

        if state.locked, state.program == .program, device.isExposureModeSupported(.locked) {
            device.exposureMode = .locked
            return
        }
        guard state.program != .program, device.isExposureModeSupported(.custom) else {
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.setExposureTargetBias(min(max(state.bias, device.minExposureTargetBias), device.maxExposureTargetBias),
                                         completionHandler: nil)
            return
        }
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            let apertureRange = format.minLensAperture...max(format.maxLensAperture, format.minLensAperture)
            let request = ExposureRequest.make(state.program, aperture: state.aperture, duration: state.shutter, iso: state.iso,
                                               isoAuto: state.isoAuto, variableAperture: apertureRange.lowerBound < apertureRange.upperBound)
                .clamped(aperture: apertureRange, duration: durationRange, iso: isoRange)
            let aperture = request.aperture ?? AVCaptureDevice.autoLensAperture
            let duration = request.duration.map { CMTime(seconds: $0, preferredTimescale: 1_000_000) } ?? AVCaptureDevice.autoExposureDuration
            let iso = request.iso ?? AVCaptureDevice.autoISO
            if format.supportsExposureModeCustom(lensAperture: aperture, duration: duration, iso: iso) {
                device.setExposureModeCustom(lensAperture: aperture, duration: duration, iso: iso, completionHandler: nil)
                if state.program.usesExposureBias {
                    device.setExposureTargetBias(min(max(state.bias, device.minExposureTargetBias), device.maxExposureTargetBias),
                                                 completionHandler: nil)
                }
                return
            }
        }
        #endif
        // Avant iOS 27 : exposition manuelle complète (vitesse et ISO).
        let iso = min(max(state.iso, isoRange.lowerBound), isoRange.upperBound)
        let seconds = min(max(state.shutter, durationRange.lowerBound), durationRange.upperBound)
        device.setExposureModeCustom(duration: CMTime(seconds: seconds, preferredTimescale: 1_000_000), iso: iso, completionHandler: nil)
    }

    private func applyWhiteBalance(_ state: HardwareState, to device: AVCaptureDevice) {
        if state.manualWhiteBalance, device.isWhiteBalanceModeSupported(.locked) {
            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: state.kelvin, tint: state.tint)
            var gains = device.deviceWhiteBalanceGains(for: values)
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), maxGain)
            gains.greenGain = min(max(gains.greenGain, 1), maxGain)
            gains.blueGain = min(max(gains.blueGain, 1), maxGain)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        } else if state.locked, device.isWhiteBalanceModeSupported(.locked) {
            device.whiteBalanceMode = .locked
        } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
    }

    private func applyFocus(_ state: HardwareState, to device: AVCaptureDevice) {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *), device.activeFormat.isContinuousAutoFocusTrackingSupported {
            device.isContinuousAutoFocusTrackingEnabled = state.tracking && !state.manualFocus
            if state.tracking {
                device.continuousAutoFocusTrackingLensPositionBias = min(max(state.trackingBias, -1), 1)
            }
        }
        #endif
        if state.manualFocus, device.isLockingFocusWithCustomLensPositionSupported {
            device.setFocusModeLocked(lensPosition: min(max(state.lensPosition, 0), 1), completionHandler: nil)
        } else if device.isFocusModeSupported(.continuousAutoFocus) {
            // Réappliquer le mode continu prend en compte le suivi et son biais.
            device.focusMode = .continuousAutoFocus
        }
    }

    // MARK: Photo

    /// Déclencheur : selon le mode d'entraînement.
    @MainActor
    func shutterPressed() {
        switch proUnlocked ? drive : .single {
        case .single: capturePhoto()
        case .bracketing: captureBracket()
        case .longExposure: startLongExposure()
        case .intervalometer: intervalShots == nil ? startIntervalometer() : stopIntervalometer()
        }
    }

    func capturePhoto() {
        let angle = captureRotationAngle
        let minimal = minimalProcessing
        let guide = frameGuide
        let raw = rawMode
        let resolution = photoResolution
        sessionQueue.async {
            let output = self.photoOutput
            let processedFormat: [String: Any]? = output.availablePhotoCodecTypes.contains(.hevc)
                ? [AVVideoCodecKey: AVVideoCodecType.hevc] : nil
            let settings: AVCapturePhotoSettings
            var isProRAW = false
            if raw != .off, let rawFormat = output.availableRawPhotoPixelFormatTypes.first(where: {
                raw == .proRAW ? AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) : AVCapturePhotoOutput.isBayerRAWPixelFormat($0)
            }) {
                settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat, processedFormat: processedFormat)
                isProRAW = raw == .proRAW
                // Le RAW Bayer est une capture brute, sans fusion multi-images.
                settings.photoQualityPrioritization = raw == .bayer ? .speed : .quality
            } else {
                settings = processedFormat.map { AVCapturePhotoSettings(format: $0) } ?? AVCapturePhotoSettings()
                settings.photoQualityPrioritization = minimal ? .speed : .quality
            }
            // Définition choisie (12, 24 ou 48 Mpx), jamais au-delà de ce que la sortie prépare.
            let maximum = output.maxPhotoDimensions
            if let resolution, resolution.width * resolution.height <= Int(maximum.width) * Int(maximum.height) {
                settings.maxPhotoDimensions = CMVideoDimensions(width: Int32(resolution.width), height: Int32(resolution.height))
            } else {
                settings.maxPhotoDimensions = maximum
            }
            if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            let id = settings.uniqueID
            let delegate = PhotoCaptureDelegate(isProRAW: isProRAW, cropAspect: guide,
                                                processedExtension: processedFormat == nil ? "jpg" : "heic") { result in
                self.sessionQueue.async {
                    self.photoDelegates[id] = nil
                    self.readiness?.stopTrackingCaptureRequest(using: id)
                }
                DispatchQueue.main.async {
                    if let result { self.onPhotoCaptured?(result) }
                }
            }
            self.photoDelegates[id] = delegate
            self.readiness?.startTrackingCaptureRequest(using: settings)
            output.capturePhoto(with: settings, delegate: delegate)
        }
    }

    // MARK: Vidéo

    func toggleRecording() {
        if isRecording {
            sessionQueue.async { self.movieOutput.stopRecording() }
            return
        }
        guard mode == .video else { return }
        let angle = captureRotationAngle
        let codec = self.codec
        let stabilization = self.stabilization
        sessionQueue.async {
            guard let connection = self.movieOutput.connection(with: .video) else { return }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = stabilization ? .auto : .off
            }
            let type = Self.codecType(for: codec)
            if self.movieOutput.availableVideoCodecTypes.contains(type) {
                self.movieOutput.setOutputSettings([AVVideoCodecKey: type], for: connection)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    private func startRecordingTimer() {
        recordingStart = Date()
        recordingDuration = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.recordingDuration = Date().timeIntervalSince(self.recordingStart ?? Date())
            self.sessionQueue.async {
                let level = self.movieOutput.connection(with: .audio)?.audioChannels.first?.averagePowerLevel ?? -160
                DispatchQueue.main.async { self.audioLevel = level }
            }
        }
    }
}

// MARK: - Bouton Commande de l'appareil photo (iOS 18)

@available(iOS 18.0, *)
extension CameraController: AVCaptureSessionControlsDelegate {
    /// Focale, correction d'exposition et, sur l'iPhone 18 Pro, ouverture (sessionQueue).
    fileprivate func configureSystemControls() {
        guard session.supportsControls, let device = videoInput?.device else { return }
        session.beginConfiguration()
        for control in session.controls { session.removeControl(control) }
        var controls: [AVCaptureControl] = []

        let stops = focalStopsForDevices().stops
        let main = focalStopsForDevices().main
        if stops.count > 1 {
            let picker = AVCaptureIndexPicker("Focale", symbolName: "camera.aperture",
                                              localizedIndexTitles: stops.map { $0.magnification(mainFocalLength: main) })
            let currentLens = devices.first { $0.value == device }?.key
            picker.selectedIndex = stops.firstIndex { $0.lens == currentLens && $0.zoom == 1 } ?? 0
            picker.setActionQueue(.main) { [weak self] index in
                guard let self, stops.indices.contains(index) else { return }
                self.selectFocal(stops[index])
            }
            controls.append(picker)
        }
        controls.append(AVCaptureSystemExposureBiasSlider(device: device) { [weak self] bias in
            guard let self else { return }
            self.exposureBias = bias
        })
        #if compiler(>=6.4)
        if #available(iOS 27.0, *), device.activeFormat.minLensAperture < device.activeFormat.maxLensAperture {
            let apertures = device.activeFormat.recommendedLensApertureStops
            if !apertures.isEmpty {
                let picker = AVCaptureIndexPicker("Ouverture", symbolName: "camera.aperture",
                                                  localizedIndexTitles: apertures.map(CameraFormat.aperture))
                picker.setActionQueue(.main) { [weak self] index in
                    guard let self, apertures.indices.contains(index), self.requirePro(.manualExposure) else { return }
                    if self.program == .program { self.setProgram(.aperturePriority) }
                    self.setExposure(aperture: apertures[index])
                }
                controls.append(picker)
            }
        }
        #endif
        for control in controls.prefix(session.maxControlsCount) where session.canAddControl(control) {
            session.addControl(control)
        }
        session.setControlsDelegate(self, queue: .main)
        session.commitConfiguration()
    }

    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}

    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        systemControlsFullscreen = true
    }

    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        systemControlsFullscreen = false
    }

    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        systemControlsFullscreen = false
    }
}

// MARK: - Prise de vue réactive

extension CameraController: AVCapturePhotoOutputReadinessCoordinatorDelegate {
    func readinessCoordinator(_ coordinator: AVCapturePhotoOutputReadinessCoordinator,
                              captureReadinessDidChange captureReadiness: AVCapturePhotoOutput.CaptureReadiness) {
        let blocked = captureReadiness != .ready
        publish { self.isCaptureBlocked = blocked }
    }
}

// MARK: - Vidéo

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async {
            self.isRecording = true
            self.startRecordingTimer()
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        // Une erreur peut accompagner un enregistrement terminé correctement (stockage plein, etc.).
        var success = error == nil
        if let error = error as NSError?,
           let finished = error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool {
            success = finished
        }
        let message = error?.localizedDescription ?? "erreur inconnue"
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
            self.audioLevel = -160
            if success {
                self.onMovieRecorded?(outputFileURL)
            } else {
                self.status = .failed("L'enregistrement a échoué : \(message)")
                try? FileManager.default.removeItem(at: outputFileURL)
            }
        }
    }
}

/// Reçoit les données d'une capture photo (RAW et/ou image traitée).
final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private var capture: CapturedPhoto
    private let completion: (CapturedPhoto?) -> Void

    init(isProRAW: Bool, cropAspect: Int, processedExtension: String, completion: @escaping (CapturedPhoto?) -> Void) {
        capture = CapturedPhoto(processedExtension: processedExtension, isProRAW: isProRAW, cropAspect: cropAspect)
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        if photo.isRawPhoto { capture.rawData = data } else { capture.processedData = data }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        let hasData = capture.rawData != nil || capture.processedData != nil
        completion(error == nil && hasData ? capture : nil)
    }
}
