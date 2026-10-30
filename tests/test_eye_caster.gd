extends SceneTree

const Materials = preload("res://plugins/honkai_mmd/render/materials.gd")


func _initialize() -> void:
	call_deferred("_run")


func _capture(refresh_light: Light3D = null) -> Color:
	if refresh_light != null:
		# Point shadow maps cache static blockers, so force a new pass after uniform-only edits.
		refresh_light.shadow_enabled = false
		await process_frame
		refresh_light.shadow_enabled = true
	await physics_frame
	await physics_frame
	for frame in 4:
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
	var light := OmniLight3D.new()
	light.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	root.add_child(light)
	light.shadow_enabled = false
	light.shadow_bias = 0.001
	light.shadow_normal_bias = 0.01
	light.position.z = 1
	light.omni_range = 10
	var setup := Materials.new()
	var receiver := MeshInstance3D.new()
	receiver.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	root.add_child(receiver)
	receiver.mesh = QuadMesh.new()
	receiver.mesh.size = Vector2.ONE
	receiver.material_override = StandardMaterial3D.new()
	receiver.material_override.albedo_color = Color.WHITE
	var caster := MeshInstance3D.new()
	caster.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	root.add_child(caster)
	caster.mesh = SphereMesh.new()
	caster.mesh.radius = 0.15
	caster.mesh.height = 0.3
	caster.position.z = 0.5
	caster.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	var bright := await _capture()
	light.shadow_enabled = true
	var positive := await _capture(light)
	print("EYE_CASTER_POSITIVE ",positive," BRIGHT ",bright)
	assert(positive.g < bright.g - 0.05, "Closed default blocker must cast before testing eye-material behavior")
	for source in [{"name":"眼白","cast_shadow":true},{"name":"EyeWhite","cast_shadow":true},{"name":"eye","cast_shadow":true},{"name":"口腔","cast_shadow":true},{"name":"mouth","cast_shadow":true},{"name":"眉毛","cast_shadow":true},{"name":"Eyebrow","cast_shadow":true},{"name":"睫毛","cast_shadow":true},{"name":"EyeLash","cast_shadow":true},{"name":"eye","cast_shadow":false}]:
		var entry: Dictionary = source.duplicate()
		entry.category = "eye"
		entry.base_color = [1,1,1,1]
		entry.edge_enabled = false
		var material := setup._make_material(entry,{},null)
		caster.material_override = material
		if source.name == "眼白":
			var current := material.shader
			var legacy := Shader.new()
			legacy.code = current.code.replace("(!casts_shadows || (enhanced && category == 5 && detail_kind > 0))", "(category == 5 || !casts_shadows)")
			material.shader = legacy
			assert(absf((await _capture(light)).g-bright.g)<0.02, "Legacy blanket eye exclusion must reproduce the missing shadow")
			material.shader = current
		var thin := "眉" in str(source.name) or "睫" in str(source.name) or "brow" in str(source.name).to_lower() or "lash" in str(source.name).to_lower()
		for enhanced in [true,false]:
			material.set_shader_parameter("enhanced",enhanced)
			var actual := await _capture(light)
			var expects_shadow: bool = source.cast_shadow and (not enhanced or not thin)
			print("EYE_SHADOW_SAMPLE ",source," enhanced=",enhanced," actual=",actual," bright=",bright)
			assert((actual.g < bright.g - 0.05) if expects_shadow else absf(actual.g-bright.g)<0.02,"Opaque eye/oral surfaces must close head shadow holes; enhanced thin details stay flat; source cast flags remain effective")
	var model := Node3D.new()
	root.add_child(model)
	caster.reparent(model)
	caster.material_override = null
	caster.mesh.material = StandardMaterial3D.new()
	caster.mesh.material.resource_name = "眉毛"
	setup.apply(model,{"materials":[{"name":"眉毛","source_name":"眉毛","base_color":[1,1,1,1],"cast_shadow":true,"edge_enabled":false}]})
	for enabled in [false,true,false,true]:
		setup.set_enhanced(enabled)
		var actual := await _capture()
		assert(absf(actual.g-bright.g)<0.02 if enabled else actual.g<bright.g-0.05, "Public enhancement toggle must refresh a stationary point-light shadow without moving camera/light/caster")
		assert(caster.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY, "Refreshing must preserve the original geometry shadow setting")
	caster.reparent(root)
	model.free()
	caster.free()
	setup.set_enhanced(false)
	receiver.free()
	print("EYE_CAST_SHADOW_PASS opaque eye/oral blockers, thin detail exclusion, source flag, enhanced/raw modes and stationary point-light cache refresh")
	quit()
