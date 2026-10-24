//! Le site d'Apertis : `paquets dev` (http://localhost:3000), ou `PORT` sur Heroku.
//! Lancer depuis `site/` : Paquets y trouve `public/` et le bundle `pkg/`.

//! `apertis-site export <dossier>` : le site en fichiers statiques (GitHub Pages).
//! `BASE_PATH` (ex. `/Apertis`) préfixe les liens, `SITE_URL` donne les URL absolues.

#[cfg(not(target_arch = "wasm32"))]
fn main() -> std::io::Result<()> {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        None => apertis_site::server::run(),
        Some("export") => {
            let dir = args.next().unwrap_or_else(|| "dist".into());
            let base = std::env::var("BASE_PATH").unwrap_or_default();
            let site_url = std::env::var("SITE_URL").ok();
            let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build()?;
            let files = runtime.block_on(apertis_site::server::export::export(std::path::Path::new(&dir), &base, site_url))?;
            println!("📦 {files} fichiers écrits dans {dir}");
            Ok(())
        }
        Some(other) => {
            eprintln!("commande inconnue {other:?} : lancez sans argument, ou `export <dossier>`");
            std::process::exit(2);
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn main() {}
