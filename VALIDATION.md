# Validation — 2026-10-26

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
