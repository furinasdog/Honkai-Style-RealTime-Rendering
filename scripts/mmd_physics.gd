class_name MMDPhysics
extends SkeletonModifier3D

class HybridBody extends RigidBody3D:
	var animated_bone_origin := Vector3.ZERO
	var body_to_bone := Transform3D.IDENTITY

	func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
		var target := state.transform
		# PMX mode 2 preserves the animated bone position while physics rotates its offset collider.
		target.origin = animated_bone_origin - target.basis * body_to_bone.origin
		state.transform = target


const MAX_BODIES := 2048
const MAX_JOINTS := 4096
const BODY_BONES := ["全ての親", "センター", "グルーブ", "腰", "下半身", "上半身", "上半身2", "首", "頭", "両目", "左目", "右目"]

var bodies: Array[PhysicsBody3D] = []
var joints: Array[Generic6DOFJoint3D] = []
var counts := {"bodies": 0, "dynamic": 0, "joints": 0, "bone_bindings": 0}
var warnings: Array[String] = []
var assisted_pairs: Array[Vector2i] = []
var _prevent_body_clipping := true
var _joint_pairs: Dictionary = {}
var _rig: Skeleton3D
var _model: Node3D
var _world_root: Node3D
var _entries: Array[Dictionary] = []
var _dynamic: Array[Dictionary] = []
var _dynamic_bones: Dictionary = {}
var _hair_bones: Dictionary = {}
var _base_local: Dictionary = {}
var _reset_requested := false
var _ready_for_simulation := false
var _saved_callback: int = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE
var _angular_spring_scale: float = 1.0
var _last_model_transform := Transform3D.IDENTITY


