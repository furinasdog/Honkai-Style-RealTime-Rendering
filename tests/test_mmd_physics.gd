extends SceneTree

const PHYSICS = preload("res://scripts/mmd_physics.gd")
const ACTOR = preload("res://scripts/actor.gd")
var last_poses: Dictionary = {}
var rate := Engine.physics_ticks_per_second


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(60.0).timeout.connect(func(): quit(1))
	var world := Node3D.new()
	root.add_child(world)
	var floor := StaticBody3D.new()
	var floor_collision := CollisionShape3D.new()
	var floor_shape := BoxShape3D.new()
	floor_shape.size = Vector3(4, 0.1, 4)
	floor_collision.shape = floor_shape
	floor_collision.position.y = -0.05
	floor.add_child(floor_collision)
	world.add_child(floor)
	var rig := Skeleton3D.new()
	world.add_child(rig)
	for bone_name in ["Anchor", "Hair", "SkirtFree", "Hybrid"]:
		rig.add_bone(bone_name)
	rig.set_bone_rest(0, Transform3D(Basis.IDENTITY, Vector3(0, 1.5, 0)))
	rig.set_bone_parent(1, 0)
	rig.set_bone_rest(1, Transform3D(Basis.IDENTITY, Vector3(0, -0.15, 0)))
	rig.set_bone_parent(2, 0)
	rig.set_bone_rest(2, Transform3D(Basis.IDENTITY, Vector3(0.35, -1.15, 0)))
	rig.set_bone_parent(3, 0)
	rig.set_bone_rest(3, Transform3D(Basis.IDENTITY, Vector3(-0.35, -0.5, 0)))
	rig.reset_bone_poses()
	var data := {"rigid_bodies": [_body("Anchor", 0, "sphere", [0.07, 0, 0], [0, 1.5, 0]), _body("Hair", 1, "capsule", [0.025, 0.3, 0], [0, 1.2, 0]), _body("SkirtFree", 1, "sphere", [0.04, 0, 0], [0.35, 0.35, 0])], "joints": [{"body_a": 0, "body_b": 1, "position": [0, 1.45, 0], "rotation": [0, 0, 0, 1], "linear_lower": [0, 0, 0], "linear_upper": [0, 0, 0], "angular_lower": [-0.8, -0.8, -0.8], "angular_upper": [0.8, 0.8, 0.8], "spring_linear": [0, 0, 0], "spring_angular": [0.1, 0.1, 0.1]}]}
	var setup = PHYSICS.new()
	data.rigid_bodies.append(_body("Hybrid", 2, "box", [0.04, 0.06, 0.03], [-0.25, 0.95, 0]))
	var rejected = PHYSICS.new()
	var invalid: Dictionary = data.duplicate(true)
	invalid.rigid_bodies[0].mass = NAN
	assert(not rejected.apply(rig, world, invalid), "Invalid physics metadata must fail before scene mutation")
	assert(rejected.get_parent() == null and rejected.bodies.is_empty())
	rejected.free()
	assert(setup.apply(rig, world, data))
	assert(setup.counts.bodies == 4 and setup.counts.dynamic == 3 and setup.counts.joints == 1)
	assert(absf(setup.bodies[1].get_child(0).shape.height - 0.35) < 0.00001, "PMX capsule uses straight segment plus two radii")
	setup.modification_processed.connect(func():
		last_poses["hair"] = rig.get_bone_global_pose(1)
		last_poses["skirt"] = rig.get_bone_global_pose(2))
	for step in rate * 2:
		await physics_frame
	assert(setup.bodies[2].global_position.y > 0.037 and setup.bodies[2].global_position.y < 0.06, "Rigid sphere must collide with the floor")
	assert(setup.bodies[1].global_position.y > 1.0, "Joint must suspend the capsule from the animated anchor")
	assert(last_poses.has("skirt") and last_poses.skirt.origin.y < 0.08, "Physics must be submitted to the skeleton, not just simulated invisibly")
	setup.bodies[3].apply_torque_impulse(Vector3(0.001, 0, 0.001))
	var start: Vector3 = setup.bodies[1].global_position
	setup.bodies[1].apply_central_impulse(Vector3(0.02, 0, 0))
	var response := 0.0
	var bone_response := 0.0
	for step in int(rate * 0.5):
		await physics_frame
		response = maxf(response, setup.bodies[1].global_position.distance_to(start))
		bone_response = maxf(bone_response, absf(last_poses.hair.origin.x))
	assert(response > 0.005 and response < 0.6, "Jointed hair body must respond without exploding")
	assert(bone_response > 0.005, "Visible hair bone must follow the rigid body")
	rig.set_bone_pose_rotation(0, Quaternion(Vector3.FORWARD, 0.25))
	for step in int(rate * 0.5):
		await physics_frame
	var expected: Transform3D = setup._follow_target(setup._entries[0])
	assert(setup.bodies[0].global_transform.is_equal_approx(expected), "Static MMD colliders must follow animation")
	var hybrid_world: Transform3D = setup.bodies[3].global_transform * setup._entries[3].offset.affine_inverse()
	var hybrid_animated: Transform3D = rig.global_transform * setup._animated_pose(3, {})
	assert(hybrid_world.origin.distance_to(hybrid_animated.origin) < 0.01, "Mode 2 body must preserve animated bone translation without disabling physical rotation")
	assert(hybrid_world.basis.get_rotation_quaternion().angle_to(hybrid_animated.basis.get_rotation_quaternion()) > 0.005, "Mode 2 body rotation must still respond to torque")
	setup.reset()
	for entry in setup._entries:
		assert(entry.body.global_transform.origin.distance_to(setup._follow_target(entry).origin) < 0.0001)
		if entry.body is RigidBody3D:
			assert(entry.body.linear_velocity.length() < 0.0001)
	var before_move: Vector3 = setup.bodies[1].global_position
	world.position.x += 0.5
	await physics_frame
	await physics_frame
	assert(setup.bodies[1].global_position.x - before_move.x > 0.45, "Moving the model must transport its world-space physics bodies")
	var follower_velocity: Vector3 = PhysicsServer3D.body_get_state(setup.bodies[0].get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
	assert(follower_velocity.length() < 0.01, "Teleport must not become a kinematic collision impulse")
	assert(PhysicsServer3D.body_get_mode(setup.bodies[0].get_rid()) == PhysicsServer3D.BODY_MODE_KINEMATIC)
	var report := {"tiny_joint_response_m": response, "visible_bone_response_m": bone_response, "collision": true, "reset": true, "hybrid_mode_translation": true}
	var physics_root: Node3D = setup._world_root
	setup.dispose()
	await process_frame
	await process_frame
	assert(not is_instance_valid(physics_root), "Model replacement must release bodies and joints")
	world.free()
	last_poses.clear()
	report["body_collision_assistance"] = await _collision_assistance()
	assert(not report.body_collision_assistance.is_empty(), "Body collision assistance regression failed")
	report["real_models"] = {}
	for folder in OS.get_cmdline_user_args():
		var result := await _real_model(folder)
		assert(not result.is_empty(), "Real-model physics regression failed: " + folder)
		report.real_models[folder] = result
	var output := FileAccess.open("res://outputs/mmd_physics_test.json", FileAccess.WRITE)
	output.store_string(JSON.stringify(report, "\t"))
	print("MMD_PHYSICS_PASS ", JSON.stringify(report))
	quit(0)


func _real_model(folder: String) -> Dictionary:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(folder.path_join("metadata.json")))
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	assert(document.append_from_file(folder.path_join("model.glb"), state) == OK)
	var model := document.generate_scene(state) as Node3D
	root.add_child(model)
	var rig := model.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	var pose_helper := ACTOR.new()
	pose_helper._prepare_pose(model, false)
	pose_helper.free()
	var setup = PHYSICS.new()
	assert(setup.apply(rig, model, data.physics))
	var assisted_contacts := {}
	for pair in setup.assisted_pairs:
		for index in [pair.x, pair.y]:
			if setup.bodies[index] is RigidBody3D:
				setup.bodies[index].contact_monitor = true
				setup.bodies[index].max_contacts_reported = 8
	var visible_response := {"hair": 0.0, "clothing": 0.0}
	setup.modification_processed.connect(func():
		var animated := {}
		for entry in setup._dynamic:
			var key := "hair" if setup._is_hair(entry) else "clothing"
			var pose := rig.get_bone_global_pose(entry.bone)
			var neutral: Transform3D = setup._animated_pose(entry.bone, animated)
			visible_response[key] = maxf(visible_response[key], (rig.global_transform * pose.origin).distance_to(rig.global_transform * neutral.origin)))
	var initial: Array[Vector3] = []
	for body in setup.bodies:
		initial.append(body.global_position)
	var maximum := 0.0
	for step in int(rate * 2.5):
		await physics_frame
		for index in setup.bodies.size():
			var body: PhysicsBody3D = setup.bodies[index]
			assert(body.global_position.is_finite(), "Real PMX body became nonfinite")
			var displacement := body.global_position.distance_to(initial[index])
			if displacement > maximum:
				maximum = displacement
	assert(maximum > 0.0001 and maximum < 1.0, "Real clothing/hair must move under gravity while remaining bounded")
	model.position.x += 0.08
	var head := rig.find_bone("頭")
	var shoulder := rig.find_bone("左肩")
	var arm := rig.find_bone("左腕")
	assert(head >= 0 and shoulder >= 0 and arm >= 0)
	var head_pose := rig.get_bone_pose_rotation(head)
	var shoulder_pose := rig.get_bone_pose_rotation(shoulder)
	var arm_pose := rig.get_bone_pose_rotation(arm)
	var motion_maximum := 0.0
	for step in rate * 4:
		var amount := minf(float(step) / (rate * 1.5), 1.0)
		rig.set_bone_pose_rotation(head, head_pose * Quaternion(Vector3.FORWARD, amount * 0.5))
		rig.set_bone_pose_rotation(shoulder, shoulder_pose * Quaternion(Vector3.FORWARD, amount * 0.18))
		rig.set_bone_pose_rotation(arm, arm_pose * Quaternion(Vector3.RIGHT, amount * 0.4))
		await physics_frame
		for entry in setup._entries:
			assert(entry.body.global_position.is_finite())
			var displacement: float = entry.body.global_position.distance_to(setup._follow_target(entry).origin)
			motion_maximum = maxf(motion_maximum, displacement)
			assert(displacement < 1.0, "Head/shoulder motion destabilized %s bone=%s mode=%s offset=%s step=%s" % [entry.source.get("name", ""), entry.source.get("bone", ""), entry.mode, displacement, step])
		for pair in setup.assisted_pairs:
			var hair: RigidBody3D = setup.bodies[pair.x] if setup.bodies[pair.x] is RigidBody3D else setup.bodies[pair.y]
			var torso: PhysicsBody3D = setup.bodies[pair.y] if hair == setup.bodies[pair.x] else setup.bodies[pair.x]
			if torso in hair.get_colliding_bodies():
				assisted_contacts[pair] = true
	assert(visible_response.clothing > 0.001, "Real clothing bone must receive physics deformation")
	var result: Dictionary = setup.counts.duplicate()
	result["maximum_gravity_displacement_m"] = maximum
	result["maximum_head_shoulder_motion_displacement_m"] = motion_maximum
	result["visible_bone_response_m"] = visible_response
	result["head_tilt_radians"] = 0.5
	result["initial_pose"] = "actor_relaxed_arms"
	result["assisted_pairs_with_real_contact"] = assisted_contacts.size()
	var shoulder_contacts := 0
	var arm_contacts := 0
	for pair: Vector2i in assisted_contacts:
		for index in [pair.x, pair.y]:
			var entry: Dictionary = setup._entries[index]
			if entry.mode != 0:
				continue
			var bone_name := str(entry.source.get("bone", "")).to_lower()
			if "肩" in bone_name or "shoulder" in bone_name:
				shoulder_contacts += 1
			if bone_name in ["左腕", "右腕"] or "upperarm" in bone_name or "upper_arm" in bone_name:
				arm_contacts += 1
	result["actual_shoulder_contacts"] = shoulder_contacts
	result["actual_upper_arm_contacts"] = arm_contacts
	result["held_head_tilt_hair_hang"] = _hair_hang(setup, rig, head)
	result["warnings"] = setup.warnings
	setup.reset()
	model.free()
	return result


