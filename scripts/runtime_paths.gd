extends RefCounted


static func importer_command(blender_override: String = "") -> Dictionary:
	var blender := blender_override if not blender_override.is_empty() else bundled_blender_path()
	if blender.is_empty():
		for folder: String in OS.get_environment("PATH").split(";", false):
			var candidate := folder.path_join("blender.exe")
			if FileAccess.file_exists(candidate):
				blender = candidate
				break
	var base := OS.get_executable_path().get_base_dir()
	var script := base.path_join("runtime/importer/import_pmx_blender.py")
	if OS.has_feature("editor"):
		base = ProjectSettings.globalize_path("res://dist/MotionCapture")
		script = ProjectSettings.globalize_path("res://tools/import_pmx_blender.py")
	var addon := base.path_join("runtime/mmd_tools")
	if blender.is_empty() or not FileAccess.file_exists(blender):
		return {"executable": "", "error": "未找到 Blender，请解压完整发布包或在设置中选择 Blender。"}
	if not FileAccess.file_exists(script) or not FileAccess.file_exists(addon.path_join("__init__.py")):
		return {"executable": "", "error": "模型转换组件不完整，请重新解压完整发布包。"}
	return {"executable": blender, "args_prefix": PackedStringArray(["--background", "--factory-startup", "--disable-autoexec", "--python-exit-code", "1", "--python", script, "--"]), "mmd_tools_dir": addon}


static func bundled_blender_path() -> String:
	var base := OS.get_executable_path().get_base_dir()
	if OS.has_feature("editor"):
		base = ProjectSettings.globalize_path("res://dist/MotionCapture")
	var candidate := base.path_join("runtime/blender/blender.exe")
	return candidate if FileAccess.file_exists(candidate) else ""