func apply(rig: Skeleton3D, model_root: Node3D, data: Dictionary) -> bool:
	warnings.clear()
	if _rig != null or rig == null or model_root == null or not rig.is_inside_tree():
		warnings.append("物理绑定需要已加载的骨架，且不能重复绑定。")
		return false
	if not _valid(data):
		warnings.append("PMX 物理数据不完整或超出规模限制。")
		return false
	_rig = rig
	_model = model_root
	_last_model_transform = model_root.global_transform
	_collect_hair_bones()
	_angular_spring_scale = pow(float(data.get("unit_scale", 1.0)), 2.0)
	_saved_callback = rig.modifier_callback_mode_process
	for bone_index in rig.get_bone_count():
		_base_local[bone_index] = rig.get_bone_pose(bone_index)
	name = "MMDRigidPhysics"
	rig.add_child(self)
	_world_root = Node3D.new()
	_world_root.name = "MMDRigidBodies"
	_world_root.top_level = true
	model_root.add_child(_world_root)
	rig.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE
	var written_bones := {}
	var free_chained := {}
	# Jointed children already follow their dynamic parent; pinning mode 2 again overconstrains that chain.
	for source: Dictionary in data.joints:
		var a := int(source.body_a)
		var b := int(source.body_b)
		if a < 0 or b < 0 or a >= data.rigid_bodies.size() or b >= data.rigid_bodies.size():
			continue
		for pair in [Vector2i(a, b), Vector2i(b, a)]:
			var parent: Dictionary = data.rigid_bodies[pair.x]
			var child: Dictionary = data.rigid_bodies[pair.y]
			if int(parent.type) == 0 or int(child.type) != 2:
				continue
			var parent_bone := rig.find_bone(str(parent.get("bone", "")))
			var child_bone := rig.find_bone(str(child.get("bone", "")))
			if parent_bone < 0 or child_bone < 0 or rig.get_bone_parent(child_bone) != parent_bone:
				continue
			var parent_name := rig.get_bone_name(parent_bone)
			var child_name := rig.get_bone_name(child_bone)
			if _protected_bone(parent_name) or _protected_bone(child_name) or _torso_name(parent_name) or _torso_name(child_name):
				continue
			free_chained[pair.y] = true
	counts["normalized_mode2_children"] = free_chained.size()
	for index in data.rigid_bodies.size():
		var source: Dictionary = data.rigid_bodies[index]
		var bone := rig.find_bone(str(source.get("bone", "")))
		var mode := 1 if free_chained.has(index) else int(source.type)
		if bone >= 0 and _protected_bone(rig.get_bone_name(bone)):
			mode = 0
		var body: PhysicsBody3D
		if mode == 0:
			var follower := AnimatableBody3D.new()
			follower.sync_to_physics = false
			body = follower
		else:
			var rigid: RigidBody3D = HybridBody.new() if mode == 2 and bone >= 0 else RigidBody3D.new()
			rigid.mass = maxf(0.001, float(source.get("mass", 1.0)))
			rigid.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
			rigid.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
			rigid.linear_damp = _damping(float(source.get("linear_damping", 0.5)))
			rigid.angular_damp = _damping(float(source.get("angular_damping", 0.5)))
			rigid.continuous_cd = true
			rigid.can_sleep = false
			body = rigid
			counts.dynamic += 1
		body.name = "Body_%04d" % index
		body.top_level = true
		body.collision_layer = 1 << clampi(int(source.get("collision_group", 0)), 0, 15)
		body.collision_mask = int(source.get("collision_mask", 65535)) & 65535
		var material := PhysicsMaterial.new()
		material.friction = clampf(float(source.get("friction", 0.5)), 0.0, 1.0)
		material.bounce = clampf(float(source.get("restitution", 0.0)), 0.0, 1.0)
		body.physics_material_override = material
		var collision := CollisionShape3D.new()
		collision.shape = _shape(str(source.shape), _vector(source.size))
		body.add_child(collision)
		var rest_world := model_root.global_transform * _transform(source)
		var offset := Transform3D.IDENTITY
		if bone >= 0:
			var bone_rest_world := rig.global_transform * rig.get_bone_global_rest(bone)
			offset = bone_rest_world.affine_inverse() * rest_world
		var entry := {"body": body, "bone": bone, "mode": mode, "offset": offset, "rest_world": rest_world, "source": source}
		_entries.append(entry)
		# Jolt captures body frames when joints are created; tree entry must see the final initial transform.
		body.transform = _follow_target(entry)
		if body is HybridBody:
			body.body_to_bone = offset.affine_inverse()
			body.animated_bone_origin = (rig.global_transform * _animated_pose(bone, {})).origin
		_world_root.add_child(body)
		body.reset_physics_interpolation()
		bodies.append(body)
		if mode != 0 and bone >= 0 and not written_bones.has(bone):
			written_bones[bone] = true
			_dynamic_bones[bone] = entry
			_dynamic.append(entry)
	_dynamic.sort_custom(func(a: Dictionary, b: Dictionary): return _depth(a.bone) < _depth(b.bone))
	for source: Dictionary in data.joints:
		var a := int(source.body_a)
		var b := int(source.body_b)
		if a < 0 or b < 0 or a >= bodies.size() or b >= bodies.size() or a == b:
			continue
		if _entries[a].mode == 0 and _entries[b].mode == 0:
			continue
		var joint := Generic6DOFJoint3D.new()
		joint.name = "Joint_%04d" % joints.size()
		joint.top_level = true
		joint.exclude_nodes_from_collision = true
		_world_root.add_child(joint)
		var authored := model_root.global_transform * _transform(source)
		var anchor_motion: Transform3D = bodies[a].global_transform * _entries[a].rest_world.affine_inverse()
		joint.global_transform = anchor_motion * authored
		joint.node_a = joint.get_path_to(bodies[a])
		joint.node_b = joint.get_path_to(bodies[b])
		_configure_joint(joint, source, _entries[a], _entries[b])
		joints.append(joint)
		_joint_pairs[Vector2i(mini(a, b), maxi(a, b))] = true
	_configure_collisions()
	counts.bodies = bodies.size()
	counts.joints = joints.size()
	counts.bone_bindings = _dynamic.size()
	if _dynamic.is_empty():
		warnings.append("模型没有绑定到可驱动物理骨的动态刚体。")
	_ready_for_simulation = true
	return true


func set_body_collision_assistance(enabled: bool) -> void:
	_prevent_body_clipping = enabled
	if _ready_for_simulation:
		_configure_collisions()


