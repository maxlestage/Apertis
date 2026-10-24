//! Les pages des laboratoires photo et vidéo. Le serveur rend toute l'interface ;
//! le code WebAssembly (src/client) la pilote et calcule les images sur le GPU.

use paquets::prelude::*;

use super::layout::{icon, page, Meta};
use crate::grade::{Control, Group, Settings, Unit, ASPECTS, COLOR, CURVE, EFFECTS, GRADE_ZONES, HSL_BANDS, LIGHT, PRESETS};
use crate::boot;

/// Message affiché sans JavaScript.
fn client_note() -> Element {
    noscript().child(p().class("lab-message").text("Le laboratoire fonctionne dans le navigateur : activez JavaScript pour l'utiliser."))
}

fn format(control: &Control, v: f32) -> String {
    match control.unit {
        Unit::Ev => format!("{v:+.2} IL"),
        Unit::Degrees => format!("{v:+.1}°"),
        Unit::None if control.min >= 0.0 && control.max <= 360.0 && control.key.starts_with("grade_h") => format!("{v:.0}°"),
        Unit::None if control.key == "grain_size" => format!("{v:.1}"),
        Unit::None if control.min >= 0.0 => format!("{v:.0}"),
        Unit::None => "0".into(),
    }
}

fn slider(control: &Control, track: Option<&str>) -> Element {
    let value = Settings::default().get(control.key).unwrap_or(0.0);
    let id = format!("c-{}", control.key);
    let mut input = input()
        .attr("type", "range")
        .attr("id", id.clone())
        .attr("data-key", control.key)
        .attr("min", control.min.to_string())
        .attr("max", control.max.to_string())
        .attr("step", control.step.to_string())
        .attr("value", value.to_string());
    if let Some(track) = track {
        input = input.class(track.to_owned());
    }
    div()
        .class("control")
        .attr("title", "Double-cliquez pour revenir à la valeur neutre")
        .child(
            div()
                .class("control-head")
                .child(label().attr("for", id).text(control.label))
                .child(output().text(format(control, value))),
        )
        .child(input)
}

fn group_panel(group: &Group, hidden: bool) -> Element {
    let panel = div()
        .class("panel")
        .attr("data-panel", group.id)
        .attr("role", "tabpanel")
        .children(group.controls.iter().map(|c| slider(c, None)));
    if hidden { panel.attr("hidden", "") } else { panel }
}

fn tabs(items: &[(&str, &str)]) -> Element {
    div().class("tabs").attr("role", "tablist").children(items.iter().enumerate().map(|(i, (id, label))| {
        button()
            .attr("type", "button")
            .attr("role", "tab")
            .attr("data-tab", (*id).to_owned())
            .attr("aria-selected", if i == 0 { "true" } else { "false" })
            .class(if i == 0 { "tab active" } else { "tab" })
            .text((*label).to_owned())
    }))
}

fn hsl_panel() -> Element {
    let bands = div().class("swatches").children(HSL_BANDS.iter().enumerate().map(|(i, (name, hue))| {
        button()
            .attr("type", "button")
            .attr("data-band", i.to_string())
            .attr("aria-label", (*name).to_owned())
            .attr("title", (*name).to_owned())
            .class(if i == 0 { "swatch active" } else { "swatch" })
            .style(format!("--h:{hue}"))
    }));
    let rows = HSL_BANDS.iter().enumerate().map(|(i, (name, _))| {
        let controls = [
            Control { key: leak(format!("hsl_h{i}")), label: "Teinte", min: -100.0, max: 100.0, step: 1.0, unit: Unit::None },
            Control { key: leak(format!("hsl_s{i}")), label: "Saturation", min: -100.0, max: 100.0, step: 1.0, unit: Unit::None },
            Control { key: leak(format!("hsl_l{i}")), label: "Luminance", min: -100.0, max: 100.0, step: 1.0, unit: Unit::None },
        ];
        let row = div()
            .class("band-rows")
            .attr("data-band-row", i.to_string())
            .child(p().class("panel-title").text(*name))
            .children(controls.iter().map(|c| slider(c, None)));
        if i == 0 { row } else { row.attr("hidden", "") }
    });
    div()
        .class("panel")
        .attr("data-panel", "tsl")
        .attr("hidden", "")
        .child(bands)
        .children(rows)
}

