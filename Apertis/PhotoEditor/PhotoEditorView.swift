import SwiftUI
import UniformTypeIdentifiers
import ApertisCore

struct PhotoEditorView: View {
    @StateObject private var model: PhotoEditorModel
    @EnvironmentObject private var subscription: Subscription
    @State private var tool: Tool = .styles
    @State private var showingOriginal = false
    @State private var showExport = false
    @State private var showHistogram = true
    @State private var importingRecipe = false
    @State private var exportingRecipe = false

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
        /// Outils réservés à Apertis Pro.
        var proFeature: ProFeature? {
            switch self {
            case .curves: return .curves
            case .hsl: return .hsl
            case .grading: return .grading
            default: return nil
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
            .frame(height: 300)
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
                moreMenu
                Button { showExport = true } label: { Image(systemName: "square.and.arrow.up") }
                    .disabled(model.preview == nil).accessibilityLabel("Exporter")
            }
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(model: model).presentationDetents([.medium])
        }
        .fileImporter(isPresented: $importingRecipe, allowedContentTypes: [.json, .plainText]) { result in
            guard case .success(let url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if !model.applyRecipe(text) { model.exportMessage = "Ce fichier n'est pas une recette Apertis." }
        }
        .fileExporter(isPresented: $exportingRecipe, document: RecipeDocument(text: model.recipe), contentType: .json,
                      defaultFilename: recipeFileName) { result in
            if case .failure(let error) = result { model.exportMessage = "Recette non enregistrée : \(error.localizedDescription)" }
        }
        .alert("Apertis", isPresented: Binding(get: { model.exportMessage != nil }, set: { if !$0 { model.exportMessage = nil } })) {
            Button("OK") { model.exportMessage = nil }
        } message: { Text(model.exportMessage ?? "") }
    }

    private var recipeFileName: String {
        ((model.project.source.originalFileName as NSString).deletingPathExtension) + "-recette.json"
    }

    /// Menu « Plus » : comparaison, alerte d'écrêtage, histogramme, recettes, historique.
    private var moreMenu: some View {
        Menu {
            Toggle(isOn: $model.showClipping) { Label("Alerte d'écrêtage", systemImage: "exclamationmark.triangle") }
            Toggle(isOn: $showHistogram) { Label("Histogramme", systemImage: "chart.bar.xaxis") }
            Section("Recette") {
                Button { UIPasteboard.general.string = model.recipe } label: { Label("Copier la recette", systemImage: "doc.on.doc") }
                Button {
                    if !model.applyRecipe(UIPasteboard.general.string ?? "") {
                        model.exportMessage = "Le presse-papiers ne contient pas de recette Apertis."
                    }
                } label: { Label("Coller une recette", systemImage: "doc.on.clipboard") }
                Button { exportingRecipe = true } label: { Label("Enregistrer la recette…", systemImage: "square.and.arrow.down") }
                Button { importingRecipe = true } label: { Label("Ouvrir une recette…", systemImage: "folder") }
            }
            Section("Historique") {
                ForEach(Array(model.project.history.entries.enumerated().reversed()), id: \.offset) { index, entry in
                    Text((index == model.project.history.index ? "• " : "") + entry.label)
                }
            }
            Button("Réinitialiser", role: .destructive) { model.reset() }
        } label: { Image(systemName: "ellipsis.circle") }
        .accessibilityLabel("Plus")
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
            VStack {
                HStack(alignment: .top) {
                    if showingOriginal {
                        Text("Avant").font(.caption.bold()).padding(6).background(.ultraThinMaterial, in: Capsule())
                    }
                    Spacer()
                    if showHistogram, let histogram = model.histogram {
                        HistogramView(histogram: histogram)
                            .frame(width: 128, height: 64)
                            .onTapGesture { model.showClipping.toggle() }
                            .accessibilityLabel("Histogramme, touchez pour l'alerte d'écrêtage")
                    }
                }
                Spacer()
                HStack {
                    if model.showClipping {
                        ClippingLegend { model.showClipping = false }
                    }
                    Spacer()
                    // Avant / après : maintenir pour voir l'original.
                    Image(systemName: "square.split.2x1")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(9)
                        .background(.ultraThinMaterial, in: Circle())
                        .onLongPressGesture(minimumDuration: 0, maximumDistance: 60, perform: {},
                                            onPressingChanged: { showingOriginal = $0 })
                        .accessibilityLabel("Maintenir pour voir l'original")
                }
            }
            .padding(10)
            if model.isExporting { ProgressView("Export…").padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)) }
        }
        // Appui prolongé sur l'image : comparaison avec l'original.
        .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 50, perform: {}, onPressingChanged: { showingOriginal = $0 })
    }

    private var toolPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(Tool.allCases) { item in
                    Button { tool = item } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.icon).font(.system(size: 18))
                            HStack(spacing: 2) {
                                Text(item.label)
                                if item.proFeature != nil && !subscription.isPro {
                                    Image(systemName: "lock.fill").font(.system(size: 7))
                                }
                            }
                            .font(.caption2)
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

