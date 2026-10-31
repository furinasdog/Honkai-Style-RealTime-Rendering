extends SceneTree

const Materials = preload("res://plugins/honkai_mmd/render/materials.gd")
var failed := false

func _initialize() -> void:
	call_deferred("_run")

func _sample() -> Color:
	for frame in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image().get_pixel(128, 128).srgb_to_linear()

func _check(actual: Color, expected: Color, label: String) -> void:
	if Vector3(actual.r, actual.g, actual.b).distance_to(Vector3(expected.r, expected.g, expected.b)) > 0.025:
		failed = true
		push_error("%s actual=%s expected=%s" % [label, actual, expected])

func _run() -> void:
	create_timer(40).timeout.connect(func(): quit(1))
	root.size = Vector2i(256, 256)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.position.z = 2
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1.5
	camera.make_current()
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	root.add_child(environment)
	var light := DirectionalLight3D.new()
	light.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	root.add_child(light)
	var patch := MeshInstance3D.new()
	patch.mesh = QuadMesh.new()
	root.add_child(patch)
	var setup := Materials.new()
	var material := setup._make_material({"name":"cloth", "category":"cloth", "base_color":[1,1,1,1], "edge_enabled":false}, {}, null)
	patch.material_override = material
	material.set_shader_parameter("rim_strength", 0.0)
	# Distinct texels make the entire shadow-to-light coordinate interval observable.
	var ramp := Image.create(256, 8, false, Image.FORMAT_RGBA8)
	for y in 8:
		for x in 256:
			ramp.set_pixel(x, y, Color(float(x) / 255.0, float(y) / 7.0, 0.2))
	material.set_shader_parameter("has_warm_ramp", true)
	material.set_shader_parameter("warm_ramp", ImageTexture.create_from_image(ramp))
	material.set_shader_parameter("has_light_map", true)
	var data := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	for row in [0, 3, 7]:
		for occlusion in [0.0, 0.5, 1.0]:
			data.fill(Color(occlusion, 0.5, 0.0, (row + 0.5) / 8.0))
			material.set_shader_parameter("light_map", ImageTexture.create_from_image(data))
			var x := mini(255, int((0.75 + 0.25 * occlusion) * 256.0))
			_check(await _sample(), ramp.get_pixel(x, row).srgb_to_linear(), "Ramp x and material row, R=%s row=%s" % [occlusion, row])
	material.set_shader_parameter("has_warm_ramp", false)
	material.set_shader_parameter("has_light_map", false)
	for color in [Color(0.8,0.3,0.6), Color(0.1,0.4,0.8), Color(0.8,0.8,0.8)]:
		material.set_shader_parameter("base_color", color.linear_to_srgb())
		_check(await _sample(), color, "No pigment-dependent bright grading")
	material.set_shader_parameter("category", 0)
	material.set_shader_parameter("shadow_color", Materials.SHADOW_TINTS[0].linear_to_srgb())
	material.set_shader_parameter("base_color", Color.WHITE)
	material.set_shader_parameter("world_to_head", Transform3D.IDENTITY)
	material.set_shader_parameter("head_to_world", Transform3D.IDENTITY)
	material.set_shader_parameter("has_face_sdf", true)
	for value in [0.0, 1.0]:
		data.fill(Color(value, value, value))
		material.set_shader_parameter("face_sdf", ImageTexture.create_from_image(data))
		for yaw in [0.0, PI]:
			light.rotation.y = yaw
			_check(await _sample(), Color.WHITE if value == 1.0 and yaw == 0.0 else Materials.SHADOW_TINTS[0], "SDF endpoints at frontal/rear light")
	material.set_shader_parameter("has_face_sdf", false)
	material.set_shader_parameter("category", 3)
	light.visible = false
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.2
	material.set_shader_parameter("base_color", Color.WHITE)
	material.set_shader_parameter("has_light_map", true)
	for occlusion in [0.0, 1.0]:
		data.fill(Color(occlusion, 0.5, 0, 0))
		material.set_shader_parameter("light_map", ImageTexture.create_from_image(data))
		_check(await _sample(), Color.WHITE * (0.2 * lerpf(0.5, 1.0, occlusion)), "Independent environment AO")
	setup.set_shadows_enabled(false)
	_check(await _sample(), Color.WHITE, "Full bright must bypass environment")
	patch.free()
	if failed:
		quit(1)
	else:
		print("GENERIC_SHADOW_PASS Ramp interval/rows/R, pigment independence, environment AO, full bright")
		quit()
