extends SceneTree

const RETARGET = preload("res://scripts/mocap_retarget.gd")
var sequence := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(15.0).timeout.connect(func(): quit(1))
	assert(_test_near_neutral_rotations())
	assert(_test_elbow_plane())
	assert(_test_pmx_finger_axes())
	var model := _synthetic_model()
	root.add_child(model)
	for animator in model.find_children("*", "AnimationPlayer", true, false):
		animator.active = false
	var skeleton := model.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	skeleton.reset_bone_poses()
	var mesh := model.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	mesh.set_blend_shape_value(_shape(mesh, "まばたき"), 0.09)
	mesh.set_blend_shape_value(_shape(mesh, "瞳小"), 0.04)
	var lower := {}
	for name in ["腰", "下半身", "左足D", "右足D", "左ひざD", "右ひざD", "左足首D", "右足首D"]:
		var index := skeleton.find_bone(name)
		lower[index] = skeleton.get_bone_global_pose(index)
	var setup = RETARGET.new()
	setup.apply(skeleton, model)
	var turn_packet := _packet(skeleton)
	var upper_index := skeleton.find_bone("左腕")
	var upper_rest := skeleton.get_bone_global_pose(upper_index).basis.orthonormalized()
	var lean := Basis(Vector3.RIGHT, 0.3)
	var shoulder_center := (_position(skeleton, "左腕") + _position(skeleton, "右腕")) * 0.5
	for point_index in [11, 12, 13, 14, 15, 16, 23, 24]:
		turn_packet.pose.world[point_index] = _mp(shoulder_center + lean * (_point(turn_packet.pose.world[point_index]) - shoulder_center))
	_settle(setup, turn_packet)
	var leaned_upper := skeleton.get_bone_global_pose(upper_index).basis.orthonormalized()
	assert(absf(leaned_upper.get_rotation_quaternion().dot((lean * upper_rest).get_rotation_quaternion())) > 0.999, "Torso lean must carry upper-arm twist, not counter-rotate the arm to its world neutral basis")
	setup.reset()
	var packet := _packet(skeleton)
	var left_shoulder := _position(skeleton, "左腕")
	var upper_direction := Vector3(0.8, 0.5, 0.05).normalized()
	var forearm_direction := Vector3(-0.1, 0.3, 0.7).normalized()
	var elbow := left_shoulder + upper_direction * 0.24
	var wrist := elbow + forearm_direction * 0.22
	packet.pose.world[13] = _mp(elbow)
	packet.pose.world[15] = _mp(wrist)
	_settle(setup, packet)
	var actual_upper := (_position(skeleton, "左ひじ") - _position(skeleton, "左腕")).normalized()
	var actual_forearm := (_position(skeleton, "左手首") - _position(skeleton, "左ひじ")).normalized()
	assert(actual_upper.dot(upper_direction) > 0.995, "Left upper arm must follow anatomical left landmarks")
	assert(actual_forearm.dot(forearm_direction) > 0.995, "Elbow target must be converted through its actual parent/rest spaces")
	assert(setup.tracking.pose)
	for index: int in lower:
		assert(skeleton.get_bone_global_pose(index).is_equal_approx(lower[index]), "Upper-body capture changed a lower-body bone")

	setup.reset()
	packet = _packet(skeleton)
	var hand := _hand(skeleton, "左")
	var mcp := _point(hand.world[5])
	var width := (_point(hand.world[5]) - _point(hand.world[17])).normalized()
	var first_direction := (_point(hand.world[6]) - mcp).normalized().rotated(width, 1.0)
	var second_direction := first_direction.rotated(width, 0.7)
	hand.world[6] = _mp3(mcp + first_direction * 0.035)
	hand.world[7] = _mp3(mcp + first_direction * 0.035 + second_direction * 0.02)
	hand.world[8] = _mp3(mcp + first_direction * 0.035 + second_direction * 0.035)
	# An intentionally wrong detector label must be corrected by image-space wrist association.
	hand.side = "Right"
	hand.image[0] = packet.pose.image[15].slice(0, 3)
	packet.hands = [hand]
	var head_basis := Basis.from_euler(Vector3(0.2, 0.4, 0.1))
	packet.face = {"blendshapes": {"eyeBlinkLeft": 1.0, "eyeBlinkRight": 0.0, "jawOpen": 0.8, "mouthSmileLeft": 0.5, "mouthSmileRight": 0.5}, "matrix": _matrix(head_basis)}
	var neutral_head := skeleton.get_bone_global_pose(skeleton.find_bone("頭")).basis.orthonormalized()
	_settle(setup, packet)
	assert(setup.tracking.left_hand and not setup.tracking.right_hand and setup.tracking.hands == 1)
	var actual_finger := (_position(skeleton, "左人指２") - _position(skeleton, "左人指１")).normalized()
	assert(actual_finger.dot(first_direction) > 0.99, "Finger segments must follow captured curl")
	var actual_head := skeleton.get_bone_global_pose(skeleton.find_bone("頭")).basis.orthonormalized()
	assert(absf(actual_head.get_rotation_quaternion().dot((head_basis * neutral_head).get_rotation_quaternion())) > 0.999, "Face matrix head rotation must survive parent-space conversion")
	assert(mesh.get_blend_shape_value(_shape(mesh, "ウィンク")) > 0.88, "Left blink must reach left eyelid")
	assert(mesh.get_blend_shape_value(_shape(mesh, "ウィンク右")) < 0.01, "Left blink must not close right eyelid")
	assert(mesh.get_blend_shape_value(_shape(mesh, "あ")) > 0.7, "Jaw-open must reach the mouth morph")
	assert(is_equal_approx(mesh.get_blend_shape_value(_shape(mesh, "瞳小")), 0.04), "Retarget must preserve render-only pupil defaults")
	assert(not setup.ingest(packet), "Duplicate packets must not restart tracking freshness")
	var restarted := packet.duplicate(true)
	restarted.seq = 0
	restarted.timestamp_ms = packet.timestamp_ms + 1
	assert(setup.ingest(restarted), "A restarted sender may reset seq when its monotonic timestamp advances")
	assert(not setup.ingest(restarted), "Repeated restart packets are still duplicates")
	assert(not setup.ingest(packet), "Packets older than a sender restart must be ignored")
	var malformed := packet.duplicate(true)
	malformed.seq = sequence + 1
	malformed.pose.world[11][0] = NAN
	assert(not setup.ingest(malformed), "Nonfinite network coordinates must be rejected")
	malformed.pose.world = []
	assert(not setup.ingest(malformed), "Malformed landmark arrays must be rejected")
	malformed = packet.duplicate(true)
	malformed.seq = sequence + 1
	malformed.timestamp_ms += 2
	malformed.face.matrix[0] = 1.0e100
	assert(not setup.ingest(malformed), "Oversized face matrices must not overflow float skeleton transforms")
	for frame in 40:
		setup.update(0.05)
	assert(not setup.tracking.pose and not setup.tracking.face and setup.tracking.hands == 0)
	assert(mesh.get_blend_shape_value(_shape(mesh, "あ")) < 0.001, "Missing face must not leave the mouth frozen open")
	assert(absf(mesh.get_blend_shape_value(_shape(mesh, "まばたき")) - 0.09) < 0.001, "Tracking loss must restore relaxed neutral eyelids")
	assert(absf(skeleton.get_bone_pose_rotation(skeleton.find_bone("左腕")).dot(setup._neutral_local[skeleton.find_bone("左腕")])) > 0.999, "Missing pose must return to neutral")
	for index: int in lower:
		assert(skeleton.get_bone_global_pose(index).is_equal_approx(lower[index]), "Tracking loss changed lower-body pose")
	setup.reset()
	packet = _packet(skeleton)
	hand = _hand(skeleton, "左")
	var neutral_finger := skeleton.get_bone_global_pose(skeleton.find_bone("左人指１")).basis.orthonormalized()
	var hand_origin := _point(hand.world[0])
	var hand_direction := (_point(hand.world[9]) - hand_origin).normalized()
	var roll := Basis(hand_direction, 1.0)
	for index in hand.world.size():
		hand.world[index] = _mp3(hand_origin + roll * (_point(hand.world[index]) - hand_origin))
	hand.image[0] = packet.pose.image[15].slice(0, 3)
	packet.hands = [hand]
	_settle(setup, packet)
	var rolled_finger := skeleton.get_bone_global_pose(skeleton.find_bone("左人指１")).basis.orthonormalized()
	assert(absf(rolled_finger.get_rotation_quaternion().dot((roll * neutral_finger).get_rotation_quaternion())) > 0.999, "Palm roll must carry finger twist instead of canceling it")
	_test_settings(setup, skeleton, mesh)
	_test_partial_models()
	print("MOCAP_RETARGET_PASS elbow-plane twist, PMX finger axes/authored tails, palm rotation, torso-carried arm twist, parent spaces, settings, optional bones/morphs, sender restart and fixed lower body")
	quit(0)


