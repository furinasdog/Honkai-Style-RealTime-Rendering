extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(20.0).timeout.connect(func(): quit(1))
	var model := Node3D.new()
	root.add_child(model)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-0.5, 0, 0), Vector3(0.5, 0, 0), Vector3(-0.5, 1, 0), Vector3(0.5, 1, 0)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3(0, -0.8, 0.6), Vector3(0, -0.8, 0.6), Vector3.BACK, Vector3.BACK])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 1, 2, 3])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var source := StandardMaterial3D.new()
	source.resource_name = "Face"
	mesh.surface_set_material(0, source)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	model.add_child(instance)
	var renderer := HonkaiMMDMaterials.new()
	assert(renderer.classify_material("脖子") == "skin")
	assert(renderer.classify_material("脖饰") == "cloth")
	renderer.apply(model, {"head": {"half_width": 0.5, "face_bottom": 0.0, "face_top": 1.0, "nose_height": 0.5}, "materials": [{"name": "Face", "source_name": "Face", "edge_enabled": false, "double_sided": false, "base_color": [1, 1, 1, 1]}]})
	for material in renderer.materials:
		material.set_shader_parameter("world_to_head", Transform3D.IDENTITY)
		material.set_shader_parameter("head_to_world", Transform3D.IDENTITY)
	var light := DirectionalLight3D.new()
	root.add_child(light)
	light.look_at_from_position(Vector3(0, 0.574, 0.819) * 8, Vector3.ZERO)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1.4
	camera.look_at_from_position(Vector3(0, 0.5, 3), Vector3(0, 0.5, 0))
	camera.make_current()
	root.size = Vector2i(320, 320)
	await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var cheek := image.get_pixel(160, 100)
	var jaw := image.get_pixel(160, 250)
	print("TOON_FACE_METRICS cheek=", cheek, " jaw=", jaw)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://outputs"))
	image.save_png("res://outputs/toon_face_lighting.png")
	assert(absf(cheek.g - jaw.g) < 0.02, "Face normals created a lower-face beard band under frontal light")
	light.look_at_from_position(Vector3(0, 0.574, -0.819) * 8, Vector3.ZERO)
	await RenderingServer.frame_post_draw
	var backlit := root.get_texture().get_image().get_pixel(160, 100)
	assert(backlit.g < cheek.g - 0.1, "The face must still switch to its shadow tone when backlit")
	light.look_at_from_position(Vector3(1, 0.574, 0) * 8, Vector3.ZERO)
	await RenderingServer.frame_post_draw
	var side := root.get_texture().get_image()
	var transition_pixels := 0
	for x in range(75, 245):
		var green := side.get_pixel(x, 140).g
		if minf(absf(green - cheek.g), absf(green - backlit.g)) > 0.015:
			transition_pixels += 1
	assert(transition_pixels <= 10, "Side-lit face has an excessively broad gradient instead of a bounded SDF transition")
	model.free()
	light.free()
	camera.free()
	print("TOON_FACE_LIGHTING_PASS no beard, backlit tone retained, two flat side-light tones; edge pixels=", transition_pixels)
	quit(0)
