// Metal shaders, compiled at runtime with `device.makeLibrary(source:)` because the Command Line
// Tools don't ship the `metal` compiler. Keep the struct layouts in sync with Renderer.swift.

let viewportShaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProjection;
    float4   cameraPosition;   // xyz
    float4   lightDirection;   // xyz, towards the light
    float2   viewportSize;     // pixels
    float    lineWidth;        // pixels
    float    time;
    float4   clipPlane;        // xyz normal, w offset; disabled when normal is zero
    float4   up;               // world "up" (xyz) for the studio environment
    float4   options;          // x: realistic shading on
    float4x4 lightViewProjection;  // world → shadow map (overhead studio light)
    float4   shadow;           // xyz: towards the overhead light (world), w: shadows on
};

constexpr sampler shadowSampler(coord::normalized, filter::linear, compare_func::less_equal, address::clamp_to_edge);

// How much of the overhead light reaches a point: 5×5 percentage-closer filtering of the
// shadow map (soft edges), offset along the normal against acne.
static inline float shadowFactor(float3 world, float3 n, constant Uniforms& u, depth2d<float> map) {
    if (u.shadow.w < 0.5) return 1.0;
    float4 lp = u.lightViewProjection * float4(world + n * 0.25, 1.0);
    float3 ndc = lp.xyz / lp.w;
    float2 uv = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    if (uv.x < 0 || uv.y < 0 || uv.x > 1 || uv.y > 1 || ndc.z > 1) return 1.0;
    float texel = 1.6 / float(map.get_width());
    float sum = 0;
    for (int i = -2; i <= 2; i++)
        for (int j = -2; j <= 2; j++)
            sum += map.sample_compare(shadowSampler, uv + float2(i, j) * texel, ndc.z - 0.0008);
    return sum / 25.0;
}

vertex float4 shadow_vertex(const device packed_float3* positions [[buffer(0)]],
                            constant float4x4& lightVP [[buffer(1)]],
                            constant float4x4& model [[buffer(2)]],
                            uint vid [[vertex_id]]) {
    return lightVP * (model * float4(float3(positions[vid * 2]), 1.0));
}

// Per-mesh surface for realistic shading.
struct Surface {
    float4 pbr;    // metallic, roughness, pattern (0 none, 1 extruded/brushed along axis), edge highlight
    float4 axis;   // world-space pattern axis (extrusion direction)
};

// ---------------------------------------------------------------- meshes

struct MeshVertex {
    packed_float3 position;
    packed_float3 normal;
};

struct MeshOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    // The mesh's own position and normal (before its transform): surface patterns follow the
    // object as it moves (the stock lifting out, the table moving), not world space.
    float3 local;
    float3 localNormal;
    float  keep;   // 0 where a vertex has no normal: no material there (simulated stock)
};

// Section plane: everything on the positive side of the plane is cut away.
static inline bool clipped(float3 world, float4 plane) {
    return length(plane.xyz) > 0 && dot(world, plane.xyz) - plane.w > 0;
}

vertex MeshOut mesh_vertex(const device MeshVertex* vertices [[buffer(0)]],
                           constant Uniforms& u [[buffer(1)]],
                           constant float4x4& model [[buffer(2)]],
                           uint vid [[vertex_id]]) {
    MeshVertex v = vertices[vid];
    float4 world = model * float4(float3(v.position), 1.0);
    MeshOut out;
    out.position = u.viewProjection * world;
    out.world = world.xyz;
    float3 n = (model * float4(float3(v.normal), 0.0)).xyz;
    out.keep = length(n) > 1e-4 ? 1.0 : 0.0;
    out.normal = out.keep > 0.5 ? normalize(n) : float3(0, 0, 1);
    out.local = float3(v.position);
    out.localNormal = length(float3(v.normal)) > 1e-4 ? normalize(float3(v.normal)) : float3(0, 0, 1);
    return out;
}

// Studio shading in linear space (the render target is sRGB, so the GPU encodes on write):
// a key light, a cool fill, hemispheric ambient (sky above, warm bounce from the table) and a
// fresnel rim. Close to how pro CAD/CAM viewers read form.
// ---- realistic (physically based) shading

