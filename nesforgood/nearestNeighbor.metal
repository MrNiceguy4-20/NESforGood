
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position;
    float2 texcoord;
};

struct VSOut {
    float4 position [[position]];
    float2 texcoord;
};

struct Uniforms {
    float2 texSize;    // 256,240
    uint   mode;       // 0=none, 1=scanlines
    float  gamma;      // 0.8..1.4
    float  curvature;  // 0..~0.2
    float  colorTemp;  // 0..1 (cool..warm)
    float  _pad;
};

vertex VSOut v_main(const device VertexIn* verts [[buffer(0)]], uint vid [[vertex_id]]) {
    VSOut out;
    VertexIn v = verts[vid];
    out.position = float4(v.position, 0.0, 1.0);
    out.texcoord = v.texcoord;
    return out;
}

// Simple color temperature adjustment: mix cool (bluish) and warm (reddish) tints
float3 applyColorTemp(float3 rgb, float t) {
    float3 cool  = float3(0.95, 0.98, 1.05);
    float3 warm  = float3(1.05, 1.02, 0.95);
    float3 tint  = mix(cool, warm, clamp(t, 0.0, 1.0));
    return rgb * tint;
}

// Barrel distortion in texture space
float2 crtWarp(float2 uv, float amount) {
    float2 xy = uv * 2.0 - 1.0;
    float r2 = dot(xy, xy);
    float k = clamp(amount, 0.0, 0.25);
    float2 warped = xy * (1.0 + k * r2);
    return warped * 0.5 + 0.5;
}

fragment float4 f_main(VSOut in [[stage_in]],
                       constant Uniforms& U [[buffer(1)]],
                       texture2d<float> tex [[texture(0)]],
                       sampler samp [[sampler(0)]]) {
    float2 uv = in.texcoord;
    if (U.curvature > 0.0001) {
        uv = crtWarp(uv, U.curvature);
    }

    float4 c = tex.sample(samp, uv);

    if (U.mode == 1) {
        float line = floor(uv.y * U.texSize.y);
        if (fmod(line, 2.0) >= 1.0) { c.rgb *= 0.72; }
    }

    c.rgb = applyColorTemp(c.rgb, U.colorTemp);
    c.rgb = pow(c.rgb, float3(1.0 / clamp(U.gamma, 0.5, 2.2)));

    return c;
}

