extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(40).timeout.connect(func(): quit(1))
	var receiver = preload("res://scripts/native_mocap.gd").new()
	assert(receiver._prepare_pose_model("full"), receiver.get_error())
	var model := preload("res://tests/test_mocap_retarget.gd")._synthetic_model()
	root.add_child(model)
	var rig: Skeleton3D = model.get_child(0)
	rig.reset_bone_poses()
	var retarget = preload("res://scripts/mocap_retarget.gd").new()
	retarget.settings = preload("res://scripts/mapping_settings.gd").new()
	assert(retarget.apply(rig, model))
	var alignment := CaptureCalibration.new()
	var sequence := 0
	var inference_ms: Array[float] = []
	var mapped_frames := {}
	for fixture in ["pose.jpg", "thumb_up.jpg", "portrait.jpg"]:
		mapped_frames[fixture] = 0
		var image := Image.load_from_file("res://mocap/test_data/" + fixture)
		assert(image != null, "Fetch the documented offline MediaPipe fixtures first")
		image.convert(Image.FORMAT_RGB8)
		for sample in 24:
			var input := image.duplicate() as Image
			if sample >= 12:
				input.flip_x()
			var yaw: float = [-35.0, 0.0, 35.0][int(sample / 8)]
			assert(alignment.update_profile({"enabled": true, "yaw": yaw}))
			sequence += 1
			var start := Time.get_ticks_usec()
			var values = receiver._native.detect_rgb(input.get_data(), input.get_width(), input.get_height(), sequence * 33)
			inference_ms.append((Time.get_ticks_usec() - start) / 1000.0)
			var packet := receiver.decode_frame(values, sequence, sequence * 33)
			assert(not packet.is_empty() and retarget.ingest(alignment.correct_frame(packet)))
			retarget.update(1.0 / 30.0)
			if (fixture == "pose.jpg" and retarget.tracking.pose) or (fixture == "thumb_up.jpg" and retarget.tracking.hands > 0) or (fixture == "portrait.jpg" and retarget.tracking.face):
				mapped_frames[fixture] += 1
			for bone in rig.get_bone_count():
				assert(rig.get_bone_global_pose(bone).is_finite())
				assert(absf(rig.get_bone_pose_rotation(bone).length() - 1.0) < 0.001)
		assert(mapped_frames[fixture] > 0, "The real fixture must reach its actual pose/hand/face mapping consumer")
	for sample in 50:
		sequence += 1
		assert(retarget.ingest({"version": 1, "seq": sequence, "timestamp_ms": sequence * 33, "pose": null, "hands": [], "face": null}))
		retarget.update(1.0 / 30.0)
	assert(not retarget.tracking.pose and not retarget.tracking.face and retarget.tracking.hands == 0)
	for bone: int in retarget._targets:
		assert(rig.get_bone_pose_rotation(bone).angle_to(retarget._neutral_local[bone]) < 0.01)
	assert(not receiver.is_running(), "Offline inference must never open the camera")
	inference_ms.sort()
	print("NATIVE_CAPTURE_REPLAY_PASS ", JSON.stringify({"frames": 72, "model": "full", "mapped_frames": mapped_frames, "p50_inference_ms": inference_ms[36], "p95_inference_ms": inference_ms[68], "camera_opened": false, "mirrored_frames": true, "calibration_yaw": [-35, 0, 35]}))
	receiver.close()
	model.free()
	quit()
