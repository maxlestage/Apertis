//! Le site d'Apertis : présentation de l'application, démonstration interactive
//! de la retouche et liste d'attente, avec la sécurité de Paquets devant chaque requête.
//!
//!     paquets dev      # http://localhost:3000

use apertis_site::labo;
use paquets::prelude::*;

/// Une inscription à la liste d'attente. Jamais exposée par une API publique.
#[model(table = "inscriptions")]
struct Inscription {
    id: i64,
    email: String,
}

/// Les données du formulaire d'inscription.
#[data]
struct NouvelleInscription {
    email: String,
}

const DESCRIPTION: &str = "Apertis : la caméra professionnelle, le laboratoire RAW et le studio vidéo \
     réunis dans votre iPhone. Photo RAW et ProRAW, retouche non destructive, montage et étalonnage.";

/// Une adresse plausible : assez courte, un « @ », un domaine avec un point, sans espace.
fn email_valide(email: &str) -> bool {
    let Some((nom, domaine)) = email.split_once('@') else {
        return false;
    };
    email.len() <= 254
        && !nom.is_empty()
        && domaine.contains('.')
        && !domaine.starts_with('.')
        && !domaine.ends_with('.')
        && !email.contains(char::is_whitespace)
        && !domaine.contains('@')
}

fn card(icone: &str, titre: &str, points: &[&str]) -> Element {
    div()
        .class("card feature")
        .child(span().class("icon").text(icone.to_owned()))
        .child(h3().text(titre.to_owned()))
        .child(ul().children(points.iter().map(|p| li().text((*p).to_owned()))))
}

fn section_titre(id: &str, surtitre: &str, titre: &str, texte: &str) -> Element {
    div()
        .class("section-head")
        .attr("id", id.to_owned())
        .child(p().class("eyebrow").text(surtitre.to_owned()))
        .child(h2().text(titre.to_owned()))
        .child(p().class("muted").text(texte.to_owned()))
}

/// La page d'accueil, rendue par le serveur avec ses balises SEO.
async fn accueil(req: Request) -> Result<Page> {
    let inscrits = Inscription::query().count(req.db()).await?;
    let merci = req.query("merci").is_some();
    let erreur = req.query("erreur").is_some();
    Ok(page(inscrits, merci, erreur))
}

