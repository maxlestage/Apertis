//! Le laboratoire photo : ouverture d'une image (fichier, glisser-déposer, exemples),
//! développement en direct sur le GPU, histogramme, styles, historique, recadrage et
//! export en pleine résolution. Tout reste dans le navigateur : aucune image n'est envoyée.

use std::cell::RefCell;
use std::rc::Rc;

use wasm_bindgen::{Clamped, JsCast};
use wasm_bindgen::prelude::*;
use wasm_bindgen_futures::{JsFuture, spawn_local};
use web_sys::{
    Blob, CanvasRenderingContext2d, Element, HtmlCanvasElement, HtmlDialogElement, HtmlElement, HtmlInputElement,
    HtmlSelectElement, ImageBitmap, ImageBitmapOptions, KeyboardEvent,
};

use super::controls;
use super::gl::{Renderer, Target, View};
use super::{by_id, document, next_frame, on, query_all, query_in, set_hidden, set_text, toggle_class, window};
use crate::grade::{self, Settings, PRESETS};

/// Taille maximale d'un export (limite des canevas de Safari sur iPhone).
const MAX_EXPORT_PIXELS: u64 = 16_777_216;

struct Lab {
    root: Element,
    renderer: Renderer,
    settings: Settings,
    history: Vec<Settings>,
    index: usize,
    view: View,
    name: String,
    loaded: bool,
    frame_pending: bool,
}

thread_local! {
    static LAB: RefCell<Option<Lab>> = const { RefCell::new(None) };
}

fn with<R>(f: impl FnOnce(&mut Lab) -> R) -> Option<R> {
    LAB.with(|lab| lab.try_borrow_mut().ok()?.as_mut().map(f))
}

pub fn init(root: Element) {
    let Some(canvas) = by_id::<HtmlCanvasElement>("lab-canvas") else {
        return;
    };
    let renderer = match Renderer::new(canvas) {
        Ok(r) => r,
        Err(e) => {
            fail(&format!("Votre navigateur ne prend pas en charge WebGL2 ({e}). Essayez Safari, Chrome ou Firefox récents."));
            return;
        }
    };
    LAB.with(|lab| {
        *lab.borrow_mut() = Some(Lab {
            root: root.clone(),
            renderer,
            settings: Settings::default(),
            history: vec![Settings::default()],
            index: 0,
            view: View::default(),
            name: "apertis".into(),
            loaded: false,
            frame_pending: false,
        });
    });

    controls::bind(
        &root,
        Settings::default(),
        Rc::new(|key, v| {
            with(|lab| {
                lab.settings.set(key, v);
            });
            request_render();
        }),
        Rc::new(|_| commit()),
    );
    bind_actions(&root);
    bind_files(&root);
    bind_keyboard();
    on(&window(), "resize", |_: web_sys::Event| request_render());

    // Exemple chargé au démarrage, sauf si la page demande l'inverse.
    if let Some(first) = query_in(&root, "[data-sample]") {
        if let Some(src) = first.get_attribute("data-sample") {
            load_url(src);
        }
    }
}

fn fail(message: &str) {
    set_text("lab-message", message);
    if let Some(el) = document().get_element_by_id("lab-message") {
        set_hidden(&el, false);
    }
}

fn busy(on: bool) {
    if let Some(el) = document().get_element_by_id("lab-busy") {
        set_hidden(&el, !on);
    }
}

// ---------------------------------------------------------------------------------
// Chargement
// ---------------------------------------------------------------------------------

fn bind_files(root: &Element) {
    if let Some(input) = by_id::<HtmlInputElement>("lab-file") {
        let input2 = input.clone();
        on(&input, "change", move |_: web_sys::Event| {
            if let Some(file) = super::take_file(&input2) {
                let name = file.name();
                load_blob(file.into(), name);
            }
        });
    }
    if let Some(input) = by_id::<HtmlInputElement>("lab-recipe-file") {
        let input2 = input.clone();
        on(&input, "change", move |_: web_sys::Event| {
            if let Some(file) = super::take_file(&input2) {
                spawn_local(async move {
                    let Ok(text) = JsFuture::from(file.text()).await else { return };
                    match Settings::from_json(&text.as_string().unwrap_or_default()) {
                        Some(s) => replace_settings(s),
                        None => toast("Cette recette n'est pas lisible."),
                    }
                });
            }
        });
    }
    if let Some(stage) = query_in(root, ".lab-stage") {
        let stage2 = stage.clone();
        on(&stage, "dragover", move |e: web_sys::DragEvent| {
            e.prevent_default();
            toggle_class(&stage2, "dragging", true);
        });
        let stage3 = stage.clone();
        on(&stage, "dragleave", move |_: web_sys::DragEvent| toggle_class(&stage3, "dragging", false));
        let stage4 = stage.clone();
        on(&stage, "drop", move |e: web_sys::DragEvent| {
            e.prevent_default();
            toggle_class(&stage4, "dragging", false);
            if let Some(file) = e.data_transfer().and_then(|d| d.files()).and_then(|f| f.get(0)) {
                if file.type_().starts_with("image/") {
                    let name = file.name();
                    load_blob(file.into(), name);
                } else {
                    toast("Déposez une image (JPEG, PNG, HEIC selon le navigateur, WebP…).");
                }
            }
        });
    }
    for button in query_all(root, "[data-sample]") {
        let button2 = button.clone();
        on(&button, "click", move |_: web_sys::Event| {
            if let Some(src) = button2.get_attribute("data-sample") {
                load_url(src);
            }
        });
    }
}