func _hair_hang(setup: MMDPhysics, rig: Skeleton3D, head: int) -> Dictionary:
	var head_rest := rig.global_transform * rig.get_bone_global_rest(head)
	var animated := {}
	var physical_angle := 0.0
	var animated_angle := 0.0
	var maximum_compensation := 0.0
	var samples := 0
	for entry in setup._dynamic:
		if not setup._is_hair(entry) or str(entry.source.shape) != "capsule" or entry.rest_world.origin.y > head_rest.origin.y - 0.2:
			continue
		var physical_direction: Vector3 = entry.body.global_basis.y.normalized()
		var animated_direction: Vector3 = setup._animated_target(entry, animated).basis.y.normalized()
		var physical := acos(clampf(absf(physical_direction.dot(Vector3.UP)), 0.0, 1.0))
		var animation := acos(clampf(absf(animated_direction.dot(Vector3.UP)), 0.0, 1.0))
		physical_angle += physical
		animated_angle += animation
		maximum_compensation = maxf(maximum_compensation, animation - physical)
		samples += 1
	if samples == 0:
		return {"samples": 0}
	return {"samples": samples, "mean_physical_degrees_from_vertical": rad_to_deg(physical_angle / samples), "mean_animation_degrees_from_vertical": rad_to_deg(animated_angle / samples), "maximum_gravity_compensation_degrees": rad_to_deg(maximum_compensation)}