fn grading_panel() -> Element {
    let zones = div().class("segmented").children(GRADE_ZONES.iter().enumerate().map(|(i, name)| {
        button()
            .attr("type", "button")
            .attr("data-zone", i.to_string())
            .class(if i == 0 { "active" } else { "" })
            .text(*name)
    }));
    let rows = GRADE_ZONES.iter().enumerate().map(|(i, _)| {
        let hue = Control { key: leak(format!("grade_h{i}")), label: "Teinte", min: 0.0, max: 360.0, step: 1.0, unit: Unit::None };
        let amount = Control { key: leak(format!("grade_s{i}")), label: "Intensité", min: 0.0, max: 100.0, step: 1.0, unit: Unit::None };
        let row = div()
            .class("zone-rows")
            .attr("data-zone-row", i.to_string())
            .child(slider(&hue, Some("hue-track")))
            .child(slider(&amount, None));
        if i == 0 { row } else { row.attr("hidden", "") }
    });
    let fade = Control { key: "fade", label: "Fondu", min: 0.0, max: 100.0, step: 1.0, unit: Unit::None };
    div()
        .class("panel")
        .attr("data-panel", "etalonnage")
        .attr("hidden", "")
        .child(zones)
        .children(rows)
        .child(slider(&fade, None))
}

/// Les clés des réglages TSL et d'étalonnage, créées une seule fois.
fn leak(key: String) -> &'static str {
    use std::collections::HashMap;
    use std::sync::{Mutex, OnceLock};
    static KEYS: OnceLock<Mutex<HashMap<String, &'static str>>> = OnceLock::new();
    let mut keys = KEYS.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner());
    if let Some(k) = keys.get(&key) {
        return k;
    }
    let leaked: &'static str = Box::leak(key.clone().into_boxed_str());
    keys.insert(key, leaked);
    leaked
}

fn effects_panel() -> Element {
    group_panel(&EFFECTS, true)
}

fn crop_panel(photo: bool) -> Element {
    let straighten = Control { key: "straighten", label: "Redresser", min: -45.0, max: 45.0, step: 0.1, unit: Unit::Degrees };
    let mut panel = div().class("panel").attr("data-panel", "cadrage").attr("hidden", "");
    if photo {
        panel = panel.child(
            div()
                .class("tool-row")
                .child(tool_button("rotate-left", "Pivoter à gauche", "rotate", "flip-x"))
                .child(tool_button("rotate", "Pivoter à droite", "rotate", ""))
                .child(tool_button("flip", "Miroir", "flip", "")),
        );
    }
    panel
        .child(p().class("panel-title").text("Format"))
        .child(div().class("chips").children(ASPECTS.iter().enumerate().map(|(i, (name, _))| {
            button()
                .attr("type", "button")
                .attr("data-action", "aspect")
                .attr("data-aspect", i.to_string())
                .class(if i == 0 { "chip active" } else { "chip" })
                .text(*name)
        })))
        .child(slider(&straighten, None))
}

fn tool_button(action: &str, label: &str, icon_name: &str, class: &str) -> Element {
    button()
        .attr("type", "button")
        .attr("data-action", action.to_owned())
        .attr("aria-label", label.to_owned())
        .attr("title", label.to_owned())
        .class(format!("tool {class}"))
        .child(icon(icon_name))
}

fn styles_panel(thumbnails: bool) -> Element {
    div()
        .class("panel")
        .attr("data-panel", "styles")
        .child(div().class("presets").children(PRESETS.iter().map(|preset| {
            let b = button()
                .attr("type", "button")
                .class("preset")
                .attr("data-action", "preset")
                .attr("data-preset", preset.id);
            let b = if thumbnails { b.child(canvas().attr("width", "160").attr("height", "107")) } else { b };
            b.child(span().text(preset.name))
        })))
        .child(p().class("hint").text("Un style garde votre exposition, votre balance des blancs et votre cadrage."))
}

