extends SceneTree

const HELPERS = preload("res://tests/test_fullbody_retarget.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(90.0).timeout.connect(func(): quit(1))
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
	assert(setup.apply(rig, model) and setup.set_mode("full_body"))
	assert(setup._fullbody.has_side("left") and setup._fullbody.has_side("right"))
	var packet := HELPERS.standing(rig)
	assert(HELPERS.settle(setup, packet))
	var left_samples := _samples(model, rig, setup._fullbody, "left")
	var right_samples := _samples(model, rig, setup._fullbody, "right")
	assert(left_samples.size() >= 20 and right_samples.size() >= 20)
	var neutral_left := _skin(rig, left_samples)
	var neutral_right := _skin(rig, right_samples)
	var right_ankle := HELPERS.position(rig, "右足首D")
	var left_ankle := HELPERS.position(rig, "左足首D")
	var first := HELPERS.position(rig, "左足D").distance_to(HELPERS.position(rig, "左ひざD"))
	var second := HELPERS.position(rig, "左ひざD").distance_to(left_ankle)
	var squat := HELPERS.crouch(packet, 0.18)
	assert(HELPERS.settle(setup, squat))
	var root_offset: Vector3 = setup._fullbody.root_offset
	assert(root_offset.y < -0.1 and root_offset.y >= -0.45)
	assert(HELPERS.position(rig, "左足首D").distance_to(left_ankle) < 0.02, "Actual model ankle must retain its calibrated sole offset during crouching")
	assert(absf(HELPERS.position(rig, "左足D").distance_to(HELPERS.position(rig, "左ひざD")) - first) < 0.0001)
	assert(absf(HELPERS.position(rig, "左ひざD").distance_to(HELPERS.position(rig, "左足首D")) - second) < 0.0001)
	assert(HELPERS.settle(setup, packet))
	var lift := HELPERS.lifted(packet, 0.22)
	assert(HELPERS.settle(setup, lift))
	var moved_left := _skin(rig, left_samples)
	var moved_right := _skin(rig, right_samples)
	var left_motion := _maximum_motion(neutral_left, moved_left)
	var right_motion := _maximum_motion(neutral_right, moved_right)
	assert(left_motion > 0.04, "Real skinned vertices must move; animating unweighted standard/IK bones is insufficient")
	assert(right_motion < 0.025, "Lifting one leg must not pull the planted opposite leg")
	assert(HELPERS.position(rig, "左足首D").y > left_ankle.y + 0.12)
	assert(HELPERS.position(rig, "右足首D").distance_to(right_ankle) < 0.02)
	assert(setup.set_mode("vtuber"))
	assert(HELPERS.settle(setup, packet))
	var restored := _skin(rig, left_samples)
	var restore_motion := _maximum_motion(neutral_left, restored)
	assert(restore_motion < 0.025)
	print("FULLBODY_NATIVE_RIG_PASS ", JSON.stringify({"model": path, "left_skin_samples": left_samples.size(), "right_skin_samples": right_samples.size(),
		"left_lift_skin_motion": left_motion, "planted_right_skin_motion": right_motion, "vtuber_restore_motion": restore_motion,
		"crouch_root_y": root_offset.y, "left_sole_y": setup._fullbody.chains[0].sole, "weighted_chains": setup._fullbody.chains.size()}))
	model.free()
	return true


func _samples(model: Node3D, rig: Skeleton3D, solver: RefCounted, side: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var wanted: Array[int] = []
	for chain: Dictionary in solver.chains:
		if chain.side == side:
			wanted.append_array([chain.upper, chain.knee, chain.ankle, chain.toe])
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if mesh.skin == null:
			continue
		for surface in mesh.mesh.get_surface_count():
			var arrays := mesh.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
			var stride: int = bones.size() / vertices.size()
			for vertex in vertices.size():
				var leg_weight := 0.0
				var bindings: Array[Dictionary] = []
				for component in stride:
					var slot := vertex * stride + component
					if weights[slot] <= 0.000001:
						continue
					var bind := bones[slot]
					var bone := mesh.skin.get_bind_bone(bind)
					bindings.append({"bone": bone, "bind_pose": mesh.skin.get_bind_pose(bind), "weight": weights[slot]})
					if bone in wanted:
						leg_weight += weights[slot]
				if leg_weight >= 0.8:
					result.append({"point": vertices[vertex], "bindings": bindings})
					if result.size() >= 200:
						return result
	return result


func _skin(rig: Skeleton3D, samples: Array[Dictionary]) -> PackedVector3Array:
	var result := PackedVector3Array()
	for sample in samples:
		var position := Vector3.ZERO
		for binding: Dictionary in sample.bindings:
			position += (rig.get_bone_global_pose(binding.bone) * binding.bind_pose * sample.point) * binding.weight
		result.append(position)
	return result


func _maximum_motion(before: PackedVector3Array, after: PackedVector3Array) -> float:
	var maximum := 0.0
	for index in before.size():
		maximum = maxf(maximum, before[index].distance_to(after[index]))
	return maximum
