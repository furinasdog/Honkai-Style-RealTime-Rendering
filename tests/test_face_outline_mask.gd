extends SceneTree


func _initialize() -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	var points := PackedVector3Array()
	var colors := PackedColorArray()
	for y in 21:
		for x in 21:
			var a := (x - 10) * 0.05
			var b := (y - 10) * 0.07
			points.append(Vector3(a, b, 0.1 * (1.0 - a * a - b * b)))
			colors.append(Color(1,1,1,0.37))
	var indices := PackedInt32Array()
	for y in 20:
		for x in 20:
			if x in [9,10] and y in [9,10]:
				continue
			var a := y * 21 + x
			indices.append_array([a,a+1,a+22,a,a+22,a+21])
	arrays[Mesh.ARRAY_VERTEX] = points
	arrays[Mesh.ARRAY_INDEX] = indices
	arrays[Mesh.ARRAY_COLOR] = colors
	HonkaiPMXLoader._mask_face_holes(arrays)
	var masked: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	assert(masked[9*21+9].r == 0.0 and masked[11*21+11].r == 0.0, "Mouth rim must not generate an inward inverted hull")
	assert(masked[0].r == 1.0 and masked[20*21+10].r == 1.0, "Face silhouette must retain its outline")
	assert(is_equal_approx(masked[0].a,0.37) and points == arrays[Mesh.ARRAY_VERTEX] and indices == arrays[Mesh.ARRAY_INDEX], "PMX edge weights, geometry and morph topology must remain unchanged")
	print("FACE_OUTLINE_MASK_PASS inner opening, outer silhouette, authored edge weights and geometry")
	quit()