fn load_url(src: String) {
    busy(true);
    spawn_local(async move {
        let result: Result<Blob, JsValue> = async {
            let response: web_sys::Response = JsFuture::from(window().fetch_with_str(&src)).await?.dyn_into()?;
            JsFuture::from(response.blob()?).await?.dyn_into()
        }
        .await;
        match result {
            Ok(blob) => {
                let name = src.rsplit('/').next().unwrap_or("photo").to_owned();
                load_blob(blob, name);
            }
            Err(_) => {
                busy(false);
                toast("Impossible de charger l'exemple.");
            }
        }
    });
}

fn load_blob(blob: Blob, name: String) {
    busy(true);
    spawn_local(async move {
        match decode(&blob).await {
            Ok(bitmap) => {
                let ok = with(|lab| {
                    let result = lab.renderer.set_image(&bitmap);
                    if result.is_ok() {
                        lab.name = super::stem(&name);
                        lab.loaded = true;
                        lab.settings = Settings::default();
                        lab.history = vec![lab.settings];
                        lab.index = 0;
                        let (w, h) = lab.renderer.source_size;
                        set_text("lab-info", &format!("{} · {w} × {h} px", lab.name));
                        controls::sync(&lab.root, &lab.settings);
                        toggle_class(&lab.root, "loaded", true);
                    }
                    result
                });
                bitmap.close();
                busy(false);
                match ok {
                    Some(Ok(())) => {
                        update_history_buttons();
                        request_render();
                        next_frame(render_thumbnails);
                    }
                    Some(Err(e)) => toast(&e),
                    None => {}
                }
            }
            Err(message) => {
                busy(false);
                toast(&message);
            }
        }
    });
}

/// Décode l'image (orientation EXIF appliquée) et la réduit si elle dépasse la taille
/// de texture du GPU.
async fn decode(blob: &Blob) -> Result<ImageBitmap, String> {
    let unreadable = "Ce format d'image n'est pas lisible par votre navigateur.".to_owned();
    let options = ImageBitmapOptions::new();
    options.set_image_orientation(web_sys::ImageOrientation::FromImage);
    let promise = window().create_image_bitmap_with_blob_and_image_bitmap_options(blob, &options).map_err(|_| unreadable.clone())?;
    let bitmap: ImageBitmap = JsFuture::from(promise).await.map_err(|_| unreadable.clone())?.unchecked_into();
    let max = with(|lab| lab.renderer.max_texture).unwrap_or(4096);
    let (w, h) = (bitmap.width(), bitmap.height());
    if w <= max && h <= max {
        return Ok(bitmap);
    }
    let scale = f64::from(max) / f64::from(w.max(h));
    let resize = ImageBitmapOptions::new();
    resize.set_resize_width((f64::from(w) * scale).floor() as u32);
    resize.set_resize_height((f64::from(h) * scale).floor() as u32);
    resize.set_resize_quality(web_sys::ResizeQuality::High);
    let promise = window()
        .create_image_bitmap_with_image_bitmap_and_image_bitmap_options(&bitmap, &resize)
        .map_err(|_| unreadable.clone())?;
    let smaller: ImageBitmap = JsFuture::from(promise).await.map_err(|_| unreadable)?.unchecked_into();
    bitmap.close();
    toast(&format!("Image réduite à {} px de côté (limite de votre carte graphique).", max));
    Ok(smaller)
}

// ---------------------------------------------------------------------------------
// Rendu
// ---------------------------------------------------------------------------------

pub fn request_render() {
    let schedule = with(|lab| {
        let first = !lab.frame_pending;
        lab.frame_pending = true;
        first
    })
    .unwrap_or(false);
    if schedule {
        next_frame(render);
    }
}

