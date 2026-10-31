extends SceneTree

const Materials = preload("res://plugins/honkai_mmd/render/materials.gd")
var setup := Materials.new()
var light: DirectionalLight3D
var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _image() -> Image:
	for frame in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func _check(image: Image, expected: Color, label: String) -> void:
	var actual := image.get_pixel(128, 128).srgb_to_linear()
	if maxf(absf(actual.r - expected.r), maxf(absf(actual.g - expected.g), absf(actual.b - expected.b))) > 0.018:
		failed = true
		push_error("%s: linear %s, expected %s" % [label, actual, expected])


func _run() -> void:
	create_timer(25).timeout.connect(func(): quit(1))
	root.size = Vector2i(256, 256)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.position.z = 2
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1.5
	camera.make_current()
	light = DirectionalLight3D.new()
	light.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	root.add_child(light)
	var patch := MeshInstance3D.new()
	patch.mesh = QuadMesh.new()
	root.add_child(patch)
	var material := setup._make_material({"name":"hair", "category":"hair", "base_color":[0.5,0.5,0.5,1.0], "edge_enabled":false}, {}, null)
	patch.material_override = material
	material.set_shader_parameter("world_to_head", Transform3D(Basis.IDENTITY, Vector3(0,-10,0)))
	material.set_shader_parameter("head_to_world", Transform3D.IDENTITY)
	material.set_shader_parameter("rim_strength", 0.0)
	material.set_shader_parameter("specular_strength", 0.0)
	setup.set_enhanced(true)
	_check(await _image(), Color(0.525,0.515,0.505), "Enhanced neutral hair has a restrained warm lift")
	setup.set_shadows_enabled(false)
	_check(await _image(), Color(0.525,0.515,0.505), "Full bright keeps the same enhanced bright palette")
	setup.set_enhanced(false)
	_check(await _image(), Color(0.5,0.5,0.5), "Disabling enhancement restores original source colors")
	setup.set_shadows_enabled(true)
	setup.set_enhanced(true)
	# Sample the same attenuated light field, rather than independently rounding visibility and N.L.
	var partial := Shader.new()
	partial.code = Materials.TOON.code.replace("ATTENUATION", "0.6").replace("dot(NORMAL, LIGHT)", "0.2")
	material.shader = partial
	_check(await _image(), Color(0.525,0.515,0.505) * Color(0.60,0.62,0.65), "Grazing neutral hair and partial visibility share one band decision")
	partial = Shader.new()
	partial.code = Materials.TOON.code.replace("ATTENUATION", "1.0").replace("dot(NORMAL, LIGHT)", "0.1")
	material.shader = partial
	_check(await _image(), Color(0.525,0.515,0.505) * Color(0.60,0.62,0.65), "Enhanced neutral hair keeps a cool dark band after half-Lambert remapping")
	material.shader = Materials.TOON
	material.set_shader_parameter("world_to_head", Transform3D(Basis.IDENTITY, Vector3(0.05, 0.13, -0.065)))
	var azimuth := deg_to_rad(20.0)
	var elevation := deg_to_rad(48.4)
	var crown_light := Vector3(sin(azimuth) * cos(elevation), sin(elevation), cos(azimuth) * cos(elevation))
	light.look_at_from_position(crown_light * 8.0, Vector3.ZERO)
	_check(await _image(), Color(0.525,0.515,0.505), "The upper rear crown stays lit under overhead key light instead of inheriting strand-normal blotches")
	material.set_shader_parameter("world_to_head", Transform3D(Basis.IDENTITY, Vector3(0,-10,0)))
	light.rotation = Vector3.ZERO
	var ramp_image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	ramp_image.fill(Color(0.6,0.8,1.0))
	material.set_shader_parameter("warm_ramp", ImageTexture.create_from_image(ramp_image))
	material.set_shader_parameter("has_warm_ramp", true)
	setup.set_enhanced(true)
	_check(await _image(), Color(0.5,0.5,0.5) * Color(0.6,0.8,1.0).srgb_to_linear(), "An authored Ramp bypasses fallback grading")
	var cloth := setup._make_material({"name":"cloth", "category":"cloth", "base_color":[0.2,0.4,0.7,1.0], "edge_enabled":false}, {}, null)
	patch.material_override = cloth
	cloth.set_shader_parameter("rim_strength", 0.0)
	var cool_source := Color(0.1221,0.3467,0.6724)
	var cool_lit := Color(0.1170,0.3095,0.6445)
	_check(await _image(), cool_lit, "Cool fabric receives the enhanced color contrast")
	light.rotation.y = PI
	_check(await _image(), cool_source * Color(0.66,0.27,0.44), "Cool fabric keeps a deeper two-tone shadow")
	light.rotation.y = 0
	cloth.set_shader_parameter("base_color", Color(0.7,0.2,0.1).linear_to_srgb())
	_check(await _image(), Color(0.6724,0.1356,0.0242), "Warm fabric retains its hue under the same contrast curve")
	cloth.set_shader_parameter("base_color", Color(0.5,0.5,0.5).linear_to_srgb())
	_check(await _image(), Color(0.515,0.51,0.505), "Neutral fabric must keep its neutral bright tone")
	var skin := setup._make_material({"name":"skin", "category":"skin", "base_color":[0.7,0.5,0.4,1.0], "edge_enabled":false}, {}, null)
	patch.material_override = skin
	skin.set_shader_parameter("rim_strength", 0.0)
	var occluded_skin := Shader.new()
	occluded_skin.code = Materials.TOON.code.replace("ATTENUATION", "0.0")
	skin.shader = occluded_skin
	_check(await _image(), Color(0.7063,0.5275,0.4168) * Color(0.94,0.61,0.57), "Occluded neck and body skin must not remain fully illuminated")
	skin.set_shader_parameter("world_to_head", Transform3D(Basis.IDENTITY, Vector3(0.0, -0.08, -0.05)))
	_check(await _image(), Color(0.7063,0.5275,0.4168), "Rear neck skin rejects hair cast shadow")
	skin.set_shader_parameter("world_to_head", Transform3D(Basis.IDENTITY, Vector3(0.0, -0.08, 0.05)))
	_check(await _image(), Color(0.7063,0.5275,0.4168) * Color(0.94,0.61,0.57), "Front neck keeps contact shadow")
	for scale in [0.5, 2.0]:
		skin.set_shader_parameter("face_bottom", -0.06 * scale)
		skin.set_shader_parameter("face_top", 0.12 * scale)
		skin.set_shader_parameter("face_half_width", 0.0817 * scale)
		skin.set_shader_parameter("world_to_head", Transform3D(Basis.IDENTITY, Vector3(0.0, -0.08, 0.05) * scale))
		_check(await _image(), Color(0.7063,0.5275,0.4168) * Color(0.94,0.61,0.57), "Scaled head keeps chin contact")
		skin.set_shader_parameter("world_to_head", Transform3D(Basis.IDENTITY, Vector3(0.0, -0.13, 0.05) * scale))
		_check(await _image(), Color(0.7063,0.5275,0.4168), "Scaled head bounds contact above the chest")
	skin.set_shader_parameter("world_to_head", Transform3D(Basis.IDENTITY, Vector3(0.4, -0.13, 0.05)))
	_check(await _image(), Color(0.7063,0.5275,0.4168) * Color(0.94,0.61,0.57), "Head contact mask must not suppress limb shadows")
	patch.free()
	if failed:
		quit(1)
		return
	print("STYLIZED_LIGHTING_PASS category fallback, raw-source toggle, cloth contrast, unified hair band, authored Ramp, neck cast split")
	quit()