fn side_panel(photo: bool) -> Element {
    let mut tab_list = vec![("styles", "Styles"), ("lumiere", "Lumière"), ("couleur", "Couleur"), ("courbe", "Courbe"), ("tsl", "TSL")];
    tab_list.extend([("etalonnage", "Étalonnage"), ("effets", "Effets"), ("cadrage", "Cadrage")]);
    aside()
        .class("lab-side")
        .attr("aria-label", "Réglages")
        .child(
            div()
                .class("hist-wrap")
                .attr("title", "Histogramme : rouge, vert, bleu. Les bords s'allument quand l'image est écrêtée.")
                .child(canvas().attr("id", "lab-hist").attr("width", "256").attr("height", "84"))
                .child(span().class("clip-dot lo").attr("title", "Noirs bouchés"))
                .child(span().class("clip-dot hi").attr("title", "Blancs brûlés"))
                .child(span().class("hist-dims mono").attr("id", "lab-dims")),
        )
        .child(tabs(&tab_list))
        .child(
            div()
                .class("panels")
                .child(styles_panel(photo))
                .child(group_panel(&LIGHT, true))
                .child(group_panel(&COLOR, true))
                .child(
                    group_panel(&CURVE, true)
                        .child(p().class("hint").text("Courbe paramétrique : chaque curseur agit sur une zone de tons.")),
                )
                .child(hsl_panel())
                .child(grading_panel())
                .child(effects_panel())
                .child(crop_panel(photo)),
        )
}

fn stage(extra: Option<Element>) -> Element {
    let mut stage = div()
        .class("lab-stage")
        .child(div().class("lab-canvas-wrap").child(canvas().attr("id", "lab-canvas").attr("aria-label", "Aperçu de l'image développée")))
        .child(div().class("lab-drop").child(icon("upload")).child(span().text("Déposez votre fichier ici")))
        .child(div().class("lab-busy").attr("id", "lab-busy").attr("hidden", "").child(span().class("spinner")).child(span().text("Chargement…")))
        .child(div().class("lab-message").attr("id", "lab-message").attr("role", "alert").attr("hidden", ""))
        .child(div().class("lab-toast").attr("id", "lab-toast").attr("role", "status").attr("hidden", ""))
        .child(div().class("lab-status mono").child(span().attr("id", "lab-info").text("Aucun fichier")));
    if let Some(extra) = extra {
        stage = stage.child(extra);
    }
    stage
}

