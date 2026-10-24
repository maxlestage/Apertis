import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import ApertisCore

struct VideoEditorView: View {
    @StateObject private var model: VideoEditorModel
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
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                PhotosPicker(selection: $pickerItems, matching: .videos, preferredItemEncoding: .current) {
                    Image(systemName: "plus.rectangle.on.rectangle")
                }
                .accessibilityLabel("Ajouter des vidéos")
                Button { importingMusic = true } label: { Image(systemName: "music.note") }
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

    private func grade(_ title: String, _ keyPath: WritableKeyPath<DevelopSettings, Double>,
                       range: ClosedRange<Double> = -100...100, format: String = "%+.0f") -> some View {
        AdjustmentSlider(title: title,
                         value: Binding(get: { clip.grade[keyPath: keyPath] },
                                        set: { value in model.updateGrade(clip.id) { $0[keyPath: keyPath] = value } }),
                         range: range, format: format) { _ in model.commitGrade() }
    }

    private var gradePanel: some View {
        VStack(spacing: 12) {
            grade("Exposition", \.exposure, range: -3...3, format: "%+.2f IL")
            grade("Contraste", \.contrast)
            grade("Hautes lumières", \.highlights)
            grade("Ombres", \.shadows)
            grade("Température", \.temperature)
            grade("Teinte", \.tint)
            grade("Vibrance", \.vibrance)
            grade("Saturation", \.saturation)
            grade("Fondu", \.fade, range: 0...100, format: "%.0f")
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
            Button("Appliquer cet étalonnage à tous les plans") { model.applyGradeToAllClips(from: clip.id) }
                .buttonStyle(.bordered)
        }
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
