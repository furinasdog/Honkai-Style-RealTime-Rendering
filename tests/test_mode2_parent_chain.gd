extends SceneTree

const PHYSICS = preload("res://scripts/mmd_physics.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(5.0).timeout.connect(func(): quit(1))
	var model := Node3D.new()
	root.add_child(model)
	model.transform = Transform3D(Basis(Vector3.UP, 0.35), Vector3(0.7, 0.2, -0.4))
	var rig := Skeleton3D.new()
	model.add_child(rig)
	for name in ["Anchor", "HairParent", "Spacer", "HairChild", "HairFree"]:
		rig.add_bone(name)
	for bone in rig.get_bone_count():
		rig.set_bone_rest(bone, Transform3D(Basis.IDENTITY, Vector3(0, 1.5 if bone == 0 else -0.12, 0)))
		if bone > 0:
			rig.set_bone_parent(bone, bone - 1)
	rig.reset_bone_poses()
	var setup = PHYSICS.new()
	var sources := []
	for bone in [1, 3, 4]:
		var origin := rig.get_bone_global_rest(bone).origin + Vector3(0.03, -0.04, 0.02)
		sources.append({"bone": rig.get_bone_name(bone), "type": 1 if bone == 4 else 2,
			"shape": "sphere", "size": [0.015, 0, 0], "position": [origin.x, origin.y, origin.z],
			"rotation": [0, 0, 0, 1], "collision_mask": 0})
	assert(setup.apply(rig, model, {"rigid_bodies": sources, "joints": []}))
	setup.set_physics_process(false)
	var parent_entry: Dictionary = setup._entries[0]
	var child_entry: Dictionary = setup._entries[1]
	var free_entry: Dictionary = setup._entries[2]
	var parent_expected := rig.get_bone_global_rest(1)
	parent_expected.basis = Basis(Vector3.FORWARD, 0.65)
	var child_expected := parent_expected * rig.get_bone_rest(2) * rig.get_bone_rest(3)
	child_expected.basis = Basis(Vector3.RIGHT, -0.45)
	var free_expected := Transform3D(Basis(Vector3.UP, 0.2), child_expected.origin + Vector3(0.06, -0.18, 0.04))
	for pair in [[parent_entry, parent_expected], [child_entry, child_expected], [free_entry, free_expected]]:
		var entry: Dictionary = pair[0]
		var pose: Transform3D = pair[1]
		if entry.mode == 2:
			pose.origin += Vector3(0.08, -0.05, 0.03)
		setup._teleport_body(entry.body, rig.global_transform * pose * entry.offset)
	var actual: Transform3D = setup._physical_pose(3, {})
	var frozen: Transform3D = setup._animated_pose(3, {})
	assert(actual.origin.distance_to(child_expected.origin) < 0.00001,
		"Mode 2 child translation must follow its physically rotated parent through unbound bones")
	assert(actual.origin.distance_to(frozen.origin) > 0.1, "Fixture must expose the undeformed-parent regression")
	assert(actual.basis.is_equal_approx(child_expected.basis), "Mode 2 must retain simulated rotation")
	assert(setup._physical_pose(4, {}).is_equal_approx(free_expected), "Mode 1 must retain simulated translation and rotation")
	setup._physics_process(0.0)
	assert(child_entry.body.animated_bone_origin.distance_to(rig.global_transform * child_expected.origin) < 0.00001,
		"Hybrid collider target and displayed mode 2 bone must share the same parent chain")
	setup._process_modification_with_delta(0.0)
	assert(rig.get_bone_global_pose(3).is_equal_approx(child_expected), "Final modifier must preserve mode 2 local translation")
	assert(rig.get_bone_global_pose(4).is_equal_approx(free_expected), "Final modifier must preserve mode 1 translation")
	assert(_jointed_mode2(), "Only jointed direct children of dynamic parents may normalize mode 2")
	print("MODE2_PARENT_CHAIN_PASS ", JSON.stringify({"parent_chain_error_m": actual.origin.distance_to(child_expected.origin),
		"old_animation_chain_error_m": actual.origin.distance_to(frozen.origin), "unbound_spacer": true, "mode1_preserved": true}))
	model.free()
	quit(0)


func _jointed_mode2() -> bool:
	for reversed in [false, true]:
		var model := Node3D.new()
		root.add_child(model)
		var rig := Skeleton3D.new()
		model.add_child(rig)
		for name in ["Anchor", "HairRoot", "HairChild", "IndependentHybrid", "左胸", "左胸１"]:
			rig.add_bone(name)
		for bone in rig.get_bone_count():
			rig.set_bone_rest(bone, Transform3D(Basis.IDENTITY, Vector3(0, 1.5 if bone == 0 else -0.1, 0)))
			if bone > 0:
				rig.set_bone_parent(bone, 1 if bone == 2 else (4 if bone == 5 else 0))
		rig.reset_bone_poses()
		var sources := []
		for bone in rig.get_bone_count():
			var origin := rig.get_bone_global_rest(bone).origin
			sources.append({"bone": rig.get_bone_name(bone), "type": 0 if bone == 0 else 2,
				"shape": "sphere", "size": [0.02, 0, 0], "position": [origin.x, origin.y, origin.z],
				"rotation": [0, 0, 0, 1], "collision_mask": 0})
		var joint := {"body_a": 2 if reversed else 1, "body_b": 1 if reversed else 2,
			"position": [0, 1.35, 0], "rotation": [0, 0, 0, 1], "linear_lower": [0, 0, 0],
			"linear_upper": [0, 0, 0], "angular_lower": [-0.5, -0.5, -0.5], "angular_upper": [0.5, 0.5, 0.5]}
		var setup = PHYSICS.new()
		var torso_joint: Dictionary = joint.duplicate(true)
		torso_joint.body_a = 4
		torso_joint.body_b = 5
		var passed: bool = setup.apply(rig, model, {"rigid_bodies": sources, "joints": [joint, torso_joint]})
		passed = passed and setup._entries[1].mode == 2 and setup._entries[2].mode == 1 and setup._entries[3].mode == 2
		passed = passed and setup._entries[4].mode == 2 and setup._entries[5].mode == 2
		passed = passed and sources[2].type == 2 and setup.counts.normalized_mode2_children == 1
		model.free()
		if not passed:
			return false
	return true
