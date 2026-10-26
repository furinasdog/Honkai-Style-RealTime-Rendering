extends SceneTree

const ASSIST = preload("res://scripts/hand_gesture_assistance.gd")
const RETARGET = preload("res://scripts/mocap_retarget.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(45.0).timeout.connect(func(): quit(1))
	assert(_classification())
	assert(_model(false))
	assert(_model(true))
	assert(_curve_restore())
	assert(_both_hands())
	print("HAND_GESTURE_ASSISTANCE_PASS fist/open/index, ambiguity/occlusion, dwell/hysteresis, default-off/toggle restoration, both sides/bone axes and palm rotation")
	quit(0)


func _classification() -> bool:
	for side in ["Left", "Right"]:
		for label in ["fist", "open", "index"]:
			for rotation in [Basis.IDENTITY, Basis(Vector3(0.3, 0.7, 0.4).normalized(), 1.2)]:
				var value := hand(label, side, rotation)
				assert(ASSIST.classify(value.world, value.image) == label)
		for label in ["ambiguous", "near_open", "thumbs_up"]:
			var value := hand(label, side)
			assert(ASSIST.classify(value.world, value.image).is_empty(), "Unsupported or borderline gestures must stay realtime")
	var value := hand("fist", "Left")
	var hidden := value.duplicate(true)
	hidden.image[8][0] = -0.1
	assert(ASSIST.classify(hidden.world, hidden.image).is_empty())
	var degenerate := value.duplicate(true)
	degenerate.world[7] = degenerate.world[6].duplicate()
	assert(ASSIST.classify(degenerate.world, degenerate.image).is_empty())
	var filter = ASSIST.new()
	assert(filter.sample("左", value.world, value.image, 0.2).weight == 0.0, "One delayed observation must not count as continuous gesture confirmation")
	assert(filter.sample("左", value.world, value.image, 0.2).weight == 0.0, "Two delayed observations must still wait for a third reliable sample")
	assert(filter.sample("左", value.world, value.image, 0.2).weight > 0.0)
	filter.reset()
	for frame in 8:
		assert(filter.sample("左", value.world, value.image, 1.0 / 60.0).weight == 0.0, "A few confident frames must not immediately snap to a preset")
	for frame in 60:
		filter.sample("左", value.world, value.image, 1.0 / 60.0)
	assert(filter._states["左"].active == "fist" and filter._states["左"].weight > 0.99)
	filter.reset()
	for frame in 80:
		var alternating := hand("open" if frame % 2 == 0 else "fist", "Left")
		assert(filter.sample("左", alternating.world, alternating.image, 1.0 / 60.0).weight == 0.0)
	value = hand("open", "Left")
	for frame in 80:
		filter.sample("左", value.world, value.image, 1.0 / 60.0)
	value = hand("near_open", "Left")
	for frame in 20:
		var state: Dictionary = filter.sample("左", value.world, value.image, 1.0 / 60.0)
		assert(state.gesture == "open" and state.weight > 0.99, "Confirmed gestures need a small release margin against threshold jitter")
	value = hand("ambiguous", "Left")
	var first: Dictionary = filter.sample("左", value.world, value.image, 1.0 / 60.0)
	assert(first.weight > 0.0 and first.weight < 0.8, "Uncertainty must smoothly release assistance instead of forcing the old preset")
	for frame in 30:
		filter.sample("左", value.world, value.image, 1.0 / 60.0)
	assert(filter._states["左"].active.is_empty() and filter._states["左"].weight == 0.0)
	return true


func _model(aligned: bool) -> bool:
	var model := preload("res://tests/test_mocap_retarget.gd")._synthetic_model(aligned)
	root.add_child(model)
	var rig := model.get_child(0) as Skeleton3D
	rig.reset_bone_poses()
	var setup = RETARGET.new()
	assert(setup.apply(rig, model) and not setup.hand_gesture_assistance)
	for side in ["Left", "Right"]:
		setup.set_hand_gesture_assistance(false)
		setup.reset()
		var prefix := "左" if side == "Left" else "右"
		var packet := frame(hand("fist", side))
		assert(settle(setup, packet))
		var live_targets := finger_targets(setup, prefix)
		var wrist := rig.find_bone(prefix + "手首")
		var pure_wrist := rig.get_bone_global_pose(wrist)
		var arm := rig.get_bone_global_pose(rig.find_bone(prefix + "腕"))
		setup.set_hand_gesture_assistance(true)
		assert(settle(setup, packet))
		assert(setup._gesture_assist._states[prefix].active == "fist")
		assert(assert_fist(rig, setup, prefix))
		assert(rig.get_bone_global_pose(wrist).is_equal_approx(pure_wrist), "Gesture assistance must not change the live palm/wrist orientation")
		assert(rig.get_bone_global_pose(rig.find_bone(prefix + "腕")).is_equal_approx(arm))
		var fist_bases := capture_bases(rig, prefix)
		setup.set_hand_gesture_assistance(false)
		for bone: int in live_targets:
			assert(absf(setup._targets[bone].dot(live_targets[bone])) > 0.99999, "Disabling assistance must restore cached live targets without waiting for another camera frame")
		assert(settle(setup, packet))
		setup.set_hand_gesture_assistance(true)
		assert(settle(setup, packet))
		var rotation := Basis(Vector3(0.4, 0.3, 0.8).normalized(), 0.9)
		setup.reset()
		assert(settle(setup, frame(hand("fist", side, rotation))))
		for bone: int in fist_bases:
			var expected: Basis = rotation * fist_bases[bone]
			assert(absf(rig.get_bone_global_pose(bone).basis.get_rotation_quaternion().dot(expected.get_rotation_quaternion())) > 0.9999, "Preset fingers must rotate equivariantly with the live palm")
		assert(settle(setup, frame(hand("open", side))))
		for finger in setup.FINGERS:
			for part: String in finger:
				var bone := rig.find_bone(prefix + part)
				assert(absf(rig.get_bone_pose_rotation(bone).dot(setup._neutral_local[bone])) > 0.999, "Open assistance derives its pose from the model neutral hand")
		assert(settle(setup, frame(hand("index", side))))
		for part: String in setup.FINGERS[1]:
			var bone := rig.find_bone(prefix + part)
			assert(absf(rig.get_bone_pose_rotation(bone).dot(setup._neutral_local[bone])) > 0.999)
		assert(assert_fist(rig, setup, prefix, true))
		setup.set_hand_gesture_assistance(false)
		packet = frame(hand("ambiguous", side))
		assert(settle(setup, packet))
		var ambiguous := capture_bases(rig, prefix)
		setup.set_hand_gesture_assistance(true)
		assert(settle(setup, packet))
		assert(setup._gesture_assist._states[prefix].active.is_empty())
		for bone: int in ambiguous:
			assert(absf(rig.get_bone_global_pose(bone).basis.get_rotation_quaternion().dot(ambiguous[bone].get_rotation_quaternion())) > 0.99999)
		assert(settle(setup, frame(hand("fist", side))))
		assert(settle(setup, {"version": 1, "seq": 0, "timestamp_ms": 0, "pose": null, "hands": [], "face": null}, 1))
		assert(not setup._gesture_assist._states.has(prefix), "Missing or occluded hands must not retain a confirmed preset")
	model.free()
	return true


func _curve_restore() -> bool:
	var model := preload("res://tests/test_mocap_retarget.gd")._synthetic_model(false)
	root.add_child(model)
	var rig := model.get_child(0) as Skeleton3D
	rig.reset_bone_poses()
	var mapping := preload("res://scripts/mapping_settings.gd").new()
	assert(mapping.set_channel_value("left_hand", "smoothing", 0.35))
	var setup = RETARGET.new()
	setup.settings = mapping
	assert(setup.apply(rig, model))
	var packet := frame(hand("fist", "Left"))
	assert(settle(setup, packet))
	var pure := finger_targets(setup, "左")
	setup.set_hand_gesture_assistance(true)
	assert(settle(setup, packet))
	var wrist_key := "left_hand:" + str(rig.find_bone("左手首"))
	var wrist_filter: float = mapping._filtered[wrist_key]
	mapping.map_value("left_arm", 0.4, 1.0 / 60.0, "arm_probe")
	var arm_filter: float = mapping._filtered["left_arm:arm_probe"]
	setup.set_hand_gesture_assistance(false)
	for bone: int in pure:
		assert(absf(setup._targets[bone].dot(pure[bone])) > 0.99999, "Preset angles must not remain in real app curve filters after disabling assistance")
	assert(mapping._filtered.has(wrist_key) and mapping._filtered[wrist_key] == wrist_filter, "Clearing gesture filters must preserve the live wrist filter")
	assert(mapping._filtered["left_arm:arm_probe"] == arm_filter, "Clearing gesture filters must not reset arm history")
	assert(settle(setup, packet, 1))
	for bone: int in pure:
		assert(absf(setup._targets[bone].dot(pure[bone])) > 0.99999, "The next camera frame must not rebound into stale assisted curve history")
	setup.set_hand_gesture_assistance(true)
	packet = frame(hand("ambiguous", "Left"))
	assert(settle(setup, packet, 15))
	var filters := mapping._filtered.duplicate()
	setup.set_hand_gesture_assistance(false)
	assert(mapping._filtered == filters, "An unconfirmed gesture must not alter pure realtime filter history on toggle")
	model.free()
	return true


func _both_hands() -> bool:
	var model := preload("res://tests/test_mocap_retarget.gd")._synthetic_model(false)
	root.add_child(model)
	var rig := model.get_child(0) as Skeleton3D
	rig.reset_bone_poses()
	var setup = RETARGET.new()
	setup.settings = preload("res://scripts/mapping_settings.gd").new()
	assert(setup.apply(rig, model))
	setup.set_hand_gesture_assistance(true)
	var packet := frame(hand("fist", "Left"))
	packet.hands.append(hand("index", "Right"))
	assert(settle(setup, packet))
	assert(setup._gesture_assist._states["左"].active == "fist" and setup._gesture_assist._states["右"].active == "index")
	assert(assert_fist(rig, setup, "左") and assert_fist(rig, setup, "右", true))
	var right_keys := {}
	for key: String in setup.settings._filtered:
		if key.begins_with("right_hand:"):
			right_keys[key] = setup.settings._filtered[key]
	packet.hands[0].image[8][0] = -0.1
	assert(settle(setup, packet, 1))
	assert(not setup._gesture_assist._states.has("左") and setup._gesture_assist._states["右"].active == "index")
	for key: String in right_keys:
		assert(setup.settings._filtered.has(key) and is_equal_approx(setup.settings._filtered[key], right_keys[key]), "Losing one hand must not reset the opposite hand's gesture/curve filters")
	setup.reset()
	packet = frame(hand("fist", "Left"))
	packet.hands.append(hand("ambiguous", "Right"))
	assert(settle(setup, packet))
	packet.hands[1] = hand("near_open", "Right")
	assert(settle(setup, packet, 1))
	right_keys.clear()
	for key: String in setup.settings._filtered:
		if key.begins_with("right_hand:"):
			right_keys[key] = setup.settings._filtered[key]
	setup.set_hand_gesture_assistance(false)
	for key: String in right_keys:
		assert(setup.settings._filtered[key] == right_keys[key], "Disabling the left preset must not advance an unassisted right finger filter twice")
	setup.set_hand_gesture_assistance(true)
	assert(settle(setup, packet))
	packet.hands[0].world[5] = packet.hands[0].world[17].duplicate()
	assert(settle(setup, packet, 1))
	for bone: int in setup._gesture_filter_bones:
		assert(setup._gesture_filter_bones[bone] != "left_hand", "A degenerate palm must discard its assisted curve history")
	model.free()
	return true


static func assert_fist(rig: Skeleton3D, setup: RefCounted, prefix: String, index_point: bool = false) -> bool:
	var wrist := rig.get_bone_global_pose(rig.find_bone(prefix + "手首")).origin
	var along := rig.get_bone_global_pose(rig.find_bone(prefix + "中指１")).origin - wrist
	var across := rig.get_bone_global_pose(rig.find_bone(prefix + "人指１")).origin - rig.get_bone_global_pose(rig.find_bone(prefix + "小指１")).origin
	var normal := across.cross(along).normalized() * (1.0 if prefix == "左" else -1.0)
	for finger in range(1, 5):
		if index_point and finger == 1:
			continue
		var first := rig.find_bone(prefix + setup.FINGERS[finger][0])
		var second := rig.find_bone(prefix + setup.FINGERS[finger][1])
		var proximal := (rig.get_bone_global_pose(second).origin - rig.get_bone_global_pose(first).origin).normalized()
		assert(proximal.dot(normal) > 0.45, "Fingers must close toward the anatomical palm rather than hyperextend dorsally")
		for part: String in setup.FINGERS[finger]:
			var bone := rig.find_bone(prefix + part)
			var relative: Quaternion = setup._neutral_local[bone].inverse() * rig.get_bone_pose_rotation(bone)
			assert(relative.is_normalized() and relative.angle_to(Quaternion.IDENTITY) < 1.95, "Every modeled finger joint must keep a bounded local flexion")
	for part: String in setup.FINGERS[0]:
		var bone := rig.find_bone(prefix + part)
		var relative: Quaternion = setup._neutral_local[bone].inverse() * rig.get_bone_pose_rotation(bone)
		assert(relative.is_normalized() and relative.angle_to(Quaternion.IDENTITY) < 1.95, "Thumb opposition must also stay bounded in arbitrary rig axes")
	return true


static func capture_bases(rig: Skeleton3D, prefix: String) -> Dictionary:
	var result := {}
	for name in [prefix + "手首"]:
		var bone := rig.find_bone(name)
		result[bone] = rig.get_bone_global_pose(bone).basis.orthonormalized()
	for finger in RETARGET.FINGERS:
		for part: String in finger:
			var bone := rig.find_bone(prefix + part)
			result[bone] = rig.get_bone_global_pose(bone).basis.orthonormalized()
	return result


static func finger_targets(setup: RefCounted, prefix: String) -> Dictionary:
	var result := {}
	for finger in RETARGET.FINGERS:
		for part: String in finger:
			var bone: int = setup._indices[prefix + part]
			result[bone] = setup._targets[bone]
	return result


static func hand(gesture: String, side: String, rotation: Basis = Basis.IDENTITY) -> Dictionary:
	var points: Array[Vector3] = [Vector3.ZERO]
	var thumb_open := gesture not in ["fist", "index"]
	var thumb: Array = [Vector3(0.028, 0.012, 0), Vector3(0.047, 0.025, 0), Vector3(0.064, 0.036, 0), Vector3(0.080, 0.044, 0)] if thumb_open else [Vector3(0.028, 0.012, 0), Vector3(0.038, 0.032, 0.006), Vector3(0.028, 0.049, 0.012), Vector3(0.013, 0.054, 0.015)]
	points.append_array(thumb)
	for finger in 4:
		var base: Vector3 = [Vector3(0.028, 0.065, 0), Vector3(0.008, 0.075, 0), Vector3(-0.012, 0.070, 0), Vector3(-0.030, 0.058, 0)][finger]
		var lengths: Array = [[0.030, 0.022, 0.018], [0.033, 0.025, 0.020], [0.031, 0.023, 0.019], [0.025, 0.019, 0.015]][finger]
		var angles: Array = [60.0, 130.0, 190.0]
		if gesture == "open" or (gesture == "index" and finger == 0):
			angles = [0.0, 0.0, 0.0]
		elif gesture == "ambiguous":
			angles = [35.0, 70.0, 95.0]
		elif gesture == "near_open":
			angles = [0.0, 25.0, 25.0]
		points.append(base)
		for segment in 3:
			var angle := deg_to_rad(float(angles[segment]))
			base += Vector3(0, cos(angle), sin(angle)) * lengths[segment]
			points.append(base)
	var world: Array = []
	var image: Array = []
	for point in points:
		if side == "Right":
			point.x = -point.x
		point = rotation * point
		world.append([point.x, -point.y, -point.z])
		image.append([0.5 + point.x * 2.0, 0.6 - point.y * 2.0, 0])
	return {"side": side, "world": world, "image": image}


static func frame(value: Dictionary) -> Dictionary:
	return {"version": 1, "seq": 0, "timestamp_ms": 0, "pose": null, "hands": [value], "face": null}


static func settle(setup: RefCounted, packet: Dictionary, frames: int = 80) -> bool:
	for sample in frames:
		packet.seq = setup._last_sequence + 1
		packet.timestamp_ms = maxf(0, setup._last_timestamp_ms + 1000.0 / 60.0)
		assert(setup.ingest(packet))
		setup.update(1.0 / 60.0)
	return true
