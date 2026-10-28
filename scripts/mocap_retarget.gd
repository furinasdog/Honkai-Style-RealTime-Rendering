class_name MocapRetarget
extends RefCounted

const SIDES := {"Left": "左", "Right": "右"}
const FINGERS := [["親指０", "親指１", "親指２"], ["人指１", "人指２", "人指３"], ["中指１", "中指２", "中指３"], ["薬指１", "薬指２", "薬指３"], ["小指１", "小指２", "小指３"]]
const MORPHS := ["まばたき", "ウィンク", "ウィンク右", "あ", "い", "う", "口角上げ", "口角下げ", "上", "怒り", "困る"]
const TRACKING_TIMEOUT := 0.4
const LIMB_HOLD_SECONDS := 0.15
const INVALID_FRAME := Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
const CENTER_ALIASES := {
	"上半身": ["spine", "Spine", "mixamorig:Spine", "J_Bip_C_Spine"],
	"上半身2": ["chest", "upper_chest", "Spine1", "mixamorig:Spine1", "J_Bip_C_Chest"],
	"首": ["neck", "mixamorig:Neck", "J_Bip_C_Neck"],
	"頭": ["head", "mixamorig:Head", "J_Bip_C_Head"]}
const PART_ALIASES := {
	"肩": ["Shoulder", "shoulder", "clavicle"],
	"腕": ["Arm", "UpperArm", "upper_arm"],
	"ひじ": ["ForeArm", "LowerArm", "lower_arm", "elbow"],
	"手首": ["Hand", "hand", "wrist"]}
const MORPH_ALIASES := {
	"まばたき": ["blink", "eyeBlink", "Fcl_EYE_Close"],
	"ウィンク": ["eyeBlinkLeft", "blinkLeft", "Blink_L", "Fcl_EYE_Close_L"],
	"ウィンク右": ["eyeBlinkRight", "blinkRight", "Blink_R", "Fcl_EYE_Close_R"],
	"あ": ["jawOpen", "A", "Fcl_MTH_A"], "い": ["mouthWide", "I", "Fcl_MTH_I"],
	"う": ["mouthPucker", "U", "Fcl_MTH_U"],
	"口角上げ": ["mouthSmile", "smile", "Fcl_MTH_Joy"],
	"口角下げ": ["mouthFrown", "frown", "Fcl_MTH_Sorrow"],
	"上": ["browInnerUp", "browUp", "Fcl_BRW_Surprised"],
	"怒り": ["browDown", "Fcl_BRW_Angry"], "困る": ["browSad", "Fcl_BRW_Sorrow"]}

var smoothing_speed: float = 14.0
var mode := "vtuber"
var hand_gesture_assistance := false
var age_seconds: float = INF
var tracking := {"pose": false, "face": false, "hands": 0, "left_hand": false, "right_hand": false, "lower_body": false, "left_leg": false, "right_leg": false}
var skeleton: Skeleton3D
var settings: RefCounted
var warnings: Array[String] = []
var capabilities: Dictionary = {}
var _indices := {}
var _neutral_local := {}
var _neutral_global := {}
var _targets := {}
var _global_targets := {}
var _resolved_bases := {}
var _morph_bindings: Array[Dictionary] = []
var _morph_targets := {}
var _last_sequence: int = -1
var _last_timestamp_ms: float = -1.0
var _frame_delta: float = 1.0 / 30.0
var _bone_channels := {}
var _joint_axes := {}
var _fullbody: RefCounted
var _body_delta := Basis.IDENTITY
var _gesture_assist: RefCounted = preload("res://scripts/hand_gesture_assistance.gd").new()
var _live_finger_bases := {}
var _gesture_filter_bones := {}
var _held_limb_targets := {}


func set_hand_gesture_assistance(enabled: bool) -> void:
	if hand_gesture_assistance == enabled:
		return
	var affected := _gesture_filter_bones.keys()
	hand_gesture_assistance = enabled
	_gesture_assist.reset()
	for index: int in _held_limb_targets.keys():
		if _bone_channels.get(index, "").ends_with("_hand"):
			if not _global_targets.has(index):
				_targets[index] = _neutral_local[index]
			_held_limb_targets.erase(index)
	if not enabled:
		_clear_gesture_curve_filters()
	if not enabled and not affected.is_empty() and skeleton != null and age_seconds <= TRACKING_TIMEOUT:
		_global_targets.merge(_live_finger_bases, true)
		_resolved_bases.clear()
		for index: int in affected:
			if not _live_finger_bases.has(index):
				continue
			var parent := _target_basis(skeleton.get_bone_parent(index))
			var rotation: Quaternion = (parent.inverse() * _live_finger_bases[index]).orthonormalized().get_rotation_quaternion()
			_targets[index] = _map_joint_rotation(index, rotation, _bone_channels[index])


