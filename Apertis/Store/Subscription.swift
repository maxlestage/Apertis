import StoreKit
import SwiftUI
import ApertisCore

/// Ce que débloque Apertis Pro (même liste que la carte « Pro » du site).
enum ProFeature: String, Identifiable {
    case curves, hsl, grading, lut, allStyles, rawDetails, highBitDepthExport, clipGrading, audioTracks
    // Appareil photo
    case manualExposure, viewfinderAssists, captureModes, advancedCapture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .curves: return "Courbes"
        case .hsl: return "TSL"
        case .grading: return "Étalonnage"
        case .lut: return "LUT 3D"
        case .allStyles: return "Tous les styles"
        case .rawDetails: return "Réduction du bruit RAW"
        case .highBitDepthExport: return "Export HEIF 10 bits et TIFF 16 bits"
        case .clipGrading: return "Étalonnage par plan"
        case .audioTracks: return "Piste musique"
        case .manualExposure: return "Modes A, S, M et ouverture"
        case .viewfinderAssists: return "Aides à la visée"
        case .captureModes: return "Bracketing, pose longue et intervallomètre"
        case .advancedCapture: return "Réglages avancés de prise de vue"
        }
    }
}

/// Abonnement Apertis Pro : 7,99 € par mois, 7 jours d'essai gratuit, sans engagement.
///
/// StoreKit 2 : les droits viennent de `Transaction.currentEntitlements`, vérifiés sur
/// l'appareil. Rien n'est bloqué en lecture : un projet créé avec des outils Pro s'ouvre,
/// s'affiche et s'exporte toujours, seuls ces outils ne sont plus modifiables.
@MainActor
final class Subscription: ObservableObject {
    static let monthlyProductID = "fr.apertis.pro.mensuel"

    @Published private(set) var isPro = false
    @Published private(set) var product: Product?
    @Published private(set) var isEligibleForTrial = true
    @Published private(set) var isPurchasing = false
    @Published var message: String?
    /// Fonction Pro demandée par un utilisateur gratuit : ouvre l'écran d'abonnement.
    @Published var requested: ProFeature?

    private var updates: Task<Void, Never>?

    init() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task { await load() }
    }

    func load() async {
        do {
            product = try await Product.products(for: [Self.monthlyProductID]).first
            if let subscription = product?.subscription {
                isEligibleForTrial = await subscription.isEligibleForIntroOffer
            }
        } catch {
            message = "Boutique indisponible : \(error.localizedDescription)"
        }
        await refresh()
    }

    func refresh() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productID == Self.monthlyProductID,
               transaction.revocationDate == nil {
                active = true
            }
        }
        isPro = active
    }

    /// Vrai si la fonction est disponible ; sinon, présente l'abonnement.
    func allows(_ feature: ProFeature) -> Bool {
        if isPro { return true }
        requested = feature
        return false
    }

    func purchase() async {
        guard let product, !isPurchasing else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                await transaction.finish()
                await refresh()
                requested = nil
            case .success(.unverified):
                message = "L'achat n'a pas pu être vérifié."
            case .pending:
                message = "Achat en attente de validation."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = "Achat impossible : \(error.localizedDescription)"
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
            await refresh()
            message = isPro ? "Abonnement Pro restauré." : "Aucun abonnement actif sur ce compte."
        } catch {
            message = "Restauration impossible : \(error.localizedDescription)"
        }
    }

    /// Prix affiché : celui de l'App Store (devise locale), à défaut le tarif de référence.
    var priceLabel: String {
        (product?.displayPrice ?? "7,99 €") + " / mois"
    }

    /// Styles de la formule gratuite : quelques styles d'Apertis et tous les styles personnels.
    func isAvailable(_ preset: Preset) -> Bool {
        isPro || !preset.isBuiltIn || BuiltInPresets.free.contains(preset.id)
    }
}