pub fn photo_page(req: &Request) -> Page {
    let samples = [("lac", "Lac de montagne"), ("portrait", "Portrait"), ("ville", "Ville"), ("nuit", "Ciel étoilé"), ("foret", "Forêt")];
    let toolbar = div()
        .class("lab-toolbar")
        .child(
            div()
                .class("tool-group")
                .child(button().attr("type", "button").attr("data-action", "open").class("btn btn-small").child(icon("upload")).child(span().text("Ouvrir une photo")))
                .child(input().attr("type", "file").attr("id", "lab-file").attr("accept", "image/*").attr("hidden", ""))
                .child(input().attr("type", "file").attr("id", "lab-recipe-file").attr("accept", "application/json,.json").attr("hidden", ""))
                .child(div().class("samples").attr("aria-label", "Exemples").children(samples.iter().map(|(file, name)| {
                    button()
                        .attr("type", "button")
                        .class("sample")
                        .attr("data-sample", format!("/media/{file}.jpg"))
                        .attr("title", format!("Exemple : {name}"))
                        .attr("aria-label", format!("Exemple : {name}"))
                        .child(img().attr("src", format!("/media/{file}-mini.jpg")).attr("alt", ""))
                }))),
        )
        .child(
            div()
                .class("tool-group")
                .child(tool_button("undo", "Annuler (⌘Z)", "undo", "").attr("disabled", ""))
                .child(tool_button("redo", "Rétablir (⇧⌘Z)", "redo", "").attr("disabled", ""))
                .child(tool_button("reset", "Tout réinitialiser", "reset", ""))
                .child(tool_button("before", "Maintenir pour voir l'original (touche B)", "compare", ""))
                .child(tool_button("clip", "Alerte d'écrêtage", "warning", "")),
        )
        .child(
            div()
                .class("tool-group")
                .child(tool_button("recipe-load", "Charger une recette (.json)", "file", ""))
                .child(tool_button("recipe-save", "Enregistrer la recette (.json)", "download", ""))
                .child(button().attr("type", "button").attr("data-action", "export").class("btn btn-small").child(icon("download")).child(span().text("Exporter"))),
        );

    let dialog = dialog()
        .attr("id", "lab-export")
        .class("dialog")
        .child(h2().text("Exporter la photo"))
        .child(p().class("muted").text("Rendu en pleine résolution depuis l'original, sur votre appareil."))
        .child(
            label().text("Format").child(
                select()
                    .attr("id", "export-format")
                    .child(option().attr("value", "image/jpeg").text("JPEG"))
                    .child(option().attr("value", "image/png").text("PNG (sans perte)"))
                    .child(option().attr("value", "image/webp").text("WebP")),
            ),
        )
        .child(
            label()
                .child(span().class("row-between").child(span().text("Qualité")).child(span().class("mono").attr("id", "export-quality-value").text("92 %")))
                .child(input().attr("type", "range").attr("id", "export-quality").attr("min", "60").attr("max", "100").attr("value", "92")),
        )
        .child(
            label().text("Taille").child(
                select()
                    .attr("id", "export-size")
                    .child(option().attr("value", "0").text("Originale (jusqu'à 16 Mpx)"))
                    .child(option().attr("value", "4096").text("4096 px (grand côté)"))
                    .child(option().attr("value", "2048").text("2048 px (web)"))
                    .child(option().attr("value", "1080").text("1080 px (réseaux sociaux)")),
            ),
        )
        .child(p().class("export-status").attr("id", "export-status").attr("role", "status"))
        .child(
            div()
                .class("dialog-actions")
                .child(button().attr("type", "button").class("btn btn-ghost").attr("data-action", "close-export").text("Fermer"))
                .child(button().attr("type", "button").class("btn").attr("id", "export-go").text("Exporter")),
        );

    let content = html::main()
        .class("lab")
        .attr("data-lab", "photo")
        .child(island("boot", "", boot))
        .child(h1().class("sr-only").text("Laboratoire photo Apertis"))
        .child(toolbar)
        .child(div().class("lab-body").child(stage(None)).child(side_panel(true)))
        .child(dialog)
        .child(client_note());
    page(
        req,
        Meta {
            title: "Labo photo en ligne — Apertis",
            description: "Développez vos photos dans le navigateur : lumière, couleur, courbe, TSL, étalonnage, grain, recadrage, histogramme et export en pleine résolution. Gratuit, sans compte, 100 % local.",
            path: "/labo",
            app: true,
        },
        content,
    )
}

