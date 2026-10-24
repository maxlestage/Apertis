//! Le laboratoire vidéo : chaque image de la vidéo traverse le même pipeline que les
//! photos, en direct. Points d'entrée et de sortie, styles, puis export (image et son)
//! enregistré par le navigateur. Aucune vidéo n'est envoyée sur un serveur.

use std::cell::RefCell;
use std::rc::Rc;

use wasm_bindgen::JsCast;
use wasm_bindgen::prelude::*;
use web_sys::{
    AudioContext, Blob, BlobEvent, Element, HtmlCanvasElement, HtmlDialogElement, HtmlElement, HtmlInputElement,
    HtmlSelectElement, HtmlVideoElement, MediaRecorder, MediaRecorderOptions, MediaStream,
    MediaStreamAudioDestinationNode,
};

use super::controls;
use super::gl::{Renderer, Target, View};
use super::{by_id, next_frame, on, query_all, query_in, set_hidden, set_text, toggle_class, window};
use crate::grade::{self, Settings, PRESETS};

struct Recording {
    recorder: MediaRecorder,
    /// L'enregistreur démarre quand la lecture a réellement commencé au point d'entrée.
    started: bool,
    width: u32,
    height: u32,
}

struct Lab {
    root: Element,
    renderer: Renderer,
    video: HtmlVideoElement,
    settings: Settings,
    view: View,
    name: String,
    url: Option<String>,
    loaded: bool,
    dirty: bool,
    in_point: f64,
    out_point: f64,
    recording: Option<Recording>,
    frames: u32,
    audio: Option<(AudioContext, MediaStreamAudioDestinationNode)>,
}

thread_local! {
    static LAB: RefCell<Option<Lab>> = const { RefCell::new(None) };
}

fn with<R>(f: impl FnOnce(&mut Lab) -> R) -> Option<R> {
    LAB.with(|lab| lab.try_borrow_mut().ok()?.as_mut().map(f))
}

pub fn init(root: Element) {
    let (Some(canvas), Some(video)) = (by_id::<HtmlCanvasElement>("lab-canvas"), by_id::<HtmlVideoElement>("video-el")) else {
        return;
    };
    let renderer = match Renderer::new(canvas) {
        Ok(r) => r,
        Err(e) => {
            set_text("lab-message", &format!("Votre navigateur ne prend pas en charge WebGL2 ({e})."));
            if let Some(m) = by_id::<Element>("lab-message") {
                set_hidden(&m, false);
            }
            return;
        }
    };
    LAB.with(|lab| {
        *lab.borrow_mut() = Some(Lab {
            root: root.clone(),
            renderer,
            video: video.clone(),
            settings: Settings::default(),
            view: View::default(),
            name: "apertis".into(),
            url: None,
            loaded: false,
            dirty: true,
            in_point: 0.0,
            out_point: 0.0,
            recording: None,
            frames: 0,
            audio: None,
        });
    });

    controls::bind(
        &root,
        Settings::default(),
        Rc::new(|key, v| {
            with(|lab| {
                lab.settings.set(key, v);
                lab.dirty = true;
            });
        }),
        Rc::new(|_| {}),
    );
    bind_video(&video);
    bind_actions(&root);
    fill_formats();

    if let Some(input) = by_id::<HtmlInputElement>("video-file") {
        let input2 = input.clone();
        on(&input, "change", move |_: web_sys::Event| {
            if let Some(file) = super::take_file(&input2) {
                let name = file.name();
                load(&file, &name);
            }
        });
    }
    if let Some(stage) = query_in(&root, ".lab-stage") {
        on(&stage, "dragover", |e: web_sys::DragEvent| e.prevent_default());
        on(&stage, "drop", |e: web_sys::DragEvent| {
            e.prevent_default();
            if let Some(file) = e.data_transfer().and_then(|d| d.files()).and_then(|f| f.get(0)) {
                let name = file.name();
                load(&file, &name);
            }
        });
    }
    if let Some(sample) = query_in(&root, "[data-sample]").and_then(|b| b.get_attribute("data-sample")) {
        load_src(&sample, sample.rsplit('/').next().unwrap_or("video"), false);
    }
    frame_loop();
}

