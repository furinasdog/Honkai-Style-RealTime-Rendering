extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(45.0).timeout.connect(func(): quit(1))
	var args := OS.get_cmdline_user_args()
	assert(args.size() >= 2, "Pass private model metadata and evidence directory")
	var metadata: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	scene._preferences_ready = false
	assert(scene._adopt_model(metadata.model_file, metadata, args[0], false))
	metadata = scene.actor.model_root.get_meta("pmx_metadata", metadata)
	scene.set_process(false)
	scene.hud.visible = false
	scene.stage.set_transparent(false)
	var rig: Skeleton3D = scene.actor.skeleton
	var head := rig.find_bone(str(metadata.head.bone))
	var rest := rig.get_bone_pose_rotation(head)
	var origin := rig.get_bone_global_rest(head).origin
	var bounds: Dictionary = metadata.head
	scene.camera.set_process(false)
	scene.camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	var face_height := float(bounds.face_top) - float(bounds.face_bottom)
	scene.camera.focus = Vector3(0, origin.y + float(bounds.face_bottom) - face_height * 0.45, 0)
	scene.camera.distance = float(bounds.half_width) * 8.4
	scene.camera.pitch = 0.05
	scene.camera._update_transform()
	root.size = Vector2i(960, 720)
	var checks := []
	var mesh: MeshInstance3D = scene.actor.model_root.get_node("MMDMesh")
	var jaw: int = mesh.find_blend_shape_by_name("あ")
	if jaw >= 0:
		mesh.set_blend_shape_value(jaw, 0.5)
	var poses := [0, -20, 20, 40, -40, 60]
	for pitch in poses:
		rig.set_bone_pose_rotation(head, rest * Quaternion(Vector3.RIGHT, deg_to_rad(pitch)))
		for step in 5:
			await process_frame
			scene.material_setup.update_head(rig)
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		assert(image.save_png(args[1].path_join("pitch_%d.png" % pitch)) == OK)
		checks.append({"pitch": pitch, "head_origin": origin, "bounds": bounds})
	rig.set_bone_pose_rotation(head, rest)
	for elevation in [5, 60, 85]:
		scene.key_light.rotation_degrees = Vector3(-float(elevation), 20.0, 0.0)
		for step in 5:
			await process_frame
			scene.material_setup.update_head(rig)
		await RenderingServer.frame_post_draw
		assert(root.get_texture().get_image().save_png(args[1].path_join("elevation_%d.png" % elevation)) == OK)
	for azimuth in [-90, 90, 180]:
		scene.key_light.rotation_degrees = Vector3(-35.0, float(azimuth), 0.0)
		await process_frame
		await RenderingServer.frame_post_draw
		assert(root.get_texture().get_image().save_png(args[1].path_join("azimuth_%d.png" % azimuth)) == OK)
	print("FACE_SHADOW_CAPTURE_PASS ", JSON.stringify({"poses": checks.size(), "light_elevations": [5, 48.4, 60, 85], "light_azimuths": [-90, 90, 180], "azimuth_sweep_elevation": 35, "mouth_open": jaw >= 0, "camera_opened": false}))
	scene.queue_free()
	await process_frame
	quit(0)