/// Histogramme RVB superposé, comme celui du laboratoire du site.
struct HistogramView: View {
    let histogram: Histogram

    var body: some View {
        Canvas { context, size in
            let colors: [Color] = [.red, .green, .blue]
            for (channel, values) in histogram.channels.enumerated() {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for (i, v) in values.enumerated() {
                    path.addLine(to: CGPoint(x: size.width * CGFloat(i) / 255, y: size.height * (1 - CGFloat(v))))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(colors[channel].opacity(0.55)))
            }
        }
        .background(.black.opacity(0.45))
        .overlay(alignment: .topTrailing) {
            Circle().fill(histogram.clippedHighlights ? Color.red : .white.opacity(0.25)).frame(width: 6, height: 6).padding(4)
        }
        .overlay(alignment: .topLeading) {
            Circle().fill(histogram.clippedShadows ? Color.blue : .white.opacity(0.25)).frame(width: 6, height: 6).padding(4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Légende de l'alerte d'écrêtage, avec un bouton pour la masquer.
struct ClippingLegend: View {
    let hide: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(red: 1, green: 0.15, blue: 0.25)).frame(width: 8, height: 8)
            Text("Blancs brûlés")
            Circle().fill(Color(red: 0.15, green: 0.35, blue: 1)).frame(width: 8, height: 8)
            Text("Noirs bouchés")
            Button("Masquer", action: hide).bold()
        }
        .font(.caption2)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

/// Recette au format JSON, pour l'enregistrer dans Fichiers.
struct RecipeDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
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
    @EnvironmentObject private var subscription: Subscription
    @ObservedObject private var library = StyleLibrary.shared
    @State private var curveChannel = 0
    @State private var hslRange: HSLRange = .red
    @State private var gradeZone = 0
    @State private var importingLUT = false
    @State private var namingStyle = false
    @State private var styleName = ""
    @State private var renaming: Preset?
    @ObservedObject private var luts = LUTLibrary.shared

    var body: some View {
        Group {
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
        .modifier(OptionalProLock(feature: tool.proFeature))
    }

    private func slider(_ title: String, _ keyPath: WritableKeyPath<DevelopSettings, Double> & Sendable,
                        range: ClosedRange<Double> = -100...100, neutral: Double = 0, format: String = "%+.0f") -> some View {
        AdjustmentSlider(title: title, value: model.binding(keyPath), range: range, neutral: neutral, format: format) { model.commit($0) }
    }

    // MARK: Styles

    private var styles: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(BuiltInPresets.all) { preset in styleTile(preset) }
                }
            }
            HStack {
                Text("Mes styles").font(.footnote.bold())
                Spacer()
                Button {
                    styleName = ""
                    namingStyle = true
                } label: { Label("Enregistrer comme style", systemImage: "plus") }
                    .font(.footnote)
            }
            if library.styles.isEmpty {
                Text("Réglez une photo, puis enregistrez le rendu pour le réutiliser sur vos autres photos et vidéos.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(library.styles) { preset in
                            styleTile(preset)
                                .contextMenu {
                                    Button("Renommer") {
                                        styleName = preset.name
                                        renaming = preset
                                    }
                                    Button("Copier la recette") { UIPasteboard.general.string = Recipe.encode(preset.settings) }
                                    Button("Supprimer", role: .destructive) { library.delete(preset.id) }
                                }
                        }
                    }
                }
            }
        }
        .onAppear { model.refreshStyleThumbnails(BuiltInPresets.all + library.styles) }
        .onChange(of: library.styles.count) { _, _ in model.refreshStyleThumbnails(library.styles) }
        .alert("Enregistrer comme style", isPresented: $namingStyle) {
            TextField("Nom du style", text: $styleName)
            Button("Annuler", role: .cancel) {}
            Button("Enregistrer") { library.save(model.settings, name: styleName) }
        } message: {
            Text("Le style garde le rendu (tonalité, couleur, effets), pas l'exposition ni le cadrage de cette photo.")
        }
        .alert("Renommer le style", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nom du style", text: $styleName)
            Button("Annuler", role: .cancel) { renaming = nil }
            Button("Renommer") {
                if let renaming { library.rename(renaming.id, to: styleName) }
                renaming = nil
            }
        }
    }

    private func styleTile(_ preset: Preset) -> some View {
        let available = subscription.isAvailable(preset)
        return Button {
            if available { model.apply(preset) } else { subscription.requested = .allStyles }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    if let thumb = model.styleThumbnails[preset.id] {
                        Image(decorative: thumb, scale: 1).resizable().scaledToFill()
                    } else {
                        Color(.tertiarySystemFill)
                    }
                    if !available {
                        Image(systemName: "lock.fill").font(.caption).padding(5)
                            .background(.thinMaterial, in: Circle())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(4)
                    }
                }
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(preset.name).font(.caption2).lineLimit(1).frame(width: 76)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Réglages

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
        let zones = ["Ombres profondes", "Tons sombres", "Tons clairs", "Hautes lumières"]
        return VStack(spacing: 10) {
            Picker("Courbe", selection: $curveChannel) {
                Text("Zones").tag(-1)
                ForEach(channels.indices, id: \.self) { Text(channels[$0].0).tag($0) }
            }
            .pickerStyle(.segmented)
            if curveChannel < 0 {
                // Courbe paramétrique, la même que celle du laboratoire du site.
                ForEach(zones.indices, id: \.self) { i in
                    AdjustmentSlider(title: zones[i],
                                     value: Binding(get: { model.settings.parametricCurve[i] },
                                                    set: { model.settings.parametricCurve[i] = $0 })) { _ in model.commit("Courbe \(zones[i])") }
                }
            } else {
                let channel = channels[curveChannel]
                CurveEditor(points: Binding(get: { model.settings.curves[keyPath: channel.1] },
                                            set: { model.settings.curves[keyPath: channel.1] = $0 }),
                            color: channel.2) { model.commit("Courbe \(channel.0)") }
                    .frame(height: 200)
                Text("Touchez pour ajouter un point, glissez-le hors du cadre pour le supprimer.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
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
        let zones: [(String, WritableKeyPath<ColorGrading, GradeWheel>, Double)] = [
            ("Ombres", \.shadows, 210), ("Tons moyens", \.midtones, 0), ("Hautes lumières", \.highlights, 40),
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
            AdjustmentSlider(title: "Teinte", value: binding(\.hue), range: 0...360, neutral: zone.2, format: "%.0f°") { _ in model.commit("Étalonnage \(zone.0)") }
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
            slider("Taille du grain", \.grainSize, range: 1...4, neutral: 1.5, format: "%.1f")
            slider("Vignette", \.vignette)
            lutPicker.proLocked(.lut)
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

    private var lutPicker: some View {
        VStack(spacing: 12) {
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
    }

    private var details: some View {
        VStack(spacing: 12) {
            slider("Netteté", \.sharpness, range: 0...100, format: "%.0f")
            slider("Réduction du bruit", \.noiseReduction, range: 0...100, format: "%.0f")
                .proLocked(.rawDetails)
        }
    }

    private var geometry: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(CropSettings.aspects.indices, id: \.self) { i in
                        Button(CropSettings.aspects[i].label) { model.setAspect(i) }
                            .buttonStyle(.bordered)
                            .tint(model.settings.crop.aspect == i ? .accentColor : .secondary)
                    }
                }
            }
            HStack {
                Button { model.rotateClockwise() } label: { Label("Pivoter", systemImage: "rotate.right") }
                Button { model.toggleFlip() } label: { Label("Miroir", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .tint(model.settings.crop.flip ? .accentColor : .secondary)
                Spacer()
                if model.outputSize != .zero {
                    Text("\(Int(model.outputSize.width)) × \(Int(model.outputSize.height))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.bordered)
            AdjustmentSlider(title: "Redresser", value: Binding(get: { model.settings.crop.angle }, set: { model.settings.crop.angle = $0 }),
                             range: -45...45, format: "%+.1f°") { _ in model.commit("Redresser") }
        }
    }
}

/// Verrouille un panneau entier quand il fait partie d'Apertis Pro.
private struct OptionalProLock: ViewModifier {
    let feature: ProFeature?

    func body(content: Content) -> some View {
        if let feature { content.proLocked(feature) } else { content }
    }
}

struct ExportSheet: View {
    @ObservedObject var model: PhotoEditorModel
    @EnvironmentObject private var subscription: Subscription
    @Environment(\.dismiss) private var dismiss
    @State private var format: PhotoExportFormat = .heif
    @State private var quality = 0.92
    @State private var removeLocation = false
    @State private var saveToPhotos = true

    var body: some View {
        NavigationStack {
            Form {
                Picker("Format", selection: $format) {
                    ForEach(PhotoExportFormat.allCases) { item in
                        Text(item.isPro && !subscription.isPro ? "\(item.label) · Pro" : item.label).tag(item)
                    }
                }
                .onChange(of: format) { _, value in
                    // HEIF 10 bits et TIFF 16 bits font partie d'Apertis Pro.
                    if value.isPro && !subscription.allows(.highBitDepthExport) { format = .heif }
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
