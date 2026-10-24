//! Le panneau de réglages, commun aux laboratoires photo et vidéo : curseurs, onglets,
//! plages TSL, zones d'étalonnage, histogramme.

use std::rc::Rc;

use wasm_bindgen::{Clamped, JsCast};
use web_sys::{CanvasRenderingContext2d, Element, HtmlCanvasElement, HtmlInputElement};

use super::{on, query_all, toggle_class};
use crate::grade::{Settings, Unit, COLOR, CURVE, EFFECTS, LIGHT};

pub type OnInput = Rc<dyn Fn(&str, f32)>;
pub type OnCommit = Rc<dyn Fn(&str)>;

fn unit_of(key: &str) -> Unit {
    if key == "straighten" {
        return Unit::Degrees;
    }
    [LIGHT, COLOR, CURVE, EFFECTS]
        .iter()
        .flat_map(|g| g.controls.iter())
        .find(|c| c.key == key)
        .map_or(Unit::None, |c| c.unit)
}

/// Valeur affichée à côté d'un curseur.
pub fn format_value(key: &str, v: f32) -> String {
    match unit_of(key) {
        Unit::Ev => format!("{v:+.2} IL"),
        Unit::Degrees => {
            if key.starts_with("grade_h") {
                format!("{v:.0}°")
            } else {
                format!("{v:+.1}°")
            }
        }
        Unit::None if key == "grain_size" => format!("{v:.1}"),
        Unit::None if key.starts_with("grade_h") => format!("{v:.0}°"),
        Unit::None => {
            if v.abs() < 0.5 { "0".into() } else if key.starts_with("grade_s") || matches!(key, "fade" | "grain" | "sharpen") { format!("{v:.0}") } else { format!("{v:+.0}") }
        }
    }
}

/// Branche les curseurs, onglets et sélecteurs d'un laboratoire.
pub fn bind(root: &Element, defaults: Settings, on_input: OnInput, on_commit: OnCommit) {
    for input in query_all(root, "input[type=range][data-key]") {
        let input: HtmlInputElement = input.unchecked_into();
        let key = input.dataset().get("key").unwrap_or_default();
        {
            let (key, input2, on_input) = (key.clone(), input.clone(), on_input.clone());
            on(&input, "input", move |_: web_sys::Event| {
                let v: f32 = input2.value().parse().unwrap_or(0.0);
                show(&input2, &key, v);
                on_input(&key, v);
            });
        }
        {
            let (key, on_commit) = (key.clone(), on_commit.clone());
            on(&input, "change", move |_: web_sys::Event| on_commit(&key));
        }
        // Double-clic (ou double-toucher) sur la ligne : valeur neutre.
        if let Some(row) = input.closest(".control").ok().flatten() {
            let (key, input2, on_input, on_commit) = (key.clone(), input.clone(), on_input.clone(), on_commit.clone());
            on(&row, "dblclick", move |_: web_sys::Event| {
                let v = defaults.get(&key).unwrap_or(0.0);
                input2.set_value(&v.to_string());
                show(&input2, &key, v);
                on_input(&key, v);
                on_commit(&key);
            });
        }
    }

    // Onglets du panneau.
    let tabs = query_all(root, "[data-tab]");
    for tab in &tabs {
        let (tab2, tabs2, root2) = (tab.clone(), tabs.clone(), root.clone());
        on(tab, "click", move |_: web_sys::Event| {
            let name = tab2.get_attribute("data-tab").unwrap_or_default();
            for t in &tabs2 {
                let active = t.get_attribute("data-tab").as_deref() == Some(name.as_str());
                toggle_class(t, "active", active);
                let _ = t.set_attribute("aria-selected", if active { "true" } else { "false" });
            }
            for panel in query_all(&root2, "[data-panel]") {
                super::set_hidden(&panel, panel.get_attribute("data-panel").as_deref() != Some(name.as_str()));
            }
            // Sur téléphone, si la page a défilé, le nouveau panneau commence sous les onglets.
            if let (Some(bar), Some(panels)) = (tab2.parent_element(), super::query_in(&root2, ".panels")) {
                let gap = panels.get_bounding_client_rect().top() - bar.get_bounding_client_rect().bottom();
                if gap < -1.0 {
                    super::window().scroll_by_with_x_and_y(0.0, gap);
                }
            }
        });
    }

    selector(root, "data-band", "data-band-row");
    selector(root, "data-zone", "data-zone-row");
}