func _clear_gesture_curve_filters(channel: String = "") -> void:
	for index: int in _gesture_filter_bones.keys():
		var bone_channel: String = _gesture_filter_bones[index]
		if channel.is_empty() or channel == bone_channel:
			if settings != null:
				settings.reset_filters(bone_channel, str(index))
			_gesture_filter_bones.erase(index)


func set_mode(value: String) -> bool:
	if value not in ["vtuber", "full_body"]:
		return false
	if mode != value:
		mode = value
		reset()
	return true


func recenter() -> void:
	reset()


func apply(rig: Skeleton3D, model_root: Node3D) -> bool:
	_fullbody = null
	_indices.clear()
	_neutral_local.clear()
	_neutral_global.clear()
	_targets.clear()
	_live_finger_bases.clear()
	_morph_bindings.clear()
	_morph_targets.clear()
	_bone_channels.clear()
	_joint_axes.clear()
	warnings.clear()
	capabilities.clear()
	skeleton = null
	if rig == null or model_root == null or not rig.is_inside_tree():
		warnings.append("角色没有可用骨骼。")
		return false
	skeleton = rig
	for index in rig.get_bone_count():
		_neutral_local[index] = rig.get_bone_pose_rotation(index)
		_neutral_global[index] = rig.get_bone_global_pose(index)
	var names: Array[String] = ["上半身", "上半身2", "首", "頭"]
	for side: String in SIDES.values():
		for part in ["肩", "腕", "ひじ", "手首"]:
			names.append(side + part)
		for finger in FINGERS:
			for part: String in finger:
				names.append(side + part)
	var bone_names := {}
	for index in rig.get_bone_count():
		bone_names[_normalized(rig.get_bone_name(index))] = index
	for name: String in names:
		var index := _resolve_bone(name, bone_names)
		if index >= 0:
			_indices[name] = index
	_fullbody = preload("res://scripts/fullbody_retarget.gd").new()
	_fullbody.setup(rig, model_root, _neutral_global, _neutral_local)
	capabilities.left_leg = _fullbody.has_side("left")
	capabilities.right_leg = _fullbody.has_side("right")
	capabilities.lower_body = capabilities.left_leg or capabilities.right_leg
	warnings.append_array(_fullbody.warnings)
	for side: String in SIDES:
		var prefix: String = SIDES[side]
		var side_id := "left" if side == "Left" else "right"
		capabilities[side_id + "_arm"] = _has_chain(prefix)
		capabilities[side_id + "_hand"] = _indices.has(prefix + "手首") and _indices.has(prefix + "中指１") and _indices.has(prefix + "人指１") and _indices.has(prefix + "小指１")
		if not _has_chain(prefix):
			warnings.append("未找到完整的" + prefix + "臂骨链，已跳过该侧手臂。")
		if _indices.has(prefix + "手首") and not capabilities[side_id + "_hand"]:
			warnings.append(prefix + "手缺少掌面参考骨，已跳过手指追踪。")
		for part: String in ["腕", "ひじ"]:
			if _indices.has(prefix + part):
				_bone_channels[_indices[prefix + part]] = side_id + "_arm"
		for part: String in ["手首"]:
			if _indices.has(prefix + part):
				_bone_channels[_indices[prefix + part]] = side_id + "_hand"
		for finger in FINGERS:
			for part: String in finger:
				if _indices.has(prefix + part):
					_bone_channels[_indices[prefix + part]] = side_id + "_hand"
	for node in model_root.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if mesh.mesh == null:
			continue
		for index in mesh.mesh.get_blend_shape_count():
			var shape_name := _canonical_morph(String(mesh.mesh.get_blend_shape_name(index)))
			if not shape_name.is_empty():
				_morph_bindings.append({"mesh": mesh, "index": index, "name": shape_name, "neutral": mesh.get_blend_shape_value(index)})
	capabilities.head = _indices.has("頭")
	capabilities.face = not _morph_bindings.is_empty()
	capabilities.channels = {"head_x": capabilities.head, "head_y": capabilities.head, "head_z": capabilities.head,
		"left_eye": _has_morph("ウィンク") or _has_morph("まばたき"), "right_eye": _has_morph("ウィンク右") or _has_morph("まばたき"),
		"jaw_open": _has_morph("あ"), "mouth_wide": _has_morph("い"), "mouth_pucker": _has_morph("う"),
		"smile": _has_morph("口角上げ"), "frown": _has_morph("口角下げ"), "brow_up": _has_morph("上") or _has_morph("困る"), "brow_down": _has_morph("怒り"),
		"left_arm": capabilities.left_arm, "right_arm": capabilities.right_arm, "left_hand": capabilities.left_hand, "right_hand": capabilities.right_hand}
	if _morph_bindings.is_empty():
		warnings.append("模型没有已支持的表情形态键，面部表情已跳过。")
	elif _has_morph("まばたき") and (not _has_morph("ウィンク") or not _has_morph("ウィンク右")):
		warnings.append("模型缺少单眼闭合形态键，将使用双眼同步眨眼。")
	if not capabilities.head and not capabilities.left_arm and not capabilities.right_arm:
		warnings.append("至少需要头部或一侧完整的上臂、前臂、手腕骨链。")
		skeleton = null
		return false
	reset()
	return true