func _configure_collisions() -> void:
	assisted_pairs.clear()
	var hair_tips: Dictionary = {}
	var torso: Dictionary = {}
	for index in _entries.size():
		var entry: Dictionary = _entries[index]
		entry.body.collision_mask = int(entry.source.get("collision_mask", 65535)) & 65535
		if _is_hair(entry) and entry.mode != 0 and entry.bone >= 0:
			var parent := _rig.get_bone_parent(entry.bone)
			if parent >= 0 and (_hair_bones.has(parent) or _hair_name(_rig.get_bone_name(parent))):
				hair_tips[index] = true
		if entry.mode == 0 and _torso_name(str(entry.source.get("bone", ""))):
			torso[index] = true
	if _prevent_body_clipping:
		for hair_index: int in hair_tips:
			for torso_index: int in torso:
				var pair := Vector2i(mini(hair_index, torso_index), maxi(hair_index, torso_index))
				if _head_neck_name(str(_entries[torso_index].source.get("bone", ""))) and _rest_overlap(_entries[hair_index], _entries[torso_index]):
					continue
				if not _joint_pairs.has(pair):
					assisted_pairs.append(pair)
					bodies[hair_index].collision_mask |= bodies[torso_index].collision_layer
					bodies[torso_index].collision_mask |= bodies[hair_index].collision_layer
	var assisted: Dictionary = {}
	for pair in assisted_pairs:
		assisted[pair] = true
	# Auxiliary mask bits also match unrelated bodies in the same layer; restore exact pair permissions.
	for a_index in bodies.size():
		var exceptions := bodies[a_index].get_collision_exceptions()
		for b_index in range(a_index + 1, bodies.size()):
			var pair := Vector2i(a_index, b_index)
			var a_allows: bool = (int(_entries[a_index].source.get("collision_mask", 65535)) & bodies[b_index].collision_layer) != 0
			var b_allows: bool = (int(_entries[b_index].source.get("collision_mask", 65535)) & bodies[a_index].collision_layer) != 0
			var allowed: bool = (a_allows and b_allows or assisted.has(pair)) and not _joint_pairs.has(pair)
			var native_contact := (bodies[a_index].collision_mask & bodies[b_index].collision_layer) != 0 or (bodies[b_index].collision_mask & bodies[a_index].collision_layer) != 0
			var needs_exception: bool = _joint_pairs.has(pair) or native_contact and not allowed
			if not needs_exception and bodies[b_index] in exceptions:
				bodies[a_index].remove_collision_exception_with(bodies[b_index])
			elif needs_exception and bodies[b_index] not in exceptions:
				bodies[a_index].add_collision_exception_with(bodies[b_index])
	counts["assisted_body_collision_pairs"] = assisted_pairs.size()
	counts["recognized_hair_bodies"] = hair_tips.size()


func _hair_name(value: String) -> bool:
	var lower := value.to_lower()
	return "hair" in lower or "髪" in lower or "发" in lower or "髮" in lower


func _is_hair(entry: Dictionary) -> bool:
	return _hair_bones.has(entry.bone) or _hair_name(str(entry.source.get("bone", ""))) or _hair_name(str(entry.source.get("name", "")))


func _collect_hair_bones() -> void:
	# Mesh weights also identify hair chains whose bone names contain no hair keyword.
	for instance: MeshInstance3D in _model.find_children("*", "MeshInstance3D", true, false):
		if instance.mesh == null or instance.skin == null or instance.get_node_or_null(instance.skeleton) != _rig:
			continue
		var bind_bones := []
		for bind in instance.skin.get_bind_count():
			var bone := instance.skin.get_bind_bone(bind)
			bind_bones.append(bone if bone >= 0 else _rig.find_bone(instance.skin.get_bind_name(bind)))
		for surface in instance.mesh.get_surface_count():
			var material := instance.get_active_material(surface)
			if material == null or not (_hair_name(material.resource_name) or material is ShaderMaterial and material.get_shader_parameter("category") == 2):
				continue
			var arrays := instance.mesh.surface_get_arrays(surface)
			if arrays[Mesh.ARRAY_BONES] == null or arrays[Mesh.ARRAY_WEIGHTS] == null:
				continue
			var joints: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
			for index in mini(joints.size(), weights.size()):
				if weights[index] >= 0.2 and joints[index] >= 0 and joints[index] < bind_bones.size():
					var bone: int = bind_bones[joints[index]]
					if bone >= 0 and not _protected_bone(_rig.get_bone_name(bone)):
						_hair_bones[bone] = true


