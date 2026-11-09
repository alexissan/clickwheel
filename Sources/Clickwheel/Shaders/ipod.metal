#include <metal_stdlib>
using namespace metal;

namespace {

// MARK: - Colour space
//
// SwiftUI hands `colorEffect` values in the destination (non-linear sRGB)
// space — measured: a shader writing 0.912 lands at 233/255 in the snapshot.
// Lighting added in that space is wrong: every `+=` compounds a gamma curve.
// Decode in, light in linear, encode out.

float3 srgbToLinear(float3 c) {
    c = max(c, 0.0);
    return select(c / 12.92, pow((c + 0.055) / 1.055, 2.4), c > 0.04045);
}

float3 linearToSRGB(float3 c) {
    c = max(c, 0.0);
    return select(c * 12.92, 1.055 * pow(c, 1.0 / 2.4) - 0.055, c > 0.0031308);
}

/// Soft shoulder instead of `saturate`. A clearcoat rim genuinely exceeds 1.0;
/// clipping it welds a flat white keyline around the object.
float3 shoulder(float3 c) {
    const float knee = 0.88;
    float3 over = max(c - knee, 0.0);
    return min(c, knee) + (1.0 - knee) * (1.0 - exp(-over / (1.0 - knee)));
}

// MARK: - Geometry

float sdRoundedBox(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

/// Exact gradient of `sdRoundedBox`: axis-aligned along the flats, radial only
/// inside the corner quadrants.
float2 sdRoundedBoxGradient(float2 p, float2 halfSize, float radius) {
    float2 s = float2(p.x < 0.0 ? -1.0 : 1.0, p.y < 0.0 ? -1.0 : 1.0);
    float2 q = abs(p) - halfSize + radius;
    float2 g = (q.x > 0.0 && q.y > 0.0)
        ? normalize(max(q, float2(1e-4)))
        : ((q.x > q.y) ? float2(1.0, 0.0) : float2(0.0, 1.0));
    return g * s;
}

/// Rim roll plus a whole-face dome of a few tenths of a millimetre.
float3 shellNormal(float2 uv, float d, float2 grad, float roll, float dome) {
    float t = saturate(-d / max(roll, 1e-3));
    float angle = (1.0 - t) * (M_PI_F * 0.5);
    float3 n = float3(grad * sin(angle), cos(angle));
    n.xy += uv * dome * t;
    return normalize(n);
}

// MARK: - Reflectance

float3 fresnelSchlick(float3 f0, float cosTheta) {
    return f0 + (1.0 - f0) * pow(1.0 - saturate(cosTheta), 5.0);
}

/// Fresnel for a rough coat: the rim brightens, but blurred and capped.
float3 fresnelRough(float3 f0, float cosTheta, float roughness) {
    float3 top = max(float3(1.0 - roughness), f0);
    return f0 + (top - f0) * pow(1.0 - saturate(cosTheta), 5.0);
}

float ggx(float3 n, float3 h, float roughness) {
    float a = max(roughness * roughness, 1e-4);
    float a2 = a * a;
    float ndoth = saturate(dot(n, h));
    float k = ndoth * ndoth * (a2 - 1.0) + 1.0;
    return a2 / (M_PI_F * k * k);
}

// MARK: - Environment

/// Far field, for grazing rays: softbox above, dim room, dark desk below.
float3 studioFar(float3 r, float2 light) {
    float up = -r.y;                            // SwiftUI's y grows downward
    float3 sky     = float3(1.34, 1.37, 1.46);
    float3 horizon = float3(0.60, 0.62, 0.68);
    float3 ground  = float3(0.11, 0.11, 0.13);

    float3 c = mix(horizon, sky, smoothstep(-0.05, 0.72, up));
    c = mix(c, ground, smoothstep(-0.12, -0.62, up));

    float key = pow(saturate(dot(r, normalize(float3(-0.34 + light.x, -0.86, 0.38)))), 3.0);
    c += float3(0.72, 0.73, 0.78) * key;

    float bounce = pow(saturate(dot(r, normalize(float3(0.45, 0.72, 0.53)))), 4.0);
    c += float3(0.26, 0.23, 0.19) * bounce;

    // The wall behind the camera. Grazing rays reflect backwards, and without
    // this the silhouette edge goes to a dark outline.
    c += float3(0.30, 0.31, 0.34) * saturate(-r.z);
    return c;
}

/// Near field: where the reflected ray lands on a wall standing in front of
/// the device. On a nearly flat face a tiny normal change sweeps a long way
/// across that wall — which is why real glossy panels show a big, soft,
/// travelling reflection instead of a constant.
float3 studioWall(float3 r, float2 p, float2 halfSize, float2 light) {
    float dist = 2.2 * halfSize.y;
    float2 hit = p + r.xy * (dist / max(r.z, 0.05));
    float2 q = hit / max(halfSize, float2(1.0));

    float2 boxCentre = float2(-0.55 + light.x * 1.1, -0.95 + light.y * 0.8);
    float2 e = (q - boxCentre) / float2(1.30, 1.15);
    float box = 1.0 - smoothstep(0.30, 1.30, length(e));

    float3 c = float3(0.30, 0.31, 0.35);
    c += float3(2.05, 2.08, 2.16) * box;
    c += float3(0.30, 0.27, 0.22) * smoothstep(1.5, 3.2, q.y);
    c += float3(0.16, 0.17, 0.20) * saturate(r.z);
    return c;
}

float3 environmentFor(float3 r, float2 p, float2 halfSize, float2 light) {
    return mix(studioFar(r, light),
               studioWall(r, p, halfSize, light),
               smoothstep(0.18, 0.62, r.z));
}

/// Blue-noise-ish dither, sized in points so it stays one pixel at any scale.
float grain(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

/// Smooth value noise over `grain`, for features larger than a pixel.
float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = grain(i);
    float b = grain(i + float2(1.0, 0.0));
    float c = grain(i + float2(0.0, 1.0));
    float d = grain(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

} // namespace

// MARK: - Shell

[[ stitchable ]] half4 glossyShell(
    float2 position,
    half4 source,
    float2 size,
    float radius,
    float mmToPt,          // points per millimetre, so edges can be real sizes
    float2 light,          // -1...1, where the key sits; same signal as `sheen`
    float2 wheelCentre,    // in this view's points; the moulded well
    float wheelRadius,
    float pointsPerPixel,
    float3 tint,
    float roughness
) {
    float2 halfSize = size * 0.5;
    float2 centred = position - halfSize;
    float d = sdRoundedBox(centred, halfSize, radius);

    float aa = max(pointsPerPixel, 0.001) * 0.75;
    float coverage = 1.0 - smoothstep(-aa, aa, d);
    if (coverage <= 0.002) { return half4(0.0); }

    float2 grad = sdRoundedBoxGradient(centred, halfSize, radius);
    float2 uv = centred / max(halfSize, float2(1.0));
    // The plastic front rolls over in ~0.4 mm, starting after the chrome and
    // seam bands below.
    float3 n = shellNormal(uv, d, grad, 0.4 * mmToPt, 0.090);

    float3 v = float3(0.0, 0.0, 1.0);
    float3 keyPos = float3((-0.55 + light.x) * halfSize.x,
                           (-1.15 + light.y) * halfSize.y,
                            2.10 * halfSize.y);
    float3 l = normalize(keyPos - float3(centred, 0.0));
    float3 h = normalize(l + v);

    float ndotv = saturate(dot(n, v));
    float ndotl = saturate(dot(n, l));

    // Polycarbonate clearcoat, n = 1.586 -> F0 = 0.0503.
    const float3 f0 = float3(0.050);
    float3 F = fresnelSchlick(f0, ndotv);

    // Cool off-white. Authored in sRGB to match Palette.shellBase.
    float3 albedo = srgbToLinear(tint);

    const float wrap = 0.32;
    float diffuse = saturate((ndotl + wrap) / (1.0 + wrap));
    float3 ambient = studioFar(n, light) * 0.30;
    float3 body = albedo * (ambient + 0.86 * diffuse) * (1.0 - F);

    float3 r = reflect(-v, n);
    float matte = smoothstep(0.085, 0.60, roughness);
    float3 reflected = mix(environmentFor(r, centred, halfSize, light), studioFar(r, light) * 0.45, matte);
    float3 spec = reflected * F * mix(1.0, 0.35, matte);
    spec += ggx(n, h, roughness) * ndotl * F * mix(0.60, 0.16, matte);

    float3 colour = body + spec;

    // The wheel sits in a moulded well, not on top of the body. The occlusion
    // pools wide and soft around it — a tight ring read as a printed outline.
    float wd = length(centred - wheelCentre) - wheelRadius;
    colour *= 1.0 - 0.06 * (1.0 - smoothstep(0.0, 4.2 * mmToPt, wd));   // soft pool
    colour *= 1.0 - 0.12 * (1.0 - smoothstep(0.0, 1.2 * mmToPt, wd));   // contact
    colour = mix(colour, colour * 0.45, 1.0 - smoothstep(0.3, 1.3, wd));  // seam
    float2 wdir = normalize(centred - wheelCentre + float2(1e-4));
    colour += 0.05 * smoothstep(3.4, 1.6, wd) * saturate(dot(wdir, float2(0.42, 0.74)));

    // Broad curvature falloff. The face is nearly flat, but it is not a
    // plane: the last few millimetres bow away from the viewer, and that
    // soft darkening toward every edge is most of what makes the object
    // read as a volume instead of a sticker.
    float inwardAll = -d;
    colour *= 1.0 - 0.075 * (1.0 - smoothstep(0.6 * mmToPt, 4.5 * mmToPt, inwardAll));

    // The two-part assembly at the silhouette. Crossing the real edge from
    // outside in, the tone profile runs:
    //
    //   chrome hairline (0.2 mm, bright specular)  — the stainless rear shell
    //   parting seam    (0.4 mm, dark)             — where the two parts meet
    //   plastic roll    (0.4 mm, bright)           — the front's rolled edge
    //   flat face
    //
    // Without these the object has no visible construction at all: no material
    // change, no seam, and so no cue that it has any thickness.
    float inward = -d;                                  // 0 at the silhouette
    float chrome = 1.0 - smoothstep(0.0, 0.20 * mmToPt, inward);
    float seam = (1.0 - smoothstep(0.20 * mmToPt, 0.62 * mmToPt, inward))
               * smoothstep(0.10 * mmToPt, 0.24 * mmToPt, inward);

    // Polished steel: near-white where the key catches it, dark elsewhere,
    // with none of the plastic's diffuse component.
    float3 steelDir = normalize(float3(grad * 0.92, 0.38));
    float3 steel = environmentFor(reflect(-v, steelDir), centred, halfSize, light) * 0.62;
    steel += pow(saturate(dot(steelDir, normalize(l + v))), 90.0) * 1.5;

    colour = mix(colour, steel, chrome * 0.88);
    colour = mix(colour, colour * 0.30, seam * 0.85);

    // Micro-wear. Twenty-year-old acrylic carries hairline swirls that are
    // invisible face-on and flash as the highlight crosses them, so the
    // streaks ride the specular term only — never the body colour. Two
    // directions, both sparse.
    float2 q = float2(position.x - position.y, position.x + position.y) * 0.707;
    float swirl = smoothstep(0.80, 0.98, vnoise(float2(q.x * 1.1, q.y * 0.05)))
                + 0.8 * smoothstep(0.84, 0.99, vnoise(float2(position.y * 1.3 + 47.0, position.x * 0.045)));
    colour += swirl * dot(spec, float3(0.333)) * 0.30;

    colour = linearToSRGB(shoulder(colour));
    colour += (grain(position * 2.0) - 0.5) * 0.0055;

    return half4(half3(saturate(colour)), 1.0) * half(coverage);
}

// MARK: - Click wheel

[[ stitchable ]] half4 clickWheel(
    float2 position,
    half4 source,
    float2 size,
    float innerRatio,
    float2 light,
    float pointsPerPixel,
    float3 tint
) {
    float2 halfSize = size * 0.5;
    float2 centred = position - halfSize;
    float outer = min(size.x, size.y) * 0.5;
    float r = length(centred);

    float aa = max(pointsPerPixel, 0.001) * 0.75;
    float innerEdge = outer * innerRatio;
    float coverage = (1.0 - smoothstep(outer - aa, outer + aa, r))
                   * smoothstep(innerEdge - aa, innerEdge + aa, r);
    if (coverage <= 0.002) { return half4(0.0); }

    float2 dir = r > 1e-4 ? centred / r : float2(0.0, -1.0);
    float t = saturate(r / outer);

    // FLAT. The Classic's wheel is a flat white disc sitting flush in the
    // face: no dish, no dome — only a hair of roll right at the rim and at
    // the hole, or the edges render as cut paper.
    float rim  =  0.09 * smoothstep(0.985, 1.0, t);
    float lip  = -0.08 * (1.0 - smoothstep(0.0, 0.018, (r - innerEdge) / outer));
    float3 n = normalize(float3(dir * (rim + lip), 1.0));

    float3 v = float3(0.0, 0.0, 1.0);
    float3 keyPos = float3((-0.55 + light.x) * outer * 3.0,
                           (-1.15 + light.y) * outer * 3.0,
                            6.0 * outer);
    float3 l = normalize(keyPos - float3(centred, 0.0));
    float3 h = normalize(l + v);

    const float roughness = 0.58;
    float ndotv = saturate(dot(n, v));
    float ndotl = saturate(dot(n, l));
    float3 F = fresnelRough(float3(0.045), ndotv, roughness);

    // Bright matte white, a half-step below the shell's clearcoat.
    float3 albedo = srgbToLinear(tint);

    const float wrap = 0.55;
    float diffuse = saturate((ndotl + wrap) / (1.0 + wrap));
    float3 ambient = studioFar(n, light) * 0.36;
    float3 colour = albedo * (ambient + 0.78 * diffuse) * (1.0 - F);
    colour += studioFar(reflect(-v, n), light) * F * 0.30;
    colour += ggx(n, h, roughness) * ndotl * F * 0.18;

    // Crisp hairline seams — the Classic's wheel meets the body and the
    // button at thin dark lines, not shaded gutters.
    colour *= 1.0 - 0.15 * smoothstep(0.994, 1.0, t);
    colour *= 1.0 - 0.09 * (1.0 - smoothstep(innerEdge, innerEdge + outer * 0.012, r));

    colour = linearToSRGB(shoulder(colour));

    // Fine moulding texture — matte, not polished.
    colour += (grain(position * 2.0) - 0.5) * 0.008;
    colour += (grain(position * 0.35 + 11.0) - 0.5) * 0.004;

    return half4(half3(saturate(colour)), 1.0) * half(coverage);
}

// MARK: - Centre button

[[ stitchable ]] half4 centreButton(
    float2 position,
    half4 source,
    float2 size,
    float pressed,
    float2 light,
    float pointsPerPixel,
    float3 tint
) {
    float2 halfSize = size * 0.5;
    float2 centred = position - halfSize;
    float outer = min(size.x, size.y) * 0.5;
    float r = length(centred);

    float aa = max(pointsPerPixel, 0.001) * 0.75;
    float coverage = 1.0 - smoothstep(outer - aa, outer + aa, r);
    if (coverage <= 0.002) { return half4(0.0); }

    float2 dir = r > 1e-4 ? centred / r : float2(0.0, -1.0);
    float t = saturate(r / outer);

    // Gently concave, like the Classic's bare-metal button: a shallow dish
    // meeting the wheel at a crisp edge, not a rolled bowl.
    float dish = -0.05 * t * t;
    float roll  = 0.16 * smoothstep(0.955, 1.0, t);
    float3 n = normalize(float3(dir * (dish + roll), 1.0));

    float3 v = float3(0.0, 0.0, 1.0);
    float3 keyPos = float3((-0.55 + light.x) * outer * 7.0,
                           (-1.15 + light.y) * outer * 7.0,
                           14.0 * outer);
    float3 l = normalize(keyPos - float3(centred, 0.0));
    float3 h = normalize(l + v);

    const float roughness = 0.48;
    float ndotv = saturate(dot(n, v));
    float ndotl = saturate(dot(n, l));
    float3 F = fresnelRough(float3(0.050), ndotv, roughness);

    // Silver, a step darker than the white wheel around it.
    float3 albedo = srgbToLinear(tint);

    const float wrap = 0.48;
    float diffuse = saturate((ndotl + wrap) / (1.0 + wrap));
    float3 ambient = studioFar(n, light) * 0.34;
    float3 colour = albedo * (ambient + 0.80 * diffuse) * (1.0 - F);
    colour += studioFar(reflect(-v, n), light) * F * 0.55;
    colour += ggx(n, h, roughness) * ndotl * F * 0.35;

    // A hairline seam where it meets the wheel.
    colour *= 1.0 - 0.11 * smoothstep(0.988, 1.0, t);

    // Pressing sinks it: the crown flattens and the base occlusion deepens
    // rather than the whole cap turning grey.
    colour *= 1.0 - pressed * (0.05 + 0.16 * smoothstep(0.55, 1.0, t));

    colour = linearToSRGB(shoulder(colour));
    colour += (grain(position * 2.0) - 0.5) * 0.009;

    return half4(half3(saturate(colour)), 1.0) * half(coverage);
}

// MARK: - LCD panel and glass

[[ stitchable ]] half4 screenGlass(
    float2 position,
    half4 source,
    float2 size,
    float sheen,
    float unit,            // points per LCD pixel, for the pixel grid
    float pointsPerPixel
) {
    float2 uv = position / max(size, float2(1.0));

    // The framebuffer is ideal — pure black ink on pure white — but the panel
    // is not. A transflective TN panel lifts black to a cool dark grey and
    // never quite reaches paper white; mapping the framebuffer through the
    // panel's real range is most of what separates "LCD" from "PDF".
    const float3 panelInk   = float3(0.075, 0.082, 0.104);
    const float3 panelWhite = float3(0.968, 0.973, 0.984);
    float3 colour = panelInk + float3(source.rgb) * (panelWhite - panelInk);

    // Pixel grid. 320×240 across 2.5" is ~160 ppi, coarse enough that the
    // gaps between pixels are plainly visible on the real device. Drawn in
    // LCD units so lines land on true pixel boundaries, and faded out when a
    // cell spans too few device pixels to draw cleanly — a grid below that
    // threshold is moiré, not realism.
    float devicePerCell = unit / max(pointsPerPixel, 1e-3);
    float gridStrength = 0.10 * smoothstep(1.8, 4.5, devicePerCell);
    if (gridStrength > 0.001) {
        float2 cell = fract(position / max(unit, 1e-3));
        float2 border = min(cell, 1.0 - cell);              // 0 on the boundary
        float line = pointsPerPixel * 0.45 / max(unit, 1e-3);
        float gap = 1.0 - smoothstep(0.0, line * 2.0, min(border.x, border.y));
        colour *= 1.0 - gridStrength * gap;
    }

    // Edge-lit backlight. The CCFL runs along the bottom of the panel, so
    // the field brightens toward it, bleeds faintly in the bottom corners
    // and falls off a touch at the top. A perfectly uniform screen reads as
    // a texture, not a lit panel.
    colour *= 0.985 + 0.045 * smoothstep(0.45, 1.0, uv.y);
    colour *= 1.0 - 0.025 * smoothstep(0.25, 0.0, uv.y);
    float bleed = exp(-length((uv - float2(0.03, 1.0)) * float2(12.0, 8.0)))
                + exp(-length((uv - float2(0.97, 1.0)) * float2(12.0, 8.0)));
    colour += bleed * 0.030;

    // The LCD sits a millimetre behind the acrylic window, and the opening's
    // top lip shades the recess; the sides take a lighter version.
    colour *= 1.0 - 0.14 * smoothstep(0.045, 0.0, uv.y);
    colour *= 1.0 - 0.05 * smoothstep(0.030, 0.0, min(uv.x, 1.0 - uv.x));

    float band = uv.x * 0.72 + uv.y * 0.62;
    float highlight = exp(-pow((band - sheen) * 2.6, 2.0)) * 0.13;
    highlight += exp(-pow((band - sheen - 0.30) * 7.0, 2.0)) * 0.05;

    // The bezel shades the panel's outermost pixels.
    float2 edge = min(uv, 1.0 - uv);
    float vignette = smoothstep(0.0, 0.055, min(edge.x, edge.y));

    colour *= mix(0.90, 1.0, vignette);
    colour += highlight;

    return half4(half3(saturate(colour)), source.a);
}
