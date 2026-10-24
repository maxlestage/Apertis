import SwiftUI

@main
struct ApertisApp: App {
    @StateObject private var store = MediaStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}

struct RootView: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            CameraView()
                .tabItem { Label("Caméra", systemImage: "camera") }
                .tag(0)
            LibraryView()
                .tabItem { Label("Bibliothèque", systemImage: "photo.on.rectangle.angled") }
                .tag(1)
            SettingsView()
                .tabItem { Label("Réglages", systemImage: "gearshape") }
                .tag(2)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: MediaStore
    @State private var saveToPhotos = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Capture") {
                    Toggle("Enregistrer aussi dans Photos", isOn: $saveToPhotos)
                        .onChange(of: saveToPhotos) { _, value in store.saveCapturesToPhotos = value }
                }
                Section("Stockage") {
                    Text("Les originaux, projets, exports et LUT sont dans « Sur mon iPhone › Apertis › Apertis » (app Fichiers). Les originaux ne sont jamais modifiés.")
                        .font(.footnote)
                }
                Section("Confidentialité") {
                    Text("Tous les traitements sont faits sur l'appareil. Aucune image n'est envoyée sur un serveur.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Réglages")
            .onAppear { saveToPhotos = store.saveCapturesToPhotos }
        }
    }
}