fn load(file: &web_sys::File, name: &str) {
    if !file.type_().starts_with("video/") && !file.type_().is_empty() {
        toast("Choisissez une vidéo (MP4, MOV, WebM…).");
        return;
    }
    let Ok(url) = web_sys::Url::create_object_url_with_blob(file) else { return };
    load_src(&url, name, true);
}

fn load_src(src: &str, name: &str, object_url: bool) {
    with(|lab| {
        if let Some(old) = lab.url.take() {
            let _ = web_sys::Url::revoke_object_url(&old);
        }
        if object_url {
            lab.url = Some(src.to_owned());
        }
        lab.name = super::stem(name);
        lab.loaded = false;
        lab.video.set_src(src);
        lab.video.load();
    });
}

fn bind_video(video: &HtmlVideoElement) {
    let v = video.clone();
    on(video, "loadedmetadata", move |_: web_sys::Event| {
        with(|lab| {
            lab.loaded = true;
            lab.dirty = true;
            lab.in_point = 0.0;
            lab.out_point = v.duration();
            toggle_class(&lab.root, "loaded", true);
            set_text(
                "lab-info",
                &format!("{} · {} × {} px · {}", lab.name, v.video_width(), v.video_height(), timecode(v.duration())),
            );
            if let Some(scrub) = by_id::<HtmlInputElement>("video-scrub") {
                scrub.set_max(&v.duration().to_string());
            }
        });
        update_range();
    });
    for event in ["seeked", "loadeddata", "timeupdate"] {
        let v = video.clone();
        on(video, event, move |_: web_sys::Event| {
            with(|lab| lab.dirty = true);
            set_text("video-time", &timecode(v.current_time()));
            if let Some(scrub) = by_id::<HtmlInputElement>("video-scrub") {
                scrub.set_value(&v.current_time().to_string());
            }
        });
    }
    for event in ["play", "pause"] {
        let v = video.clone();
        on(video, event, move |_: web_sys::Event| {
            if let Some(b) = by_id::<Element>("video-play") {
                b.set_text_content(Some(if v.paused() { "▶" } else { "❚❚" }));
                let _ = b.set_attribute("aria-label", if v.paused() { "Lecture" } else { "Pause" });
            }
        });
    }
    let v = video.clone();
    on(video, "error", move |_: web_sys::Event| {
        if v.src().is_empty() {
            return;
        }
        toast("Cette vidéo n'est pas lisible par votre navigateur (essayez MP4 H.264 ou HEVC sur Safari).");
    });
    if let Some(scrub) = by_id::<HtmlInputElement>("video-scrub") {
        let (s2, v2) = (scrub.clone(), video.clone());
        on(&scrub, "input", move |_: web_sys::Event| {
            if let Ok(t) = s2.value().parse::<f64>() {
                v2.set_current_time(t);
            }
        });
    }
}

/// Boucle d'affichage : une image développée par image d'écran pendant la lecture.
fn frame_loop() {
    let closure: Rc<RefCell<Option<Closure<dyn FnMut()>>>> = Rc::new(RefCell::new(None));
    let again = closure.clone();
    *closure.borrow_mut() = Some(Closure::new(move || {
        draw_frame();
        if let Some(c) = again.borrow().as_ref() {
            let _ = window().request_animation_frame(c.as_ref().unchecked_ref());
        }
    }));
    if let Some(c) = closure.borrow().as_ref() {
        let _ = window().request_animation_frame(c.as_ref().unchecked_ref());
    }
}