static inline float hash11(float x) { return fract(sin(x * 127.1) * 43758.5453); }
static inline float noise1(float x) {
    float i = floor(x), f = fract(x);
    return mix(hash11(i), hash11(i + 1.0), f * f * (3.0 - 2.0 * f));
}

// A photo studio: bright softbox overhead, a strip light from the key side, grey walls, a dark
// floor. Metals reflect it, which is what makes them read as metal.
static inline float3 studio(float3 d, float3 up, float3 key) {
    float h = dot(d, up);
    float3 wall = float3(0.55, 0.56, 0.58);
    float3 top = float3(1.6, 1.62, 1.65);
    float3 floorC = float3(0.16, 0.16, 0.17);
    float3 c = h >= 0 ? mix(wall, top, smoothstep(0.55, 0.92, h)) : mix(wall * 0.6, floorC, smoothstep(0.0, 0.35, -h));
    float3 k = normalize(key - up * dot(key, up));
    float strip = smoothstep(0.93, 0.985, dot(d, k)) * smoothstep(-0.2, 0.25, h);
    return c + strip * 2.5;
}

static inline float3 studioDiffuse(float3 n, float3 up) {
    float h = dot(n, up);
    return mix(float3(0.06, 0.06, 0.065), float3(0.75, 0.76, 0.78), 0.5 + 0.5 * h);
}

static inline float3 shadeRealistic(MeshOut in, constant Uniforms& u, float4 color, constant Surface& s, float3 n, float3 v, float shadow) {
    float3 up = normalize(u.up.xyz);
    float3 key = normalize(u.lightDirection.xyz);
    float metallic = s.pbr.x;
    float rough = clamp(s.pbr.y, 0.03, 1.0);
    float3 albedo = color.rgb;
    // Extrusion / brushing: fine streaks running along the axis (bar stock, brushed plates).
    if (s.pbr.z > 0.5) {
        float3 ax = normalize(s.axis.xyz);
        float3 ln = normalize(in.localNormal);
        float3 t = cross(ax, ln);
        if (length(t) < 0.2) t = cross(float3(0.577, 0.577, 0.577), ln);
        float w = dot(in.local, normalize(t));
        float g = noise1(w * 9.0) * 0.55 + noise1(w * 37.0) * 0.3 + noise1(w * 113.0) * 0.15;
        rough = clamp(rough * (0.65 + 0.8 * g), 0.03, 1.0);
        albedo *= 0.9 + 0.16 * g;
    }
    // Metals reflect most light (aluminium ~90 %): the flat view's darker display colour becomes
    // a brighter reflectance here, keeping its hue.
    float3 metalColor = min(albedo * 1.55 + 0.06, float3(1.0));
    float3 f0 = mix(float3(0.04), metalColor, metallic);
    float3 diffuseColor = albedo * (1.0 - metallic);
    float nv = max(dot(n, v), 1e-3);
    // Direct light: GGX / Smith / Schlick, key + fill.
    float3 lo = float3(0);
    // Key (over the viewer's shoulder), fill, and the studio's overhead softbox, which casts the
    // shadows (contact shadows under clamps, stops and the stock).
    float3 overhead = u.shadow.w > 0.5 ? normalize(u.shadow.xyz) : up;
    float3 lights[3] = { key, normalize(float3(-key.x, -key.y, -key.z) + up * 1.2), overhead };
    // Neutral white key (a warm key turned aluminium beige), slightly cool fill.
    float3 power[3] = { float3(1.6, 1.6, 1.6), float3(0.42, 0.45, 0.5), float3(2.3, 2.3, 2.32) * shadow };
    float a = rough * rough, a2 = a * a;
    for (int i = 0; i < 3; i++) {
        float3 l = lights[i];
        float nl = max(dot(n, l), 0.0);
        if (nl <= 0) continue;
        float3 h = normalize(l + v);
        float nh = max(dot(n, h), 0.0), vh = max(dot(v, h), 0.0);
        float d = a2 / (3.14159 * pow(nh * nh * (a2 - 1.0) + 1.0, 2.0));
        float k = (rough + 1.0) * (rough + 1.0) / 8.0;
        float g = (nv / (nv * (1 - k) + k)) * (nl / (nl * (1 - k) + k));
        float3 f = f0 + (1.0 - f0) * pow(1.0 - vh, 5.0);
        lo += (diffuseColor / 3.14159 * (1.0 - f) + d * g * f / (4.0 * nv * nl)) * power[i] * nl;
    }
    // Image-based light from the studio: reflections blur toward the diffuse light as the
    // surface gets rougher.
    float3 r = reflect(-v, n);
    float3 fr = f0 + (max(float3(1.0 - rough), f0) - f0) * pow(1.0 - nv, 5.0);
    // A large soft light behind the camera, as in a product studio: faces turned to the viewer
    // catch it, so flat metal reads bright instead of reflecting the dark wall.
    float3 env = studio(r, up, key) + float3(0.9, 0.9, 0.92) * smoothstep(0.55, 0.97, dot(r, v));
    float3 envSpec = mix(env, studioDiffuse(r, up), clamp(rough * rough * 1.6, 0.0, 1.0));
    float occlusion = 0.35 + 0.65 * shadow;  // the softbox is the sky: shadowed spots see less of it
    float3 c = lo + diffuseColor * studioDiffuse(n, up) * 0.55 * occlusion + envSpec * fr * 0.85 * (0.55 + 0.45 * shadow);
    // Rounded-edge highlight (KeyShot's "round edges"): where the shading normal turns sharply
    // between neighbouring pixels there's an edge; give it the thin glint a small fillet would.
    float e = clamp(length(fwidth(in.normal)) * 2.2, 0.0, 1.0) * s.pbr.w;
    c += e * (0.25 + 0.75 * metallic) * studio(normalize(r + up * 0.5), up, key) * 0.45;
    // Filmic tone map.
    c = c * (2.51 * c + 0.03) / (c * (2.43 * c + 0.59) + 0.14);
    return clamp(c, 0.0, 1.0);
}

