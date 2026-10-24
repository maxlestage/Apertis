//! Le moteur de développement du laboratoire, partagé par le serveur (interface,
//! tests) et le navigateur (rendu WebGL2).
//!
//! Le pipeline reprend celui de l'application iOS :
//! 1. **linéaire** (shader) : balance des blancs et exposition en lumière linéaire ;
//! 2. **tonalité et couleur** (cette fonction, [`develop`]) : points noir/blanc, contraste,
//!    hautes lumières, ombres, courbe paramétrique, TSL, vibrance, saturation, étalonnage,
//!    fondu. Fonction pure, cuite dans une LUT 3D ([`bake_lut`]) que le GPU interpole ;
//! 3. **effets** (shader) : netteté, vignette, grain ;
//! 4. **géométrie** : rotation, miroir, recadrage, redressement ([`geometry`]).

/// Unité affichée à côté d'une valeur.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Unit {
    None,
    Ev,
    Degrees,
}

/// Un curseur du laboratoire.
#[derive(Clone, Copy, Debug)]
pub struct Control {
    pub key: &'static str,
    pub label: &'static str,
    pub min: f32,
    pub max: f32,
    pub step: f32,
    pub unit: Unit,
}

const fn c(key: &'static str, label: &'static str) -> Control {
    Control { key, label, min: -100.0, max: 100.0, step: 1.0, unit: Unit::None }
}

const fn pos(key: &'static str, label: &'static str) -> Control {
    Control { key, label, min: 0.0, max: 100.0, step: 1.0, unit: Unit::None }
}

/// Un panneau de réglages.
#[derive(Clone, Copy, Debug)]
pub struct Group {
    pub id: &'static str,
    pub label: &'static str,
    pub controls: &'static [Control],
}

pub const LIGHT: Group = Group {
    id: "lumiere",
    label: "Lumière",
    controls: &[
        Control { key: "exposure", label: "Exposition", min: -4.0, max: 4.0, step: 0.05, unit: Unit::Ev },
        c("contrast", "Contraste"),
        c("highlights", "Hautes lumières"),
        c("shadows", "Ombres"),
        c("whites", "Blancs"),
        c("blacks", "Noirs"),
    ],
};

pub const COLOR: Group = Group {
    id: "couleur",
    label: "Couleur",
    controls: &[
        c("temperature", "Température"),
        c("tint", "Teinte"),
        c("vibrance", "Vibrance"),
        c("saturation", "Saturation"),
    ],
};

pub const CURVE: Group = Group {
    id: "courbe",
    label: "Courbe",
    controls: &[
        c("curve0", "Ombres profondes"),
        c("curve1", "Tons sombres"),
        c("curve2", "Tons clairs"),
        c("curve3", "Hautes lumières"),
    ],
};

pub const EFFECTS: Group = Group {
    id: "effets",
    label: "Effets",
    controls: &[
        pos("fade", "Fondu"),
        pos("grain", "Grain"),
        Control { key: "grain_size", label: "Taille du grain", min: 1.0, max: 4.0, step: 0.1, unit: Unit::None },
        c("vignette", "Vignette"),
        pos("sharpen", "Netteté"),
    ],
};

/// Les huit plages de teintes du réglage TSL : nom, teinte centrale (degrés).
pub const HSL_BANDS: [(&str, f32); 8] = [
    ("Rouges", 0.0),
    ("Oranges", 30.0),
    ("Jaunes", 60.0),
    ("Verts", 120.0),
    ("Cyans", 180.0),
    ("Bleus", 240.0),
    ("Violets", 270.0),
    ("Magentas", 300.0),
];

/// Les trois zones de l'étalonnage.
pub const GRADE_ZONES: [&str; 3] = ["Ombres", "Tons moyens", "Hautes lumières"];

/// Les rapports de recadrage proposés : libellé, largeur / hauteur (0 = original).
pub const ASPECTS: [(&str, f32); 7] = [
    ("Original", 0.0),
    ("1:1", 1.0),
    ("4:5", 0.8),
    ("3:2", 1.5),
    ("4:3", 4.0 / 3.0),
    ("16:9", 16.0 / 9.0),
    ("9:16", 9.0 / 16.0),
];

