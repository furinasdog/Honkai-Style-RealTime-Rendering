extends SceneTree

var sequence := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(10.0).timeout.connect(func(): quit(1))
	var model := preload("res://tests/test_mocap_retarget.gd")._synthetic_model()
	root.add_child(model)
	var rig: Skeleton3D = model.get_child(0)
	rig.reset_bone_poses()
	var retarget = preload("res://scripts/mocap_retarget.gd").new()
	assert(retarget.apply(rig, model))
	var world: Array = []
	var image: Array = []
	for index in 33:
		world.append([0.0, 0.0, 0.0, 1.0])
		image.append([0.5, 0.5, 0.0, 1.0])
	for pair in [[11, "左腕"], [12, "右腕"], [13, "左ひじ"], [14, "右ひじ"], [15, "左手首"], [16, "右手首"]]:
		world[pair[0]] = _mp(rig.get_bone_global_pose(rig.find_bone(pair[1])).origin)
	world[23] = _mp(Vector3(0.1, 0.95, 0))
	world[24] = _mp(Vector3(-0.1, 0.95, 0))
	world[13] = _mp(Vector3(0.4, 1.8, 0.1))
	world[15] = _mp(Vector3(0.4, 2.2, 0.2))
	world[14] = _mp(Vector3(-0.4, 1.8, 0.1))
	world[16] = _mp(Vector3(-0.4, 2.2, 0.2))
	image[15] = [0.8, 1.2, 0.0, 1.0]
	var packet := {"version": 1, "seq": 0, "timestamp_ms": 0, "pose": {"world": world, "image": image}, "hands": [], "face": {"blendshapes": {"eyeBlinkLeft": 0.8}, "matrix": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]}}
	_settle(retarget, packet)
	var left := rig.find_bone("左腕")
	var right := rig.find_bone("右腕")
	assert(rig.get_bone_pose_rotation(left).angle_to(retarget._neutral_local[left]) < 0.01, "An out-of-frame wrist must not drive its arm, even with high confidence")
	assert(rig.get_bone_pose_rotation(right).angle_to(retarget._neutral_local[right]) > 0.2, "Valid opposite arm must continue tracking")
	assert(retarget.tracking.face)
	retarget.reset()
	packet.pose.image[15] = [0.7, 0.7, 0.0, 0.1]
	_settle(retarget, packet)
	assert(rig.get_bone_pose_rotation(left).angle_to(retarget._neutral_local[left]) < 0.01, "Low image-space confidence must also reject the arm")
	retarget.reset()
	packet.pose = null
	var hand_world: Array = [_mp(rig.get_bone_global_pose(rig.find_bone("左手首")).origin).slice(0, 3)]
	var hand_image: Array = [[-0.2, 0.5, 0.0]]
	for finger in retarget.FINGERS:
		for name: String in finger:
			hand_world.append(_mp(rig.get_bone_global_pose(rig.find_bone("左" + name)).origin).slice(0, 3))
			hand_image.append([0.5, 0.5, 0.0])
		var pose := rig.get_bone_global_pose(rig.find_bone("左" + finger[2]))
		hand_world.append(_mp(pose.origin + pose.basis.y.normalized() * 0.018).slice(0, 3))
		hand_image.append([0.5, 0.5, 0.0])
	packet.hands = [{"side": "Left", "world": hand_world, "image": hand_image}]
	_settle(retarget, packet)
	assert(not retarget.tracking.left_hand, "An out-of-frame hand must not control wrist or fingers")
	model.queue_free()
	await process_frame
	print("MOCAP_BOUNDS_PASS: out-of-frame pose/hand rejection, confidence, unaffected opposite arm and face")
	quit(0)


func _settle(retarget: RefCounted, packet: Dictionary) -> void:
	for frame in 100:
		sequence += 1
		packet.seq = sequence
		packet.timestamp_ms = sequence * 17
		assert(retarget.ingest(packet))
		retarget.update(1.0 / 60.0)


func _mp(point: Vector3) -> Array:
	return [point.x, -point.y, -point.z, 1.0]
