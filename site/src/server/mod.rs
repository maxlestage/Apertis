//! Le serveur : pages, liste d'accès anticipé, sécurité de Paquets devant chaque requête.

pub mod export;
pub mod home;
pub mod lab;
pub mod layout;
pub mod legal;

use paquets::prelude::*;

/// Une inscription à l'accès anticipé. Jamais exposée par une API publique.
#[model(table = "inscriptions")]
pub struct Inscription {
    pub id: i64,
    pub email: String,
}

#[data]
struct NouvelleInscription {
    email: String,
}

/// Une adresse plausible : assez courte, un seul « @ », un domaine avec un point, sans espace.
pub fn email_valide(email: &str) -> bool {
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

async fn accueil(req: Request) -> Result<Page> {
    let count = Inscription::query().count(req.db()).await?;
    let thanks = req.query("merci").is_some();
    let error = req.query("erreur").is_some();
    Ok(home::render(&req, count, thanks, error))
}

async fn inscrire(req: Request) -> Result<Redirect> {
    let form: NouvelleInscription = req.form().await?;
    let email = form.email.trim().to_lowercase();
    if !email_valide(&email) {
        return Ok(Redirect::see_other("/?erreur#liste"));
    }
    let deja = Inscription::query().filter(Inscription::EMAIL.eq(email.clone())).count(req.db()).await?;
    if deja == 0 {
        let mut inscription = Inscription { id: 0, email };
        inscription.insert(req.db()).await?;
    }
    Ok(Redirect::see_other("/?merci#liste"))
}

/// Vrai pendant l'export statique (GitHub Pages) : pas de serveur derrière les formulaires.
pub static STATIC_EXPORT: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

pub fn is_static() -> bool {
    STATIC_EXPORT.load(std::sync::atomic::Ordering::Relaxed)
}

pub fn app() -> App {
    let mut app = App::new();
    app.model::<Inscription>();
    app.get("/", accueil);
    app.post("/inscription", inscrire);
    app.get("/labo", |req: Request| async move { lab::photo_page(&req) });
    app.get("/labo/video", |req: Request| async move { lab::video_page(&req) });
    app.get("/confidentialite", |req: Request| async move { legal::privacy(&req) });
    app.get("/mentions-legales", |req: Request| async move { legal::legal(&req) });
    app.health("/health");
    if is_static() {
        app.fallback(|req: Request| async move { legal::not_found(&req) });
        return app;
    }
    app.pwa(
        Pwa::new("Apertis")
            .short_name("Apertis")
            .description("Caméra pro, laboratoire RAW et studio vidéo. Labo photo et vidéo en ligne.")
            .lang("fr")
            .start_url("/labo")
            .theme_color("#07070a")
            .background_color("#07070a"),
    );
    app.fallback(|req: Request| async move { legal::not_found(&req) });
    app
}

pub fn run() -> std::io::Result<()> {
    app().run()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validation_des_adresses() {
        assert!(email_valide("ada@exemple.fr"));
        for bad in ["ada", "ada@exemple", "a da@exemple.fr", "@exemple.fr", "ada@@exemple.fr", "ada@.fr"] {
            assert!(!email_valide(bad), "{bad}");
        }
    }

    #[tokio::test]
    async fn pages_inscription_et_securite() {
        let client = app().test().await;
        for path in ["/", "/labo", "/labo/video", "/confidentialite", "/mentions-legales"] {
            let res = client.get(path).await;
            assert_eq!(res.status(), 200, "{path}");
            let html = res.text();
            assert!(html.contains(r#"lang="fr""#), "{path}");
            assert!(html.contains("<title>"), "{path}");
        }
        // Les laboratoires chargent le bundle (îlot de démarrage) et contiennent leurs outils.
        let photo = client.get("/labo").await.text();
        assert!(photo.contains(r#"data-lab="photo""#));
        assert!(photo.contains(r#"data-key="exposure""#));
        assert!(photo.contains(r#"data-key="hsl_s7""#));
        assert!(photo.contains(r#"data-key="grade_h2""#));
        assert!(photo.contains(r#"data-preset="cinema""#));
        assert!(photo.contains("<active-island"));
        let video = client.get("/labo/video").await.text();
        assert!(video.contains(r#"data-lab="video""#) && video.contains("video-el"));

        let missing = client.get("/nulle-part").await;
        assert_eq!(missing.status(), 404);
        assert!(missing.text().contains("hors champ"));

        assert_eq!(client.get("/health").await.status(), 200);
        assert_eq!(client.get("/manifest.webmanifest").await.status(), 200);

        // Une inscription valide, puis la même adresse : comptée une seule fois.
        for _ in 0..2 {
            let res = client.post("/inscription").form(&[("email", "Ada@Exemple.fr")]).await;
            assert_eq!(res.status(), 303);
        }
        assert!(client.get("/").await.text().contains("1 personne déjà inscrite"));
        let res = client.post("/inscription").form(&[("email", "pas-une-adresse")]).await;
        assert_eq!(res.status(), 303);
        assert!(client.get("/").await.text().contains("1 personne déjà inscrite"));
        // Les inscriptions ne sont exposées par aucune API.
        assert_eq!(client.get("/api/inscriptions").await.status(), 404);
    }
}
