import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import ApertisCore

struct VideoEditorView: View {
    @StateObject private var model: VideoEditorModel
    @EnvironmentObject private var subscription: Subscription
    @State private var showingOriginal = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var importingMusic = false
    @State private var showExport = false
    @State private var inspector: Inspector = .edit

    enum Inspector: String, CaseIterable, Identifiable {
        case edit, grade, audio
        var id: String { rawValue }
        var label: String {
            switch self {
            case .edit: return "Montage"
            case .grade: return "Étalonnage"
            case .audio: return "Audio"
            }
        }
    }

    init(project: VideoProject, store: MediaStore) {
        _model = StateObject(wrappedValue: VideoEditorModel(project: project, store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                VideoPlayer(player: model.player)
                if model.isBuilding { ProgressView().tint(.white) }
                VStack {
                    HStack {
                        if showingOriginal {
                            Text("Avant").font(.caption.bold()).padding(6).background(.ultraThinMaterial, in: Capsule())
                        }
                        Spacer()
                        // Avant / après : maintenir pour voir le montage sans étalonnage.
                        Image(systemName: "square.split.2x1")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(9)
                            .background(.ultraThinMaterial, in: Circle())
                            .onLongPressGesture(minimumDuration: 0, maximumDistance: 60, perform: {}, onPressingChanged: { pressing in
                                showingOriginal = pressing
                                model.showOriginal(pressing)
                            })
                            .accessibilityLabel("Maintenir pour voir l'original")
                    }
                    Spacer()
                }
                .padding(8)
                if let progress = model.exportProgress {
                    VStack {
                        ProgressView(value: Double(progress))
                        Text("Export \(Int(progress * 100)) %").font(.caption)
                    }
                    .padding()
                    .frame(width: 220)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(Color.black)

            transport
            TimelineStrip(model: model)
            Divider()
            if let clip = model.selectedClip {
                Picker("Inspecteur", selection: $inspector) {
                    ForEach(Inspector.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                ScrollView {
                    ClipInspector(model: model, clip: clip, inspector: inspector).padding()
                }
            } else {
                ContentUnavailableView("Aucun plan sélectionné", systemImage: "film",
                                       description: Text("Ajoutez des vidéos puis touchez un plan pour le monter et l'étalonner."))
            }
        }
        .navigationTitle(model.project.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.perClipGrading = subscription.isPro }
        .onChange(of: subscription.isPro) { _, pro in model.perClipGrading = pro }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                PhotosPicker(selection: $pickerItems, matching: .videos, preferredItemEncoding: .current) {
                    Image(systemName: "plus.rectangle.on.rectangle")
                }
                .accessibilityLabel("Ajouter des vidéos")
                Button { if subscription.allows(.audioTracks) { importingMusic = true } } label: { Image(systemName: "music.note") }
                    .accessibilityLabel("Ajouter une musique")
                Button { showExport = true } label: { Image(systemName: "square.and.arrow.up") }
                    .disabled(model.mainClips.isEmpty || model.exportProgress != nil)
                    .accessibilityLabel("Exporter")
            }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task {
                var urls: [URL] = []
                for item in items {
                    if let file = try? await item.loadTransferable(type: ImportedFile.self) { urls.append(file.url) }
                }
                model.importMedia(urls, asMusic: false)
            }
        }
        .fileImporter(isPresented: $importingMusic, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let copies = urls.compactMap { ImportedFile.copyToTemporary($0) }
            model.importMedia(copies, asMusic: true)
        }
        .confirmationDialog("Exporter la vidéo", isPresented: $showExport, titleVisibility: .visible) {
            ForEach(VideoExportPreset.allCases) { preset in
                Button(preset.label) { model.export(preset, saveToPhotos: true) }
            }
        }
        .alert("Vidéo", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private var transport: some View {
        HStack(spacing: 16) {
            Text(Self.timecode(model.currentTime, fps: model.timeline.frameRate.seconds))
                .font(.system(.footnote, design: .monospaced))
            Slider(value: Binding(get: { model.currentTime }, set: { model.seek(to: $0) }), in: 0...max(model.duration, 0.1))
            Button { model.splitAtPlayhead() } label: { Image(systemName: "scissors") }
                .accessibilityLabel("Couper à la tête de lecture")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    /// Timecode HH:MM:SS:II (images).
    static func timecode(_ seconds: Double, fps: Double) -> String {
        let rate = max(Int(fps.rounded()), 1)
        let totalFrames = Int((seconds * fps).rounded(.down))
        let frames = totalFrames % rate
        let total = totalFrames / rate
        return String(format: "%02d:%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60, frames)
    }
}

/// Pistes vidéo principale et audio, proportionnelles à la durée.
private struct TimelineStrip: View {
    @ObservedObject var model: VideoEditorModel
    private let pointsPerSecond: CGFloat = 36

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 6) {
                row(model.mainClips, height: 54, tint: .blue)
                row(model.audioClips, height: 28, tint: .green)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(height: 112)
    }

    private func row(_ clips: [Clip], height: CGFloat, tint: Color) -> some View {
        HStack(spacing: 2) {
            ForEach(clips) { clip in
                let width = max(CGFloat(clip.duration.seconds) * pointsPerSecond, 24)
                ZStack(alignment: .bottomLeading) {
                    if let thumbnail = model.thumbnails[clip.mediaID] {
                        Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                            .frame(width: width, height: height).clipped()
                    } else {
                        tint.opacity(0.35)
                    }
                    if clip.speed != .one {
                        Text("×\(clip.speed.seconds, specifier: "%.2g")").font(.caption2.bold()).padding(2)
                            .background(Color.black.opacity(0.6))
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(model.selectedClipID == clip.id ? Color.yellow : Color.clear, lineWidth: 2))
                .onTapGesture { model.selectedClipID = clip.id }
            }
            if clips.isEmpty {
                Text(height > 40 ? "Piste vidéo vide" : "Piste audio vide").font(.caption).foregroundStyle(.secondary)
                    .frame(height: height)
            }
        }
    }
}

private struct ClipInspector: View {
    @ObservedObject var model: VideoEditorModel
    let clip: Clip
    let inspector: VideoEditorView.Inspector

    var body: some View {
        switch inspector {
        case .edit: editPanel
        case .grade: gradePanel
        case .audio: audioPanel
        }
    }

    private var mediaDuration: Double {
        model.project.media[clip.mediaID]?.duration?.seconds ?? clip.sourceOut.seconds
    }

    private var editPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            TrimControl(clip: clip, mediaDuration: mediaDuration) { inPoint, outPoint in
                model.trim(clip.id, sourceIn: inPoint, sourceOut: outPoint)
            }
            HStack {
                Text("Vitesse").font(.footnote)
                Spacer()
                Picker("Vitesse", selection: Binding(get: { clip.speed }, set: { model.setSpeed(clip.id, $0) })) {
                    ForEach([Rational(1, 4), Rational(1, 2), Rational(1), Rational(2), Rational(4)], id: \.self) {
                        Text("×\($0.seconds, specifier: "%g")").tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
            HStack {
                Button { model.move(clip.id, by: -1) } label: { Label("Avancer", systemImage: "arrow.left") }
                Button { model.move(clip.id, by: 1) } label: { Label("Reculer", systemImage: "arrow.right") }
                Spacer()
                Button(role: .destructive) { model.delete(clip.id) } label: { Label("Supprimer", systemImage: "trash") }
            }
            .buttonStyle(.bordered)
            .font(.footnote)
        }
    }

    private var gradePanel: some View {
        ClipGradePanel(model: model, clip: clip)
    }

    private var audioPanel: some View {
        VStack(spacing: 12) {
            AdjustmentSlider(title: "Volume", value: Binding(get: { clip.volume * 100 }, set: { model.setVolume(clip.id, $0 / 100) }),
                             range: 0...200, format: "%.0f %%") { _ in }
            ForEach(model.timeline.tracks) { track in
                Toggle("Couper la piste \(track.name)", isOn: Binding(get: { track.isMuted }, set: { model.setMuted(track.id, $0) }))
                    .font(.footnote)
            }
        }
    }
}

/// Points d'entrée et de sortie : appliqués à la fin du geste pour ne pas reconstruire
/// la composition à chaque image.
private struct TrimControl: View {
    let clip: Clip
    let mediaDuration: Double
    let onCommit: (Double, Double) -> Void
    @State private var inPoint: Double = 0
    @State private var outPoint: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Entrée \(inPoint, specifier: "%.2f") s — Sortie \(outPoint, specifier: "%.2f") s")
                .font(.footnote.monospacedDigit())
            Slider(value: $inPoint, in: 0...max(mediaDuration, 0.1)) { editing in
                if !editing { commit() }
            }
            Slider(value: $outPoint, in: 0...max(mediaDuration, 0.1)) { editing in
                if !editing { commit() }
            }
        }
        .onAppear(perform: sync)
        .onChange(of: clip) { _, _ in sync() }
    }

    private func sync() {
        inPoint = clip.sourceIn.seconds
        outPoint = clip.sourceOut.seconds
    }

    private func commit() {
        let minimum = 0.1
        if outPoint - inPoint < minimum { outPoint = min(inPoint + minimum, mediaDuration) }
        onCommit(inPoint, outPoint)
    }
}

/// Étalonnage d'un plan : les mêmes panneaux que le laboratoire vidéo du site.
private struct ClipGradePanel: View {
    @ObservedObject var model: VideoEditorModel
    @EnvironmentObject private var subscription: Subscription
    @ObservedObject private var library = StyleLibrary.shared
    let clip: Clip
    @State private var section: Pane = .styles
    @State private var hslRange: HSLRange = .red
    @State private var gradeZone = 0

    enum Pane: String, CaseIterable, Identifiable {
        case styles, light, color, curve, hsl, grading, effects, frame
        var id: String { rawValue }
        var label: String {
            switch self {
            case .styles: return "Styles"
            case .light: return "Lumière"
            case .color: return "Couleur"
            case .curve: return "Courbe"
            case .hsl: return "TSL"
            case .grading: return "Étalonnage"
            case .effects: return "Effets"
            case .frame: return "Cadrage"
            }
        }
        var proFeature: ProFeature? {
            switch self {
            case .curve: return .curves
            case .hsl: return .hsl
            case .grading: return .grading
            default: return nil
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Pane.allCases) { item in
                        Button {
                            section = item
                        } label: {
                            HStack(spacing: 3) {
                                Text(item.label)
                                if item.proFeature != nil && !subscription.isPro { Image(systemName: "lock.fill").font(.system(size: 8)) }
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(section == item ? .accentColor : .secondary)
                        .font(.footnote)
                    }
                }
            }
            if !subscription.isPro {
                Label("Réglages appliqués à tout le montage. L'étalonnage plan par plan fait partie d'Apertis Pro.", systemImage: "info.circle")
                    .font(.caption2).foregroundStyle(.secondary)
                    .onTapGesture { subscription.requested = .clipGrading }
            }
            Group {
                switch section {
                case .styles: styles
                case .light: light
                case .color: color
                case .curve: curve
                case .hsl: hsl
                case .grading: grading
                case .effects: effects
                case .frame: frame
                }
            }
            .modifier(VideoProLock(feature: section.proFeature))
            if subscription.isPro {
                Button("Appliquer cet étalonnage à tous les plans") { model.applyGradeToAllClips(from: clip.id) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func slider(_ title: String, _ keyPath: WritableKeyPath<DevelopSettings, Double>,
                        range: ClosedRange<Double> = -100...100, neutral: Double = 0, format: String = "%+.0f") -> some View {
        AdjustmentSlider(title: title,
                         value: Binding(get: { clip.grade[keyPath: keyPath] },
                                        set: { value in model.updateGrade(clip.id) { $0[keyPath: keyPath] = value } }),
                         range: range, neutral: neutral, format: format) { _ in model.commitGrade() }
    }

    private var styles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(BuiltInPresets.all + library.styles) { preset in
                    let available = subscription.isAvailable(preset)
                    Button {
                        if available { model.applyStyle(preset, to: clip.id) } else { subscription.requested = .allStyles }
                    } label: {
                        HStack(spacing: 3) {
                            Text(preset.name)
                            if !available { Image(systemName: "lock.fill").font(.system(size: 8)) }
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.footnote)
                }
            }
        }
    }

    private var light: some View {
        VStack(spacing: 12) {
            slider("Exposition", \.exposure, range: -5...5, format: "%+.2f IL")
            slider("Contraste", \.contrast)
            slider("Hautes lumières", \.highlights)
            slider("Ombres", \.shadows)
            slider("Blancs", \.whites)
            slider("Noirs", \.blacks)
        }
    }

    private var color: some View {
        VStack(spacing: 12) {
            slider("Température", \.temperature)
            slider("Teinte", \.tint)
            slider("Vibrance", \.vibrance)
            slider("Saturation", \.saturation)
        }
    }

    private var curve: some View {
        let zones = ["Ombres profondes", "Tons sombres", "Tons clairs", "Hautes lumières"]
        return VStack(spacing: 12) {
            ForEach(zones.indices, id: \.self) { i in
                AdjustmentSlider(title: zones[i],
                                 value: Binding(get: { clip.grade.parametricCurve[i] },
                                                set: { v in model.updateGrade(clip.id) { $0.parametricCurve[i] = v } })) { _ in model.commitGrade() }
            }
        }
    }

    private var hsl: some View {
        let range = hslRange
        func binding(_ field: WritableKeyPath<HSLBand, Double>) -> Binding<Double> {
            Binding(get: { clip.grade.hsl[range][keyPath: field] },
                    set: { v in model.updateGrade(clip.id) { $0.hsl[range][keyPath: field] = v } })
        }
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                ForEach(HSLRange.allCases, id: \.self) { item in
                    Circle()
                        .fill(Color(hue: Double(item.centerHue) / 360, saturation: 0.85, brightness: 0.9))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().stroke(Color.primary, lineWidth: item == hslRange ? 2 : 0).padding(-3))
                        .onTapGesture { hslRange = item }
                        .accessibilityLabel(item.label)
                }
            }
            Text(range.label).font(.caption.bold())
            AdjustmentSlider(title: "Teinte", value: binding(\.hue)) { _ in model.commitGrade() }
            AdjustmentSlider(title: "Saturation", value: binding(\.saturation)) { _ in model.commitGrade() }
            AdjustmentSlider(title: "Luminance", value: binding(\.luminance)) { _ in model.commitGrade() }
        }
    }

    private var grading: some View {
        let zones: [(String, WritableKeyPath<ColorGrading, GradeWheel>, Double)] = [
            ("Ombres", \.shadows, 210), ("Tons moyens", \.midtones, 0), ("Hautes lumières", \.highlights, 40),
        ]
        let zone = zones[gradeZone]
        func binding(_ field: WritableKeyPath<GradeWheel, Double>) -> Binding<Double> {
            Binding(get: { clip.grade.grading[keyPath: zone.1][keyPath: field] },
                    set: { v in model.updateGrade(clip.id) { $0.grading[keyPath: zone.1][keyPath: field] = v } })
        }
        return VStack(spacing: 12) {
            Picker("Zone", selection: $gradeZone) {
                ForEach(zones.indices, id: \.self) { Text(zones[$0].0).tag($0) }
            }
            .pickerStyle(.segmented)
            AdjustmentSlider(title: "Teinte", value: binding(\.hue), range: 0...360, neutral: zone.2, format: "%.0f°") { _ in model.commitGrade() }
            AdjustmentSlider(title: "Intensité", value: binding(\.saturation), range: 0...100, format: "%.0f") { _ in model.commitGrade() }
            AdjustmentSlider(title: "Luminosité", value: binding(\.luminance)) { _ in model.commitGrade() }
            slider("Fondu", \.fade, range: 0...100, format: "%.0f")
        }
    }

    private var effects: some View {
        VStack(spacing: 12) {
            slider("Fondu", \.fade, range: 0...100, format: "%.0f")
            slider("Grain", \.grain, range: 0...100, format: "%.0f")
            slider("Taille du grain", \.grainSize, range: 1...4, neutral: 1.5, format: "%.1f")
            slider("Vignette", \.vignette)
            slider("Netteté", \.sharpness, range: 0...100, format: "%.0f")
            lut.proLocked(.lut)
        }
    }

    private var lut: some View {
        VStack(spacing: 12) {
            HStack {
                Text("LUT").font(.footnote)
                Spacer()
                Menu(clip.grade.lut.flatMap { ref in LUTLibrary.shared.entries.first { $0.identifier == ref.identifier }?.title } ?? "Aucune") {
                    Button("Aucune") {
                        model.updateGrade(clip.id) { $0.lut = nil }
                        model.commitGrade()
                    }
                    ForEach(LUTLibrary.shared.entries) { entry in
                        Button(entry.title) {
                            model.updateGrade(clip.id) { $0.lut = LUTReference(identifier: entry.identifier) }
                            model.commitGrade()
                        }
                    }
                }
            }
            if clip.grade.lut != nil {
                AdjustmentSlider(title: "Intensité LUT",
                                 value: Binding(get: { clip.grade.lut?.intensity ?? 100 },
                                                set: { v in model.updateGrade(clip.id) { $0.lut?.intensity = v } }),
                                 range: 0...100, format: "%.0f") { _ in model.commitGrade() }
            }
            Text("Images Log : appliquez la LUT de conversion du fabricant (par exemple Apple Log → Rec. 709) avant vos réglages créatifs. Les LUT s'importent depuis l'éditeur photo.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var frame: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Format du film").font(.footnote.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(CropSettings.aspects.indices, id: \.self) { i in
                        Button(CropSettings.aspects[i].label) { model.setFilmAspect(i) }
                            .buttonStyle(.bordered)
                            .tint(model.filmAspect == i ? .accentColor : .secondary)
                    }
                }
            }
            AdjustmentSlider(title: "Redresser",
                             value: Binding(get: { clip.grade.crop.angle }, set: { v in model.updateGrade(clip.id) { $0.crop.angle = v } }),
                             range: -45...45, format: "%+.1f°") { _ in model.commitGrade() }
        }
    }
}

private struct VideoProLock: ViewModifier {
    let feature: ProFeature?

    func body(content: Content) -> some View {
        if let feature { content.proLocked(feature) } else { content }
    }
}
