//
//  Shaders.metal
//  Magnetic
//
//  3D Ray Marching metaball renderer with orbit camera (optimized)
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Shared Structs

struct Ball {
    float4 data;       // xyz = position (normalized 0..1, z=0.5 center), w = radius
};

struct SimParams {
    float  time;
    float  bassEnergy;
    float  midEnergy;
    float  highEnergy;
    uint   ballCount;
    uint   gridWidth;
    uint   gridHeight;
    float  threshold;
    float  screenAspect;
    uint   touchCount;
    float  animSpeed;
    // Camera orientation matrix columns (3x3, packed as 9 floats)
    float  camR0; float camR1; float camR2;  // right
    float  camU0; float camU1; float camU2;  // up
    float  camF0; float camF1; float camF2;  // -forward
    float  cameraDistance;
    uint   materialMode;   // 0=black, 1=mercury, 2=wireframe, 3=custom color, 4=glass
    float  colorHue;       // 0..1 hue for custom color mode
    float  colorBri;       // 0..1 brightness for custom color mode
    uint   envMapIndex;    // 0=none (procedural), 1-5=HDRI maps
    float  envIntensity;   // HDRI brightness multiplier
    uint   bgMode;         // 0=white, 1=black, 2=green, 3=custom color
    float  bgR;            // custom background color R
    float  bgG;            // custom background color G
    float  bgB;            // custom background color B
    uint   envLocked;      // 0=FREE(camera-relative), 1=FIXED(world-fixed 天地固定), 2=FRONT(camera-local)
    float  blendK;          // smin blend factor (0.05=sharp, 1.0=gooey)
};

struct Vertex {
    float4 position [[position]];
    float2 uv;
};

// MARK: - SDF

inline float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

inline float mapScene(float3 p, constant Ball *balls, uint ballCount, float blendK) {
    float d = 1e10;
    float k = blendK;
    
    for (uint i = 0; i < ballCount; i++) {
        float3 pos = balls[i].data.xyz;
        float  rad = balls[i].data.w;
        float3 center = float3(
            (pos.x - 0.5) * 3.0,
            -(pos.y - 0.5) * 3.0,
            (pos.z - 0.5) * 3.0
        );
        float r = rad * 4.5;
        float sphere = length(p - center) - r;
        d = smin(d, sphere, k);
    }
    return d;
}

inline float3 calcNormal(float3 p, constant Ball *balls, uint ballCount, float blendK) {
    // Tetrahedron technique: 4 SDF evaluations instead of 6
    const float h = 0.003;
    const float2 k = float2(1, -1);
    return normalize(
        k.xyy * mapScene(p + k.xyy * h, balls, ballCount, blendK) +
        k.yyx * mapScene(p + k.yyx * h, balls, ballCount, blendK) +
        k.yxy * mapScene(p + k.yxy * h, balls, ballCount, blendK) +
        k.xxx * mapScene(p + k.xxx * h, balls, ballCount, blendK)
    );
}

// MARK: - Orbit camera (quaternion-based, matrix passed from CPU)

// MARK: - Vertex Shader

vertex Vertex fullscreenVertex(uint vid [[vertex_id]]) {
    float2 positions[6] = {
        float2(-1, -1), float2( 1, -1), float2(-1,  1),
        float2(-1,  1), float2( 1, -1), float2( 1,  1)
    };
    float2 uvs[6] = {
        float2(0, 1), float2(1, 1), float2(0, 0),
        float2(0, 0), float2(1, 1), float2(1, 0)
    };
    
    Vertex out;
    out.position = float4(positions[vid], 0, 1);
    out.uv = uvs[vid];
    return out;
}

// MARK: - HSV to RGB

