//! Confidentialité, mentions légales et page introuvable.

use paquets::prelude::*;

use super::layout::{page, Meta};

fn prose(title: &str, intro: &str, sections: &[(&str, &[&str])]) -> Element {
    html::main()
        .child(
            article()
                .class("prose")
                .child(p().class("eyebrow").text("Apertis"))
                .child(h1().text(title.to_owned()))
                .child(p().class("lead").text(intro.to_owned()))
                .children(sections.iter().map(|(heading, paragraphs)| {
                    section()
                        .child(h2().text((*heading).to_owned()))
                        .children(paragraphs.iter().map(|t| p().text((*t).to_owned())))
                })),
        )
}

pub fn privacy(req: &Request) -> Page {
    let content = prose(
        "Confidentialité",
        "Nous collectons le strict minimum : votre adresse e-mail si vous rejoignez l'accès anticipé. Rien d'autre.",
        &[
            (
                "Vos photos et vidéos",
                &[
                    "Les laboratoires photo et vidéo du site fonctionnent entièrement dans votre navigateur (WebAssembly et WebGL2). Les fichiers que vous ouvrez ne sont jamais envoyés sur nos serveurs ni sur ceux d'un tiers : ils sont lus, calculés et exportés sur votre appareil.",
                    "L'application iPhone et iPad suit le même principe : aucun cloud, aucun compte obligatoire, aucun envoi d'image.",
                ],
            ),
            (
                "Liste d'accès anticipé",
                &[
                    "Si vous vous inscrivez, nous enregistrons uniquement votre adresse e-mail, dans le seul but de vous envoyer l'invitation à la bêta et l'annonce du lancement.",
                    "Elle n'est ni vendue, ni louée, ni partagée, et elle est supprimée au plus tard un an après le lancement public de l'application.",
                ],
            ),
            (
                "Cookies et mesure d'audience",
                &[
                    "Le site n'utilise ni cookie publicitaire, ni outil de mesure d'audience, ni traceur tiers. Le navigateur peut garder une copie des pages pour fonctionner hors ligne (application web installable) ; elle reste sur votre appareil.",
                ],
            ),
            (
                "Hébergement et journaux",
                &[
                    "Le site est hébergé par Heroku (Salesforce). Comme tout serveur web, il produit des journaux techniques (adresse IP, page demandée, date) conservés pour la sécurité et le diagnostic, puis supprimés automatiquement.",
                ],
            ),
            (
                "Vos droits",
                &[
                    "Conformément au RGPD, vous pouvez demander l'accès à vos données, leur rectification ou leur suppression, et vous opposer à leur traitement. Écrivez-nous via la page du projet sur GitHub. Vous pouvez aussi saisir la CNIL (cnil.fr).",
                ],
            ),
        ],
    );
    page(
        req,
        Meta {
            title: "Confidentialité — Apertis",
            description: "Ce qu'Apertis collecte (votre e-mail si vous rejoignez l'accès anticipé) et ce qu'il ne collecte jamais (vos photos et vidéos).",
            path: "/confidentialite",
            app: false,
        },
        content,
    )
}

pub fn legal(req: &Request) -> Page {
    let content = prose(
        "Mentions légales",
        "Informations sur l'éditeur et l'hébergeur du site.",
        &[
            ("Éditeur", &["Le site apertis est édité par Maxime Lestage, à titre personnel. Contact : via la page du projet sur GitHub (github.com/maxlestage/Apertis)."]),
            ("Hébergeur", &["Heroku, une société de Salesforce, Inc., 415 Mission Street, San Francisco, CA 94105, États-Unis."]),
            (
                "Propriété intellectuelle",
                &[
                    "Les textes, l'interface et le code du site appartiennent à leur auteur. Les photographies de démonstration proviennent d'Unsplash et sont utilisées selon la licence Unsplash.",
                ],
            ),
        ],
    );
    page(
        req,
        Meta {
            title: "Mentions légales — Apertis",
            description: "Éditeur, hébergeur et crédits du site Apertis.",
            path: "/mentions-legales",
            app: false,
        },
        content,
    )
}

pub fn not_found(req: &Request) -> Page {
    let content = html::main().child(
        section()
            .class("not-found")
            .child(p().class("eyebrow").text("Erreur 404"))
            .child(h1().text("Cette page est hors champ."))
            .child(p().class("lead").text("Elle a peut-être été déplacée, ou l'adresse contient une faute de frappe."))
            .child(
                div()
                    .class("cta-row")
                    .child(a().href("/").class("btn").text("Retour à l'accueil"))
                    .child(a().href("/labo").class("btn btn-ghost").text("Ouvrir le labo photo")),
            ),
    );
    page(
        req,
        Meta { title: "Page introuvable — Apertis", description: "Cette page n'existe pas.", path: req.path(), app: false },
        content,
    )
    .status(404)
}
