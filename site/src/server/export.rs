//! `apertis-site export <dossier>` : le site en fichiers statiques, pour GitHub Pages.
//!
//! Chaque page vient du serveur lui-même, par le client de test en mémoire de Paquets
//! (`app.test()`) : le site statique est identique au site servi. Les laboratoires
//! fonctionnent entièrement dans le navigateur, ils n'ont pas besoin de serveur. Ce qu'un
//! hébergement statique ne sait pas faire est remplacé : la liste d'accès anticipé
//! renvoie vers le projet GitHub.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;

/// Les pages du site et leur fichier.
const PAGES: [(&str, &str); 5] = [
    ("/", "index.html"),
    ("/labo", "labo/index.html"),
    ("/labo/video", "labo/video/index.html"),
    ("/confidentialite", "confidentialite/index.html"),
    ("/mentions-legales", "mentions-legales/index.html"),
];

/// Écrit le site dans `out`, liens derrière `base` (`""` ou `/Apertis`), URL absolues
/// (canonique, Open Graph) sur `site_url`. Renvoie le nombre de fichiers écrits.
pub async fn export(out: &Path, base: &str, site_url: Option<String>) -> io::Result<usize> {
    let base = normalize_base(base);
    let out = std::path::absolute(out)?;
    // Paquets trouve `public/` et `pkg/` dans le dossier courant.
    let dir = std::path::absolute(site_dir())?;
    std::env::set_current_dir(&dir)?;
    if !dir.join("pkg").is_dir() {
        eprintln!("attention : site/pkg manque, les laboratoires ne seront pas interactifs (lancez ./heroku-build.sh)");
    }
    let site_url = site_url
        .filter(|u| !u.trim().is_empty())
        .unwrap_or_else(|| if base.is_empty() { "http://localhost:3000".into() } else { format!("https://maxlestage.github.io{base}") });
    // Lu par `layout::origin` pour les URL canoniques et Open Graph.
    // SAFETY : appelé avant tout autre fil d'exécution du programme qui lirait l'environnement.
    unsafe { std::env::set_var("SITE_URL", site_url.trim_end_matches('/')) };
    super::STATIC_EXPORT.store(true, Ordering::Relaxed);

    let mut app = super::app();
    // Des fichiers statiques n'ont pas de serveur à protéger, et l'export demande toutes
    // les pages d'un coup (la limitation de débit l'arrêterait).
    app.security(None);
    let client = app.test().await;

    if out.exists() {
        std::fs::remove_dir_all(&out)?;
    }
    let mut written = 0;
    let mut write = |path: &str, bytes: &[u8]| -> io::Result<()> {
        let file = out.join(path.trim_start_matches('/'));
        if let Some(parent) = file.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(file, bytes)?;
        written += 1;
        Ok(())
    };

    // Version du bundle dans ses adresses : un navigateur ne peut pas mélanger le
    // JavaScript d'un déploiement et le WebAssembly d'un autre (GitHub Pages met ces
    // fichiers en cache 10 minutes).
    let version = bundle_version(&dir.join("pkg"));
    let finish = |html: &str| with_version(&with_base(html, &base), &version);
    for (path, file) in PAGES {
        let res = client.get(path).await;
        if res.status() != 200 {
            return Err(io::Error::other(format!("GET {path} : {}", res.status())));
        }
        write(file, finish(&res.text()).as_bytes())?;
    }
    // Page introuvable : GitHub Pages sert 404.html pour toute adresse inconnue.
    let missing = client.get("/introuvable").await;
    if missing.status() != 404 {
        return Err(io::Error::other(format!("page 404 : {}", missing.status())));
    }
    write("404.html", finish(&missing.text()).as_bytes())?;

    for folder in ["public", "pkg"] {
        let root = dir.join(folder);
        let prefix = if folder == "pkg" { "pkg/" } else { "" };
        for file in files(&root) {
            let relative = file.strip_prefix(&root).map_err(io::Error::other)?;
            let url = format!("{prefix}{}", relative.to_string_lossy().replace('\\', "/"));
            // Fichiers propres à wasm-bindgen, inutiles pour exécuter le bundle.
            if url.ends_with(".gitignore") || url.ends_with("package.json") || url.ends_with(".d.ts") {
                continue;
            }
            write(&url, &std::fs::read(&file)?)?;
        }
    }
    // Sans ce fichier, GitHub Pages passerait le site dans Jekyll.
    write(".nojekyll", b"")?;
    Ok(written)
}

