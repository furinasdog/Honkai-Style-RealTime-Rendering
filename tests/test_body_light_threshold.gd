extends SceneTree

const Materials = preload("res://plugins/honkai_mmd/render/materials.gd")


func _initialize() -> void:
	call_deferred("_run")


func _mesh(n_dot_l: float) -> ArrayMesh:
	var arrays := QuadMesh.new().surface_get_arrays(0)
	var normal := Vector3(sqrt(1.0-n_dot_l*n_dot_l),0,n_dot_l)
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([normal,normal,normal,normal])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	return mesh


func _run() -> void:
	create_timer(30).timeout.connect(func(): quit(1))
	root.size = Vector2i(256,256)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.position.z = 2
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1.5
	camera.make_current()
	var light := DirectionalLight3D.new()
	root.add_child(light)
	var patch := MeshInstance3D.new()
	root.add_child(patch)
	for kind in ["cloth","skin","metal"]:
		var setup := Materials.new()
		var material := setup._make_material({"name":kind,"category":kind,"base_color":[0.5,0.25,0.75,1.0] if kind == "cloth" else [1,1,1,1],"edge_enabled":false},{},null)
		material.set_shader_parameter("rim_strength",0.0)
		material.set_shader_parameter("specular_strength",0.0)
		patch.material_override = material
		for enhanced in [false,true]:
			setup.set_enhanced(enhanced)
			var samples: Array[Color] = []
			for n_dot in [0.15,0.45,-0.8,0.9]:
				patch.mesh = _mesh(n_dot)
				for frame in 3:
					await process_frame
				await RenderingServer.frame_post_draw
				samples.append(root.get_texture().get_image().get_pixel(128,128))
			if enhanced:
				assert(absf(samples[0].g-samples[3].g)<0.015, "%s: enhanced half-Lambert should light N.L=.15" % kind)
			else:
				assert(absf(samples[0].g-samples[2].g)<0.015, "%s: basic mode should keep N.L=.15 in shadow" % kind)
			assert(absf(samples[1].g-samples[3].g)<0.015, "%s: N.L=.45 must stay above the same threshold" % kind)
			assert(samples[2].g+0.05<samples[3].g, "Fixture must contain distinct dark and bright tones")
	var pale_setup := Materials.new()
	patch.material_override = pale_setup._make_material({"name":"pale cloth","category":"cloth","base_color":[1,1,1,1],"edge_enabled":false},{},null)
	var pale_samples := []
	for n_dot in [0.20, -0.55]:
		patch.mesh = _mesh(n_dot)
		for frame in 3:
			await process_frame
		await RenderingServer.frame_post_draw
		pale_samples.append(root.get_texture().get_image().get_pixel(128,128))
	assert(pale_samples[0].get_luminance() > pale_samples[1].get_luminance() + 0.12, "Pale cloth uses the same normal threshold as colored cloth")
	patch.free()
	print("BODY_LIGHT_THRESHOLD_PASS basic .3 and enhanced half-Lambert thresholds, cloth/skin/metal")
	quit()