fn render() {
    with(|lab| {
        lab.frame_pending = false;
        if !lab.loaded {
            return;
        }
        let Some(stage) = query_in(&lab.root, ".lab-canvas-wrap") else { return };
        let stage: HtmlElement = stage.unchecked_into();
        let geo = lab.renderer.geometry(&lab.settings);
        let ratio = window().device_pixel_ratio().clamp(1.0, 2.0);
        let avail_w = (f64::from(stage.client_width()) * ratio).max(1.0);
        let avail_h = (f64::from(stage.client_height()) * ratio).max(1.0);
        let scale = (avail_w / f64::from(geo.width)).min(avail_h / f64::from(geo.height)).min(1.0);
        let w = ((f64::from(geo.width) * scale).round() as u32).max(1);
        let h = ((f64::from(geo.height) * scale).round() as u32).max(1);
        let canvas = lab.renderer.canvas.clone();
        if canvas.width() != w || canvas.height() != h {
            canvas.set_width(w);
            canvas.set_height(h);
        }
        let style = canvas.style();
        let _ = style.set_property("width", &format!("{}px", f64::from(w) / ratio));
        let _ = style.set_property("height", &format!("{}px", f64::from(h) / ratio));
        lab.renderer.draw(&lab.settings, lab.view, Target { framebuffer: None, width: w, height: h, flip_y: false });

        // Histogramme du rendu (sans l'alerte d'écrêtage, qui colore les pixels).
        if let Some(hist) = by_id::<HtmlCanvasElement>("lab-hist") {
            let hw = 240u32;
            let hh = ((240.0 * f64::from(geo.height) / f64::from(geo.width)).round() as u32).clamp(16, 480);
            let view = View { clipping: false, ..lab.view };
            if let Ok(pixels) = lab.renderer.render_pixels(&lab.settings, view, hw, hh) {
                controls::draw_histogram(&hist, &pixels);
            }
            set_text("lab-dims", &format!("{} × {} px", geo.width, geo.height));
        }
    });
}

/// Vignettes des styles, rendues avec l'image ouverte.
fn render_thumbnails() {
    with(|lab| {
        let base = lab.settings;
        for button in query_all(&lab.root, "[data-preset]") {
            let id = button.get_attribute("data-preset").unwrap_or_default();
            let Some(preset) = PRESETS.iter().find(|p| p.id == id) else { continue };
            let Some(canvas) = button.query_selector("canvas").ok().flatten() else { continue };
            let canvas: HtmlCanvasElement = canvas.unchecked_into();
            let s = grade::apply_preset(&base, preset);
            let geo = lab.renderer.geometry(&s);
            let w = 160u32;
            let h = ((160.0 * f64::from(geo.height) / f64::from(geo.width)).round() as u32).clamp(40, 320);
            if let Ok(pixels) = lab.renderer.render_pixels(&s, View::default(), w, h) {
                put_pixels(&canvas, &pixels, w, h);
            }
        }
    });
    request_render();
}

fn put_pixels(canvas: &HtmlCanvasElement, pixels: &[u8], w: u32, h: u32) {
    canvas.set_width(w);
    canvas.set_height(h);
    if let Some(ctx) = canvas.get_context("2d").ok().flatten().and_then(|c| c.dyn_into::<CanvasRenderingContext2d>().ok()) {
        if let Ok(data) = web_sys::ImageData::new_with_u8_clamped_array_and_sh(Clamped(pixels), w, h) {
            let _ = ctx.put_image_data(&data, 0.0, 0.0);
        }
    }
}

// ---------------------------------------------------------------------------------
// Historique et actions
// ---------------------------------------------------------------------------------

fn commit() {
    with(|lab| {
        if lab.history.get(lab.index) == Some(&lab.settings) {
            return;
        }
        lab.history.truncate(lab.index + 1);
        lab.history.push(lab.settings);
        if lab.history.len() > 200 {
            lab.history.remove(1);
        }
        lab.index = lab.history.len() - 1;
    });
    update_history_buttons();
}

fn replace_settings(s: Settings) {
    with(|lab| {
        lab.settings = s;
        controls::sync(&lab.root, &lab.settings);
    });
    commit();
    request_render();
}

fn step_history(delta: i32) {
    with(|lab| {
        let target = lab.index as i32 + delta;
        if target < 0 || target as usize >= lab.history.len() {
            return;
        }
        lab.index = target as usize;
        lab.settings = lab.history[lab.index];
        controls::sync(&lab.root, &lab.settings);
    });
    update_history_buttons();
    request_render();
}