func _test_settings(setup: RefCounted, skeleton: Skeleton3D, mesh: MeshInstance3D) -> void:
	var mapping := preload("res://scripts/mapping_settings.gd").new()
	for channel: String in mapping.channels:
		mapping.set_channel_value(channel, "smoothing", 0.0)
	setup.settings = mapping
	setup.reset()
	mapping.set_channel_value("left_eye", "lower", 0.2)
	mapping.set_channel_value("left_eye", "upper", 0.6)
	mapping.set_channel_value("right_eye", "lower", 0.5)
	mapping.set_channel_value("right_eye", "upper", 0.9)
	var packet := _packet(skeleton)
	packet.face = {"blendshapes": {"eyeBlinkLeft": 0.4, "eyeBlinkRight": 0.4, "jawOpen": 0.26}, "matrix": _matrix(Basis.IDENTITY)}
	mapping.set_channel_value("jaw_open", "precision", 2)
	_settle(setup, packet)
	assert(absf(mesh.get_blend_shape_value(_shape(mesh, "ウィンク")) - 0.455) < 0.003, "Configured open/closed thresholds must remap the left eyelid")
	assert(mesh.get_blend_shape_value(_shape(mesh, "ウィンク右")) < 0.001, "The right eye must use its own thresholds")
	assert(absf(mesh.get_blend_shape_value(_shape(mesh, "あ")) - 0.45) < 0.003, "Configured output precision must affect the actual mouth morph")
	mapping.set_channel_value("left_eye", "invert", true)
	packet.face.blendshapes.eyeBlinkLeft = 0.1
	_settle(setup, packet)
	assert(mesh.get_blend_shape_value(_shape(mesh, "ウィンク")) > 0.9, "Eye inversion must change the mapped eyelid")
	mapping.set_channel_value("left_eye", "enabled", false)
	_settle(setup, packet)
	assert(mesh.get_blend_shape_value(_shape(mesh, "ウィンク")) < 0.001, "Disabled eye channels must release their morph")
	setup.reset()
	packet = _packet(skeleton)
	var shoulder := _position(skeleton, "左腕")
	packet.pose.world[13] = _mp(shoulder + Vector3(0.2, 0.2, 0.0))
	packet.pose.world[15] = _mp(shoulder + Vector3(0.2, 0.4, 0.1))
	_settle(setup, packet)
	var index := skeleton.find_bone("左腕")
	var neutral: Quaternion = setup._neutral_local[index]
	var forward := (neutral.inverse() * skeleton.get_bone_pose_rotation(index)).normalized()
	mapping.set_channel_value("left_arm", "invert", true)
	_settle(setup, packet)
	var reverse := (neutral.inverse() * skeleton.get_bone_pose_rotation(index)).normalized()
	assert(absf(reverse.dot(forward.inverse())) > 0.999, "Arm inversion must affect actual local joint rotations")
	mapping.set_channel_value("left_arm", "enabled", false)
	_settle(setup, packet)
	assert(absf(skeleton.get_bone_pose_rotation(index).dot(neutral)) > 0.999, "Disabled arms must retain their neutral local pose")
	setup.reset()
	setup.settings = null


