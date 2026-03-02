#!/usr/bin/env python3
"""Generate ground-truth reference renders in Mitsuba 3.

Renders canonical scenes matching test/test_cross_renderer.jl exactly.
Outputs raw float32 binary (for Julia comparison) and PNG (for inspection).

Usage: .mitsuba-env/bin/python3 scripts/mitsuba_reference.py
"""
import os, sys, time
import numpy as np

# ---------------------------------------------------------------------------
# Mitsuba setup
# ---------------------------------------------------------------------------
import mitsuba as mi
mi.set_variant('scalar_rgb')

OUT = os.path.join(os.path.dirname(__file__), '..', 'test', 'fixtures', 'mitsuba_reference')
SHOWCASE = os.path.join(os.path.dirname(__file__), '..', 'showcase', 'benchmarks')
os.makedirs(OUT, exist_ok=True)
os.makedirs(SHOWCASE, exist_ok=True)

# ---------------------------------------------------------------------------
# Canonical parameters — MUST match test_cross_renderer.jl
# ---------------------------------------------------------------------------
RES     = 256
SPP     = 4096
RADIUS  = 10.0
SIGMA_T = 1.0
CAM_Z   = 40.0
FOV     = 40.0

def save_bin(pixels: np.ndarray, path: str):
    """Save HxWx3 float32 array with 12-byte header (H, W, C as uint32 LE)."""
    h, w, c = pixels.shape
    with open(path, 'wb') as f:
        f.write(np.array([h, w, c], dtype=np.uint32).tobytes())
        f.write(pixels.astype(np.float32).tobytes())

def save_png(pixels: np.ndarray, path: str):
    """Save as 8-bit sRGB PNG via Mitsuba's bitmap."""
    bmp = mi.Bitmap(pixels)
    bmp = bmp.convert(mi.Bitmap.PixelFormat.RGB, mi.Struct.Type.UInt8, True)
    bmp.write(path)

def render_scene(desc: dict, name: str, spp: int = SPP):
    """Render, save .bin + .png, print timing."""
    t0 = time.time()
    scene = mi.load_dict(desc)
    img = mi.render(scene, spp=spp)
    pixels = np.array(img, copy=False).astype(np.float32)
    dt = time.time() - t0

    save_bin(pixels, os.path.join(OUT, f'{name}.bin'))
    save_png(pixels, os.path.join(OUT, f'{name}.png'))
    # Also save a showcase PNG
    save_png(pixels, os.path.join(SHOWCASE, f'mitsuba_{name}.png'))

    avg = float(pixels.mean())
    print(f'  {name}: {dt:.1f}s  avg={avg:.4f}  shape={pixels.shape}')
    return pixels

# ---------------------------------------------------------------------------
# Shared scene components
# ---------------------------------------------------------------------------
def perspective_sensor(spp_hint=SPP):
    return {
        'type': 'perspective',
        'to_world': mi.ScalarTransform4f.look_at(
            origin=[0, 0, CAM_Z], target=[0, 0, 0], up=[0, 1, 0]),
        'fov': FOV,
        'film': {'type': 'hdrfilm', 'width': RES, 'height': RES,
                 'pixel_format': 'rgb',
                 'component_format': 'float32',
                 'rfilter': {'type': 'box'}},  # box filter = no pixel bleed
        'sampler': {'type': 'independent', 'sample_count': spp_hint},
    }

def fog_sphere(sigma_t=SIGMA_T, albedo=0.8, phase_type='isotropic', phase_g=0.0):
    """Homogeneous fog sphere with null BSDF boundary."""
    phase = {'type': phase_type}
    if phase_type == 'hg':
        phase['g'] = phase_g
    return {
        'medium_fog': {
            'type': 'homogeneous',
            'sigma_t': sigma_t,
            'albedo': {'type': 'rgb', 'value': [albedo, albedo, albedo]},
            'phase': phase,
        },
        'sphere': {
            'type': 'sphere',
            'radius': RADIUS,
            'bsdf': {'type': 'null'},
            'interior': {'type': 'ref', 'id': 'medium_fog'},
        },
    }

def directional_light(direction=(0, 0, -1), irradiance=(1, 1, 1)):
    """Directional emitter. Direction = light travel direction (toward scene)."""
    return {
        'type': 'directional',
        'direction': list(direction),
        'irradiance': {'type': 'rgb', 'value': list(irradiance)},
    }

# ---------------------------------------------------------------------------
# Scene A: Single scatter
# ---------------------------------------------------------------------------
print('=== Scene A: Single Scatter ===')
scene_a = {
    'type': 'scene',
    'integrator': {'type': 'volpath', 'max_depth': 2},  # direct + 1 scatter
    'sensor': perspective_sensor(),
    'light': directional_light(),
    **fog_sphere(sigma_t=SIGMA_T, albedo=0.8),
}
render_scene(scene_a, 'scene_A_single_scatter')

# ---------------------------------------------------------------------------
# Scene B: Multi scatter (albedo=1.0, unlimited depth)
# ---------------------------------------------------------------------------
print('=== Scene B: Multi Scatter ===')
scene_b = {
    'type': 'scene',
    'integrator': {'type': 'volpath', 'max_depth': -1, 'rr_depth': 5},
    'sensor': perspective_sensor(),
    'light': directional_light(),
    **fog_sphere(sigma_t=SIGMA_T, albedo=1.0),
}
render_scene(scene_b, 'scene_B_multi_scatter')

# ---------------------------------------------------------------------------
# Scene C: White furnace (constant environment, albedo=1.0)
# ---------------------------------------------------------------------------
print('=== Scene C: White Furnace ===')
scene_c = {
    'type': 'scene',
    'integrator': {'type': 'volpath', 'max_depth': -1, 'rr_depth': 5},
    'sensor': perspective_sensor(),
    'env_light': {
        'type': 'constant',
        'radiance': {'type': 'rgb', 'value': [1.0, 1.0, 1.0]},
    },
    **fog_sphere(sigma_t=SIGMA_T, albedo=1.0),
}
render_scene(scene_c, 'scene_C_white_furnace')

# ---------------------------------------------------------------------------
# Scene D: HG phase function sweep
# ---------------------------------------------------------------------------
print('=== Scene D: HG Phase Sweep ===')
for g in [0.0, 0.3, 0.7, 0.9]:
    name = f'scene_D_hg_g{g:.1f}'.replace('.', 'p')
    scene_d = {
        'type': 'scene',
        'integrator': {'type': 'volpath', 'max_depth': 2},
        'sensor': perspective_sensor(),
        'light': directional_light(),
        **fog_sphere(sigma_t=SIGMA_T, albedo=0.8, phase_type='hg', phase_g=g),
    }
    render_scene(scene_d, name)

print('\n=== Done ===')
print(f'Reference renders: {OUT}')
print(f'Showcase PNGs:     {SHOWCASE}')