func ingest(frame: Dictionary) -> bool:
	if skeleton == null or not _valid_frame(frame):
		return false
	var sequence := int(frame.seq)
	var timestamp_ms := float(frame.timestamp_ms)
	if timestamp_ms < _last_timestamp_ms or (timestamp_ms == _last_timestamp_ms and sequence <= _last_sequence):
		return false
	_frame_delta = clampf((timestamp_ms - _last_timestamp_ms) / 1000.0, 0.001, 0.2) if _last_timestamp_ms >= 0 else 1.0 / 30.0
	_last_sequence = sequence
	_last_timestamp_ms = timestamp_ms
	age_seconds = 0.0
	_set_neutral_targets()
	tracking = {"pose": false, "face": false, "hands": 0, "left_hand": false, "right_hand": false}
	var pose = frame.get("pose")
	_body_delta = Basis.IDENTITY
	if mode == "full_body":
		_fullbody.ingest(pose.world if pose is Dictionary else [], pose.image if pose is Dictionary else [])
		tracking.merge(_fullbody.tracking(), true)
		tracking.pose = tracking.lower_body
	else:
		tracking.merge({"lower_body": false, "left_leg": false, "right_leg": false})
	if pose is Dictionary:
		_apply_pose(pose.world, pose.image)
	if mode == "full_body":
		_global_targets.merge(_fullbody.global_targets, true)
	var used_sides := {}
	for hand: Dictionary in frame.get("hands", []):
		if not _image_visible(hand.image, range(21)):
			continue
		var side := _hand_side(hand, pose)
		var side_id := "left" if side == "Left" else "right"
		if pose is Dictionary and not _image_visible(pose.image, [11, 13, 15] if side == "Left" else [12, 14, 16]):
			continue
		if used_sides.has(side) or not capabilities.get(side_id + "_hand", false) or not _channel_enabled(side_id + "_hand"):
			continue
		if not _apply_hand(SIDES[side], hand.world, hand.image):
			continue
		used_sides[side] = true
		tracking.hands += 1
		tracking.left_hand = tracking.left_hand or side == "Left"
		tracking.right_hand = tracking.right_hand or side == "Right"
	if hand_gesture_assistance:
		for side: String in SIDES:
			if not used_sides.has(side):
				_gesture_assist.reset_side(SIDES[side])
				_clear_gesture_curve_filters("left_hand" if side == "Left" else "right_hand")
	var face = frame.get("face")
	if face is Dictionary:
		_apply_face(face)
		tracking.face = true
	# Resolve held parents before converting world-space wrist and finger targets.
	_hold_missing_limbs()
	_resolved_bases.clear()
	for index: int in _global_targets:
		var parent := skeleton.get_bone_parent(index)
		var parent_basis := _target_basis(parent)
		_targets[index] = (parent_basis.inverse() * _global_targets[index]).orthonormalized().get_rotation_quaternion()
	for index: int in _bone_channels:
		if _global_targets.has(index):
			_targets[index] = _map_joint_rotation(index, _targets[index], _bone_channels[index])
			_held_limb_targets[index] = {"rotation": _targets[index], "age": 0.0}
	_hold_missing_limbs()
	if mode == "full_body":
		_fullbody.capture_targets(_targets)
		_targets.merge(_fullbody.fallback_targets(), true)
	return true


