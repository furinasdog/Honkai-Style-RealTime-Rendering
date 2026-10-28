extends SceneTree

const FIXTURE = preload("res://tests/test_mocap_retarget.gd")
var sequence := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(10).timeout.connect(func(): quit(1))
	var model := FIXTURE._synthetic_model()
	root.add_child(model)
	var rig: Skeleton3D = model.get_child(0)
	rig.reset_bone_poses()
	var mapping = preload("res://scripts/mapping_settings.gd").new()
	var retarget = preload("res://scripts/mocap_retarget.gd").new()
	retarget.settings = mapping
	assert(retarget.apply(rig, model))
	var fixture := FIXTURE.new()
	var packet: Dictionary = fixture._packet(rig)
	var shoulder: Vector3 = fixture._position(rig, "左腕")
	packet.pose.world[13] = fixture._mp(shoulder + Vector3(0.22, 0.05, 0.02))
	packet.pose.world[15] = fixture._mp(shoulder + Vector3(0.22, 0.3, 0.02))
	for i in 90:
		_step(retarget, packet)
	var arm := rig.find_bone("左腕")
	var elbow := rig.find_bone("左ひじ")
	var before := rig.get_bone_pose_rotation(elbow)
	var posed_packet := packet.duplicate(true)
	var palm_before := rig.get_bone_global_pose(rig.find_bone("左手首")).basis.orthonormalized().get_rotation_quaternion()
	packet.pose = null
	packet.hands = [fixture._hand(rig, "左")]
	_step(retarget, packet)
	var palm_held := rig.get_bone_global_pose(rig.find_bone("左手首")).basis.orthonormalized().get_rotation_quaternion()
	assert(palm_held.angle_to(palm_before) < 0.025, "A valid hand must resolve its wrist against the held arm, not the neutral parent")
	packet = posed_packet
	packet.pose.image[15][3] = 0.1
	_step(retarget, packet)
	assert(not retarget.tracking.pose or not retarget._global_targets.has(arm))
	assert(rig.get_bone_pose_rotation(elbow).angle_to(before) < 0.025, "One low-confidence frame must not pull the bent elbow back toward rest")
	for i in 60:
		_step(retarget, packet)
	assert(rig.get_bone_pose_rotation(elbow).angle_to(retarget._neutral_local[elbow]) < 0.01, "Sustained loss must release the held arm")
	packet.pose.image[15][3] = 1.0
	for i in 90:
		_step(retarget, packet)
	mapping.set_channel_value("left_arm", "enabled", false)
	for i in 60:
		_step(retarget, packet)
	assert(rig.get_bone_pose_rotation(elbow).angle_to(retarget._neutral_local[elbow]) < 0.01, "Disabling an arm must bypass the dropout hold")
	retarget.reset()
	packet = fixture._packet(rig)
	packet.pose = null
	var hand: Dictionary = fixture._hand(rig, "左")
	var hand_origin: Vector3 = fixture._point(hand.world[0])
	var turn := Basis(Vector3.UP, 0.6)
	for i in hand.world.size():
		hand.world[i] = fixture._mp3(hand_origin + turn * (fixture._point(hand.world[i]) - hand_origin))
	packet.hands = [hand]
	for i in 90:
		_step(retarget, packet)
	var wrist := rig.find_bone("左手首")
	var wrist_before := rig.get_bone_pose_rotation(wrist)
	packet.hands.clear()
	_step(retarget, packet)
	assert(not retarget.tracking.left_hand)
	assert(rig.get_bone_pose_rotation(wrist).angle_to(wrist_before) < 0.025, "One missing hand frame must retain palm orientation")
	for i in 60:
		_step(retarget, packet)
	assert(rig.get_bone_pose_rotation(wrist).angle_to(retarget._neutral_local[wrist]) < 0.01)
	retarget.reset()
	retarget.set_hand_gesture_assistance(true)
	var gestures = preload("res://tests/test_hand_gesture_assistance.gd")
	packet = gestures.frame(gestures.hand("fist", "Left"))
	for i in 90:
		_step(retarget, packet)
	var finger := rig.find_bone("左人指２")
	var held_finger := rig.get_bone_pose_rotation(finger)
	packet.hands.clear()
	_step(retarget, packet)
	retarget.set_hand_gesture_assistance(false)
	retarget.update(1.0 / 30.0)
	assert(rig.get_bone_pose_rotation(finger).angle_to(held_finger) > 0.1, "Disabling assistance during dropout must release the held preset without waiting for another packet")
	retarget.reset()
	assert(retarget._targets[elbow].angle_to(retarget._neutral_local[elbow]) < 0.001)
	fixture.free()
	model.queue_free()
	await process_frame
	print("TRACKING_CONTINUITY_PASS transient loss, sustained release, reacquire, disabled channel and reset")
	quit()


func _step(retarget: RefCounted, packet: Dictionary) -> void:
	sequence += 1
	packet.seq = sequence
	packet.timestamp_ms = sequence * 33
	assert(retarget.ingest(packet))
	retarget.update(1.0 / 30.0)
