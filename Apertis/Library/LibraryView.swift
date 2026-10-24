import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import ApertisCore

/// Fichier reçu de PhotosPicker ou de l'app Fichiers, copié dans le dossier temporaire.
/// `preferredItemEncoding: .current` conserve le fichier d'origine (DNG, HEIF, vidéo HDR…).
struct ImportedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .rawImage) { received in
            ImportedFile(url: try copy(received.file))
        }
        FileRepresentation(importedContentType: .image) { received in
            ImportedFile(url: try copy(received.file))
        }
        FileRepresentation(importedContentType: .movie) { received in
            ImportedFile(url: try copy(received.file))
        }
    }

    private static func copy(_ source: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// Copie un fichier choisi dans l'app Fichiers (accès temporaire sécurisé).
    static func copyToTemporary(_ url: URL) -> URL? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try? copy(url)
    }
}

struct LibraryView: View {
    @EnvironmentObject private var store: MediaStore
    @State private var section = 0
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var importingFiles = false
    @State private var isImporting = false
    @State private var message: String?
    @State private var pendingDeletion: PhotoProject?
    @State private var path = NavigationPath()

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Picker("Bibliothèque", selection: $section) {
                    Text("Photos").tag(0)
                    Text("Montages").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()
                if !store.unreadableProjects.isEmpty {
                    Label("\(store.unreadableProjects.count) projet(s) illisible(s) conservé(s) sur le disque", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if section == 0 { photoGrid } else { videoList }
            }
            .navigationTitle("Apertis")
            .navigationDestination(for: PhotoProject.ID.self) { id in
                if let project = store.photoProjects.first(where: { $0.id == id }) {
                    PhotoEditorView(project: project, store: store)
                }
            }
            .navigationDestination(for: VideoRoute.self) { route in
                if let project = store.videoProjects.first(where: { $0.id == route.id }) {
                    VideoEditorView(project: project, store: store)
                }
            }
            .toolbar { toolbar }
            .overlay { if isImporting { ProgressView("Import…").padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        }
        .onChange(of: pickerItems) { _, items in importFromPicker(items) }
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.rawImage, .image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            importFiles(urls.compactMap(ImportedFile.copyToTemporary))
        }
        .confirmationDialog("Supprimer cette photo ?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                            titleVisibility: .visible, presenting: pendingDeletion) { project in
            Button("Supprimer la retouche seulement", role: .destructive) { store.delete(project, removeOriginal: false) }
            Button("Supprimer la retouche et l'original", role: .destructive) { store.delete(project, removeOriginal: true) }
        } message: { _ in
            Text("Les copies déjà enregistrées dans Photos ne sont pas concernées.")
        }
        .alert("Bibliothèque", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }

    struct VideoRoute: Hashable { let id: UUID }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if section == 0 {
                Menu {
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 50, matching: .images, preferredItemEncoding: .current) {
                        Label("Depuis Photos", systemImage: "photo.on.rectangle")
                    }
                    Button { importingFiles = true } label: { Label("Depuis Fichiers (RAW d'appareil photo)", systemImage: "folder") }
                } label: { Image(systemName: "plus") }
            } else {
                Menu {
                    ForEach([24, 25, 30, 60], id: \.self) { fps in
                        Button("Nouveau montage \(fps) i/s") { createVideoProject(frameRate: Rational(Int64(fps))) }
                    }
                    Button("Nouveau montage 29,97 i/s") { createVideoProject(frameRate: Rational(30000, 1001)) }
                } label: { Image(systemName: "plus") }
            }
        }
    }

    private var photoGrid: some View {
        ScrollView {
            if store.photoProjects.isEmpty {
                ContentUnavailableView("Aucune photo", systemImage: "camera",
                                       description: Text("Prenez une photo ou importez des images, y compris des RAW."))
                    .padding(.top, 60)
            }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(store.photoProjects) { project in
                    NavigationLink(value: project.id) {
                        ProjectThumbnail(project: project)
                    }
                    .contextMenu {
                        Button(role: .destructive) { pendingDeletion = project } label: { Label("Supprimer", systemImage: "trash") }
                    }
                }
            }
        }
    }

    private var videoList: some View {
        List {
            ForEach(store.videoProjects) { project in
                NavigationLink(value: VideoRoute(id: project.id)) {
                    VStack(alignment: .leading) {
                        Text(project.name).font(.headline)
                        Text("\(project.timeline.clips.count) plan(s) · \(Int(project.timeline.duration.seconds)) s · \(project.timeline.frameRate.seconds, specifier: "%.3g") i/s")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                offsets.map { store.videoProjects[$0] }.forEach { store.delete($0) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if store.videoProjects.isEmpty {
                ContentUnavailableView("Aucun montage", systemImage: "film.stack", description: Text("Créez un montage avec le bouton +."))
            }
        }
    }

    private func createVideoProject(frameRate: Rational) {
        do {
            let project = try store.createVideoProject(name: "Montage \(store.videoProjects.count + 1)", frameRate: frameRate)
            path.append(VideoRoute(id: project.id))
        } catch {
            message = error.localizedDescription
        }
    }

    private func importFromPicker(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        pickerItems = []
        isImporting = true
        Task {
            var urls: [URL] = []
            for item in items {
                if let file = try? await item.loadTransferable(type: ImportedFile.self) { urls.append(file.url) }
            }
            importFiles(urls)
        }
    }

    private func importFiles(_ urls: [URL]) {
        var failures = 0
        for url in urls {
            do { try store.importPhoto(from: url) } catch { failures += 1 }
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        isImporting = false
        if failures > 0 { message = "\(failures) fichier(s) n'ont pas pu être importés." }
    }
}

/// Vignette rendue avec les réglages du projet.
struct ProjectThumbnail: View {
    @EnvironmentObject private var store: MediaStore
    let project: PhotoProject
    @State private var image: CGImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if project.source.kind != .photo {
                    Text(project.source.kind == .proRAW ? "ProRAW" : "RAW")
                        .font(.system(size: 9, weight: .bold))
                        .padding(3)
                        .background(Color.black.opacity(0.6))
                        .foregroundStyle(.white)
                }
            }
            .task(id: project.modifiedAt) {
                image = await Self.render(project, store: store)
            }
    }

    private static let queue = DispatchQueue(label: "fr.apertis.thumbnails", qos: .utility)

    static func render(_ project: PhotoProject, store: MediaStore) async -> CGImage? {
        let url = store.url(for: project.source)
        let kind = project.source.kind
        let settings = project.settings
        return await withCheckedContinuation { continuation in
            queue.async {
                guard let source = try? PhotoSource(url: url, kind: kind),
                      let image = source.render(settings: settings, maxDimension: 360, cubeDimension: 17)
                else { return continuation.resume(returning: nil) }
                let cg = GradeRenderer.shared.context.createCGImage(image, from: image.extent, format: .RGBA8,
                                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                continuation.resume(returning: cg)
            }
        }
    }
}