func _test_partial_models() -> void:
	var model := Node3D.new()
	root.add_child(model)
	var rig := Skeleton3D.new()
	model.add_child(rig)
	for name in ["LeftArm", "LeftForeArm", "LeftHand"]:
		rig.add_bone(name)
	rig.set_bone_parent(1, 0)
	rig.set_bone_parent(2, 1)
	rig.set_bone_rest(0, Transform3D(Basis.IDENTITY, Vector3(0.2, 1.4, 0)))
	rig.set_bone_rest(1, Transform3D(Basis.IDENTITY, Vector3(0.25, 0, 0)))
	rig.set_bone_rest(2, Transform3D(Basis.IDENTITY, Vector3(0.25, 0, 0)))
	rig.reset_bone_poses()
	var setup = RETARGET.new()
	assert(setup.apply(rig, model), "A standard English arm chain without face/fingers must remain usable")
	assert(setup.capabilities.left_arm and not setup.capabilities.right_arm and not setup.capabilities.face)
	var points: Array = []
	for point in 33:
		points.append([0, 0, 0, 0])
	points[11] = _mp(Vector3(0.2, 1.4, 0))
	points[13] = _mp(Vector3(0.4, 1.6, 0))
	points[15] = _mp(Vector3(0.4, 1.8, 0.1))
	var packet := {"version": 1, "seq": 0, "timestamp_ms": 0, "pose": {"world": points, "image": _image_points(points)}, "hands": [], "face": null}
	_settle(setup, packet)
	var direction := (rig.get_bone_global_pose(1).origin - rig.get_bone_global_pose(0).origin).normalized()
	assert(direction.dot(Vector3(1, 1, 0).normalized()) > 0.995)
	var invalid := Skeleton3D.new()
	model.add_child(invalid)
	invalid.add_bone("Unrelated")
	assert(not setup.apply(invalid, model), "An incompatible skeleton must return an error instead of asserting")
	assert(not setup.warnings.is_empty())
	model.free()