/// Tous les réglages d'une image. Les curseurs vont de -100 à 100 (0 = neutre), sauf
/// l'exposition (IL), le redressement (degrés) et les effets (0 à 100).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Settings {
    pub exposure: f32,
    pub contrast: f32,
    pub highlights: f32,
    pub shadows: f32,
    pub whites: f32,
    pub blacks: f32,
    pub temperature: f32,
    pub tint: f32,
    pub vibrance: f32,
    pub saturation: f32,
    pub curve: [f32; 4],
    pub hsl_h: [f32; 8],
    pub hsl_s: [f32; 8],
    pub hsl_l: [f32; 8],
    pub grade_h: [f32; 3],
    pub grade_s: [f32; 3],
    pub fade: f32,
    pub grain: f32,
    pub grain_size: f32,
    pub vignette: f32,
    pub sharpen: f32,
    pub straighten: f32,
    /// Quarts de tour dans le sens horaire (0 à 3).
    pub rotate: u8,
    pub flip: bool,
    /// Index dans [`ASPECTS`].
    pub aspect: u8,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            exposure: 0.0,
            contrast: 0.0,
            highlights: 0.0,
            shadows: 0.0,
            whites: 0.0,
            blacks: 0.0,
            temperature: 0.0,
            tint: 0.0,
            vibrance: 0.0,
            saturation: 0.0,
            curve: [0.0; 4],
            hsl_h: [0.0; 8],
            hsl_s: [0.0; 8],
            hsl_l: [0.0; 8],
            grade_h: [210.0, 0.0, 40.0],
            grade_s: [0.0; 3],
            fade: 0.0,
            grain: 0.0,
            grain_size: 1.5,
            vignette: 0.0,
            sharpen: 0.0,
            straighten: 0.0,
            rotate: 0,
            flip: false,
            aspect: 0,
        }
    }
}

/// Indice d'un tableau dans une clé comme `hsl_h3` ou `curve0`.
fn indexed(key: &str, prefix: &str) -> Option<usize> {
    key.strip_prefix(prefix)?.parse().ok()
}

impl Settings {
    /// La valeur d'un réglage par sa clé (`exposure`, `hsl_s4`, `grade_h0`…).
    pub fn get(&self, key: &str) -> Option<f32> {
        Some(match key {
            "exposure" => self.exposure,
            "contrast" => self.contrast,
            "highlights" => self.highlights,
            "shadows" => self.shadows,
            "whites" => self.whites,
            "blacks" => self.blacks,
            "temperature" => self.temperature,
            "tint" => self.tint,
            "vibrance" => self.vibrance,
            "saturation" => self.saturation,
            "fade" => self.fade,
            "grain" => self.grain,
            "grain_size" => self.grain_size,
            "vignette" => self.vignette,
            "sharpen" => self.sharpen,
            "straighten" => self.straighten,
            "rotate" => f32::from(self.rotate),
            "flip" => f32::from(u8::from(self.flip)),
            "aspect" => f32::from(self.aspect),
            k => {
                if let Some(i) = indexed(k, "curve") {
                    *self.curve.get(i)?
                } else if let Some(i) = indexed(k, "hsl_h") {
                    *self.hsl_h.get(i)?
                } else if let Some(i) = indexed(k, "hsl_s") {
                    *self.hsl_s.get(i)?
                } else if let Some(i) = indexed(k, "hsl_l") {
                    *self.hsl_l.get(i)?
                } else if let Some(i) = indexed(k, "grade_h") {
                    *self.grade_h.get(i)?
                } else if let Some(i) = indexed(k, "grade_s") {
                    *self.grade_s.get(i)?
                } else {
                    return None;
                }
            }
        })
    }

    /// Modifie un réglage ; la valeur est bornée à sa plage. Renvoie `false` si la clé
    /// est inconnue.
    pub fn set(&mut self, key: &str, value: f32) -> bool {
        if !value.is_finite() {
            return false;
        }
        let v = |lo: f32, hi: f32| value.clamp(lo, hi);
        match key {
            "exposure" => self.exposure = v(-4.0, 4.0),
            "contrast" => self.contrast = v(-100.0, 100.0),
            "highlights" => self.highlights = v(-100.0, 100.0),
            "shadows" => self.shadows = v(-100.0, 100.0),
            "whites" => self.whites = v(-100.0, 100.0),
            "blacks" => self.blacks = v(-100.0, 100.0),
            "temperature" => self.temperature = v(-100.0, 100.0),
            "tint" => self.tint = v(-100.0, 100.0),
            "vibrance" => self.vibrance = v(-100.0, 100.0),
            "saturation" => self.saturation = v(-100.0, 100.0),
            "fade" => self.fade = v(0.0, 100.0),
            "grain" => self.grain = v(0.0, 100.0),
            "grain_size" => self.grain_size = v(1.0, 4.0),
            "vignette" => self.vignette = v(-100.0, 100.0),
            "sharpen" => self.sharpen = v(0.0, 100.0),
            "straighten" => self.straighten = v(-45.0, 45.0),
            "rotate" => self.rotate = (value.round() as i32).rem_euclid(4) as u8,
            "flip" => self.flip = value >= 0.5,
            "aspect" => self.aspect = (value.round().max(0.0) as usize).min(ASPECTS.len() - 1) as u8,
            k => {
                let slot = if let Some(i) = indexed(k, "curve") {
                    self.curve.get_mut(i).map(|s| (s, -100.0, 100.0))
                } else if let Some(i) = indexed(k, "hsl_h") {
                    self.hsl_h.get_mut(i).map(|s| (s, -100.0, 100.0))
                } else if let Some(i) = indexed(k, "hsl_s") {
                    self.hsl_s.get_mut(i).map(|s| (s, -100.0, 100.0))
                } else if let Some(i) = indexed(k, "hsl_l") {
                    self.hsl_l.get_mut(i).map(|s| (s, -100.0, 100.0))
                } else if let Some(i) = indexed(k, "grade_h") {
                    self.grade_h.get_mut(i).map(|s| (s, 0.0, 360.0))
                } else if let Some(i) = indexed(k, "grade_s") {
                    self.grade_s.get_mut(i).map(|s| (s, 0.0, 100.0))
                } else {
                    None
                };
                match slot {
                    Some((slot, lo, hi)) => *slot = v(lo, hi),
                    None => return false,
                }
            }
        }
        true
    }