/// Boutons qui affichent un groupe de lignes (plage TSL, zone d'étalonnage).
fn selector(root: &Element, button_attr: &'static str, row_attr: &'static str) {
    let buttons = query_all(root, &format!("[{button_attr}]"));
    for button in &buttons {
        let (button2, buttons2, root2) = (button.clone(), buttons.clone(), root.clone());
        on(button, "click", move |_: web_sys::Event| {
            let id = button2.get_attribute(button_attr).unwrap_or_default();
            for b in &buttons2 {
                toggle_class(b, "active", b.get_attribute(button_attr).as_deref() == Some(id.as_str()));
            }
            for row in query_all(&root2, &format!("[{row_attr}]")) {
                super::set_hidden(&row, row.get_attribute(row_attr).as_deref() != Some(id.as_str()));
            }
        });
    }
}

fn show(input: &HtmlInputElement, key: &str, v: f32) {
    if let Some(out) = input.closest(".control").ok().flatten().and_then(|row| row.query_selector("output").ok().flatten()) {
        out.set_text_content(Some(&format_value(key, v)));
    }
    if let Some(row) = input.closest(".control").ok().flatten() {
        toggle_class(&row, "changed", v.abs() > 1e-3 && key != "grain_size");
    }
}

/// Met les curseurs à jour après une annulation, un style ou une recette.
pub fn sync(root: &Element, s: &Settings) {
    for input in query_all(root, "input[type=range][data-key]") {
        let input: HtmlInputElement = input.unchecked_into();
        let key = input.dataset().get("key").unwrap_or_default();
        if let Some(v) = s.get(&key) {
            input.set_value(&v.to_string());
            show(&input, &key, v);
        }
    }
    for button in query_all(root, "[data-aspect]") {
        let i: u8 = button.get_attribute("data-aspect").and_then(|v| v.parse().ok()).unwrap_or(0);
        toggle_class(&button, "active", i == s.aspect);
    }
}

/// Histogramme RVB à partir de pixels RGBA.
pub fn draw_histogram(canvas: &HtmlCanvasElement, pixels: &[u8]) {
    let Some(ctx) = canvas
        .get_context("2d")
        .ok()
        .flatten()
        .and_then(|c| c.dyn_into::<CanvasRenderingContext2d>().ok())
    else {
        return;
    };
    let mut bins = [[0u32; 256]; 3];
    for px in pixels.chunks_exact(4) {
        for c in 0..3 {
            bins[c][px[c] as usize] += 1;
        }
    }
    // Échelle : on ignore les extrémités pour que l'écrêtage n'écrase pas la courbe.
    let peak = bins.iter().flat_map(|b| b[2..254].iter()).copied().max().unwrap_or(1).max(1) as f32;
    let (w, h) = (canvas.width() as usize, canvas.height() as usize);
    let mut image = vec![0u8; w * h * 4];
    for x in 0..w {
        let bin = x * 256 / w;
        for (c, channel) in bins.iter().enumerate() {
            let v = (channel[bin] as f32 / peak).min(1.0);
            let top = h - (v * (h as f32 - 1.0)) as usize;
            for y in top..h {
                let i = (y * w + x) * 4;
                image[i + c] = image[i + c].saturating_add(170);
                image[i + 3] = 230;
            }
        }
    }
    if let Ok(data) = web_sys::ImageData::new_with_u8_clamped_array_and_sh(Clamped(&image), w as u32, h as u32) {
        let _ = ctx.put_image_data(&data, 0.0, 0.0);
    }
    // Indicateurs d'écrêtage.
    let total = (pixels.len() / 4).max(1) as f32;
    let clipped_hi = pixels.chunks_exact(4).filter(|p| p[0] >= 254 || p[1] >= 254 || p[2] >= 254).count() as f32 / total;
    let clipped_lo = pixels.chunks_exact(4).filter(|p| p[0] <= 1 && p[1] <= 1 && p[2] <= 1).count() as f32 / total;
    if let Some(parent) = canvas.parent_element() {
        toggle_class(&parent, "clip-hi", clipped_hi > 0.002);
        toggle_class(&parent, "clip-lo", clipped_lo > 0.002);
    }
}
