extends SceneTree

var importer
var evidence: String
var worker_script: String


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.size() != 3:
		print("BLENDER_IMPORTER_SKIP requires ZIP, PMX path and output directory")
		quit(0)
		return
	evidence = arguments[2]
	create_timer(90.0).timeout.connect(func(): push_error("Blender import timed out"); quit(1))
	var command: Dictionary = load("res://scripts/runtime_paths.gd").importer_command()
	assert(not command.executable.is_empty(), "Bundled Blender must be available")
	assert(command.executable.get_file().to_lower() == "blender.exe")
	assert(command.args_prefix.has("--python-exit-code") and command.args_prefix.has("--disable-autoexec"))
	worker_script = str(command.args_prefix[command.args_prefix.find("--python") + 1])
	assert(worker_script.ends_with("import_pmx_blender.py"), "Only the bpy worker may execute inside Blender")
	importer = load("res://scripts/model_importer.gd").new()
	importer._cache = evidence.path_join("cache")
	root.add_child(importer)
	importer.message.connect(func(text: String):
		print(text)
		if not importer.busy:
			push_error(text if not text.is_empty() else "Importer failed without an error message")
			quit(1))
	importer.archive_ready.connect(func(models: Array):
		assert(not models.is_empty())
		importer.convert_selected(arguments[1], true))
	importer.model_ready.connect(_model_ready)
	importer.inspect_archive(arguments[0])


func _model_ready(glb: String, metadata: Dictionary, metadata_path: String) -> void:
	assert(FileAccess.file_exists(glb) and not metadata.get("bones", []).is_empty())
	assert(ClassDB.class_exists("NativeModelArchive"), "ZIP extraction must use the C++ backend")
	var result := {"ok": true, "model": glb, "metadata": metadata_path, "additional_uv_channels": metadata.get("additional_uv_channels", 0), "bone_count": metadata.bones.size(), "rigid_bodies": metadata.get("physics", {}).get("rigid_bodies", []).size(), "joints": metadata.get("physics", {}).get("joints", []).size(), "archive_backend": "native_7z", "worker_script": worker_script, "standalone_python_helper": false}
	var report := FileAccess.open(evidence.path_join("result.json"), FileAccess.WRITE)
	report.store_string(JSON.stringify(result, "  "))
	report.close()
	print("NATIVE_ARCHIVE_BLENDER_PASS ", JSON.stringify(result))
	importer.queue_free()
	await process_frame
	quit(0)
