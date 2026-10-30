extends SceneTree

const Loader = preload("res://plugins/honkai_mmd/runtime/pmx_loader.gd")
var reader


func _initialize() -> void:
	call_deferred("_run")


func _text(file: FileAccess, value: String) -> void:
	var bytes := value.to_utf8_buffer()
	file.store_32(bytes.size())
	file.store_buffer(bytes)


func _numbers(file: FileAccess, values: Array) -> void:
	for value in values:
		file.store_float(value)


func _fixture(folder: String, eyes: bool = true, toon: int = 1, common: int = 4, missing: bool = false, invalid_color: bool = false, sphere: int = 2) -> String:
	var path := folder.path_join("fixture.pmx")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer("PMX ".to_ascii_buffer())
	file.store_float(2.0)
	file.store_buffer(PackedByteArray([8,1,0,1,1,1,1,1,1]))
	for value in ["材质夹具", "fixture", "", ""]:
		_text(file, value)
	file.store_32(3)
	for point in [Vector3.ZERO, Vector3.RIGHT, Vector3.UP]:
		_numbers(file, [point.x, point.y, point.z, 0,0,1, point.x,point.y])
		file.store_8(0)
		file.store_8(0)
		file.store_float(1)
	file.store_32(6)
	file.store_buffer(PackedByteArray([0,1,2,0,1,2]))
	file.store_32(3)
	for name in ["diffuse.png", "missing-toon.png" if missing else "toon.png", "missing-sphere.png" if missing else "sphere.png"]:
		_text(file, name)
	file.store_32(2)
	for index in 2:
		_text(file, "脸" if index == 0 else "衣服")
		_text(file, "")
		_numbers(file, [1,1,1,1, NAN if invalid_color else 0.1,0.2,0.3,12.5,0.4,0.5,0.6])
		file.store_8(0x1d)
		_numbers(file, [0,0,0,1,1])
		file.store_8(0)
		file.store_8(2)
		file.store_8(sphere)
		file.store_8(index)
		file.store_8(toon if index == 0 else common)
		_text(file, "")
		file.store_32(3)
	file.store_32(3 if eyes else 1)
	for index in (3 if eyes else 1):
		_text(file, ["頭", "左目", "右目"][index])
		_text(file, "")
		_numbers(file, [0.5,0.5,0] if index == 0 else [0.6 if index == 1 else 0.4,0.8,0.1])
		file.store_8(255 if index == 0 else 0)
		file.store_32(0)
		file.store_16(0)
		_numbers(file, [0,0,0])
	for index in 4:
		file.store_32(0)
	file.close()
	return path