/// Écran d'abonnement.
struct PaywallView: View {
    @EnvironmentObject private var subscription: Subscription
    @Environment(\.dismiss) private var dismiss
    var feature: ProFeature?

    private let benefits = [
        ("camera.aperture", "Modes A, S, M et ouverture variable de l'iPhone 18 Pro"),
        ("scope", "Focus peaking, zébras, fausses couleurs, loupe"),
        ("square.stack.3d.down.right", "Bracketing, pose longue, intervallomètre"),
        ("slider.horizontal.3", "Charte grise, traitement minimal, cadres cinéma, C1–C3"),
        ("point.topleft.down.to.point.bottomright.curvepath", "Courbes, TSL, étalonnage, LUT 3D"),
        ("camera.filters", "Réduction du bruit RAW et ProRAW"),
        ("film.stack", "Étalonnage plan par plan et piste musique"),
        ("square.and.arrow.up", "Export HEIF 10 bits et TIFF 16 bits"),
        ("square.stack.3d.up", "Tous les styles et ceux à venir"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let feature {
                        Label("\(feature.title) fait partie d'Apertis Pro.", systemImage: "lock.fill")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("Apertis Pro").font(.largeTitle.bold())
                    Text(subscription.priceLabel).font(.title2.weight(.semibold))
                    Text(subscription.isEligibleForTrial
                         ? "Abonnement mensuel, sans engagement. 7 jours d'essai gratuit."
                         : "Abonnement mensuel, sans engagement.")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(benefits, id: \.1) { icon, text in
                            Label(text, systemImage: icon)
                        }
                    }
                    Button {
                        Task { await subscription.purchase() }
                    } label: {
                        Group {
                            if subscription.isPurchasing { ProgressView() } else {
                                Text(subscription.isEligibleForTrial ? "Essayer 7 jours gratuitement" : "S'abonner")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(subscription.product == nil || subscription.isPurchasing)
                    Button("Restaurer mes achats") { Task { await subscription.restore() } }
                        .frame(maxWidth: .infinity)
                    Text("Le paiement est débité sur votre compte Apple à la fin de l'essai. L'abonnement se renouvelle chaque mois sauf résiliation au moins 24 heures avant la fin de la période, depuis les réglages de votre compte. Vos projets et vos originaux restent accessibles et exportables, abonnement ou non.")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Link("Confidentialité", destination: URL(string: "https://maxlestage.github.io/Apertis/confidentialite/")!)
                        Spacer()
                        Link("Conditions d'utilisation", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    }
                    .font(.footnote)
                }
                .padding()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
            }
            .onChange(of: subscription.isPro) { _, pro in if pro { dismiss() } }
        }
    }
}

/// Section d'abonnement des réglages.
struct SubscriptionSection: View {
    @EnvironmentObject private var subscription: Subscription
    @State private var showPaywall = false

    var body: some View {
        Section("Abonnement") {
            if subscription.isPro {
                Label("Apertis Pro actif", systemImage: "checkmark.seal.fill")
                Button("Gérer l'abonnement") {
                    Task {
                        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                            try? await AppStore.showManageSubscriptions(in: scene)
                        }
                    }
                }
            } else {
                Button("Découvrir Apertis Pro — \(subscription.priceLabel)") { showPaywall = true }
                Button("Restaurer mes achats") { Task { await subscription.restore() } }
            }
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }
}

/// Badge « Pro » cliquable posé sur un outil verrouillé.
struct ProLock: ViewModifier {
    @EnvironmentObject private var subscription: Subscription
    let feature: ProFeature

    func body(content: Content) -> some View {
        if subscription.isPro {
            content
        } else {
            content
                .disabled(true)
                .opacity(0.45)
                .overlay {
                    Button { subscription.requested = feature } label: {
                        Label("Pro", systemImage: "lock.fill")
                            .font(.caption.bold())
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
        }
    }
}

extension View {
    func proLocked(_ feature: ProFeature) -> some View { modifier(ProLock(feature: feature)) }
}
