extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(20.0).timeout.connect(func(): quit(1))
	var model := Node3D.new()
	root.add_child(model)
	var metadata := {"materials": []}
	for entry in [
		{"name": "目", "color": [1.0, 0.0, 0.0, 1.0], "z": 0.0, "x": 0.0, "width": 3.0},
		{"name": "发", "color": [0.0, 0.0, 1.0, 1.0], "z": 0.1, "x": 0.0, "width": 3.0},
		{"name": "衣", "color": [0.0, 1.0, 0.0, 1.0], "z": 0.2, "x": 0.6, "width": 0.5}
	]:
		var instance := MeshInstance3D.new()
		instance.mesh = QuadMesh.new()
		instance.mesh.size = Vector2(entry.width, 1.0)
		var source := StandardMaterial3D.new()
		source.resource_name = entry.name
		instance.mesh.material = source
		instance.position = Vector3(entry.x, 0, entry.z)
		model.add_child(instance)
		metadata.materials.append({"name": entry.name, "source_name": entry.name, "base_color": entry.color, "edge_enabled": false})
	var renderer := HonkaiMMDMaterials.new()
	renderer.enhanced = false
	renderer.shadows_enabled = false
	renderer.apply(model, metadata)
	for material in renderer._eye_overlays:
		material.set_shader_parameter("head_to_world", Transform3D.IDENTITY)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.position.z = 2
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2
	camera.make_current()
	root.size = Vector2i(256, 128)
	await process_frame
	await RenderingServer.frame_post_draw
	var before := root.get_texture().get_image()
	assert(before.get_pixel(128, 64).b > 0.9 and before.get_pixel(128, 64).r < 0.1)
	renderer.set_eye_transparency(true, 1.0)
	await process_frame
	await RenderingServer.frame_post_draw
	var after := root.get_texture().get_image()
	assert(after.get_pixel(128, 64).r > 0.9, "The iris must become visible through hair when enabled")
	assert(after.get_pixel(166, 64).g > 0.9 and after.get_pixel(166, 64).r < 0.1, "Eye transparency must not pass through the hand or clothes")
	for material in renderer._eye_overlays:
		material.set_shader_parameter("head_to_world", Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO))
	await process_frame
	await RenderingServer.frame_post_draw
	assert(root.get_texture().get_image().get_pixel(128, 64).b > 0.9, "Turning the head away must disable the overlay even if the eye mesh remains front-facing")
	model.free()
	print("EYE_OVERLAY_PASS off/on, hair-only stencil, foreground occluder, back-view gate")
	quit()
