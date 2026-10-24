//! Gabarit commun : en-tête, menu, pied de page, balises SEO.

use paquets::prelude::*;

/// Icônes au trait (24 × 24), dessinées pour le site.
pub fn icon(name: &str) -> Element {
    let paths = match name {
        "camera" => r#"<path d="M4 8h3l2-3h6l2 3h3v11H4z"/><circle cx="12" cy="13" r="3.5"/>"#,
        "sliders" => r#"<path d="M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M20 18h0"/><circle cx="16" cy="6" r="2"/><circle cx="10" cy="12" r="2"/><circle cx="18" cy="18" r="2"/>"#,
        "film" => r#"<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M7 5v14M17 5v14M3 9h4M3 15h4M17 9h4M17 15h4"/>"#,
        "lock" => r#"<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>"#,
        "layers" => r#"<path d="M12 3 3 8l9 5 9-5z"/><path d="m3 13 9 5 9-5"/>"#,
        "aperture" => r#"<circle cx="12" cy="12" r="9"/><path d="m14.3 3.3-5.8 10M20.4 9.4H8.9M17.4 18.4l-5.8-10M9.7 20.7l5.8-10M3.6 14.6h11.5M6.6 5.6l5.8 10"/>"#,
        "wand" => r#"<path d="m4 20 11-11M15 4v2M19 8h2M18 5l1-1M13 7l4 4"/>"#,
        "download" => r#"<path d="M12 4v11M7 10l5 5 5-5M5 20h14"/>"#,
        "upload" => r#"<path d="M12 16V5M7 10l5-5 5 5M5 20h14"/>"#,
        "undo" => r#"<path d="M9 14 4 9l5-5"/><path d="M4 9h10a6 6 0 0 1 0 12h-3"/>"#,
        "redo" => r#"<path d="m15 14 5-5-5-5"/><path d="M20 9H10a6 6 0 0 0 0 12h3"/>"#,
        "reset" => r#"<path d="M3 12a9 9 0 1 0 3-6.7L3 8"/><path d="M3 3v5h5"/>"#,
        "compare" => r#"<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M12 4v16"/>"#,
        "warning" => r#"<path d="M12 4 2 20h20z"/><path d="M12 10v4M12 17v.5"/>"#,
        "rotate" => r#"<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 4v7h-7"/>"#,
        "flip" => r#"<path d="M12 3v18M8 7 3 12l5 5V7zM16 7l5 5-5 5z"/>"#,
        "play" => r#"<path d="M7 4v16l13-8z"/>"#,
        "scissors" => r#"<circle cx="6" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><path d="M20 4 8.1 15.9M14.5 14.5 20 20M8.1 8.1 12 12"/>"#,
        "file" => r#"<path d="M14 3H6v18h12V7z"/><path d="M14 3v4h4"/>"#,
        "check" => r#"<path d="m5 12 5 5L20 7"/>"#,
        "arrow" => r#"<path d="M5 12h14M13 6l6 6-6 6"/>"#,
        "menu" => r#"<path d="M4 7h16M4 12h16M4 17h16"/>"#,
        "phone" => r#"<rect x="6" y="2" width="12" height="20" rx="3"/><path d="M11 18h2"/>"#,
        "sparkle" => r#"<path d="M12 3v4M12 17v4M3 12h4M17 12h4M6 6l2.5 2.5M15.5 15.5 18 18M18 6l-2.5 2.5M8.5 15.5 6 18"/>"#,
        "more" => r#"<circle cx="5" cy="12" r="1.6"/><circle cx="12" cy="12" r="1.6"/><circle cx="19" cy="12" r="1.6"/>"#,
        "volume" => r#"<path d="M4 9v6h4l5 4V5L8 9z"/><path d="M17 9a4 4 0 0 1 0 6"/>"#,
        _ => "",
    };
    span().class("icon").attr("aria-hidden", "true").html(format!(
        r#"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">{paths}</svg>"#
    ))
}

/// Ce qu'une page apporte au gabarit.
pub struct Meta<'a> {
    pub title: &'a str,
    pub description: &'a str,
    pub path: &'a str,
    /// Page « application » (laboratoires) : pleine hauteur, pied de page réduit.
    pub app: bool,
}

/// L'adresse publique du site : `SITE_URL`, sinon l'hôte de la requête.
pub fn origin(req: &Request) -> String {
    if let Ok(url) = std::env::var("SITE_URL") {
        return url.trim_end_matches('/').to_owned();
    }
    let host = req.header("x-forwarded-host").or_else(|| req.host()).unwrap_or("localhost:3000");
    let proto = req.header("x-forwarded-proto").unwrap_or(if host.starts_with("localhost") { "http" } else { "https" });
    format!("{proto}://{host}")
}

fn nav_link(href: &str, label: &str, current: &str) -> Element {
    let link = a().href(href.to_owned()).text(label.to_owned());
    if current == href { link.attr("aria-current", "page") } else { link }
}

