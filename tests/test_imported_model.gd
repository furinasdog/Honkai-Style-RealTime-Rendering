extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(60.0).timeout.connect(func(): quit(1))
	var args := OS.get_cmdline_user_args()
	assert(args.size() == 2, "Pass private metadata.json and evidence directory")
	var metadata: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	var world := Node3D.new()
	root.add_child(world)
	var actor = load("res://scripts/actor.gd").new()
	var visual := Node3D.new()
	visual.name = "Visual"
	actor.add_child(visual)
	world.add_child(actor)
	var candidate: Node3D = actor.stage_external(str(metadata.get("model_file", args[0].get_base_dir().path_join("model.glb"))))
	assert(candidate != null)
	actor.commit_model(candidate)
	var triangles := 0
	for instance in candidate.find_children("*", "MeshInstance3D", true, false):
		for surface in instance.mesh.get_surface_count():
			triangles += instance.mesh.surface_get_array_index_len(surface) / 3
	assert(triangles == int(metadata.get("triangle_count", triangles)), "Runtime mesh lost imported faces")
	var materials = load("res://scripts/march_materials.gd").new()
	materials.apply(candidate, metadata)
	var retarget = load("res://scripts/mocap_retarget.gd").new()
	assert(retarget.apply(actor.skeleton, candidate))
	var physics = load("res://scripts/mmd_physics.gd").new()
	assert(physics.apply(actor.skeleton, candidate, metadata.physics))
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.08, 0.09, 0.12)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.6
	world.add_child(environment)
	var light := DirectionalLight3D.new()
	world.add_child(light)
	light.rotation_degrees = Vector3(-25, -25, 0)
	var camera := Camera3D.new()
	world.add_child(camera)
	var head: int = actor.skeleton.find_bone("頭")
	var arm: int = actor.skeleton.find_bone("左腕")
	var head_height: float = (actor.skeleton.global_transform * actor.skeleton.get_bone_global_pose(head).origin).y
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = head_height * 1.4
	camera.look_at_from_position(Vector3(0, head_height * 0.5, 3.2), Vector3(0, head_height * 0.5, 0))
	camera.make_current()
	root.size = Vector2i(960, 720)
	var head_rest: Quaternion = actor.skeleton.get_bone_pose_rotation(head)
	var arm_rest: Quaternion = actor.skeleton.get_bone_pose_rotation(arm)
	for pose in [{"name": "neutral", "head": 0.0, "arm": 0.0}, {"name": "tilt", "head": 0.4, "arm": 0.0}, {"name": "arm", "head": 0.0, "arm": -0.7}]:
		var previous_head: Quaternion = actor.skeleton.get_bone_pose_rotation(head)
		var previous_arm: Quaternion = actor.skeleton.get_bone_pose_rotation(arm)
		for step in Engine.physics_ticks_per_second:
			var amount := float(step + 1) / Engine.physics_ticks_per_second
			actor.skeleton.set_bone_pose_rotation(head, previous_head.slerp(head_rest * Quaternion(Vector3.FORWARD, pose.head), amount))
			var axis := Vector3.FORWARD if metadata.get("loader") == "native_pmx_v1" else Vector3.RIGHT
			actor.skeleton.set_bone_pose_rotation(arm, previous_arm.slerp(arm_rest * Quaternion(axis, pose.arm), amount))
			await physics_frame
			materials.update_head(actor.skeleton)
		await create_timer(0.5).timeout
		await RenderingServer.frame_post_draw
		assert(root.get_texture().get_image().save_png(args[1].path_join(pose.name + ".png")) == OK)
	for index in actor.skeleton.get_bone_count():
		assert(actor.skeleton.get_bone_global_pose(index).is_finite())
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var corner := image.get_pixel(10, 10)
	var foreground := 0
	for y in range(0, image.get_height(), 4):
		for x in range(0, image.get_width(), 4):
			var pixel := image.get_pixel(x, y)
			if absf(pixel.r - corner.r) + absf(pixel.g - corner.g) + absf(pixel.b - corner.b) > 0.05:
				foreground += 1
	assert(foreground > 400, "Imported model is blank")
	assert(image.save_png(args[1].path_join("render.png")) == OK)
	camera.size = head_height * 0.5
	camera.look_at_from_position(Vector3(0, head_height * 0.92, 3.2), Vector3(0, head_height * 0.92, 0))
	await RenderingServer.frame_post_draw
	assert(root.get_texture().get_image().save_png(args[1].path_join("portrait.png")) == OK)
	var report := {"triangles": triangles, "bones": actor.skeleton.get_bone_count(), "bodies": physics.counts.bodies, "camera_opened": false}
	var file := FileAccess.open(args[1].path_join("render_result.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	world.queue_free()
	await process_frame
	print("IMPORTED_MODEL_PASS ", JSON.stringify(report))
	quit(0)