    /// Toutes les clés, dans l'ordre d'une recette.
    pub fn keys() -> Vec<String> {
        let mut keys: Vec<String> = [
            "exposure", "contrast", "highlights", "shadows", "whites", "blacks", "temperature",
            "tint", "vibrance", "saturation",
        ]
        .iter()
        .map(|k| (*k).to_owned())
        .collect();
        keys.extend((0..4).map(|i| format!("curve{i}")));
        for prefix in ["hsl_h", "hsl_s", "hsl_l"] {
            keys.extend((0..8).map(|i| format!("{prefix}{i}")));
        }
        for prefix in ["grade_h", "grade_s"] {
            keys.extend((0..3).map(|i| format!("{prefix}{i}")));
        }
        keys.extend(
            ["fade", "grain", "grain_size", "vignette", "sharpen", "straighten", "rotate", "flip", "aspect"]
                .iter()
                .map(|k| (*k).to_owned()),
        );
        keys
    }

    /// La recette : les réglages en JSON (`{"exposure":0.5,…}`), lisible et partageable.
    pub fn to_json(&self) -> String {
        let fields: Vec<String> = Settings::keys()
            .into_iter()
            .map(|k| {
                let v = self.get(&k).unwrap_or(0.0);
                format!("\"{k}\":{}", fmt_number(v))
            })
            .collect();
        format!("{{\"format\":\"apertis-recette\",\"version\":1,{}}}", fields.join(","))
    }

    /// Lit une recette ; les clés inconnues sont ignorées, les absentes restent neutres.
    pub fn from_json(text: &str) -> Option<Settings> {
        let body = text.trim().strip_prefix('{')?.strip_suffix('}')?;
        let mut settings = Settings::default();
        let mut known = 0;
        for pair in body.split(',') {
            let (key, value) = pair.split_once(':')?;
            let key = key.trim().trim_matches('"');
            if let Ok(value) = value.trim().parse::<f32>() {
                if settings.set(key, value) {
                    known += 1;
                }
            }
        }
        (known > 0).then_some(settings)
    }

    /// Les réglages de tonalité et de couleur sont-ils tous neutres ?
    pub fn color_is_neutral(&self) -> bool {
        let n = Settings::default();
        self.contrast == 0.0
            && self.highlights == 0.0
            && self.shadows == 0.0
            && self.whites == 0.0
            && self.blacks == 0.0
            && self.vibrance == 0.0
            && self.saturation == 0.0
            && self.curve == n.curve
            && self.hsl_h == n.hsl_h
            && self.hsl_s == n.hsl_s
            && self.hsl_l == n.hsl_l
            && self.grade_s == n.grade_s
            && self.fade == 0.0
    }
}

fn fmt_number(v: f32) -> String {
    let s = format!("{v:.3}");
    let s = s.trim_end_matches('0').trim_end_matches('.');
    if s.is_empty() || s == "-" { "0".to_owned() } else { s.to_owned() }
}

// ---------------------------------------------------------------------------------
// Colorimétrie
// ---------------------------------------------------------------------------------

pub type Rgb = [f32; 3];

pub fn srgb_to_linear(v: f32) -> f32 {
    let a = v.abs();
    let l = if a <= 0.04045 { a / 12.92 } else { ((a + 0.055) / 1.055).powf(2.4) };
    l.copysign(v)
}

pub fn linear_to_srgb(v: f32) -> f32 {
    let a = v.abs();
    let e = if a <= 0.003_130_8 { a * 12.92 } else { 1.055 * a.powf(1.0 / 2.4) - 0.055 };
    e.copysign(v)
}

pub fn luma(c: Rgb) -> f32 {
    0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
}