func update(delta: float) -> void:
	if skeleton == null or not is_finite(delta) or delta < 0.0:
		return
	age_seconds += delta
	for state: Dictionary in _held_limb_targets.values():
		state.age += delta
	if mode == "full_body":
		_fullbody.advance(delta)
		tracking.merge(_fullbody.tracking(), true)
	if age_seconds > TRACKING_TIMEOUT:
		_set_neutral_targets()
		_gesture_assist.reset()
		_clear_gesture_curve_filters()
		tracking = {"pose": false, "face": false, "hands": 0, "left_hand": false, "right_hand": false}
		tracking.merge({"lower_body": false, "left_leg": false, "right_leg": false})
	if mode == "full_body":
		_targets.merge(_fullbody.fallback_targets(), true)
	_hold_missing_limbs()
	var weight := 1.0 - exp(-clampf(smoothing_speed, 1.0, 40.0) * minf(delta, 0.1))
	for index: int in _targets:
		var current := skeleton.get_bone_pose_rotation(index)
		skeleton.set_bone_pose_rotation(index, current.slerp(_targets[index], weight).normalized())
	if _fullbody != null and _fullbody.root_index >= 0:
		var root_index: int = _fullbody.root_index
		var target: Vector3 = _fullbody.root_position
		skeleton.set_bone_pose_position(root_index, skeleton.get_bone_pose_position(root_index).lerp(target, weight))
	for binding in _morph_bindings:
		var mesh: MeshInstance3D = binding.mesh
		var value := lerpf(mesh.get_blend_shape_value(binding.index), _morph_targets[binding.name], weight)
		mesh.set_blend_shape_value(binding.index, clampf(value, 0.0, 1.0))


func reset() -> void:
	age_seconds = INF
	_last_sequence = -1
	_last_timestamp_ms = -1.0
	_joint_axes.clear()
	_held_limb_targets.clear()
	_gesture_assist.reset()
	_gesture_filter_bones.clear()
	_body_delta = Basis.IDENTITY
	if _fullbody != null:
		_fullbody.reset()
	if settings != null:
		settings.reset_filters()
	tracking = {"pose": false, "face": false, "hands": 0, "left_hand": false, "right_hand": false}
	tracking.merge({"lower_body": false, "left_leg": false, "right_leg": false})
	_set_neutral_targets()
	if skeleton == null:
		return
	for index: int in _targets:
		skeleton.set_bone_pose_rotation(index, _targets[index])
	if _fullbody != null and _fullbody.root_index >= 0:
		skeleton.set_bone_pose_position(_fullbody.root_index, _fullbody.root_position)
	for binding in _morph_bindings:
		binding.mesh.set_blend_shape_value(binding.index, binding.neutral)


func _hold_missing_limbs() -> void:
	for index: int in _held_limb_targets.keys():
		if not _channel_enabled(_bone_channels[index]):
			_targets[index] = _neutral_local[index]
			_held_limb_targets.erase(index)
		elif not _global_targets.has(index):
			var state: Dictionary = _held_limb_targets[index]
			# Brief occlusion must not restart a return-to-rest on every missing packet.
			_targets[index] = state.rotation if state.age <= LIMB_HOLD_SECONDS else _neutral_local[index]
			if state.age > LIMB_HOLD_SECONDS:
				_held_limb_targets.erase(index)


func _set_neutral_targets() -> void:
	_global_targets.clear()
	_live_finger_bases.clear()
	_resolved_bases.clear()
	for index: int in _indices.values():
		_targets[index] = _neutral_local[index]
	if _fullbody != null:
		for index: int in _fullbody.indices():
			_targets[index] = _neutral_local[index]
	for binding in _morph_bindings:
		_morph_targets[binding.name] = binding.neutral


func _apply_pose(points: Array, image: Array) -> void:
	var body_delta := Basis.IDENTITY
	if _visible(points, [11, 12]) and _image_visible(image, [11, 12]):
		var across := _point(points[11]) - _point(points[12])
		var up := Vector3.UP
		if _visible(points, [23, 24]) and _image_visible(image, [23, 24]):
			up = (_point(points[11]) + _point(points[12]) - _point(points[23]) - _point(points[24])) * 0.5
		var body := _frame(across, up)
		if body != INVALID_FRAME:
			if mode == "full_body":
				body *= _fullbody.body_reference.inverse()
			var rotation := body.get_rotation_quaternion()
			if mode == "vtuber":
				var angles := body.get_euler()
				angles = Vector3(clampf(angles.x, -0.35, 0.35), clampf(angles.y, -0.65, 0.65), clampf(angles.z, -0.3, 0.3))
				rotation = Basis.from_euler(angles).get_rotation_quaternion()
			body_delta = Basis(rotation)
			_body_delta = body_delta
			var base: Quaternion = _fullbody.pelvis_delta.get_rotation_quaternion() if mode == "full_body" else Quaternion.IDENTITY
			_set_delta("上半身", base.slerp(rotation, 0.35))
			_set_delta("上半身2", rotation)
	for side: String in SIDES:
		var joint := [11, 13, 15] if side == "Left" else [12, 14, 16]
		var prefix: String = SIDES[side]
		if not _visible(points, joint) or not _image_visible(image, joint) or not _has_chain(prefix) or not _channel_enabled("left_arm" if side == "Left" else "right_arm"):
			continue
		var upper := _point(points[joint[1]]) - _point(points[joint[0]])
		var lower := _point(points[joint[2]]) - _point(points[joint[1]])
		var arm_delta := _arm_delta(prefix, upper, lower, body_delta)
		_aim(prefix + "腕", prefix + "ひじ", upper, arm_delta)
		_aim(prefix + "ひじ", prefix + "手首", lower, arm_delta)
		tracking.pose = true


