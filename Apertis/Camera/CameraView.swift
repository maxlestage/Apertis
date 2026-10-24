import SwiftUI
import ApertisCore

struct CameraView: View {
    @EnvironmentObject private var store: MediaStore
    @StateObject private var camera = CameraController()
    @State private var showGrid = true
    @State private var showManual = false
    @State private var showVideoSettings = false
    @State private var flash = false
    @State private var message: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                ZStack {
                    CameraPreviewView(session: camera.session) { camera.focus(at: $0) }
                    if showGrid { GridOverlay() }
                    if flash { Color.black.opacity(0.6).transition(.opacity) }
                    statusOverlay
                }
                .aspectRatio(camera.mode == .photo ? 3.0 / 4.0 : 9.0 / 16.0, contentMode: .fit)
                .clipped()
                if showManual { ManualControlsPanel(camera: camera).transition(.move(edge: .bottom)) }
                Spacer(minLength: 0)
                bottomBar
            }
        }
        .foregroundStyle(.white)
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            camera.onPhotoCaptured = { capture in
                do { try store.addCapturedPhoto(capture) } catch { message = "Enregistrement impossible : \(error.localizedDescription)" }
            }
            camera.onMovieRecorded = { url in
                Task {
                    do { _ = try await store.addRecordedMovie(at: url) } catch { message = "Vidéo non enregistrée : \(error.localizedDescription)" }
                }
            }
            camera.start()
        }
        .onDisappear { camera.stop() }
        .sheet(isPresented: $showVideoSettings) {
            VideoSettingsSheet(camera: camera).presentationDetents([.medium])
        }
        .alert("Caméra", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: Barres

    private var topBar: some View {
        HStack(spacing: 16) {
            Button { showGrid.toggle() } label: {
                Image(systemName: showGrid ? "grid" : "square").accessibilityLabel("Grille")
            }
            if camera.mode == .photo {
                Menu {
                    ForEach(availableRAWModes) { mode in
                        Button(mode.label) { camera.setRAWMode(mode) }
                    }
                } label: {
                    Text(camera.rawMode.label)
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

    private var bottomBar: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                ForEach(camera.capabilities.photo.lenses, id: \.self) { lens in
                    Button(lens.label) { camera.selectLens(lens) }
                        .font(.caption.bold())
                        .frame(width: 44, height: 32)
                        .background(lens == camera.lens ? Color.yellow.opacity(0.9) : Color.white.opacity(0.15), in: Capsule())
                        .foregroundStyle(lens == camera.lens ? .black : .white)
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
        .padding(.bottom, 12)
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
                    Circle().fill(Color.white).frame(width: 60, height: 60)
                } else {
                    RoundedRectangle(cornerRadius: camera.isRecording ? 6 : 30)
                        .fill(Color.red)
                        .frame(width: camera.isRecording ? 30 : 60, height: camera.isRecording ? 30 : 60)
                }
            }
        }
        .disabled(camera.status != .ready || camera.isCapturingPhoto)
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

/// Exposition, balance des blancs et mise au point manuelles.
struct ManualControlsPanel: View {
    @ObservedObject var camera: CameraController

    var body: some View {
        VStack(spacing: 10) {
            Toggle("Exposition manuelle", isOn: Binding(get: { camera.manualExposure }, set: { camera.setManualExposure($0) }))
            if camera.manualExposure {
                LabeledSlider(label: "ISO", value: Binding(get: { Double(camera.iso) }, set: { camera.setManualExposure(true, iso: Float($0)) }),
                              range: Double(camera.isoRange.lowerBound)...Double(camera.isoRange.upperBound),
                              format: { String(format: "%.0f", $0) })
                // Curseur logarithmique : la vitesse varie sur plusieurs ordres de grandeur.
                LabeledSlider(label: "Vitesse",
                              value: Binding(get: { log2(camera.shutter) }, set: { camera.setManualExposure(true, shutter: exp2($0)) }),
                              range: log2(camera.shutterRange.lowerBound)...log2(camera.shutterRange.upperBound),
                              format: { Self.shutterText(exp2($0)) })
            } else {
                LabeledSlider(label: "IL", value: Binding(get: { Double(camera.exposureBias) }, set: { camera.setManualExposure(false, bias: Float($0)) }),
                              range: Double(camera.biasRange.lowerBound)...Double(camera.biasRange.upperBound),
                              format: { String(format: "%+.1f", $0) })
            }
            Toggle("Balance des blancs manuelle",
                   isOn: Binding(get: { camera.manualWhiteBalance }, set: { camera.setManualWhiteBalance($0) }))
            if camera.manualWhiteBalance {
                LabeledSlider(label: "Kelvin", value: Binding(get: { Double(camera.kelvin) }, set: { camera.setManualWhiteBalance(true, kelvin: Float($0)) }),
                              range: 2500...10000, format: { String(format: "%.0f K", $0) })
                LabeledSlider(label: "Teinte", value: Binding(get: { Double(camera.whiteBalanceTint) }, set: { camera.setManualWhiteBalance(true, tint: Float($0)) }),
                              range: -150...150, format: { String(format: "%+.0f", $0) })
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

    static func shutterText(_ seconds: Double) -> String {
        seconds >= 0.5 ? String(format: "%.1f s", seconds) : "1/\(Int((1 / seconds).rounded()))"
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
