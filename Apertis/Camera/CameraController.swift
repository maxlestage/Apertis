@preconcurrency import AVFoundation
import UIKit
import ApertisCore

/// Pilote la caméra avec AVFoundation.
///
/// Toute la configuration matérielle s'exécute sur `sessionQueue` ; les propriétés publiées
/// sont mises à jour sur le fil principal. Les choix proposés à l'interface proviennent du
/// profil `capabilities`, construit à partir des formats réellement exposés par l'appareil.
final class CameraController: NSObject, ObservableObject {
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

    @Published private(set) var status: Status = .starting
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
    @Published private(set) var isCapturingPhoto = false

    @Published private(set) var isoRange: ClosedRange<Float> = 25...3200
    @Published private(set) var shutterRange: ClosedRange<Double> = (1.0 / 8000)...(1.0 / 2)
    @Published private(set) var biasRange: ClosedRange<Float> = -3...3
    @Published private(set) var supportsManualFocus = false

    @Published private(set) var manualExposure = false
    @Published private(set) var iso: Float = 100
    @Published private(set) var shutter: Double = 1.0 / 60
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var manualWhiteBalance = false
    @Published private(set) var kelvin: Float = 5500
    @Published private(set) var whiteBalanceTint: Float = 0
    @Published private(set) var manualFocus = false
    @Published private(set) var lensPosition: Float = 0.5
    @Published private(set) var stabilization = true
    /// Verrouillage exposition + balance des blancs (évite les variations en cours de plan).
    @Published private(set) var aeAwbLocked = false

    /// Appelé sur le fil principal pour chaque photo enregistrée.
    var onPhotoCaptured: ((CapturedPhoto) -> Void)?
    /// Appelé sur le fil principal avec le fichier temporaire de la vidéo.
    var onMovieRecorded: ((URL) -> Void)?

