extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(30.0).timeout.connect(func(): quit(1))
	var args := OS.get_cmdline_user_args()
	assert(args.size() == 1)
	var metadata: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	scene._preferences_ready = false
	scene.app_settings._set_mode(1)
	scene.app_settings._gesture_toggle.button_pressed = true
	scene._set_shadows_enabled(false)
	assert(scene._adopt_model(metadata.model_file, metadata, args[0], false))
	assert(scene.retarget.mode == "full_body", "Imported models must retain the selected capture mode")
	assert(scene.retarget.hand_gesture_assistance and not scene.material_setup.shadows_enabled, "New models must inherit gesture and shading settings")
	assert(scene._pose_diagnostic().is_empty(), "No diagnostic can be exported without a capture frame")
	scene._raw_capture_frame = {"seq": 1, "timestamp_ms": 100, "pose": {"world": [[0, 0, 0, 1]], "image": [[0.5, 0.5, 0, 1]]}, "hands": [], "face": {"private": "must not be exported"}, "image": "private RGB fixture"}
	scene._mapped_capture_frame = scene._raw_capture_frame.duplicate(true)
	var diagnostic: Dictionary = scene._pose_diagnostic()
	assert(diagnostic.raw.pose == scene._raw_capture_frame.pose and diagnostic.corrected.pose == scene._mapped_capture_frame.pose)
	assert(not diagnostic.raw.has("face") and not diagnostic.raw.has("image") and diagnostic.bones.has("左腕"))
	var encoded := JSON.stringify(diagnostic)
	assert(not encoded.contains("private") and not encoded.contains(metadata.model_file), "Diagnostics must exclude RGB, face data and model paths")
	if DisplayServer.get_name() == "headless":
		scene.receiver.last_packet_ms = Time.get_ticks_msec()
		scene._save_pose_diagnostic()
		var files := DirAccess.get_files_at("user://diagnostics")
		assert(files.size() == 1 and files[0].ends_with(".json"))
		var stored = JSON.parse_string(FileAccess.get_file_as_string("user://diagnostics/" + files[0]))
		assert(stored is Dictionary and stored.bones.has("左腕") and not stored.raw.has("face"))
		scene.receiver.last_packet_ms = -1
		scene._save_pose_diagnostic()
		assert(DirAccess.get_files_at("user://diagnostics").size() == 1, "Stale frames must not create another diagnostic")
	scene._recenter_capture(false)
	assert(scene._pose_diagnostic().is_empty(), "Recenter must invalidate a stale diagnostic frame")
	var previous: Node3D = scene.actor.model_root
	assert(previous != null and scene.actor.skeleton != null)
	var broken := "res://outputs/invalid_model_transaction.pmx"
	var file := FileAccess.open(broken, FileAccess.WRITE)
	file.store_buffer("not a PMX".to_utf8_buffer())
	file.close()
	assert(not scene._adopt_model(ProjectSettings.globalize_path(broken), {}, "", false))
	assert(scene.actor.model_root == previous and previous.visible, "A failed import destroyed the current character")
	assert(not scene.actor.import_error.is_empty() and not scene.receiver.is_running())
	DirAccess.remove_absolute(ProjectSettings.globalize_path(broken))
	scene.queue_free()
	await process_frame
	print("MODEL_TRANSACTION_PASS original PMX, mapping, physics, failed-import rollback, no webcam")
	quit(0)
