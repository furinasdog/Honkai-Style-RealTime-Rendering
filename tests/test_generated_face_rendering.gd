extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(20.0).timeout.connect(func(): quit(1))
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	root.add_child(environment)
	var model := Node3D.new()
	root.add_child(model)
	var rig := Skeleton3D.new()
	rig.add_bone("頭")
	model.add_child(rig)
	rig.reset_bone_poses()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-0.1,0,0),Vector3(0,0,0),Vector3(0.1,0,0),Vector3(-0.1,0.2,0),Vector3(0,0.2,0),Vector3(0.1,0.2,0)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.BACK,Vector3.BACK,Vector3.BACK,Vector3.BACK,Vector3.BACK,Vector3.BACK])
	# Both facial halves deliberately share the same mirrored UV region.
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(1,0),Vector2(0,0),Vector2(1,0),Vector2(1,1),Vector2(0,1),Vector2(1,1)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0,4,1,0,3,4,1,5,2,1,4,5])
	var instance := MeshInstance3D.new()
	instance.mesh = ArrayMesh.new()
	instance.mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	var original := StandardMaterial3D.new()
	original.resource_name = "face"
	instance.mesh.surface_set_material(0,original)
	model.add_child(instance)
	var renderer := HonkaiMMDMaterials.new()
	renderer.apply(model,{"archive_sha256":"mirrored-face-gpu-fixture","head":{"bone":"頭","half_width":0.1,"face_bottom":0,"face_top":0.2},"materials":[{"name":"face","source_name":"face","base_color":[1,1,1,1],"edge_enabled":false}]})
	assert(instance.get_active_material(0).get_shader_parameter("has_generated_map"))
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.position = Vector3(0,0.1,2)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 0.3
	camera.make_current()
	root.size = Vector2i(320,240)
	var light := DirectionalLight3D.new()
	light.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	root.add_child(light)
	var sides := []
	for yaw in [90,-90,0,180]:
		light.rotation_degrees.y = yaw
		light.reset_physics_interpolation()
		for frame in 3:
			await process_frame
			await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		sides.append(Vector2(image.get_pixel(120,120).g,image.get_pixel(200,120).g))
	print("GENERATED_FACE_LIGHT_SAMPLES ", sides)
	assert(absf(sides[0].x-sides[0].y)>0.1, "Side lighting must split the face even when both halves share UVs")
	assert(absf(sides[0].x-sides[1].y)<0.03 and absf(sides[0].y-sides[1].x)<0.03, "Opposite lights must exchange the lit and dark halves")
	assert(minf(sides[2].x,sides[2].y)>0.95, "Frontal lighting must illuminate both cheeks")
	assert(maxf(sides[3].x,sides[3].y)<0.85, "Back lighting must not incorrectly illuminate the entire face")
	model.free()
	print("GENERATED_FACE_RENDERING_PASS mirrored UV, left/right light, frontal and rear thresholds ", sides)
	quit()