func _torso_name(value: String) -> bool:
	var lower := value.to_lower()
	for part in ["上半身", "下半身", "胸", "肩", "躯干", "上臂", "spine", "chest", "torso", "shoulder", "upperarm", "upper_arm", "upperbody", "upper_body"]:
		if part in lower:
			return true
	return value in ["左腕", "右腕"] or _head_neck_name(value)


func _head_neck_name(value: String) -> bool:
	return value in ["頭", "首"] or value.to_lower() in ["head", "neck", "j_bip_c_head", "j_bip_c_neck"]


func _rest_overlap(a: Dictionary, b: Dictionary) -> bool:
	var endpoints: Array[Vector3] = []
	var radius := 0.0
	for entry in [a, b]:
		var size := _vector(entry.source.size)
		var half_length := size.y * 0.5 if str(entry.source.shape) == "capsule" else 0.0
		radius += size.length() if str(entry.source.shape) == "box" else size.x
		endpoints.append(entry.rest_world * Vector3(0, -half_length, 0))
		endpoints.append(entry.rest_world * Vector3(0, half_length, 0))
	var closest := Geometry3D.get_closest_points_between_segments(endpoints[0], endpoints[1], endpoints[2], endpoints[3])
	# Authored overlap at the hair roots must not become a new contact fighting a locked joint.
	return closest[0].distance_to(closest[1]) < radius - 0.0002


func _physics_process(_delta: float) -> void:
	if not _ready_for_simulation:
		return
	_move_with_model()
	if _reset_requested:
		reset()
	var animated: Dictionary = {}
	var physical: Dictionary = {}
	for entry in _entries:
		if entry.mode == 0:
			entry.body.global_transform = _animated_target(entry, animated)
		elif entry.body is HybridBody:
			entry.body.animated_bone_origin = (_rig.global_transform * _physical_pose(entry.bone, physical)).origin


func _move_with_model() -> void:
	var current := _model.global_transform
	if current.is_equal_approx(_last_model_transform):
		return
	# Bodies live in world space; moving the avatar must not leave its cloth behind.
	var motion := current * _last_model_transform.affine_inverse()
	for body in bodies:
		_teleport_body(body, motion * body.global_transform)
		if body is RigidBody3D:
			body.linear_velocity = motion.basis * body.linear_velocity
			body.angular_velocity = motion.basis.orthonormalized() * body.angular_velocity
	_last_model_transform = current


func _teleport_body(body: PhysicsBody3D, target: Transform3D) -> void:
	var rid := body.get_rid()
	var mode := PhysicsServer3D.body_get_mode(rid)
	# A kinematic target jump otherwise becomes an enormous one-tick collision velocity.
	if mode == PhysicsServer3D.BODY_MODE_KINEMATIC:
		PhysicsServer3D.body_set_mode(rid, PhysicsServer3D.BODY_MODE_STATIC)
	body.global_transform = target
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM, target)
	if mode == PhysicsServer3D.BODY_MODE_KINEMATIC:
		PhysicsServer3D.body_set_mode(rid, mode)
	body.reset_physics_interpolation()


func _process_modification_with_delta(_delta: float) -> void:
	if not _ready_for_simulation or _reset_requested:
		return
	var inverse := _rig.global_transform.affine_inverse()
	var animated: Dictionary = {}
	for entry in _dynamic:
		var body: RigidBody3D = entry.body
		var body_world := body.get_global_transform_interpolated()
		if not body_world.origin.is_finite() or body_world.origin.distance_to(_animated_target(entry, animated).origin) > 2.0:
			_reset_requested = true
			return
		var target: Transform3D = inverse * body_world * entry.offset.affine_inverse()
		if entry.mode == 2:
			target.origin = _rig.get_bone_global_pose(entry.bone).origin
		_rig.set_bone_global_pose(entry.bone, target)


func reset() -> void:
	if _rig == null:
		return
	_reset_requested = false
	var animated: Dictionary = {}
	for entry in _entries:
		var body: PhysicsBody3D = entry.body
		_teleport_body(body, _animated_target(entry, animated))
		if body is HybridBody:
			body.animated_bone_origin = (_rig.global_transform * _animated_pose(entry.bone, animated)).origin
		if body is RigidBody3D:
			body.linear_velocity = Vector3.ZERO
			body.angular_velocity = Vector3.ZERO


