extends SceneTree

const MATERIALS = preload("res://scripts/march_materials.gd")


func _initialize() -> void:
	call_deferred("_run")


func _capture(path: String) -> void:
	for frame in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var occupied := image.get_used_rect()
	assert(occupied.size.x > image.get_width() / 8 and occupied.size.y > image.get_height() / 4, "Capture must contain a rendered model")
	assert(image.save_png(path) == OK)


func _run() -> void:
	create_timer(120.0).timeout.connect(func(): quit(1))
	var args := OS.get_cmdline_user_args()
	assert(args.size() == 2)
	assert(DirAccess.make_dir_recursive_absolute(args[1]) == OK)
	var pmx_path: String = args[0].replace("\\", "/")
	var loader := HonkaiPMXLoader.new()
	var result := loader.load_file(pmx_path, {"cache_root": pmx_path.get_base_dir(), "aliases": {}})
	assert(not result.is_empty(), loader.error)
	var actor = preload("res://scripts/actor.gd").new()
	var visual := Node3D.new()
	visual.name = "Visual"
	actor.add_child(visual)
	root.add_child(actor)
	result.root.set_meta("pmx_metadata", result.metadata)
	var model: Node3D = actor.stage_prepared(result.root)
	assert(model != null)
	actor.commit_model(model)
	var renderer = MATERIALS.new()
	renderer.apply(model, model.get_meta("pmx_metadata"))
	renderer.set_enhanced(true)
	renderer.set_pmx_outline_colors(false)
	renderer.set_outline_width(2.6)
	renderer.set_shadow_threshold(0.30)
	renderer.set_shadows_enabled(true)
	var rig: Skeleton3D = actor.skeleton
	var head_index := rig.find_bone("頭")
	assert(head_index >= 0, "Head bone is required for matched upper-body capture")
	var head_y: float = rig.get_bone_global_rest(head_index).origin.y
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.far = 12.0
	camera.make_current()
	root.size = Vector2i(800, 1000)
	root.transparent_bg = true
	root.msaa_3d = Viewport.MSAA_4X
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.15
	root.add_child(environment)
	var light := DirectionalLight3D.new()
	light.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	root.add_child(light)
	var azimuth := deg_to_rad(20.0)
	var elevation := deg_to_rad(48.4)
	var direction := Vector3(sin(azimuth) * cos(elevation), sin(elevation), cos(azimuth) * cos(elevation))
	light.look_at_from_position(direction * 8.0, Vector3.ZERO)
	light.light_energy = 0.85
	light.light_angular_distance = 0.0
	light.shadow_enabled = true
	light.shadow_bias = 0.05
	light.shadow_normal_bias = 0.8
	RenderingServer.directional_shadow_atlas_set_size(8192, false)
	light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	light.directional_shadow_max_distance = 14.0
	var full_focus := Vector3(0.0, float(result.metadata.get("height", 1.7)) * 0.51, 0.0)
	camera.size = float(result.metadata.get("height", 1.7)) * 1.29
	camera.look_at_from_position(full_focus + Vector3(0.0, 0.02, 3.0), full_focus)
	renderer.update_head(rig)
	await _capture(args[1].path_join("front_full.png"))
	camera.size = 0.93
	var upper_focus := Vector3(0.0, head_y - 0.16, 0.0)
	camera.look_at_from_position(upper_focus + Vector3(0.72, 0.02, 0.69).normalized() * 3.0, upper_focus)
	rig.set_bone_pose_rotation(head_index, rig.get_bone_pose_rotation(head_index) * Quaternion(Vector3.UP, deg_to_rad(15.0)))
	renderer.update_head(rig)
	await _capture(args[1].path_join("quarter_upper.png"))
	rig.set_bone_pose_rotation(head_index, rig.get_bone_pose_rotation(head_index) * Quaternion(Vector3.UP, deg_to_rad(-15.0)))
	root.size = Vector2i(800, 1000)
	camera.look_at_from_position(upper_focus + Vector3(0.0, 0.02, 3.0), upper_focus)
	var angles := {"front":0.0, "left_three_quarter":-45.0, "left_profile":-90.0, "back":180.0, "right_three_quarter":45.0, "turn_minus":-44.0, "turn_plus":-46.0}
	for view in angles:
		actor.rotation.y = deg_to_rad(float(angles[view]))
		actor.reset_physics_interpolation()
		await process_frame
		renderer.update_head(rig)
		await _capture(args[1].path_join(view + ".png"))
	var record := FileAccess.open(args[1].path_join("metadata.json"), FileAccess.WRITE)
	record.store_string(JSON.stringify(result.metadata, "  "))
	record.close()
	print("GENERIC_MODEL_CAPTURE_PASS name=", result.metadata.name, " height=", result.metadata.height)
	quit()
