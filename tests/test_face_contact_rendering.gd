extends SceneTree

const Materials = preload("res://plugins/honkai_mmd/render/materials.gd")
const Maps = preload("res://plugins/honkai_mmd/render/generated_maps.gd")


func _initialize() -> void:
	call_deferred("_run")


func _capture() -> Image:
	for frame in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func _run() -> void:
	create_timer(20).timeout.connect(func(): quit(1))
	root.size = Vector2i(256,256)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.position = Vector3(0,0.1,2)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 0.24
	camera.make_current()
	var light := DirectionalLight3D.new()
	root.add_child(light)
	var patch := MeshInstance3D.new()
	patch.mesh = QuadMesh.new()
	patch.mesh.size = Vector2(0.2,0.2)
	patch.position.y = 0.1
	root.add_child(patch)
	var arrays := patch.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for index in vertices.size():
		vertices[index] += patch.position
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var head := {"face_bottom":0.0,"face_top":0.2,"half_width":0.1,"eye_height":0.11}
	var setup := Materials.new()
	var material := setup._make_material({"name":"face","category":"face","base_color":[1,1,1,1],"edge_enabled":false},head,null)
	material.set_shader_parameter("world_to_head",Transform3D.IDENTITY)
	material.set_shader_parameter("head_to_world",Transform3D.IDENTITY)
	material.set_shader_parameter("generated_map",Maps.build(arrays,"face",head,Vector3.ZERO))
	material.set_shader_parameter("has_generated_map",true)
	material.set_shader_parameter("rim_strength",0.0)
	var occluded := Shader.new()
	occluded.code = Materials.TOON.code.replace("ATTENUATION","0.0")
	material.shader = occluded
	patch.material_override = material
	var image := await _capture()
	assert(image.get_pixel(128,112).g + 0.03 < image.get_pixel(128,176).g, "Shadow visibility must affect the eye region, while leaving lips/chin lit")
	for row in range(106, 150):
		assert(absf(image.get_pixel(128,row).g - image.get_pixel(128,row+1).g) < 0.035, "Eye-height contact reception must fade without a hard horizontal cut")
	var shared_uv := material.get_shader_parameter("generated_map").get_image() as Image
	for y in shared_uv.get_height():
		for x in shared_uv.get_width():
			var pixel := shared_uv.get_pixel(x,y)
			pixel.a = 0.0
			shared_uv.set_pixel(x,y,pixel)
	material.set_shader_parameter("generated_map",ImageTexture.create_from_image(shared_uv))
	image = await _capture()
	assert(image.get_pixel(128,112).g + 0.03 < image.get_pixel(128,176).g, "Reused UVs or generated alpha must not move the geometric eye contact region")
	material.set_shader_parameter("has_generated_map",false)
	image = await _capture()
	assert(image.get_pixel(128,112).g + 0.03 < image.get_pixel(128,176).g, "Models without generated data need the same safe eye-height fallback")
	material.set_shader_parameter("shadows_enabled",false)
	image = await _capture()
	assert(absf(image.get_pixel(128,112).g-image.get_pixel(128,176).g)<0.01, "Full-bright must bypass contact shading")
	patch.free()
	print("FACE_CONTACT_RENDERING_PASS eye contact, reused UV independence, lower-face protection, geometric fallback and full-bright on actual GPU")
	quit()