func dispose() -> void:
	_ready_for_simulation = false
	active = false
	set_physics_process(false)
	for body in bodies:
		if is_instance_valid(body):
			body.collision_layer = 0
			body.collision_mask = 0
	if is_instance_valid(_rig):
		_rig.modifier_callback_mode_process = _saved_callback
	if is_instance_valid(_world_root):
		_world_root.queue_free()
	queue_free()


func _exit_tree() -> void:
	_ready_for_simulation = false
	if is_instance_valid(_world_root):
		_world_root.queue_free()


func _follow_target(entry: Dictionary) -> Transform3D:
	return _animated_target(entry, {})


func _animated_target(entry: Dictionary, cache: Dictionary) -> Transform3D:
	if entry.bone < 0:
		return _model.global_transform * _transform(entry.source)
	return _rig.global_transform * _animated_pose(entry.bone, cache) * entry.offset


func _animated_pose(index: int, cache: Dictionary) -> Transform3D:
	if cache.has(index):
		return cache[index]
	var local: Transform3D = _base_local[index] if _dynamic_bones.has(index) else _rig.get_bone_pose(index)
	var parent := _rig.get_bone_parent(index)
	var result: Transform3D = _animated_pose(parent, cache) * local if parent >= 0 else local
	cache[index] = result
	return result


func _physical_pose(index: int, cache: Dictionary) -> Transform3D:
	if cache.has(index):
		return cache[index]
	var local: Transform3D = _base_local[index] if _dynamic_bones.has(index) else _rig.get_bone_pose(index)
	var parent := _rig.get_bone_parent(index)
	var result: Transform3D = _physical_pose(parent, cache) * local if parent >= 0 else local
	if _dynamic_bones.has(index):
		var entry: Dictionary = _dynamic_bones[index]
		var simulated: Transform3D = _rig.global_transform.affine_inverse() * entry.body.global_transform * entry.offset.affine_inverse()
		result.basis = simulated.basis
		if entry.mode == 1:
			result.origin = simulated.origin
	# Mode 2 follows the physically rotated parent chain, not the undeformed animation chain.
	cache[index] = result
	return result


