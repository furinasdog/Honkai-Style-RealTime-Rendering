extends RefCounted

const HOLD_SECONDS := 0.25
const RELEASE_SECONDS := 0.45
const EPS := 0.000001
const INVALID_FRAME := Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
var rig: Skeleton3D
var neutral: Dictionary
var local_rotations: Dictionary
var chains: Array[Dictionary] = []
var warnings: Array[String] = []
var global_targets := {}
var pelvis_delta := Basis.IDENTITY
var body_reference := Basis.IDENTITY
var root_index := -1
var pelvis_index := -1
var root_offset := Vector3.ZERO
var root_position := Vector3.ZERO
var _root_neutral := Vector3.ZERO
var _root_parent := Basis.IDENTITY
var _floor := 0.0
var _owned := {}
var _sides := {}
var _last_root := Vector3.ZERO
var _support_age := INF
var _names := {}
var _pelvis_reference := Basis.IDENTITY
var _pelvis_age := INF
var _pelvis_seen := false
var _last_pelvis := Basis.IDENTITY
var _held_pelvis := Quaternion.IDENTITY
var _has_held_pelvis := false


func setup(skeleton: Skeleton3D, model: Node3D, rest: Dictionary, rotations: Dictionary) -> void:
	rig = skeleton
	neutral = rest
	local_rotations = rotations
	for i in rig.get_bone_count():
		_names[_normalize(rig.get_bone_name(i))] = i
	pelvis_index = _find(["下半身", "Hips", "J_Bip_C_Hips", "pelvis", "腰"])
	root_index = _find(["センター", "グルーブ", "Hips", "J_Bip_C_Hips", "pelvis", "腰", "下半身"])
	if root_index >= 0:
		_root_neutral = rig.get_bone_pose_position(root_index)
		var parent := rig.get_bone_parent(root_index)
		_root_parent = neutral[parent].basis.orthonormalized() if parent >= 0 else Basis.IDENTITY
		_owned[root_index] = true
	if pelvis_index >= 0:
		_owned[pelvis_index] = true
	var surfaces: Array[Dictionary] = []
	var weights := {}
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if mesh.mesh == null:
			continue
		for surface in mesh.mesh.get_surface_count():
			var arrays := mesh.mesh.surface_get_arrays(surface)
			if not arrays[Mesh.ARRAY_BONES] is PackedInt32Array or not arrays[Mesh.ARRAY_WEIGHTS] is PackedFloat32Array:
				continue
			var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES].duplicate()
			var values: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
			for slot in bones.size():
				var bone := bones[slot]
				if mesh.skin != null and bone >= 0 and bone < mesh.skin.get_bind_count():
					var bind := mesh.skin.get_bind_bone(bone)
					bone = bind if bind >= 0 else rig.find_bone(mesh.skin.get_bind_name(bone))
				bones[slot] = bone
				if bone >= 0 and bone < rig.get_bone_count() and slot < values.size() and values[slot] > EPS:
					weights[bone] = float(weights.get(bone, 0.0)) + values[slot]
			surfaces.append({"points": arrays[Mesh.ARRAY_VERTEX], "bones": bones, "weights": values})
	for side in ["left", "right"]:
		_sides[side] = {"age": INF, "seen": false, "held": {}, "scale": 0.0}
		var prefix := "左" if side == "left" else "右"
		var english := "Left" if side == "left" else "Right"
		var short_side := "L" if side == "left" else "R"
		var candidates := [[prefix + "足D", prefix + "ひざD", prefix + "足首D", prefix + "足先EX"],
			[prefix + "足", prefix + "ひざ", prefix + "足首", prefix + "つま先"],
			[english + "UpLeg", english + "Leg", english + "Foot", english + "ToeBase"],
			["J_Bip_" + short_side + "_UpperLeg", "J_Bip_" + short_side + "_LowerLeg", "J_Bip_" + short_side + "_Foot", "J_Bip_" + short_side + "_Toes"]]
		var roots := {}
		for names: Array in candidates:
			var upper := _find([names[0]])
			if upper < 0 or roots.has(upper) or _subtree_weight(upper, weights) <= EPS:
				continue
			roots[upper] = true
			var knee := _find([names[1]])
			var ankle := _find([names[2]])
			if knee < 0 or ankle < 0 or not _descendant(knee, upper) or not _descendant(ankle, knee):
				warnings.append(prefix + "腿蒙皮骨链不完整，已跳过该条链。")
				continue
			var toe := _find([names[3]])
			if toe >= 0 and not _descendant(toe, ankle):
				toe = -1
			var first: float = neutral[upper].origin.distance_to(neutral[knee].origin)
			var second: float = neutral[knee].origin.distance_to(neutral[ankle].origin)
			if minf(first, second) < 0.01:
				warnings.append(prefix + "腿骨长度无效，已跳过该条链。")
				continue
			var bounds := _foot_bounds(ankle, surfaces)
			var sole_points := PackedVector3Array()
			for x in [bounds.position.x, bounds.end.x]:
				for z in [bounds.position.z, bounds.end.z]:
					sole_points.append(Vector3(x, bounds.position.y, z) - neutral[ankle].origin)
			var forward: Vector3 = neutral[toe].origin - neutral[ankle].origin if toe >= 0 else Vector3.BACK
			forward.y = 0.0
			if forward.length_squared() < EPS:
				forward = Vector3.BACK
			var foot_frame := _frame(forward, Vector3.UP)
			chains.append({"side": side, "upper": upper, "knee": knee, "ankle": ankle, "toe": toe, "first": first, "second": second,
				"sole": bounds.position.y, "sole_points": sole_points, "foot_frame": foot_frame,
				"contact": false, "planted_before": false, "anchor": Vector3.ZERO, "anchor_rotation": Basis.IDENTITY, "solved": false})
			for bone: int in [upper, knee, ankle, toe]:
				if bone >= 0:
					_owned[bone] = true
	if not chains.is_empty() and (root_index < 0 or pelvis_index < 0 or not _descendant(pelvis_index, root_index) or chains.any(func(chain: Dictionary): return not _descendant(chain.upper, root_index) or not _descendant(chain.upper, pelvis_index))):
		warnings.append("下肢蒙皮链缺少受支持的共同根骨/骨盆层级，已跳过全身下肢。")
		chains.clear()
	_floor = INF
	for chain in chains:
		_floor = minf(_floor, chain.sole)
	if not is_finite(_floor):
		_floor = 0.0
	if has_side("left") and has_side("right"):
		var left: Dictionary = chains.filter(func(chain: Dictionary): return chain.side == "left")[0]
		var right: Dictionary = chains.filter(func(chain: Dictionary): return chain.side == "right")[0]
		var across: Vector3 = neutral[left.upper].origin - neutral[right.upper].origin
		var up := Vector3.UP
		var left_arm := _find(["左腕", "LeftArm", "LeftUpperArm", "J_Bip_L_UpperArm"])
		var right_arm := _find(["右腕", "RightArm", "RightUpperArm", "J_Bip_R_UpperArm"])
		if left_arm >= 0 and right_arm >= 0:
			up = (neutral[left_arm].origin + neutral[right_arm].origin - neutral[left.upper].origin - neutral[right.upper].origin) * 0.5
			var shoulders: Vector3 = neutral[left_arm].origin - neutral[right_arm].origin
			var reference := _frame(shoulders.cross(up), up)
			if reference != INVALID_FRAME:
				body_reference = reference
		var reference := _frame(across.cross(up), up)
		if reference != INVALID_FRAME:
			_pelvis_reference = reference
	reset()


