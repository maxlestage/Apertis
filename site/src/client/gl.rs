//! Rendu WebGL2 : l'image (ou l'image courante d'une vidéo) traverse l'étape linéaire,
//! la LUT 3D de tonalité et de couleur, puis les effets, dans un seul shader.

use wasm_bindgen::JsCast;
use web_sys::{
    HtmlCanvasElement, ImageBitmap, HtmlVideoElement, WebGl2RenderingContext as Gl, WebGlFramebuffer,
    WebGlProgram, WebGlTexture, WebGlUniformLocation, WebGlVertexArrayObject,
};

use crate::grade::{self, Geometry, Settings};

pub const LUT_SIZE: usize = 33;

const VERTEX: &str = r#"#version 300 es
in vec2 a_pos;
out vec2 v_uv;
uniform bool u_flip_y;
void main() {
    v_uv = a_pos;
    vec2 p = a_pos * 2.0 - 1.0;
    gl_Position = vec4(p.x, u_flip_y ? p.y : -p.y, 0.0, 1.0);
}
"#;

const FRAGMENT: &str = r#"#version 300 es
precision highp float;
precision highp sampler3D;
in vec2 v_uv;
out vec4 o;
uniform sampler2D u_src;
uniform sampler3D u_lut;
uniform mat3 u_geo;
uniform vec2 u_texel;
uniform vec3 u_wb;
uniform float u_gain;
uniform bool u_lut_on;
uniform bool u_original;
uniform bool u_clip;
uniform float u_sharpen;
uniform float u_vignette;
uniform float u_grain;
uniform float u_grain_size;
uniform vec2 u_size;

vec3 to_linear(vec3 c) {
    return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}
vec3 to_srgb(vec3 c) {
    return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}
float hash(vec2 p) {
    p = fract(p * vec2(443.897, 441.423));
    p += dot(p, p.yx + 19.19);
    return fract((p.x + p.y) * p.x);
}

void main() {
    vec2 st = (u_geo * vec3(v_uv, 1.0)).xy;
    vec3 c = texture(u_src, st).rgb;
    if (u_original) { o = vec4(c, 1.0); return; }
    if (u_sharpen > 0.0) {
        vec3 b = texture(u_src, st + vec2(u_texel.x, 0.0)).rgb + texture(u_src, st - vec2(u_texel.x, 0.0)).rgb
               + texture(u_src, st + vec2(0.0, u_texel.y)).rgb + texture(u_src, st - vec2(0.0, u_texel.y)).rgb;
        c = clamp(c + u_sharpen * (c - b * 0.25), 0.0, 1.0);
    }
    c = clamp(to_srgb(max(to_linear(c) * u_wb * u_gain, 0.0)), 0.0, 1.0);
    if (u_lut_on) {
        float n = 33.0;
        c = texture(u_lut, c * ((n - 1.0) / n) + 0.5 / n).rgb;
    }
    if (u_vignette != 0.0) {
        float aspect = u_size.x / u_size.y;
        vec2 d = (v_uv - 0.5) * vec2(aspect, 1.0);
        float r = length(d) / length(vec2(aspect, 1.0) * 0.5);
        float w = smoothstep(0.3, 1.05, r);
        c = u_vignette > 0.0 ? c * (1.0 - u_vignette * w * 0.85) : c + (-u_vignette) * w * (1.0 - c) * 0.6;
    }
    if (u_grain > 0.0) {
        vec2 p = floor(v_uv * u_size / u_grain_size);
        float n = (hash(p) + hash(p + 17.31) - 1.0);
        float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
        c += n * u_grain * 0.16 * (1.0 - abs(l - 0.45) * 1.1);
    }
    c = clamp(c, 0.0, 1.0);
    if (u_clip) {
        if (max(c.r, max(c.g, c.b)) >= 0.996) c = vec3(1.0, 0.15, 0.25);
        else if (min(c.r, min(c.g, c.b)) <= 0.004) c = vec3(0.15, 0.35, 1.0);
    }
    o = vec4(c, 1.0);
}
"#;

/// Où dessiner : le canevas affiché, ou une texture hors écran à relire.
pub struct Target<'a> {
    pub framebuffer: Option<&'a WebGlFramebuffer>,
    pub width: u32,
    pub height: u32,
    /// Lignes de haut en bas dans `readPixels` (export, histogramme).
    pub flip_y: bool,
}

/// Options d'affichage qui ne font pas partie des réglages.
#[derive(Clone, Copy, Default)]
pub struct View {
    pub original: bool,
    pub clipping: bool,
}

