# Rendering and model enhancements

The game screenshots were inspected locally, including March 7th, Phainon and
Sparxie. They show stylized light/dark regions on clothing as well as the head.
Still images do not establish the original engine's complete shadow algorithm.

References read:

- [Honkai 3rd toon lighting breakdown](https://zhuanlan.zhihu.com/p/120908528):
  LightMap channels separate shadow thresholds from specular masks.
- [URP Genshin recreation notes](https://zhuanlan.zhihu.com/p/699682089):
  color/data texture handling, Ramp sampling, face SDF and outline masks. Its
  example does not implement general shadow reception or multiple lights.
- [Unity cartoon rendering notes](https://zhuanlan.zhihu.com/p/711037262):
  separate body/hair lighting controls, remapped Lambert response, face-local
  angular SDF evaluation, artist-authored Ramp colors, nose marks and stencil
  layering for bangs. The article describes a recreation, not an official shader.
- [Godot spatial shaders](https://docs.godotengine.org/en/4.7/tutorials/shaders/shader_reference/spatial_shader.html):
  transparent-pass stencil reads/writes and render ordering. This application
  targets the pinned Godot 4.7 Windows renderer; stencil support is experimental
  upstream.

## Runtime behavior

The main light has a fixed world-space azimuth of 20 degrees and elevation of
48.4 degrees. Camera orbit, actor movement and actor rotation do not move the
light. Direction/elevation sliders and automatic light rotation are removed;
the shadow toggle and light/dark threshold control remain available.

The enhancement switch is enabled by default. All characters use the same
material rules and authored inputs. Diffuse colors, outline pigments, character
names and head height do not select shadow-color or threshold compensation.
Mesh normals are retained; there is no crown-normal replacement or guessed
neck/chest shadow exemption.

Body, skin, hair and metal use half-Lambert, with LightMap G shifting the
threshold and R multiplying the resulting illumination. The default UI value
0.30 means a half-Lambert threshold of 0.5, independent of material pigment.
Normal-band softness is 0.025; face SDF softness is 0.015, both with a derivative
minimum for raster antialiasing. Directional projected visibility limits the
normal band separately, so clothing receives occluder shadows. Point/spot lights
retain their distance attenuation and source receive-shadow flags.

Authored cold/warm Ramps sample x = 0.75 + 0.25 * illumination. Body rows use
eight equal LightMap alpha bands; hair uses one row. This row convention must
match the supplied asset (the reference article leaves row decoding unspecified).
Light elevation blends the cold/warm colors. R is not multiplied into direct
light a second time after the Ramp. PMX Toon and Sphere inputs remain intact;
a supplied Ramp takes precedence over Toon. Without either, a shared category
palette supplies the shadow tone, without inferring hues or folds from diffuse
colors. Source textures and meshes remain unchanged.

Enhanced materials now receive Godot environment diffuse irradiance, with
LightMap R controlling ambient AO as 0.5 + 0.5 * R. FaceMap R selects face skin
versus feature regions; G supplies feature AO. The studio uses a flat white
ambient term of 0.15 and key energy 0.85 for consistent transparent-background
output. This is a flat environment approximation, not a reconstruction of the
game's SH coefficients; sky environments can supply directional irradiance.
Basic mode retains the original PMX lighting path. Full-bright mode suppresses
ambient and direct light, preserving texture/diffuse and additive Sphere output.

Face lighting stays in head-local coordinates and uses authored SDF when
available. Geometric fallback maps remain approximations. The generic eye-height
mask limits projected shadow reception to the upper face, preserving the SDF
shape below it; skin below the head receives ordinary projected shadows.

The character studio uses an 8192-pixel orthogonal directional shadow atlas over
14 metres, preserving the camera's 12-metre zoom range while reducing close-up
cascade transitions and projected-edge stair steps. GPU compatibility and memory
optimization have not been addressed in this visual-fidelity pass.

Missing face data is approximated from this model's face geometry and UVs.
Horizontal cheek profiles generate paired angular thresholds for left/right
lighting. A nose mark is derived from the actual central protrusion, baked into
UV space and drawn only near frontal views. Hair highlight masks follow the
model's head-relative geometry and original UVs. These 128-pixel helper maps
are cached by geometry, UVs, topology and generator version. They are
SDF-style lighting thresholds, not a reconstruction of the original hand-painted
FaceMap. Artist maps should be supplied for exact expression of character style.
The automatic face thresholds use head-space side selection to support mirrored
facial UVs. Head-local height aligns contact-shadow reception with valid eye rest
bones, or the face bounds when those landmarks are unavailable. This region is
independent of atlas overlap and protects lips/chin without removing nose marks.
Atlases tiled outside 0–1 or with no rasterizable triangles fall back to the basic field instead of
using a clipped generated map; user-supplied maps remain available.

Face-opening topology produces an outline mask in the otherwise unused red
vertex channel; the PMX alpha edge weight, triangle topology, normals, UVs and
morph deltas remain unchanged. The outline shell is suppressed around internal
openings while the external face silhouette is preserved.
Outline width is expressed in output pixels for both perspective and orthographic
cameras. The video-calibrated default is 2.6 pixels before each material's edge
scale and vertex weight. Enhanced lines use the original material texture/diffuse color; the PMX
outline-color switch retains the source edge color and opacity.

Eye transparency is disabled by default. A depth-tested, zero-color hair pass
writes a stencil mask; the eye-detail overlay reads it later. Only visible hair
pixels qualify. Opaque foreground geometry still occludes the result; frontal-angle
gating prevents eyes showing through the rear of the head. Eyewhites and mouth
materials are excluded. Custom names may still need material-classification
adaptation.
Solid eye/oral materials retain authored cast-shadow flags so facial openings
do not leak light onto the neck. Enhanced brow/lash cards do not cast extra
thin-layer shadows. Enhancement changes invalidate static point-light shadow
caches without changing the mesh's original shadow setting.

## Optional user maps

Choose a material and role in Model → Enhanced textures. FaceMap RGBA and
standalone grayscale SDF are separate roles. For FaceMap, R is the facial
region mask, G occlusion, B nose marks and A SDF. A standalone SDF overrides
the FaceMap SDF channel; FaceMap still supplies its other channels. User SDF
sampling mirrors U for opposite light directions, so the supplied atlas must
match that convention as well as the model's UVs.

Body/hair LightMap uses R for occlusion, G for the light threshold, B for
specular response and A for material bands. The eight equal alpha bands select
body Ramp rows; hair uses one row. Cold/warm Ramp inputs are optional and use
the source light elevation. Grayscale highlight masks override generated masks.
LightMap R controls the direct Ramp coordinate and the separate ambient AO term.
This convention must match the supplied art; arbitrary textures cannot be
automatically interpreted as matching lighting maps.

Imported images are copied as PNG into the current user's cache, with a
content hash. Assignment JSON is keyed by archive/model identity and material
ID. Moving the external source image does not break the assignment. Removing
an override restores generated data or the basic scheme; turning enhancement
off bypasses all auxiliary lighting maps. No character or generated user map
is included in the repository or distribution.

## Physics boundaries

The host keeps authored PMX rigid bodies and joints. Optional hair assistance
fits terminal hair-chain convex proxies to weighted mesh sections, adds
hair-only kinematic clothing envelopes and allows appropriate hair/dynamic-cloth
contacts. Turning it off restores authored proxy shapes and masks. Initial
overlap between same-group cloth boxes is detected with separating axes;
excluding these impossible rest contacts prevents persistent cape lift.

These are rigid proxy improvements, not a triangle-level cloth solver.
Thin sheets, blended skinning between bones, authored overlaps, very fast
motion and models without useful physical bones can retain intersections.

## Generic shadow verification (2026-10-31)

`tests/test_generic_shadow.gd` checks actual GPU pixels for Ramp coordinates,
material rows, LightMap R, pigment independence, environment AO and full-bright.
`tests/capture_shadow_models.gd` accepts a PMX path and output directory; it uses
the same 0.30 threshold, studio lighting and views for every model. Run GPU
checks serially. Captures are visual evidence, not a pixel-matched game benchmark.
Original game LightMap/FaceMap/Ramp assets were not supplied for these PMX models;
matching their artistic shadow boundaries remains limited by that missing data.
