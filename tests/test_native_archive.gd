extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(15.0).timeout.connect(func(): quit(1))
	assert(GDExtensionManager.load_extension("res://native/mocap.gdextension") in [GDExtensionManager.LOAD_STATUS_OK, GDExtensionManager.LOAD_STATUS_ALREADY_LOADED])
	var archive = ClassDB.instantiate("NativeModelArchive")
	assert(archive != null)
	var args := OS.get_cmdline_user_args()
	assert(args.size() == 2, "Pass -- <fixture.zip> <cache-directory>")
	assert(archive.start_extract(args[0], args[1]))
	while archive.is_running():
		await process_frame
	assert(archive.get_error().is_empty(), archive.get_error())
	var path: String = archive.get_result_path()
	assert(FileAccess.file_exists(path))
	var index = JSON.parse_string(FileAccess.get_file_as_string(path))
	assert(index is Dictionary and index.models.size() == 1)
	assert(str(index.models[0].path).ends_with("角色.pmx"))
	archive.cancel()
	assert(not archive.is_running())
	assert(archive.start_extract(args[0] + ".missing", args[1]))
	while archive.is_running():
		await process_frame
	assert(not archive.get_error().is_empty() and archive.get_result_path().is_empty())
	archive = null
	print("NATIVE_ARCHIVE_PASS: Unicode paths, async extraction, result index, cancellation and failure state")
	quit(0)