func _collision_assistance() -> Dictionary:
	var world := Node3D.new()
	root.add_child(world)
	var rig := Skeleton3D.new()
	world.add_child(rig)
	for bone_name in ["頭", "髪根", "髪先", "左肩"]:
		rig.add_bone(bone_name)
		rig.set_bone_rest(rig.get_bone_count() - 1, Transform3D.IDENTITY)
	rig.set_bone_rest(0, Transform3D(Basis.IDENTITY, Vector3(0, 1.5, 0)))
	rig.set_bone_parent(1, 0)
	rig.set_bone_parent(2, 1)
	rig.set_bone_rest(2, Transform3D(Basis.IDENTITY, Vector3(0, -0.2, 0)))
	rig.set_bone_rest(3, Transform3D(Basis.IDENTITY, Vector3(0, 1.0, 0)))
	rig.reset_bone_poses()
	var sources := [_body("頭", 0, "sphere", [0.12, 0, 0], [0, 1.5, 0]), _body("髪根", 0, "sphere", [0.04, 0, 0], [0, 1.5, 0]), _body("髪先", 1, "sphere", [0.04, 0, 0], [0, 1.3, 0]), _body("左肩", 0, "sphere", [0.1, 0, 0], [0, 1.0, 0])]
	for source in sources:
		source.collision_mask = 0
	sources[2].collision_group = 4
	var setup = PHYSICS.new()
	assert(setup.apply(rig, world, {"rigid_bodies": sources, "joints": []}))
	assert(Vector2i(2, 3) in setup.assisted_pairs and Vector2i(0, 2) in setup.assisted_pairs)
	var hair: RigidBody3D = setup.bodies[2]
	hair.contact_monitor = true
	hair.max_contacts_reported = 8
	var contact_seen := false
	for step in int(rate * 1.5):
		await physics_frame
		contact_seen = contact_seen or setup.bodies[3] in hair.get_colliding_bodies()
	assert(contact_seen and hair.global_position.y > 1.12, "Auxiliary hair/shoulder contact must actually stop falling hair")
	assert(not (hair in setup.bodies[0].get_collision_exceptions()), "Hair tips must also be allowed to collide with the head")
	setup.set_body_collision_assistance(false)
	assert(setup.assisted_pairs.is_empty() and hair.collision_mask == 0)
	for step in int(rate * 0.5):
		await physics_frame
	assert(hair.global_position.y < 0.7, "Disabling assistance must restore original PMX collision exclusions")
	world.free()
	return {"actual_shoulder_collision": true, "head_collision_enabled": true, "runtime_disable_restores_source_masks": true}


func _body(bone: String, mode: int, shape: String, size: Array, position: Array) -> Dictionary:
	return {"bone": bone, "type": mode, "shape": shape, "size": size, "position": position, "rotation": [0, 0, 0, 1], "mass": 0.05, "linear_damping": 0.5, "angular_damping": 0.5, "collision_group": 0, "collision_mask": 1}
