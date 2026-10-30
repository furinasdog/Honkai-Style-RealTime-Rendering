# Rendering and model enhancements

The game screenshots were inspected locally, including March 7th, Phainon and
Sparxie. They show stylized light/dark regions on clothing as well as the head.
Still images do not establish the original engine's complete shadow algorithm.

References read:

- [Unity cartoon rendering notes](https://zhuanlan.zhihu.com/p/711037262):
  separate body/hair lighting controls, remapped Lambert response, face-local
  angular SDF evaluation, artist-authored Ramp colors, nose marks and stencil
  layering for bangs. The article describes a recreation, not an official shader.
- [Godot spatial shaders](https://docs.godotengine.org/en/4.7/tutorials/shaders/shader_reference/spatial_shader.html):
  transparent-pass stencil reads/writes and render ordering. This application
  targets the pinned Godot 4.7 Windows renderer; stencil support is experimental
  upstream.

## Runtime behavior

The enhancement switch is enabled by default. Cloth uses broad two-tone
normal bands without hard self-cast shadow patches. Skin, hair and the upper face
retain controlled projected shadows; the lower face does not use lip, chin or
nose surface normals to generate a curved shadow. Data maps are sampled in
linear space; source colors and Ramp textures are sampled as color data.

Native PMX Toon and Sphere textures are retained. In enhanced mode, the material
category palette can blend with a PMX Toon shadow color; disabling enhancement
restores its original light/shadow ratio. Sphere multiplication and addition
preserve the original material operation. Shared Toon indices without external
images use the runtime's category fallback. User warm/cool Ramps override the
category palette. Enhancement brightens pale faces and hair, adds contrast to
colored cloth, and limits broad shadows on near-white cloth without erasing
medium-strength authored Toon shading.
Without custom cloth maps, source hue and brightness deepen blue painted folds,
gently reduce cyan in bright blue fabric while leaving very dark blue details
intact, soften bright pink fabric, and slightly lift near-neutral pale fabric
highlights. User Ramps bypass these approximate adjustments.
The balance scales its lift by remaining highlight headroom: black and white
endpoints remain unchanged, rather than clipping bright hair or white garments.
The source textures remain unchanged. Turning enhancement off keeps original
PMX material inputs and bypasses generated lighting details and fallback grading.
Hair combines normal lighting and shadow visibility before a single two-tone
decision, including partial projected-shadow visibility.
The enhanced half-Lambert body threshold is near N.L = 0 at the default slider
setting; pale fallback cloth lowers that threshold so the white chest retains
small angular folds instead of a broad horizontal dark band. The basic PMX path
keeps its original N.L threshold. Fallback pale pink hair uses its source hue
and head-relative height to deepen lower strands without tinting neutral white
hair; authored LightMaps and Ramps bypass this adjustment. Rear neck skin
rejects hair cast shadow while frontal contact shadows remain active.

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
LightMap R occlusion is applied after palette selection, including user Ramps.
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