func has_side(side: String) -> bool:
	return chains.any(func(chain: Dictionary): return chain.side == side)


func indices() -> Array:
	return _owned.keys()


func reset() -> void:
	global_targets.clear()
	pelvis_delta = Basis.IDENTITY
	_last_pelvis = Basis.IDENTITY
	_pelvis_age = INF
	_pelvis_seen = false
	_has_held_pelvis = false
	root_offset = Vector3.ZERO
	_last_root = Vector3.ZERO
	_support_age = INF
	root_position = _root_neutral
	for side: String in _sides:
		_sides[side] = {"age": INF, "seen": false, "held": {}, "scale": 0.0}
	for chain in chains:
		chain.contact = false
		chain.planted_before = false
		chain.solved = false


func ingest(points: Array, image: Array) -> void:
	global_targets.clear()
	_pelvis_seen = false
	for state: Dictionary in _sides.values():
		state.seen = false
	for chain in chains:
		chain.solved = false
	if points.size() != 33 or image.size() != 33:
		for chain in chains:
			chain.contact = false
		return
	if pelvis_index >= 0 and _visible(points, image, [23, 24]):
		var up := Vector3.UP
		if _visible(points, image, [11, 12]):
			up = (_point(points[11]) + _point(points[12]) - _point(points[23]) - _point(points[24])) * 0.5
		var across := _point(points[23]) - _point(points[24])
		var pelvis := _frame(across.cross(up), up)
		if pelvis != INVALID_FRAME:
			pelvis_delta = pelvis * _pelvis_reference.inverse()
			_pelvis_seen = true
	var observations := {}
	var lowest := INF
	for side in ["left", "right"]:
		var ids := [23, 25, 27, 29, 31] if side == "left" else [24, 26, 28, 30, 32]
		if not has_side(side) or not _visible(points, image, ids.slice(0, 3)):
			continue
		var hip := _point(points[ids[0]])
		var knee := _point(points[ids[1]])
		var ankle := _point(points[ids[2]])
		var length := hip.distance_to(knee) + knee.distance_to(ankle)
		if not is_finite(length) or length < 0.15 or length > 3.0:
			continue
		var state: Dictionary = _sides[side]
		if state.scale <= 0.0:
			var chain: Dictionary = chains.filter(func(item: Dictionary): return item.side == side)[0]
			state.scale = clampf((chain.first + chain.second) / length, 0.4, 2.5)
		state.age = 0.0
		state.seen = true
		var observation := {"hip": hip, "knee": knee, "ankle": ankle, "feet": _visible(points, image, ids.slice(2)), "floor": INF, "foot_delta": pelvis_delta}
		if observation.feet:
			var heel := _point(points[ids[3]])
			var toe := _point(points[ids[4]])
			var foot_forward := (toe - heel).normalized()
			var foot_up := ankle - (heel + toe) * 0.5
			foot_up -= foot_forward * foot_up.dot(foot_forward)
			var foot := _frame(foot_forward, foot_up)
			if foot == INVALID_FRAME:
				observation.feet = false
			else:
				observation.foot_frame = foot
				observation.floor = minf(heel.y, toe.y)
				lowest = minf(lowest, observation.floor)
		observations[side] = observation
	# A visible leg still needs the same held pelvis basis in both the IK solver and the rig.
	_pelvis_seen = _pelvis_seen or not observations.is_empty()
	if _pelvis_seen:
		_pelvis_age = 0.0
		_last_pelvis = pelvis_delta
	if pelvis_index >= 0:
		global_targets[pelvis_index] = pelvis_delta * neutral[pelvis_index].basis.orthonormalized()
	var root_sum := Vector3.ZERO
	var supports := 0
	for chain in chains:
		if not observations.has(chain.side):
			chain.contact = false
			continue
		var observation: Dictionary = observations[chain.side]
		var scale: float = _sides[chain.side].scale
		var hip := _hip_position(chain)
		var free_ankle: Vector3 = hip + (observation.ankle - observation.hip) * scale
		var foot_delta: Basis = observation.foot_frame * chain.foot_frame.inverse() if observation.feet else pelvis_delta
		var height: float = (observation.floor - lowest) * scale if observation.feet and is_finite(lowest) else INF
		var both_feet: bool = observations.size() == 2 and observations.left.feet and observations.right.feet
		var facing_changed: bool = absf(foot_delta.get_rotation_quaternion().dot(chain.anchor_rotation.get_rotation_quaternion())) < cos(0.35 * 0.5)
		if not observation.feet or height > 0.065 or facing_changed:
			chain.contact = false
		if not chain.contact and both_feet and height <= 0.025:
			chain.contact = true
			chain.anchor = free_ankle + root_offset if facing_changed or chain.planted_before else neutral[chain.ankle].origin + root_offset
			chain.anchor_rotation = foot_delta
			chain.planted_before = true
		if chain.contact:
			var sole_height := INF
			for point: Vector3 in chain.sole_points:
				sole_height = minf(sole_height, (foot_delta * point).y)
			chain.anchor.y = _floor - sole_height
			root_sum += chain.anchor - free_ankle
			supports += 1
		chain.free_ankle = free_ankle
		chain.foot_delta = foot_delta
	if supports > 0:
		# Hip-centered landmarks carry posture; planted feet supply a bounded local displacement.
		root_offset = _bounded_root(root_sum / supports)
		_last_root = root_offset
		_support_age = 0.0
	for chain in chains:
		if not observations.has(chain.side):
			continue
		var observation: Dictionary = observations[chain.side]
		var hip := _hip_position(chain) + root_offset
		var target: Vector3 = chain.anchor if chain.contact else chain.free_ankle + root_offset
		var forward := pelvis_delta * Vector3.BACK
		var pole: Vector3 = observation.knee - observation.hip
		var axis := (target - hip).normalized()
		if axis.is_zero_approx():
			axis = Vector3.DOWN
		target = hip + axis * clampf(hip.distance_to(target), absf(chain.first - chain.second) + 0.0001, chain.first + chain.second - 0.0001)
		pole -= axis * pole.dot(axis)
		if pole.length_squared() < 0.0004:
			pole = forward - axis * forward.dot(axis)
		if pole.length_squared() < EPS:
			pole = Vector3.RIGHT - axis * axis.x
		var knee := _two_bone(hip, target, pole, chain.first, chain.second)
		var upper := knee - hip
		var lower := target - knee
		var delta := _leg_delta(chain, upper, lower)
		global_targets[chain.upper] = _aim(neutral[chain.knee].origin - neutral[chain.upper].origin, upper, delta, neutral[chain.upper].basis)
		global_targets[chain.knee] = _aim(neutral[chain.ankle].origin - neutral[chain.knee].origin, lower, delta, neutral[chain.knee].basis)
		if observation.feet:
			global_targets[chain.ankle] = chain.foot_delta * neutral[chain.ankle].basis.orthonormalized()
		chain.solved = true
	root_position = _root_neutral + _root_parent.inverse() * root_offset