pub struct Renderer {
    pub gl: Gl,
    pub canvas: HtmlCanvasElement,
    program: WebGlProgram,
    vao: WebGlVertexArrayObject,
    source: WebGlTexture,
    lut: WebGlTexture,
    pub source_size: (u32, u32),
    pub max_texture: u32,
    lut_key: Option<Settings>,
    lut_on: bool,
    uniforms: Uniforms,
}

struct Uniforms {
    flip_y: Option<WebGlUniformLocation>,
    src: Option<WebGlUniformLocation>,
    lut: Option<WebGlUniformLocation>,
    geo: Option<WebGlUniformLocation>,
    texel: Option<WebGlUniformLocation>,
    wb: Option<WebGlUniformLocation>,
    gain: Option<WebGlUniformLocation>,
    lut_on: Option<WebGlUniformLocation>,
    original: Option<WebGlUniformLocation>,
    clip: Option<WebGlUniformLocation>,
    sharpen: Option<WebGlUniformLocation>,
    vignette: Option<WebGlUniformLocation>,
    grain: Option<WebGlUniformLocation>,
    grain_size: Option<WebGlUniformLocation>,
    size: Option<WebGlUniformLocation>,
}

fn compile(gl: &Gl, kind: u32, source: &str) -> Result<web_sys::WebGlShader, String> {
    let shader = gl.create_shader(kind).ok_or("shader")?;
    gl.shader_source(&shader, source);
    gl.compile_shader(&shader);
    if gl.get_shader_parameter(&shader, Gl::COMPILE_STATUS).as_bool() == Some(true) {
        Ok(shader)
    } else {
        Err(gl.get_shader_info_log(&shader).unwrap_or_default())
    }
}

impl Renderer {
    pub fn new(canvas: HtmlCanvasElement) -> Result<Renderer, String> {
        let options = js_sys::Object::new();
        let _ = js_sys::Reflect::set(&options, &"preserveDrawingBuffer".into(), &true.into());
        let _ = js_sys::Reflect::set(&options, &"premultipliedAlpha".into(), &false.into());
        let gl: Gl = canvas
            .get_context_with_context_options("webgl2", &options)
            .map_err(|_| "WebGL2 indisponible")?
            .ok_or("WebGL2 indisponible")?
            .dyn_into()
            .map_err(|_| "WebGL2 indisponible")?;
        let program = gl.create_program().ok_or("programme")?;
        gl.attach_shader(&program, &compile(&gl, Gl::VERTEX_SHADER, VERTEX)?);
        gl.attach_shader(&program, &compile(&gl, Gl::FRAGMENT_SHADER, FRAGMENT)?);
        gl.link_program(&program);
        if gl.get_program_parameter(&program, Gl::LINK_STATUS).as_bool() != Some(true) {
            return Err(gl.get_program_info_log(&program).unwrap_or_default());
        }
        gl.use_program(Some(&program));

        let vao = gl.create_vertex_array().ok_or("vao")?;
        gl.bind_vertex_array(Some(&vao));
        let buffer = gl.create_buffer().ok_or("buffer")?;
        gl.bind_buffer(Gl::ARRAY_BUFFER, Some(&buffer));
        let quad: [f32; 12] = [0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0, 1.0];
        let array = js_sys::Float32Array::from(&quad[..]);
        gl.buffer_data_with_array_buffer_view(Gl::ARRAY_BUFFER, &array, Gl::STATIC_DRAW);
        let position = gl.get_attrib_location(&program, "a_pos") as u32;
        gl.enable_vertex_attrib_array(position);
        gl.vertex_attrib_pointer_with_i32(position, 2, Gl::FLOAT, false, 0, 0);

        let source = gl.create_texture().ok_or("texture")?;
        let lut = gl.create_texture().ok_or("texture")?;
        let max_texture = gl.get_parameter(Gl::MAX_TEXTURE_SIZE).ok().and_then(|v| v.as_f64()).unwrap_or(4096.0) as u32;
        let u = |name: &str| gl.get_uniform_location(&program, name);
        let uniforms = Uniforms {
            flip_y: u("u_flip_y"),
            src: u("u_src"),
            lut: u("u_lut"),
            geo: u("u_geo"),
            texel: u("u_texel"),
            wb: u("u_wb"),
            gain: u("u_gain"),
            lut_on: u("u_lut_on"),
            original: u("u_original"),
            clip: u("u_clip"),
            sharpen: u("u_sharpen"),
            vignette: u("u_vignette"),
            grain: u("u_grain"),
            grain_size: u("u_grain_size"),
            size: u("u_size"),
        };
        gl.uniform1i(uniforms.src.as_ref(), 0);
        gl.uniform1i(uniforms.lut.as_ref(), 1);
        Ok(Renderer {
            gl,
            canvas,
            program,
            vao,
            source,
            lut,
            source_size: (0, 0),
            max_texture,
            lut_key: None,
            lut_on: false,
            uniforms,
        })
    }