func _arm_delta(side: String, upper: Vector3, lower: Vector3, body_delta: Basis) -> Basis:
	var shoulder: Vector3 = _neutral_global[_indices[side + "腕"]].origin
	var elbow: Vector3 = _neutral_global[_indices[side + "ひじ"]].origin
	var wrist: Vector3 = _neutral_global[_indices[side + "手首"]].origin
	var neutral_upper := (elbow - shoulder).normalized()
	var neutral_lower := (wrist - elbow).normalized()
	if neutral_upper.is_zero_approx() or upper.is_zero_approx() or lower.is_zero_approx():
		return body_delta
	var swing := Basis(Quaternion(body_delta * neutral_upper, upper.normalized())) * body_delta
	# Near-straight elbows have no reliable bend plane; retain the torso-carried swing.
	var reliability := upper.normalized().cross(lower.normalized()).length()
	var weight := clampf((reliability - 0.05) / 0.15, 0.0, 1.0)
	if weight <= 0.0:
		return swing
	var reference := neutral_lower
	if neutral_upper.cross(neutral_lower).length() < 0.05:
		# shortcut: straight rest arms assume forward flexion; use an authored hinge axis when available.
		reference = Vector3.BACK
		if _indices.has("左腕") and _indices.has("右腕"):
			var across: Vector3 = _neutral_global[_indices["左腕"]].origin - _neutral_global[_indices["右腕"]].origin
			var torso_frame := _frame(across, Vector3.UP)
			if torso_frame != INVALID_FRAME:
				reference = torso_frame.z
		if absf(neutral_upper.dot(reference)) > 0.95:
			reference = Vector3.UP
	var neutral_frame := _frame(reference, neutral_upper)
	var measured_frame := _frame(lower, upper)
	if neutral_frame == INVALID_FRAME or measured_frame == INVALID_FRAME:
		return swing
	var plane_delta := measured_frame * neutral_frame.inverse()
	return Basis(swing.get_rotation_quaternion().slerp(plane_delta.get_rotation_quaternion(), weight))


func _apply_hand(side: String, points: Array, image: Array) -> bool:
	var wrist: int = _indices[side + "手首"]
	var middle: int = _indices[side + "中指１"]
	var index: int = _indices[side + "人指１"]
	var little: int = _indices[side + "小指１"]
	var neutral_frame := _frame(_neutral_global[index].origin - _neutral_global[little].origin, _neutral_global[middle].origin - _neutral_global[wrist].origin)
	var measured_frame := _frame(_point(points[5]) - _point(points[17]), _point(points[9]) - _point(points[0]))
	if neutral_frame == INVALID_FRAME or measured_frame == INVALID_FRAME:
		return false
	var hand_delta := measured_frame * neutral_frame.inverse()
	_global_targets[wrist] = hand_delta * _neutral_global[wrist].basis.orthonormalized()
	var assistance := {"gesture": "", "weight": 0.0}
	if hand_gesture_assistance:
		assistance = _gesture_assist.sample(side, points, image, _frame_delta)
	var palm_normal := neutral_frame.z * (1.0 if side == "左" else -1.0)
	var thumb: int = _indices.get(side + FINGERS[0][0], -1)
	var toward_palm: Vector3 = _neutral_global[middle].origin - _neutral_global[thumb].origin if thumb >= 0 else neutral_frame.y
	for finger in 5:
		var start := 1 if finger == 0 else finger * 4 + 1
		var complete: bool = assistance.weight > 0.0 and FINGERS[finger].all(func(part: String): return _indices.has(side + part))
		for segment in 3:
			var name: String = side + FINGERS[finger][segment]
			if not _indices.has(name):
				continue
			var next_name: String = side + FINGERS[finger][segment + 1] if segment < 2 else ""
			if not next_name.is_empty() and not _indices.has(next_name):
				next_name = ""
			_aim(name, next_name, _point(points[start + segment + 1]) - _point(points[start + segment]), hand_delta)
			var bone: int = _indices[name]
			if not _global_targets.has(bone):
				continue
			_live_finger_bases[bone] = _global_targets[bone]
			if complete:
				_gesture_filter_bones[bone] = _bone_channels[bone]
				var base: int = _indices[side + FINGERS[finger][0]]
				var next: int = _indices[side + FINGERS[finger][1]]
				var rotation: Basis = _gesture_assist.preset_rotation(assistance.gesture, finger, segment, _neutral_direction(base, next), palm_normal, toward_palm)
				var preset: Basis = hand_delta * rotation * _neutral_global[bone].basis.orthonormalized()
				_global_targets[bone] = Basis(_global_targets[bone].get_rotation_quaternion().slerp(preset.get_rotation_quaternion(), assistance.weight))
	return true


