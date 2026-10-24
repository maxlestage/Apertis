import SwiftUI
import UniformTypeIdentifiers
import ApertisCore

struct PhotoEditorView: View {
    @StateObject private var model: PhotoEditorModel
    @State private var tool: Tool = .styles
    @State private var showingOriginal = false
    @State private var showExport = false

    init(project: PhotoProject, store: MediaStore) {
        _model = StateObject(wrappedValue: PhotoEditorModel(project: project, store: store))
    }

    enum Tool: String, CaseIterable, Identifiable {
        case styles, light, color, curves, hsl, grading, effects, details, geometry
        var id: String { rawValue }
        var label: String {
            switch self {
            case .styles: return "Styles"
            case .light: return "Lumière"
            case .color: return "Couleur"
            case .curves: return "Courbes"
            case .hsl: return "TSL"
            case .grading: return "Étalonnage"
            case .effects: return "Effets"
            case .details: return "Détails"
            case .geometry: return "Recadrage"
            }
        }
        var icon: String {
            switch self {
            case .styles: return "square.stack.3d.up"
            case .light: return "sun.max"
            case .color: return "thermometer.medium"
            case .curves: return "point.topleft.down.to.point.bottomright.curvepath"
            case .hsl: return "paintpalette"
            case .grading: return "circle.lefthalf.filled"
            case .effects: return "sparkles"
            case .details: return "triangle"
            case .geometry: return "crop.rotate"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            previewArea
            toolPicker
            ScrollView {
                ToolPanel(tool: tool, model: model).padding()
            }
            .frame(height: 280)
            .background(Color(.secondarySystemBackground))
        }
        .navigationTitle(model.project.source.originalFileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!model.canUndo).accessibilityLabel("Annuler")
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!model.canRedo).accessibilityLabel("Rétablir")
                Menu {
                    Button("Réinitialiser", role: .destructive) { model.reset() }
                    Section("Historique") {
                        ForEach(Array(model.project.history.entries.enumerated().reversed()), id: \.offset) { index, entry in
                            Text((index == model.project.history.index ? "• " : "") + entry.label)
                        }
                    }
                } label: { Image(systemName: "clock.arrow.circlepath") }
                Button { showExport = true } label: { Image(systemName: "square.and.arrow.up") }
                    .disabled(model.preview == nil).accessibilityLabel("Exporter")
            }
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(model: model).presentationDetents([.medium])
        }
        .alert("Export", isPresented: Binding(get: { model.exportMessage != nil }, set: { if !$0 { model.exportMessage = nil } })) {
            Button("OK") { model.exportMessage = nil }
        } message: { Text(model.exportMessage ?? "") }
    }

    private var previewArea: some View {
        ZStack {
            Color.black
            if let image = showingOriginal ? model.original : model.preview {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else if let error = model.loadError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.white).padding()
            } else {
                ProgressView().tint(.white)
            }
            if showingOriginal {
                Text("Original").font(.caption.bold()).padding(6).background(.ultraThinMaterial, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding()
            }
            if model.isExporting { ProgressView("Export…").padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)) }
        }
        // Appui prolongé : comparaison avec l'original.
        .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 50, perform: {}, onPressingChanged: { showingOriginal = $0 })
    }

    private var toolPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(Tool.allCases) { item in
                    Button { tool = item } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.icon).font(.system(size: 18))
                            Text(item.label).font(.caption2)
                        }
                        .foregroundStyle(item == tool ? Color.accentColor : .primary)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(Color(.systemBackground))
    }
}

/// Curseur de réglage : double-tap sur le libellé pour revenir à la valeur neutre.
struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var neutral: Double = 0
    var step: Double? = nil
    var format: String = "%+.0f"
    let onCommit: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .onTapGesture(count: 2) {
                        value = neutral
                        onCommit(title)
                    }
                Spacer()
                Text(String(format: format, value)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.footnote)
            Slider(value: $value, in: range) { editing in
                if !editing { onCommit(title) }
            }
        }
    }
}

