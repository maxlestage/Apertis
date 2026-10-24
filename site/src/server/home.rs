//! La page d'accueil.

use paquets::prelude::*;

use super::layout::{icon, page, Meta};
use crate::compare;

fn eyebrow(text: &str) -> Element {
    p().class("eyebrow").text(text.to_owned())
}

fn section_head(eyebrow_text: &str, title: &str, lead: &str) -> Element {
    div()
        .class("section-head")
        .child(eyebrow(eyebrow_text))
        .child(h2().text(title.to_owned()))
        .child(p().class("lead").text(lead.to_owned()))
}

fn bullets(items: &[&str]) -> Element {
    ul().class("checks").children(items.iter().map(|t| li().child(icon("check")).child(span().text((*t).to_owned()))))
}

fn hero() -> Element {
    section()
        .class("hero")
        .child(div().class("hero-bg").child(img().attr("src", "/media/compare-apres.jpg").attr("alt", "").attr("fetchpriority", "high")))
        .child(
            div()
                .class("hero-inner")
                .child(
                    div()
                        .class("hero-copy")
                        .child(p().class("pill").child(span().class("dot")).text("iPhone et iPad · accès anticipé en cours"))
                        .child(h1().child(span().text("Photographiez. Développez. Montez.")).child(span().class("grad").text("Comme un pro.")))
                        .child(p().class("lead").text(
                            "Apertis réunit une caméra entièrement manuelle avec RAW et ProRAW, un laboratoire de \
                             développement non destructif et un studio vidéo avec étalonnage. Tout est calculé sur \
                             votre appareil.",
                        ))
                        .child(
                            div()
                                .class("cta-row")
                                .child(a().href("/labo").class("btn btn-large").child(span().text("Essayer le labo en ligne")).child(icon("arrow")))
                                .child(a().href("#liste").class("btn btn-large btn-ghost").text("Rejoindre l'accès anticipé")),
                        )
                        .child(p().class("fine").text("Gratuit, sans compte, dans votre navigateur. Vos images ne sont envoyées nulle part.")),
                )
                .child(hero_panel()),
        )
}

/// Aperçu du panneau de réglages (statique), pour montrer l'outil.
fn hero_panel() -> Element {
    let row = |label: &str, value: &str, pos: u8| {
        div()
            .class("mock-row")
            .child(div().class("mock-label").child(span().text(label.to_owned())).child(span().class("mono").text(value.to_owned())))
            .child(div().class("mock-track").child(div().class("mock-fill").style(format!("width:{pos}%"))))
    };
    div()
        .class("hero-panel glass")
        .attr("aria-hidden", "true")
        .child(div().class("mock-head").child(span().text("Développement")).child(span().class("badge").text("RAW")))
        .child(div().class("mock-hist"))
        .child(row("Exposition", "+0,35 IL", 58))
        .child(row("Contraste", "+18", 59))
        .child(row("Hautes lumières", "−20", 40))
        .child(row("Ombres", "+12", 56))
        .child(row("Température", "−6", 47))
        .child(
            div()
                .class("mock-chips")
                .child(span().text("Portra"))
                .child(span().class("on").text("Cinéma"))
                .child(span().text("N&B")),
        )
}

fn stats() -> Element {
    let stat = |value: &str, label: &str| div().class("stat").child(strong().text(value.to_owned())).child(span().text(label.to_owned()));
    section()
        .class("stats")
        .child(stat("RAW · ProRAW", "Capture et développement des fichiers bruts"))
        .child(stat("4K · HDR · Log", "Selon les capacités réelles de votre iPhone"))
        .child(stat("LUT 3D 33³", "Étalonnage calculé sur le GPU, aperçu = export"))
        .child(stat("0 octet", "Envoyé sur nos serveurs : tout reste sur l'appareil"))
}

fn before_after() -> Element {
    section()
        .class("section")
        .child(section_head(
            "Développement",
            "Du fichier plat au rendu final.",
            "Un RAW ou une vidéo Log sortent ternes de la caméra : c'est voulu, toute l'information est encore là. \
             Faites glisser pour voir ce que le laboratoire en tire.",
        ))
        .child(
            figure()
                .class("compare-figure")
                .child(island(
                    "compare",
                    "/media/compare-avant.jpg|/media/compare-apres.jpg|Montagnes au-dessus d'une mer de nuages, développées avec le style Cinéma",
                    compare,
                ))
                .child(figcaption().text("Rendu plat, puis style « Cinéma » : contraste, hautes lumières, ombres bleutées, tons chauds, vignette. Réalisé avec le moteur du laboratoire.")),
        )
}

