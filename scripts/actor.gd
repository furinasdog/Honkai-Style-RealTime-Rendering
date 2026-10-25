extends Node3D

var visual: Node3D
var skeleton: Skeleton3D
var model_root: Node3D
var import_error := ""


func _ready() -> void:
	visual = $Visual


func stage_external(path: String) -> Node3D:
	import_error = ""
	if path.get_extension().to_lower() == "pmx":
		var loader := HonkaiPMXLoader.new()
		var result := loader.load_file(path)
		if result.is_empty():
			import_error = loader.error
			return null
		result.root.set_meta("pmx_metadata", result.metadata)
		return stage_prepared(result.root)
	var state := GLTFState.new()
	var document := GLTFDocument.new()
	if document.append_from_file(path, state) != OK:
		return null
	var candidate := document.generate_scene(state) as Node3D
	if candidate == null:
		return null
	return stage_prepared(candidate)


func stage_prepared(candidate: Node3D) -> Node3D:
	visual.add_child(candidate)
	candidate.visible = false
	_prepare_pose(candidate, false)
	if find_rig(candidate) == null:
		candidate.free()
		return null
	return candidate


func clear_model() -> void:
	if is_instance_valid(model_root):
		model_root.queue_free()
	model_root = null
	skeleton = null


func commit_model(candidate: Node3D) -> void:
	var previous := model_root
	model_root = candidate
	skeleton = find_rig(candidate)
	candidate.visible = true
	if is_instance_valid(previous) and previous != candidate:
		previous.queue_free()


static func find_rig(root: Node3D) -> Skeleton3D:
	if root is Skeleton3D:
		return root as Skeleton3D
	var rigs := root.find_children("*", "Skeleton3D", true, false)
	return rigs[0] as Skeleton3D if not rigs.is_empty() else null


func _prepare_pose(root: Node3D, use_idle: bool) -> void:
	for node in root.find_children("*", "AnimationPlayer", true, false):
		var animation := node as AnimationPlayer
		if use_idle:
			for clip in animation.get_animation_list():
				if String(clip).get_file().get_slice("|", String(clip).get_slice_count("|") - 1).to_lower() == "idle":
					animation.play(clip)
					animation.seek(0.0, true)
					animation.advance(0.0)
					break
		animation.pause()
		animation.active = false
	if use_idle:
		return
	var rig := find_rig(root)
	if rig == null:
		return
	for side in ["左", "右"]:
		var arm := rig.find_bone(side + "腕")
		var elbow := rig.find_bone(side + "ひじ")
		if arm < 0 or elbow < 0:
			continue
		var pose := rig.get_bone_global_pose(arm)
		var direction := rig.get_bone_global_pose(elbow).origin - pose.origin
		if direction.length_squared() < 0.000001:
			continue
		var relaxed := Vector3(0.42 if side == "左" else -0.42, -0.907, 0.04).normalized()
		var target := Basis(Quaternion(direction.normalized(), relaxed)) * pose.basis.orthonormalized()
		var parent := rig.get_bone_parent(arm)
		var parent_basis := rig.get_bone_global_pose(parent).basis.orthonormalized() if parent >= 0 else Basis.IDENTITY
		rig.set_bone_pose_rotation(arm, (parent_basis.inverse() * target).get_rotation_quaternion())