pub fn header_bar(current: &str) -> Element {
    header()
        .class("site-header")
        .child(
            a().href("/")
                .class("brand")
                .attr("aria-label", "Apertis, accueil")
                .child(img().attr("src", "/favicon.svg").attr("alt", "").attr("width", "28").attr("height", "28"))
                .child(span().text("Apertis")),
        )
        .child(
            nav()
                .class("site-nav")
                .attr("aria-label", "Navigation principale")
                .child(nav_link("/#fonctionnalites", "Fonctionnalités", current))
                .child(nav_link("/labo", "Labo photo", current))
                .child(nav_link("/labo/video", "Labo vidéo", current))
                .child(nav_link("/#tarifs", "Tarifs", current)),
        )
        .child(
            div()
                .class("header-actions")
                .child(a().href("/#liste").class("btn btn-small").text("Accès anticipé"))
                .child(
                    details()
                        .class("menu")
                        .child(summary().attr("aria-label", "Menu").child(icon("menu")))
                        .child(
                            nav()
                                .class("menu-panel")
                                .child(a().href("/#fonctionnalites").text("Fonctionnalités"))
                                .child(a().href("/labo").text("Labo photo"))
                                .child(a().href("/labo/video").text("Labo vidéo"))
                                .child(a().href("/#tarifs").text("Tarifs"))
                                .child(a().href("/#faq").text("Questions"))
                                .child(a().href("/#liste").class("btn").text("Accès anticipé")),
                        ),
                ),
        )
}

pub fn footer_bar(app: bool) -> Element {
    if app {
        return footer()
            .class("site-footer compact")
            .child(span().text("Traitement 100 % local : vos fichiers ne quittent jamais votre appareil."))
            .child(
                nav()
                    .child(a().href("/confidentialite").text("Confidentialité"))
                    .child(a().href("/mentions-legales").text("Mentions légales")),
            );
    }
    footer()
        .class("site-footer")
        .child(
            div()
                .class("footer-grid")
                .child(
                    div()
                        .class("footer-brand")
                        .child(
                            a().href("/")
                                .class("brand")
                                .child(img().attr("src", "/favicon.svg").attr("alt", "").attr("width", "28").attr("height", "28"))
                                .child(span().text("Apertis")),
                        )
                        .child(p().text("La caméra pro, le laboratoire RAW et le studio vidéo de l'iPhone.")),
                )
                .child(
                    div()
                        .child(h4().text("Produit"))
                        .child(a().href("/#fonctionnalites").text("Fonctionnalités"))
                        .child(a().href("/#tarifs").text("Tarifs"))
                        .child(a().href("/#faq").text("Questions fréquentes")),
                )
                .child(
                    div()
                        .child(h4().text("Essayer"))
                        .child(a().href("/labo").text("Labo photo en ligne"))
                        .child(a().href("/labo/video").text("Labo vidéo en ligne"))
                        .child(a().href("/#liste").text("Accès anticipé")),
                )
                .child(
                    div()
                        .child(h4().text("Apertis"))
                        .child(a().href("/confidentialite").text("Confidentialité"))
                        .child(a().href("/mentions-legales").text("Mentions légales"))
                        .child(a().href("https://github.com/maxlestage/Apertis").attr("rel", "noopener").text("Code source")),
                ),
        )
        .child(
            div()
                .class("footer-bottom")
                .child(span().text("© 2026 Apertis. Photos de démonstration : Unsplash."))
                .child(span().text("Site écrit en Rust avec Paquets.")),
        )
}

/// Une page complète du site.
pub fn page(req: &Request, meta: Meta<'_>, content: Element) -> Page {
    let origin = origin(req);
    let seo = Seo::new()
        .site_name("Apertis")
        .locale("fr_FR")
        .canonical(format!("{origin}{}", meta.path))
        .image(format!("{origin}/media/og.jpg"))
        .base_url(origin.clone());
    Page::new(meta.title)
        .plain()
        .lang("fr")
        .description(meta.description)
        .seo(seo)
        .head(r##"<link rel="icon" href="/favicon.svg" type="image/svg+xml"/><meta name="theme-color" content="#07070a"/><meta name="color-scheme" content="dark"/>"##)
        .stylesheet(format!("/site.css?v={}", css_version()))
        .body(a().href("#contenu").class("skip").text("Aller au contenu"))
        .body(header_bar(meta.path))
        .body(content.attr("id", "contenu").class(if meta.app { "app-main" } else { "page-main" }))
        .body(footer_bar(meta.app))
}

/// Version courte de la feuille de style, pour invalider le cache à chaque déploiement.
fn css_version() -> &'static str {
    static VERSION: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    VERSION.get_or_init(|| {
        let css = std::fs::read("public/site.css").unwrap_or_default();
        let hash = css.iter().fold(0xcbf2_9ce4_8422_2325_u64, |h, b| (h ^ u64::from(*b)).wrapping_mul(0x0100_0000_01b3));
        format!("{hash:016x}")[..10].to_owned()
    })
}