fragment float4 mesh_fragment(MeshOut in [[stage_in]],
                              constant Uniforms& u [[buffer(1)]],
                              constant float4& color [[buffer(3)]],
                              constant Surface& surface [[buffer(4)]],
                              depth2d<float> shadowMap [[texture(0)]],
                              bool front [[front_facing]]) {
    if (clipped(in.world, u.clipPlane) || in.keep < 0.999) discard_fragment();
    if (surface.axis.w > 0.5) {  // unlit: flat colour with a soft edge shade
        float3 nn = normalize(in.normal) * (front ? 1.0 : -1.0);
        float facing = abs(dot(nn, normalize(u.cameraPosition.xyz - in.world)));
        return float4(color.rgb * (0.78 + 0.22 * facing), color.a);
    }
    float3 n = normalize(in.normal) * (front ? 1.0 : -1.0);
    float3 v = normalize(u.cameraPosition.xyz - in.world);
    if (u.options.x > 0.5 && (front || color.a < 0.999)) {
        if (!front && length(u.clipPlane.xyz) > 0 && color.a >= 0.999) {
            float stripe = fmod(in.position.x + in.position.y, 10.0) < 2.0 ? 0.55 : 1.0;
            return float4(float3(0.62, 0.30, 0.10) * stripe, 1.0);
        }
        float sh = shadowFactor(in.world, n, u, shadowMap);
        if (u.options.z > 0.5) return float4(float3(sh), 1.0);  // debug: the shadow factor
        return float4(shadeRealistic(in, u, color, surface, n, v, sh), color.a);
    }
    float3 key = normalize(u.lightDirection.xyz);
    float3 fill = normalize(float3(-key.x, -key.y, 0.25));
    float3 albedo = color.rgb;
    float hemi = 0.5 + 0.5 * n.z;
    float3 ambient = mix(float3(0.03, 0.03, 0.03), float3(0.07, 0.08, 0.1), hemi);
    float3 light = ambient
                 + float3(1.0, 1.0, 1.0) * max(dot(n, key), 0.0) * 0.85
                 + float3(0.55, 0.65, 0.8) * max(dot(n, fill), 0.0) * 0.18;
    float3 h = normalize(key + v);
    float specular = pow(max(dot(n, h), 0.0), 48.0) * 0.25;
    float rim = pow(1.0 - max(dot(n, v), 0.0), 4.0) * 0.06;
    float3 c = albedo * light + specular + rim;
    // Back faces seen through a section cut are the cut surface: draw them as a hatched cap,
    // like a CAD cross-section. Without a cut they're interior faces (dark).
    if (!front && color.a < 0.999) {
        // Translucent solids (stock, ghosted machine): back faces are just the far side.
    } else if (!front) {
        if (length(u.clipPlane.xyz) > 0) {
            float stripe = fmod(in.position.x + in.position.y, 10.0) < 2.0 ? 0.55 : 1.0;
            c = float3(0.62, 0.30, 0.10) * stripe;
        } else {
            c = albedo * 0.05;
        }
    }
    return float4(c, color.a);
}

