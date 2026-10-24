//! Développe les images de démonstration du site avec le pipeline du laboratoire
//! (référence CPU de `grade` : étape linéaire, tonalité et couleur, vignette).
//!
//!     cargo run -p apertis-site --example bake -- <source.jpg> <sortie.jpg> <style|flat> [largeur]

use apertis_site::grade::{self, Settings, PRESETS};
use image::{ImageReader, RgbImage, imageops::FilterType};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [input, output, style, rest @ ..] = args.as_slice() else {
        eprintln!("usage: bake <source> <sortie> <style|flat> [largeur]");
        std::process::exit(2);
    };
    let width: u32 = rest.first().and_then(|w| w.parse().ok()).unwrap_or(1600);
    let source = ImageReader::open(input).expect("source").decode().expect("image").to_rgb8();
    let height = (u64::from(source.height()) * u64::from(width) / u64::from(source.width())) as u32;
    let source = image::imageops::resize(&source, width, height, FilterType::Lanczos3);

    let settings = if style == "flat" {
        // Rendu « plat », comme un RAW ou un profil Log avant développement.
        Settings { contrast: -55.0, saturation: -35.0, highlights: -40.0, shadows: 35.0, blacks: 35.0, fade: 20.0, ..Settings::default() }
    } else {
        let preset = PRESETS.iter().find(|p| p.id == style).expect("style inconnu");
        grade::apply_preset(&Settings::default(), preset)
    };

    let mut out = RgbImage::new(width, height);
    let aspect = width as f32 / height as f32;
    for (x, y, px) in source.enumerate_pixels() {
        let c = [px[0] as f32 / 255.0, px[1] as f32 / 255.0, px[2] as f32 / 255.0];
        let mut c = grade::develop(&settings, grade::linear_stage(&settings, c));
        if settings.vignette != 0.0 {
            let (u, v) = (x as f32 / width as f32 - 0.5, y as f32 / height as f32 - 0.5);
            let r = ((u * aspect).powi(2) + v * v).sqrt() / ((aspect * 0.5).powi(2) + 0.25).sqrt();
            let w = grade::smoothstep(0.3, 1.05, r);
            for ch in &mut c {
                *ch *= 1.0 - settings.vignette / 100.0 * w * 0.85;
            }
        }
        out.put_pixel(x, y, image::Rgb(c.map(|v| (v.clamp(0.0, 1.0) * 255.0).round() as u8)));
    }
    let file = std::fs::File::create(output).expect("sortie");
    let mut encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(std::io::BufWriter::new(file), 84);
    encoder.encode_image(&out).expect("encodage");
    println!("{output} ({width} × {height}, {style})");
}