fn features() -> Element {
    let card = |name: &str, title: &str, text: &str, items: &[&str], class: &str| {
        article()
            .class(format!("feature {class}"))
            .child(div().class("feature-icon").child(icon(name)))
            .child(h3().text(title.to_owned()))
            .child(p().text(text.to_owned()))
            .child(bullets(items))
    };
    section()
        .class("section")
        .attr("id", "fonctionnalites")
        .child(section_head(
            "Fonctionnalités",
            "Trois outils de pro. Une seule app.",
            "Pensée pour les photographes, vidéastes et créateurs qui veulent le contrôle total, sans sacrifier la simplicité.",
        ))
        .child(
            div()
                .class("bento")
                .child(card(
                    "camera",
                    "Caméra manuelle",
                    "Chaque réglage du capteur, sous vos doigts. Seuls les modes que votre iPhone sait vraiment faire sont proposés.",
                    &["RAW (DNG) et Apple ProRAW", "ISO, vitesse, balance des blancs en Kelvin", "Mise au point manuelle, verrouillage AE/AWB", "Vidéo 4K, HDR et Apple Log, ProRes"],
                    "wide",
                ))
                .child(card(
                    "sliders",
                    "Laboratoire photo",
                    "Développement non destructif : l'original n'est jamais modifié, chaque version est un jeu d'instructions.",
                    &["Lumière, couleur, courbes, TSL 8 plages", "Étalonnage 3 voies, LUT 3D .cube", "Grain, vignette, netteté, recadrage", "Export JPEG, HEIF 10 bits, TIFF 16 bits"],
                    "",
                ))
                .child(card(
                    "film",
                    "Studio vidéo",
                    "Une timeline aux temps exacts : chaque coupe tombe sur une image, jamais entre deux.",
                    &["Coupe, entrée et sortie, vitesse", "Étalonnage par plan, en direct", "Piste musique et volume", "Export HEVC et H.264 jusqu'en 4K"],
                    "",
                ))
                .child(card(
                    "lock",
                    "Privé par conception",
                    "Pas de cloud, pas de compte obligatoire, aucune image envoyée. Vos originaux restent visibles dans l'app Fichiers.",
                    &["Fonctionne en mode avion", "Projets enregistrés sans risque de corruption", "Localisation retirée à l'export, sur demande"],
                    "wide",
                )),
        )
}

fn styles() -> Element {
    let tile = |file: &str, name: &str, note: &str| {
        figure()
            .class("style-tile")
            .child(img().attr("src", format!("/media/style-{file}.jpg")).attr("alt", format!("Style {name}")).attr("loading", "lazy"))
            .child(figcaption().child(strong().text(name.to_owned())).child(span().text(note.to_owned())))
    };
    section()
        .class("section")
        .child(section_head(
            "Styles",
            "Un point de départ, jamais une prison.",
            "Des rendus inspirés de l'argentique et du cinéma. Chaque style reste entièrement réglable, et vous pouvez enregistrer les vôtres.",
        ))
        .child(
            div()
                .class("styles-row")
                .child(tile("original", "Original", "Le fichier tel quel"))
                .child(tile("portra", "Portra", "Doux, tons chair chauds"))
                .child(tile("kodachrome", "Kodachrome", "Dense et saturé"))
                .child(tile("cinema", "Cinéma", "Ombres bleues, peaux chaudes"))
                .child(tile("nordique", "Nordique", "Froid et désaturé"))
                .child(tile("dore", "Heure dorée", "Lumière de fin de journée"))
                .child(tile("nb", "Noir et blanc", "Contrasté, grain fin")),
        )
}

fn labs() -> Element {
    let card = |href: &str, image: &str, title: &str, text: &str, cta: &str| {
        a().href(href.to_owned())
            .class("lab-card")
            .child(div().class("lab-card-media").child(img().attr("src", image.to_owned()).attr("alt", "").attr("loading", "lazy")))
            .child(
                div()
                    .class("lab-card-body")
                    .child(h3().text(title.to_owned()))
                    .child(p().text(text.to_owned()))
                    .child(span().class("link").child(span().text(cta.to_owned())).child(icon("arrow"))),
            )
    };
    section()
        .class("section")
        .child(section_head(
            "Essayez maintenant",
            "Le laboratoire, directement dans votre navigateur.",
            "Le même moteur de développement que l'app, compilé en WebAssembly et accéléré par WebGL2. Ouvrez vos propres fichiers : ils ne quittent pas votre appareil.",
        ))
        .child(
            div()
                .class("lab-cards")
                .child(card(
                    "/labo",
                    "/media/lac.jpg",
                    "Labo photo",
                    "Lumière, couleur, courbe, TSL, étalonnage, grain, recadrage, histogramme, styles et export en pleine résolution.",
                    "Ouvrir le labo photo",
                ))
                .child(card(
                    "/labo/video",
                    "/media/demo-poster.jpg",
                    "Labo vidéo",
                    "Étalonnez une vidéo en direct pendant la lecture, choisissez l'entrée et la sortie, exportez avec le son.",
                    "Ouvrir le labo vidéo",
                )),
        )
}