func _settle(setup: RefCounted, packet: Dictionary) -> void:
	for frame in 80:
		sequence += 1
		packet.seq = sequence
		packet.timestamp_ms = sequence * 17
		assert(setup.ingest(packet))
		setup.update(1.0 / 60.0)


func _packet(skeleton: Skeleton3D) -> Dictionary:
	var points: Array = []
	for index in 33:
		points.append([0.0, 0.0, 0.0, 0.0])
	for pair in [[11, "左腕"], [12, "右腕"], [13, "左ひじ"], [14, "右ひじ"], [15, "左手首"], [16, "右手首"]]:
		points[pair[0]] = _mp(_position(skeleton, pair[1]))
	var center := (_position(skeleton, "左腕") + _position(skeleton, "右腕")) * 0.5
	points[23] = _mp(center + Vector3(0.15, -0.45, 0.0))
	points[24] = _mp(center + Vector3(-0.15, -0.45, 0.0))
	var image: Array = []
	for point in points:
		image.append([0.5 + point[0] * 0.5, 0.9 + point[1] * 0.5, point[2], point[3]])
	return {"version": 1, "seq": sequence, "timestamp_ms": sequence * 17, "pose": {"world": points, "image": image}, "hands": [], "face": null}


func _hand(skeleton: Skeleton3D, side: String) -> Dictionary:
	var points: Array = [_mp3(_position(skeleton, side + "手首"))]
	for finger in RETARGET.FINGERS:
		for part: String in finger:
			points.append(_mp3(_position(skeleton, side + part)))
		var bone := skeleton.find_bone(side + finger[2])
		var pose := skeleton.get_bone_global_pose(bone)
		var previous := _position(skeleton, side + finger[1])
		points.append(_mp3(pose.origin + (pose.origin - previous).normalized() * 0.018))
	return {"side": "Left", "world": points, "image": _image_points(points)}


func _image_points(points: Array) -> Array:
	var result: Array = []
	for point in points:
		var value := [0.5 + point[0] * 0.2, 0.9 + point[1] * 0.3, point[2]]
		if point.size() == 4:
			value.append(point[3])
		result.append(value)
	return result


func _position(skeleton: Skeleton3D, bone_name: String) -> Vector3:
	return skeleton.get_bone_global_pose(skeleton.find_bone(bone_name)).origin


func _mp(value: Vector3) -> Array:
	return [value.x, -value.y, -value.z, 1.0]


func _mp3(value: Vector3) -> Array:
	return [value.x, -value.y, -value.z]


func _point(value: Array) -> Vector3:
	return Vector3(value[0], -value[1], -value[2])


func _matrix(basis: Basis) -> Array:
	return [basis.x.x, basis.y.x, basis.z.x, 0.0, basis.x.y, basis.y.y, basis.z.y, 0.0, basis.x.z, basis.y.z, basis.z.z, 0.0, 0.0, 0.0, 0.0, 1.0]


func _test_near_neutral_rotations() -> bool:
	var setup = RETARGET.new()
	setup.settings = preload("res://scripts/mapping_settings.gd").new()
	for sample in 100:
		var neutral := Quaternion.from_euler(Vector3(sample * 0.017, sample * -0.023, sample * 0.031))
		setup._neutral_local[0] = neutral
		for small_angle in [0.0, 0.00000001, 0.000001, 0.0001, 0.001]:
			var rotation := (neutral * Quaternion(Vector3.RIGHT, small_angle)).normalized()
			var mapped: Quaternion = setup._map_joint_rotation(0, rotation, "left_arm")
			assert(mapped.is_normalized(), "Near-neutral mapping must stay a valid rotation")
			for axis: Vector3 in setup._joint_axes.values():
				assert(axis.is_normalized(), "Tiny rotations must not cache an unstable axis")
	return true


