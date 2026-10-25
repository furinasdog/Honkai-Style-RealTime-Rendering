"""Blender-only PMX conversion worker; never executes archive scripts or reads external textures."""
import argparse
import json
import inspect
import math
from pathlib import Path
import struct
import sys

import bpy
from mathutils import Euler, Matrix, Vector


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--pmx", required=True, type=Path)
    parser.add_argument("--cache-root", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--final-dir", required=True, type=Path)
    parser.add_argument("--mmd-tools-dir", type=Path)
    return parser.parse_args(argv if argv is not None else sys.argv[sys.argv.index("--") + 1:])


def category(name):
    value = name.casefold()
    if any(part in value for part in ("眼", "瞳", "眉", "口腔", "牙", "睫", "eye", "lash", "brow", "teeth")):
        return "eye"
    if any(part in value for part in ("脸", "顔", "face")):
        return "face"
    if any(part in value for part in ("发", "髪", "hair")):
        return "hair"
    if any(part in value for part in ("肌", "皮肤", "皮膚", "skin", "手", "腿", "body")) and not any(part in value for part in ("套", "环", "飾", "饰", "袋", "glove")):
        return "skin"
    if any(part in value for part in ("金属", "金屬", "metal")):
        return "metal"
    return "cloth"


def export_preserving_faces(kwargs):
    # Blender's validator deletes coincident PMX faces even when their materials differ.
    # shortcut: this guarded Blender 4.5 exporter seam needs updating if its validation call changes.
    from io_scene_gltf2.blender.exp import nodes
    original = nodes.__gather_mesh
    source = inspect.getsource(original)
    validation = "res = blender_object.data.validate()"
    if source.count(validation) != 1:
        raise ValueError("Blender glTF 导出器版本不兼容，无法保证 MMD 面片完整性")
    namespace = dict(original.__globals__)
    exec(compile(source.replace(validation, "res = False"), original.__code__.co_filename, "exec"), namespace)
    try:
        nodes.__gather_mesh = namespace[original.__name__]
        bpy.ops.export_scene.gltf(**kwargs)
    finally:
        nodes.__gather_mesh = original


def physics_metadata(source, model_scale, lowest):
    """PMX local coordinates -> the exact normalized GLB model coordinates."""
    unit = 0.08 * model_scale
    to_godot = Matrix(((1.0, 0.0, 0.0), (0.0, 0.0, 1.0), (0.0, -1.0, 0.0)))

    def position(value):
        return [float(value[0]) * unit, float(value[1]) * unit - lowest * model_scale, -float(value[2]) * unit]

    def rotation(value):
        # Same YXZ frame used by mmd_tools for rigid bodies and joints, then Blender -> glTF.
        blender = Euler((-float(value[0]), -float(value[2]), -float(value[1])), "YXZ").to_matrix()
        quaternion = (to_godot @ blender @ to_godot.transposed()).to_quaternion().normalized()
        return [quaternion.x, quaternion.y, quaternion.z, quaternion.w]

    bodies = []
    for index, rigid in enumerate(source.rigids):
        bone_index = rigid.bone if rigid.bone is not None else -1
        shape = {0: "sphere", 1: "box", 2: "capsule"}.get(rigid.type)
        if shape is None:
            raise ValueError("不支持的 PMX 刚体形状")
        size = [float(value) * unit for value in rigid.size]
        if shape == "sphere":
            size = [size[0], 0.0, 0.0]
        elif shape == "capsule":
            size = [size[0], size[1], 0.0]
        bodies.append({"name": rigid.name, "bone": source.bones[bone_index].name if 0 <= bone_index < len(source.bones) else "",
                       "bone_index": bone_index, "type": int(rigid.mode), "shape": shape, "size": size,
                       "position": position(rigid.location), "rotation": rotation(rigid.rotation),
                       "mass": float(rigid.mass), "linear_damping": float(rigid.velocity_attenuation),
                       "angular_damping": float(rigid.rotation_attenuation), "restitution": float(rigid.bounce),
                       "friction": float(rigid.friction), "collision_group": int(rigid.collision_group_number),
                       "collision_mask": (~int(rigid.collision_group_mask)) & 0xFFFF,
                       "pmx_collision_mask": int(rigid.collision_group_mask)})
    joints = []
    for joint in source.joints:
        low, high = joint.minimum_location, joint.maximum_location
        angular_low, angular_high = joint.minimum_rotation, joint.maximum_rotation
        joints.append({"name": joint.name, "type": int(joint.mode),
                       "body_a": int(joint.src_rigid) if joint.src_rigid is not None else -1,
                       "body_b": int(joint.dest_rigid) if joint.dest_rigid is not None else -1,
                       "position": position(joint.location), "rotation": rotation(joint.rotation),
                       "linear_lower": [float(low[0]) * unit, float(low[1]) * unit, -float(high[2]) * unit],
                       "linear_upper": [float(high[0]) * unit, float(high[1]) * unit, -float(low[2]) * unit],
                       "angular_lower": [-float(angular_high[0]), -float(angular_high[1]), float(angular_low[2])],
                       "angular_upper": [-float(angular_low[0]), -float(angular_low[1]), float(angular_high[2])],
                       "spring_linear": [float(value) for value in joint.spring_constant],
                       "spring_angular": [float(value) for value in joint.spring_rotation_constant]})
    result = {"version": 1, "coordinate_space": "normalized_model", "gravity": [0.0, -9.8, 0.0],
              "damping_model": "pmx_fraction", "unit_scale": unit, "ground_offset_y": -lowest * model_scale,
              "rigid_bodies": bodies, "joints": joints}
    # Fail in the converter instead of feeding invalid floats into the runtime physics server.
    json.dumps(result, allow_nan=False)
    for body in bodies:
        if any(value < 0.0 for value in body["size"]) or body["mass"] < 0.0 or body["type"] not in (0, 1, 2) or not 0 <= body["collision_group"] <= 15:
            raise ValueError("PMX刚体参数无效")
    for joint in joints:
        if any(index < -1 or index >= len(bodies) for index in (joint["body_a"], joint["body_b"])):
            raise ValueError("PMX关节刚体索引越界")
    return result


def main(argv=None):
    args = parse_arguments(argv)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    if args.mmd_tools_dir:
        addon_path = args.mmd_tools_dir.resolve()
        if not (addon_path / "__init__.py").is_file():
            raise ValueError("随包 MMD 导入插件不完整")
        sys.path.insert(0, str(addon_path.parent))
    else:
        # Development fallback uses Blender's active user profile, never a fixed account path.
        user_config = Path(bpy.utils.user_resource("CONFIG")).parent
        extension_path = user_config / "extensions/blender_org"
        if extension_path.is_dir():
            sys.path.insert(0, str(extension_path))
    import mmd_tools
    from mmd_tools.core import pmx
    mmd_tools.register()
    source = pmx.load(str(args.pmx))
    if not source.bones or len(source.vertices) < 3 or not source.faces:
        raise ValueError("PMX没有可用的骨骼或网格")
    if len(source.vertices) > 500000 or len(source.bones) > 4096 or len(source.materials) > 2048:
        raise ValueError("模型超过实时导入限制：50万顶点、4096骨骼或2048材质")
    if any(not math.isfinite(float(value)) for vertex in source.vertices for value in (*vertex.co, *vertex.normal, *vertex.uv, vertex.edge_scale)):
        raise ValueError("PMX包含非有限的顶点数据")
    if any(not math.isfinite(float(value)) for bone in source.bones for value in bone.location):
        raise ValueError("PMX包含非有限的骨骼数据")
    if any(any(index < 0 or index >= len(source.vertices) for index in face) for face in source.faces):
        raise ValueError("PMX面索引越界")
    additional_uv_count = max((len(vertex.additional_uvs) for vertex in source.vertices), default=0)
    if additional_uv_count > 4 or any(len(uv) != 4 or any(not math.isfinite(float(value)) for value in uv) for vertex in source.vertices for uv in vertex.additional_uvs):
        raise ValueError("PMX附加UV数量、维度或数值无效")
    cache_root = args.cache_root.resolve()
    archive_index = json.loads((cache_root / "archive_index.json").read_text(encoding="utf-8"))
    aliases = archive_index["aliases"]
    warnings = []

    def texture_path(requested):
        requested = str(requested).replace("\\", "/")
        candidate = (args.pmx.parent / requested).resolve()
        if candidate.is_relative_to(cache_root) and candidate.is_file():
            return candidate
        if candidate.is_relative_to(cache_root):
            aliased = aliases.get(candidate.relative_to(cache_root).as_posix().casefold())
            if aliased:
                target = (cache_root / aliased).resolve()
                if target.is_relative_to(cache_root) and target.is_file():
                    return target
        matches = {actual for alias, actual in aliases.items() if Path(alias).name.casefold() == Path(requested).name.casefold()}
        if len(matches) == 1:
            target = (cache_root / matches.pop()).resolve()
            if target.is_relative_to(cache_root) and target.is_file():
                return target
        return None

    textures = []
    for requested in source.textures:
        safe = texture_path(requested.path)
        if safe is None:
            warnings.append("贴图缺失或路径不安全：" + requested.path)
        textures.append(safe)
    # Sanitize before mmd_tools opens any texture, including sphere maps.
    for entry, path in zip(source.textures, textures):
        entry.path = str(path) if path else str(args.output_dir / "__missing_texture__.png")
    sanitized = args.output_dir / "sanitized.pmx"
    pmx.save(str(sanitized), source, add_uv_count=additional_uv_count)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    bpy.ops.mmd_tools.import_model(filepath=str(sanitized), types={"MESH", "ARMATURE", "MORPHS"}, scale=0.08,
                                   clean_model=False, remove_doubles=False, rename_bones=False,
                                   import_adduv2_as_vertex_colors=False, save_log=False)
    rigs = [obj for obj in bpy.context.scene.objects if obj.type == "ARMATURE"]
    if len(rigs) != 1:
        raise ValueError("PMX没有唯一可用的骨架")
    rig = rigs[0]
    meshes = [obj for obj in bpy.context.scene.objects if obj.type == "MESH" and obj.find_armature() == rig]
    if not meshes:
        raise ValueError("PMX没有绑定网格")
    rig.name = "Imported_Rig"
    rig.animation_data_clear()
    for bone in rig.pose.bones:
        bone.mmd_ik_toggle = False
        for constraint in list(bone.constraints):
            bone.constraints.remove(constraint)
        bone.matrix_basis = Matrix.Identity(4)
    for obj in meshes:
        obj.animation_data_clear()
        if obj.data.shape_keys:
            obj.data.shape_keys.animation_data_clear()
            for key in obj.data.shape_keys.key_blocks:
                key.value = 0.0
        for modifier in list(obj.modifiers):
            if modifier.type != "ARMATURE":
                obj.modifiers.remove(modifier)
    bpy.context.view_layer.update()
    world_positions = [obj.matrix_world @ vertex.co for obj in meshes for vertex in obj.data.vertices]
    lowest, highest = min(p.z for p in world_positions), max(p.z for p in world_positions)
    original_height = highest - lowest
    if not 0.01 < original_height < 100.0:
        raise ValueError("PMX尺寸无效")
    scale = 1.7 / original_height
    normalizer = bpy.data.objects.new("Imported_Model", None)
    bpy.context.scene.collection.objects.link(normalizer)
    rig_world = rig.matrix_world.copy()
    rig.parent = normalizer
    rig.matrix_world = rig_world
    for obj in meshes:
        world = obj.matrix_world.copy()
        obj.parent = rig
        obj.matrix_world = world
    normalizer.scale = (scale, scale, scale)
    normalizer.location.z = -lowest * scale
    physics = physics_metadata(source, scale, lowest)
    material_records = []
    image_cache = {}
    texture_dir = args.output_dir / "textures"
    texture_dir.mkdir()
    for obj in meshes:
        # A float color layer carries the original per-vertex MMD edge multiplier only in alpha.
        for layer in list(obj.data.color_attributes):
            obj.data.color_attributes.remove(layer)
        colors = obj.data.color_attributes.new(name="MMD_Edge", type="FLOAT_COLOR", domain="POINT")
        obj.data.color_attributes.active_color = colors
        edge_group = obj.vertex_groups.get("mmd_edge_scale")
        for index, value in enumerate(colors.data):
            try:
                edge = source.vertices[index].edge_scale if len(meshes) == 1 and len(source.vertices) == len(obj.data.vertices) else edge_group.weight(index) if edge_group else 1.0
            except RuntimeError:
                edge = 1.0
            value.color = (1.0, 1.0, 1.0, max(0.0, float(edge)))
        for slot, material in enumerate(obj.data.materials):
            if material is None:
                continue
            if any(item["name"] == material.name for item in material_records):
                continue
            native = material.mmd_material
            original_name = native.name_j or material.name
            record = {"name": material.name, "source_name": original_name, "category": category(original_name),
                      "base_color": [*native.diffuse_color, native.alpha], "texture": "", "double_sided": bool(native.is_double_sided),
                      "edge_enabled": bool(native.enabled_toon_edge), "edge_color": list(native.edge_color), "edge_size": float(native.edge_weight)}
            texture_index = source.materials[slot].texture if slot < len(source.materials) else -1
            image = None
            if 0 <= texture_index < len(textures) and textures[texture_index]:
                path = textures[texture_index]
                if path not in image_cache:
                    try:
                        image = bpy.data.images.load(str(path), check_existing=False)
                        if not image.has_data:
                            image.pixels[0]
                        image.file_format = "PNG"
                        output_name = "texture_%03d.png" % len(image_cache)
                        image.filepath_raw = str(texture_dir / output_name)
                        image.save()
                        image_cache[path] = (image, str(args.final_dir / "textures" / output_name))
                    except Exception as error:
                        warnings.append("贴图读取失败：" + str(path.name) + ": " + str(error))
                        image_cache[path] = (None, "")
                image, record["texture"] = image_cache[path]
            material.use_nodes = True
            material.node_tree.nodes.clear()
            nodes, links = material.node_tree.nodes, material.node_tree.links
            output = nodes.new("ShaderNodeOutputMaterial")
            shader = nodes.new("ShaderNodeBsdfPrincipled")
            shader.inputs["Base Color"].default_value = record["base_color"]
            shader.inputs["Alpha"].default_value = native.alpha
            shader.inputs["Roughness"].default_value = 0.9
            if image:
                texture = nodes.new("ShaderNodeTexImage")
                texture.image = image
                links.new(texture.outputs["Color"], shader.inputs["Base Color"])
                links.new(texture.outputs["Alpha"], shader.inputs["Alpha"])
            links.new(shader.outputs["BSDF"], output.inputs["Surface"])
            material.use_backface_culling = not native.is_double_sided
            material_records.append(record)
    bpy.ops.object.select_all(action="DESELECT")
    for obj in [normalizer, rig, *meshes]:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = rig
    kwargs = dict(filepath=str(args.output_dir / "model.glb"), export_format="GLB", use_selection=True, export_yup=True,
                  export_apply=False, export_animations=False, export_skins=True, export_morph=True,
                  export_morph_normal=True, export_morph_tangent=False, export_def_bones=False, export_leaf_bone=False)
    properties = bpy.ops.export_scene.gltf.get_rna_type().properties
    if "export_vertex_color" in properties:
        kwargs["export_vertex_color"] = "ACTIVE"
    triangle_count = sum(len(obj.data.polygons) for obj in meshes)
    export_preserving_faces(kwargs)
    blob = (args.output_dir / "model.glb").read_bytes()
    length = struct.unpack_from("<I", blob, 12)[0]
    gltf = json.loads(blob[20:20 + length])
    exported_triangles = sum(gltf["accessors"][primitive["indices"]]["count"] // 3 for mesh in gltf.get("meshes", []) for primitive in mesh["primitives"])
    if exported_triangles != triangle_count:
        raise ValueError("GLB导出面数不完整，已取消导入以保留当前角色")
    lookup = {item["name"]: item for item in material_records}
    for material in gltf.get("materials", []):
        if material.get("name") in lookup:
            material["pbrMetallicRoughness"]["baseColorFactor"] = lookup[material["name"]]["base_color"]
    encoded = json.dumps(gltf, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")
    encoded += b" " * (-len(encoded) % 4)
    remaining = blob[20 + length:]
    (args.output_dir / "model.glb").write_bytes(struct.pack("<4sII", b"glTF", 2, 20 + len(encoded) + len(remaining)) + struct.pack("<I4s", len(encoded), b"JSON") + encoded + remaining)
    if not gltf.get("skins") or not all("COLOR_0" in primitive["attributes"] for mesh in gltf.get("meshes", []) for primitive in mesh["primitives"]):
        raise ValueError("GLB骨架或MMD顶点描边权重导出失败")
    head_name = next((name for name in ("頭", "head", "Head") if name in rig.data.bones), "")
    head = {"bone": head_name, "half_width": 0.08, "nose_height": 0.025}
    morphs = sorted({key.name for obj in meshes if obj.data.shape_keys for key in obj.data.shape_keys.key_blocks if key.name != "Basis"})
    metadata = {"name": source.name or args.pmx.stem, "height": 1.7, "scale": scale, "head": head, "additional_uv_channels": additional_uv_count, "triangle_count": exported_triangles,
                "bones": [bone.name for bone in rig.data.bones], "morphs": morphs, "materials": material_records,
                "warnings": warnings, "coordinate_system": "Y up, +Z forward", "mmd_edge_vertex_attribute": "COLOR_0.a", "vertex_edge_weights": True,
                "physics": physics}
    (args.output_dir / "metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
    sanitized.unlink()
    print("PMX_CONVERSION_OK", json.dumps({"name": metadata["name"], "bones": len(metadata["bones"]), "morphs": len(morphs), "materials": len(material_records)}))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        args = parse_arguments()
        args.output_dir.mkdir(parents=True, exist_ok=True)
        message = str(error).strip() or "模型转换失败：" + type(error).__name__
        (args.output_dir / "import_error.json").write_text(json.dumps({"ok": False, "error": message}, ensure_ascii=False), encoding="utf-8")
        raise