    // MARK: AVFoundation

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "fr.apertis.camera.session")
    private var devices: [LensKind: AVCaptureDevice] = [:]
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var photoDelegates: [Int64: PhotoCaptureDelegate] = [:]
    private var bayerRAWSupported = false
    private var recordingTimer: Timer?
    private var recordingStart: Date?
    private var isConfigured = false

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

    private func publish(_ update: @escaping () -> Void) {
        DispatchQueue.main.async(execute: update)
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
        let initialLens: LensKind = devices[.wide] != nil ? .wide : devices.keys.sorted().first!
        setInput(lens: initialLens)
        session.commitConfiguration()

        bayerRAWSupported = photoOutput.availableRawPhotoPixelFormatTypes.contains { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
        let capabilities = buildCapabilities()
        publish {
            self.capabilities = capabilities
            self.lens = initialLens
            self.videoMode = capabilities.resolve(VideoModeQuery(lens: initialLens, resolution: Resolution(width: 3840, height: 2160),
                                                                  frameRate: 30, profile: .sdr))
            self.status = .ready
        }
    }

    private static func discoverDevices() -> [LensKind: AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .unspecified)
        var result: [LensKind: AVCaptureDevice] = [:]
        for device in discovery.devices {
            switch (device.deviceType, device.position) {
            case (.builtInUltraWideCamera, .back): result[.ultraWide] = device
            case (.builtInWideAngleCamera, .back): result[.wide] = device
            case (.builtInTelephotoCamera, .back): result[.telephoto] = device
            case (.builtInWideAngleCamera, .front): result[.front] = device
            default: break
            }
        }
        return result
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
        if let dims = device.activeFormat.supportedMaxPhotoDimensions.last {
            photoOutput.maxPhotoDimensions = dims
        }
        publishDeviceRanges(device)
    }

    private func publishDeviceRanges(_ device: AVCaptureDevice) {
        let format = device.activeFormat
        let iso = format.minISO...format.maxISO
        let shutter = format.minExposureDuration.seconds...min(format.maxExposureDuration.seconds, 1)
        let bias = device.minExposureTargetBias...device.maxExposureTargetBias
        let manualFocus = device.isLockingFocusWithCustomLensPositionSupported
        publish {
            self.isoRange = iso
            self.shutterRange = shutter
            self.biasRange = bias
            self.supportsManualFocus = manualFocus
        }
    }

    /// Construit la matrice des capacités à partir des formats exposés par chaque objectif.
    private func buildCapabilities() -> CaptureCapabilities {
        let videoResolutions: Set<Resolution> = [
            Resolution(width: 1280, height: 720), Resolution(width: 1920, height: 1080), Resolution(width: 3840, height: 2160),
        ]
        let candidateRates = [24, 25, 30, 48, 50, 60, 120, 240]
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
        @unknown default: return nil
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

    // MARK: Commandes

    func setMode(_ newMode: Mode) {
        guard newMode != mode, !isRecording else { return }
        let target = videoMode
        publish { self.mode = newMode }
        sessionQueue.async {
            self.session.beginConfiguration()
            if newMode == .video {
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
            }
            self.session.commitConfiguration()
            if newMode == .video, let target { self.applyVideoMode(target) }
            if let device = self.videoInput?.device { self.publishDeviceRanges(device) }
        }
    }

    func selectLens(_ newLens: LensKind) {
        guard newLens != lens, !isRecording, capabilities.photo.lenses.contains(newLens) else { return }
        let currentMode = mode
        let desired = videoMode.map { VideoModeQuery(lens: newLens, resolution: $0.resolution, frameRate: $0.frameRate, profile: $0.profile) }
        let resolved = desired.flatMap { capabilities.resolve($0) }
        publish {
            self.lens = newLens
            if let resolved { self.videoMode = resolved }
        }
        sessionQueue.async {
            self.session.beginConfiguration()
            self.setInput(lens: newLens)
            self.session.commitConfiguration()
            if currentMode == .video, let resolved { self.applyVideoMode(resolved) }
            self.applyExposureAndFocus()
        }
    }

    func setRAWMode(_ newMode: RAWMode) {
        let photo = capabilities.photo
        guard (newMode == .bayer && photo.bayerRAW) || (newMode == .proRAW && photo.appleProRAW) || newMode == .off else { return }
        publish { self.rawMode = newMode }
        sessionQueue.async {
            let wantsProRAW = newMode == .proRAW
            guard self.photoOutput.isAppleProRAWSupported, self.photoOutput.isAppleProRAWEnabled != wantsProRAW else { return }
            self.session.beginConfiguration()
            self.photoOutput.isAppleProRAWEnabled = wantsProRAW
            self.session.commitConfiguration()
        }
    }

    /// Choisit un mode vidéo ; si la combinaison demandée n'existe pas, le plus proche est retenu.
    func selectVideoMode(_ query: VideoModeQuery) {
        guard !isRecording, let resolved = capabilities.resolve(query) else { return }
        publish { self.videoMode = resolved }
        guard mode == .video else { return }
        sessionQueue.async { self.applyVideoMode(resolved) }
    }

    func selectCodec(_ newCodec: VideoCodec) {
        guard capabilities.videoCodecs.contains(newCodec), !isRecording else { return }
        publish { self.codec = newCodec }
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
            session.automaticallyConfiguresCaptureDeviceWideColor = false
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
        applyExposureAndFocus()
    }

    // MARK: Réglages manuels

    /// Copie de l'état manuel propre à `sessionQueue` (jamais lue depuis le fil principal).
    private struct HardwareState {
        var manualExposure = false
        var iso: Float = 100
        var shutter: Double = 1.0 / 60
        var bias: Float = 0
        var manualWhiteBalance = false
        var kelvin: Float = 5500
        var tint: Float = 0
        var manualFocus = false
        var lensPosition: Float = 0.5
        var locked = false
    }

    private var hardwareState = HardwareState()

    /// À appeler depuis le fil principal : publie l'état puis l'applique au matériel.
    private func updateHardware(_ change: (inout HardwareState) -> Void) {
        var state = HardwareState(manualExposure: manualExposure, iso: iso, shutter: shutter, bias: exposureBias,
                                  manualWhiteBalance: manualWhiteBalance, kelvin: kelvin, tint: whiteBalanceTint,
                                  manualFocus: manualFocus, lensPosition: lensPosition, locked: aeAwbLocked)
        change(&state)
        manualExposure = state.manualExposure
        iso = state.iso
        shutter = state.shutter
        exposureBias = state.bias
        manualWhiteBalance = state.manualWhiteBalance
        kelvin = state.kelvin
        whiteBalanceTint = state.tint
        manualFocus = state.manualFocus
        lensPosition = state.lensPosition
        aeAwbLocked = state.locked
        sessionQueue.async {
            self.hardwareState = state
            self.applyExposureAndFocus()
        }
    }

    func setManualExposure(_ enabled: Bool, iso: Float? = nil, shutter: Double? = nil, bias: Float? = nil) {
        updateHardware {
            $0.manualExposure = enabled
            if let iso { $0.iso = iso }
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
            if let lensPosition { $0.lensPosition = lensPosition }
        }
    }

    func setAEAWBLocked(_ locked: Bool) {
        updateHardware { $0.locked = locked }
    }

    func setStabilization(_ enabled: Bool) {
        stabilization = enabled
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
            if device.isExposurePointOfInterestSupported, !state.manualExposure, !state.locked {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        }
    }

    /// Applique `hardwareState` à l'objectif actif (sessionQueue).
    private func applyExposureAndFocus() {
        let state = hardwareState
        guard let device = videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        let format = device.activeFormat

        if state.manualExposure, device.isExposureModeSupported(.custom) {
            let iso = min(max(state.iso, format.minISO), format.maxISO)
            let seconds = min(max(state.shutter, format.minExposureDuration.seconds), format.maxExposureDuration.seconds)
            device.setExposureModeCustom(duration: CMTime(seconds: seconds, preferredTimescale: 1_000_000), iso: iso,
                                         completionHandler: nil)
        } else if state.locked, device.isExposureModeSupported(.locked) {
            device.exposureMode = .locked
        } else if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
            device.setExposureTargetBias(min(max(state.bias, device.minExposureTargetBias), device.maxExposureTargetBias),
                                         completionHandler: nil)
        }

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

        if state.manualFocus, device.isLockingFocusWithCustomLensPositionSupported {
            device.setFocusModeLocked(lensPosition: min(max(state.lensPosition, 0), 1), completionHandler: nil)
        } else if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
    }

    // MARK: Photo

    func capturePhoto() {
        let angle = Self.captureRotationAngle()
        let raw = rawMode
        publish { self.isCapturingPhoto = true }
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
                settings.photoQualityPrioritization = .quality
            }
            settings.maxPhotoDimensions = output.maxPhotoDimensions
            if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            let id = settings.uniqueID
            let delegate = PhotoCaptureDelegate(isProRAW: isProRAW,
                                                processedExtension: processedFormat == nil ? "jpg" : "heic") { result in
                self.sessionQueue.async { self.photoDelegates[id] = nil }
                DispatchQueue.main.async {
                    self.isCapturingPhoto = false
                    if let result { self.onPhotoCaptured?(result) }
                }
            }
            self.photoDelegates[id] = delegate
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
        let angle = Self.captureRotationAngle()
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

    /// Angle de capture correspondant à l'orientation physique de l'appareil.
    private static func captureRotationAngle() -> CGFloat {
        switch UIDevice.current.orientation {
        case .landscapeLeft: return 0
        case .landscapeRight: return 180
        case .portraitUpsideDown: return 270
        default: return 90
        }
    }
}

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
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
            self.audioLevel = -160
            if success {
                self.onMovieRecorded?(outputFileURL)
            } else {
                self.status = .failed("L'enregistrement a échoué : \(error?.localizedDescription ?? "erreur inconnue")")
                try? FileManager.default.removeItem(at: outputFileURL)
            }
        }
    }
}

/// Reçoit les données d'une capture photo (RAW et/ou image traitée).
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private var capture: CapturedPhoto
    private var failed = false
    private let completion: (CapturedPhoto?) -> Void

    init(isProRAW: Bool, processedExtension: String, completion: @escaping (CapturedPhoto?) -> Void) {
        capture = CapturedPhoto(processedExtension: processedExtension, isProRAW: isProRAW)
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            failed = true
            return
        }
        if photo.isRawPhoto { capture.rawData = data } else { capture.processedData = data }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        let hasData = capture.rawData != nil || capture.processedData != nil
        completion(error == nil && hasData ? capture : nil)
    }
}
