extends SceneTree

const HELPERS = preload("res://tests/test_hand_gesture_assistance.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(60.0).timeout.connect(func(): quit(1))
	assert(not OS.get_cmdline_user_args().is_empty(), "Pass private native-import result.json paths")
	for path: String in OS.get_cmdline_user_args():
		assert(_exercise(path))
	quit(0)


func _exercise(path: String) -> bool:
	var result: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var metadata: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(result.metadata)) if result.has("metadata") else result
	var loaded := HonkaiPMXLoader.new().load_file(metadata.model_file)
	assert(not loaded.is_empty())
	var model: Node3D = loaded.root
	root.add_child(model)
	var actor = preload("res://scripts/actor.gd").new()
	actor._prepare_pose(model, false)
	actor.free()
	var rig := model.get_node("MMDSkeleton") as Skeleton3D
	var setup = preload("res://scripts/mocap_retarget.gd").new()
	setup.set_hand_gesture_assistance(true)
	assert(setup.apply(rig, model) and setup.hand_gesture_assistance)
	var minimum_rotation_dot := 1.0
	var maximum_joint_angle := 0.0
	for side in ["Left", "Right"]:
		var prefix := "左" if side == "Left" else "右"
		setup.set_hand_gesture_assistance(false)
		setup.reset()
		var packet := HELPERS.frame(HELPERS.hand("fist", side))
		assert(HELPERS.settle(setup, packet))
		var live := HELPERS.finger_targets(setup, prefix)
		var wrist := rig.get_bone_global_pose(rig.find_bone(prefix + "手首"))
		var arm := rig.get_bone_global_pose(rig.find_bone(prefix + "腕"))
		setup.set_hand_gesture_assistance(true)
		assert(HELPERS.settle(setup, packet))
		assert(HELPERS.assert_fist(rig, setup, prefix))
		assert(rig.get_bone_global_pose(rig.find_bone(prefix + "手首")).is_equal_approx(wrist))
		assert(rig.get_bone_global_pose(rig.find_bone(prefix + "腕")).is_equal_approx(arm))
		var bases := HELPERS.capture_bases(rig, prefix)
		for finger in setup.FINGERS:
			for part: String in finger:
				var bone := rig.find_bone(prefix + part)
				var relative: Quaternion = setup._neutral_local[bone].inverse() * rig.get_bone_pose_rotation(bone)
				maximum_joint_angle = maxf(maximum_joint_angle, relative.angle_to(Quaternion.IDENTITY))
		setup.set_hand_gesture_assistance(false)
		for bone: int in live:
			assert(absf(live[bone].dot(setup._targets[bone])) > 0.99999)
		setup.set_hand_gesture_assistance(true)
		setup.reset()
		var rotation := Basis(Vector3(0.4, 0.7, 0.2).normalized(), 1.0)
		assert(HELPERS.settle(setup, HELPERS.frame(HELPERS.hand("fist", side, rotation))))
		for bone: int in bases:
			var expected: Basis = rotation * bases[bone]
			var rotation_dot := absf(rig.get_bone_global_pose(bone).basis.get_rotation_quaternion().dot(expected.get_rotation_quaternion()))
			minimum_rotation_dot = minf(minimum_rotation_dot, rotation_dot)
			assert(rotation_dot > 0.9999, "Native authored finger tails and arbitrary axes must follow palm rotation without reversing flexion")
		assert(HELPERS.settle(setup, HELPERS.frame(HELPERS.hand("open", side))))
		for finger in setup.FINGERS:
			for part: String in finger:
				var bone := rig.find_bone(prefix + part)
				assert(absf(rig.get_bone_pose_rotation(bone).dot(setup._neutral_local[bone])) > 0.999)
		assert(HELPERS.settle(setup, HELPERS.frame(HELPERS.hand("index", side))))
		assert(HELPERS.assert_fist(rig, setup, prefix, true))
		for part: String in setup.FINGERS[1]:
			var bone := rig.find_bone(prefix + part)
			assert(absf(rig.get_bone_pose_rotation(bone).dot(setup._neutral_local[bone])) > 0.999)
	print("HAND_GESTURE_NATIVE_RIG_PASS ", JSON.stringify({"model": path, "sides": 2, "gestures": 3, "maximum_joint_angle_radians": maximum_joint_angle, "palm_rotation_min_dot": minimum_rotation_dot}))
	model.free()
	return true