pub fn smoothstep(e0: f32, e1: f32, x: f32) -> f32 {
    let t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

fn clamp01(c: Rgb) -> Rgb {
    [c[0].clamp(0.0, 1.0), c[1].clamp(0.0, 1.0), c[2].clamp(0.0, 1.0)]
}

/// RVB → (teinte en degrés, saturation, luminosité).
pub fn rgb_to_hsl(c: Rgb) -> (f32, f32, f32) {
    let max = c[0].max(c[1]).max(c[2]);
    let min = c[0].min(c[1]).min(c[2]);
    let l = (max + min) / 2.0;
    let d = max - min;
    if d < 1e-6 {
        return (0.0, 0.0, l);
    }
    let s = if l > 0.5 { d / (2.0 - max - min) } else { d / (max + min) };
    let h = if max == c[0] {
        (c[1] - c[2]) / d + if c[1] < c[2] { 6.0 } else { 0.0 }
    } else if max == c[1] {
        (c[2] - c[0]) / d + 2.0
    } else {
        (c[0] - c[1]) / d + 4.0
    };
    (h * 60.0, s, l)
}

pub fn hsl_to_rgb(h: f32, s: f32, l: f32) -> Rgb {
    if s < 1e-6 {
        return [l, l, l];
    }
    let h = h.rem_euclid(360.0) / 360.0;
    let q = if l < 0.5 { l * (1.0 + s) } else { l + s - l * s };
    let p = 2.0 * l - q;
    let f = |t: f32| {
        let t = t.rem_euclid(1.0);
        if t < 1.0 / 6.0 {
            p + (q - p) * 6.0 * t
        } else if t < 0.5 {
            q
        } else if t < 2.0 / 3.0 {
            p + (q - p) * (2.0 / 3.0 - t) * 6.0
        } else {
            p
        }
    };
    [f(h + 1.0 / 3.0), f(h), f(h - 1.0 / 3.0)]
}

/// Gains de balance des blancs en lumière linéaire, luminance conservée.
pub fn white_balance(temperature: f32, tint: f32) -> Rgb {
    let t = temperature.clamp(-100.0, 100.0) / 100.0;
    let ti = tint.clamp(-100.0, 100.0) / 100.0;
    let g = [(0.35 * t).exp2(), (-0.25 * ti).exp2(), (-0.35 * t).exp2()];
    let l = luma(g);
    [g[0] / l, g[1] / l, g[2] / l]
}

/// Étape linéaire (référence CPU du shader) : sRGB encodé → sRGB encodé, avant la LUT.
pub fn linear_stage(s: &Settings, c: Rgb) -> Rgb {
    let wb = white_balance(s.temperature, s.tint);
    let gain = s.exposure.exp2();
    let mut out = [0.0; 3];
    for i in 0..3 {
        out[i] = linear_to_srgb(srgb_to_linear(c[i]) * wb[i] * gain).clamp(0.0, 1.0);
    }
    out
}

/// Courbe de tonalité appliquée à une valeur [0, 1] (monotone pour toute valeur des curseurs).
fn tone(s: &Settings, x: f32) -> f32 {
    // Points noir et blanc.
    let black = -s.blacks / 100.0 * 0.08;
    let white = 1.0 - s.whites / 100.0 * 0.12;
    let mut x = ((x - black) / (white - black)).clamp(0.0, 1.0);
    // Contraste en S autour du gris moyen : 0 → 0, 1 → 1.
    if s.contrast != 0.0 {
        let k = (s.contrast / 100.0 * 1.2).exp2();
        let pivot = 0.46_f32;
        x = if x < pivot {
            pivot * (x / pivot).powf(k)
        } else {
            1.0 - (1.0 - pivot) * ((1.0 - x) / (1.0 - pivot)).powf(k)
        };
    }
    // Hautes lumières et ombres.
    if s.highlights != 0.0 {
        x += s.highlights / 100.0 * 0.3 * smoothstep(0.5, 1.0, x) * if s.highlights < 0.0 { 1.0 } else { 1.0 - x * 0.5 };
    }
    if s.shadows != 0.0 {
        let w = x * (1.0 - x) * (1.0 - x) * 6.75 * (1.0 - smoothstep(0.6, 1.0, x));
        x += s.shadows / 100.0 * 0.14 * w;
    }
    x.clamp(0.0, 1.0)
}

/// Courbe paramétrique : quatre zones (ombres profondes, tons sombres, tons clairs,
/// hautes lumières) en cloches de cosinus.
fn parametric(s: &Settings, x: f32) -> f32 {
    const CENTERS: [f32; 4] = [0.12, 0.37, 0.63, 0.88];
    let mut y = x;
    for (i, center) in CENTERS.iter().enumerate() {
        let a = s.curve[i] / 100.0;
        if a != 0.0 {
            let d = ((x - center) / 0.25).clamp(-1.0, 1.0);
            let bump = 0.5 * (1.0 + (d * std::f32::consts::PI).cos());
            y += a * 0.1 * bump;
        }
    }
    y.clamp(0.0, 1.0)
}

fn apply_hsl(s: &Settings, c: Rgb) -> Rgb {
    let (mut h, mut sat, mut l) = rgb_to_hsl(c);
    if sat < 1e-5 {
        return c;
    }
    let n = HSL_BANDS.len();
    let mut lower = n - 1;
    for (i, (_, center)) in HSL_BANDS.iter().enumerate() {
        if *center <= h {
            lower = i;
        }
    }
    let upper = (lower + 1) % n;
    let lo = HSL_BANDS[lower].1;
    let mut hi = HSL_BANDS[upper].1;
    if hi <= lo {
        hi += 360.0;
    }
    let hh = if h < lo { h + 360.0 } else { h };
    let f = smoothstep(0.0, 1.0, (hh - lo) / (hi - lo));
    let mix = |a: &[f32; 8]| a[lower] * (1.0 - f) + a[upper] * f;
    let dh = mix(&s.hsl_h);
    let ds = mix(&s.hsl_s);
    let dl = mix(&s.hsl_l);
    h += dh / 100.0 * 30.0;
    let s0 = sat;
    sat = (sat * (1.0 + ds / 100.0)).clamp(0.0, 1.0);
    l = (l + dl / 100.0 * 0.25 * s0).clamp(0.0, 1.0);
    hsl_to_rgb(h, sat, l)
}

/// Étape tonalité et couleur, en sRGB encodé : c'est elle que la LUT 3D contient.
pub fn develop(s: &Settings, input: Rgb) -> Rgb {
    let mut c = clamp01(input);
    // Tonalité sur la luminance, teinte conservée.
    let l = luma(c);
    let tl = parametric(s, tone(s, l));
    if l > 1e-5 {
        let k = tl / l;
        c = [c[0] * k, c[1] * k, c[2] * k];
        // Les couleurs qui dépasseraient le blanc se rapprochent du blanc au lieu d'écrêter.
        let m = c[0].max(c[1]).max(c[2]);
        if m > 1.0 {
            let t = ((m - 1.0) / m).min(1.0);
            c = [c[0] / m + t * (1.0 - c[0] / m), c[1] / m + t * (1.0 - c[1] / m), c[2] / m + t * (1.0 - c[2] / m)];
            let l2 = luma(c);
            if l2 > 1e-5 {
                let k2 = (tl / l2).min(1.0 / c[0].max(c[1]).max(c[2]).max(1e-5));
                c = [c[0] * k2, c[1] * k2, c[2] * k2];
            }
        }
    } else {
        c = [tl, tl, tl];
    }
    c = clamp01(c);

    if s.hsl_h.iter().chain(&s.hsl_s).chain(&s.hsl_l).any(|v| *v != 0.0) {
        c = apply_hsl(s, c);
    }

    if s.vibrance != 0.0 || s.saturation != 0.0 {
        let l = luma(c);
        let chroma = c[0].max(c[1]).max(c[2]) - c[0].min(c[1]).min(c[2]);
        let factor = (1.0 + s.vibrance / 100.0 * (1.0 - chroma)) * (1.0 + s.saturation / 100.0);
        c = clamp01([l + (c[0] - l) * factor, l + (c[1] - l) * factor, l + (c[2] - l) * factor]);
    }

    if s.grade_s.iter().any(|v| *v > 0.0) {
        let l = luma(c).clamp(0.0, 1.0);
        let weights = [(1.0 - l) * (1.0 - l), 2.0 * l * (1.0 - l), l * l];
        for zone in 0..3 {
            let amount = s.grade_s[zone] / 100.0;
            if amount > 0.0 {
                let tint = hsl_to_rgb(s.grade_h[zone], 1.0, 0.5);
                for i in 0..3 {
                    c[i] += (tint[i] - 0.5) * amount * 0.22 * weights[zone];
                }
            }
        }
        c = clamp01(c);
    }

    if s.fade > 0.0 {
        let f = s.fade / 100.0 * 0.14;
        c = [f + c[0] * (1.0 - f), f + c[1] * (1.0 - f * 0.6), f + c[2] * (1.0 - f * 0.3)];
    }
    clamp01(c)
}

/// LUT 3D RGBA 8 bits (rouge le plus rapide), `size`³ entrées, pour une texture WebGL2.
pub fn bake_lut(s: &Settings, size: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(size * size * size * 4);
    let scale = 1.0 / (size - 1) as f32;
    for b in 0..size {
        for g in 0..size {
            for r in 0..size {
                let c = develop(s, [r as f32 * scale, g as f32 * scale, b as f32 * scale]);
                for v in c {
                    out.push((v * 255.0).round() as u8);
                }
                out.push(255);
            }
        }
    }
    out
}

// ---------------------------------------------------------------------------------
// Géométrie
// ---------------------------------------------------------------------------------

/// Cadrage final : taille de sortie et transformation des coordonnées de sortie
/// (u, v ∈ [0, 1], origine en haut à gauche) vers les coordonnées de la source.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Geometry {
    pub width: u32,
    pub height: u32,
    /// Matrice 3×3 en colonnes (format GLSL `mat3`) : source = M · (u, v, 1).
    pub matrix: [f32; 9],
}