func capture_targets(targets: Dictionary) -> void:
	if _pelvis_seen and pelvis_index >= 0:
		_held_pelvis = targets.get(pelvis_index, local_rotations[pelvis_index])
		_has_held_pelvis = true
	for side: String in _sides:
		if not _sides[side].seen:
			continue
		var held := {}
		for chain in chains:
			if chain.side == side and chain.solved:
				for bone: int in [chain.upper, chain.knee, chain.ankle, chain.toe]:
					if bone >= 0:
						held[bone] = targets.get(bone, local_rotations[bone])
		_sides[side].held = held


func advance(delta: float) -> void:
	for state: Dictionary in _sides.values():
		state.age += delta
	_support_age += delta
	_pelvis_age += delta
	if _pelvis_age > HOLD_SECONDS:
		var release := clampf((_pelvis_age - HOLD_SECONDS) / RELEASE_SECONDS, 0.0, 1.0)
		pelvis_delta = Basis(_last_pelvis.get_rotation_quaternion().slerp(Quaternion.IDENTITY, release))
	for chain in chains:
		if _sides[chain.side].age > HOLD_SECONDS:
			chain.contact = false
	if _support_age > HOLD_SECONDS:
		root_offset = _last_root * (1.0 - clampf((_support_age - HOLD_SECONDS) / RELEASE_SECONDS, 0.0, 1.0))
		root_position = _root_neutral + _root_parent.inverse() * root_offset


