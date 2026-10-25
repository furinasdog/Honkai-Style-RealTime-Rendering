"""Run only inside Blender: export must preserve coincident MMD material faces."""
import json
from pathlib import Path
import runpy
import struct
import sys

import bpy

args = sys.argv[sys.argv.index("--") + 1:]
output = Path(args[0])
output.mkdir(parents=True, exist_ok=True)
for obj in list(bpy.context.scene.objects):
    bpy.data.objects.remove(obj, do_unlink=True)
mesh = bpy.data.meshes.new("CoincidentMaterialFaces")
mesh.from_pydata([(0, 0, 0), (1, 0, 0), (0, 1, 0), (1, 1, 0)], [], [(0, 1, 2), (2, 1, 0), (1, 3, 2)])
obj = bpy.data.objects.new("Fixture", mesh)
bpy.context.scene.collection.objects.link(obj)
for name in ("Outside", "Inside"):
    mesh.materials.append(bpy.data.materials.new(name))
mesh.polygons[1].material_index = 1
obj.shape_key_add(name="Basis")
obj.shape_key_add(name="Expression").data[0].co.z = 0.1
kwargs = dict(filepath=str(output / "fixture.glb"), export_format="GLB", export_animations=False)
if "--baseline" in args:
    bpy.ops.export_scene.gltf(**kwargs)
else:
    worker = runpy.run_path(str(Path(__file__).resolve().parents[1] / "tools/import_pmx_blender.py"))
    worker["export_preserving_faces"](kwargs)
blob = (output / "fixture.glb").read_bytes()
length = struct.unpack_from("<I", blob, 12)[0]
doc = json.loads(blob[20:20 + length])
count = sum(doc["accessors"][p["indices"]]["count"] // 3 for m in doc["meshes"] for p in m["primitives"])
assert count == 3 and len(mesh.polygons) == 3, "Exporter deleted coincident material faces"
assert len(doc["meshes"][0]["weights"]) == 1, "Expression morph must survive"
print("IMPORT_TOPOLOGY_PASS triangles=3 coincident_materials=true morphs=1")