impl Geometry {
    pub fn map(&self, u: f32, v: f32) -> (f32, f32) {
        let m = &self.matrix;
        (m[0] * u + m[3] * v + m[6], m[1] * u + m[4] * v + m[7])
    }
}

/// Calcule le cadrage d'une image source de `w × h` pixels.
pub fn geometry(s: &Settings, w: u32, h: u32) -> Geometry {
    let quarter = s.rotate % 4;
    // Dimensions après rotation par quarts de tour.
    let (rw, rh) = if quarter % 2 == 1 { (h as f32, w as f32) } else { (w as f32, h as f32) };
    // Recadrage centré au rapport demandé.
    let ratio = ASPECTS[usize::from(s.aspect).min(ASPECTS.len() - 1)].1;
    let (mut cw, mut ch) = (rw, rh);
    if ratio > 0.0 {
        if rw / rh > ratio {
            cw = rh * ratio;
        } else {
            ch = rw / ratio;
        }
    }
    // Redressement : le cadre tourné doit rester dans l'image, on réduit le cadre.
    let theta = s.straighten.to_radians();
    let (sin, cos) = (theta.sin().abs(), theta.cos().abs());
    let need = ((cos * cw + sin * ch) / rw).max((sin * cw + cos * ch) / rh);
    let k = if need > 1.0 { 1.0 / need } else { 1.0 };
    let (cw, ch) = (cw * k, ch * k);

    // Sortie (u, v) → pixels centrés dans l'image tournée.
    // x = (u - 0.5)·cw, y = (v - 0.5)·ch, puis rotation de θ.
    let (st, ct) = (theta.sin(), theta.cos());
    // Coordonnées normalisées dans l'image tournée : (x·cos − y·sin)/rw + 0.5, …
    let a = [ct * cw / rw, st * cw / rh];
    let b = [-st * ch / rw, ct * ch / rh];
    let o = [0.5 - 0.5 * (a[0] + b[0]), 0.5 - 0.5 * (a[1] + b[1])];
    // Image tournée (p, q) → source (su, sv), selon le quart de tour et le miroir.
    // Rotation horaire de 90° : le point (p, q) de l'image tournée vient de (q, 1 − p).
    let (rot, rot_o): ([[f32; 2]; 2], [f32; 2]) = match quarter {
        0 => ([[1.0, 0.0], [0.0, 1.0]], [0.0, 0.0]),
        1 => ([[0.0, -1.0], [1.0, 0.0]], [0.0, 1.0]),
        2 => ([[-1.0, 0.0], [0.0, -1.0]], [1.0, 1.0]),
        _ => ([[0.0, 1.0], [-1.0, 0.0]], [1.0, 0.0]),
    };
    // rot[i] = colonne i : source = rot[0]·p + rot[1]·q + rot_o
    let compose = |vec: [f32; 2]| [rot[0][0] * vec[0] + rot[1][0] * vec[1], rot[0][1] * vec[0] + rot[1][1] * vec[1]];
    let mut ca = compose(a);
    let cb = compose(b);
    let co0 = compose(o);
    let mut co = [co0[0] + rot_o[0], co0[1] + rot_o[1]];
    if s.flip {
        // Miroir horizontal de la sortie : u → 1 − u.
        co = [co[0] + ca[0], co[1] + ca[1]];
        ca = [-ca[0], -ca[1]];
    }
    Geometry {
        width: cw.round().max(1.0) as u32,
        height: ch.round().max(1.0) as u32,
        matrix: [ca[0], ca[1], 0.0, cb[0], cb[1], 0.0, co[0], co[1], 1.0],
    }
}