func fallback_targets() -> Dictionary:
	var result := {}
	if _has_held_pelvis and (not _pelvis_seen or _pelvis_age > 0.05):
		var release := clampf((_pelvis_age - HOLD_SECONDS) / RELEASE_SECONDS, 0.0, 1.0)
		result[pelvis_index] = _held_pelvis.slerp(local_rotations[pelvis_index], release)
	for state: Dictionary in _sides.values():
		if state.seen and state.age <= 0.05:
			continue
		var release := clampf((float(state.age) - HOLD_SECONDS) / RELEASE_SECONDS, 0.0, 1.0)
		for bone: int in state.held:
			result[bone] = state.held[bone].slerp(local_rotations[bone], release)
	return result


func tracking() -> Dictionary:
	var left: bool = _sides.left.seen and _sides.left.age < HOLD_SECONDS
	var right: bool = _sides.right.seen and _sides.right.age < HOLD_SECONDS
	return {"lower_body": left or right, "left_leg": left, "right_leg": right}


func _hip_position(chain: Dictionary) -> Vector3:
	var position: Vector3 = neutral[chain.upper].origin
	if pelvis_index >= 0:
		var pivot: Vector3 = neutral[pelvis_index].origin
		position = pivot + pelvis_delta * (position - pivot)
	return position


