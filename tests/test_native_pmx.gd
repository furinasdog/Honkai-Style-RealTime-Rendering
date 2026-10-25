extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(90.0).timeout.connect(func(): quit(1))
	var args := OS.get_cmdline_user_args()
	assert(args.size() == 2)
	var loader := HonkaiPMXLoader.new()
	var result := loader.load_file(args[0])
	assert(not result.is_empty(), loader.error)
	root.add_child(result.root)
	var mesh: ArrayMesh = result.root.get_node("MMDMesh").mesh
	var triangles := 0
	for surface in mesh.get_surface_count():
		triangles += mesh.surface_get_array_index_len(surface) / 3
	assert(triangles == int(result.metadata.triangle_count))
	assert(HonkaiMMDMaterials.classify_material("颜") == "face")
	assert(HonkaiMMDMaterials.classify_material("顏") == "face")
	assert(HonkaiMMDMaterials.classify_material("肌衣2") == "cloth")
	assert(HonkaiMMDMaterials.classify_material("髪") == "hair")
	result.metadata["model_file"] = args[0]
	var file := FileAccess.open(args[1], FileAccess.WRITE)
	file.store_string(JSON.stringify(result.metadata, "  "))
	file.close()
	print("NATIVE_PMX_PASS ", triangles, " triangles, ", mesh.get_surface_count(), " materials")
	result.root.free()
	quit(0)