// ---------------------------------------------------------------------------------
// Styles
// ---------------------------------------------------------------------------------

pub struct Preset {
    pub id: &'static str,
    pub name: &'static str,
    pub apply: fn(&mut Settings),
}

/// Applique un style en conservant l'exposition, la balance des blancs, la géométrie
/// et la netteté propres à l'image.
pub fn apply_preset(base: &Settings, preset: &Preset) -> Settings {
    let mut s = Settings {
        exposure: base.exposure,
        temperature: base.temperature,
        tint: base.tint,
        sharpen: base.sharpen,
        straighten: base.straighten,
        rotate: base.rotate,
        flip: base.flip,
        aspect: base.aspect,
        ..Settings::default()
    };
    (preset.apply)(&mut s);
    s
}

pub const PRESETS: &[Preset] = &[
    Preset { id: "original", name: "Original", apply: |_| {} },
    Preset {
        id: "naturel",
        name: "Naturel",
        apply: |s| {
            s.contrast = 10.0;
            s.vibrance = 18.0;
            s.shadows = 12.0;
            s.highlights = -10.0;
        },
    },
    Preset {
        id: "portra",
        name: "Portra",
        apply: |s| {
            s.contrast = -18.0;
            s.saturation = -15.0;
            s.fade = 35.0;
            s.grain = 18.0;
            s.highlights = -25.0;
            s.shadows = 15.0;
            s.hsl_l[1] = 15.0;
            s.hsl_s[1] = -10.0;
            s.hsl_h[3] = -20.0;
            s.grade_h = [190.0, 30.0, 40.0];
            s.grade_s = [18.0, 10.0, 35.0];
        },
    },
    Preset {
        id: "kodachrome",
        name: "Kodachrome",
        apply: |s| {
            s.contrast = 38.0;
            s.saturation = 22.0;
            s.vibrance = 15.0;
            s.blacks = -20.0;
            s.hsl_h[5] = -12.0;
            s.hsl_s[0] = 12.0;
            s.grade_h = [220.0, 0.0, 40.0];
            s.grade_s = [10.0, 0.0, 14.0];
            s.grain = 10.0;
        },
    },
    Preset {
        id: "cinema",
        name: "Cinéma",
        apply: |s| {
            s.contrast = 18.0;
            s.saturation = -10.0;
            s.highlights = -20.0;
            s.grade_h = [190.0, 0.0, 35.0];
            s.grade_s = [35.0, 0.0, 30.0];
            s.hsl_s[1] = 10.0;
            s.hsl_h[5] = -15.0;
            s.vignette = 22.0;
        },
    },
    Preset {
        id: "nordique",
        name: "Nordique",
        apply: |s| {
            s.contrast = -10.0;
            s.saturation = -45.0;
            s.fade = 22.0;
            s.whites = 15.0;
            s.grade_h = [210.0, 200.0, 190.0];
            s.grade_s = [25.0, 15.0, 10.0];
        },
    },
    Preset {
        id: "dore",
        name: "Heure dorée",
        apply: |s| {
            s.contrast = 12.0;
            s.vibrance = 30.0;
            s.shadows = 20.0;
            s.grade_h = [20.0, 35.0, 45.0];
            s.grade_s = [20.0, 25.0, 45.0];
            s.hsl_l[2] = 10.0;
        },
    },
    Preset {
        id: "nb",
        name: "Noir et blanc",
        apply: |s| {
            s.saturation = -100.0;
            s.contrast = 30.0;
            s.grain = 22.0;
            s.curve = [-20.0, -5.0, 10.0, 15.0];
        },
    },
    Preset {
        id: "nb-doux",
        name: "N&B doux",
        apply: |s| {
            s.saturation = -100.0;
            s.contrast = -15.0;
            s.fade = 30.0;
            s.grain = 30.0;
            s.grade_h = [30.0, 0.0, 40.0];
            s.grade_s = [8.0, 0.0, 8.0];
        },
    },
];

