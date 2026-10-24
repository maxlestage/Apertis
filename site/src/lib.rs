//! Partagé par le serveur et le navigateur : l'îlot « labo », une démonstration
//! interactive de la retouche d'Apertis.
//!
//! Le serveur le rend en HTML (src/main.rs) ; compilé en WebAssembly, il devient
//! interactif dans le navigateur.

use paquets::prelude::*;

/// Un style : exposition, contraste, saturation, température (-100 … 100).
struct Style {
    name: &'static str,
    values: [i32; 4],
}

const STYLES: [Style; 5] = [
    Style { name: "Original", values: [0, 0, 0, 0] },
    Style { name: "Naturel", values: [5, 10, 15, 0] },
    Style { name: "Argentique", values: [10, -15, -20, 45] },
    Style { name: "Cinéma", values: [-10, 25, -15, -35] },
    Style { name: "N&B", values: [0, 30, -100, 0] },
];

/// Le filtre CSS qui imite les réglages (la vraie app travaille sur le RAW).
fn css_filter(exposure: i32, contrast: i32, saturation: i32, temperature: i32) -> String {
    let brightness = 1.0 + f64::from(exposure) / 100.0 * 0.7;
    let contrast = 1.0 + f64::from(contrast) / 100.0 * 0.8;
    let saturate = (1.0 + f64::from(saturation) / 100.0).max(0.0);
    let (sepia, hue) = if temperature >= 0 {
        (f64::from(temperature) / 100.0 * 0.45, 0.0)
    } else {
        (0.0, f64::from(temperature) / 100.0 * 25.0)
    };
    format!(
        "brightness({brightness:.3}) contrast({contrast:.3}) saturate({saturate:.3}) sepia({sepia:.3}) hue-rotate({hue:.1}deg)"
    )
}

/// Le paysage de démonstration, dessiné en CSS (public/site.css).
fn scene() -> Element {
    div()
        .class("scene")
        .child(div().class("sky"))
        .child(div().class("sun"))
        .child(div().class("mountain far"))
        .child(div().class("mountain near"))
        .child(div().class("lake"))
}

fn slider(label_text: &'static str, state: State<i32>) -> Element {
    label()
        .class("labo-slider")
        .child(
            span()
                .class("row labo-label")
                .child(span().text(label_text))
                .child(span().class("muted").text_dyn(move || format!("{:+}", state.get()))),
        )
        .child(
            input()
                .attr("type", "range")
                .attr("min", "-100")
                .attr("max", "100")
                .attr("aria-label", label_text)
                .bind_parsed(state),
        )
}

/// L'îlot : curseurs, styles et comparaison avant/après.
pub fn labo(_props: &str) -> Node {
    let exposure = use_state(0);
    let contrast = use_state(0);
    let saturation = use_state(0);
    let temperature = use_state(0);
    let split = use_state(50);

    let presets = STYLES.iter().map(move |style| {
        let [e, c, s, t] = style.values;
        button()
            .class("ghost")
            .on_click(move |_| {
                exposure.set(e);
                contrast.set(c);
                saturation.set(s);
                temperature.set(t);
            })
            .text(style.name)
    });

    div()
        .class("labo")
        .child(
            div()
                .class("labo-frame")
                .child(scene().style_dyn("filter", move || {
                    css_filter(exposure.get(), contrast.get(), saturation.get(), temperature.get())
                }))
                .child(
                    scene()
                        .class("before")
                        .style_dyn("clip-path", move || format!("inset(0 {}% 0 0)", 100 - split.get())),
                )
                .child(div().class("divider").style_dyn("left", move || format!("{}%", split.get())))
                .child(span().class("tag left").text("Avant"))
                .child(span().class("tag right").text("Après")),
        )
        .child(
            div()
                .class("labo-controls stack")
                .child(slider("Exposition", exposure))
                .child(slider("Contraste", contrast))
                .child(slider("Saturation", saturation))
                .child(slider("Température", temperature))
                .child(
                    label()
                        .class("labo-slider")
                        .child(span().class("labo-label").text("Comparer avant / après"))
                        .child(
                            input()
                                .attr("type", "range")
                                .attr("min", "0")
                                .attr("max", "100")
                                .attr("aria-label", "Comparer avant / après")
                                .bind_parsed(split),
                        ),
                )
                .child(div().class("row").children(presets)),
        )
        .into()
}

/// Point d'entrée du navigateur : rend les îlots de la page interactifs.
#[cfg(target_arch = "wasm32")]
#[wasm_bindgen::prelude::wasm_bindgen(start)]
pub fn start() {
    paquets::hydrate(&[("labo", labo)]);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn neutral_filter_changes_nothing() {
        assert_eq!(
            css_filter(0, 0, 0, 0),
            "brightness(1.000) contrast(1.000) saturate(1.000) sepia(0.000) hue-rotate(0.0deg)"
        );
    }

    #[test]
    fn black_and_white_never_goes_negative() {
        assert!(css_filter(0, 0, -100, 0).contains("saturate(0.000)"));
        assert!(css_filter(0, 0, -100, -100).contains("hue-rotate(-25.0deg)"));
    }
}
