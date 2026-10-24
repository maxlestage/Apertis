#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

// Étape « effets » d'Apertis : vignette, grain et alerte d'écrêtage. Même calcul que le
// shader du laboratoire du site (site/src/client/gl.rs), sur des valeurs sRGB encodées.

static float apertisHash(float2 p) {
    p = fract(p * float2(443.897, 441.423));
    p += dot(p, p.yx + 19.19);
    return fract((p.x + p.y) * p.x);
}

// frame : origine (x, y) et taille (z, w) de l'image de sortie, en pixels.
[[stitchable]] float4 apertisEffects(coreimage::sample_t s, float4 frame, float vignette, float grain,
                                     float grainSize, float clip, coreimage::destination dest) {
    float3 c = clamp(s.rgb, 0.0, 1.0);
    float2 size = frame.zw;
    // Coordonnées de sortie, origine en haut à gauche comme dans le navigateur.
    float2 uv = (dest.coord() - frame.xy) / size;
    uv.y = 1.0 - uv.y;
    if (vignette != 0.0) {
        float aspect = size.x / size.y;
        float2 d = (uv - 0.5) * float2(aspect, 1.0);
        float r = length(d) / length(float2(aspect, 1.0) * 0.5);
        float w = smoothstep(0.3, 1.05, r);
        c = vignette > 0.0 ? c * (1.0 - vignette * w * 0.85) : c + (-vignette) * w * (1.0 - c) * 0.6;
    }
    if (grain > 0.0) {
        float2 p = floor(uv * size / grainSize);
        float n = apertisHash(p) + apertisHash(p + 17.31) - 1.0;
        float l = dot(c, float3(0.2126, 0.7152, 0.0722));
        c += n * grain * 0.16 * (1.0 - abs(l - 0.45) * 1.1);
    }
    c = clamp(c, 0.0, 1.0);
    if (clip > 0.5) {
        if (max(c.r, max(c.g, c.b)) >= 0.996) c = float3(1.0, 0.15, 0.25);
        else if (min(c.r, min(c.g, c.b)) <= 0.004) c = float3(0.15, 0.35, 1.0);
    }
    return float4(c, 1.0);
}
