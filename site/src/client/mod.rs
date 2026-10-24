//! Le code du navigateur : îlots du site, laboratoires photo et vidéo.

mod controls;
mod gl;
mod photo;
mod video;

use wasm_bindgen::JsCast;
use wasm_bindgen::prelude::*;
use web_sys::{Document, Element, EventTarget, HtmlElement, Window};

#[wasm_bindgen(start)]
pub fn start() {
    paquets::hydrate(&crate::ISLANDS);
    if let Some(root) = query("[data-lab=photo]") {
        photo::init(root);
    }
    if let Some(root) = query("[data-lab=video]") {
        video::init(root);
    }
    // Un toucher hors du menu « Plus » le referme.
    on(&document(), "click", |e: web_sys::MouseEvent| {
        let target = e.target().and_then(|t| t.dyn_into::<web_sys::Node>().ok());
        for menu in query_all(&document().document_element().expect("html"), "details.more[open]") {
            if !menu.contains(target.as_ref()) {
                let _ = menu.remove_attribute("open");
            }
        }
    });
}

pub fn window() -> Window {
    web_sys::window().expect("window")
}

pub fn document() -> Document {
    window().document().expect("document")
}

pub fn query(selector: &str) -> Option<Element> {
    document().query_selector(selector).ok().flatten()
}

pub fn query_in(root: &Element, selector: &str) -> Option<Element> {
    root.query_selector(selector).ok().flatten()
}

pub fn query_all(root: &Element, selector: &str) -> Vec<Element> {
    let Ok(list) = root.query_selector_all(selector) else {
        return Vec::new();
    };
    (0..list.length()).filter_map(|i| list.item(i)?.dyn_into::<Element>().ok()).collect()
}

pub fn by_id<T: JsCast>(id: &str) -> Option<T> {
    document().get_element_by_id(id)?.dyn_into::<T>().ok()
}

/// Ajoute un écouteur pour toute la durée de la page.
pub fn on<E: JsCast + 'static>(target: &EventTarget, event: &str, f: impl FnMut(E) + 'static) {
    let mut f = f;
    let closure = Closure::<dyn FnMut(web_sys::Event)>::new(move |e: web_sys::Event| f(e.unchecked_into()));
    let _ = target.add_event_listener_with_callback(event, closure.as_ref().unchecked_ref());
    closure.forget();
}

/// Appelle `f` à la prochaine image d'affichage.
pub fn next_frame(f: impl FnOnce() + 'static) {
    let closure = Closure::once_into_js(f);
    let _ = window().request_animation_frame(closure.unchecked_ref());
}

pub fn set_text(id: &str, text: &str) {
    if let Some(el) = document().get_element_by_id(id) {
        el.set_text_content(Some(text));
    }
}

pub fn set_hidden(el: &Element, hidden: bool) {
    if hidden {
        let _ = el.set_attribute("hidden", "");
    } else {
        let _ = el.remove_attribute("hidden");
    }
}

pub fn toggle_class(el: &Element, class: &str, on: bool) {
    let _ = el.class_list().toggle_with_force(class, on);
}

/// Télécharge un `Blob` sous le nom donné.
pub fn download(blob: &web_sys::Blob, name: &str) {
    let Ok(url) = web_sys::Url::create_object_url_with_blob(blob) else {
        return;
    };
    if let Ok(a) = document().create_element("a") {
        let a: HtmlElement = a.unchecked_into();
        let _ = a.set_attribute("href", &url);
        let _ = a.set_attribute("download", name);
        let _ = document().body().map(|b| b.append_child(&a));
        a.click();
        a.remove();
    }
    // Laisse au navigateur le temps de lire le fichier avant de libérer l'URL.
    let release = Closure::once_into_js(move || {
        let _ = web_sys::Url::revoke_object_url(&url);
    });
    let _ = window().set_timeout_with_callback_and_timeout_and_arguments_0(release.unchecked_ref(), 60_000);
}

/// Nom de fichier sans extension.
pub fn stem(name: &str) -> String {
    let base = name.rsplit_once('.').map_or(name, |(s, _)| s);
    let clean: String = base.chars().filter(|c| c.is_alphanumeric() || matches!(c, '-' | '_' | ' ')).collect();
    if clean.trim().is_empty() { "apertis".into() } else { clean.trim().to_owned() }
}

/// Le fichier choisi dans un `<input type=file>`, puis le champ est vidé pour pouvoir
/// rechoisir le même fichier.
pub fn take_file(input: &web_sys::HtmlInputElement) -> Option<web_sys::File> {
    let file = input.files()?.get(0);
    input.set_value("");
    file
}

/// Referme le menu « Plus » qui contient `button`, s'il y en a un.
pub fn close_menu(button: &Element) {
    if let Some(menu) = button.closest("details").ok().flatten() {
        let _ = menu.remove_attribute("open");
    }
}

/// Reflète l'état de l'alerte d'écrêtage : boutons et légende.
pub fn show_clipping(root: &Element, on: bool) {
    for b in query_all(root, "[data-action=clip]") {
        toggle_class(&b, "active", on);
    }
    if let Some(legend) = document().get_element_by_id("lab-clip-legend") {
        set_hidden(&legend, !on);
    }
}
