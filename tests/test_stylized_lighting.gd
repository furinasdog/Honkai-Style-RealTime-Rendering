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
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	root.add_child(environment)
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
	_check(await _image(), Color(0.5,0.5,0.5), "Enhanced hair preserves source pigment")
	setup.set_shadows_enabled(false)
	_check(await _image(), Color(0.5,0.5,0.5), "Full bright keeps the same enhanced bright palette")
	setup.set_enhanced(false)
	_check(await _image(), Color(0.5,0.5,0.5), "Disabling enhancement restores original source colors")
	setup.set_shadows_enabled(true)
	setup.set_enhanced(true)
	# Neither head-relative position nor outline pigment changes the lighting normal.
	for position in [Vector3(0, -10, 0), Vector3(0.05, 0.13, -0.065)]:
		material.set_shader_parameter("world_to_head", Transform3D(Basis.IDENTITY, position))
		light.rotation.y = PI
		_check(await _image(), Color(0.5,0.5,0.5) * Materials.SHADOW_TINTS[2], "Backlit hair uses the mesh normal at every head height")
		light.rotation.y = 0
		_check(await _image(), Color(0.5,0.5,0.5), "Lit hair preserves its source at every head height")
	for kind in ["skin", "cloth", "metal"]:
		var receiver := setup._make_material({"name":kind, "category":kind, "base_color":[0.5,0.5,0.5,1], "edge_enabled":false}, {}, null)
		receiver.set_shader_parameter("rim_strength", 0.0)
		receiver.set_shader_parameter("specular_strength", 0.0)
		var occluded := Shader.new()
		occluded.code = Materials.TOON.code.replace("ATTENUATION", "0.0")
		receiver.shader = occluded
		patch.material_override = receiver
		for position in [Vector3(0,-0.08,-0.05), Vector3(0,-0.13,0.05), Vector3(0.4,-0.13,0.05)]:
			receiver.set_shader_parameter("world_to_head", Transform3D(Basis.IDENTITY, position))
			_check(await _image(), Color(0.5,0.5,0.5) * Materials.SHADOW_TINTS[Materials.CATEGORY[kind]], "Occlusion cannot disappear at a guessed neck/chest height: " + kind)
	patch.free()
	if failed:
		quit(1)
		return
	print("STYLIZED_LIGHTING_PASS source toggle, mesh normals at all heights, generic skin/cloth/metal occlusion")
	quit()
