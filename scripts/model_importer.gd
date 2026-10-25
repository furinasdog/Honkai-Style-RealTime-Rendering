extends Node

signal archive_ready(models: Array)
signal model_ready(glb_path: String, metadata: Dictionary, metadata_path: String)
signal native_model_ready(root: Node3D, metadata: Dictionary, metadata_path: String)
signal message(text: String)

var busy := false
var archive_path := ""
var blender_path := ""
var _pid := 0
var _phase := ""
var _job_dir := ""
var _staging_dir := ""
var _selected_pmx := ""
var _started_ms := 0
var _cache := ProjectSettings.globalize_path("user://model_imports")
var _archive_worker: RefCounted
var _archive_index: Dictionary = {}


func inspect_archive(path: String) -> void:
	if busy:
		message.emit("请等待当前模型导入完成。")
		return
	if not FileAccess.file_exists(path):
		message.emit("找不到所选压缩包。")
		return
	if not ClassDB.class_exists("NativeModelArchive"):
		var status := GDExtensionManager.load_extension("res://native/mocap.gdextension")
		if status not in [GDExtensionManager.LOAD_STATUS_OK, GDExtensionManager.LOAD_STATUS_ALREADY_LOADED]:
			message.emit("无法加载原生模型导入组件，请检查完整发行文件。")
			return
	_archive_worker = ClassDB.instantiate("NativeModelArchive") as RefCounted
	if _archive_worker == null:
		message.emit("无法创建原生模型导入组件。")
		return
	archive_path = path
	_archive_index = {}
	if not bool(_archive_worker.start_extract(path, _cache.path_join("archives"))):
		message.emit(str(_archive_worker.get_error()))
		return
	_phase = "inspect"
	_started_ms = Time.get_ticks_msec()
	busy = true
	message.emit("正在检查并解压模型压缩包…")


func convert_selected(pmx_path: String, use_blender: bool = false) -> void:
	if busy or _archive_index.is_empty():
		return
	var listed := false
	for model: Dictionary in _archive_index.get("models", []):
		if str(model.get("path", "")) == pmx_path:
			listed = true
			break
	if not listed or pmx_path.is_absolute_path() or ".." in pmx_path.replace("\\", "/").split("/"):
		message.emit("所选 PMX 不在已验证的压缩包内。")
		return
	var cache_root := str(_archive_index.get("cache_root", ""))
	var source := cache_root.path_join(pmx_path)
	if not FileAccess.file_exists(source):
		message.emit("模型缓存已缺失，请重新导入压缩包。")
		return
	_selected_pmx = pmx_path
	_job_dir = _cache.path_join("models/%d_%d" % [int(Time.get_unix_time_from_system()), Time.get_ticks_usec()])
	_staging_dir = _job_dir + ".staging"
	DirAccess.make_dir_recursive_absolute(_staging_dir)
	if not use_blender:
		busy = true
		_phase = "native"
		message.emit("正在读取原始 PMX、贴图和物理数据…")
		_load_native.call_deferred(source)
		return
	var runtime := preload("res://scripts/runtime_paths.gd").importer_command(blender_path)
	if runtime.executable.is_empty():
		message.emit(runtime.error)
		return
	var command: PackedStringArray = runtime.args_prefix
	command.append_array(PackedStringArray(["--pmx", source, "--cache-root", cache_root, "--output-dir", _staging_dir, "--final-dir", _job_dir, "--mmd-tools-dir", runtime.mmd_tools_dir]))
	_pid = OS.create_process(runtime.executable, command, false)
	if _pid <= 0:
		_pid = 0
		message.emit("Blender 模型转换未能启动。")
		return
	_phase = "convert"
	_started_ms = Time.get_ticks_msec()
	busy = true
	message.emit("正在转换模型和贴图，请稍候…")


func _load_native(source: String) -> void:
	var loader := HonkaiPMXLoader.new()
	var result := loader.load_file(source, _archive_index)
	busy = false
	if result.is_empty():
		message.emit(loader.error + "\n当前角色已保留。")
		return
	result.metadata["model_file"] = source
	var file := FileAccess.open(_staging_dir.path_join("metadata.json"), FileAccess.WRITE)
	if file == null:
		result.root.free()
		message.emit("无法保存模型缓存，当前角色已保留。")
		return
	file.store_string(JSON.stringify(result.metadata, "  "))
	file.close()
	if DirAccess.rename_absolute(_staging_dir, _job_dir) != OK:
		result.root.free()
		message.emit("无法完成模型缓存写入，当前角色已保留。")
		return
	native_model_ready.emit(result.root, result.metadata, _job_dir.path_join("metadata.json"))


func _process(_delta: float) -> void:
	if not busy:
		return
	if _phase == "native":
		return
	if _phase == "inspect":
		if bool(_archive_worker.is_running()):
			if Time.get_ticks_msec() - _started_ms > 180000:
				_archive_worker.cancel()
				busy = false
				message.emit("模型解压超时，当前角色已保留。")
			return
		busy = false
		var failure := str(_archive_worker.get_error())
		if not failure.is_empty():
			message.emit(failure)
			return
		_archive_index = _read(str(_archive_worker.get_result_path()))
		if not _archive_index.get("ok", false):
			message.emit("压缩包检查失败，请确认它是有效的 ZIP 或 7z。")
			return
		var models: Array = _archive_index.get("models", [])
		if models.is_empty():
			message.emit("压缩包内没有 PMX 模型。")
			return
		archive_ready.emit(models)
		return
	if OS.is_process_running(_pid):
		if Time.get_ticks_msec() - _started_ms > 180000:
			OS.kill(_pid)
			_pid = 0
			busy = false
			message.emit("模型转换超时，当前角色已保留。")
		return
	busy = false
	_pid = 0
	var metadata := _read(_staging_dir.path_join("metadata.json"))
	if metadata.is_empty() or metadata.get("bones", []).is_empty() or not FileAccess.file_exists(_staging_dir.path_join("model.glb")):
		var failure := _read(_staging_dir.path_join("import_error.json"))
		var reason := str(failure.get("error", "")).strip_edges()
		message.emit(reason if not reason.is_empty() else "模型转换失败，当前角色已保留。")
		return
	metadata["source_pmx"] = _selected_pmx
	metadata["archive_sha256"] = _archive_index.get("sha256", "")
	var file := FileAccess.open(_staging_dir.path_join("metadata.json"), FileAccess.WRITE)
	if file == null:
		message.emit("无法保存转换结果，当前角色已保留。")
		return
	file.store_string(JSON.stringify(metadata, "  "))
	file.close()
	if DirAccess.rename_absolute(_staging_dir, _job_dir) != OK:
		message.emit("无法完成模型缓存写入，当前角色已保留。")
		return
	model_ready.emit(_job_dir.path_join("model.glb"), metadata, _job_dir.path_join("metadata.json"))


func _exit_tree() -> void:
	if _archive_worker != null:
		_archive_worker.cancel()
	if _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)


func _read(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var value = JSON.parse_string(FileAccess.get_file_as_string(path))
	return value if value is Dictionary else {}
