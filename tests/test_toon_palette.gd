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
	_setup.set_enhanced(false)
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
	assert(is_equal_approx(_setup.materials[2].get_shader_parameter("shadow_threshold"), 0.30))
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
	_setup.set_shadows_enabled(false)
	var fill_light := OmniLight3D.new()
	fill_light.position.z = 2.0
	fill_light.omni_range = 10.0
	fill_light.light_color = Color.RED
	fill_light.light_energy = 5.0
	root.add_child(fill_light)
	for degrees in [0, 90, 180]:
		_light.rotation.y = deg_to_rad(degrees)
		_light.light_color = Color(0.25, 0.5, 1.0)
		_light.light_energy = 2.0 + float(degrees) / 90.0
		var full_bright := await _image()
		for row in 2:
			for column in 4:
				_assert_color(full_bright.get_pixel(64 + column * 128, 109 + row * 166), Color.WHITE if row == 0 else DIFFUSE, "Shadows disabled %s at %d" % [KINDS[column], degrees])
		_save(full_bright, "disabled_%d" % degrees)
	fill_light.free()
	_light.visible = false
	var no_light := await _image()
	_assert_color(no_light.get_pixel(64, 275), DIFFUSE, "Disabled shadows must preserve source color without a light")
	_light.visible = true
	_light.light_color = Color.WHITE
	_light.light_energy = 1.0
	for patch in _patches:
		patch.free()
	var imported := Node3D.new()
	root.add_child(imported)
	var fresh := _patch(Vector3.ZERO, Vector3.BACK, "cloth", DIFFUSE)
	fresh.reparent(imported)
	var source := StandardMaterial3D.new()
	source.resource_name = "Imported"
	var texture_image := Image.create(2, 1, false, Image.FORMAT_RGBA8)
	var texture_color := Color(0.8, 0.6, 0.4)
	texture_image.set_pixel(0, 0, texture_color)
	texture_image.set_pixel(1, 0, Color(0.8, 0.6, 0.4, 0.0))
	source.albedo_texture = ImageTexture.create_from_image(texture_image)
	var arrays := fresh.mesh.surface_get_arrays(0)
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.DOWN, Vector2.ONE])
	var imported_mesh := ArrayMesh.new()
	imported_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	imported_mesh.surface_set_material(0, source)
	fresh.mesh = imported_mesh
	fresh.material_override = null
	_setup.apply(imported, {"materials": [{"name": "Imported", "source_name": "cloth", "base_color": [DIFFUSE.r, DIFFUSE.g, DIFFUSE.b, 1.0], "edge_enabled": false}]})
	assert(_setup.materials.size() == 1 and not _setup.materials[0].get_shader_parameter("shadows_enabled"), "A newly applied model must inherit the disabled shadow setting")
	root.transparent_bg = true
	var reloaded := await _image()
	_assert_color(reloaded.get_pixel(234, 192), texture_color.srgb_to_linear() * DIFFUSE, "New material keeps texture UV and original diffuse in backlight")
	assert(reloaded.get_pixel(278, 192).a < 0.01, "Disabling shadows must retain texture alpha cutout")
	imported.free()
	root.transparent_bg = false
	_setup.set_shadows_enabled(true)
	# A grazing receiver at N.L=.4 with 60% visibility must cross the .3 band together.
	var grazing := _patch(Vector3.ZERO, Vector3(sqrt(0.84), 0, 0.4), "cloth", Color.WHITE)
	_setup.set_enhanced(false)
	_light.rotation = Vector3.ZERO
	var partial := Shader.new()
	partial.code = Materials.TOON.code.replace("ATTENUATION", "0.6")
	grazing.material_override.shader = partial
	var combined := await _image()
	_assert_color(combined.get_pixel(256, 192), SHADOWS[0], "Partial visibility times grazing light")
	_save(combined, "combined")
	grazing.free()
	var receiver := _patch(Vector3.ZERO, Vector3.BACK, "cloth", Color.WHITE)
	_setup.set_enhanced(false)
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
	_setup.set_enhanced(true)
	var enhanced_receiver := await _image()
	_assert_color(enhanced_receiver.get_pixel(256, 192), Materials.SHADOW_TINTS[3], "Enhanced cloth must receive actual occlusion")
	_setup.set_enhanced(false)
	var basic_receiver := await _image()
	_assert_color(basic_receiver.get_pixel(256, 192), SHADOWS[0], "Basic rendering must restore authored cast-shadow reception")
	_setup.set_shadows_enabled(false)
	var cast_disabled := await _image()
	_assert_color(cast_disabled.get_pixel(256, 192), Color.WHITE, "Full-bright toggle must bypass real cast shadows")
	_setup.set_shadows_enabled(true)
	var cast_restored := await _image()
	_assert_color(cast_restored.get_pixel(256, 192), SHADOWS[0], "Reenabling shadows must restore real cast shadows")
	receiver.material_override.set_shader_parameter("shadow_receive", 0.0)
	var unoccluded := await _image()
	_assert_color(unoccluded.get_pixel(256, 192), Color.WHITE, "Shadow reception disabled")
	receiver.free()
	var face := _patch(Vector3.ZERO, Vector3.BACK, "face", DIFFUSE)
	face.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	face.material_override.set_shader_parameter("world_to_head", Transform3D.IDENTITY)
	face.material_override.set_shader_parameter("face_half_width", 1.0)
	face.material_override.set_shader_parameter("face_bottom", -1.0)
	face.material_override.set_shader_parameter("face_top", -0.5)
	face.material_override.set_shader_parameter("eye_height", -0.7)
	var face_shadow := await _image()
	_assert_color(face_shadow.get_pixel(256, 192), DIFFUSE * SHADOWS[1], "Face must receive the real cast-shadow fixture while enabled")
	_setup.set_shadows_enabled(false)
	var face_cast_disabled := await _image()
	_assert_color(face_cast_disabled.get_pixel(256, 192), DIFFUSE, "Face cast-shadow field must be bypassed when disabled")
	_light.rotation = Vector3(0, PI, 0)
	var face_back_disabled := await _image()
	_assert_color(face_back_disabled.get_pixel(256, 192), DIFFUSE, "Face analytic backlight field must be bypassed when disabled")
	_setup.set_shadows_enabled(true)
	var face_back_restored := await _image()
	_assert_color(face_back_restored.get_pixel(256, 192), DIFFUSE * SHADOWS[1], "Face analytic backlight field must return when enabled")
	if _failed:
		quit(1)
		return
	print("TOON_PALETTE_METRICS diffuse=", lit.get_pixel(64, 275).srgb_to_linear(), " cloth_shadow=", shadow.get_pixel(64, 109).srgb_to_linear(), " cast_shadow=", occluded.get_pixel(256, 192).srgb_to_linear())
	print("TOON_PALETTE_PASS linear palette, runtime full-bright toggle, colored/front/back/no light, new model UV/alpha, face and real cast shadow restore; MSAA 4x")
	quit(0)
