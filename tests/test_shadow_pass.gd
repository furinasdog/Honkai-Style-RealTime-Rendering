extends SceneTree

const Materials = preload("res://plugins/honkai_mmd/render/materials.gd")


func _initialize() -> void:
	call_deferred("_run")


func _capture() -> Color:
	await physics_frame
	for frame in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image().get_pixel(128,128)


func _run() -> void:
	create_timer(25).timeout.connect(func(): quit(1))
	root.size = Vector2i(256,256)
	var camera := Camera3D.new()
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	root.add_child(camera)
	camera.position.z = 3
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1.5
	camera.make_current()
	var receiver := MeshInstance3D.new()
	root.add_child(receiver)
	receiver.mesh = QuadMesh.new()
	receiver.material_override = StandardMaterial3D.new()
	var caster := MeshInstance3D.new()
	caster.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	root.add_child(caster)
	caster.mesh = SphereMesh.new()
	caster.mesh.radius = 0.15
	caster.mesh.height = 0.3
	caster.position.z = 0.5
	caster.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	var setup := Materials.new()
	for enabled in [true,false]:
		caster.material_override = setup._make_material({"name":"眼白","category":"eye","cast_shadow":enabled,"base_color":[1,1,1,1],"edge_enabled":true},{},null)
		var light := OmniLight3D.new()
		light.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		root.add_child(light)
		light.position = camera.position
		light.omni_range = 10
		light.shadow_bias = 0.001
		light.shadow_normal_bias = 0.01
		light.shadow_enabled = false
		var bright := await _capture()
		light.shadow_enabled = true
		var actual := await _capture()
		assert(actual.g < bright.g-0.05 if enabled else absf(actual.g-bright.g)<0.02,"Source cast flag and outline exclusion must work even when a shadow camera coincides with the main camera")
		light.free()
	caster.free()
	receiver.free()
	print("SHADOW_PASS_PASS coincident camera/light, source caster flag, outline rejection, blocked positive control")
	quit()
