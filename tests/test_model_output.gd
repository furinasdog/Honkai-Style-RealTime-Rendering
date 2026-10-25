extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(40.0).timeout.connect(func(): quit(1))
	var args := OS.get_cmdline_user_args()
	assert(args.size() == 1, "Pass -- <private model metadata.json>; no model is distributed")
	var metadata = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	assert(metadata is Dictionary)
	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	scene._preferences_ready = false
	assert(scene._adopt_model(str(metadata.get("model_file", args[0].get_base_dir().path_join("model.glb"))), metadata, args[0], false))
	assert(scene.actor.skeleton != null and scene.cloth_setup is MMDPhysics)
	scene.camera.distance = 2.4
	scene.camera._update_transform()
	var panel = scene.video_output
	panel.settings_path = "res://outputs/model_output_test.cfg"
	panel._resolution.select(2)
	panel._rate.select(2)
	panel.start_output()
	await create_timer(3.0).timeout
	var first: int = panel._bridge.get_frames()
	var started := Time.get_ticks_msec()
	await create_timer(2.0).timeout
	var elapsed := float(Time.get_ticks_msec() - started) / 1000.0
	var fps := float(panel._bridge.get_frames() - first) / elapsed
	assert(panel._bridge.enabled and panel._bridge.get_frames() > 10)
	await RenderingServer.frame_post_draw
	var image: Image = panel._viewport.get_texture().get_image()
	assert(image.get_size() == Vector2i(1920, 1080) and image.get_pixel(30, 30).a < 0.01)
	assert(image.save_png("res://outputs/model_output_1080.png") == OK)
	var report := {"width": 1920, "height": 1080, "target_fps": 60, "measured_fps": fps, "bodies": scene.cloth_setup.counts.bodies, "joints": scene.cloth_setup.counts.joints, "camera_opened": false, "model_distributed": false}
	report["process_ms"] = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	report["physics_ms"] = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var file := FileAccess.open("res://outputs/model_output_validation.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	panel.stop_output()
	scene.queue_free()
	await process_frame
	print("MODEL_OUTPUT_PASS ", JSON.stringify(report))
	quit(0)
