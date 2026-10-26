extends SceneTree

const RETARGET = preload("res://scripts/mocap_retarget.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(45.0).timeout.connect(func(): quit(1))
	assert(_exercise(false))
	assert(_exercise(true))
	assert(_standard_only())
	assert(_calibrated_fullbody())
	print("FULLBODY_RETARGET_PASS VTuber default, weighted D/dual chains, crouch, lift, foot direction, turn/head, bounded support-root, independent loss/reacquire, mode/recenter reset")
	quit(0)


func _exercise(dual: bool) -> bool:
	var model := fixture(dual)
	root.add_child(model)
	var rig := model.get_child(0) as Skeleton3D
	var setup = RETARGET.new()
	assert(setup.apply(rig, model))
	assert(setup.has_method("set_mode") and setup.mode == "vtuber")
	assert(not setup.set_mode("invalid") and setup.mode == "vtuber")
	var neutral_root := rig.get_bone_pose_position(rig.find_bone("腰"))
	var packet := standing(rig)
	assert(settle(setup, packet))
	assert(not setup.tracking.lower_body)
	assert(setup.set_mode("full_body"))
	assert(setup.capabilities.left_leg and setup.capabilities.right_leg)
	assert(setup._fullbody.chains.size() == (4 if dual else 2), "Every independently weighted deform chain must be driven")
	assert(settle(setup, packet))
	var foot_before := position(rig, "左足首D")
	var invalid_foot := packet.duplicate(true)
	invalid_foot.pose.world[29] = mp(point(packet.pose.world[27]) - Vector3.UP * 0.15)
	invalid_foot.pose.world[31] = invalid_foot.pose.world[29].duplicate()
	assert(settle(setup, invalid_foot))
	var right_contact := false
	for chain: Dictionary in setup._fullbody.chains:
		if chain.side == "right":
			right_contact = right_contact or chain.contact
	assert(right_contact, "A degenerate opposite foot must not pollute the floor estimate and release the valid planted foot")
	assert(settle(setup, packet))
	var rolled := crouch(packet, 0.12)
	var hip_center := (point(rolled.pose.world[23]) + point(rolled.pose.world[24])) * 0.5
	var pelvis_roll := Basis(Vector3.BACK, 0.45)
	for id in [11, 12, 13, 14, 15, 16, 23, 24]:
		rolled.pose.world[id] = mp(hip_center + pelvis_roll * (point(rolled.pose.world[id]) - hip_center))
	for ids in [[23, 25, 27], [24, 26, 28]]:
		rolled.pose.world[ids[1]] = mp(reference_knee(point(rolled.pose.world[ids[0]]), point(rolled.pose.world[ids[2]]), 0.4, 0.4))
	assert(settle(setup, rolled))
	for chain: Dictionary in setup._fullbody.chains:
		assert(chain.contact, "Pelvis roll and unequal hip heights must not classify either grounded foot as airborne")
	assert(settle(setup, packet))
	var maximum_drift := 0.0
	for frame in 60:
		assert(settle(setup, crouch(packet, 0.25 * (frame + 1) / 60.0), 1))
		maximum_drift = maxf(maximum_drift, position(rig, "左足首D").distance_to(foot_before))
	assert(maximum_drift < 0.03, "Continuous crouching must reduce planted-foot sliding between frames, not only converge at the final pose")
	var squat := crouch(packet, 0.25)
	assert(settle(setup, squat))
	assert(rig.get_bone_pose_position(rig.find_bone("腰")).y < neutral_root.y - 0.18, "Squatting must lower the model root from support constraints")
	assert(position(rig, "左足首D").distance_to(foot_before) < 0.015, "Planted ankle must stay anchored while crouching")
	assert(position(rig, "左ひざD").z > 0.15, "Human knees must protrude forward while the shins flex backward")
	assert(absf(position(rig, "左足D").distance_to(position(rig, "左ひざD")) - 0.4) < 0.0001)
	assert(absf(position(rig, "左ひざD").distance_to(position(rig, "左足首D")) - 0.4) < 0.0001)
	if dual:
		assert(position(rig, "左ひざ").distance_to(position(rig, "左ひざD")) < 0.001)
	assert(settle(setup, packet))
	var lift := lifted(packet, 0.3)
	assert(settle(setup, lift))
	assert(position(rig, "左足首D").y > foot_before.y + 0.2)
	assert(position(rig, "右足首D").distance_to(Vector3(-0.1, 0.05, 0)) < 0.015)
	var held := rig.get_bone_pose_rotation(rig.find_bone("左ひざD"))
	var lost := lift.duplicate(true)
	lost.pose.image[25][0] = 1.2
	assert(settle(setup, lost, 5))
	assert(not setup.tracking.left_leg and setup.tracking.right_leg and setup.tracking.lower_body)
	assert(absf(held.dot(rig.get_bone_pose_rotation(rig.find_bone("左ひざD")))) > 0.999, "Only the lost leg must briefly hold")
	assert(settle(setup, lost, 70))
	assert(rig.get_bone_pose_rotation(rig.find_bone("左ひざD")).angle_to(Quaternion.IDENTITY) < 0.02)
	assert(settle(setup, lift, 1))
	var first_angle := rig.get_bone_pose_rotation(rig.find_bone("左ひざD")).angle_to(Quaternion.IDENTITY)
	assert(settle(setup, lift))
	assert(first_angle < rig.get_bone_pose_rotation(rig.find_bone("左ひざD")).angle_to(Quaternion.IDENTITY) - 0.05, "Reacquisition must interpolate rather than snap")
	var landing := lifted(packet, 0.0)
	assert(settle(setup, landing))
	assert(position(rig, "左足首D").z > foot_before.z + 0.08, "A new planted foot must anchor at its landing position rather than snap to the original stance")
	assert(settle(setup, packet))
	var pointed := packet.duplicate(true)
	var ankle := point(pointed.pose.world[27])
	var foot_turn := Basis(Vector3.UP, 0.65)
	for id in [29, 31]:
		pointed.pose.world[id] = mp(ankle + foot_turn * (point(pointed.pose.world[id]) - ankle))
	assert(settle(setup, pointed))
	assert((rig.get_bone_global_pose(rig.find_bone("左足首D")).basis * Vector3.BACK).dot(foot_turn * Vector3.BACK) > 0.995)
	var tilted := packet.duplicate(true)
	for id in [29, 31]:
		tilted.pose.world[id] = mp(ankle + Basis(Vector3.RIGHT, -0.3) * (point(tilted.pose.world[id]) - ankle))
	assert(settle(setup, tilted))
	assert(minimum_sole(model, rig, "左") >= setup._fullbody.chains[0].sole - 0.002, "Pitching a planted shoe must preserve its sole clearance")
	var turned := packet.duplicate(true)
	var yaw := Basis(Vector3.UP, 2.2)
	var pivot := (point(packet.pose.world[23]) + point(packet.pose.world[24])) * 0.5
	for id in 33:
		if turned.pose.world[id][3] > 0.5:
			turned.pose.world[id] = mp(pivot + yaw * (point(packet.pose.world[id]) - pivot))
	turned.face = {"blendshapes": {}, "matrix": matrix(yaw)}
	assert(settle(setup, turned))
	var head := rig.find_bone("頭")
	assert(absf(rig.get_bone_global_pose(head).basis.get_rotation_quaternion().dot(yaw.get_rotation_quaternion())) > 0.999, "Head limits must be relative to the torso during a full-body turn")
	assert(absf(rig.get_bone_global_pose(rig.find_bone("下半身")).basis.get_rotation_quaternion().dot(yaw.get_rotation_quaternion())) > 0.999)
	var right_anchor := position(rig, "右足首D")
	var lost_hip := turned.duplicate(true)
	lost_hip.pose.image[23][0] = 1.2
	assert(settle(setup, lost_hip))
	assert(setup.tracking.right_leg and not setup.tracking.left_leg)
	assert(position(rig, "右足首D").distance_to(right_anchor) < 0.015, "Losing one hip must not reset the actual pelvis while the valid leg solver uses its previous orientation")
	assert(setup._fullbody.root_offset.is_finite() and Vector2(setup._fullbody.root_offset.x, setup._fullbody.root_offset.z).length() <= 0.35001)
	setup.recenter()
	assert(rig.get_bone_pose_position(rig.find_bone("腰")).is_equal_approx(neutral_root))
	assert(settle(setup, packet))
	var invalid := packet.duplicate(true)
	invalid.pose.world[27][0] = 50.0
	assert(settle(setup, invalid))
	assert(not setup.tracking.left_leg and setup.tracking.right_leg)
	assert(setup._fullbody.root_offset.is_finite())
	assert(settle(setup, squat))
	setup.update(1.0)
	assert(not setup.tracking.lower_body)
	for frame in 80:
		setup.update(1.0 / 60.0)
	assert(rig.get_bone_pose_position(rig.find_bone("腰")).distance_to(neutral_root) < 0.001, "Missing full-body frames must release root translation as well as leg rotations")
	assert(settle(setup, landing))
	assert(position(rig, "左足首D").z > 0.08, "A new stance after a network gap must not reuse the pre-gap contact anchor")
	var absent := {"version": 1, "seq": 0, "timestamp_ms": 0, "pose": null, "hands": [], "face": null}
	assert(settle(setup, absent, 50))
	assert(settle(setup, packet))
	assert(absf(position(rig, "左足首D").z) < 0.03, "Pose-null frames must also release old foot anchors before reacquisition")
	assert(settle(setup, squat))
	var hidden_feet := squat.duplicate(true)
	for id in [29, 30, 31, 32]:
		hidden_feet.pose.image[id][1] = 1.2
	assert(settle(setup, hidden_feet, 80))
	assert(setup.tracking.left_leg and setup.tracking.right_leg)
	assert(setup._fullbody.root_offset.length() < 0.001, "Root displacement must expire without observed foot support even while knees/ankles remain tracked")
	assert(setup.set_mode("vtuber"))
	assert(rig.get_bone_pose_position(rig.find_bone("腰")).is_equal_approx(neutral_root))
	assert(settle(setup, squat))
	assert(rig.get_bone_pose_rotation(rig.find_bone("左ひざD")).angle_to(Quaternion.IDENTITY) < 0.001)
	assert(not setup.tracking.lower_body)
	print("FULLBODY_CONTACT_DRIFT ", JSON.stringify({"dual_skin_chain": dual, "maximum_ankle_drift": maximum_drift}))
	model.free()
	return true


func _calibrated_fullbody() -> bool:
	var model := fixture()
	root.add_child(model)
	var rig := model.get_child(0) as Skeleton3D
	var setup = RETARGET.new()
	assert(setup.apply(rig, model) and setup.set_mode("full_body"))
	var initial := standing(rig)
	var packet := crouch(initial, 0.25)
	packet.face = {"blendshapes": {}, "matrix": matrix(Basis.from_euler(Vector3(0.1, 0.2, -0.1)))}
	assert(settle(setup, initial) and settle(setup, packet))
	var expected: Array[Quaternion] = []
	for bone in rig.get_bone_count():
		expected.append(rig.get_bone_pose_rotation(bone))
	var expected_root: Vector3 = setup._fullbody.root_offset
	assert(expected_root.y < -0.2)
	for angles in [Vector2(45, 45), Vector2(-45, -45)]:
		var calibration := preload("res://scripts/capture_calibration.gd").new()
		assert(calibration.update_profile({"enabled": true, "position": [0.0, 0.0, 1.5], "yaw": angles.x, "pitch": angles.y}))
		var rotation := Basis(Vector3.UP, deg_to_rad(angles.x)) * Basis(Vector3.RIGHT, -deg_to_rad(angles.y))
		setup.recenter()
		assert(settle(setup, calibration.correct_frame(camera_frame(initial, rotation))))
		var raw := camera_frame(packet, rotation)
		var corrected: Dictionary = calibration.correct_frame(raw)
		assert(corrected.pose.image == raw.pose.image, "Camera correction must leave image visibility coordinates intact")
		assert(settle(setup, corrected))
		for bone in rig.get_bone_count():
			assert(absf(expected[bone].dot(rig.get_bone_pose_rotation(bone))) > 0.99999, "Off-axis correction must preserve full-body/head/arm bone targets")
		assert(setup._fullbody.root_offset.distance_to(expected_root) < 0.00001)
	# MediaPipe's hip-centered world coordinates carry relative posture, not a global root trajectory.
	setup.recenter()
	var centered_initial := hip_centered(initial)
	var centered_packet := hip_centered(packet)
	assert(settle(setup, centered_initial) and settle(setup, centered_packet))
	assert(((point(centered_packet.pose.world[23]) + point(centered_packet.pose.world[24])) * 0.5).length() < 0.000001)
	assert(setup._fullbody.root_offset.distance_to(expected_root) < 0.00001, "Support-derived crouch motion must work even when the world hip midpoint stays zero")
	model.free()
	return true


static func camera_frame(packet: Dictionary, camera_to_user: Basis) -> Dictionary:
	var result := packet.duplicate(true)
	for id in 33:
		var confidence: float = result.pose.world[id][3]
		result.pose.world[id] = mp(camera_to_user.inverse() * point(result.pose.world[id]))
		result.pose.world[id][3] = confidence
	if result.face is Dictionary:
		var m: Array = result.face.matrix
		var basis := Basis(Vector3(m[0], m[4], m[8]), Vector3(m[1], m[5], m[9]), Vector3(m[2], m[6], m[10]))
		result.face.matrix = matrix(camera_to_user.inverse() * basis)
	return result


static func hip_centered(packet: Dictionary) -> Dictionary:
	var result := packet.duplicate(true)
	var origin := (point(result.pose.world[23]) + point(result.pose.world[24])) * 0.5
	for id in 33:
		var confidence: float = result.pose.world[id][3]
		result.pose.world[id] = mp(point(result.pose.world[id]) - origin)
		result.pose.world[id][3] = confidence
	return result


static func minimum_sole(model: Node3D, rig: Skeleton3D, side: String) -> float:
	var minimum := INF
	var wanted := [rig.find_bone(side + "足首D"), rig.find_bone(side + "足先EX")]
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if mesh.skin == null:
			continue
		for surface in mesh.mesh.get_surface_count():
			var arrays := mesh.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
			for vertex in vertices.size():
				var bind := bones[vertex * 4]
				var bone := mesh.skin.get_bind_bone(bind)
				if bone in wanted:
					var transformed: Vector3 = rig.get_bone_global_pose(bone) * mesh.skin.get_bind_pose(bind) * vertices[vertex]
					minimum = minf(minimum, transformed.y)
	return minimum


func _standard_only() -> bool:
	var model := fixture(true, true)
	root.add_child(model)
	var rig := model.get_child(0) as Skeleton3D
	var setup = RETARGET.new()
	assert(setup.apply(rig, model) and setup.set_mode("full_body"))
	assert(setup._fullbody.chains.size() == 2)
	for chain: Dictionary in setup._fullbody.chains:
		assert(not rig.get_bone_name(chain.upper).ends_with("D"), "Unweighted D controls must not override the actual standard skin chain")
	var packet := standing(rig)
	assert(settle(setup, packet))
	assert(settle(setup, lifted(packet, 0.3)))
	assert(position(rig, "左足首").y > 0.2)
	assert(rig.get_bone_pose_rotation(rig.find_bone("左ひざD")).angle_to(Quaternion.IDENTITY) < 0.001)
	model.free()
	return true


static func fixture(dual: bool = false, standard_only: bool = false) -> Node3D:
	var model := preload("res://tests/test_mocap_retarget.gd")._synthetic_model(false)
	var rig := model.get_child(0) as Skeleton3D
	for side in ["左", "右"]:
		var sign := 1.0 if side == "左" else -1.0
		var toe := rig.get_bone_count()
		rig.add_bone(side + "足先EX")
		rig.set_bone_parent(toe, rig.find_bone(side + "足首D"))
		rig.set_bone_rest(toe, Transform3D(Basis.IDENTITY, Vector3(0, -0.03, 0.12)))
		if dual:
			var parent := rig.find_bone("下半身")
			for part in ["足", "ひざ", "足首", "つま先"]:
				var index := rig.get_bone_count()
				rig.add_bone(side + part)
				rig.set_bone_parent(index, parent)
				var offset := Vector3(sign * 0.1, -0.1, 0) if part == "足" else (Vector3(0, -0.03, 0.12) if part == "つま先" else Vector3(0, -0.4, 0))
				rig.set_bone_rest(index, Transform3D(Basis.IDENTITY, offset))
				parent = index
	rig.reset_bone_poses()
	var vertices := PackedVector3Array()
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	for side in ["左", "右"]:
		var parts := [] if standard_only else ["足D", "ひざD", "足首D", "足先EX"]
		if dual:
			parts.append_array(["足", "ひざ", "足首", "つま先"])
		for part: String in parts:
			var bone := rig.find_bone(side + part)
			var origin := rig.get_bone_global_rest(bone).origin
			for offset in [Vector3(-0.02, -0.05, -0.03), Vector3(0.02, -0.05, -0.03), Vector3(0, -0.05, 0.1)]:
				vertices.append(origin + offset)
				bones.append_array(PackedInt32Array([bone, 0, 0, 0]))
				weights.append_array(PackedFloat32Array([1.0, 0, 0, 0]))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.skin = rig.create_skin_from_rest_transforms()
	model.add_child(instance)
	instance.skeleton = instance.get_path_to(rig)
	return model


static func standing(rig: Skeleton3D) -> Dictionary:
	var world: Array = []
	var image: Array = []
	for id in 33:
		world.append([0, 0, 0, 0])
		image.append([0.5, 0.5, 0, 0])
	for pair in [[11, "左腕"], [12, "右腕"], [13, "左ひじ"], [14, "右ひじ"], [15, "左手首"], [16, "右手首"], [23, "左足D"], [24, "右足D"], [25, "左ひざD"], [26, "右ひざD"], [27, "左足首D"], [28, "右足首D"]]:
		world[pair[0]] = mp(position(rig, pair[1]))
		image[pair[0]] = [0.5, 0.5, 0, 1]
	for ids in [[27, 29, 31], [28, 30, 32]]:
		var ankle := point(world[ids[0]])
		world[ids[1]] = mp(ankle + Vector3(0, -0.05, -0.05))
		world[ids[2]] = mp(ankle + Vector3(0, -0.05, 0.15))
		image[ids[1]] = [0.5, 0.5, 0, 1]
		image[ids[2]] = [0.5, 0.5, 0, 1]
	return {"version": 1, "seq": 0, "timestamp_ms": 0, "pose": {"world": world, "image": image}, "hands": [], "face": null}


static func crouch(packet: Dictionary, amount: float) -> Dictionary:
	var result := packet.duplicate(true)
	for id in [11, 12, 13, 14, 15, 16, 23, 24]:
		result.pose.world[id] = mp(point(packet.pose.world[id]) - Vector3.UP * amount)
	for ids in [[23, 25, 27], [24, 26, 28]]:
		var hip := point(result.pose.world[ids[0]])
		var ankle := point(result.pose.world[ids[2]])
		var first := point(packet.pose.world[ids[0]]).distance_to(point(packet.pose.world[ids[1]]))
		var second := point(packet.pose.world[ids[1]]).distance_to(point(packet.pose.world[ids[2]]))
		result.pose.world[ids[1]] = mp(reference_knee(hip, ankle, first, second))
	return result


static func lifted(packet: Dictionary, amount: float) -> Dictionary:
	var result := packet.duplicate(true)
	for id in [27, 29, 31]:
		result.pose.world[id] = mp(point(packet.pose.world[id]) + Vector3(0, amount, 0.12))
	var hip := point(result.pose.world[23])
	var ankle := point(result.pose.world[27])
	var first := point(packet.pose.world[23]).distance_to(point(packet.pose.world[25]))
	var second := point(packet.pose.world[25]).distance_to(point(packet.pose.world[27]))
	result.pose.world[25] = mp(reference_knee(hip, ankle, first, second))
	return result


static func reference_knee(hip: Vector3, ankle: Vector3, first: float, second: float) -> Vector3:
	# Construct a bent triangle from the cosine rule independently of the retarget solver.
	var distance := minf(hip.distance_to(ankle), first + second - 0.0001)
	var axis := (ankle - hip).normalized()
	var angle := acos(clampf((first * first + distance * distance - second * second) / (2.0 * first * distance), -1.0, 1.0))
	var pole := (Vector3.BACK - axis * axis.z).normalized()
	return hip + first * (axis * cos(angle) + pole * sin(angle))


static func settle(setup: RefCounted, packet: Dictionary, frames: int = 80) -> bool:
	for frame in frames:
		packet.seq = setup._last_sequence + 1
		packet.timestamp_ms = maxf(0, setup._last_timestamp_ms + 17)
		assert(setup.ingest(packet))
		setup.update(1.0 / 60.0)
	return true


static func position(rig: Skeleton3D, name: String) -> Vector3:
	return rig.get_bone_global_pose(rig.find_bone(name)).origin


static func point(value: Array) -> Vector3:
	return Vector3(value[0], -value[1], -value[2])


static func mp(value: Vector3) -> Array:
	return [value.x, -value.y, -value.z, 1.0]


static func matrix(basis: Basis) -> Array:
	return [basis.x.x, basis.y.x, basis.z.x, 0, basis.x.y, basis.y.y, basis.z.y, 0, basis.x.z, basis.y.z, basis.z.z, 0, 0, 0, 0, 1]
