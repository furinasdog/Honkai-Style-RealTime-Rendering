extends SceneTree

const HELPERS = preload("res://tests/test_fullbody_retarget.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(90.0).timeout.connect(func(): quit(1))
	assert(not OS.get_cmdline_user_args().is_empty(), "Pass private native-import result.json paths")
	for path: String in OS.get_cmdline_user_args():
		var baseline = await _replay(path, false)
		if not baseline is Dictionary or baseline.is_empty():
			quit(1)
			return
		var motion = await _replay(path, true)
		if not motion is Dictionary or motion.is_empty():
			quit(1)
			return
		print("FULLBODY_PHYSICS_PASS ", JSON.stringify({"model": path, "baseline": baseline, "motion": motion}))
	quit(0)


func _replay(path: String, animated_replay: bool) -> Dictionary:
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
	var retarget = preload("res://scripts/mocap_retarget.gd").new()
	assert(retarget.apply(rig, model))
	var physics := preload("res://scripts/mmd_physics.gd").new()
	assert(physics.apply(rig, model, metadata.physics))
	assert(retarget.set_mode("full_body"))
	physics.reset()
	var initial := HELPERS.standing(rig)
	var full_lift := HELPERS.lifted(initial, 0.22)
	var root_bone: int = retarget._fullbody.root_index
	var root_neutral := rig.get_bone_pose_position(root_bone)
	var joint_frames: Array[Dictionary] = []
	for joint: Generic6DOFJoint3D in physics.joints:
		var a := joint.get_node(joint.node_a) as PhysicsBody3D
		var b := joint.get_node(joint.node_b) as PhysicsBody3D
		var lower := Vector3(joint.get_param_x(Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT), joint.get_param_y(Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT), joint.get_param_z(Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT))
		var upper := Vector3(joint.get_param_x(Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT), joint.get_param_y(Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT), joint.get_param_z(Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT))
		joint_frames.append({"a": a, "b": b, "frame_a": a.global_transform.affine_inverse() * joint.global_transform, "frame_b": b.global_transform.affine_inverse() * joint.global_transform, "lower": lower, "upper": upper})
	var static_initial := {}
	var lower_followers := {}
	var lower_indices: Array = retarget._fullbody.indices()
	for entry: Dictionary in physics._entries:
		if entry.mode == 0 and entry.bone >= 0:
			static_initial[entry.body] = entry.body.global_position
			if entry.bone in lower_indices:
				lower_followers[entry.body] = true
	var rate := Engine.physics_ticks_per_second
	var maximum_static_error := 0.0
	var maximum_static_angle := 0.0
	var maximum_static_motion := 0.0
	var maximum_lower_motion := 0.0
	var maximum_dynamic_offset := 0.0
	var maximum_joint_gap := 0.0
	var maximum_joint_excess := 0.0
	var maximum_locked_gap := 0.0
	var turn_binding_offset := 0.0
	var turn_joint_excess := 0.0
	var worst_dynamic := {}
	var worst_joint := {}
	var worst_excess := {}
	var maximum_root := 0.0
	var restored := false
	var recentered := false
	for step in int(rate * 3.5):
		var time := float(step) / rate
		var packet := initial.duplicate(true)
		if animated_replay and time >= 0.4 and time < 1.5:
			var amount := clampf((time - 0.4) / 0.6, 0.0, 1.0) if time < 1.0 else clampf((1.5 - time) / 0.5, 0.0, 1.0)
			packet = HELPERS.crouch(initial, 0.18 * amount)
		elif animated_replay and time >= 1.5 and time < 2.1:
			var amount := sin((time - 1.5) / 0.6 * PI)
			for id in 33:
				var before := HELPERS.point(initial.pose.world[id])
				var after := HELPERS.point(full_lift.pose.world[id])
				packet.pose.world[id] = HELPERS.mp(before.lerp(after, amount))
				packet.pose.world[id][3] = initial.pose.world[id][3]
		elif animated_replay and time >= 2.1 and time < 2.9:
			var turn := Basis(Vector3.UP, 1.5 * clampf((time - 2.1) / 0.8, 0.0, 1.0))
			var pivot := (HELPERS.point(initial.pose.world[23]) + HELPERS.point(initial.pose.world[24])) * 0.5
			for id in 33:
				packet.pose.world[id] = HELPERS.mp(pivot + turn * (HELPERS.point(initial.pose.world[id]) - pivot))
				packet.pose.world[id][3] = initial.pose.world[id][3]
		elif time >= 2.9 and not restored:
			assert(retarget.set_mode("vtuber"))
			physics.reset()
			assert(rig.get_bone_pose_position(root_bone).distance_to(root_neutral) < 0.00001)
			restored = true
		if time >= 3.15 and not recentered:
			assert(retarget.set_mode("full_body"))
			retarget.recenter()
			physics.reset()
			assert(rig.get_bone_pose_position(root_bone).distance_to(root_neutral) < 0.00001)
			recentered = true
		packet.seq = retarget._last_sequence + 1
		packet.timestamp_ms = maxf(0.0, retarget._last_timestamp_ms + 1000.0 / rate)
		assert(retarget.ingest(packet))
		retarget.update(1.0 / rate)
		await physics_frame
		await process_frame
		var animated := {}
		for entry: Dictionary in physics._entries:
			var body: PhysicsBody3D = entry.body
			assert(body.global_transform.is_finite(), "A physical body became nonfinite during full-body replay")
			var target: Transform3D = physics._animated_target(entry, animated)
			var error := body.global_position.distance_to(target.origin)
			if entry.mode == 0:
				maximum_static_error = maxf(maximum_static_error, error)
				var angle := body.global_basis.orthonormalized().get_rotation_quaternion().angle_to(target.basis.orthonormalized().get_rotation_quaternion())
				maximum_static_angle = maxf(maximum_static_angle, angle)
				if static_initial.has(body):
					maximum_static_motion = maxf(maximum_static_motion, body.global_position.distance_to(static_initial[body]))
					if lower_followers.has(body):
						maximum_lower_motion = maxf(maximum_lower_motion, body.global_position.distance_to(static_initial[body]))
			else:
				if error > maximum_dynamic_offset:
					worst_dynamic = {"time": time, "mode": retarget.mode, "bone": entry.source.get("bone", ""), "body": entry.source.get("name", ""), "offset": error}
				maximum_dynamic_offset = maxf(maximum_dynamic_offset, error)
				if time >= 2.1 and time < 2.9:
					turn_binding_offset = maxf(turn_binding_offset, error)
		for joint: Dictionary in joint_frames:
			var a: Transform3D = joint.a.global_transform * joint.frame_a
			var b: Transform3D = joint.b.global_transform * joint.frame_b
			var gap := a.origin.distance_to(b.origin)
			if gap > maximum_joint_gap:
				worst_joint = {"time": time, "mode": retarget.mode, "a": str(joint.a.name), "b": str(joint.b.name), "gap": gap}
			maximum_joint_gap = maxf(maximum_joint_gap, gap)
			var difference: Vector3 = a.basis.orthonormalized().inverse() * (b.origin - a.origin)
			var violation := Vector3.ZERO
			for axis in 3:
				if joint.lower[axis] <= joint.upper[axis]:
					violation[axis] = maxf(0.0, maxf(joint.lower[axis] - difference[axis], difference[axis] - joint.upper[axis]))
			var excess := violation.length()
			if excess > maximum_joint_excess:
				worst_excess = {"time": time, "a": str(joint.a.name), "b": str(joint.b.name), "excess": excess}
			maximum_joint_excess = maxf(maximum_joint_excess, excess)
			if time >= 2.1 and time < 2.9:
				turn_joint_excess = maxf(turn_joint_excess, excess)
			if joint.lower.is_zero_approx() and joint.upper.is_zero_approx():
				maximum_locked_gap = maxf(maximum_locked_gap, gap)
		for bone in rig.get_bone_count():
			assert(rig.get_bone_global_pose(bone).is_finite(), "A skeleton pose became nonfinite during full-body replay")
		for chain: Dictionary in retarget._fullbody.chains:
			var first := rig.get_bone_global_pose(chain.upper).origin.distance_to(rig.get_bone_global_pose(chain.knee).origin)
			var second := rig.get_bone_global_pose(chain.knee).origin.distance_to(rig.get_bone_global_pose(chain.ankle).origin)
			assert(absf(first - chain.first) < 0.0001 and absf(second - chain.second) < 0.0001, "Physics must not detach or stretch the driven deform leg chain")
		maximum_root = maxf(maximum_root, rig.get_bone_pose_position(root_bone).distance_to(root_neutral))
	var report := {"model": path, "animated_replay": animated_replay, "physics_ticks": int(rate * 3.5), "bodies": physics.counts.bodies, "joints": physics.counts.joints,
		"maximum_root_motion": maximum_root, "maximum_kinematic_motion": maximum_static_motion,
		"lower_kinematic_followers": lower_followers.size(), "maximum_lower_kinematic_motion": maximum_lower_motion,
		"maximum_kinematic_position_error": maximum_static_error, "maximum_kinematic_angle_error": maximum_static_angle,
		"maximum_dynamic_binding_offset": maximum_dynamic_offset, "maximum_joint_anchor_gap": maximum_joint_gap,
		"maximum_joint_limit_excess": maximum_joint_excess, "maximum_locked_joint_gap": maximum_locked_gap,
		"turn_binding_offset": turn_binding_offset, "turn_joint_limit_excess": turn_joint_excess,
		"residual_root_offset": rig.get_bone_pose_position(root_bone).distance_to(root_neutral), "worst_dynamic": worst_dynamic, "worst_joint": worst_joint, "worst_excess": worst_excess}
	print("FULLBODY_PHYSICS_METRICS ", JSON.stringify(report))
	assert(restored and recentered)
	if animated_replay:
		assert(maximum_root > 0.1 and maximum_static_motion > 0.1, "The replay must exercise root translation and moving kinematic followers")
		assert(not lower_followers.is_empty() and maximum_lower_motion > 0.05, "Actual lower-body kinematic rigid bodies must move with the driven root/leg chain")
	assert(maximum_static_error < 0.02 and maximum_static_angle < 0.02, "Kinematic rigid bodies must follow the animated root/legs")
	# Bound existing solver residuals; free helper joints' raw anchor gap is not an attachment error.
	assert(maximum_dynamic_offset < 1.5 and maximum_joint_excess < 0.05, "A dynamic chain exceeded the bounded authored-limit regression tolerance")
	assert(rig.get_bone_pose_position(root_bone).distance_to(root_neutral) < 0.003)
	physics.dispose()
	model.queue_free()
	await process_frame
	return report
