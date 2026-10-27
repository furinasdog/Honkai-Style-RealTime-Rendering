extends SceneTree

const PHYSICS = preload("res://scripts/mmd_physics.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(40.0).timeout.connect(func(): quit(1))
	var args := OS.get_cmdline_user_args()
	assert(args.size() == 2, "Pass private metadata.json and report.json")
	var report := await _real_model(args[0])
	assert(not report.is_empty(), "Real-model physics stability regression failed")
	report["hair_head_collision"] = await _head_contact()
	report["ticks"] = Engine.physics_ticks_per_second
	var file := FileAccess.open(args[1], FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("PHYSICS_STABILITY ", JSON.stringify(report))
	if not report.hair_head_collision:
		push_error("Hair tips must collide with the head instead of falling through")
		quit(1)
	else:
		quit(0)


func _real_model(path: String) -> Dictionary:
	var metadata: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var model: Node3D
	if metadata.get("loader") == "native_pmx_v1":
		var loaded := HonkaiPMXLoader.new().load_file(metadata.model_file)
		assert(not loaded.is_empty())
		model = loaded.root
	else:
		var document := GLTFDocument.new()
		var state := GLTFState.new()
		assert(document.append_from_file(path.get_base_dir().path_join("model.glb"), state) == OK)
		model = document.generate_scene(state) as Node3D
	root.add_child(model)
	var rig: Skeleton3D = model.find_children("*", "Skeleton3D", true, false)[0]
	var helper = load("res://scripts/actor.gd").new()
	helper._prepare_pose(model, false)
	helper.free()
	var renderer := MarchMaterials.new()
	renderer.enhanced = false
	renderer.apply(model, metadata)
	var setup = PHYSICS.new()
	assert(setup.apply(rig, model, metadata.physics))
	var head := rig.find_bone("頭")
	var arm := rig.find_bone("左腕")
	var head_pose := rig.get_bone_pose_rotation(head)
	var arm_pose := rig.get_bone_pose_rotation(arm)
	var rate := Engine.physics_ticks_per_second
	var started := Time.get_ticks_usec()
	for step in rate * 2:
		await physics_frame
	var before_motion: Array[Vector3] = []
	for entry in setup._dynamic:
		before_motion.append(entry.body.global_position)
	var motion_response := 0.0
	for step in rate * 2:
		var phase := float(step) / float(rate * 2) * TAU
		rig.set_bone_pose_rotation(head, head_pose * Quaternion(Vector3.FORWARD, sin(phase) * 0.4))
		rig.set_bone_pose_rotation(arm, arm_pose * Quaternion(Vector3.RIGHT, sin(phase) * 0.45))
		await physics_frame
		for index in setup._dynamic.size():
			motion_response = maxf(motion_response, setup._dynamic[index].body.global_position.distance_to(before_motion[index]))
	rig.set_bone_pose_rotation(head, head_pose)
	rig.set_bone_pose_rotation(arm, arm_pose)
	var speeds: Array[float] = []
	var angular_speeds: Array[float] = []
	var maximum_offset := 0.0
	var residuals := {}
	for step in rate * 3:
		await physics_frame
		for entry in setup._dynamic:
			var body: RigidBody3D = entry.body
			assert(body.global_transform.is_finite())
			maximum_offset = maxf(maximum_offset, body.global_position.distance_to(setup._follow_target(entry).origin))
			if step >= rate * 2 and not setup._is_hair(entry):
				speeds.append(body.linear_velocity.length())
				angular_speeds.append(body.angular_velocity.length())
				var key: String = str(entry.source.get("name", entry.bone))
				residuals[key] = float(residuals.get(key, 0.0)) + body.angular_velocity.length() / rate
	speeds.sort()
	angular_speeds.sort()
	var ranked: Array = residuals.keys()
	ranked.sort_custom(func(a, b): return residuals[a] > residuals[b])
	var worst := {}
	for key in ranked.slice(0, 5):
		worst[key] = residuals[key]
	var result := {"bodies": setup.counts.bodies, "joints": setup.counts.joints,
		"normalized_mode2_children": setup.counts.get("normalized_mode2_children", 0),
		"cloth_speed_p95_m_s": speeds[int(speeds.size() * 0.95)],
		"cloth_angular_speed_p95_rad_s": angular_speeds[int(angular_speeds.size() * 0.95)],
		"maximum_offset_m": maximum_offset, "assisted_pairs": setup.assisted_pairs.size(),
		"simulation_wall_ms": (Time.get_ticks_usec() - started) / 1000.0}
	result["worst_residual_angular_speed"] = worst
	result["motion_response_m"] = motion_response
	assert(motion_response > 0.005, "Settled physics must still respond to head and arm movement")
	model.queue_free()
	await process_frame
	return result


func _head_contact() -> bool:
	var world := Node3D.new()
	root.add_child(world)
	var rig := Skeleton3D.new()
	world.add_child(rig)
	for name in ["頭", "Bone_001", "Bone_002"]:
		rig.add_bone(name)
	rig.set_bone_rest(0, Transform3D(Basis.IDENTITY, Vector3(0, 1.0, 0)))
	rig.set_bone_parent(1, 0)
	rig.set_bone_rest(1, Transform3D(Basis.IDENTITY, Vector3(0, 0.5, 0)))
	rig.set_bone_parent(2, 1)
	rig.set_bone_rest(2, Transform3D(Basis.IDENTITY, Vector3(0, -0.2, 0)))
	rig.reset_bone_poses()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0, 1.3, 0), Vector3(0.01, 1.3, 0), Vector3(0, 1.31, 0)])
	arrays[Mesh.ARRAY_BONES] = PackedInt32Array([1, 2, 0, 0, 1, 2, 0, 0, 1, 2, 0, 0])
	arrays[Mesh.ARRAY_WEIGHTS] = PackedFloat32Array([0.5, 0.5, 0, 0, 0.5, 0.5, 0, 0, 0.5, 0.5, 0, 0])
	var mesh := MeshInstance3D.new()
	mesh.mesh = ArrayMesh.new()
	mesh.mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := StandardMaterial3D.new()
	material.resource_name = "Hair"
	mesh.mesh.surface_set_material(0, material)
	world.add_child(mesh)
	mesh.skin = rig.create_skin_from_rest_transforms()
	mesh.skeleton = mesh.get_path_to(rig)
	var data := {"rigid_bodies": [
		{"name": "頭", "bone": "頭", "type": 0, "shape": "sphere", "size": [0.1, 0, 0], "position": [0, 1.0, 0], "rotation": [0, 0, 0, 1], "collision_mask": 0},
		{"name": "Bone_002", "bone": "Bone_002", "type": 1, "shape": "sphere", "size": [0.02, 0, 0], "position": [0, 1.3, 0], "rotation": [0, 0, 0, 1], "mass": 0.05, "collision_group": 4, "collision_mask": 0}], "joints": []}
	var setup = PHYSICS.new()
	assert(setup.apply(rig, world, data))
	assert(setup._hair_bones.has(1) and setup._hair_bones.has(2), "Hair material weights must identify unnamed chains")
	var inside: Dictionary = setup._entries[1].duplicate()
	inside.rest_world = Transform3D(Basis.IDENTITY, Vector3(0, 1.0, 0))
	assert(setup._rest_overlap(inside, setup._entries[0]))
	assert(not setup._rest_overlap(setup._entries[1], setup._entries[0]))
	for step in Engine.physics_ticks_per_second:
		await physics_frame
	var supported: bool = setup.bodies[1].global_position.y > 1.11
	world.queue_free()
	await process_frame
	return supported
