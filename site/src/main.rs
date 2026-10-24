//! Le site d'Apertis : `paquets dev` (http://localhost:3000), ou `PORT` sur Heroku.
//! Lancer depuis `site/` : Paquets y trouve `public/` et le bundle `pkg/`.

#[cfg(not(target_arch = "wasm32"))]
fn main() -> std::io::Result<()> {
    apertis_site::server::run()
}

#[cfg(target_arch = "wasm32")]
fn main() {}
