import SwiftUI
import ApertisCore

struct CameraView: View {
    @EnvironmentObject private var store: MediaStore
    @StateObject private var camera = CameraController()
    @StateObject private var level = LevelMonitor()
    @AppStorage("camera.grid") private var showGrid = true
    @AppStorage("camera.level") private var showLevel = true
    @AppStorage("camera.histogram") private var showHistogram = true
    @State private var showManual = false
    @State private var showVideoSettings = false
    @State private var flash = false
    @State private var message: String?

    var body: some View {
        GeometryReader { proxy in
            // Paysage : iPad (et toute fenêtre plus large que haute) ; viseur et commandes côte à côte.
            let landscape = proxy.size.width > proxy.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                if landscape {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            topBar
                            viewfinder(aspect: camera.mode == .photo ? 4.0 / 3.0 : 16.0 / 9.0)
                        }
                        Divider().background(Color.white.opacity(0.2))
                        ScrollView {
                            VStack(spacing: 18) {
                                ManualControlsPanel(camera: camera)
                                captureControls
                            }
                            .padding(.vertical)
                        }
                        .frame(width: min(360, proxy.size.width * 0.36))
                    }
                } else {
                    VStack(spacing: 0) {
                        topBar
                        viewfinder(aspect: camera.mode == .photo ? 3.0 / 4.0 : 9.0 / 16.0)
                        if showManual {
                            ScrollView { ManualControlsPanel(camera: camera) }
                                .frame(maxHeight: proxy.size.height * 0.36)
                                .transition(.move(edge: .bottom))
                        }
                        Spacer(minLength: 0)
                        captureControls.padding(.bottom, 12)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .onAppear {
            camera.onPhotoCaptured = { capture in
                do { try store.addCapturedPhoto(capture) } catch { message = "Enregistrement impossible : \(error.localizedDescription)" }
            }
            camera.onMovieRecorded = { url in
                Task {
                    do { _ = try await store.addRecordedMovie(at: url) } catch { message = "Vidéo non enregistrée : \(error.localizedDescription)" }
                }
            }
            camera.start()
            level.start()
        }
        .onDisappear {
            camera.stop()
            level.stop()
        }
        .sheet(isPresented: $showVideoSettings) {
            VideoSettingsSheet(camera: camera).presentationDetents([.medium, .large])
        }
        .alert("Caméra", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: Viseur

    private func viewfinder(aspect: CGFloat) -> some View {
        ZStack {
            CameraPreviewView(camera: camera)
            // Pendant que le bouton Commande affiche ses réglages, le viseur reste dégagé.
            if !camera.systemControlsFullscreen {
                if showGrid { GridOverlay() }
                if showLevel && level.isAvailable { LevelIndicator(tilt: level.tilt) }
                VStack {
                    HStack(alignment: .top) {
                        if camera.isLensSmudged {
                            Label("Objectif sale : essuyez la lentille", systemImage: "drop.triangle")
                                .font(.caption.bold())
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.orange.opacity(0.9), in: Capsule())
                                .foregroundStyle(.black)
                        }
                        Spacer()
                        if showHistogram, let histogram = camera.liveHistogram {
                            HistogramView(histogram: histogram).frame(width: 112, height: 56)
                        }
                    }
                    Spacer()
                    HStack {
                        ExposureReadout(camera: camera)
                        Spacer()
                        if camera.zoomFactor > 1.01 {
                            Text(String(format: "%.1f×", camera.zoomFactor))
                                .font(.caption.monospacedDigit().bold())
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.black.opacity(0.5), in: Capsule())
                        }
                    }
                }
                .padding(10)
            }
            if flash { Color.black.opacity(0.6).transition(.opacity) }
            statusOverlay
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipped()
    }

    // MARK: Barres

    private var topBar: some View {
        HStack(spacing: 16) {
            Menu {
                Toggle("Grille", isOn: $showGrid)
                Toggle("Niveau", isOn: $showLevel)
                Toggle("Histogramme", isOn: $showHistogram)
            } label: {
                Image(systemName: "viewfinder").accessibilityLabel("Aides du viseur")
            }
            if camera.mode == .photo {
                Menu {
                    Section("Format") {
                        ForEach(availableRAWModes) { mode in
                            Button { camera.setRAWMode(mode) } label: {
                                if mode == camera.rawMode { Label(mode.label, systemImage: "checkmark") } else { Text(mode.label) }
                            }
                        }
                    }
                    if camera.photoResolutions.count > 1 {
                        Section("Définition") {
                            ForEach(camera.photoResolutions) { resolution in
                                Button { camera.setPhotoResolution(resolution) } label: {
                                    if resolution == camera.photoResolution {
                                        Label(resolution.label, systemImage: "checkmark")
                                    } else {
                                        Text(resolution.label)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Text([camera.rawMode.label, camera.photoResolution?.label].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(camera.rawMode == .off ? Color.white.opacity(0.15) : Color.yellow.opacity(0.85),
                                    in: Capsule())
                        .foregroundStyle(camera.rawMode == .off ? .white : .black)
                }
            } else {
                Button { showVideoSettings = true } label: { videoModeLabel }
            }
            Spacer()
            if camera.isRecording {
                Text(Self.format(camera.recordingDuration))
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8)
                    .background(Color.red, in: Capsule())
                AudioMeter(level: camera.audioLevel).frame(width: 40, height: 6)
            }
            Spacer()
            Button { withAnimation { showManual.toggle() } } label: {
                Image(systemName: "slider.horizontal.3").accessibilityLabel("Réglages manuels")
            }
        }
        .padding(.horizontal)
        .frame(height: 44)
    }

    private var videoModeLabel: some View {
        let mode = camera.videoMode
        let text = mode.map { "\($0.resolution) · \($0.frameRate) · \($0.profile.label) · \(camera.codec.label)" } ?? "Vidéo"
        return Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.white.opacity(0.15), in: Capsule())
    }

    /// Focales, mode, déclencheur.
    private var captureControls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(camera.focalStops) { stop in
                    let active = stop.lens == camera.lens && abs(camera.zoomFactor - stop.zoom) < 0.05
                    Button(stop.magnification(mainFocalLength: camera.mainFocalLength)) { camera.selectFocal(stop) }
                        .font(.caption.bold())
                        .frame(minWidth: 38, minHeight: 32)
                        .padding(.horizontal, 2)
                        .background(active ? Color.yellow.opacity(0.9) : Color.white.opacity(0.15), in: Capsule())
                        .foregroundStyle(active ? .black : .white)
                        .accessibilityLabel("\(stop.label)\(stop.isOpticalQualityCrop ? ", qualité optique" : "")")
                }
                ForEach(camera.capabilities.photo.lenses.filter { $0 == .front || $0 == .external }, id: \.self) { lens in
                    Button { camera.selectLens(lens == camera.lens ? .wide : lens) } label: {
                        Image(systemName: lens == .front ? "arrow.triangle.2.circlepath.camera" : "cable.connector")
                            .frame(width: 38, height: 32)
                            .background(lens == camera.lens ? Color.yellow.opacity(0.9) : Color.white.opacity(0.15), in: Capsule())
                            .foregroundStyle(lens == camera.lens ? .black : .white)
                    }
                    .accessibilityLabel(lens == .front ? "Caméra avant" : "Caméra externe")
                }
            }
            Picker("Mode", selection: Binding(get: { camera.mode }, set: { camera.setMode($0) })) {
                ForEach(CameraController.Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .disabled(camera.isRecording)
            shutterButton
        }
    }

    private var shutterButton: some View {
        Button {
            if camera.mode == .photo {
                withAnimation(.easeOut(duration: 0.08)) { flash = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { withAnimation { flash = false } }
                camera.capturePhoto()
            } else {
                camera.toggleRecording()
            }
        } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 74, height: 74)
                if camera.mode == .photo {
                    Circle().fill(camera.isCaptureBlocked ? Color.gray : Color.white).frame(width: 60, height: 60)
                } else {
                    RoundedRectangle(cornerRadius: camera.isRecording ? 6 : 30)
                        .fill(Color.red)
                        .frame(width: camera.isRecording ? 30 : 60, height: camera.isRecording ? 30 : 60)
                }
            }
        }
        // Prise de vue réactive : le déclencheur n'attend que si l'appareil n'est vraiment pas prêt.
        .disabled(camera.status != .ready || (camera.mode == .photo && camera.isCaptureBlocked))
        .accessibilityLabel(camera.mode == .photo ? "Prendre une photo" : (camera.isRecording ? "Arrêter" : "Filmer"))
    }

    @ViewBuilder private var statusOverlay: some View {
        switch camera.status {
        case .unauthorized:
            VStack(spacing: 12) {
                Text("Accès à la caméra refusé").font(.headline)
                Button("Ouvrir les Réglages") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        case .failed(let reason):
            Text(reason).font(.footnote).padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .starting:
            ProgressView().tint(.white)
        case .ready:
            EmptyView()
        }
    }

    private var availableRAWModes: [CameraController.RAWMode] {
        var modes: [CameraController.RAWMode] = [.off]
        if camera.capabilities.photo.bayerRAW { modes.append(.bayer) }
        if camera.capabilities.photo.appleProRAW { modes.append(.proRAW) }
        return modes
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Bandeau d'exposition, comme l'écran d'un boîtier : programme, ouverture, vitesse, ISO.
struct ExposureReadout: View {
    @ObservedObject var camera: CameraController

    var body: some View {
        let program = camera.program
        let fixesAperture = program == .aperturePriority || program == .manual
        let fixesShutter = program == .shutterPriority || program == .manual
        HStack(spacing: 8) {
            Text(program.letter).bold().foregroundStyle(.yellow)
            if camera.apertureRange.lowerBound < camera.apertureRange.upperBound {
                Text(fixesAperture ? CameraFormat.aperture(camera.aperture) : "ƒ auto").opacity(fixesAperture ? 1 : 0.6)
            } else {
                Text(CameraFormat.aperture(camera.apertureRange.lowerBound)).opacity(0.6)
            }
            Text(fixesShutter ? CameraFormat.shutter(camera.shutter) : "auto").opacity(fixesShutter ? 1 : 0.6)
            Text(fixesShutter && !camera.isoAuto ? "ISO \(Int(camera.iso))" : "ISO auto").opacity(fixesShutter && !camera.isoAuto ? 1 : 0.6)
            if program.usesExposureBias && camera.exposureBias != 0 {
                Text(String(format: "%+.1f IL", camera.exposureBias))
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.5), in: Capsule())
    }
}

/// Vumètre : -60 dBFS … 0 dBFS, rouge au-delà de -6 dBFS.
struct AudioMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            let normalized = CGFloat(min(max((level + 60) / 60, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(level > -6 ? Color.red : Color.green).frame(width: proxy.size.width * normalized)
            }
        }
    }
}

/// Programme d'exposition (P, A, S, M), ouverture, vitesse, ISO, balance des blancs et mise au point.
struct ManualControlsPanel: View {
    @ObservedObject var camera: CameraController

    var body: some View {
        let program = camera.program
        let variableAperture = camera.apertureRange.lowerBound < camera.apertureRange.upperBound
        VStack(spacing: 10) {
            if camera.programs.count > 1 {
                Picker("Programme", selection: Binding(get: { camera.program }, set: { camera.setProgram($0) })) {
                    ForEach(camera.programs) { Text($0.letter).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(program.label).font(.caption2).foregroundStyle(.secondary)
            }
            if variableAperture && (program == .aperturePriority || program == .manual) {
                apertureControl
            }
            if program == .shutterPriority || program == .manual {
                // Curseur logarithmique : la vitesse varie sur plusieurs ordres de grandeur.
                LabeledSlider(label: "Vitesse",
                              value: Binding(get: { log2(camera.shutter) }, set: { camera.setExposure(shutter: exp2($0)) }),
                              range: log2(camera.shutterRange.lowerBound)...log2(camera.shutterRange.upperBound),
                              format: { CameraFormat.shutter(exp2($0)) })
                if camera.programs.contains(.shutterPriority) {
                    Toggle("ISO auto", isOn: Binding(get: { camera.isoAuto }, set: { camera.setExposure(isoAuto: $0) }))
                }
                if !camera.isoAuto {
                    LabeledSlider(label: "ISO", value: Binding(get: { Double(camera.iso) }, set: { camera.setExposure(iso: Float($0)) }),
                                  range: Double(camera.isoRange.lowerBound)...Double(camera.isoRange.upperBound),
                                  format: { String(format: "%.0f", $0) })
                }
            }
            if program.usesExposureBias {
                LabeledSlider(label: "IL", value: Binding(get: { Double(camera.exposureBias) }, set: { camera.setExposure(bias: Float($0)) }),
                              range: Double(camera.biasRange.lowerBound)...Double(camera.biasRange.upperBound),
                              format: { String(format: "%+.1f", $0) })
            }
            Divider().background(Color.white.opacity(0.2))
            Toggle("Balance des blancs manuelle",
                   isOn: Binding(get: { camera.manualWhiteBalance }, set: { camera.setManualWhiteBalance($0) }))
            if camera.manualWhiteBalance {
                LabeledSlider(label: "Kelvin", value: Binding(get: { Double(camera.kelvin) }, set: { camera.setManualWhiteBalance(true, kelvin: Float($0)) }),
                              range: 2500...10000, format: { String(format: "%.0f K", $0) })
                LabeledSlider(label: "Teinte", value: Binding(get: { Double(camera.whiteBalanceTint) }, set: { camera.setManualWhiteBalance(true, tint: Float($0)) }),
                              range: -150...150, format: { String(format: "%+.0f", $0) })
            }
            Divider().background(Color.white.opacity(0.2))
            if camera.supportsSubjectTracking {
                Toggle("Suivi du sujet", isOn: Binding(get: { camera.subjectTracking }, set: { camera.setSubjectTracking($0) }))
                if camera.subjectTracking {
                    LabeledSlider(label: "Netteté", value: Binding(get: { Double(camera.trackingBias) },
                                                                   set: { camera.setSubjectTracking(true, bias: Float($0)) }),
                                  range: -1...1, format: { $0 < -0.1 ? "avant" : ($0 > 0.1 ? "arrière" : "centre") })
                }
            }
            if camera.supportsManualFocus {
                Toggle("Mise au point manuelle", isOn: Binding(get: { camera.manualFocus }, set: { camera.setManualFocus($0) }))
                if camera.manualFocus {
                    LabeledSlider(label: "Distance", value: Binding(get: { Double(camera.lensPosition) }, set: { camera.setManualFocus(true, lensPosition: Float($0)) }),
                                  range: 0...1, format: { String(format: "%.2f", $0) })
                }
            }
            if camera.mode == .video {
                Toggle("Verrouiller exposition et balance", isOn: Binding(get: { camera.aeAwbLocked }, set: { camera.setAEAWBLocked($0) }))
            }
        }
        .font(.footnote)
        .tint(.yellow)
        .padding()
        .background(Color.black.opacity(0.85))
    }

    /// Diaphragme variable (iPhone 18 Pro) : les ouvertures conseillées, sinon un curseur.
    @ViewBuilder private var apertureControl: some View {
        if camera.apertureStops.count > 1 {
            HStack {
                Text("Ouverture").frame(width: 70, alignment: .leading)
                ForEach(camera.apertureStops, id: \.self) { stop in
                    let active = abs(stop - camera.aperture) < 0.01
                    Button(CameraFormat.aperture(stop)) { camera.setExposure(aperture: stop) }
                        .font(.caption.monospacedDigit().bold())
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(active ? Color.yellow.opacity(0.9) : Color.white.opacity(0.15), in: Capsule())
                        .foregroundStyle(active ? .black : .white)
                }
                Spacer(minLength: 0)
            }
        } else {
            LabeledSlider(label: "Ouverture", value: Binding(get: { Double(camera.aperture) }, set: { camera.setExposure(aperture: Float($0)) }),
                          range: Double(camera.apertureRange.lowerBound)...Double(camera.apertureRange.upperBound),
                          format: { CameraFormat.aperture(Float($0)) })
        }
    }
}

struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        HStack {
            Text(label).frame(width: 70, alignment: .leading)
            Slider(value: $value, in: range)
            Text(format(value)).font(.caption.monospacedDigit()).frame(width: 64, alignment: .trailing)
        }
    }
}

/// Choix du mode vidéo : seules les combinaisons prises en charge par l'objectif sont proposées.
struct VideoSettingsSheet: View {
    @ObservedObject var camera: CameraController

    var body: some View {
        let caps = camera.capabilities
        let current = camera.videoMode
        let lensQuery = VideoModeQuery(lens: camera.lens)
        NavigationStack {
            Form {
                Picker("Résolution", selection: Binding(get: { current?.resolution }, set: { r in
                    camera.selectVideoMode(VideoModeQuery(lens: camera.lens, resolution: r, frameRate: current?.frameRate, profile: current?.profile))
                })) {
                    ForEach(caps.options(\.resolution, matching: lensQuery), id: \.self) { Text($0.description).tag(Optional($0)) }
                }
                Picker("Cadence", selection: Binding(get: { current?.frameRate }, set: { fps in
                    camera.selectVideoMode(VideoModeQuery(lens: camera.lens, resolution: current?.resolution, frameRate: fps, profile: current?.profile))
                })) {
                    ForEach(caps.options(\.frameRate, matching: VideoModeQuery(lens: camera.lens, resolution: current?.resolution)), id: \.self) {
                        Text("\($0) i/s").tag(Optional($0))
                    }
                }
                Picker("Profil", selection: Binding(get: { current?.profile }, set: { p in
                    camera.selectVideoMode(VideoModeQuery(lens: camera.lens, resolution: current?.resolution, frameRate: current?.frameRate, profile: p))
                })) {
                    ForEach(caps.options(\.profile, matching: VideoModeQuery(lens: camera.lens, resolution: current?.resolution,
                                                                             frameRate: current?.frameRate)), id: \.self) {
                        Text($0.label).tag(Optional($0))
                    }
                }
                Picker("Codec", selection: Binding(get: { camera.codec }, set: { camera.selectCodec($0) })) {
                    ForEach(caps.videoCodecs, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Stabilisation", isOn: Binding(get: { camera.stabilization }, set: { camera.setStabilization($0) }))
                Section {
                    Text("Le Log et le HDR ne sont proposés que si l'objectif et le format les prennent en charge. Un fichier Log se développe dans l'éditeur vidéo.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Vidéo")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