private struct ToolPanel: View {
    let tool: PhotoEditorView.Tool
    @ObservedObject var model: PhotoEditorModel
    @State private var curveChannel = 0
    @State private var hslRange: HSLRange = .red
    @State private var gradeZone = 0
    @State private var importingLUT = false
    @ObservedObject private var luts = LUTLibrary.shared

    var body: some View {
        switch tool {
        case .styles: styles
        case .light: light
        case .color: color
        case .curves: curves
        case .hsl: hsl
        case .grading: grading
        case .effects: effects
        case .details: details
        case .geometry: geometry
        }
    }

    private func slider(_ title: String, _ keyPath: WritableKeyPath<DevelopSettings, Double>,
                        range: ClosedRange<Double> = -100...100, format: String = "%+.0f") -> some View {
        AdjustmentSlider(title: title, value: model.binding(keyPath), range: range, format: format) { model.commit($0) }
    }

    private var styles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 10) {
            ForEach(BuiltInPresets.all) { preset in
                Button(preset.name) { model.apply(preset) }
                    .buttonStyle(.bordered)
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

    private var curves: some View {
        let channels: [(String, WritableKeyPath<CurveSet, [CurvePoint]>, Color)] = [
            ("Luminance", \.master, .primary), ("Rouge", \.red, .red), ("Vert", \.green, .green), ("Bleu", \.blue, .blue),
        ]
        let channel = channels[curveChannel]
        return VStack(spacing: 10) {
            Picker("Canal", selection: $curveChannel) {
                ForEach(channels.indices, id: \.self) { Text(channels[$0].0).tag($0) }
            }
            .pickerStyle(.segmented)
            CurveEditor(points: Binding(get: { model.settings.curves[keyPath: channel.1] },
                                        set: { model.settings.curves[keyPath: channel.1] = $0 }),
                        color: channel.2) { model.commit("Courbe \(channel.0)") }
                .frame(height: 200)
            Text("Touchez pour ajouter un point, glissez-le hors du cadre pour le supprimer.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var hsl: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ForEach(HSLRange.allCases, id: \.self) { range in
                    Circle()
                        .fill(Color(hue: Double(range.centerHue) / 360, saturation: 0.85, brightness: 0.9))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().stroke(Color.primary, lineWidth: range == hslRange ? 2 : 0).padding(-3))
                        .onTapGesture { hslRange = range }
                        .accessibilityLabel(range.label)
                }
            }
            Text(hslRange.label).font(.caption.bold())
            let base = \DevelopSettings.hsl
            AdjustmentSlider(title: "Teinte", value: hslBinding(base, \.hue)) { _ in model.commit("TSL \(hslRange.label)") }
            AdjustmentSlider(title: "Saturation", value: hslBinding(base, \.saturation)) { _ in model.commit("TSL \(hslRange.label)") }
            AdjustmentSlider(title: "Luminance", value: hslBinding(base, \.luminance)) { _ in model.commit("TSL \(hslRange.label)") }
        }
    }

    private func hslBinding(_ base: WritableKeyPath<DevelopSettings, HSLAdjustments>,
                            _ field: WritableKeyPath<HSLBand, Double>) -> Binding<Double> {
        let range = hslRange
        return Binding(get: { model.settings[keyPath: base][range][keyPath: field] },
                       set: { model.settings[keyPath: base][range][keyPath: field] = $0 })
    }

    private var grading: some View {
        let zones: [(String, WritableKeyPath<ColorGrading, GradeWheel>)] = [
            ("Ombres", \.shadows), ("Tons moyens", \.midtones), ("Hautes lumières", \.highlights),
        ]
        let zone = zones[gradeZone]
        func binding(_ field: WritableKeyPath<GradeWheel, Double>) -> Binding<Double> {
            Binding(get: { model.settings.grading[keyPath: zone.1][keyPath: field] },
                    set: { model.settings.grading[keyPath: zone.1][keyPath: field] = $0 })
        }
        return VStack(spacing: 12) {
            Picker("Zone", selection: $gradeZone) {
                ForEach(zones.indices, id: \.self) { Text(zones[$0].0).tag($0) }
            }
            .pickerStyle(.segmented)
            AdjustmentSlider(title: "Teinte", value: binding(\.hue), range: 0...360, format: "%.0f°") { _ in model.commit("Étalonnage \(zone.0)") }
            LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { Color(hue: $0, saturation: 0.8, brightness: 0.9) },
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 6).clipShape(Capsule())
            AdjustmentSlider(title: "Intensité", value: binding(\.saturation), range: 0...100, format: "%.0f") { _ in model.commit("Étalonnage \(zone.0)") }
            AdjustmentSlider(title: "Luminosité", value: binding(\.luminance)) { _ in model.commit("Étalonnage \(zone.0)") }
        }
    }

    private var effects: some View {
        VStack(spacing: 12) {
            slider("Fondu", \.fade, range: 0...100, format: "%.0f")
            slider("Grain", \.grain, range: 0...100, format: "%.0f")
            slider("Vignette", \.vignette)
            HStack {
                Text("LUT").font(.footnote)
                Spacer()
                Menu(model.settings.lut.flatMap { ref in luts.entries.first { $0.identifier == ref.identifier }?.title } ?? "Aucune") {
                    Button("Aucune") {
                        model.settings.lut = nil
                        model.commit("LUT")
                    }
                    ForEach(luts.entries) { entry in
                        Button(entry.title) {
                            model.settings.lut = LUTReference(identifier: entry.identifier, intensity: model.settings.lut?.intensity ?? 100)
                            model.commit("LUT")
                        }
                    }
                    Divider()
                    Button("Importer un fichier .cube…") { importingLUT = true }
                }
            }
            if model.settings.lut != nil {
                AdjustmentSlider(title: "Intensité LUT",
                                 value: Binding(get: { model.settings.lut?.intensity ?? 100 }, set: { model.settings.lut?.intensity = $0 }),
                                 range: 0...100, format: "%.0f") { _ in model.commit("Intensité LUT") }
            }
        }
        .fileImporter(isPresented: $importingLUT, allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data]) { result in
            if case .success(let url) = result {
                do {
                    let entry = try LUTLibrary.shared.importLUT(from: url)
                    model.settings.lut = LUTReference(identifier: entry.identifier)
                    model.commit("LUT")
                } catch {
                    model.exportMessage = "LUT refusée : \(error.localizedDescription)"
                }
            }
        }
    }

    private var details: some View {
        VStack(spacing: 12) {
            slider("Netteté", \.sharpness, range: 0...100, format: "%.0f")
            slider("Réduction du bruit", \.noiseReduction, range: 0...100, format: "%.0f")
        }
    }

    private var geometry: some View {
        let ratios: [(String, Double?)] = [("Original", nil), ("1:1", 1), ("4:5", 4.0 / 5), ("3:2", 3.0 / 2), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16)]
        return VStack(spacing: 12) {
            AdjustmentSlider(title: "Redresser", value: Binding(get: { model.settings.crop.angle }, set: { model.settings.crop.angle = $0 }),
                             range: -45...45, format: "%+.1f°") { _ in model.commit("Redresser") }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(ratios.indices, id: \.self) { i in
                        Button(ratios[i].0) { model.setAspectRatio(ratios[i].1) }.buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}

struct ExportSheet: View {
    @ObservedObject var model: PhotoEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var format: PhotoExportFormat = .heif
    @State private var quality = 0.92
    @State private var removeLocation = false
    @State private var saveToPhotos = true

    var body: some View {
        NavigationStack {
            Form {
                Picker("Format", selection: $format) {
                    ForEach(PhotoExportFormat.allCases) { Text($0.label).tag($0) }
                }
                if format.isLossy {
                    LabeledContent("Qualité") {
                        Slider(value: $quality, in: 0.5...1)
                        Text("\(Int(quality * 100)) %").monospacedDigit()
                    }
                }
                Toggle("Retirer la localisation", isOn: $removeLocation)
                Toggle("Ajouter à Photos", isOn: $saveToPhotos)
                Section {
                    Text("Export en pleine résolution depuis l'original. L'original et le projet ne sont pas modifiés.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Exporter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Exporter") {
                        model.export(format: format, quality: quality, removeLocation: removeLocation, saveToPhotos: saveToPhotos)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
            }
        }
    }
}
