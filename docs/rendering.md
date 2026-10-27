# Rendering and model enhancements

The game screenshots were inspected locally, including March 7th, Phainon and
Sparxie. They show stylized light/dark regions on clothing as well as the head.
Still images do not establish the original engine's complete shadow algorithm.

References read:

- [Unity cartoon rendering notes](https://zhuanlan.zhihu.com/p/711037262):
  separate body/hair lighting controls, remapped Lambert response, face-local
  angular SDF evaluation, artist-authored Ramp colors, nose marks and stencil
  layering for bangs. The article describes a recreation, not an official shader.
- [StarToon SRS](https://github.com/XIEYUANSHEN/startoon-srs): per-category
  lighting and layered eye visibility. It is a Blender implementation; its code
  and assets are not included in this MIT runtime.
- [Godot spatial shaders](https://docs.godotengine.org/en/4.7/tutorials/shaders/shader_reference/spatial_shader.html):
  transparent-pass stencil reads/writes and render ordering. This application
  targets the pinned Godot 4.7 Windows renderer; stencil support is experimental
  upstream.

## Runtime behavior

The enhancement switch is enabled by default. Body/cloth use broad two-tone
normal bands without hard self-cast shadow patches. Hair and the upper face
retain controlled projected shadows; the lower face does not use lip, chin or
nose surface normals to generate a curved shadow. Data maps are sampled in
linear space; source colors and Ramp textures are sampled as color data.

Missing face data is approximated from this model's face geometry and UVs.
Horizontal cheek profiles generate paired angular thresholds for left/right
lighting. A nose mark is derived from the actual central protrusion, baked into
UV space and drawn only near frontal views. Hair highlight masks follow the
model's head-relative geometry and original UVs. These 128-pixel helper maps
are cached by geometry, UVs, topology and generator version. They are
SDF-style lighting thresholds, not a reconstruction of the original hand-painted
FaceMap. Artist maps should be supplied for exact expression of character style.
The automatic face thresholds use head-space side selection to support mirrored
facial UVs. Atlases tiled outside 0–1 fall back to the basic field instead of
using a clipped generated map; user-supplied maps remain available.

Face-opening topology produces an outline mask in the otherwise unused red
vertex channel; the PMX alpha edge weight, triangle topology, normals, UVs and
morph deltas remain unchanged. The outline shell is suppressed around internal
openings while the external face silhouette is preserved.

Eye transparency is disabled by default. A depth-tested, zero-color hair pass
writes a stencil mask; the eye-detail overlay reads it later. Only visible hair
pixels qualify. Opaque foreground geometry still occludes the result; frontal-angle
gating prevents eyes showing through the rear of the head. Eyewhites and mouth
materials are excluded. Custom names may still need material-classification
adaptation.

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