pub fn video_page(req: &Request) -> Page {
    let toolbar = div()
        .class("lab-toolbar")
        .child(
            div()
                .class("tool-group")
                .child(button().attr("type", "button").attr("data-action", "open").class("btn btn-small").child(icon("upload")).child(span().text("Ouvrir une vidéo")))
                .child(input().attr("type", "file").attr("id", "video-file").attr("accept", "video/*").attr("hidden", "")),
        )
        .child(
            div()
                .class("tool-group")
                .child(tool_button("reset", "Tout réinitialiser", "reset", ""))
                .child(tool_button("before", "Maintenir pour voir l'original", "compare", ""))
                .child(tool_button("clip", "Alerte d'écrêtage", "warning", ""))
                .child(tool_button("mute", "Couper le son", "volume", "")),
        )
        .child(
            div()
                .class("tool-group")
                .child(button().attr("type", "button").attr("data-action", "export").class("btn btn-small").child(icon("download")).child(span().text("Exporter"))),
        );

    let transport = div()
        .class("transport")
        .child(
            div()
                .class("transport-row")
                .child(button().attr("type", "button").class("tool").attr("data-action", "step-back").attr("aria-label", "Image précédente").text("‹"))
                .child(button().attr("type", "button").class("tool play").attr("id", "video-play").attr("data-action", "play").attr("aria-label", "Lecture").text("▶"))
                .child(button().attr("type", "button").class("tool").attr("data-action", "step-forward").attr("aria-label", "Image suivante").text("›"))
                .child(span().class("mono time").attr("id", "video-time").text("00:00.0"))
                .child(
                    div()
                        .class("scrub")
                        .child(div().class("scrub-range").attr("id", "video-range-bar"))
                        .child(input().attr("type", "range").attr("id", "video-scrub").attr("min", "0").attr("max", "1").attr("step", "0.01").attr("value", "0").attr("aria-label", "Position")),
                ),
        )
        .child(
            div()
                .class("transport-row")
                .child(button().attr("type", "button").class("chip").attr("data-action", "mark-in").text("[ Entrée"))
                .child(button().attr("type", "button").class("chip").attr("data-action", "mark-out").text("Sortie ]"))
                .child(button().attr("type", "button").class("chip").attr("data-action", "clear-range").text("Tout"))
                .child(span().class("mono muted range-text").attr("id", "video-range")),
        );

    let video_el = video()
        .attr("id", "video-el")
        .class("source-video")
        .attr("playsinline", "")
        .attr("preload", "auto")
        .attr("data-sample", "/media/demo.mp4");

    let dialog = dialog()
        .attr("id", "lab-export")
        .class("dialog")
        .child(h2().text("Exporter la vidéo"))
        .child(p().class("muted").text("La vidéo est relue et enregistrée en temps réel entre l'entrée et la sortie, avec le son, sur votre appareil."))
        .child(label().text("Format").child(select().attr("id", "export-format")))
        .child(
            label().text("Définition").child(
                select()
                    .attr("id", "export-size")
                    .child(option().attr("value", "1920").text("1080p (Full HD)"))
                    .child(option().attr("value", "1280").text("720p"))
                    .child(option().attr("value", "3840").text("4K (si la source le permet)")),
            ),
        )
        .child(
            label().text("Qualité").child(
                select()
                    .attr("id", "export-bitrate")
                    .child(option().attr("value", "12000000").text("Haute (12 Mb/s)"))
                    .child(option().attr("value", "25000000").text("Très haute (25 Mb/s)"))
                    .child(option().attr("value", "6000000").text("Web (6 Mb/s)")),
            ),
        )
        .child(div().class("progress").child(div().class("progress-bar").attr("id", "export-progress-bar")))
        .child(p().class("export-status").attr("id", "export-status").attr("role", "status"))
        .child(
            div()
                .class("dialog-actions")
                .child(button().attr("type", "button").class("btn btn-ghost").attr("data-action", "close-export").text("Fermer"))
                .child(button().attr("type", "button").class("btn").attr("id", "export-go").text("Enregistrer")),
        );

    let content = html::main()
        .class("lab")
        .attr("data-lab", "video")
        .child(island("boot", "", boot))
        .child(h1().class("sr-only").text("Laboratoire vidéo Apertis"))
        .child(toolbar)
        .child(
            div()
                .class("lab-body")
                .child(div().class("lab-main").child(stage(Some(video_el))).child(transport))
                .child(side_panel(false)),
        )
        .child(dialog)
        .child(client_note());
    page(
        req,
        Meta {
            title: "Labo vidéo en ligne — Apertis",
            description: "Étalonnez vos vidéos dans le navigateur, en direct pendant la lecture : lumière, couleur, TSL, étalonnage, grain, recadrage, entrée et sortie, export avec le son. 100 % local.",
            path: "/labo/video",
            app: true,
        },
        content,
    )
}
