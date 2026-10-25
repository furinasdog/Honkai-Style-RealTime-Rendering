extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(35.0).timeout.connect(func(): quit(1))
	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	assert(scene.actor.model_root == null, "Run this test in an isolated empty project")
	var subject := MeshInstance3D.new()
	subject.mesh = SphereMesh.new()
	subject.position = Vector3(0, 1.25, 0)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color.RED
	subject.material_override = material
	scene.actor.visual.add_child(subject)
	scene.stage.set_transparent(false)
	scene.stage.set_background_color(Color.BLUE)
	var panel = scene.video_output
	panel.settings_path = "res://outputs/video_test.cfg"
	var report := {"camera_opened": false, "profiles": []}
	for index in panel.RESOLUTIONS.size():
		panel._resolution.select(index + 1)
		panel._rate.select(2 if index == 3 else 1)
		panel.start_output()
		assert(panel._bridge.enabled)
		await create_timer(1.5).timeout
		assert(panel._bridge.get_frames() >= 10, "Output profile did not produce frames")
		var started := Time.get_ticks_msec()
		var first: int = panel._bridge.get_frames()
		await create_timer(1.0).timeout
		var elapsed := float(Time.get_ticks_msec() - started) / 1000.0
		await RenderingServer.frame_post_draw
		var image: Image = panel._viewport.get_texture().get_image()
		assert(image.get_size() == panel.RESOLUTIONS[index])
		assert(image.get_pixel(30, 30).a < 0.01, "Spout view must exclude navigation and background color")
		var center := image.get_pixel(image.get_width() / 2, image.get_height() / 2)
		assert(center.r > 0.9 and center.b < 0.01 and center.a > 0.99, "Output camera must render the shared avatar world")
		var fps := float(panel._bridge.get_frames() - first) / elapsed
		report.profiles.append({"width": image.get_width(), "height": image.get_height(), "target_fps": panel._active_fps, "measured_fps": fps, "alpha": true, "ui_excluded": true})
		print("VIDEO_PROFILE_PASS ", JSON.stringify(report.profiles[-1]))
		panel.stop_output()
		assert(not panel._bridge.enabled)
	assert(not scene.receiver.is_running())
	# Exercise shutdown while an output is active, including externally owned GPU texture retirement.
	panel.start_output()
	await create_timer(0.3).timeout
	root.mode = Window.MODE_MINIMIZED
	await create_timer(0.3).timeout
	var before: int = panel._bridge.get_frames()
	await create_timer(1.2).timeout
	var minimized_frames: int = panel._bridge.get_frames() - before
	assert(minimized_frames >= 30, "Minimizing the window must not stop OBS output")
	report["minimized_frames_in_1_2s"] = minimized_frames
	root.mode = Window.MODE_WINDOWED
	scene.queue_free()
	await process_frame
	var file := FileAccess.open("res://outputs/video_profiles.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	print("VIDEO_OUTPUT_PANEL_PASS: four independent resolutions, alpha, scene/UI exclusion, resize and active shutdown")
	quit(0)
