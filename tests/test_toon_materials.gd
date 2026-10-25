extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(20.0).timeout.connect(func(): quit(1))
	var model := Node3D.new()
	root.add_child(model)
	var mesh := ArrayMesh.new()
	var metadata := {"materials": []}
	for side in 2:
		var vertices := PackedVector3Array([Vector3(-0.5, -0.5, 0), Vector3(0, 0.5, 0), Vector3(0.5, -0.5, 0)])
		if side == 1:
			vertices.reverse()
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3(0, 0, 1 - side * 2), Vector3(0, 0, 1 - side * 2), Vector3(0, 0, 1 - side * 2)])
		arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var source := StandardMaterial3D.new()
		source.resource_name = "surface%d" % side
		mesh.surface_set_material(side, source)
		metadata.materials.append({"name": source.resource_name, "source_name": "衣", "category": "cloth", "double_sided": false, "edge_enabled": false, "base_color": [1, 1, 1, 1] if side == 0 else [0.1, 0.01, 0.3, 1]})
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	model.add_child(instance)
	var renderer := HonkaiMMDMaterials.new()
	renderer.apply(model, metadata)
	var light := DirectionalLight3D.new()
	root.add_child(light)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.position.z = 2
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1.5
	camera.make_current()
	root.size = Vector2i(320, 240)
	await process_frame
	await RenderingServer.frame_post_draw
	var color := root.get_texture().get_image().get_pixel(160, 120)
	assert(color.r > 0.7 and color.g > 0.7 and color.b > 0.7, "Back-facing purple lining overwrote the white front material")
	model.free()
	light.free()
	camera.free()
	print("TOON_MATERIALS_PASS front/back material fidelity ", color)
	quit(0)