func _leg_delta(chain: Dictionary, upper: Vector3, lower: Vector3) -> Basis:
	var neutral_upper: Vector3 = neutral[chain.knee].origin - neutral[chain.upper].origin
	var neutral_lower: Vector3 = neutral[chain.ankle].origin - neutral[chain.knee].origin
	var swing := Basis(Quaternion((pelvis_delta * neutral_upper).normalized(), upper.normalized())) * pelvis_delta
	var weight := clampf((upper.normalized().cross(lower.normalized()).length() - 0.05) / 0.15, 0.0, 1.0)
	if neutral_upper.normalized().cross(neutral_lower.normalized()).length() < 0.05:
		# Straight legs flex their shins backward; the IK knee pole itself points forward.
		neutral_lower = Vector3.FORWARD
	var rest := _frame(neutral_lower, neutral_upper)
	var measured := _frame(lower, upper)
	if rest == INVALID_FRAME or measured == INVALID_FRAME:
		return swing
	return Basis(swing.get_rotation_quaternion().slerp((measured * rest.inverse()).get_rotation_quaternion(), weight))


static func _two_bone(hip: Vector3, target: Vector3, pole: Vector3, first: float, second: float) -> Vector3:
	var difference := target - hip
	var distance := clampf(difference.length(), absf(first - second) + 0.0001, first + second - 0.0001)
	var along := difference.normalized() if difference.length_squared() > EPS else Vector3.DOWN
	var offset := (first * first - second * second + distance * distance) / (2.0 * distance)
	var height := sqrt(maxf(0.0, first * first - offset * offset))
	return hip + along * offset + pole.normalized() * height


static func _bounded_root(value: Vector3) -> Vector3:
	if not value.is_finite():
		return Vector3.ZERO
	var horizontal := Vector2(value.x, value.z).limit_length(0.35)
	return Vector3(horizontal.x, clampf(value.y, -0.45, 0.2), horizontal.y)


static func _aim(rest: Vector3, measured: Vector3, delta: Basis, basis: Basis) -> Basis:
	if minf(rest.length_squared(), measured.length_squared()) < EPS:
		return delta * basis.orthonormalized()
	return Basis(Quaternion((delta * rest).normalized(), measured.normalized())) * delta * basis.orthonormalized()


static func _point(value: Array) -> Vector3:
	return Vector3(value[0], -value[1], -value[2])


static func _frame(forward: Vector3, up: Vector3) -> Basis:
	if minf(forward.length_squared(), up.length_squared()) < EPS:
		return INVALID_FRAME
	var y := up.normalized()
	var z := forward - y * forward.dot(y)
	if z.length_squared() < EPS:
		return INVALID_FRAME
	z = z.normalized()
	return Basis(y.cross(z).normalized(), y, z).orthonormalized()


static func _visible(points: Array, image: Array, ids: Array) -> bool:
	for id: int in ids:
		if float(points[id][3]) < 0.55 or float(image[id][3]) < 0.55 or not _point(points[id]).is_finite():
			return false
		if image[id][0] < 0.0 or image[id][0] > 1.0 or image[id][1] < 0.0 or image[id][1] > 1.0:
			return false
	return true


func _descendant(bone: int, ancestor: int) -> bool:
	while bone >= 0:
		if bone == ancestor:
			return true
		bone = rig.get_bone_parent(bone)
	return false


func _subtree_weight(root: int, weights: Dictionary) -> float:
	var total := 0.0
	for bone: int in weights:
		if _descendant(bone, root):
			total += weights[bone]
	return total


func _foot_bounds(ankle: int, surfaces: Array[Dictionary]) -> AABB:
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	for surface in surfaces:
		var points: PackedVector3Array = surface.points
		if points.is_empty():
			continue
		var stride: int = surface.bones.size() / points.size()
		for vertex in points.size():
			var weight := 0.0
			for component in stride:
				var slot := vertex * stride + component
				if _descendant(surface.bones[slot], ankle):
					weight += surface.weights[slot]
			if weight >= 0.5:
				minimum = minimum.min(points[vertex])
				maximum = maximum.max(points[vertex])
	if not minimum.is_finite():
		minimum = neutral[ankle].origin + Vector3(-0.04, -0.08, -0.05)
		maximum = neutral[ankle].origin + Vector3(0.04, 0.02, 0.15)
	# shortcut: a sole rectangle is conservative; use authored contact points for irregular footwear.
	return AABB(minimum, maximum - minimum)


func _find(names: Array) -> int:
	for name: String in names:
		if _names.has(_normalize(name)):
			return _names[_normalize(name)]
	return -1


static func _normalize(value: String) -> String:
	return value.to_lower().replace("mixamorig:", "").replace("_", "").replace(".", "").replace(" ", "")