func _shape(mesh: MeshInstance3D, shape_name: String) -> int:
	for index in mesh.mesh.get_blend_shape_count():
		if mesh.mesh.get_blend_shape_name(index) == shape_name:
			return index
	assert(false, "Missing test morph: " + shape_name)
	return -1


func _test_elbow_plane() -> bool:
	var model := _synthetic_model()
	root.add_child(model)
	var rig := model.get_child(0) as Skeleton3D
	rig.reset_bone_poses()
	var setup = RETARGET.new()
	assert(setup.apply(rig, model))
	var packet := _packet(rig)
	var elbow := _position(rig, "左ひじ")
	packet.pose.world[15] = _mp(elbow + Vector3.BACK * 0.22)
	_settle(setup, packet)
	var bone := rig.find_bone("左腕")
	var initial := rig.get_bone_global_pose(bone).basis.orthonormalized()
	var roll := Basis(Vector3.RIGHT, 0.8)
	packet.pose.world[15] = _mp(elbow + roll * Vector3.BACK * 0.22)
	_settle(setup, packet)
	var actual := rig.get_bone_global_pose(bone).basis.orthonormalized()
	assert(absf(actual.get_rotation_quaternion().dot((roll * initial).get_rotation_quaternion())) > 0.999, "Elbow bend plane must drive upper-arm axial rotation even when the shoulder-elbow direction stays fixed")
	assert((_position(rig, "左手首") - _position(rig, "左ひじ")).normalized().dot(roll * Vector3.BACK) > 0.995)
	# Straight arms provide no reliable bend plane; a noisy wrist must keep torso-carried twist.
	setup.reset()
	packet = _packet(rig)
	packet.pose.world[15] = _mp(elbow + Vector3(0.22, 0.00001, -0.00001))
	_settle(setup, packet)
	assert(absf(rig.get_bone_pose_rotation(bone).dot(setup._neutral_local[bone])) > 0.999)
	model.free()
	return true


func _test_pmx_finger_axes() -> bool:
	var model := _synthetic_model(false)
	root.add_child(model)
	var rig := model.get_child(0) as Skeleton3D
	rig.reset_bone_poses()
	var setup = RETARGET.new()
	assert(setup.apply(rig, model))
	for side in ["左", "右"]:
		setup.reset()
		var hand := _hand(rig, side)
		hand.side = "Left" if side == "左" else "Right"
		var packet := {"version": 1, "seq": 0, "timestamp_ms": 0, "pose": null, "hands": [hand], "face": null}
		_settle(setup, packet)
		for finger in RETARGET.FINGERS:
			for part: String in finger:
				var bone := rig.find_bone(side + part)
				assert(absf(rig.get_bone_pose_rotation(bone).dot(setup._neutral_local[bone])) > 0.999, "Open fingers on a PMX rig must not depend on local +Y bone axes")
		setup.reset()
		var palm_origin := _point(hand.world[0])
		var roll := Basis(Vector3(0.4, 0.3, 0.8).normalized(), 0.9)
		for index in hand.world.size():
			hand.world[index] = _mp3(palm_origin + roll * (_point(hand.world[index]) - palm_origin))
		_settle(setup, packet)
		for finger in RETARGET.FINGERS:
			for part: String in finger:
				var bone := rig.find_bone(side + part)
				var expected: Basis = roll * setup._neutral_global[bone].basis
				var actual := rig.get_bone_global_pose(bone).basis.orthonormalized()
				assert(absf(actual.get_rotation_quaternion().dot(expected.get_rotation_quaternion())) > 0.999, "Palm rotation must carry every PMX finger segment, including terminal bones")
		var wrist := rig.find_bone(side + "手首")
		var expected_wrist: Basis = roll * setup._neutral_global[wrist].basis
		assert(absf(rig.get_bone_global_pose(wrist).basis.get_rotation_quaternion().dot(expected_wrist.get_rotation_quaternion())) > 0.999, "Both PMX wrists must follow the full palm orientation")
	# Authored tails can differ from the previous segment and must take precedence.
	setup.reset()
	var offsets := PackedVector3Array()
	offsets.resize(rig.get_bone_count())
	var terminal := rig.find_bone("左人指３")
	offsets[terminal] = Vector3(0.02, 0.008, 0.006)
	rig.set_meta("pmx_tail_offsets", offsets)
	var hand := _hand(rig, "左")
	var tip := _position(rig, "左人指３") + offsets[terminal]
	hand.world[8] = _mp3(tip)
	var packet := {"version": 1, "seq": 0, "timestamp_ms": 0, "pose": null, "hands": [hand], "face": null}
	_settle(setup, packet)
	assert(absf(rig.get_bone_pose_rotation(terminal).dot(setup._neutral_local[terminal])) > 0.999, "PMX authored tail offsets must override parent-segment approximations")
	# The model's neutral arm pose rotates model-space PMX offsets along with the hand.
	setup.reset()
	rig.set_bone_pose_rotation(rig.find_bone("左腕"), Quaternion(Vector3.FORWARD, 0.7))
	assert(setup.apply(rig, model))
	hand = _hand(rig, "左")
	hand.world[8] = _mp3(_position(rig, "左人指３") + rig.get_bone_global_pose(terminal).basis * offsets[terminal])
	packet.hands = [hand]
	_settle(setup, packet)
	assert(absf(rig.get_bone_pose_rotation(terminal).dot(setup._neutral_local[terminal])) > 0.999, "Tail offsets must follow the captured model neutral pose")
	model.free()
	return true


