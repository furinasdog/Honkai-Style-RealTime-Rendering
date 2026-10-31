extends SceneTree

const Materials = preload("res://plugins/honkai_mmd/render/materials.gd")
const AUTHORED_SHADE := Color(213.0 / 255.0, 212.0 / 255.0, 222.0 / 255.0)
var setup := Materials.new()
var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, label: String) -> void:
	if not condition:
		failed = true
		push_error(label)


func _image() -> Image:
	for frame in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func _patch(column: int, kind: String, color: Color, authored: bool = false, edge: Array = []) -> ShaderMaterial:
	var entry := {"name": kind, "category": kind, "base_color": [color.r, color.g, color.b, 1.0], "edge_enabled": false}
	if not edge.is_empty():
		entry["edge_color"] = edge
	if authored:
		entry["toon_texture"] = "user://neutral_shadow_toon.png"
	var material := setup._make_material(entry, {}, null)
	material.set_shader_parameter("world_to_head", Transform3D.IDENTITY)
	material.set_shader_parameter("head_to_world", Transform3D.IDENTITY)
	material.set_shader_parameter("rim_strength", 0.0)
	material.set_shader_parameter("specular_strength", 0.0)
	var patch := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.6, 0.6)
	patch.mesh = quad
	patch.material_override = material
	patch.position.x = -3.2 + column * 0.8
	root.add_child(patch)
	return material


func _run() -> void:
	create_timer(30).timeout.connect(func(): quit(1))
	root.size = Vector2i(1152, 256)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	root.add_child(environment)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.position.z = 2.0
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1.6
	camera.make_current()
	var light := DirectionalLight3D.new()
	light.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	root.add_child(light)
	var toon := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	toon.fill(Color.WHITE)
	for x in 2:
		toon.set_pixel(x, 1, AUTHORED_SHADE)
	assert(toon.save_png("user://neutral_shadow_toon.png") == OK)
	_patch(0, "cloth", Color(0.4, 0.4, 0.4))
	_patch(1, "cloth", Color(0.4, 0.4, 0.4), true)
	_patch(2, "hair", Color(0.65, 0.62, 0.59))
	_patch(3, "hair", Color(0.55, 0.59, 0.65))
	_patch(4, "cloth", Color(0.08, 0.25, 0.75))
	var blue_gray := Color(94.0 / 255.0, 92.0 / 255.0, 104.0 / 255.0).srgb_to_linear()
	_patch(5, "cloth", blue_gray)
	_patch(6, "cloth", blue_gray, true)
	var mapped_gray := _patch(7, "cloth", Color(0.4, 0.4, 0.4))
	var data_map := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	data_map.fill(Color(1.0, 0.5, 0.5, 0.0))
	mapped_gray.set_shader_parameter("light_map", ImageTexture.create_from_image(data_map))
	mapped_gray.set_shader_parameter("has_light_map", true)
	_patch(8, "hair", Color(0.5, 0.5, 0.5), false, [0.45, 0.2, 0.3, 1.0])
	setup.set_enhanced(true)
	setup.set_shadow_threshold(0.30)
	var lit := await _image()
	light.rotation.y = PI
	var dark := await _image()
	var labels := ["neutral cloth fallback", "neutral cloth authored Toon", "warm gray hair", "blue gray hair", "saturated blue cloth", "blue gray cloth fallback", "blue gray cloth authored Toon", "neutral cloth with LightMap", "hair with authored pink ink"]
	var lit_colors: Array[Color] = []
	var dark_colors: Array[Color] = []
	for column in 9:
		var pixel := Vector2i(64 + column * 128, 128)
		var bright := lit.get_pixelv(pixel).srgb_to_linear()
		var shade := dark.get_pixelv(pixel).srgb_to_linear()
		lit_colors.append(bright)
		dark_colors.append(shade)
		_check(shade.get_luminance() > 0.015, "%s shadow must retain visible color: %s" % [labels[column], shade])
		_check(bright.get_luminance() > shade.get_luminance() + 0.025, "%s must have distinct lit and shadow tones: %s / %s" % [labels[column], bright, shade])
		if column not in [4, 8]:
			_check(shade.r - shade.g <= maxf(bright.r - bright.g, 0.0) + 0.02, "%s shadow adds red over green: %s / %s" % [labels[column], bright, shade])
			_check(minf(shade.r, shade.b) - shade.g <= maxf(minf(bright.r, bright.b) - bright.g, 0.0) + 0.02, "%s shadow becomes magenta: %s / %s" % [labels[column], bright, shade])
			_check(minf(bright.r, bright.b) - bright.g <= 0.02, "%s lit tone must not become magenta: %s" % [labels[column], bright])
	var authored_ratio := Vector3(dark_colors[1].r / lit_colors[1].r, dark_colors[1].g / lit_colors[1].g, dark_colors[1].b / lit_colors[1].b)
	var authored_linear := AUTHORED_SHADE.srgb_to_linear()
	# A shared exposure scalar may deepen the Toon; its channel relationship must survive.
	var scalar := authored_ratio.y / authored_linear.g
	_check(scalar > 0.05 and scalar <= 1.05, "Authored Toon exposure scalar must remain bounded: %f" % scalar)
	_check(absf(authored_ratio.x - authored_linear.r * scalar) <= 0.025 and absf(authored_ratio.z - authored_linear.b * scalar) <= 0.025, "Authored Toon shadow/lit channel ratios changed: %s; scalar=%f" % [authored_ratio, scalar])
	for color in [lit_colors[4], dark_colors[4]]:
		_check(color.b > color.g + 0.04 and color.g > color.r + 0.01, "Saturated blue cloth must retain blue hue in both tones: %s" % color)
	_check(dark_colors[8].r > dark_colors[8].g * 1.3 and dark_colors[8].b > dark_colors[8].g, "Authored pink hair pigment must survive in its pale strands' shadow")
	if failed:
		quit(1)
		return
	print("NEUTRAL_SHADOW_METRICS lit=", lit_colors, " dark=", dark_colors, " authored_ratio=", authored_ratio)
	print("NEUTRAL_SHADOW_PASS neutral and blue-gray authored/fallback cloth, warm/cool gray hair, saturated blue cloth")
	quit()