inline float3 hsv2rgb(float h, float s, float v) {
    float3 c = float3(h, s, v);
    float3 p = abs(fract(float3(c.x) + float3(0.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0);
    return c.z * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

// MARK: - Equirectangular HDRI sampling

inline float3 sampleEnvMap(float3 dir, texture2d<float> envMap, sampler envSampler) {
    // Convert direction vector to equirectangular UV
    float phi = atan2(dir.z, dir.x);          // -pi..pi
    float theta = asin(clamp(dir.y, -1.0, 1.0)); // -pi/2..pi/2
    float2 envUV = float2(
        phi / (2.0 * M_PI_F) + 0.5,  // 0..1
        0.5 - theta / M_PI_F          // 0..1 (flip Y: top = sky)
    );
    return envMap.sample(envSampler, envUV).rgb;
}

// MARK: - Procedural Space Background

// Hash functions
inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

inline float hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

// Value noise
inline float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Lightweight FBM — only 3 octaves for performance
inline float fbm3(float2 p) {
    float v = 0.0;
    v += 0.50 * vnoise(p); p *= 2.0;
    v += 0.25 * vnoise(p); p *= 2.0;
    v += 0.125 * vnoise(p);
    return v;
}

// Single-pass domain warp — one warp + one FBM = marble look, much cheaper
inline float warpNoise(float2 p) {
    float2 q = float2(fbm3(p), fbm3(p + float2(5.2, 1.3)));
    return fbm3(p + 3.0 * q);
}

// Classic marble: sin(coordinate + noise) creates vein-like stripes
inline float marblePattern(float2 p, float freq, float strength) {
    float n = fbm3(p);
    // sin of (linear coord + turbulence) = organic vein lines
    float v = sin(p.x * freq + p.y * freq * 0.7 + n * strength);
    return v * 0.5 + 0.5; // remap to 0..1
}

// Procedural space/cosmos background with marble nebula and slow scroll
inline float3 spaceBackground(float2 uv, float3 rd, float time) {
    // Slow continuous scroll
    float scrollSpeed = 0.008;
    float2 scrollOffset = float2(time * scrollSpeed, time * scrollSpeed * 0.3);
    float2 baseUV = uv + scrollOffset;
    
    // Deep space base color
    float3 col = float3(0.003, 0.002, 0.010);
    
    // === Primary marble veins — diagonal flowing streaks ===
    // Rotated coordinates for diagonal flow (~30 deg)
    float2 mUV1 = baseUV * 2.5;
    float m1 = marblePattern(mUV1, 3.0, 6.0);
    // Sharpen the veins: pow creates thin bright lines with dark gaps
    float vein1 = pow(m1, 3.0);
    // Softer broad glow around veins
    float glow1 = pow(m1, 1.5);
    
    // Purple/blue marble veins
    col += float3(0.08, 0.03, 0.14) * vein1 * 0.5;
    col += float3(0.03, 0.02, 0.06) * glow1 * 0.3;
    
    // === Secondary marble layer — cross-hatching veins at different angle ===
    float2 mUV2 = float2(baseUV.x * 0.7 - baseUV.y * 0.7,
                          baseUV.x * 0.7 + baseUV.y * 0.7) * 1.8;
    float m2 = marblePattern(mUV2 + float2(40.0, 20.0), 2.5, 5.0);
    float vein2 = pow(m2, 3.5);
    float glow2 = pow(m2, 1.8);
    
    // Teal/cyan cross veins
    col += float3(0.02, 0.06, 0.10) * vein2 * 0.35;
    col += float3(0.01, 0.03, 0.05) * glow2 * 0.25;
    
    // === Broad marble wash — large scale light/dark variation ===
    float2 mUV3 = baseUV * 0.8;
    float wash = fbm3(mUV3 + float2(100.0, 50.0));
    float washMarble = sin(mUV3.x * 1.5 + mUV3.y * 1.0 + wash * 4.0) * 0.5 + 0.5;
    // Creates large bright/dark patches like real marble slabs
    col += float3(0.04, 0.03, 0.06) * pow(washMarble, 2.0) * 0.4;
    
    // === Dark veins (cracks) — subtract light for contrast ===
    float2 mUV4 = baseUV * 3.5;
    float crack = marblePattern(mUV4 + float2(70.0, 0.0), 4.0, 7.0);
    float darkLine = 1.0 - pow(crack, 0.5); // invert + soften = dark veins
    darkLine = smoothstep(0.2, 0.5, darkLine);
    col *= 1.0 - darkLine * 0.3;
    
    // === Warm reddish accent in some vein intersections ===
    float warmth = vein1 * vein2;
    col += float3(0.06, 0.01, 0.02) * pow(warmth, 1.5) * 2.0;
    
    // === Star density follows the marble veins ===
    float starDensityMap = 0.03 + glow1 * 0.15 + glow2 * 0.10;
    starDensityMap = clamp(starDensityMap, 0.0, 0.25);
    
    // === Star field — 2 sparse layers ===
    for (int layer = 0; layer < 2; layer++) {
        float layerF = float(layer);
        float scale = 100.0 + layerF * 180.0;
        float2 parallax = scrollOffset * (0.85 + layerF * 0.1);
        float2 starUV = (uv + parallax) * scale;
        float2 cellId = floor(starUV);
        float2 cellFrac = fract(starUV) - 0.5;
        
        float h = hash21(cellId + layerF * 137.0);
        float threshold = 1.0 - (starDensityMap + 0.03 * layerF);
        
        if (h > threshold) {
            float2 ofs = float2(hash21(cellId + 1.0 + layerF * 50.0),
                                hash21(cellId + 2.0 + layerF * 50.0)) - 0.5;
            float2 d = cellFrac - ofs * 0.7;
            float dist = length(d);
            
            float baseBright = (h - threshold) / (1.0 - threshold);
            baseBright = baseBright * 0.6 + 0.4;
            float twinkle = sin(time * (0.4 + h * 0.8) + h * 100.0) * 0.12 + 0.88;
            float brightness = baseBright * twinkle;
            
            float starSize = 0.035;
            float glowSize = 0.10;
            if (h > 0.99) {
                starSize = 0.055;
                glowSize = 0.18;
                brightness *= 1.3;
            }
            
            float star = smoothstep(starSize, 0.0, dist) * brightness;
            float glow = smoothstep(glowSize, 0.0, dist) * brightness * 0.2;
            
            float3 starColor;
            float cs = hash11(h * 123.456 + layerF);
            if (cs > 0.85) {
                starColor = float3(0.65, 0.75, 1.0);
            } else if (cs > 0.7) {
                starColor = float3(1.0, 0.92, 0.75);
            } else {
                starColor = float3(0.92, 0.92, 1.0);
            }
            
            col += starColor * (star + glow);
        }
    }
    
    // Faint diffuse glow along main veins
    col += float3(0.04, 0.04, 0.06) * glow1 * glow2 * 0.15;
    
    // Avoid pure black
    col += float3(0.003, 0.002, 0.005);
    
    return col;
}

// MARK: - Fragment Shader: optimized 3D Ray Marching with material modes

fragment float4 metaballFragment(
    Vertex in                      [[stage_in]],
    constant Ball  *balls          [[buffer(0)]],
    constant SimParams &params     [[buffer(1)]],
    texture2d<float> envMap        [[texture(0)]],
    sampler envSampler             [[sampler(0)]]
) {
    float2 uv = in.uv;
    float2 screen = (uv * 2.0 - 1.0);
    screen.x *= params.screenAspect;
    
    // Camera from CPU-supplied orientation matrix (right, up, forward columns)
    float3 camRight = float3(params.camR0, params.camR1, params.camR2);
    float3 camUp    = float3(params.camU0, params.camU1, params.camU2);
    float3 camFwd   = float3(params.camF0, params.camF1, params.camF2);
    
    // Camera position: along the local forward axis, looking back toward origin
    float3 ro = camFwd * params.cameraDistance;
    
    // View matrix: camFwd points away from origin, so forward view direction is -camFwd
    // rdCam z=-2.2 maps through camFwd column to produce -camFwd direction (toward origin)
    float3x3 camMat = float3x3(camRight, camUp, camFwd);
    
    float3 rdCam = normalize(float3(screen, -2.2));
    float3 rd = camMat * rdCam;
    
    // Ray march
    float t = 0.0;
    bool hit = false;
    float lastD = 1e10;
    
    for (int i = 0; i < 48; i++) {
        float3 p = ro + rd * t;
        float d = mapScene(p, balls, params.ballCount, params.blendK);
        
        if (d < 0.003) {
            hit = true;
            break;
        }
        if (t > 25.0) break;
        
        lastD = d;
        t += max(d, 0.01);
    }
    
    // --- Wireframe mode: draw edges near the surface ---
    if (params.materialMode == 2) {
        // Wireframe: show grid lines near the surface
        if (!hit && lastD > 0.08) {
            if (params.bgMode == 3) return float4(params.bgR, params.bgG, params.bgB, 1.0);
            if (params.bgMode == 2) return float4(0.0, 1.0, 0.0, 1.0);
            float bg = (params.bgMode == 0) ? 1.0 : 0.0;
            return float4(bg, bg, bg, 1.0);
        }
        
        if (hit) {
            float3 p = ro + rd * t;
            float3 N = calcNormal(p, balls, params.ballCount, params.blendK);
            
            // Create grid pattern on surface using world-space coordinates
            float scale = 12.0;
            float3 sp = p * scale;
            float3 fw = fwidth(sp);
            float lineW = 1.2;
            
            // Grid lines along each axis pair
            float3 grid = abs(fract(sp - 0.5) - 0.5) / max(fw, 0.001);
            float line = min(min(grid.x, grid.y), grid.z);
            float wire = 1.0 - smoothstep(0.0, lineW, line);
            
            // Edge detection: highlight silhouette edges
            float3 V = normalize(ro - p);
            float edge = 1.0 - smoothstep(0.0, 0.3, abs(dot(N, V)));
            wire = max(wire, edge);
            
            float3 wireColor = float3(0.1);
            float3 fillColor = float3(0.97);
            float3 color = mix(fillColor, wireColor, wire);
            
            return float4(color, 1.0);
        }
        
        // Near-surface glow for wireframe
        return float4(1.0, 1.0, 1.0, 1.0);
    }
    
    // Non-wireframe modes: background if no hit
    if (!hit) {
        if (params.bgMode == 3) return float4(params.bgR, params.bgG, params.bgB, 1.0);
        if (params.bgMode == 2) return float4(0.0, 1.0, 0.0, 1.0);
        float bg = (params.bgMode == 0) ? 1.0 : 0.0;
        return float4(bg, bg, bg, 1.0);
    }
    
    // Hit point and normal
    float3 p = ro + rd * t;
    float3 N = calcNormal(p, balls, params.ballCount, params.blendK);
    float3 V = normalize(ro - p);
    
    // --- Lighting ---
    
    // Key light
    float3 L1 = normalize(float3(-1.0, 1.5, 2.0));
    float3 H1 = normalize(L1 + V);
    float NdotL1 = max(dot(N, L1), 0.0);
    
    // Fill light
    float3 L2 = normalize(float3(1.5, 0.5, 1.5));
    float3 H2 = normalize(L2 + V);
    float NdotL2 = max(dot(N, L2), 0.0);
    
    // Fresnel
    float fresnel = pow(1.0 - max(dot(N, V), 0.0), 5.0);
    
    // Environment reflection
    float3 refl = reflect(-V, N);
    
    // Environment reflection direction:
    // FREE  (0): reflection rotates with camera (world-space reflection)
    // FIXED (1): camera-local XZ but world-space Y (天地固定)
    // FRONT (2): fully camera-local (ENV center always faces camera)
    float3 envRefl;
    if (params.envLocked == 0) {
        // Camera-relative: use reflection as-is (world space = camera-locked)
        envRefl = refl;
    } else if (params.envLocked == 1) {
        // H-FIX: placeholder — handled in sampling below (like FRONT)
        envRefl = refl;
    } else {
        // Front: placeholder — FRONT mode samples directly below
        envRefl = refl;
    }
    float envUp = envRefl.y * 0.5 + 0.5;
    
    // Sample HDRI environment map if available
    bool hasEnvMap = (params.envMapIndex > 0);
    float3 envSample = float3(0.0);
    if (hasEnvMap) {
        if (params.envLocked == 1) {
            // H-FIX: based on FRONT, but horizontal rotation follows world space.
            // Vertical (theta) = camera-local Y → sky stays up regardless of camera tilt
            // Horizontal (phi) = world-space reflection → ENV rotates when camera pans
            float3x3 camMatInv = transpose(camMat);
            float3 local = normalize(camMatInv * refl);
            local.y = -local.y;  // correct reflection's Y-flip (same as FRONT)
            float theta = asin(clamp(local.y, -1.0, 1.0));
            // Horizontal angle from world-space reflection
            float phi = atan2(refl.x, refl.z);
            float2 hfixUV = float2(phi / (2.0 * M_PI_F) + 0.5,
                                   0.5 - theta / M_PI_F);
            envSample = envMap.sample(envSampler, hfixUV).rgb * params.envIntensity;
        } else if (params.envLocked == 2) {
            // FRONT: use reflection for natural env spread across surface,
            // but flip Y in camera-local space to correct mirror inversion.
            float3x3 camMatInv = transpose(camMat);
            float3 local = normalize(camMatInv * refl);
            local.y = -local.y;  // correct reflection's Y-flip so image appears upright
            float phi = atan2(local.x, local.z);              // -π..π, 0 = camera direction
            float theta = asin(clamp(local.y, -1.0, 1.0));   // -π/2..π/2
            float2 frontUV = float2(phi / (2.0 * M_PI_F) + 0.5,
                                    0.5 - theta / M_PI_F);
            envSample = envMap.sample(envSampler, frontUV).rgb * params.envIntensity;
        } else {
            envSample = sampleEnvMap(envRefl, envMap, envSampler) * params.envIntensity;
        }
    }
    
    // Cheap AO approximation: use dot(N,V) as a proxy instead of extra SDF evaluation
    float ao = mix(0.6, 1.0, max(dot(N, V), 0.0));
    
    float3 color;
    
    if (params.materialMode == 1) {
        // --- Mercury / Chrome: highly reflective silver ---
        float3 baseColor = float3(0.85, 0.87, 0.9);  // cool silver
        
        float spec1 = pow(max(dot(N, H1), 0.0), 400.0);
        float spec2 = pow(max(dot(N, H2), 0.0), 300.0);
        
        // Strong environment reflection for mercury look
        float3 envColor;
        if (hasEnvMap) {
            envColor = envSample;
        } else {
            envColor = mix(float3(0.3, 0.32, 0.35), float3(0.95), envUp * envUp);
        }
        
        // Mercury has very high Fresnel reflectance (metal)
        float metalFresnel = mix(0.7, 1.0, fresnel);
        
        float diffuse = NdotL1 * 0.15 + NdotL2 * 0.08;
        float specular = spec1 * 1.2 + spec2 * 0.6;
        
        color = baseColor * diffuse;
        color += float3(specular);
        color += envColor * metalFresnel * 0.6;
        color *= ao;
        
    } else if (params.materialMode == 3) {
        // --- Custom color mode ---
        float3 baseColor = hsv2rgb(params.colorHue, 1.0, params.colorBri);
        
        float spec1 = pow(max(dot(N, H1), 0.0), 200.0);
        float spec2 = pow(max(dot(N, H2), 0.0), 120.0);
        
        float3 envColor;
        float envMix;
        if (hasEnvMap) {
            // Tint HDRI with the custom color
            envColor = envSample * mix(float3(1.0), baseColor, 0.4);
            envMix = mix(0.3, 0.7, fresnel);  // visible even at center
        } else {
            envColor = mix(float3(0.08), float3(0.6), envUp * envUp);
            envMix = fresnel * 0.25;
        }
        
        float diffuse = NdotL1 * 0.5 + NdotL2 * 0.25;
        float specular = spec1 * 0.7 + spec2 * 0.35;
        
        color = baseColor * (0.15 + diffuse);
        color += float3(specular);
        color += envColor * envMix;
        color *= ao;
        
    } else if (params.materialMode == 4) {
        // --- Glass: transparent with refraction, Fresnel reflection, caustics ---
        float ior = 1.45;  // glass index of refraction
        
        // Fresnel: Schlick approximation
        float f0 = pow((1.0 - ior) / (1.0 + ior), 2.0);
        float glassF = f0 + (1.0 - f0) * pow(1.0 - max(dot(N, V), 0.0), 5.0);
        
        // Refracted ray through the glass body
        float3 refractDir = refract(-V, N, 1.0 / ior);
        
        // March a short distance through the interior to find the exit point
        float3 entryP = p;
        float3 innerRay = (length(refractDir) > 0.001) ? refractDir : -N;
        float innerT = 0.04;
        for (int j = 0; j < 16; j++) {
            float3 ip = entryP + innerRay * innerT;
            float id = mapScene(ip, balls, params.ballCount, params.blendK);
            if (id > 0.003) break;  // exited the surface
            innerT += max(-id, 0.005);
            if (innerT > 2.0) break;
        }
        float3 exitP = entryP + innerRay * innerT;
        float3 exitN = -calcNormal(exitP, balls, params.ballCount, params.blendK);
        
        // Second refraction at exit surface
        float3 exitRefract = refract(innerRay, exitN, ior);
        if (length(exitRefract) < 0.001) exitRefract = innerRay;  // total internal reflection fallback
        
        // Sample background/environment through the refracted ray
        float3 refractColor;
        if (hasEnvMap) {
            if (params.envLocked == 1) {
                // H-FIX: same as reflection — camera-local Y for theta, world XZ for phi
                float3x3 camMatInv = transpose(camMat);
                float3 localR = normalize(camMatInv * exitRefract);
                localR.y = -localR.y;
                float theta = asin(clamp(localR.y, -1.0, 1.0));
                float phi = atan2(exitRefract.x, exitRefract.z);
                float2 hfixUV = float2(phi / (2.0 * M_PI_F) + 0.5,
                                       0.5 - theta / M_PI_F);
                refractColor = envMap.sample(envSampler, hfixUV).rgb * params.envIntensity;
            } else if (params.envLocked == 2) {
                // FRONT: camera-local UV for refraction (same math as reflection)
                float3x3 camMatT = float3x3(camRight, camUp, camFwd);
                float3x3 camMatInv = transpose(camMatT);
                float3 localR = normalize(camMatInv * exitRefract);
                float phi = atan2(localR.x, -localR.z);
                float theta = asin(clamp(localR.y, -1.0, 1.0));
                float2 frontUV = float2(phi / (2.0 * M_PI_F) + 0.5,
                                        0.5 - theta / M_PI_F);
                refractColor = envMap.sample(envSampler, frontUV).rgb * params.envIntensity;
            } else {
                refractColor = sampleEnvMap(exitRefract, envMap, envSampler) * params.envIntensity;
            }
        } else {
            // Procedural background through refraction
            float bgVal = (params.bgMode == 0) ? 1.0 : 0.0;
            float3 bgColor = (params.bgMode == 2) ? float3(0.0, 1.0, 0.0)
                           : (params.bgMode == 3) ? float3(params.bgR, params.bgG, params.bgB)
                           : float3(bgVal);
            float upFactor = exitRefract.y * 0.5 + 0.5;
            refractColor = mix(bgColor * 0.8, bgColor, upFactor);
        }
        
        // Absorption: tint light passing through the interior (subtle blue-white)
        float thickness = innerT;
        float3 glassTint = exp(-float3(0.05, 0.02, 0.01) * thickness * 8.0);
        refractColor *= glassTint;
        
        // Reflection
        float3 reflColor;
        if (hasEnvMap) {
            reflColor = envSample;  // already computed with FRONT correction if needed
        } else {
            reflColor = mix(float3(0.15), float3(0.9), envUp * envUp);
        }
        
        // Specular highlights
        float spec1 = pow(max(dot(N, H1), 0.0), 500.0);
        float spec2 = pow(max(dot(N, H2), 0.0), 350.0);
        float specular = spec1 * 1.5 + spec2 * 0.8;
        
        // Combine: Fresnel blend of reflection and refraction + specular
        color = mix(refractColor, reflColor, glassF);
        color += float3(specular);
        color *= ao;
        
    } else {
        // --- Default: black glossy ---
        float3 baseColor = float3(0.02);
        
        float spec1 = pow(max(dot(N, H1), 0.0), 200.0);
        float spec2 = pow(max(dot(N, H2), 0.0), 120.0);
        
        float3 envColor;
        float envMix;
        if (hasEnvMap) {
            envColor = envSample;
            envMix = mix(0.35, 0.8, fresnel);  // strong reflection on dark surface
        } else {
            envColor = mix(float3(0.08), float3(0.6), envUp * envUp);
            envMix = fresnel * 0.35;
        }
        
        float diffuse = NdotL1 * 0.12 + NdotL2 * 0.06;
        float specular = spec1 * 0.9 + spec2 * 0.45;
        
        color = baseColor + float3(diffuse);
        color += float3(specular);
        color += envColor * envMix;
        color *= ao;
    }
    
    color = clamp(color, float3(0.0), float3(1.0));
    
    return float4(color, 1.0);
}