func _apply_face(face: Dictionary) -> void:
	var values: Dictionary = face.blendshapes
	var baseline: float = _morph_targets.get("まばたき", 0.0)
	var left_blink := _mapped("left_eye", _score(values, "eyeBlinkLeft"))
	var right_blink := _mapped("right_eye", _score(values, "eyeBlinkRight"))
	if _has_morph("まばたき") and (not _has_morph("ウィンク") or not _has_morph("ウィンク右")):
		_morph_targets["まばたき"] = baseline + (left_blink + right_blink) * 0.5 * (1.0 - baseline)
	else:
		_morph_targets["ウィンク"] = left_blink * (1.0 - baseline)
		_morph_targets["ウィンク右"] = right_blink * (1.0 - baseline)
	_morph_targets["あ"] = _mapped("jaw_open", _score(values, "jawOpen")) * 0.9
	_morph_targets["い"] = _mapped("mouth_wide", maxf(_score(values, "mouthStretchLeft"), _score(values, "mouthStretchRight"))) * 0.5
	_morph_targets["う"] = _mapped("mouth_pucker", maxf(_score(values, "mouthPucker"), _score(values, "mouthFunnel"))) * 0.8
	_morph_targets["口角上げ"] = _mapped("smile", (_score(values, "mouthSmileLeft") + _score(values, "mouthSmileRight")) * 0.5) * 0.8
	_morph_targets["口角下げ"] = _mapped("frown", (_score(values, "mouthFrownLeft") + _score(values, "mouthFrownRight")) * 0.5) * 0.7
	var brow_up := _mapped("brow_up", maxf(_score(values, "browInnerUp"), maxf(_score(values, "browOuterUpLeft"), _score(values, "browOuterUpRight"))))
	_morph_targets["上"] = brow_up * 0.7
	_morph_targets["怒り"] = _mapped("brow_down", (_score(values, "browDownLeft") + _score(values, "browDownRight")) * 0.5) * 0.6
	_morph_targets["困る"] = brow_up * 0.3
	var matrix: Array = face.matrix
	# Face transformation matrices already use an OpenGL right-handed, Y-up camera space.
	var basis := Basis(Vector3(matrix[0], matrix[4], matrix[8]), Vector3(matrix[1], matrix[5], matrix[9]), Vector3(matrix[2], matrix[6], matrix[10]))
	if basis.determinant() < 0.1:
		return
	basis = basis.orthonormalized()
	if mode == "full_body":
		basis = _body_delta.inverse() * basis
	var angles := basis.get_euler()
	angles = Vector3(_mapped("head_x", angles.x), _mapped("head_y", angles.y), _mapped("head_z", angles.z))
	angles = Vector3(clampf(angles.x, -0.65, 0.65), clampf(angles.y, -1.0, 1.0), clampf(angles.z, -0.55, 0.55))
	var head_rotation := Basis.from_euler(angles).get_rotation_quaternion()
	var neck_rotation := Quaternion.IDENTITY.slerp(head_rotation, 0.35)
	if mode == "full_body":
		neck_rotation = _body_delta.get_rotation_quaternion() * neck_rotation
		head_rotation = _body_delta.get_rotation_quaternion() * head_rotation
	_set_delta("首", neck_rotation)
	_set_delta("頭", head_rotation)