fn draw_frame() {
    let mut stop = false;
    with(|lab| {
        if !lab.loaded || (lab.video.paused() && !lab.dirty && lab.recording.is_none()) {
            return;
        }
        lab.dirty = false;
        if !lab.renderer.set_video_frame(&lab.video) {
            return;
        }
        let geo = lab.renderer.geometry(&lab.settings);
        let canvas = lab.renderer.canvas.clone();
        let (w, h) = if let Some(rec) = &lab.recording {
            (rec.width, rec.height)
        } else {
            let Some(stage) = query_in(&lab.root, ".lab-canvas-wrap") else { return };
            let stage: HtmlElement = stage.unchecked_into();
            let ratio = window().device_pixel_ratio().clamp(1.0, 2.0);
            let scale = (f64::from(stage.client_width()) * ratio / f64::from(geo.width))
                .min(f64::from(stage.client_height()) * ratio / f64::from(geo.height))
                .min(1.0);
            (((f64::from(geo.width) * scale) as u32).max(1), ((f64::from(geo.height) * scale) as u32).max(1))
        };
        if canvas.width() != w || canvas.height() != h {
            canvas.set_width(w);
            canvas.set_height(h);
        }
        if lab.recording.is_none() {
            let ratio = window().device_pixel_ratio().clamp(1.0, 2.0);
            let style = canvas.style();
            let _ = style.set_property("width", &format!("{}px", f64::from(w) / ratio));
            let _ = style.set_property("height", &format!("{}px", f64::from(h) / ratio));
        }
        lab.renderer.draw(&lab.settings, lab.view, Target { framebuffer: None, width: w, height: h, flip_y: false });

        // Histogramme, quelques fois par seconde.
        lab.frames = lab.frames.wrapping_add(1);
        if lab.recording.is_none() && (lab.video.paused() || lab.frames % 8 == 0) {
            if let Some(hist) = by_id::<HtmlCanvasElement>("lab-hist") {
                let hh = ((240.0 * f64::from(geo.height) / f64::from(geo.width)).round() as u32).clamp(16, 480);
                let view = View { clipping: false, ..lab.view };
                if let Ok(pixels) = lab.renderer.render_pixels(&lab.settings, view, 240, hh) {
                    controls::draw_histogram(&hist, &pixels);
                }
            }
            set_text("lab-dims", &format!("{} × {} px", geo.width, geo.height));
        }

        if let Some(rec) = lab.recording.as_mut() {
            if !rec.started && !lab.video.paused() {
                let _ = rec.recorder.start_with_time_slice(1000);
                rec.started = true;
            }
        }
        if lab.recording.is_some() {
            let t = lab.video.current_time();
            let span = (lab.out_point - lab.in_point).max(0.001);
            let progress = ((t - lab.in_point) / span).clamp(0.0, 1.0);
            if let Some(bar) = by_id::<HtmlElement>("export-progress-bar") {
                let _ = bar.style().set_property("width", &format!("{:.1}%", progress * 100.0));
            }
            set_text("export-status", &format!("Enregistrement… {:.0} %", progress * 100.0));
            stop = t >= lab.out_point || lab.video.ended();
        } else if !lab.video.paused() && lab.out_point > lab.in_point && lab.video.current_time() >= lab.out_point {
            // Lecture en boucle entre les points d'entrée et de sortie.
            lab.video.set_current_time(lab.in_point);
        }
    });
    if stop {
        stop_recording();
    }
}

fn bind_actions(root: &Element) {
    for button in query_all(root, "[data-action]") {
        let action = button.get_attribute("data-action").unwrap_or_default();
        if action == "before" {
            on(&button, "pointerdown", |e: web_sys::PointerEvent| {
                e.prevent_default();
                set_original(true);
            });
            for end in ["pointerup", "pointerleave", "pointercancel"] {
                on(&button, end, |_: web_sys::PointerEvent| set_original(false));
            }
            continue;
        }
        let button2 = button.clone();
        on(&button, "click", move |_: web_sys::Event| run_action(&action, &button2));
    }
    if let Some(go) = by_id::<HtmlElement>("export-go") {
        on(&go, "click", |_: web_sys::Event| start_recording());
    }
}