// ---------------------------------------------------------------- thick lines
// One instance per segment, expanded to a screen-space quad (6 vertices) in the vertex shader,
// so lines keep a constant pixel width at any zoom and stay anti-aliased.

struct LineSegment {
    packed_float3 a;
    packed_float3 b;
    uchar4 colorA;
    uchar4 colorB;
};

struct LineOut {
    float4 position [[position]];
    float4 color;
    float  across;     // −1…1 across the line, for anti-aliasing
    float  along;      // distance along the line in pixels, for dashes
    float  dashed;
    float3 world;
};

vertex LineOut line_vertex(const device LineSegment* segments [[buffer(0)]],
                           constant Uniforms& u [[buffer(1)]],
                           constant float& visibleCount [[buffer(2)]],
                           constant float4x4& model [[buffer(3)]],
                           uint vid [[vertex_id]],
                           uint iid [[instance_id]]) {
    LineSegment s = segments[iid];
    float3 wa = (model * float4(float3(s.a), 1.0)).xyz;
    float3 wb = (model * float4(float3(s.b), 1.0)).xyz;
    float4 pa = u.viewProjection * float4(wa, 1.0);
    float4 pb = u.viewProjection * float4(wb, 1.0);
    float2 sa = pa.xy / pa.w * u.viewportSize * 0.5;
    float2 sb = pb.xy / pb.w * u.viewportSize * 0.5;
    float2 dir = sb - sa;
    float len = length(dir);
    dir = len > 1e-4 ? dir / len : float2(1, 0);
    float2 normal = float2(-dir.y, dir.x);

    // corner: (end, side) for the two triangles of the quad
    const float2 corners[6] = { float2(0,-1), float2(1,-1), float2(1,1), float2(0,-1), float2(1,1), float2(0,1) };
    float2 c = corners[vid];
    float halfWidth = u.lineWidth * 0.5 + 1.0;  // +1 px for the AA ramp
    float4 p = c.x < 0.5 ? pa : pb;
    float2 offset = normal * c.y * halfWidth / (u.viewportSize * 0.5) * p.w;

    LineOut out;
    out.position = p + float4(offset, 0, 0);
    uchar4 col = c.x < 0.5 ? s.colorA : s.colorB;
    out.color = float4(col) / 255.0;
    // Playback: segments past the cursor are hidden.
    if (float(iid) >= visibleCount) out.color.a = 0;
    out.across = c.y;
    out.along = c.x * len;
    out.dashed = col.a < 255 ? 1.0 : 0.0;   // alpha < 255 marks rapids (drawn dashed)
    out.world = c.x < 0.5 ? wa : wb;
    return out;
}

fragment float4 line_fragment(LineOut in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
    if (clipped(in.world, u.clipPlane)) discard_fragment();
    float halfWidth = u.lineWidth * 0.5 + 1.0;
    float d = abs(in.across) * halfWidth;
    float alpha = clamp(halfWidth - d, 0.0, 1.0);
    if (in.dashed > 0.5 && fmod(in.along, 8.0) > 4.0) discard_fragment();
    float a = in.color.a > 0 ? alpha : 0;
    if (u.options.y > 0) a *= u.options.y;   // x-ray pass: faint
    if (a <= 0.01) discard_fragment();
    return float4(in.color.rgb, a);
}
"""#
