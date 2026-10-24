import SwiftUI

@main
struct ApertisApp: App {
    @StateObject private var store = MediaStore()
    @StateObject private var subscription = Subscription()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(subscription)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var subscription: Subscription
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
        // Un outil Pro touché par un utilisateur gratuit ouvre l'abonnement.
        .sheet(item: $subscription.requested) { feature in PaywallView(feature: feature) }
        .alert("Apertis Pro", isPresented: Binding(get: { subscription.message != nil },
                                                    set: { if !$0 { subscription.message = nil } })) {
            Button("OK") { subscription.message = nil }
        } message: { Text(subscription.message ?? "") }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: MediaStore
    @State private var saveToPhotos = true

    var body: some View {
        NavigationStack {
            Form {
                SubscriptionSection()
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