fn pipeline() -> Element {
    let step = |n: &str, title: &str, text: &str| {
        div().class("step").child(span().class("step-n").text(n.to_owned())).child(h3().text(title.to_owned())).child(p().text(text.to_owned()))
    };
    section()
        .class("section")
        .child(section_head(
            "Sous le capot",
            "Un pipeline couleur, de la capture à l'export.",
            "Les mêmes calculs pour l'aperçu, l'export photo et chaque image de vos vidéos : ce que vous voyez est ce que vous obtenez.",
        ))
        .child(
            div()
                .class("steps")
                .child(step("01", "Lumière linéaire", "Dématriçage RAW, balance des blancs et exposition appliqués en lumière linéaire, comme sur un capteur."))
                .child(step("02", "Tonalité", "Points noir et blanc, contraste, hautes lumières, ombres et courbe, sans casser les teintes."))
                .child(step("03", "Couleur", "TSL, vibrance, étalonnage et LUT créatives, cuits dans une LUT 3D interpolée par le GPU."))
                .child(step("04", "Finition", "Netteté, vignette, grain et recadrage, puis export en pleine résolution depuis l'original.")),
        )
}

fn pricing() -> Element {
    let plan = |name: &str, price: &str, note: &str, items: &[&str], featured: bool| {
        article()
            .class(if featured { "plan featured" } else { "plan" })
            .child(h3().text(name.to_owned()))
            .child(p().class("price").text(price.to_owned()))
            .child(p().class("muted").text(note.to_owned()))
            .child(bullets(items))
            .child(a().href("#liste").class(if featured { "btn" } else { "btn btn-ghost" }).text("Rejoindre l'accès anticipé"))
    };
    section()
        .class("section")
        .attr("id", "tarifs")
        .child(section_head(
            "Tarifs",
            "Gratuit pour commencer. Pro quand vous en avez besoin.",
            "La version gratuite est vraiment utile. Vos projets et vos originaux restent toujours accessibles, abonnement ou non.",
        ))
        .child(
            div()
                .class("plans")
                .child(plan(
                    "Gratuit",
                    "0 €",
                    "Pour découvrir et créer sans contrainte.",
                    &["Caméra photo et vidéo", "Réglages fondamentaux et styles de base", "Montage simple", "Exports sans filigrane"],
                    false,
                ))
                .child(plan(
                    "Pro",
                    "Prix au lancement",
                    "Abonnement mensuel, sans engagement. 7 jours d'essai gratuit.",
                    &["Développement RAW et ProRAW avancé", "Courbes, TSL, étalonnage, LUT 3D", "Timeline multipiste et étalonnage par plan", "Export HEIF 10 bits, TIFF 16 bits, 4K HDR", "Tous les styles et ceux à venir"],
                    true,
                )),
        )
}

fn faq() -> Element {
    let q = |question: &str, answer: &str| details().class("faq-item").child(summary().text(question.to_owned())).child(p().text(answer.to_owned()));
    section()
        .class("section narrow")
        .attr("id", "faq")
        .child(section_head("Questions", "Questions fréquentes.", ""))
        .child(q("Quand l'application sera-t-elle disponible ?", "La bêta privée ouvre sur TestFlight pour les personnes inscrites à l'accès anticipé, puis l'app arrivera sur l'App Store. Un seul e-mail vous préviendra."))
        .child(q("Quels iPhone sont compatibles ?", "Apertis fonctionne à partir d'iOS 17. Le RAW, le ProRAW, le HDR, l'Apple Log et les cadences élevées dépendent de votre modèle : l'app lit les capacités réelles de chaque objectif et ne propose jamais une fonction indisponible."))
        .child(q("Mes photos sont-elles envoyées quelque part ?", "Non. L'app et le laboratoire en ligne calculent tout sur votre appareil. Il n'y a ni cloud ni compte obligatoire, et aucune image ne transite par nos serveurs."))
        .child(q("Le laboratoire en ligne lit-il les RAW ?", "Le laboratoire en ligne ouvre les images que votre navigateur sait décoder (JPEG, PNG, WebP, HEIC sur Safari). Le développement des RAW et ProRAW est réservé à l'application, qui accède aux données du capteur."))
        .child(q("Que deviennent mes projets si j'arrête l'abonnement ?", "Ils restent à vous : vos originaux, vos projets et vos exports restent accessibles et exportables. Seuls les outils Pro ne sont plus modifiables."))
        .child(q("Y aura-t-il une version Android ?", "Le lancement se fait sur iPhone et iPad, pour exploiter pleinement le matériel Apple (ProRAW, Apple Log, ProRes). Android est envisagé ensuite."))
}