fn set_original(original: bool) {
    with(|lab| {
        lab.view.original = original;
        lab.dirty = true;
    });
}

fn apply(s: Settings) {
    with(|lab| {
        lab.settings = s;
        lab.dirty = true;
        controls::sync(&lab.root, &lab.settings);
    });
}

fn run_action(action: &str, button: &Element) {
    match action {
        "open" => {
            if let Some(input) = by_id::<HtmlElement>("video-file") {
                input.click();
            }
        }
        "play" => {
            with(|lab| {
                if lab.video.paused() {
                    if lab.out_point > lab.in_point && lab.video.current_time() >= lab.out_point {
                        lab.video.set_current_time(lab.in_point);
                    }
                    let _ = lab.video.play();
                } else {
                    let _ = lab.video.pause();
                }
            });
        }
        "step-back" | "step-forward" => {
            let delta = if action == "step-back" { -1.0 / 30.0 } else { 1.0 / 30.0 };
            with(|lab| {
                let _ = lab.video.pause();
                lab.video.set_current_time((lab.video.current_time() + delta).max(0.0));
            });
        }
        "mark-in" | "mark-out" => {
            with(|lab| {
                let t = lab.video.current_time();
                if action == "mark-in" {
                    lab.in_point = t.min(lab.out_point - 0.1).max(0.0);
                } else {
                    lab.out_point = t.max(lab.in_point + 0.1).min(lab.video.duration());
                }
            });
            update_range();
        }
        "clear-range" => {
            with(|lab| {
                lab.in_point = 0.0;
                lab.out_point = lab.video.duration();
            });
            update_range();
        }
        "mute" => {
            with(|lab| {
                let muted = !lab.video.muted();
                lab.video.set_muted(muted);
                toggle_class(button, "active", muted);
            });
        }
        "reset" => apply(Settings::default()),
        "preset" => {
            let id = button.get_attribute("data-preset").unwrap_or_default();
            if let (Some(preset), Some(base)) = (PRESETS.iter().find(|p| p.id == id), with(|lab| lab.settings)) {
                apply(grade::apply_preset(&base, preset));
            }
        }
        "aspect" => {
            let i: f32 = button.get_attribute("data-aspect").and_then(|v| v.parse().ok()).unwrap_or(0.0);
            if let Some(mut s) = with(|lab| lab.settings) {
                s.set("aspect", i);
                apply(s);
            }
        }
        "clip" => {
            with(|lab| {
                lab.view.clipping = !lab.view.clipping;
                lab.dirty = true;
                toggle_class(button, "active", lab.view.clipping);
            });
        }
        "export" => {
            if !with(|lab| lab.loaded).unwrap_or(false) {
                return;
            }
            set_text("export-status", "");
            if let Some(dialog) = by_id::<HtmlDialogElement>("lab-export") {
                let _ = dialog.show_modal();
            }
        }
        "close-export" => {
            stop_recording();
            if let Some(dialog) = by_id::<HtmlDialogElement>("lab-export") {
                dialog.close();
            }
        }
        _ => {}
    }
}

fn update_range() {
    with(|lab| {
        let d = lab.video.duration();
        if !d.is_finite() || d <= 0.0 {
            return;
        }
        set_text(
            "video-range",
            &format!("Entrée {} · Sortie {} · Durée {}", timecode(lab.in_point), timecode(lab.out_point), timecode(lab.out_point - lab.in_point)),
        );
        if let Some(bar) = by_id::<HtmlElement>("video-range-bar") {
            let style = bar.style();
            let _ = style.set_property("left", &format!("{:.2}%", lab.in_point / d * 100.0));
            let _ = style.set_property("width", &format!("{:.2}%", (lab.out_point - lab.in_point) / d * 100.0));
        }
    });
}

