import SwiftUI
import ApertisCore

/// Panneau pro : exposition, aides à la visée, prise de vue, réglages personnels.
struct ProPanel: View {
    @ObservedObject var camera: CameraController
    @State private var tab: Tab = .exposure

    enum Tab: String, CaseIterable, Identifiable {
        case exposure, assist, drive, presets
        var id: String { rawValue }
        var label: String {
            switch self {
            case .exposure: return "Expo"
            case .assist: return "Visée"
            case .drive: return "Prise de vue"
            case .presets: return "Perso"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panneau", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            switch tab {
            case .exposure: ManualControlsPanel(camera: camera)
            case .assist: AssistPanel(camera: camera)
            case .drive: DrivePanel(camera: camera)
            case .presets: PresetsPanel(camera: camera)
            }
        }
        .background(Color.black.opacity(0.85))
    }
}

/// Peaking, zébras, fausses couleurs, loupe et cadres de visée.
struct AssistPanel: View {
    @ObservedObject var camera: CameraController

    private func binding<T>(_ keyPath: WritableKeyPath<AssistSettings, T>) -> Binding<T> {
        Binding(get: { camera.assist[keyPath: keyPath] }, set: { value in
            var assist = camera.assist
            assist[keyPath: keyPath] = value
            camera.setAssist(assist)
        })
    }

    var body: some View {
        VStack(spacing: 10) {
            Toggle("Focus peaking", isOn: binding(\.focusPeaking))
            if camera.assist.focusPeaking {
                LabeledSlider(label: "Sensibilité", value: Binding(get: { Double(1 - camera.assist.peakingThreshold) },
                                                                    set: { v in binding(\.peakingThreshold).wrappedValue = Float(1 - v) }),
                              range: 0.5...0.95, format: { String(format: "%.0f %%", ($0 - 0.5) / 0.45 * 100) })
            }
            Toggle("Zébras", isOn: binding(\.zebras))
            if camera.assist.zebras {
                LabeledSlider(label: "Niveau", value: Binding(get: { Double(camera.assist.zebraLevel) },
                                                               set: { binding(\.zebraLevel).wrappedValue = Float($0) }),
                              range: 0.7...1, format: { String(format: "%.0f IRE", $0 * 100) })
            }
            Toggle("Fausses couleurs", isOn: binding(\.falseColor))
            if camera.assist.falseColor { FalseColorLegend() }
            Toggle("Loupe de mise au point", isOn: binding(\.loupe))
            if camera.assist.loupe {
                Text("Touchez le viseur pour placer la loupe.").font(.caption2).foregroundStyle(.secondary)
            }
            Divider().background(Color.white.opacity(0.2))
            HStack {
                Text("Cadre")
                Spacer()
                Menu {
                    ForEach(FrameGuide.options, id: \.self) { aspect in
                        Button(aspect == 0 ? "Aucun" : CropSettings.aspects[aspect].label) { camera.setFrameGuide(aspect) }
                    }
                } label: {
                    Text(camera.frameGuide == 0 ? "Aucun" : CropSettings.aspects[camera.frameGuide].label)
                        .font(.footnote.bold())
                }
            }
            if camera.frameGuide > 0 {
                Text("Les photos sont recadrées à ce format dans l'éditeur, sans rien perdre de l'original.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .tint(.yellow)
        .padding()
    }
}

/// Échelle des fausses couleurs.
struct FalseColorLegend: View {
    private let items: [(Color, String)] = [
        (Color(red: 0.55, green: 0, blue: 0.65), "Bouché"), (Color(red: 0.05, green: 0.25, blue: 0.95), "Ombres"),
        (Color(red: 0.15, green: 0.8, blue: 0.25), "Gris 18 %"), (Color(red: 0.95, green: 0.55, blue: 0.65), "Peau"),
        (Color(red: 1, green: 0.85, blue: 0.1), "Hautes"), (Color(red: 1, green: 0.1, blue: 0.1), "Brûlé"),
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items.indices, id: \.self) { i in
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2).fill(items[i].0).frame(height: 8)
                    Text(items[i].1).font(.system(size: 8))
                }
            }
        }
    }
}