pub fn waitlist(count: u64, thanks: bool, error: bool) -> Element {
    if super::is_static() {
        // Hébergement statique (GitHub Pages) : pas de serveur pour enregistrer l'adresse.
        return section().class("section").attr("id", "liste").child(
            div()
                .class("waitlist glass")
                .child(eyebrow("Accès anticipé"))
                .child(h2().text("Soyez parmi les premiers."))
                .child(p().class("lead").text("Suivez le projet sur GitHub : l'ouverture de la bêta TestFlight y sera annoncée en premier."))
                .child(
                    div()
                        .class("cta-row")
                        .child(a().href("https://github.com/maxlestage/Apertis").attr("rel", "noopener").class("btn btn-large").child(span().text("Suivre Apertis sur GitHub")).child(icon("arrow")))
                        .child(a().href("/labo").class("btn btn-large btn-ghost").text("Essayer le labo")),
                ),
        );
    }
    section()
        .class("section")
        .attr("id", "liste")
        .child(
            div()
                .class("waitlist glass")
                .child(eyebrow("Accès anticipé"))
                .child(h2().text("Soyez parmi les premiers."))
                .child(p().class("lead").text("Inscrivez-vous pour recevoir votre invitation à la bêta TestFlight. Un seul e-mail, au lancement. Pas de publicité, désinscription en un clic."))
                .child(if thanks {
                    p().class("notice ok").attr("role", "status").child(icon("check")).child(span().text("C'est noté, vous êtes sur la liste. À très vite."))
                } else if error {
                    p().class("notice err").attr("role", "alert").child(icon("warning")).child(span().text("Cette adresse ne semble pas valide. Vérifiez-la et réessayez."))
                } else {
                    p().class("notice").attr("hidden", "")
                })
                .child(
                    form()
                        .attr("method", "post")
                        .attr("action", "/inscription")
                        .class("waitlist-form")
                        .child(label().attr("for", "email").class("sr-only").text("Adresse e-mail"))
                        .child(
                            input()
                                .attr("id", "email")
                                .attr("type", "email")
                                .attr("name", "email")
                                .attr("autocomplete", "email")
                                .attr("inputmode", "email")
                                .attr("placeholder", "vous@exemple.fr")
                                .attr("required", ""),
                        )
                        .child(button().attr("type", "submit").class("btn").text("Je m'inscris")),
                )
                .child(small().class("muted").text(match count {
                    0 => "Les inscriptions viennent d'ouvrir.".to_owned(),
                    1 => "1 personne déjà inscrite. Voir notre politique de confidentialité.".to_owned(),
                    n => format!("{n} personnes déjà inscrites. Voir notre politique de confidentialité."),
                })),
        )
}

pub fn render(req: &Request, count: u64, thanks: bool, error: bool) -> Page {
    let content = html::main()
        .child(hero())
        .child(stats())
        .child(before_after())
        .child(features())
        .child(styles())
        .child(labs())
        .child(pipeline())
        .child(pricing())
        .child(faq())
        .child(waitlist(count, thanks, error));
    page(
        req,
        Meta {
            title: "Apertis — caméra pro, labo RAW et studio vidéo pour iPhone",
            description: "Apertis réunit une caméra manuelle avec RAW et ProRAW, un laboratoire de développement non destructif et un studio vidéo avec étalonnage. Essayez le labo photo et vidéo en ligne, gratuitement.",
            path: "/",
            app: false,
        },
        content,
    )
    .seo(Seo::new().json_ld(
        r#"{"@context":"https://schema.org","@type":"SoftwareApplication","name":"Apertis","operatingSystem":"iOS 17","applicationCategory":"PhotographyApplication","description":"Caméra pro, laboratoire RAW et studio vidéo pour iPhone.","offers":{"@type":"Offer","price":"0","priceCurrency":"EUR"}}"#,
    ))
}