/// Formats d'enregistrement pris en charge par ce navigateur, du plus compatible au moins.
const FORMATS: [(&str, &str, &str); 5] = [
    ("video/mp4;codecs=avc1.640028,mp4a.40.2", "MP4 (H.264, AAC)", "mp4"),
    ("video/mp4", "MP4 (codec du navigateur)", "mp4"),
    ("video/webm;codecs=vp9,opus", "WebM (VP9, Opus)", "webm"),
    ("video/webm;codecs=vp8,opus", "WebM (VP8, Opus)", "webm"),
    ("video/webm", "WebM", "webm"),
];

fn fill_formats() {
    let Some(select) = by_id::<HtmlSelectElement>("export-format") else { return };
    let mut any = false;
    for (mime, label, _) in FORMATS {
        if MediaRecorder::is_type_supported(mime) {
            if let Ok(option) = super::document().create_element("option") {
                let _ = option.set_attribute("value", mime);
                option.set_text_content(Some(label));
                let _ = select.append_child(&option);
                any = true;
            }
        }
    }
    if !any {
        set_text("export-status", "Votre navigateur ne sait pas enregistrer de vidéo (MediaRecorder).");
        if let Some(b) = by_id::<Element>("export-go") {
            let _ = b.set_attribute("disabled", "");
        }
    }
}

fn start_recording() {
    let mime = by_id::<HtmlSelectElement>("export-format").map(|s| s.value()).unwrap_or_default();
    let max_edge: u32 = by_id::<HtmlSelectElement>("export-size").and_then(|s| s.value().parse().ok()).unwrap_or(1920);
    let bitrate: u32 = by_id::<HtmlSelectElement>("export-bitrate").and_then(|s| s.value().parse().ok()).unwrap_or(12_000_000);
    if mime.is_empty() {
        return;
    }
    let started = with(|lab| -> Result<(), String> {
        if lab.recording.is_some() {
            return Ok(());
        }
        let geo = lab.renderer.geometry(&lab.settings);
        let scale = (f64::from(max_edge) / f64::from(geo.width.max(geo.height))).min(1.0);
        // Dimensions paires : exigées par la plupart des encodeurs.
        let even = |v: f64| ((v as u32) / 2 * 2).max(2);
        let (w, h) = (even(f64::from(geo.width) * scale), even(f64::from(geo.height) * scale));

        let stream: MediaStream = lab
            .renderer
            .canvas
            .capture_stream_with_frame_request_rate(30.0)
            .map_err(|_| "Capture du canevas impossible")?;
        // Le son passe par Web Audio pour être enregistré et rester audible.
        if lab.audio.is_none() {
            if let Ok(ctx) = AudioContext::new() {
                if let (Ok(source), Ok(dest)) = (ctx.create_media_element_source(&lab.video), ctx.create_media_stream_destination()) {
                    let _ = source.connect_with_audio_node(&dest);
                    let _ = source.connect_with_audio_node(&ctx.destination());
                    lab.audio = Some((ctx, dest));
                }
            }
        }
        if let Some((ctx, dest)) = &lab.audio {
            let _ = ctx.resume();
            let tracks = dest.stream().get_audio_tracks();
            for i in 0..tracks.length() {
                if let Ok(track) = tracks.get(i).dyn_into::<web_sys::MediaStreamTrack>() {
                    stream.add_track(&track);
                }
            }
        }
        let options = MediaRecorderOptions::new();
        options.set_mime_type(&mime);
        options.set_video_bits_per_second(bitrate);
        let recorder =
            MediaRecorder::new_with_media_stream_and_media_recorder_options(&stream, &options).map_err(|_| "Enregistreur indisponible")?;

        let chunks: Rc<RefCell<Vec<Blob>>> = Rc::new(RefCell::new(Vec::new()));
        let c2 = chunks.clone();
        let on_data = Closure::<dyn FnMut(BlobEvent)>::new(move |e: BlobEvent| {
            if let Some(blob) = e.data() {
                if blob.size() > 0.0 {
                    c2.borrow_mut().push(blob);
                }
            }
        });
        recorder.set_ondataavailable(Some(on_data.as_ref().unchecked_ref()));
        on_data.forget();
        let extension = FORMATS.iter().find(|f| f.0 == mime).map_or("webm", |f| f.2);
        let file = format!("{}-apertis.{extension}", lab.name);
        let mime2 = mime.clone();
        let on_stop = Closure::<dyn FnMut()>::new(move || {
            let parts = js_sys::Array::new();
            for blob in chunks.borrow().iter() {
                parts.push(blob);
            }
            let options = web_sys::BlobPropertyBag::new();
            options.set_type(mime2.split(';').next().unwrap_or("video/webm"));
            if let Ok(blob) = Blob::new_with_blob_sequence_and_options(&parts, &options) {
                let mb = blob.size() / 1_000_000.0;
                super::download(&blob, &file);
                set_text("export-status", &format!("Exporté : {file} ({mb:.1} Mo)"));
            }
            chunks.borrow_mut().clear();
            if let Some(b) = by_id::<Element>("export-go") {
                let _ = b.remove_attribute("disabled");
            }
        });
        recorder.set_onstop(Some(on_stop.as_ref().unchecked_ref()));
        on_stop.forget();

        lab.recording = Some(Recording { recorder: recorder.clone(), started: false, width: w, height: h });
        let _ = lab.video.pause();
        lab.video.set_current_time(lab.in_point);
        let video = lab.video.clone();
        // Lecture après le positionnement sur le point d'entrée ; l'enregistreur démarre
        // à la première image lue (voir draw_frame).
        let start = Closure::once_into_js(move || {
            let _ = video.play();
        });
        let _ = window().set_timeout_with_callback_and_timeout_and_arguments_0(start.unchecked_ref(), 250);
        Ok(())
    });
    match started {
        Some(Ok(())) => {
            if let Some(b) = by_id::<Element>("export-go") {
                let _ = b.set_attribute("disabled", "");
            }
            set_text("export-status", "Préparation…");
        }
        Some(Err(e)) => set_text("export-status", &e),
        None => {}
    }
}