static func _synthetic_model(align_bone_axes: bool = true) -> Node3D:
	var model := Node3D.new()
	var rig := Skeleton3D.new()
	model.add_child(rig)
	var transforms := {}
	var add_bone := func(name: String, parent: String, position: Vector3, basis: Basis = Basis.IDENTITY):
		var index := rig.get_bone_count()
		rig.add_bone(name)
		var world := Transform3D(basis, position)
		if not parent.is_empty():
			rig.set_bone_parent(index, rig.find_bone(parent))
			rig.set_bone_rest(index, transforms[parent].affine_inverse() * world)
		else:
			rig.set_bone_rest(index, world)
		transforms[name] = world
	add_bone.call("腰", "", Vector3(0, 0.9, 0))
	add_bone.call("下半身", "腰", Vector3(0, 0.95, 0))
	add_bone.call("上半身", "腰", Vector3(0, 1.2, 0))
	add_bone.call("上半身2", "上半身", Vector3(0, 1.42, 0))
	add_bone.call("首", "上半身2", Vector3(0, 1.5, 0))
	add_bone.call("頭", "首", Vector3(0, 1.58, 0))
	for side in ["左", "右"]:
		var sign := 1.0 if side == "左" else -1.0
		var orientation := Basis(Quaternion(Vector3.UP, Vector3(sign, 0, 0))) if align_bone_axes else Basis.IDENTITY
		add_bone.call(side + "肩", "上半身2", Vector3(sign * 0.12, 1.42, 0))
		add_bone.call(side + "腕", side + "肩", Vector3(sign * 0.2, 1.42, 0), orientation)
		add_bone.call(side + "ひじ", side + "腕", Vector3(sign * 0.44, 1.42, 0), orientation)
		add_bone.call(side + "手首", side + "ひじ", Vector3(sign * 0.66, 1.42, 0), orientation)
		for finger in RETARGET.FINGERS.size():
			var parent: String = side + "手首"
			for joint in 3:
				var name: String = side + RETARGET.FINGERS[finger][joint]
				add_bone.call(name, parent, Vector3(sign * (0.7 + joint * 0.025), 1.47 - finger * 0.025, 0.02 if finger == 0 else 0.0), orientation)
				parent = name
		add_bone.call(side + "足D", "下半身", Vector3(sign * 0.1, 0.85, 0))
		add_bone.call(side + "ひざD", side + "足D", Vector3(sign * 0.1, 0.45, 0))
		add_bone.call(side + "足首D", side + "ひざD", Vector3(sign * 0.1, 0.05, 0))
	var mesh := ArrayMesh.new()
	for name in RETARGET.MORPHS + ["瞳小"]:
		mesh.add_blend_shape(name)
	var vertices := PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var shapes: Array[Array] = []
	for index in mesh.get_blend_shape_count():
		shapes.append(arrays.duplicate(true))
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, shapes)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	model.add_child(instance)
	return model
