extends SceneTree

const RETARGET = preload("res://scripts/mocap_retarget.gd")
var sequence := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(45.0).timeout.connect(func(): quit(1))
	var args := OS.get_cmdline_user_args()
	assert(not args.is_empty(), "Pass private native-import result.json or metadata.json paths")
	for path: String in args:
		var metadata: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		if metadata.has("metadata"):
			metadata = JSON.parse_string(FileAccess.get_file_as_string(metadata.metadata))
		var loader := HonkaiPMXLoader.new()
		var loaded := loader.load_file(metadata.model_file)
		assert(not loaded.is_empty(), loader.error)
		var model: Node3D = loaded.root
		root.add_child(model)
		var actor = preload("res://scripts/actor.gd").new()
		actor._prepare_pose(model, false)
		actor.free()
		var rig := model.get_node("MMDSkeleton") as Skeleton3D
		var tails: PackedVector3Array = rig.get_meta("pmx_tail_offsets")
		assert(tails.size() == rig.get_bone_count())
		var setup = RETARGET.new()
		assert(setup.apply(rig, model))
		var report := {"model": path, "hands": [], "arms": []}
		for side in ["左", "右"]:
			setup.reset()
			var hand := _hand(rig, side, tails)
			var packet := {"version": 1, "seq": 0, "timestamp_ms": 0, "pose": null, "hands": [hand], "face": null}
			_settle(setup, packet)
			var neutral_dot := _assert_hand(rig, setup, side, Basis.IDENTITY)
			assert(neutral_dot > 0.999)
			var palm_origin := _point(hand.world[0])
			var rotation := Basis(Vector3(0.4, 0.6, 0.2).normalized(), 0.8)
			for index in hand.world.size():
				hand.world[index] = _mp(palm_origin + rotation * (_point(hand.world[index]) - palm_origin))
			_settle(setup, packet)
			var rotated_dot := _assert_hand(rig, setup, side, rotation)
			assert(rotated_dot > 0.999)
			report.hands.append({"side": side, "neutral_min_rotation_dot": neutral_dot, "rotated_min_rotation_dot": rotated_dot})
			setup.reset()
			var upper := Vector3(0.4 if side == "左" else -0.4, 0.5, 0.8).normalized()
			var lower := (Vector3.BACK - upper * Vector3.BACK.dot(upper)).normalized()
			packet = _pose(rig, side, upper, lower)
			_settle(setup, packet)
			var upper_bone := rig.find_bone(side + "腕")
			var initial := rig.get_bone_global_pose(upper_bone).basis.orthonormalized()
			var roll := Basis(upper, 0.8)
			packet = _pose(rig, side, upper, roll * lower)
			_settle(setup, packet)
			var actual := rig.get_bone_global_pose(upper_bone).basis.orthonormalized()
			var plane_dot := absf(actual.get_rotation_quaternion().dot((roll * initial).get_rotation_quaternion()))
			var upper_dot := (_position(rig, side + "ひじ") - _position(rig, side + "腕")).normalized().dot(upper)
			var lower_dot := (_position(rig, side + "手首") - _position(rig, side + "ひじ")).normalized().dot(roll * lower)
			assert(plane_dot > 0.999, "Native rig upper-arm twist must follow the elbow plane")
			assert(upper_dot > 0.995 and lower_dot > 0.995)
			report.arms.append({"side": side, "elbow_plane_rotation_dot": plane_dot, "upper_direction_dot": upper_dot, "lower_direction_dot": lower_dot})
		print("MOCAP_NATIVE_RIG_PASS ", JSON.stringify(report))
		model.free()
	quit(0)


func _hand(rig: Skeleton3D, side: String, tails: PackedVector3Array) -> Dictionary:
	var points: Array = [_mp(_position(rig, side + "手首"))]
	var image: Array = [[0.5, 0.5, 0.0]]
	for finger in RETARGET.FINGERS:
		for part: String in finger:
			points.append(_mp(_position(rig, side + part)))
			image.append([0.5, 0.5, 0.0])
		var terminal := rig.find_bone(side + finger[2])
		assert(tails[terminal].is_finite() and tails[terminal].length() > 0.0001, "Private PMX fixture must exercise real authored terminal tails")
		var pose := rig.get_bone_global_pose(terminal)
		points.append(_mp(pose.origin + pose.basis * tails[terminal]))
		image.append([0.5, 0.5, 0.0])
	return {"side": "Left" if side == "左" else "Right", "world": points, "image": image}


func _assert_hand(rig: Skeleton3D, setup: RefCounted, side: String, rotation: Basis) -> float:
	var names: Array = [side + "手首"]
	for finger in RETARGET.FINGERS:
		for part: String in finger:
			names.append(side + part)
	var minimum_dot := 1.0
	for name: String in names:
		var bone := rig.find_bone(name)
		var expected: Basis = rotation * setup._neutral_global[bone].basis.orthonormalized()
		var actual := rig.get_bone_global_pose(bone).basis.orthonormalized()
		var rotation_dot := absf(actual.get_rotation_quaternion().dot(expected.get_rotation_quaternion()))
		assert(rotation_dot > 0.999, "Native hand must preserve its rest orientation and follow palm rotation: " + name)
		minimum_dot = minf(minimum_dot, rotation_dot)
	return minimum_dot


func _pose(rig: Skeleton3D, side: String, upper: Vector3, lower: Vector3) -> Dictionary:
	var world: Array = []
	var image: Array = []
	for index in 33:
		world.append([0.0, 0.0, 0.0, 0.0])
		image.append([0.5, 0.5, 0.0, 0.0])
	var indices := [11, 13, 15] if side == "左" else [12, 14, 16]
	var shoulder := _position(rig, side + "腕")
	for pair in [[indices[0], shoulder], [indices[1], shoulder + upper * 0.25], [indices[2], shoulder + upper * 0.25 + lower * 0.2]]:
		world[pair[0]] = _mp(pair[1]) + [1.0]
		image[pair[0]] = [0.5, 0.5, 0.0, 1.0]
	return {"version": 1, "seq": 0, "timestamp_ms": 0, "pose": {"world": world, "image": image}, "hands": [], "face": null}


func _settle(setup: RefCounted, packet: Dictionary) -> void:
	for frame in 80:
		sequence += 1
		packet.seq = sequence
		packet.timestamp_ms = sequence * 17
		assert(setup.ingest(packet))
		setup.update(1.0 / 60.0)


func _position(rig: Skeleton3D, name: String) -> Vector3:
	return rig.get_bone_global_pose(rig.find_bone(name)).origin


func _mp(point: Vector3) -> Array:
	return [point.x, -point.y, -point.z]


func _point(value: Array) -> Vector3:
	return Vector3(value[0], -value[1], -value[2])