func _aim(name: String, child_name: String, measured: Vector3, reference_delta: Basis = Basis.IDENTITY) -> void:
	if measured.length_squared() < 0.00000001 or not _indices.has(name):
		return
	var index: int = _indices[name]
	var neutral: Transform3D = _neutral_global[index]
	var direction := _neutral_direction(index, int(_indices.get(child_name, -1)))
	if direction.length_squared() < 0.00000001:
		return
	direction = reference_delta * direction
	_global_targets[index] = Basis(Quaternion(direction.normalized(), measured.normalized())) * reference_delta * neutral.basis.orthonormalized()


func _neutral_direction(index: int, child: int = -1) -> Vector3:
	var neutral: Transform3D = _neutral_global[index]
	var direction: Vector3
	if child >= 0:
		direction = _neutral_global[child].origin - neutral.origin
	else:
		var tails = skeleton.get_meta("pmx_tail_offsets", PackedVector3Array())
		if tails is PackedVector3Array and index < tails.size() and tails[index].is_finite():
			direction = neutral.basis * skeleton.get_bone_global_rest(index).basis.inverse() * tails[index]
		if direction.length_squared() < 0.00000001:
			var parent := skeleton.get_bone_parent(index)
			# shortcut: absent authored tails use the previous segment; add a rig profile for curved terminal bones.
			direction = neutral.origin - _neutral_global[parent].origin if parent >= 0 else Vector3.ZERO
	return direction


func _set_delta(name: String, rotation: Quaternion) -> void:
	if not _indices.has(name):
		return
	var index: int = _indices[name]
	_global_targets[index] = Basis(rotation) * _neutral_global[index].basis.orthonormalized()


func _target_basis(index: int) -> Basis:
	if index < 0:
		return Basis.IDENTITY
	if _resolved_bases.has(index):
		return _resolved_bases[index]
	var result: Basis
	if _global_targets.has(index):
		result = _global_targets[index]
	else:
		result = _target_basis(skeleton.get_bone_parent(index)) * Basis(_targets.get(index, _neutral_local[index]))
	_resolved_bases[index] = result
	return result


func _hand_side(hand: Dictionary, pose: Variant) -> String:
	if pose is Dictionary and pose.has("image") and _image_visible(pose.image, [15, 16]):
		var wrist := Vector2(hand.image[0][0], hand.image[0][1])
		var left := Vector2(pose.image[15][0], pose.image[15][1])
		var right := Vector2(pose.image[16][0], pose.image[16][1])
		if absf(wrist.distance_squared_to(left) - wrist.distance_squared_to(right)) > 0.0001:
			return "Left" if wrist.distance_squared_to(left) < wrist.distance_squared_to(right) else "Right"
	return hand.side


func _visible(points: Array, indices: Array) -> bool:
	for index: int in indices:
		if float(points[index][3]) < 0.45:
			return false
	return true


func _image_visible(points: Array, indices: Array) -> bool:
	for index: int in indices:
		if not image_point_visible(points[index]):
			return false
	return true


static func image_point_visible(point: Array) -> bool:
	return point.size() >= 2 and float(point[0]) >= 0.0 and float(point[0]) <= 1.0 and float(point[1]) >= 0.0 and float(point[1]) <= 1.0 and (point.size() < 4 or float(point[3]) >= 0.45)


func _frame(across: Vector3, along: Vector3) -> Basis:
	if across.length_squared() < 0.000001 or along.length_squared() < 0.000001:
		return INVALID_FRAME
	var y := along.normalized()
	var x := across - y * across.dot(y)
	if x.length_squared() < 0.000001:
		return INVALID_FRAME
	x = x.normalized()
	return Basis(x, y, x.cross(y).normalized()).orthonormalized()


func _point(value: Array) -> Vector3:
	return Vector3(float(value[0]), -float(value[1]), -float(value[2]))


func _score(values: Dictionary, key: String) -> float:
	return clampf(float(values.get(key, 0.0)), 0.0, 1.0)


func _mapped(channel: String, value: float) -> float:
	return settings.map_value(channel, value, _frame_delta) if settings != null else value


func _channel_enabled(channel: String) -> bool:
	return bool(settings.get_channel(channel).get("enabled", true)) if settings != null else true