#[cfg(test)]
mod tests {
    use super::*;

    fn close(a: Rgb, b: Rgb, eps: f32) -> bool {
        (0..3).all(|i| (a[i] - b[i]).abs() <= eps)
    }

    #[test]
    fn neutral_settings_change_nothing() {
        let s = Settings::default();
        assert!(s.color_is_neutral());
        for c in [[0.0, 0.0, 0.0], [1.0, 1.0, 1.0], [0.8, 0.2, 0.1], [0.1, 0.5, 0.9], [0.46, 0.46, 0.46]] {
            assert!(close(develop(&s, c), c, 1e-4), "{c:?} → {:?}", develop(&s, c));
            assert!(close(linear_stage(&s, c), c, 1e-4));
        }
    }

    #[test]
    fn tone_curve_is_monotonic_for_extreme_settings() {
        for v in [-100.0, -50.0, 50.0, 100.0] {
            let s = Settings { contrast: v, highlights: v, shadows: v, whites: v, blacks: v, curve: [v; 4], ..Settings::default() };
            let mut previous = -1.0;
            for i in 0..=200 {
                let y = parametric(&s, tone(&s, i as f32 / 200.0));
                assert!(y >= previous - 1e-4, "v={v} i={i} y={y} prev={previous}");
                previous = y;
            }
        }
    }

    #[test]
    fn exposure_doubles_linear_light() {
        let s = Settings { exposure: 1.0, ..Settings::default() };
        let out = linear_stage(&s, [0.4, 0.4, 0.4]);
        assert!((srgb_to_linear(out[0]) - 2.0 * srgb_to_linear(0.4)).abs() < 1e-4);
    }

    #[test]
    fn warm_white_balance_keeps_luminance() {
        let g = white_balance(60.0, 0.0);
        assert!(g[0] > g[2]);
        assert!((luma(g) - 1.0).abs() < 1e-5);
    }

    #[test]
    fn black_and_white_is_grey() {
        let s = Settings { saturation: -100.0, ..Settings::default() };
        let c = develop(&s, [0.8, 0.2, 0.1]);
        assert!((c[0] - c[1]).abs() < 1e-4 && (c[1] - c[2]).abs() < 1e-4);
    }

    #[test]
    fn hsl_targets_its_band_only() {
        let mut s = Settings::default();
        s.hsl_s[5] = -100.0; // bleus
        let blue = develop(&s, [0.1, 0.2, 0.9]);
        assert!((blue[0] - blue[2]).abs() < 0.05);
        let red = [0.9, 0.2, 0.1];
        assert!(close(develop(&s, red), red, 1e-3));
        // Les gris ne bougent jamais.
        s.hsl_l = [80.0; 8];
        assert!(close(develop(&s, [0.5, 0.5, 0.5]), [0.5, 0.5, 0.5], 1e-4));
    }