/// Bracketing, pose longue, intervallomètre, traitement, blanc et priorités de l'automatisme.
struct DrivePanel: View {
    @ObservedObject var camera: CameraController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Entraînement", selection: Binding(get: { camera.drive }, set: { camera.setDrive($0) })) {
                ForEach(DriveMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            switch camera.drive {
            case .single:
                Text("Une photo à chaque appui.").font(.caption2).foregroundStyle(.secondary)
            case .bracketing:
                bracketing
            case .longExposure:
                longExposure
            case .intervalometer:
                intervalometer
            }
            Divider().background(Color.white.opacity(0.2))
            Toggle(isOn: Binding(get: { camera.minimalProcessing }, set: { camera.setMinimalProcessing($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Traitement minimal")
                    Text("Sans fusion multi-images (Smart HDR, Deep Fusion) : un rendu naturel, proche du capteur.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Button {
                camera.beginWhiteMeasurement()
            } label: {
                Label("Balance des blancs sur charte grise", systemImage: "eyedropper")
            }
            .buttonStyle(.bordered)
            if !camera.supportedSignals.isEmpty { signals }
        }
        .font(.footnote)
        .tint(.yellow)
        .padding()
    }

    private var bracketing: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Vues", selection: Binding(get: { camera.bracketing.count }, set: { n in
                var b = camera.bracketing; b.count = n; camera.setBracketing(b)
            })) {
                ForEach(Bracketing.counts.filter { $0 <= max(camera.maxBracketCount, 3) }, id: \.self) { Text("\($0) vues").tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Écart", selection: Binding(get: { camera.bracketing.step }, set: { s in
                var b = camera.bracketing; b.step = s; camera.setBracketing(b)
            })) {
                ForEach(Bracketing.steps, id: \.self) { Text("±\(CameraFormat.ev($0)) IL").tag($0) }
            }
            .pickerStyle(.segmented)
            Text("Une photo par vue, en RAW si le RAW est choisi. À fusionner en HDR ou pour garder la mieux exposée.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var longExposure: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Effet", selection: Binding(get: { camera.longExposure.style }, set: { s in
                var l = camera.longExposure; l.style = s; camera.setLongExposure(l)
            })) {
                ForEach(LongExposureStyle.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Durée", selection: Binding(get: { camera.longExposure.duration }, set: { d in
                var l = camera.longExposure; l.duration = d; camera.setLongExposure(l)
            })) {
                ForEach(LongExposure.durations, id: \.self) { Text(CameraFormat.shutter($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(String(format: "Équivaut à un filtre ND d'environ %.0f IL. Posez l'appareil sur un support.",
                        camera.longExposure.equivalentNDStops(frameDuration: 1.0 / 30)))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var intervalometer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Intervalle", selection: Binding(get: { camera.intervalometer.interval }, set: { i in
                var p = camera.intervalometer; p.interval = i; camera.setIntervalometer(p)
            })) {
                ForEach(Intervalometer.intervals, id: \.self) { Text(CameraFormat.shutter($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Photos", selection: Binding(get: { camera.intervalometer.count }, set: { c in
                var p = camera.intervalometer; p.count = c; camera.setIntervalometer(p)
            })) {
                ForEach(Intervalometer.counts, id: \.self) { Text($0 == 0 ? "∞" : "\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            if let total = camera.intervalometer.totalDuration, let clip = camera.intervalometer.playbackDuration() {
                Text("Durée de la série : \(Self.duration(total)) · timelapse de \(Self.duration(clip)) à 25 i/s.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var signals: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Priorités de l'automatisme", isOn: Binding(get: { camera.customSignals != nil }, set: { custom in
                camera.setExposureSignals(custom ? [] : nil)
            }))
            if let enabled = camera.customSignals {
                ForEach(camera.supportedSignals) { signal in
                    Toggle(isOn: Binding(get: { enabled.contains(signal) }, set: { on in
                        var next = enabled
                        if on { next.insert(signal) } else { next.remove(signal) }
                        camera.setExposureSignals(next)
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(signal.label)
                            Text(signal.detail).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("L'iPhone choisit seul comment l'ouverture et la vitesse s'adaptent à la scène.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return "\(s / 3600) h \(String(format: "%02d", (s % 3600) / 60))" }
        if s >= 60 { return "\(s / 60) min \(String(format: "%02d", s % 60))" }
        return "\(s) s"
    }
}

/// Réglages personnels C1 à C3 : enregistrer l'état actuel, le rappeler d'un geste.
struct PresetsPanel: View {
    @ObservedObject var camera: CameraController
    @State private var naming: Int?
    @State private var name = ""

    var body: some View {
        VStack(spacing: 10) {
            ForEach(1...3, id: \.self) { slot in
                let preset = camera.presets.first { $0.slot == slot }
                HStack {
                    Text("C\(slot)").font(.headline).foregroundStyle(.yellow).frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset?.name ?? "Libre").bold()
                        Text(preset?.summary ?? "Enregistrez vos réglages actuels.").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let preset {
                        Button("Rappeler") { camera.applyPreset(preset) }.buttonStyle(.borderedProminent)
                    }
                    Menu {
                        Button("Enregistrer les réglages actuels") {
                            name = preset?.name ?? ""
                            naming = slot
                        }
                        if preset != nil {
                            Button("Effacer", role: .destructive) { camera.deletePreset(slot: slot) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .font(.footnote)
        .tint(.yellow)
        .padding()
        .alert("Réglage personnel", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Nom (Rue, Portrait, Nuit…)", text: $name)
            Button("Annuler", role: .cancel) { naming = nil }
            Button("Enregistrer") {
                if let slot = naming { camera.savePreset(slot: slot, name: name) }
                naming = nil
            }
        } message: {
            Text("Programme, ouverture, vitesse, ISO, balance des blancs, format, définition, focale, mode et cadre.")
        }
    }
}

/// Cadre de visée : la zone hors cadre est assombrie.
struct FrameGuideOverlay: View {
    let aspect: Int

    var body: some View {
        GeometryReader { proxy in
            let r = FrameGuide.rect(aspect: aspect, width: proxy.size.width, height: proxy.size.height)
            let frame = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
            Path { path in
                path.addRect(CGRect(origin: .zero, size: proxy.size))
                path.addRect(frame)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            Rectangle().stroke(Color.white.opacity(0.7), lineWidth: 1)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
            Text(CropSettings.aspects[aspect].label)
                .font(.caption2.bold())
                .padding(4)
                .position(x: frame.minX + 28, y: frame.minY + 12)
        }
        .allowsHitTesting(false)
    }
}

/// Aiguille de la cellule, de −3 à +3 IL, comme dans le viseur d'un reflex.
struct MeterNeedle: View {
    let offset: Float

    var body: some View {
        let needle = ExposureMeter.needle(offset: offset)
        HStack(spacing: 4) {
            Text("−").font(.caption2)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(0..<7) { i in
                            Rectangle().fill(Color.white.opacity(i == 3 ? 0.9 : 0.5)).frame(width: 1, height: i == 3 ? 8 : 5)
                            if i < 6 { Spacer(minLength: 0) }
                        }
                    }
                    Circle().fill(abs(needle) < 0.34 ? Color.green : Color.yellow).frame(width: 7, height: 7)
                        .offset(x: proxy.size.width * CGFloat((needle + 3) / 6) - 3.5)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(width: 84, height: 10)
            Text("+").font(.caption2)
            Text(ExposureMeter.label(offset: offset)).font(.caption2.monospacedDigit()).frame(width: 28, alignment: .leading)
        }
        .accessibilityLabel("Cellule : \(ExposureMeter.label(offset: offset)) IL")
    }
}
