extends "res://tests/test_mocap_retarget.gd"


func _run() -> void:
	create_timer(20.0).timeout.connect(func(): quit(1))
	var calibration := CaptureCalibration.new()
	calibration.settings_path = "user://test_capture_calibration.json"
	var model := _synthetic_model()
	root.add_child(model)
	var skeleton := model.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	var setup = RETARGET.new()
	setup.apply(skeleton, model)
	var source := _packet(skeleton)
	source.hands = [_hand(skeleton, "左"), _hand(skeleton, "右")]
	var head := Basis.from_euler(Vector3(0.1, 0.3, -0.12))
	source.face = {"matrix": _matrix(head), "blendshapes": {"eyeBlinkLeft": 0.7, "jawOpen": 0.3}}
	assert(calibration.correct_frame(source) == source, "Calibration must default off")
	_settle(setup, source)
	var expected := []
	for bone in skeleton.get_bone_count():
		expected.append(skeleton.get_bone_pose_rotation(bone))
	# Generate off-axis camera measurements independently of the correction implementation.
	for yaw in [-45.0, 0.0, 45.0]:
		var camera_to_user := Basis(Vector3.UP, deg_to_rad(yaw)) * Basis(Vector3.RIGHT, deg_to_rad(-20.0)) * Basis(Vector3.BACK, deg_to_rad(12.0))
		var camera_position := camera_to_user.z * 1.5
		assert(calibration.update_profile({"enabled": true, "position": [camera_position.x, camera_position.y, camera_position.z], "roll": 12.0}))
		var measured := source.duplicate(true)
		_turn_points(measured.pose.world, camera_to_user.inverse())
		for hand: Dictionary in measured.hands:
			_turn_points(hand.world, camera_to_user.inverse())
		measured.face.matrix = _matrix(camera_to_user.inverse() * head)
		var untouched := measured.duplicate(true)
		var corrected := calibration.correct_frame(measured)
		assert(measured == untouched, "Correction must not mutate native measurements or the preview")
		assert(corrected.pose.image == source.pose.image and corrected.hands[0].image == source.hands[0].image)
		assert(corrected.face.blendshapes == source.face.blendshapes)
		for index in source.pose.world.size():
			assert(_point(corrected.pose.world[index]).distance_to(_point(source.pose.world[index])) < 0.00001)
		setup.reset()
		_settle(setup, corrected)
		for bone in skeleton.get_bone_count():
			assert(absf(expected[bone].dot(skeleton.get_bone_pose_rotation(bone))) > 0.99999, "Corrected head, arms and hands must match frontal capture")
	calibration.set_device(2)
	assert(not calibration.profile.enabled)
	assert(calibration.update_profile({"enabled": true, "yaw": 9.0}))
	calibration.set_device(0)
	assert(calibration.profile.enabled and calibration.profile.roll == 12.0)
	assert(calibration.save_file() == OK)
	var restored := CaptureCalibration.new()
	restored.settings_path = calibration.settings_path
	assert(restored.load_file() == OK)
	assert(restored.profile.enabled and restored.profile.roll == calibration.profile.roll)
	for axis in 3:
		assert(is_equal_approx(restored.profile.position[axis], calibration.profile.position[axis]))
	restored.set_device(2)
	assert(restored.profile.yaw == 9.0)
	var before := restored.profile.duplicate(true)
	for invalid in [{"position": [0, 0, 0]}, {"position": [NAN, 0, 1]}, {"yaw": INF}, {"unknown": 1}, {"enabled": 1}]:
		assert(not restored.update_profile(invalid) and restored.profile == before)
	restored.reset_device()
	assert(restored.profile == CaptureCalibration.defaults())
	var invalid_file := FileAccess.open(restored.settings_path, FileAccess.WRITE)
	invalid_file.store_string(JSON.stringify({"version": 1, "devices": {"2": {"enabled": true, "position": [0, 0, -1], "yaw": 0, "pitch": 0, "roll": 0}}}))
	invalid_file.close()
	assert(restored.load_file() == OK and restored.profile == CaptureCalibration.defaults(), "Invalid device profiles must fall back to the safe default")
	var panel = preload("res://scripts/capture_calibration_panel.gd").new()
	root.add_child(panel)
	panel.setup(restored)
	panel.popup_centered()
	await process_frame
	panel._top.move_camera(panel._top._center() + Vector2(-1, -2) * panel._top._scale())
	assert(Vector3(restored.profile.position[0], restored.profile.position[1], restored.profile.position[2]).is_equal_approx(Vector3(1, 0, 2)), "Top drag must use the user's anatomical left")
	panel._side.move_camera(panel._side._center() + Vector2(1.5, -0.5) * panel._side._scale())
	assert(Vector3(restored.profile.position[0], restored.profile.position[1], restored.profile.position[2]).is_equal_approx(Vector3(1, 0.5, 1.5)))
	panel._fields.yaw.value = -7
	panel._fields.roll.value = 3
	assert(restored.profile.yaw == -7 and restored.profile.roll == 3, "Every numeric control must bind its own field")
	panel._enabled.button_pressed = true
	assert(restored.profile.enabled)
	for view in [panel._top, panel._side]:
		for x in [-4.0, 4.0]:
			for y in [-4.0, 4.0]:
				var icon: Vector2 = view._center() + (Vector2(4, -y) if view.side else Vector2(-x, -4)) * view._scale()
				assert(Rect2(Vector2(15, 32), view.size - Vector2(30, 42)).has_point(icon), "All allowed camera positions must remain visible")
	if DisplayServer.get_name() != "headless":
		await process_frame
		await RenderingServer.frame_post_draw
		assert(panel.get_texture().get_image().save_png("res://outputs/capture_calibration_ui.png") == OK)
	panel._close()
	assert(FileAccess.file_exists(restored.settings_path))
	assert(panel.get_child(0).get_combined_minimum_size().x <= 850 and panel.get_child(0).get_combined_minimum_size().y <= 680, "Calibration must fit its default window")
	panel.queue_free()
	model.queue_free()
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(restored.settings_path))
	print("CAPTURE_CALIBRATION_PASS: off-axis head/arm/finger retarget, immutable preview, per-device persistence, input validation and dual-view UI; no camera opened")
	quit(0)


func _turn_points(points: Array, transform: Basis) -> void:
	for point: Array in points:
		var direction := transform * Vector3(point[0], -point[1], -point[2])
		point[0] = direction.x
		point[1] = -direction.y
		point[2] = -direction.z