fn update_history_buttons() {
    with(|lab| {
        for (action, enabled) in [("undo", lab.index > 0), ("redo", lab.index + 1 < lab.history.len())] {
            if let Some(b) = query_in(&lab.root, &format!("[data-action={action}]")) {
                if enabled {
                    let _ = b.remove_attribute("disabled");
                } else {
                    let _ = b.set_attribute("disabled", "");
                }
            }
        }
        let edited = lab.settings != Settings::default();
        toggle_class(&lab.root, "edited", edited);
    });
}

fn set_original(original: bool) {
    let changed = with(|lab| {
        let changed = lab.view.original != original;
        lab.view.original = original;
        if let Some(b) = query_in(&lab.root, "[data-action=before]") {
            toggle_class(&b, "active", original);
        }
        changed
    })
    .unwrap_or(false);
    if changed {
        request_render();
    }
}

fn bind_actions(root: &Element) {
    for button in query_all(root, "[data-action]") {
        let action = button.get_attribute("data-action").unwrap_or_default();
        match action.as_str() {
            "before" => {
                on(&button, "pointerdown", |e: web_sys::PointerEvent| {
                    e.prevent_default();
                    set_original(true);
                });
                for end in ["pointerup", "pointerleave", "pointercancel"] {
                    on(&button, end, |_: web_sys::PointerEvent| set_original(false));
                }
            }
            _ => {
                let button2 = button.clone();
                on(&button, "click", move |_: web_sys::Event| run_action(&action, &button2));
            }
        }
    }
    if let Some(go) = by_id::<HtmlElement>("export-go") {
        on(&go, "click", |_: web_sys::Event| export());
    }
    if let Some(quality) = by_id::<HtmlInputElement>("export-quality") {
        let q2 = quality.clone();
        on(&quality, "input", move |_: web_sys::Event| set_text("export-quality-value", &format!("{} %", q2.value())));
    }
}

fn run_action(action: &str, button: &Element) {
    match action {
        "open" => {
            if let Some(input) = by_id::<HtmlElement>("lab-file") {
                input.click();
            }
        }
        "undo" => step_history(-1),
        "redo" => step_history(1),
        "reset" => {
            let keep = with(|lab| lab.settings).unwrap_or_default();
            replace_settings(Settings { rotate: keep.rotate, flip: keep.flip, ..Settings::default() });
        }
        "clip" => {
            with(|lab| {
                lab.view.clipping = !lab.view.clipping;
                toggle_class(button, "active", lab.view.clipping);
            });
            request_render();
        }
        "rotate" | "rotate-left" => {
            let delta = if action == "rotate" { 1 } else { 3 };
            let s = with(|lab| {
                let mut s = lab.settings;
                s.rotate = (s.rotate + delta) % 4;
                s
            });
            if let Some(s) = s {
                replace_settings(s);
                next_frame(render_thumbnails);
            }
        }
        "flip" => {
            if let Some(mut s) = with(|lab| lab.settings) {
                s.flip = !s.flip;
                replace_settings(s);
            }
        }
        "aspect" => {
            let i: f32 = button.get_attribute("data-aspect").and_then(|v| v.parse().ok()).unwrap_or(0.0);
            if let Some(mut s) = with(|lab| lab.settings) {
                s.set("aspect", i);
                replace_settings(s);
            }
        }
        "preset" => {
            let id = button.get_attribute("data-preset").unwrap_or_default();
            if let (Some(preset), Some(base)) = (PRESETS.iter().find(|p| p.id == id), with(|lab| lab.settings)) {
                replace_settings(grade::apply_preset(&base, preset));
            }
        }
        "recipe-save" => {
            if let Some((json, name)) = with(|lab| (lab.settings.to_json(), lab.name.clone())) {
                let parts = js_sys::Array::of1(&JsValue::from_str(&json));
                let options = web_sys::BlobPropertyBag::new();
                options.set_type("application/json");
                if let Ok(blob) = Blob::new_with_str_sequence_and_options(&parts, &options) {
                    super::download(&blob, &format!("{name}-recette.json"));
                }
            }
        }
        "recipe-load" => {
            if let Some(input) = by_id::<HtmlElement>("lab-recipe-file") {
                input.click();
            }
        }
        "export" => {
            let loaded = with(|lab| lab.loaded).unwrap_or(false);
            if !loaded {
                return;
            }
            set_text("export-status", "");
            if let Some(dialog) = by_id::<HtmlDialogElement>("lab-export") {
                let _ = dialog.show_modal();
            }
        }
        "close-export" => {
            if let Some(dialog) = by_id::<HtmlDialogElement>("lab-export") {
                dialog.close();
            }
        }
        _ => {}
    }
}