    fn bind_source_params(&self, mipmaps: bool) {
        let gl = &self.gl;
        gl.tex_parameteri(Gl::TEXTURE_2D, Gl::TEXTURE_WRAP_S, Gl::CLAMP_TO_EDGE as i32);
        gl.tex_parameteri(Gl::TEXTURE_2D, Gl::TEXTURE_WRAP_T, Gl::CLAMP_TO_EDGE as i32);
        gl.tex_parameteri(Gl::TEXTURE_2D, Gl::TEXTURE_MAG_FILTER, Gl::LINEAR as i32);
        let min = if mipmaps { Gl::LINEAR_MIPMAP_LINEAR } else { Gl::LINEAR };
        gl.tex_parameteri(Gl::TEXTURE_2D, Gl::TEXTURE_MIN_FILTER, min as i32);
        if mipmaps {
            gl.generate_mipmap(Gl::TEXTURE_2D);
        }
    }

    /// Charge une photo (déjà orientée) comme source.
    pub fn set_image(&mut self, bitmap: &ImageBitmap) -> Result<(), String> {
        let gl = &self.gl;
        gl.active_texture(Gl::TEXTURE0);
        gl.bind_texture(Gl::TEXTURE_2D, Some(&self.source));
        gl.pixel_storei(Gl::UNPACK_FLIP_Y_WEBGL, 0);
        gl.tex_image_2d_with_u32_and_u32_and_image_bitmap(Gl::TEXTURE_2D, 0, Gl::RGBA as i32, Gl::RGBA, Gl::UNSIGNED_BYTE, bitmap)
            .map_err(|_| "Image trop grande pour la carte graphique")?;
        self.bind_source_params(true);
        self.source_size = (bitmap.width(), bitmap.height());
        Ok(())
    }

    /// Envoie l'image courante d'une vidéo comme source.
    pub fn set_video_frame(&mut self, video: &HtmlVideoElement) -> bool {
        let (w, h) = (video.video_width(), video.video_height());
        if w == 0 || h == 0 {
            return false;
        }
        let gl = &self.gl;
        gl.active_texture(Gl::TEXTURE0);
        gl.bind_texture(Gl::TEXTURE_2D, Some(&self.source));
        gl.pixel_storei(Gl::UNPACK_FLIP_Y_WEBGL, 0);
        if gl
            .tex_image_2d_with_u32_and_u32_and_html_video_element(Gl::TEXTURE_2D, 0, Gl::RGBA as i32, Gl::RGBA, Gl::UNSIGNED_BYTE, video)
            .is_err()
        {
            return false;
        }
        self.bind_source_params(false);
        self.source_size = (w, h);
        true
    }

    /// Recalcule la LUT si les réglages de tonalité ou de couleur ont changé.
    fn update_lut(&mut self, s: &Settings) {
        let mut key = *s;
        // Seuls les réglages qui entrent dans la LUT comptent.
        key.exposure = 0.0;
        key.temperature = 0.0;
        key.tint = 0.0;
        key.grain = 0.0;
        key.grain_size = 0.0;
        key.vignette = 0.0;
        key.sharpen = 0.0;
        key.straighten = 0.0;
        key.rotate = 0;
        key.flip = false;
        key.aspect = 0;
        if self.lut_key == Some(key) {
            return;
        }
        self.lut_key = Some(key);
        self.lut_on = !key.color_is_neutral();
        if !self.lut_on {
            return;
        }
        let data = grade::bake_lut(&key, LUT_SIZE);
        let gl = &self.gl;
        gl.active_texture(Gl::TEXTURE1);
        gl.bind_texture(Gl::TEXTURE_3D, Some(&self.lut));
        gl.pixel_storei(Gl::UNPACK_ALIGNMENT, 1);
        let n = LUT_SIZE as i32;
        let _ = gl.tex_image_3d_with_opt_u8_array(Gl::TEXTURE_3D, 0, Gl::RGBA8 as i32, n, n, n, 0, Gl::RGBA, Gl::UNSIGNED_BYTE, Some(&data));
        for p in [Gl::TEXTURE_WRAP_S, Gl::TEXTURE_WRAP_T, Gl::TEXTURE_WRAP_R] {
            gl.tex_parameteri(Gl::TEXTURE_3D, p, Gl::CLAMP_TO_EDGE as i32);
        }
        gl.tex_parameteri(Gl::TEXTURE_3D, Gl::TEXTURE_MIN_FILTER, Gl::LINEAR as i32);
        gl.tex_parameteri(Gl::TEXTURE_3D, Gl::TEXTURE_MAG_FILTER, Gl::LINEAR as i32);
        gl.active_texture(Gl::TEXTURE0);
    }

