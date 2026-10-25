extends SceneTree

var importer
var evidence: String


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	assert(args.size() == 3)
	evidence = args[2]
	create_timer(90.0).timeout.connect(func(): push_error("Native import timed out"); quit(1))
	importer = load("res://scripts/model_importer.gd").new()
	importer._cache = evidence.path_join("cache")
	root.add_child(importer)
	importer.message.connect(func(value: String):
		print(value)
		if not importer.busy:
			push_error(value)
			quit(1))
	importer.archive_ready.connect(func(_models: Array): importer.convert_selected(args[1]))
	importer.native_model_ready.connect(func(model: Node3D, metadata: Dictionary, path: String):
		assert(metadata.loader == "native_pmx_v1")
		assert(importer._pid == 0, "Native PMX import must not launch Blender or another helper")
		assert(FileAccess.file_exists(path) and FileAccess.file_exists(metadata.model_file))
		assert(model.get_node("MMDMesh").mesh.get_surface_count() > 0)
		var file := FileAccess.open(evidence.path_join("result.json"), FileAccess.WRITE)
		file.store_string(JSON.stringify({"metadata": path, "triangles": metadata.triangle_count, "bones": metadata.bones.size(), "bodies": metadata.physics.rigid_bodies.size(), "helper_process": false}, "  "))
		file.close()
		model.free()
		print("NATIVE_IMPORTER_PASS ", metadata.name)
		quit(0))
	importer.inspect_archive(args[0])
