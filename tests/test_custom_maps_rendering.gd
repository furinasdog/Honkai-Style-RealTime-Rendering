extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(20.0).timeout.connect(func(): quit(1))
	var model := Node3D.new()
	root.add_child(model)
	var metadata := {"archive_sha256": "gpu-map-fixture", "materials": []}
	var instances: Array[MeshInstance3D] = []
	for index in 2:
		var instance := MeshInstance3D.new()
		instance.mesh = QuadMesh.new()
		instance.mesh.size = Vector2(0.8,0.8)
		var source := StandardMaterial3D.new()
		source.resource_name = "face" if index == 0 else "cloth"
		instance.mesh.material = source
		instance.position.x = -0.5 if index == 0 else 0.5
		model.add_child(instance)
		instances.append(instance)
		metadata.materials.append({"name": source.resource_name, "source_name": source.resource_name, "base_color": [1,1,1,1], "edge_enabled": false})
	var renderer := HonkaiMMDMaterials.new()
	renderer.enhanced = false
	renderer.apply(model,metadata)
	var source_image := Image.create(4,4,false,Image.FORMAT_RGBA8)
	source_image.fill(Color.BLACK)
	assert(source_image.save_png("user://black.png") == OK)
	source_image.fill(Color.WHITE)
	assert(source_image.save_png("user://white.png") == OK)
	source_image.fill(Color.RED)
	assert(source_image.save_png("user://red.png") == OK)
	assert(renderer.import_custom_map("face","face_sdf","user://black.png"))
	assert(renderer.import_custom_map("cloth","warm_ramp","user://red.png"))
	renderer.set_enhanced(true)
	var light := DirectionalLight3D.new()
	root.add_child(light)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.position.z = 2
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1.5
	camera.make_current()
	root.size = Vector2i(320,240)
	await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var dark := image.get_pixel(80,120)
	var red := image.get_pixel(240,120)
	assert(dark.g < 0.9, "Imported black SDF must produce the dark face tone")
	assert(red.r > 0.9 and red.g < 0.05 and red.b < 0.05, "Imported Ramp must control the actual rendered clothing color")
	assert(renderer.import_custom_map("face","face_sdf","user://white.png"))
	await process_frame
	await RenderingServer.frame_post_draw
	var bright := root.get_texture().get_image().get_pixel(80,120)
	assert(bright.g > dark.g + 0.1 and bright.g > 0.9, "Replacing SDF must affect rendered pixels, not only settings")
	renderer.set_enhanced(false)
	await process_frame
	await RenderingServer.frame_post_draw
	assert(root.get_texture().get_image().get_pixel(240,120).g > 0.9, "Disabling enhancement must restore the source color")
	model.free()
	print("CUSTOM_MAPS_RENDERING_PASS SDF shadow/light replacement, exact Ramp color and source fallback")
	quit()