fn stop_recording() {
    let recording = with(|lab| {
        let rec = lab.recording.take();
        if rec.is_some() {
            let _ = lab.video.pause();
            lab.dirty = true;
        }
        rec
    })
    .flatten();
    if let Some(rec) = recording {
        if rec.started && rec.recorder.state() != web_sys::RecordingState::Inactive {
            let _ = rec.recorder.stop();
        } else {
            // Rien n'a été enregistré : on rend la main sans fichier.
            set_text("export-status", "Enregistrement annulé.");
            if let Some(b) = by_id::<Element>("export-go") {
                let _ = b.remove_attribute("disabled");
            }
            return;
        }
        set_text("export-status", "Finalisation du fichier…");
        next_frame(|| with(|lab| lab.dirty = true).unwrap_or(()));
    }
}

/// `mm:ss.d`, ou `h:mm:ss` au-delà d'une heure.
fn timecode(t: f64) -> String {
    if !t.is_finite() || t < 0.0 {
        return "00:00.0".into();
    }
    let total = t.floor() as u64;
    let tenths = ((t - t.floor()) * 10.0).floor() as u64;
    if total >= 3600 {
        format!("{}:{:02}:{:02}", total / 3600, (total / 60) % 60, total % 60)
    } else {
        format!("{:02}:{:02}.{tenths}", total / 60, total % 60)
    }
}

fn toast(message: &str) {
    let Some(el) = super::document().get_element_by_id("lab-toast") else { return };
    el.set_text_content(Some(message));
    set_hidden(&el, false);
    let el2 = el.clone();
    let hide = Closure::once_into_js(move || set_hidden(&el2, true));
    let _ = window().set_timeout_with_callback_and_timeout_and_arguments_0(hide.unchecked_ref(), 5000);
}