func _map_joint_rotation(index: int, rotation: Quaternion, channel: String) -> Quaternion:
	if settings == null:
		return rotation
	var neutral: Quaternion = _neutral_local[index]
	var delta := (neutral.inverse() * rotation).normalized()
	if delta.w < 0.0:
		delta = Quaternion(-delta.x, -delta.y, -delta.z, -delta.w)
	# acos(w) loses precision near identity and can produce a non-unit axis.
	var vector := Vector3(delta.x, delta.y, delta.z)
	var angle := 2.0 * atan2(vector.length(), delta.w)
	var axis: Vector3 = vector.normalized() if angle > 0.0000001 else _joint_axes.get(index, Vector3.RIGHT)
	if angle > 0.0000001:
		_joint_axes[index] = axis
	var mapped: float = settings.map_value(channel, angle / PI, _frame_delta, str(index))
	return (neutral * Quaternion(axis, clampf(mapped, -1.0, 1.0) * PI)).normalized()


func _has_chain(side: String) -> bool:
	return _indices.has(side + "腕") and _indices.has(side + "ひじ") and _indices.has(side + "手首")


func _has_morph(name: String) -> bool:
	for binding in _morph_bindings:
		if binding.name == name:
			return true
	return false


func _resolve_bone(name: String, available: Dictionary) -> int:
	var candidates: Array = [name]
	if CENTER_ALIASES.has(name):
		candidates.append_array(CENTER_ALIASES[name])
	else:
		var side := "Left" if name.begins_with("左") else "Right"
		var short_side := "L" if side == "Left" else "R"
		var part := name.substr(1)
		if part == "ひじ":
			candidates.append(name.substr(0, 1) + "肘")
		if PART_ALIASES.has(part):
			for alias: String in PART_ALIASES[part]:
				candidates.append_array([side + alias, "mixamorig:" + side + alias, alias + "_" + short_side, alias + "." + short_side, alias + "_" + short_side.to_lower(), "J_Bip_" + short_side + "_" + alias])
		for finger_index in FINGERS.size():
			var segment: int = FINGERS[finger_index].find(part)
			if segment < 0:
				continue
			var finger_name: String = ["Thumb", "Index", "Middle", "Ring", "Little"][finger_index]
			var alternate_name := "Pinky" if finger_index == 4 else finger_name
			for alias: String in [finger_name, alternate_name]:
				candidates.append_array([side + "Hand" + alias + str(segment + 1), "mixamorig:" + side + "Hand" + alias + str(segment + 1), alias + str(segment + 1) + "." + short_side, alias + "_" + str(segment + 1) + "_" + short_side])
			if finger_index == 1:
				candidates.append(name.replace("人指", "人差指"))
	for candidate: String in candidates:
		var normalized := _normalized(candidate)
		if available.has(normalized):
			return int(available[normalized])
	return -1


func _canonical_morph(name: String) -> String:
	var normalized := _normalized(name)
	for canonical: String in MORPHS:
		if normalized == _normalized(canonical):
			return canonical
		for alias: String in MORPH_ALIASES.get(canonical, []):
			if normalized == _normalized(alias):
				return canonical
	return ""


func _normalized(value: String) -> String:
	var result := value.to_lower().replace("mixamorig:", "")
	for token in [" ", "_", ".", ":", "-"]:
		result = result.replace(token, "")
	for index in 10:
		result = result.replace("０１２３４５６７８９".substr(index, 1), str(index))
	return result


func _valid_frame(frame: Dictionary) -> bool:
	if frame.get("version") != 1 or not _number(frame.get("seq")) or not _number(frame.get("timestamp_ms")) or float(frame.seq) < 0 or float(frame.timestamp_ms) < 0 or float(frame.seq) != floorf(float(frame.seq)):
		return false
	var pose = frame.get("pose")
	if pose != null and (not pose is Dictionary or not _landmarks(pose.get("world"), 33, 4) or not _landmarks(pose.get("image"), 33, 4)):
		return false
	var hands = frame.get("hands", [])
	if not hands is Array or hands.size() > 2:
		return false
	for hand in hands:
		if not hand is Dictionary or not SIDES.has(hand.get("side")) or not _landmarks(hand.get("world"), 21, 3) or not _landmarks(hand.get("image"), 21, 3):
			return false
	var face = frame.get("face")
	if face != null:
		if not face is Dictionary or not face.get("blendshapes") is Dictionary or not face.get("matrix") is Array or face.matrix.size() != 16:
			return false
		for value in face.matrix:
			if not _number(value) or absf(float(value)) > 10000.0:
				return false
		for key in face.blendshapes:
			if not key is String or not _number(face.blendshapes[key]):
				return false
	return true


func _landmarks(value: Variant, count: int, width: int) -> bool:
	if not value is Array or value.size() != count:
		return false
	for point in value:
		if not point is Array or point.size() != width:
			return false
		for coordinate in point:
			if not _number(coordinate) or absf(float(coordinate)) > 100.0:
				return false
	return true


func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))
