//! Le site d'Apertis : le moteur du laboratoire (partagé), le serveur (natif) et le
//! code du navigateur (WebAssembly) : laboratoires photo et vidéo, comparateur.

pub mod grade;

#[cfg(not(target_arch = "wasm32"))]
pub mod server;

#[cfg(target_arch = "wasm32")]
mod client;

use paquets::prelude::*;

/// Îlot de démarrage : sa présence fait charger le bundle WebAssembly par la page
/// (les laboratoires ne sont pas des îlots : ils pilotent eux-mêmes leur DOM).
pub fn boot(_props: &str) -> Node {
    span().attr("hidden", "").into()
}

/// Comparateur avant / après : deux images superposées et un curseur.
/// `props` : `avant.jpg|après.jpg|texte alternatif`.
pub fn compare(props: &str) -> Node {
    let mut parts = props.splitn(3, '|');
    let before = parts.next().unwrap_or_default().to_owned();
    let after = parts.next().unwrap_or_default().to_owned();
    let alt = parts.next().unwrap_or_default().to_owned();
    let split = use_state(50);
    div()
        .class("compare")
        .child(img().attr("src", after).attr("alt", alt.clone()).attr("loading", "lazy").attr("draggable", "false"))
        .child(
            div()
                .class("compare-before")
                .style_dyn("clip-path", move || format!("inset(0 {}% 0 0)", 100 - split.get()))
                .child(img().attr("src", before).attr("alt", "").attr("loading", "lazy").attr("draggable", "false")),
        )
        .child(div().class("compare-handle").style_dyn("left", move || format!("{}%", split.get())))
        .child(span().class("compare-tag left").text("Avant"))
        .child(span().class("compare-tag right").text("Après"))
        .child(
            input()
                .attr("type", "range")
                .attr("min", "0")
                .attr("max", "100")
                .attr("aria-label", "Comparer avant et après")
                .bind_parsed(split),
        )
        .into()
}

/// Les îlots du site.
pub const ISLANDS: [(&str, fn(&str) -> Node); 2] = [("boot", boot), ("compare", compare)];