fn bind_keyboard() {
    on(&document(), "keydown", |e: KeyboardEvent| {
        let typing = e
            .target()
            .and_then(|t| t.dyn_into::<HtmlInputElement>().ok())
            .is_some_and(|i| i.type_() != "range");
        if typing {
            return;
        }
        let modifier = e.ctrl_key() || e.meta_key();
        match e.key().as_str() {
            "z" | "Z" if modifier => {
                e.prevent_default();
                step_history(if e.shift_key() { 1 } else { -1 });
            }
            "y" if modifier => {
                e.prevent_default();
                step_history(1);
            }
            "\\" | "b" if !modifier => set_original(true),
            _ => {}
        }
    });
    on(&document(), "keyup", |e: KeyboardEvent| {
        if matches!(e.key().as_str(), "\\" | "b") {
            set_original(false);
        }
    });
}

// ---------------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------------

fn export() {
    let format = by_id::<HtmlSelectElement>("export-format").map_or("image/jpeg".into(), |s| s.value());
    let quality: f64 = by_id::<HtmlInputElement>("export-quality").and_then(|q| q.value().parse().ok()).unwrap_or(92.0) / 100.0;
    let size: u32 = by_id::<HtmlSelectElement>("export-size").and_then(|s| s.value().parse().ok()).unwrap_or(0);
    set_text("export-status", "Rendu en cours…");
    if let Some(b) = by_id::<Element>("export-go") {
        let _ = b.set_attribute("disabled", "");
    }
    // Laisse le message s'afficher avant le rendu, qui occupe le fil principal.
    next_frame(move || next_frame(move || render_export(format, quality, size)));
}

fn render_export(format: String, quality: f64, size: u32) {
    let result = with(|lab| -> Result<(Vec<u8>, u32, u32, String), String> {
        let geo = lab.renderer.geometry(&lab.settings);
        let mut scale = 1.0_f64;
        if size > 0 {
            scale = scale.min(f64::from(size) / f64::from(geo.width.max(geo.height)));
        }
        let max = f64::from(lab.renderer.max_texture);
        scale = scale.min(max / f64::from(geo.width.max(geo.height)));
        let area = f64::from(geo.width) * f64::from(geo.height) * scale * scale;
        if area > MAX_EXPORT_PIXELS as f64 {
            scale *= (MAX_EXPORT_PIXELS as f64 / area).sqrt();
        }
        let w = ((f64::from(geo.width) * scale).floor() as u32).max(1);
        let h = ((f64::from(geo.height) * scale).floor() as u32).max(1);
        let view = View { original: false, clipping: false };
        let pixels = lab.renderer.render_pixels(&lab.settings, view, w, h)?;
        Ok((pixels, w, h, lab.name.clone()))
    });
    let done = |message: &str| {
        set_text("export-status", message);
        if let Some(b) = by_id::<Element>("export-go") {
            let _ = b.remove_attribute("disabled");
        }
    };
    let Some(result) = result else { return };
    let (pixels, w, h, name) = match result {
        Ok(r) => r,
        Err(e) => return done(&e),
    };
    let Ok(canvas) = document().create_element("canvas") else { return };
    let canvas: HtmlCanvasElement = canvas.unchecked_into();
    put_pixels(&canvas, &pixels, w, h);
    drop(pixels);
    let extension = match format.as_str() {
        "image/png" => "png",
        "image/webp" => "webp",
        _ => "jpg",
    };
    let file = format!("{name}-apertis.{extension}");
    let status = format!("Exporté : {file} ({w} × {h} px)");
    let callback = Closure::once_into_js(move |blob: JsValue| {
        match blob.dyn_into::<Blob>() {
            Ok(blob) => {
                super::download(&blob, &file);
                set_text("export-status", &status);
            }
            Err(_) => set_text("export-status", "Ce format n'est pas pris en charge par votre navigateur."),
        }
        if let Some(b) = by_id::<Element>("export-go") {
            let _ = b.remove_attribute("disabled");
        }
    });
    if canvas
        .to_blob_with_type_and_encoder_options(callback.unchecked_ref(), &format, &JsValue::from_f64(quality))
        .is_err()
    {
        done("L'export a échoué.");
    }
}

fn toast(message: &str) {
    let Some(el) = document().get_element_by_id("lab-toast") else { return };
    el.set_text_content(Some(message));
    set_hidden(&el, false);
    let el2 = el.clone();
    let hide = Closure::once_into_js(move || set_hidden(&el2, true));
    let _ = window().set_timeout_with_callback_and_timeout_and_arguments_0(hide.unchecked_ref(), 4500);
}