func _run() -> void:
	create_timer(45).timeout.connect(func(): quit(1))
	var eye_rig := Skeleton3D.new()
	for name in ["頭","左目","右目"]:
		eye_rig.add_bone(name)
	var head_origin := Vector3(1.5,2.0,-0.4)
	eye_rig.set_bone_rest(0,Transform3D(Basis(Vector3.FORWARD,0.6),head_origin))
	eye_rig.set_bone_rest(1,Transform3D(Basis.IDENTITY,head_origin+Vector3(-0.03,0.11,0.01)))
	eye_rig.set_bone_rest(2,Transform3D(Basis.IDENTITY,head_origin+Vector3(0.03,0.11,0.01)))
	var eye_bounds := {"face_bottom":0.0,"face_top":0.2,"half_width":0.1}
	Loader._set_eye_landmarks(eye_rig,0,eye_bounds)
	assert(eye_bounds.eye_landmarks_from_bones and absf(eye_bounds.eye_height-0.11)<0.00001, "Rest roll must not rotate the model-space eye height away from face bounds")
	for invalid_point in [Vector3(0.03,1.0,0),Vector3(0.5,0.11,0)]:
		eye_rig.set_bone_rest(2,Transform3D(Basis.IDENTITY,head_origin+invalid_point))
		Loader._set_eye_landmarks(eye_rig,0,eye_bounds)
		assert(not eye_bounds.eye_landmarks_from_bones and absf(eye_bounds.eye_height-0.11)<0.00001, "Misnamed helpers outside the face must preserve safe landmarks")
	eye_rig.free()
	var extension := GDExtensionManager.load_extension("res://native/mocap.gdextension")
	assert(extension in [GDExtensionManager.LOAD_STATUS_OK, GDExtensionManager.LOAD_STATUS_ALREADY_LOADED])
	reader = ClassDB.instantiate("NativePmxReader")
	var folder := ProjectSettings.globalize_path("user://material-fixture")
	assert(DirAccess.make_dir_recursive_absolute(folder) == OK)
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	for name in ["diffuse.png", "toon.png", "sphere.png"]:
		image.fill(Color.WHITE)
		assert(image.save_png(folder.path_join(name)) == OK)
	var raw = reader.read_file(_fixture(folder))
	assert(raw is Dictionary, reader.get_error())
	var material: Dictionary = raw.metadata.materials[0]
	assert(not material.toon_shared and material.toon_index == 1 and material.sphere_mode == 2)
	assert(is_equal_approx(material.specular[0], 0.1) and is_equal_approx(material.shininess, 12.5))
	assert(is_equal_approx(material.ambient[2], 0.6))
	assert(raw.metadata.materials[1].toon_shared and raw.metadata.materials[1].toon_index == 4)
	var json: Dictionary = JSON.parse_string(JSON.stringify(raw.metadata))
	assert(is_equal_approx(json.materials[0].specular[2], 0.3) and json.materials[1].toon_shared)
	var archive := {"cache_root": folder, "aliases": {}}
	var loaded := Loader.new().load_file(folder.path_join("fixture.pmx"), archive)
	assert(not loaded.is_empty())
	assert(loaded.metadata.materials[0].toon_texture == folder.path_join("toon.png"))
	assert(loaded.metadata.materials[0].sphere_texture == folder.path_join("sphere.png"))
	assert(loaded.metadata.materials[1].toon_texture.is_empty(), "Common Toon needs no external asset")
	assert(loaded.metadata.head.eye_landmarks_from_bones)
	assert(absf(loaded.metadata.head.eye_height - 0.51) < 0.00001)
	assert(absf(loaded.metadata.head.eye_half_width - 0.17) < 0.00001)
	loaded.root.free()
	loaded = Loader.new().load_file(_fixture(folder, false, 1, 4, true), archive)
	assert(not loaded.is_empty(), "Optional missing Toon/Sphere must preserve model import")
	assert(loaded.metadata.materials[0].toon_texture.is_empty() and loaded.metadata.materials[0].sphere_texture.is_empty())
	assert(not loaded.metadata.head.eye_landmarks_from_bones)
	assert(is_equal_approx(loaded.metadata.head.eye_height, lerpf(loaded.metadata.head.face_bottom, loaded.metadata.head.face_top, 0.55)))
	loaded.root.free()
	assert(not reader.read_file(_fixture(folder, true, 3)) is Dictionary, "External Toon index must be checked")
	assert(not reader.read_file(_fixture(folder, true, 1, 10)) is Dictionary, "Common Toon index must be checked")
	assert(reader.read_file(_fixture(folder, true, 255)) is Dictionary, "The signed missing-Toon sentinel must remain valid")
	assert(not reader.read_file(_fixture(folder, true, 1, 4, false, false, 4)) is Dictionary, "Unknown Sphere operation must be checked")
	assert(not reader.read_file(_fixture(folder, true, 1, 4, false, true)) is Dictionary, "Non-finite material data must fail before JSON conversion")
	assert(Loader._texture_path("../../outside.png", folder, folder, {}).is_empty())
	assert(Loader._texture_path("outside.png", folder, folder, {"outside.png": "../outside.png"}).is_empty())
	var args := OS.get_cmdline_user_args()
	var reports := []
	for metadata_path in args.slice(0, maxi(0, args.size() - 1)):
		var source: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(metadata_path))
		loaded = Loader.new().load_file(source.model_file)
		assert(not loaded.is_empty())
		var toon_count := 0
		var sphere_count := 0
		for entry: Dictionary in loaded.metadata.materials:
			assert(entry.has_all(["toon_shared", "toon_index", "specular", "ambient", "shininess"]))
			toon_count += int(not entry.toon_texture.is_empty())
			sphere_count += int(entry.sphere_mode != 0 and not entry.sphere_texture.is_empty())
		var serialized: Dictionary = JSON.parse_string(JSON.stringify(loaded.metadata))
		assert(serialized.head.has_all(["eye_height", "eye_half_width", "eye_landmarks_from_bones"]))
		reports.append({"name": loaded.metadata.name, "materials": loaded.metadata.materials.size(), "toon_textures": toon_count, "sphere_textures": sphere_count, "head": loaded.metadata.head})
		loaded.root.free()
	if args.size() > 1:
		var report_file := FileAccess.open(args[-1], FileAccess.WRITE)
		report_file.store_string(JSON.stringify(reports, "  "))
		report_file.close()
	print("NATIVE_MATERIAL_METADATA_PASS optional authored textures, common Toon fallback, original values, JSON, indices, eye landmarks ", JSON.stringify(reports))
	quit()