fn page(inscrits: u64, merci: bool, erreur: bool) -> Page {
    let liste = div()
        .class("card waitlist")
        .attr("id", "inscription")
        .child(h2().text("Rejoindre la liste d'attente"))
        .child(p().class("muted").text(
            "Soyez parmi les premiers à essayer Apertis sur TestFlight. \
             Un seul e-mail, au lancement de la bêta. Pas de publicité.",
        ))
        .child(if merci {
            p().class("notice ok").text("Merci ! Vous êtes sur la liste.")
        } else if erreur {
            p().class("notice err").text("Cette adresse ne semble pas valide.")
        } else {
            p().class("hidden")
        })
        .child(
            form()
                .attr("method", "post")
                .attr("action", "/inscription")
                .class("row")
                .child(
                    input()
                        .attr("type", "email")
                        .attr("name", "email")
                        .attr("autocomplete", "email")
                        .attr("placeholder", "vous@exemple.fr")
                        .attr("aria-label", "Adresse e-mail")
                        .attr("required", ""),
                )
                .child(button().text("Je m'inscris")),
        )
        .child(small().class("muted").text(match inscrits {
            0 => "Soyez la première personne inscrite.".to_owned(),
            1 => "1 personne inscrite.".to_owned(),
            n => format!("{n} personnes inscrites."),
        }));

    Page::new("Apertis — caméra pro, labo RAW et studio vidéo pour iPhone")
        .lang("fr")
        .description(DESCRIPTION)
        .head(r#"<link rel="icon" href="/favicon.svg" type="image/svg+xml"/>"#)
        .stylesheet("/site.css")
        .body(
            header()
                .child(
                    a().href("/")
                        .class("brand")
                        .child(img().attr("src", "/favicon.svg").attr("alt", "").attr("width", "28").attr("height", "28"))
                        .child(strong().text("Apertis")),
                )
                .child(
                    nav()
                        .child(a().href("#camera").text("Caméra"))
                        .child(a().href("#retouche").text("Retouche"))
                        .child(a().href("#video").text("Vidéo"))
                        .child(a().href("#labo").text("Labo"))
                        .child(a().href("#inscription").class("button").text("Liste d'attente")),
                ),
        )
        .body(
            // `html::main()` : dans ce fichier, `main` est la fonction du programme.
            html::main()
                .child(
                    section()
                        .class("hero")
                        .child(p().class("eyebrow").text("Pour iPhone et iPad · bientôt sur TestFlight"))
                        .child(h1().text("La caméra pro, le labo RAW et le studio vidéo dans votre poche."))
                        .child(p().text(
                            "Apertis réunit une caméra entièrement manuelle, un développement RAW \
                             non destructif et un montage vidéo avec étalonnage. Tout est traité \
                             sur l'appareil, et vos originaux ne sont jamais modifiés.",
                        ))
                        .child(
                            div()
                                .class("row center-row")
                                .child(a().href("#inscription").class("button").text("Rejoindre la liste d'attente"))
                                .child(a().href("#labo").class("button ghost").text("Essayer le labo")),
                        ),
                )
                .child(section_titre(
                    "camera",
                    "Capture",
                    "Une vraie caméra, pas un filtre",
                    "Les réglages proposés sont ceux que votre iPhone sait réellement faire : \
                     Apertis lit les capacités de chaque objectif au lancement.",
                ))
                .child(
                    div()
                        .class("grid")
                        .child(card("📷", "Photo", &[
                            "HEIF, RAW (DNG) et Apple ProRAW selon l'appareil",
                            "ISO, vitesse, exposition et balance des blancs manuelles",
                            "Mise au point manuelle et au toucher",
                            "Ultra grand-angle, grand-angle et téléobjectif",
                        ]))
                        .child(card("🎥", "Vidéo", &[
                            "Jusqu'en 4K, de 24 à 240 images par seconde",
                            "HDR (HLG) et Apple Log quand l'objectif le permet",
                            "HEVC, H.264 et ProRes",
                            "Verrouillage exposition et balance, vumètre audio",
                        ]))
                        .child(card("🧭", "Assistance", &[
                            "Grille des tiers",
                            "Combinaisons impossibles jamais proposées",
                            "Mode le plus proche choisi automatiquement",
                            "Histogramme et zébras : prochainement",
                        ])),
                )
                .child(section_titre(
                    "retouche",
                    "Laboratoire photo",
                    "Développez vos RAW comme sur ordinateur",
                    "Chaque réglage est enregistré comme une instruction, jamais appliqué aux pixels \
                     de l'original. Annulez, revenez en arrière, exportez autant de versions que vous voulez.",
                ))
                .child(
                    div()
                        .class("grid")
                        .child(card("☀️", "Lumière et couleur", &[
                            "Exposition, contraste, hautes lumières, ombres, blancs, noirs",
                            "Température, teinte, vibrance, saturation",
                            "Courbes RVB et par canal",
                            "TSL sur huit plages de teintes",
                        ]))
                        .child(card("🎨", "Étalonnage et styles", &[
                            "Roues ombres, tons moyens, hautes lumières",
                            "LUT 3D .cube",
                            "Fondu, grain, vignette",
                            "Styles intégrés : argentique, cinéma, noir et blanc…",
                        ]))
                        .child(card("💾", "Export sans compromis", &[
                            "JPEG, HEIF, HEIF 10 bits, TIFF 16 bits",
                            "Pleine résolution, depuis l'original",
                            "Métadonnées conservées, localisation retirée sur demande",
                            "Historique complet, avant/après d'un appui long",
                        ])),
                )
                .child(section_titre(
                    "labo",
                    "Démonstration",
                    "Essayez le labo",
                    "Jouez avec les curseurs et les styles, puis faites glisser la comparaison. \
                     Cette démo tourne dans votre navigateur, en Rust compilé en WebAssembly.",
                ))
                .child(island("labo", "", labo))
                .child(section_titre(
                    "video",
                    "Studio vidéo",
                    "Montez et étalonnez vos plans",
                    "Une timeline aux temps exacts : chaque coupe tombe sur une image, jamais entre deux.",
                ))
                .child(
                    div()
                        .class("grid")
                        .child(card("✂️", "Montage", &[
                            "Coupe à la tête de lecture, entrée et sortie",
                            "Réorganisation des plans",
                            "Ralenti et accéléré",
                            "Piste musique et volume par plan",
                        ]))
                        .child(card("🎞️", "Étalonnage par plan", &[
                            "Les mêmes outils que pour la photo",
                            "Aperçu en direct pendant la lecture",
                            "Copie de l'étalonnage vers tous les plans",
                            "LUT de conversion pour les images Log",
                        ]))
                        .child(card("🚀", "Export", &[
                            "HEVC jusqu'en 4K",
                            "H.264 pour la compatibilité",
                            "Enregistrement dans Photos",
                            "Rendu identique à l'aperçu",
                        ])),
                )
                .child(section_titre(
                    "principes",
                    "Nos engagements",
                    "Vos images vous appartiennent",
                    "",
                ))
                .child(
                    div()
                        .class("grid")
                        .child(card("🔒", "Local d'abord", &[
                            "Aucun cloud, aucun compte obligatoire",
                            "Aucune image envoyée sur un serveur",
                            "Fonctionne en mode avion",
                        ]))
                        .child(card("🛡️", "Originaux protégés", &[
                            "Jamais écrasés ni modifiés",
                            "Projets enregistrés sans risque de corruption",
                            "Tout est visible dans l'app Fichiers",
                        ]))
                        .child(card("🤝", "Honnêteté matérielle", &[
                            "Une fonction indisponible n'est jamais affichée comme disponible",
                            "Les limites de votre iPhone sont expliquées",
                            "Vos projets restent accessibles, abonnement ou non",
                        ])),
                )
                .child(liste),
        )
        .body(
            footer()
                .child(span().text("© Apertis"))
                .child(a().href("https://github.com/maxlestage/Apertis").text("Code source"))
                .child(span().text("Site fait avec Paquets 📦")),
        )
}

/// Enregistre une inscription, puis revient à la page d'accueil.
async fn inscrire(req: Request) -> Result<Redirect> {
    let form: NouvelleInscription = req.form().await?;
    let email = form.email.trim().to_lowercase();
    if !email_valide(&email) {
        return Ok(Redirect::see_other("/?erreur#inscription"));
    }
    let deja = Inscription::query()
        .filter(Inscription::EMAIL.eq(email.clone()))
        .count(req.db())
        .await?;
    if deja == 0 {
        let mut inscription = Inscription { id: 0, email };
        inscription.insert(req.db()).await?;
    }
    Ok(Redirect::see_other("/?merci#inscription"))
}

fn app() -> App {
    let mut app = App::new();
    app.model::<Inscription>(); // la table, créée au démarrage, sans API publique
    app.get("/", accueil);
    app.post("/inscription", inscrire);
    app.health("/health"); // pour Heroku et les moniteurs de disponibilité
    app.pwa(Pwa::new("Apertis").theme_color("#0b0b10")); // installable sur l'écran d'accueil
    app
}

fn main() -> std::io::Result<()> {
    app().run() // $PORT sur Heroku, 3000 sinon
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validation_des_adresses() {
        assert!(email_valide("ada@exemple.fr"));
        assert!(!email_valide("ada"));
        assert!(!email_valide("ada@exemple"));
        assert!(!email_valide("a da@exemple.fr"));
        assert!(!email_valide("@exemple.fr"));
        assert!(!email_valide("ada@@exemple.fr"));
    }

    #[tokio::test]
    async fn accueil_inscription_et_securite() {
        let client = app().test().await;
        let home = client.get("/").await;
        assert_eq!(home.status(), 200);
        let html = home.text();
        assert!(html.contains("Apertis"));
        assert!(html.contains(r#"lang="fr""#));
        assert_eq!(client.get("/health").await.status(), 200);
        assert_eq!(client.get("/manifest.webmanifest").await.status(), 200);

        // Une inscription valide, puis la même adresse : comptée une seule fois.
        for _ in 0..2 {
            let res = client.post("/inscription").form(&[("email", "Ada@Exemple.fr")]).await;
            assert_eq!(res.status(), 303);
        }
        assert!(client.get("/").await.text().contains("1 personne inscrite."));

        // Une adresse invalide est refusée sans être enregistrée.
        let res = client.post("/inscription").form(&[("email", "pas-une-adresse")]).await;
        assert_eq!(res.status(), 303);
        assert!(client.get("/").await.text().contains("1 personne inscrite."));

        // Les inscriptions ne sont exposées par aucune API.
        assert_eq!(client.get("/api/inscriptions").await.status(), 404);
    }
}
