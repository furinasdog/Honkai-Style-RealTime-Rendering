extends SceneTree

var _capture_pose := false
var _poses: Array[Transform3D] = []
var _rig: Skeleton3D
var _mesh: MeshInstance3D
var _surfaces: Array[Dictionary] = []
var _head_height := 1.4
var _setup


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(60.0).timeout.connect(func(): quit(1))
	assert(_geometry_self_check(), "Contact geometry must distinguish solid, hollow and disconnected surfaces")
	var args := OS.get_cmdline_user_args()
	assert(args.size() == 2)
	var metadata_path: String = args[0]
	var metadata: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(metadata_path))
	if metadata.has("metadata"):
		metadata_path = metadata.metadata
		metadata = JSON.parse_string(FileAccess.get_file_as_string(metadata_path))
	assert(DirAccess.make_dir_recursive_absolute(args[1]) == OK)
	var scene := Node3D.new()
	root.add_child(scene)
	var actor = load("res://scripts/actor.gd").new()
	var visual := Node3D.new()
	visual.name = "Visual"
	actor.add_child(visual)
	scene.add_child(actor)
	var model: Node3D = actor.stage_external(metadata.model_file)
	assert(model != null)
	actor.commit_model(model)
	var materials = load("res://scripts/march_materials.gd").new()
	materials.apply(model, metadata)
	_rig = actor.skeleton
	_mesh = model.get_node("MMDMesh")
	_setup = load("res://scripts/mmd_physics.gd").new()
	assert(_setup.apply(_rig, model, metadata.physics))
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.06, 0.07, 0.1)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.6
	scene.add_child(environment)
	var light := DirectionalLight3D.new()
	scene.add_child(light)
	light.rotation_degrees = Vector3(-35, -20, 0)
	var camera = load("res://scripts/blender_camera.gd").new()
	scene.add_child(camera)
	camera.make_current()
	var head := _rig.find_bone("頭")
	_head_height = _rig.get_bone_global_rest(head).origin.y
	for surface in _mesh.mesh.get_surface_count():
		var material: ShaderMaterial = _mesh.get_active_material(surface)
		var color: Color = material.get_shader_parameter("base_color")
		if color.a < 0.01:
			continue
		var category: int = material.get_shader_parameter("category")
		if category not in [1, 2, 3]:
			continue
		var arrays := _mesh.mesh.surface_get_arrays(surface)
		_surfaces.append({"surface": surface, "name": material.resource_name, "arrays": arrays, "hair": category == 2, "category": category, "components": _components(arrays) if category == 3 else PackedInt32Array()})
	_setup.modification_processed.connect(func():
		if _capture_pose:
			_poses.clear()
			for bone in _rig.get_bone_count():
				_poses.append(_rig.get_bone_global_pose(bone))
			_capture_pose = false)
	camera.focus = Vector3(0, _head_height * 0.88, 0)
	camera.distance = 1.25
	camera._update_transform()
	root.size = Vector2i(800, 720)
	await create_timer(1.0).timeout
	var rest := _rig.get_bone_pose_rotation(head)
	var report := {"vertex_source": "gpu_bake_after_modifier", "max_penetration_m": 0.0, "inside_samples": 0, "samples": 0, "max_collider_skin_gap_m": 0.0, "snapshots": []}
	report["depth_measurement"] = "ray_parity_per_connected_cloth_component_or_skin"
	report["max_envelope_depth_m"] = 0.0
	report["crossing_faces"] = 0
	report["sample_stride_ticks"] = 10
	report["physics_ticks_per_second"] = Engine.physics_ticks_per_second
	report["camera_opened"] = false
	report["physics"] = _setup.counts.duplicate()
	for step in 241:
		var phase := float(step) / 240.0 * TAU
		_rig.set_bone_pose_rotation(head, rest * Quaternion.from_euler(Vector3(sin(phase) * 0.45, sin(phase * 2) * 0.35, 0)))
		await physics_frame
		if step % 10 != 0:
			continue
		_capture_pose = true
		await RenderingServer.frame_post_draw
		assert(not _capture_pose and not _poses.is_empty(), "Must inspect this frame's post-modifier skin pose")
		# The engine reads the rendered skin buffers back from the GPU; do not duplicate skinning in this test.
		var baked := _mesh.bake_mesh_from_current_skeleton_pose()
		assert(baked != null and baked.get_surface_count() == _mesh.mesh.get_surface_count())
		var sample := _penetration(baked)
		sample["step"] = step
		report.max_penetration_m = maxf(report.max_penetration_m, sample.max_penetration_m)
		report.max_envelope_depth_m = maxf(report.max_envelope_depth_m, sample.max_envelope_depth_m)
		report.max_collider_skin_gap_m = maxf(report.max_collider_skin_gap_m, sample.max_collider_skin_gap_m)
		report.inside_samples += sample.inside_samples
		report.samples += sample.samples
		report.crossing_faces += sample.crossing_hair_faces.size()
		report.snapshots.append(sample)
		if step % 30 == 0 or not sample.crossing_hair_faces.is_empty():
			root.get_texture().get_image().save_png(args[1].path_join("step_%d.png" % step))
	assert(report.samples > 0, "The real-model probe must include rendered chest-level hair vertices")
	var file := FileAccess.open(args[1].path_join("mesh_contact.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("HAIR_MESH_CONTACT ", JSON.stringify(report))
	scene.queue_free()
	await process_frame
	if int(report.crossing_faces) > 0 or float(report.max_penetration_m) > 0.015:
		push_error("GPU hair intersects the torso: %d crossing faces, %.2f mm inside solid components" % [report.crossing_faces, report.max_penetration_m * 1000.0])
		quit(1)
	else:
		quit(0)


func _penetration(baked: ArrayMesh) -> Dictionary:
	var faces := PackedVector3Array()
	var hair := PackedVector3Array()
	var face_sources: Array[Dictionary] = []
	var hair_sources: Array[Dictionary] = []
	var hair_edges: Array[Dictionary] = []
	var volume_faces := {}
	for surface: Dictionary in _surfaces:
		var arrays: Array = surface.arrays
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var rendered: PackedVector3Array = baked.surface_get_arrays(surface.surface)[Mesh.ARRAY_VERTEX]
		assert(rendered.size() == vertices.size())
		if surface.hair:
			for index in range(0, vertices.size(), 3):
				if vertices[index].z > 0 and absf(vertices[index].x) < 0.2:
					var point := _mesh.global_transform * rendered[index]
					if point.y > _head_height * 0.65 and point.y < _head_height * 0.95:
						hair.append(point)
						hair_sources.append({"surface": surface.surface, "material": surface.name, "vertex": index, "weights": _vertex_weights(arrays, index)})
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			for triangle in range(0, indices.size(), 3):
				var center: Vector3 = (vertices[indices[triangle]] + vertices[indices[triangle + 1]] + vertices[indices[triangle + 2]]) / 3.0
				if center.z <= 0 or absf(center.x) > 0.2:
					continue
				for slot in 3:
					var a := _mesh.global_transform * rendered[indices[triangle + slot]]
					var b := _mesh.global_transform * rendered[indices[triangle + (slot + 1) % 3]]
					if maxf(a.y, b.y) < _head_height * 0.65 or minf(a.y, b.y) > _head_height * 0.95:
						continue
					hair_edges.append({"a": a, "b": b, "material": surface.name, "surface": surface.surface, "triangle": triangle / 3, "weights": _vertex_weights(arrays, indices[triangle])})
		else:
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			for triangle in range(0, indices.size(), 3):
				var center: Vector3 = (vertices[indices[triangle]] + vertices[indices[triangle + 1]] + vertices[indices[triangle + 2]]) / 3.0
				if absf(center.x) > 0.21 or center.y < _head_height * 0.6 or center.y > _head_height * 0.99:
					continue
				for slot in 3:
					faces.append(_mesh.global_transform * rendered[indices[triangle + slot]])
				var volume := "skin" if surface.category == 1 else "%s:%s" % [surface.surface, surface.components[triangle / 3]]
				if not volume_faces.has(volume):
					volume_faces[volume] = PackedVector3Array()
				for slot in 3:
					volume_faces[volume].append(_mesh.global_transform * rendered[indices[triangle + slot]])
				face_sources.append({"surface": surface.surface, "material": surface.name, "triangle": triangle / 3, "weights": _vertex_weights(arrays, indices[triangle])})
	var tree := TriangleMesh.new()
	assert(tree.create_from_faces(faces))
	var volumes: Array[TriangleMesh] = []
	for volume in volume_faces:
		var component := TriangleMesh.new()
		if component.create_from_faces(volume_faces[volume]):
			volumes.append(component)
	var result := {"max_penetration_m": 0.0, "inside_samples": 0, "samples": hair.size(), "worst_point": Vector3.ZERO, "max_collider_skin_gap_m": 0.0}
	result["max_envelope_depth_m"] = 0.0
	result["envelope_inside_samples"] = 0
	result["crossing_hair_faces"] = {}
	for edge: Dictionary in hair_edges:
		var a: Vector3 = edge.a
		var b: Vector3 = edge.b
		var direction := (b - a).normalized()
		var hit := tree.intersect_segment(a + direction * 0.00001, b - direction * 0.00001)
		if hit.is_empty() or hit.position.y < _head_height * 0.65 or hit.position.y > _head_height * 0.95:
			continue
		var key := "%s:%s" % [edge.surface, edge.triangle]
		if not result.crossing_hair_faces.has(key):
			result.crossing_hair_faces[key] = {"hair_material": edge.material, "hair_weights": edge.weights, "position": hit.position, "torso_face": face_sources[int(hit.face_index)]}
	for entry: Dictionary in _setup._dynamic:
		if _setup._is_hair(entry):
			var collider_pose: Transform3D = entry.body.get_global_transform_interpolated() * entry.offset.affine_inverse()
			var skin_pose := _rig.global_transform * _poses[entry.bone]
			result.max_collider_skin_gap_m = maxf(result.max_collider_skin_gap_m, skin_pose.origin.distance_to(collider_pose.origin))
	for index in hair.size():
		var point := hair[index]
		var solid_depth := 0.0
		for volume in volumes:
			solid_depth = maxf(solid_depth, _solid_depth(volume, point))
		if solid_depth > 0.005:
			result.inside_samples += 1
		if solid_depth > result.max_penetration_m:
			result.max_penetration_m = solid_depth
			result["solid_worst_point"] = point
		var front := tree.intersect_ray(Vector3(point.x, point.y, 1), Vector3.FORWARD)
		var back := tree.intersect_ray(Vector3(point.x, point.y, -1), Vector3.BACK)
		if front.is_empty() or back.is_empty():
			continue
		var depth := minf(float(front.position.z) - point.z, point.z - float(back.position.z))
		if depth > 0.005:
			result.envelope_inside_samples += 1
		if depth > result.max_envelope_depth_m:
			result.max_envelope_depth_m = depth
			result.worst_point = point
			result["worst_hair_source"] = hair_sources[index]
			result["front_source"] = face_sources[int(front.face_index)]
			result["back_source"] = face_sources[int(back.face_index)]
			result["front_position"] = front.position
			result["back_position"] = back.position
			result["layers"] = _ray_layers(tree, Vector3(point.x, point.y, 1), face_sources)
	return result


func _components(arrays: Array) -> PackedInt32Array:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var parents := PackedInt32Array()
	parents.resize(vertices.size())
	var welded := {}
	for vertex in vertices.size():
		var point := vertices[vertex]
		var key := Vector3i(roundi(point.x * 100000), roundi(point.y * 100000), roundi(point.z * 100000))
		parents[vertex] = int(welded.get(key, vertex))
		welded[key] = parents[vertex]
	for triangle in range(0, indices.size(), 3):
		for edge in 2:
			var a := _component_root(parents, indices[triangle + edge])
			var b := _component_root(parents, indices[triangle + edge + 1])
			parents[maxi(a, b)] = mini(a, b)
	var result := PackedInt32Array()
	for triangle in range(0, indices.size(), 3):
		result.append(_component_root(parents, indices[triangle]))
	return result


func _component_root(parents: PackedInt32Array, index: int) -> int:
	while parents[index] != index:
		index = parents[index]
	return index


func _solid_depth(tree: TriangleMesh, point: Vector3) -> float:
	var intersections := PackedFloat32Array()
	var start := Vector3(point.x, point.y, 1)
	for layer in 64:
		var hit := tree.intersect_ray(start, Vector3.FORWARD)
		if hit.is_empty():
			break
		intersections.append(hit.position.z)
		start = hit.position + Vector3.FORWARD * 0.00001
	# Open or unmatched surfaces do not define a solid interior.
	if intersections.size() % 2 != 0:
		return 0.0
	var result := 0.0
	for layer in range(0, intersections.size(), 2):
		result = maxf(result, minf(intersections[layer] - point.z, point.z - intersections[layer + 1]))
	return result


func _geometry_self_check() -> bool:
	var outer := BoxMesh.new()
	outer.size = Vector3.ONE * 0.2
	var solid := TriangleMesh.new()
	if not solid.create_from_faces(outer.get_faces()) or absf(_solid_depth(solid, Vector3.ZERO) - 0.1) > 0.0001:
		return false
	if _solid_depth(solid, Vector3(0, 0, 0.2)) != 0.0 or solid.intersect_segment(Vector3(0, 0, 0.2), Vector3.ZERO).is_empty():
		return false
	var inner := BoxMesh.new()
	inner.size = Vector3.ONE * 0.16
	var shell_faces := outer.get_faces()
	shell_faces.append_array(inner.get_faces())
	var shell := TriangleMesh.new()
	if not shell.create_from_faces(shell_faces) or _solid_depth(shell, Vector3.ZERO) != 0.0:
		return false
	if absf(_solid_depth(shell, Vector3(0, 0, 0.09)) - 0.01) > 0.0001:
		return false
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-0.1, -0.1, 0.1), Vector3(0.1, -0.1, 0.1), Vector3(0.1, 0.1, 0.1), Vector3(-0.1, 0.1, 0.1), Vector3(-0.1, -0.1, -0.1), Vector3(0.1, -0.1, -0.1), Vector3(0.1, 0.1, -0.1), Vector3(-0.1, 0.1, -0.1)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7])
	var components := _components(arrays)
	if components[0] != components[1] or components[2] != components[3] or components[0] == components[2]:
		return false
	for first in [0, 6]:
		var faces := PackedVector3Array()
		for index in range(first, first + 6):
			faces.append(arrays[Mesh.ARRAY_VERTEX][arrays[Mesh.ARRAY_INDEX][index]])
		var open := TriangleMesh.new()
		if not open.create_from_faces(faces) or _solid_depth(open, Vector3.ZERO) != 0.0:
			return false
	return true


func _vertex_weights(arrays: Array, vertex: int) -> Dictionary:
	var result := {}
	for slot in 4:
		var offset := vertex * 4 + slot
		var weight: float = arrays[Mesh.ARRAY_WEIGHTS][offset]
		if weight <= 0.0:
			continue
		var bind: int = arrays[Mesh.ARRAY_BONES][offset]
		var bone := _mesh.skin.get_bind_bone(bind)
		if bone < 0:
			bone = _rig.find_bone(_mesh.skin.get_bind_name(bind))
		result[_rig.get_bone_name(bone)] = weight
	return result


func _ray_layers(tree: TriangleMesh, start: Vector3, sources: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for layer in 64:
		var hit := tree.intersect_ray(start, Vector3.FORWARD)
		if hit.is_empty():
			break
		var source: Dictionary = sources[int(hit.face_index)].duplicate()
		source["z"] = hit.position.z
		source["normal_z"] = hit.normal.z
		result.append(source)
		start = hit.position + Vector3.FORWARD * 0.00001
	return result
