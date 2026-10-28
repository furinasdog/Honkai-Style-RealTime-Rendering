# Validation

## 1.0.0

Windows x64, Godot 4.7.2, RTX 5070 Laptop / D3D12. Checks use isolated user
profiles. No real camera or OBS receiver is opened, and private model assets
and diagnostics are excluded from the published source and package.

Regression checks cover:

- Transient arm/palm loss holds the last valid target for 150 ms, sustained
  loss releases to neutral, reacquisition resumes, and disabling a channel or
  resetting cannot retain the held pose.
- Partial face rigs use a combined blink without also adding the remaining
  unilateral blink. Degenerate palm frames are not reported as tracked.
- Failed lighting-map writes/removals preserve both the previous in-memory
  assignment and existing JSON. Successful writes replace a temporary file.
- Full native inference → decode → camera correction → actual retarget replay
  on 72 offline fixture frames, including horizontal mirrors and -35/0/+35
  degree camera correction, followed by loss recovery. This checks numerical
  integrity and integration, not webcam accuracy or a motion-capture FPS claim.
- Hu Tao, Phainon, March 7th and Cyrene arm/finger and actual skinned-leg
  regressions, including the three weighted leg chains in the Hu Tao fixture.
  Full-body/physics replay retains the existing model-specific support offset.
- Basic and enhanced toon palettes are checked separately: basic cloth retains
  cast shadows; enhanced cloth omits hard self-cast patches. Both retain source
  colors and the full-bright toggle. Face bands, manual/generated helper maps,
  eye stencils, UI scaling and transparent output are covered by GPU tests.
- Native parser CTest, archive path/collision/limit/cancellation checks, import
  rollback, and filtered portable ZIP checksum verification.

The final production scripts completed a 600-second D3D12 stress run with
7 model installations and 11,239 native fixture-inference frames, minimized
1080p transparent output, mode/gesture/enhancement/eye/shadow switches, finite
bone transforms and stable scene-node counts on repeated visits to each model.
The previous output-camera interpolation warning no longer appeared. A further
120-second run replaced models 8 times while the same Spout sender stayed active.
These deliberately synchronous inference probes are stability checks, not camera
tracking-accuracy or representative rendering-throughput benchmarks.

The ZIP was extracted into a new path containing Chinese characters and spaces.
The official release executable passed empty-startup and private-model startup
checks. An editor test host opened the executable's embedded PCK and its relocated
native DLLs to exercise actual packed PMX, Full inference, enhancement and GPU
transparent output; this is distinct from injecting tests into the release EXE.
Fresh Hysilens/Cyrene ZIP imports also succeeded through these packed components
and isolated caches, without relying on an existing user's imported model.

The renderer preserved source colors and the nose in the inspected packed-output
screenshot. This was a local visual check, not a new official-reference similarity
score. Offline test images have an optional, checksum-pinned download manifest;
they are not bundled in the release.

The previous thin-sheet crossing limitation below remains unresolved. A 1.0
version does not imply perfect monocular depth, official-renderer equivalence,
universal PMX effect support, or zero mesh intersections.

## 0.1.5 supplement

Windows x64, Godot 4.7.2, RTX 5070 Laptop, Forward+ / D3D12.
No real camera or OBS application was opened.

Passed:

- GPU eye-overlay test: disabled/enabled, visible-hair stencil, opaque foreground
  occlusion, and head-facing gate without relying on back-face culling.
- GPU user-map test: black/white SDF changes rendered face pixels, imported Ramp
  produces its source color, and disabling enhancement restores source color.
- Generated face-map GPU test: mirrored UV halves exchange light/dark under
  opposite side lights, both brighten from the front and darken from behind.
  Light interpolation is disabled and stable frames are sampled in this test.
- Lazy geometric map generation, mirrored face UV thresholds, cached image
  assignment, moved external source, removal and malformed-setting fallback.
- Face-opening outline mask preserves outer silhouette, source alpha edge
  weights, vertices and indices. Private close-ups were inspected with closed,
  partial and open mouth morphs; the nose and its cartoon mark remain visible.
- Cloth rest-contact exclusion, thin/zero-thickness box separation, hair
  assistance toggling, original collision/reset tests and import rollback.
- Native model physics stability on Hu Tao, Phainon, March 7th and Cyrene.
  Full-body/physics replay on Hu Tao, Phainon and Cyrene covers crouch, turn,
  leg movement and mode/recenter resets. Ongoing root offsets are compared with
  each model's static support calibration; Hu Tao's 3.142 mm standing offset
  was identical with original and updated physics, rather than a new drift.
- Light UI at 100/150/200 percent, including the auxiliary texture window.
- The exported official-template executable also loads a private model with
  enhancement and eye overlay enabled, creates its helper maps and renders
  without script or shader errors in an isolated profile.
- 1080p transparent Spout sender output with a real local character:
  60.0 measured FPS for a 60 FPS target in this local run. This is not OBS
  receiver verification or a promise for all hardware/models.