    pub fn geometry(&self, s: &Settings) -> Geometry {
        grade::geometry(s, self.source_size.0.max(1), self.source_size.1.max(1))
    }

    /// Dessine l'image développée dans la cible.
    pub fn draw(&mut self, s: &Settings, view: View, target: Target<'_>) {
        self.update_lut(s);
        let geo = self.geometry(s);
        let gl = &self.gl;
        gl.bind_framebuffer(Gl::FRAMEBUFFER, target.framebuffer);
        gl.viewport(0, 0, target.width as i32, target.height as i32);
        gl.use_program(Some(&self.program));
        gl.bind_vertex_array(Some(&self.vao));
        gl.active_texture(Gl::TEXTURE0);
        gl.bind_texture(Gl::TEXTURE_2D, Some(&self.source));
        gl.active_texture(Gl::TEXTURE1);
        gl.bind_texture(Gl::TEXTURE_3D, Some(&self.lut));
        let u = &self.uniforms;
        let wb = grade::white_balance(s.temperature, s.tint);
        gl.uniform1i(u.flip_y.as_ref(), i32::from(target.flip_y));
        gl.uniform_matrix3fv_with_f32_array(u.geo.as_ref(), false, &geo.matrix);
        let (sw, sh) = self.source_size;
        gl.uniform2f(u.texel.as_ref(), 1.0 / sw.max(1) as f32, 1.0 / sh.max(1) as f32);
        gl.uniform3f(u.wb.as_ref(), wb[0], wb[1], wb[2]);
        gl.uniform1f(u.gain.as_ref(), s.exposure.exp2());
        gl.uniform1i(u.lut_on.as_ref(), i32::from(self.lut_on));
        gl.uniform1i(u.original.as_ref(), i32::from(view.original));
        gl.uniform1i(u.clip.as_ref(), i32::from(view.clipping && !view.original));
        gl.uniform1f(u.sharpen.as_ref(), s.sharpen / 100.0 * 1.6);
        gl.uniform1f(u.vignette.as_ref(), s.vignette / 100.0);
        gl.uniform1f(u.grain.as_ref(), s.grain / 100.0);
        gl.uniform1f(u.grain_size.as_ref(), s.grain_size * (geo.width.max(geo.height) as f32 / 2400.0).max(1.0));
        gl.uniform2f(u.size.as_ref(), geo.width as f32, geo.height as f32);
        gl.draw_arrays(Gl::TRIANGLES, 0, 6);
        gl.active_texture(Gl::TEXTURE0);
    }

    /// Rend hors écran et relit les pixels (RGBA, lignes de haut en bas).
    pub fn render_pixels(&mut self, s: &Settings, view: View, width: u32, height: u32) -> Result<Vec<u8>, String> {
        let gl = self.gl.clone();
        let texture = gl.create_texture().ok_or("texture")?;
        gl.active_texture(Gl::TEXTURE2);
        gl.bind_texture(Gl::TEXTURE_2D, Some(&texture));
        gl.tex_storage_2d(Gl::TEXTURE_2D, 1, Gl::RGBA8, width as i32, height as i32);
        let fbo = gl.create_framebuffer().ok_or("framebuffer")?;
        gl.bind_framebuffer(Gl::FRAMEBUFFER, Some(&fbo));
        gl.framebuffer_texture_2d(Gl::FRAMEBUFFER, Gl::COLOR_ATTACHMENT0, Gl::TEXTURE_2D, Some(&texture), 0);
        gl.active_texture(Gl::TEXTURE0);
        if gl.check_framebuffer_status(Gl::FRAMEBUFFER) != Gl::FRAMEBUFFER_COMPLETE {
            gl.bind_framebuffer(Gl::FRAMEBUFFER, None);
            gl.delete_framebuffer(Some(&fbo));
            gl.delete_texture(Some(&texture));
            return Err("Rendu hors écran impossible à cette taille".into());
        }
        self.draw(s, view, Target { framebuffer: Some(&fbo), width, height, flip_y: true });
        let mut pixels = vec![0u8; (width * height * 4) as usize];
        let result = gl.read_pixels_with_opt_u8_array(0, 0, width as i32, height as i32, Gl::RGBA, Gl::UNSIGNED_BYTE, Some(&mut pixels));
        gl.bind_framebuffer(Gl::FRAMEBUFFER, None);
        gl.delete_framebuffer(Some(&fbo));
        gl.delete_texture(Some(&texture));
        result.map_err(|_| "Lecture des pixels impossible".to_owned())?;
        Ok(pixels)
    }
}