func _configure_joint(joint: Generic6DOFJoint3D, source: Dictionary, a: Dictionary, b: Dictionary) -> void:
	var parameters := [joint.set_param_x, joint.set_param_y, joint.set_param_z]
	var flags := [joint.set_flag_x, joint.set_flag_y, joint.set_flag_z]
	var linear_lower := _vector(source.linear_lower)
	var linear_upper := _vector(source.linear_upper)
	var angular_lower := _vector(source.angular_lower)
	var angular_upper := _vector(source.angular_upper)
	var linear_spring := _vector(source.get("spring_linear", [0, 0, 0]))
	var angular_spring := _vector(source.get("spring_angular", [0, 0, 0]))
	var mass_a := float(a.source.get("mass", 1.0)) if a.mode != 0 else 100000.0
	var mass_b := float(b.source.get("mass", 1.0)) if b.mode != 0 else 100000.0
	var mass := maxf(0.001, 1.0 / (1.0 / maxf(mass_a, 0.001) + 1.0 / maxf(mass_b, 0.001)))
	var size_a := _vector(a.source.size).length()
	var size_b := _vector(b.source.size).length()
	var inertia := maxf(0.00000001, mass * pow(minf(size_a, size_b), 2.0) / 6.0)
	for axis in 3:
		var parameter: Callable = parameters[axis]
		var flag: Callable = flags[axis]
		flag.call(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT, true)
		flag.call(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
		parameter.call(Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT, linear_lower[axis])
		parameter.call(Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT, linear_upper[axis])
		parameter.call(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, angular_lower[axis])
		parameter.call(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, angular_upper[axis])
		var stiffness := maxf(0.0, linear_spring[axis])
		flag.call(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_SPRING, stiffness > 0.0)
		parameter.call(Generic6DOFJoint3D.PARAM_LINEAR_SPRING_STIFFNESS, stiffness)
		parameter.call(Generic6DOFJoint3D.PARAM_LINEAR_SPRING_DAMPING, 1.6 * sqrt(stiffness * mass))
		stiffness = maxf(0.0, angular_spring[axis]) * _angular_spring_scale
		flag.call(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_SPRING, stiffness > 0.0)
		parameter.call(Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_STIFFNESS, stiffness)
		parameter.call(Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_DAMPING, 1.6 * sqrt(stiffness * inertia))


func _shape(kind: String, size: Vector3) -> Shape3D:
	if kind == "sphere":
		var sphere := SphereShape3D.new()
		sphere.radius = maxf(0.001, size.x)
		return sphere
	if kind == "box":
		var box := BoxShape3D.new()
		box.size = Vector3(maxf(0.001, size.x * 2.0), maxf(0.001, size.y * 2.0), maxf(0.001, size.z * 2.0))
		return box
	var capsule := CapsuleShape3D.new()
	capsule.radius = maxf(0.001, size.x)
	capsule.height = maxf(capsule.radius * 2.0, size.y + capsule.radius * 2.0)
	return capsule


func _protected_bone(bone_name: String) -> bool:
	if bone_name in BODY_BONES:
		return true
	for side in ["左", "右"]:
		for part in ["肩", "腕", "ひじ", "手首", "足", "足D", "ひざ", "ひざD", "足首", "足首D"]:
			if bone_name == side + part:
				return true
	return false


func _depth(index: int) -> int:
	var depth := 0
	while index >= 0:
		depth += 1
		index = _rig.get_bone_parent(index)
	return depth


func _damping(fraction: float) -> float:
	if fraction >= 1.0:
		return float(Engine.physics_ticks_per_second) * 2.0
	return -log(maxf(0.0001, 1.0 - clampf(fraction, 0.0, 1.0)))


func _transform(data: Dictionary) -> Transform3D:
	var q: Array = data.rotation
	return Transform3D(Basis(Quaternion(q[0], q[1], q[2], q[3]).normalized()), _vector(data.position))


func _vector(value: Array) -> Vector3:
	return Vector3(value[0], value[1], value[2])


func _valid(data: Dictionary) -> bool:
	if not _number_finite(data.get("unit_scale", 1.0)) or float(data.get("unit_scale", 1.0)) <= 0.0:
		return false
	if not data.get("rigid_bodies") is Array or not data.get("joints") is Array:
		return false
	if data.rigid_bodies.is_empty() or data.rigid_bodies.size() > MAX_BODIES or data.joints.size() > MAX_JOINTS:
		return false
	for body in data.rigid_bodies:
		if not body is Dictionary or body.get("shape") not in ["sphere", "box", "capsule"] or not _number_finite(body.get("type")):
			return false
		if int(body.type) not in [0, 1, 2]:
			return false
		if not _array_finite(body.get("size"), 3) or not _array_finite(body.get("position"), 3) or not _array_finite(body.get("rotation"), 4):
			return false
		var dimensions := _vector(body.size)
		if dimensions.x < 0.0 or dimensions.y < 0.0 or dimensions.z < 0.0 or _quaternion_length(body.rotation) < 0.000001:
			return false
		for key in ["mass", "linear_damping", "angular_damping", "friction", "restitution", "collision_group", "collision_mask"]:
			if body.has(key) and not _number_finite(body[key]):
				return false
	for joint in data.joints:
		if not joint is Dictionary or not _number_finite(joint.get("body_a")) or not _number_finite(joint.get("body_b")) or not _array_finite(joint.get("position"), 3) or not _array_finite(joint.get("rotation"), 4):
			return false
		if not _number_finite(joint.get("type", 0)) or int(joint.get("type", 0)) != 0:
			return false
		if _quaternion_length(joint.rotation) < 0.000001:
			return false
		for key in ["linear_lower", "linear_upper", "angular_lower", "angular_upper", "spring_linear", "spring_angular"]:
			if key in ["spring_linear", "spring_angular"] and not joint.has(key):
				continue
			if not _array_finite(joint.get(key), 3):
				return false
	return true


func _number_finite(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


func _quaternion_length(value: Array) -> float:
	return Vector4(value[0], value[1], value[2], value[3]).length_squared()


func _array_finite(value: Variant, count: int) -> bool:
	if not value is Array or value.size() != count:
		return false
	for number in value:
		if not (number is int or number is float) or not is_finite(float(number)):
			return false
	return true