/// Empreinte courte des fichiers du bundle (FNV-1a).
fn bundle_version(pkg: &Path) -> String {
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for file in files(pkg) {
        for byte in std::fs::read(&file).unwrap_or_default() {
            hash = (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3);
        }
    }
    format!("{hash:016x}")[..10].to_owned()
}

/// Ajoute `?v=<version>` aux adresses du bundle (`….js"` et `…_bg.wasm"`).
pub fn with_version(html: &str, version: &str) -> String {
    html.replace("/pkg/apertis_site.js\"", &format!("/pkg/apertis_site.js?v={version}\""))
        .replace("/pkg/apertis_site_bg.wasm\"", &format!("/pkg/apertis_site_bg.wasm?v={version}\""))
}

/// `""`, ou `/quelque-chose` sans barre finale.
pub fn normalize_base(base: &str) -> String {
    match base.trim().trim_end_matches('/') {
        "" => String::new(),
        b if b.starts_with('/') => b.to_owned(),
        b => format!("/{b}"),
    }
}

/// Préfixe par `base` chaque adresse de la racine du site (`href="/…"`, `src="/…"`,
/// le chargeur du bundle…), sans toucher aux adresses absolues (`https://`, `//`).
pub fn with_base(html: &str, base: &str) -> String {
    if base.is_empty() {
        return html.to_owned();
    }
    let mut out = String::with_capacity(html.len() + 512);
    let mut rest = html;
    while let Some(i) = rest.find("\"/") {
        out.push_str(&rest[..=i]);
        rest = &rest[i + 1..];
        // `"//hôte` est une adresse absolue ; `"/` seul n'est pas une adresse.
        if !rest.starts_with("//") && rest.len() > 1 {
            let before = out.trim_end_matches('"');
            if is_url_attribute(before) {
                out.push_str(base);
            }
        }
    }
    out.push_str(rest);
    out
}

/// Le texte qui précède `"` est-il un attribut d'adresse ou le chargeur du bundle ?
fn is_url_attribute(before: &str) -> bool {
    ["href=", "src=", "action=", "data-sample=", "data-props=", "content=", "import init from ", "module_or_path:"]
        .iter()
        .any(|a| before.ends_with(a))
}

fn site_dir() -> PathBuf {
    if Path::new("public").is_dir() {
        return PathBuf::from(".");
    }
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn files(dir: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return found;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            found.extend(files(&path));
        } else {
            found.push(path);
        }
    }
    found.sort();
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefixes_site_urls_only() {
        let html = r#"<a href="/labo">x</a><img src="/media/a.jpg"/><a href="https://github.com/x">g</a><a href="//cdn.x/y">c</a><form action="/inscription"></form><button data-sample="/media/lac.jpg"></button><script type="module">import init from "/pkg/a.js";init({module_or_path:"/pkg/a_bg.wasm"});</script><p>"/pas une adresse"</p><meta property="og:image" content="https://h/media/og.jpg"/>"#;
        let out = with_base(html, "/Apertis");
        for expected in [
            r#"href="/Apertis/labo""#,
            r#"src="/Apertis/media/a.jpg""#,
            r#"action="/Apertis/inscription""#,
            r#"data-sample="/Apertis/media/lac.jpg""#,
            r#"import init from "/Apertis/pkg/a.js""#,
            r#"module_or_path:"/Apertis/pkg/a_bg.wasm""#,
            r#"href="https://github.com/x""#,
            r#"href="//cdn.x/y""#,
            r#""/pas une adresse""#,
            r#"content="https://h/media/og.jpg""#,
        ] {
            assert!(out.contains(expected), "{expected} absent de {out}");
        }
        assert_eq!(with_base(html, ""), html);
        let versioned = with_version(r#"<link href="/A/pkg/apertis_site.js"/>import init from "/A/pkg/apertis_site.js";init({module_or_path:"/A/pkg/apertis_site_bg.wasm"})"#, "abc");
        assert_eq!(versioned.matches("?v=abc\"").count(), 3);
        assert_eq!(normalize_base("Apertis/"), "/Apertis");
        assert_eq!(normalize_base(""), "");
    }
}