    #[test]
    fn contrast_spreads_tones_around_middle_grey() {
        let s = Settings { contrast: 60.0, ..Settings::default() };
        assert!(develop(&s, [0.2; 3])[0] < 0.2);
        assert!(develop(&s, [0.75; 3])[0] > 0.75);
        assert!((develop(&s, [0.46; 3])[0] - 0.46).abs() < 1e-3);
    }

    #[test]
    fn lut_has_the_expected_layout() {
        let lut = bake_lut(&Settings::default(), 3);
        assert_eq!(lut.len(), 27 * 4);
        // (r=1, g=0, b=0) : deuxième entrée, rouge le plus rapide.
        assert_eq!(&lut[4..8], &[128, 0, 0, 255]);
        assert_eq!(&lut[26 * 4..], &[255, 255, 255, 255]);
    }

    #[test]
    fn recipe_round_trip() {
        let mut s = Settings::default();
        s.set("exposure", 0.75);
        s.set("hsl_s3", -40.0);
        s.set("grade_h2", 35.0);
        s.set("rotate", 3.0);
        s.set("flip", 1.0);
        s.set("aspect", 2.0);
        let json = s.to_json();
        assert!(json.starts_with("{\"format\":\"apertis-recette\""));
        assert_eq!(Settings::from_json(&json), Some(s));
        assert_eq!(Settings::from_json("pas du json"), None);
    }

    #[test]
    fn set_clamps_and_rejects_unknown_keys() {
        let mut s = Settings::default();
        assert!(s.set("contrast", 500.0));
        assert_eq!(s.contrast, 100.0);
        assert!(s.set("rotate", -1.0));
        assert_eq!(s.rotate, 3);
        assert!(!s.set("inconnu", 1.0));
        assert!(!s.set("hsl_h9", 1.0));
        assert!(!s.set("exposure", f32::NAN));
    }

    #[test]
    fn every_control_key_is_a_setting() {
        for group in [LIGHT, COLOR, CURVE, EFFECTS] {
            for control in group.controls {
                assert!(Settings::default().get(control.key).is_some(), "{}", control.key);
            }
        }
        for key in Settings::keys() {
            assert!(Settings::default().get(&key).is_some(), "{key}");
        }
    }

    #[test]
    fn identity_geometry() {
        let g = geometry(&Settings::default(), 4000, 3000);
        assert_eq!((g.width, g.height), (4000, 3000));
        let (u, v) = g.map(0.25, 0.75);
        assert!((u - 0.25).abs() < 1e-5 && (v - 0.75).abs() < 1e-5);
    }

    #[test]
    fn quarter_turns_and_flip() {
        // Rotation horaire : le coin haut-gauche de la sortie vient du bas-gauche de la source.
        let s = Settings { rotate: 1, ..Settings::default() };
        let g = geometry(&s, 4000, 3000);
        assert_eq!((g.width, g.height), (3000, 4000));
        let (u, v) = g.map(0.0, 0.0);
        assert!((u - 0.0).abs() < 1e-5 && (v - 1.0).abs() < 1e-5, "{u} {v}");
        let (u, v) = g.map(1.0, 0.0);
        assert!((u - 0.0).abs() < 1e-5 && (v - 0.0).abs() < 1e-5, "{u} {v}");
        // Demi-tour.
        let g = geometry(&Settings { rotate: 2, ..Settings::default() }, 400, 300);
        let (u, v) = g.map(0.0, 0.0);
        assert!((u - 1.0).abs() < 1e-5 && (v - 1.0).abs() < 1e-5);
        // Miroir.
        let g = geometry(&Settings { flip: true, ..Settings::default() }, 400, 300);
        let (u, v) = g.map(0.2, 0.3);
        assert!((u - 0.8).abs() < 1e-5 && (v - 0.3).abs() < 1e-5);
    }

    #[test]
    fn aspect_crop_and_straighten_stay_inside_the_image() {
        let s = Settings { aspect: 1, straighten: 12.0, ..Settings::default() };
        let g = geometry(&s, 4000, 3000);
        assert_eq!(g.width, g.height);
        assert!(g.width < 3000);
        for (u, v) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
            let (x, y) = g.map(u, v);
            assert!((-1e-4..=1.0001).contains(&x) && (-1e-4..=1.0001).contains(&y), "{u},{v} → {x},{y}");
        }
    }

    #[test]
    fn presets_are_distinct_and_keep_photo_settings() {
        let base = Settings { exposure: 0.5, rotate: 1, ..Settings::default() };
        for preset in PRESETS {
            let s = apply_preset(&base, preset);
            assert_eq!(s.exposure, 0.5);
            assert_eq!(s.rotate, 1);
            if preset.id != "original" {
                assert!(!s.color_is_neutral() || s.grain > 0.0 || s.vignette != 0.0, "{}", preset.id);
            }
        }
    }
}