Private same-motion GPU probes:

| Measurement | Before | Updated |
|---|---:|---:|
| Hu Tao sampled maximum solid penetration | 44.51 mm | 0.00 mm |
| Hu Tao thin-mesh crossing-face observations across 25 samples | 682 | 106 |
| Phainon largest settled cape-bone displacement from rest | 646.14 mm | 135.59 mm |

The stricter zero-mesh-crossing probe remains **red**: the updated run includes
42 cloth and 64 hat/strap face-crossing observations. Zero sampled solid depth
does not imply zero thin-sheet intersection. It is not counted as a passing
zero-clipping test. Rigid proxy contacts and ordinary linear skinning still
have limits; the automatic lighting helpers are not official artist maps.

## Earlier baseline — 2026-10-26

Environment: Windows x64, Godot 4.7.2, Visual Studio 2026, NVIDIA RTX 5070 Laptop.
No live webcam was opened during this validation. Private model assets, reference
images, user profiles and rendered character screenshots are not published.

## Import and rendering

ZIP extraction and native PMX loading completed without Blender/helper processes:

| Local regression model | Preserved triangles | Source bones | Physics bodies |
|---|---:|---:|---:|
| Hysilens | 58,896 | 432 | 320 |
| Cyrene | 36,999 | 493 | 368 |
| Fu Hua | 41,879 | 909 | 768 |
| Sparxie variant 1 | 50,150 | 332 | 220 |
| Sparxie variant 2 | 53,976 | 332 | 220 |
| March 7th | 28,039 | 371 | 269 |

The first five cases exercised ZIP selection through `test_native_importer.gd`;
March 7th used an existing verified archive. All six exercised runtime meshes,
retarget binding, Jolt physics, neutral/head-tilt/arm poses and visible rendered
output. Close-up screenshots were manually inspected locally. The toon shader
was compared visually with game-reference images; this is not a pixel-identical
rendering claim or proof for every MMD model.

Corrected failure causes: face material aliases including 颜/顏/顔; clothing names
containing 肌; forced double-sided rendering that exposed purple back linings;
and source geometry/material loss in the prior conversion path. The default
path now reads PMX directly and preserves every source triangle. A synthetic
front/back color test checks the lining regression independently of characters.

## Application and output

- Parser CTest passed: UTF-8 Chinese, malformed header, truncated data and bounds.
- Godot regressions passed: native frame adapter, mapping settings, out-of-frame
  rejection, retargeting, video preview, app/stage settings and Blender camera.
- UI render tests passed at 720p/1080p/1440p and 150% UI scale: native pixels,
  transparent display, opaque navigation, retained title bar, empty startup.
- Transaction test preserved the active character after a malformed PMX failed.
- Native Spout receiver verified actual RGBA GPU sharing: opaque RGB regions,
  approximately 50% green alpha and zero-alpha background at 1280×720.
- Cyrene with 368 bodies / 572 joints output 1920×1080 Alpha video at approximately
  58 FPS after shader-cache warmup, targeting 60. First cold-cache samples were
  lower; this is one machine/model, not a general performance guarantee.
- Fu Hua physics stability/contact test passed: 120 Hz, 768 bodies / 1,244 joints,
  hair/head contact, finite transforms, retained motion response. Cloth angular
  speed P95 after settling was approximately 0.018 rad/s in this test.
- Exported Release EXE started empty and loaded Cyrene, Fu Hua and Sparxie from
  isolated local caches without errors. Default Release has no Blender runtime.
- Fresh dependency bootstrap downloaded pinned official artifacts and verified
  both DLLs and all three Tasks models without installing/running Python.
- ZIP contents and SHA-256 manifest were checked file by file.

Not checked: live webcam capture in this run, OBS plugin end-to-end reception,
other C++ compilers/platforms, every MMD constraint/effect, or every user model.
See loader UPSTREAM.md for SDEF/QDEF, advanced morph and soft-body limitations.

## v0.1.1 shadow regression

The v0.1.0 visual checks missed the lip/chin shading problem during mouth
morphs and high lighting. A minimal render with a uniform white face and
downward-facing lower-face normals reproduced it: upper green intensity 1.00,
lower intensity approximately 0.91 under frontal light. Disabling projected
shadows did not remove it; disabling the face's normal-based chin branch did.

The face now uses only the head-local two-tone field, with no lip/chin normal
shading or face rim light. Smooth tonal masks were replaced by pixel-width
antialiasing boundaries. The regression renders the actual material shader and
checks equal frontal tones, retained backlighting, and no more than two edge
pixels between the two side-lit tones. It passes after failing on v0.1.0.

Local Cyrene, March 7th and Sparxie captures cover an open mouth, six head pitch
angles, light elevations 5/35/60/85 degrees, and side/back light. No live webcam
or private character asset is required by the synthetic regression test.
Neck-material aliases were also corrected so a material named 脖子 uses the
skin shadow palette, while neck accessories retain their clothing category.
