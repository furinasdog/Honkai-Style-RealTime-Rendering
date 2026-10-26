extends SceneTree

const Materials = preload("res://plugins/honkai_mmd/render/materials.gd")
const SHADOWS := [Color(0.54, 0.51, 0.70), Color(0.88, 0.49, 0.46), Color(0.61, 0.32, 0.42), Color(0.54, 0.51, 0.70)]
const KINDS := ["cloth", "skin", "hair", "metal"]
const DIFFUSE := Color(0.5, 0.25, 0.75)
var _setup := Materials.new()
var _light: DirectionalLight3D
var _camera: Camera3D
var _patches: Array[MeshInstance3D] = []
var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _patch(position: Vector3, normal: Vector3, kind: String, diffuse: Color) -> MeshInstance3D:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-0.35, -0.35, 0), Vector3(0.35, -0.35, 0), Vector3(-0.35, 0.35, 0), Vector3(0.35, 0.35, 0)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([normal, normal, normal, normal])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 1, 2, 3])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var patch := MeshInstance3D.new()
	patch.mesh = mesh
	patch.material_override = _setup._make_material({"name": kind, "category": kind, "base_color": [diffuse.r, diffuse.g, diffuse.b, 1.0], "edge_enabled": false}, {}, null)
	patch.material_override.set_shader_parameter("world_to_head", Transform3D(Basis.IDENTITY, Vector3(0, -10, 0)))
	patch.material_override.set_shader_parameter("head_to_world", Transform3D.IDENTITY)
	patch.material_override.set_shader_parameter("rim_strength", 0.0)
	patch.material_override.set_shader_parameter("specular_strength", 0.0)
	patch.position = position
	root.add_child(patch)
	return patch


func _image() -> Image:
	for frame in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func _assert_color(actual: Color, expected: Color, label: String) -> void:
	var linear := actual.srgb_to_linear()
	if maxf(absf(linear.r - expected.r), maxf(absf(linear.g - expected.g), absf(linear.b - expected.b))) >= 0.015:
		_failed = true
		push_error("%s actual linear=%s expected=%s" % [label, linear, expected])


func _save(image: Image, name: String) -> void:
	assert(image.save_png("res://outputs/toon_palette_%s.png" % name) == OK)


func _run() -> void:
	create_timer(30.0).timeout.connect(func(): quit(1))
	DirAccess.make_dir_recursive_absolute("res://outputs")
	root.size = Vector2i(512, 384)
	root.msaa_3d = Viewport.MSAA_4X
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	root.add_child(world)
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 3.0
	# Orthographic shadow precision follows camera depth, so keep this metre-scale fixture bounded.
	_camera.far = 12.0
	_camera.position.z = 5.0
	root.add_child(_camera)
	_camera.make_current()
	_light = DirectionalLight3D.new()
	_light.light_angular_distance = 0.0
	root.add_child(_light)
	for row in 2:
		for column in 4:
			_patches.append(_patch(Vector3(-1.5 + column, 0.65 - row * 1.3, 0), Vector3.BACK, KINDS[column], Color.WHITE if row == 0 else DIFFUSE))
	_setup.set_shadow_threshold(0.30)
	assert(is_equal_approx(_setup.materials[2].get_shader_parameter("shadow_threshold"), 0.22))
	var lit := await _image()
	_save(lit, "lit")
	_light.rotation.y = PI
	var shadow := await _image()
	_save(shadow, "shadow")
	for row in 2:
		for column in 4:
			var pixel := Vector2i(64 + column * 128, 109 + row * 166)
			var base := Color.WHITE if row == 0 else DIFFUSE
			_assert_color(lit.get_pixelv(pixel), base, "Lit %s row %d" % [KINDS[column], row])
			_assert_color(shadow.get_pixelv(pixel), base * SHADOWS[column], "Shadow %s row %d" % [KINDS[column], row])
	for patch in _patches:
		patch.free()
	# A grazing receiver at N.L=.4 with 60% visibility must cross the .3 band together.
	var grazing := _patch(Vector3.ZERO, Vector3(sqrt(0.84), 0, 0.4), "cloth", Color.WHITE)
	_light.rotation = Vector3.ZERO
	var partial := Shader.new()
	partial.code = Materials.TOON.code.replace("ATTENUATION", "0.6")
	grazing.material_override.shader = partial
	var combined := await _image()
	_assert_color(combined.get_pixel(256, 192), SHADOWS[0], "Partial visibility times grazing light")
	_save(combined, "combined")
	grazing.free()
	var receiver := _patch(Vector3.ZERO, Vector3.BACK, "cloth", Color.WHITE)
	receiver.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_light.look_at_from_position(Vector3(1, 0, 1) * 8.0, Vector3.ZERO)
	_light.shadow_enabled = true
	_light.shadow_bias = 0.001
	_light.shadow_normal_bias = 0.01
	_light.directional_shadow_max_distance = 8.0
	var blocker := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.3, 0.8, 0.08)
	blocker.mesh = box
	blocker.position = Vector3(0.5, 0, 0.5)
	blocker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	root.add_child(blocker)
	var occluded := await _image()
	_assert_color(occluded.get_pixel(256, 192), SHADOWS[0], "Real cast shadow")
	_assert_color(occluded.get_pixel(224, 192), Color.WHITE, "Outside real cast shadow")
	for y in range(188, 197, 4):
		for x in range(252, 261, 4):
			_assert_color(occluded.get_pixel(x, y), SHADOWS[0], "Flat shadow interior")
	_save(occluded, "occlusion")
	receiver.material_override.set_shader_parameter("shadow_receive", 0.0)
	var unoccluded := await _image()
	_assert_color(unoccluded.get_pixel(256, 192), Color.WHITE, "Shadow reception disabled")
	if _failed:
		quit(1)
		return
	print("TOON_PALETTE_METRICS diffuse=", lit.get_pixel(64, 275).srgb_to_linear(), " cloth_shadow=", shadow.get_pixel(64, 109).srgb_to_linear(), " cast_shadow=", occluded.get_pixel(256, 192).srgb_to_linear())
	print("TOON_PALETTE_PASS linear PMX diffuse, four material palettes, combined grazing/visibility band, real cast shadow; MSAA 4x")
	quit(0)
