extends Node3D

@export_range(-180.0, 180.0) var light_azimuth: float = -20.0
@export_range(5.0, 85.0) var light_elevation: float = 35.0
@export_range(-0.5, 0.7) var shadow_threshold: float = 0.12
@export_range(0.0, 3.0) var outline_width: float = 1.15

@onready var actor: Node3D = $Actor
@onready var camera = $Camera3D
@onready var key_light: DirectionalLight3D = $KeyLight

var material_setup := MarchMaterials.new()
var cloth_setup = null
var receiver := preload("res://scripts/native_mocap.gd").new()
var retarget := preload("res://scripts/mocap_retarget.gd").new()
var receiver_error: Error = OK
var _was_capturing := false
var turn_light: bool = false
var hud: CanvasLayer
var status: Label
var render_status: Label
var light_slider: HSlider
var notice: Label
var menu_windows: Dictionary = {}
var start_button: Button
var stop_button: Button
var import_button: Button
var restore_button: Button
var model_label: Label
var main_panel
var mapping_settings := preload("res://scripts/mapping_settings.gd").new()
var mapping_panel
var app_settings
var video_output
var capture_preview
var importer
var stage
var archive_dialog: FileDialog
var scene_dialog: FileDialog
var model_dialog: ConfirmationDialog
var model_list: ItemList
var compatibility_import: CheckButton
var background_picker: ColorPickerButton
var transparent_toggle: CheckButton
var pmx_outline_toggle: CheckButton
var body_collision_toggle: CheckButton
var physics_status: Label
var body_collision_assistance := true
var _archive_models: Array = []
var _model_metadata_path: String = ""
var _ui_scale := 1.0
var _preferences_ready: bool = false


func _ready() -> void:
	process_priority = -20
	mapping_settings.load_file()
	retarget.settings = mapping_settings
	receiver_error = receiver.open()
	stage = preload("res://scripts/stage_settings.gd").new()
	add_child(stage)
	stage.setup(self)
	importer = preload("res://scripts/model_importer.gd").new()
	add_child(importer)
	importer.message.connect(func(text: String): notice.text = text)
	importer.archive_ready.connect(_on_archive_ready)
	importer.model_ready.connect(_adopt_model)
	importer.native_model_ready.connect(_adopt_native_model)
	stage.message.connect(func(text: String): notice.text = text)
	_build_ui()
	_refresh_physics_status()
	_build_model_dialogs()
	mapping_panel = preload("res://scripts/mapping_settings_panel.gd").new()
	add_child(mapping_panel)
	mapping_panel.setup(mapping_settings)
	_refresh_capabilities()
	get_window().files_dropped.connect(_on_files_dropped)
	app_settings = preload("res://scripts/app_settings_panel.gd").new()
	add_child(app_settings)
	app_settings.setup(camera, get_viewport())
	app_settings.capture_options_changed.connect(_apply_capture_options)
	app_settings.blender_path_changed.connect(func(path: String): importer.blender_path = path)
	importer.blender_path = app_settings.blender_path
	video_output = preload("res://scripts/video_output_panel.gd").new()
	add_child(video_output)
	video_output.setup(self)
	capture_preview = preload("res://scripts/capture_preview.gd").new()
	add_child(capture_preview)
	capture_preview.setup(receiver)
	app_settings.preview_requested.connect(capture_preview.set_enabled)
	capture_preview.preview_changed.connect(app_settings.set_preview_state)
	_restore_preferences()
	_preferences_ready = true
	_set_light()
	if receiver_error != OK:
		notice.text = "原生动捕模块加载失败，请检查完整发行文件。"
	print("MOCAP_READY renderer=", RenderingServer.get_video_adapter_name(), " render_size=", get_viewport().get_texture().get_size())


func _process(delta: float) -> void:
	var frame: Dictionary = receiver.poll()
	if not frame.is_empty():
		retarget.ingest(frame)
	if actor.skeleton != null:
		retarget.update(delta)
		material_setup.update_head(actor.skeleton)
	if turn_light:
		light_azimuth = wrapf(light_azimuth + delta * 24.0, -180.0, 180.0)
		light_slider.set_value_no_signal(light_azimuth)
		_set_light()
	var running: bool = receiver.is_running()
	if _was_capturing and not running:
		notice.text = "捕捉已结束。" + receiver.get_error()
	_was_capturing = running
	notice.visible = not notice.text.is_empty()
	start_button.disabled = running or actor.skeleton == null or importer.busy
	stop_button.disabled = not running
	import_button.disabled = importer.busy or running
	restore_button.disabled = importer.busy or actor.model_root == null
	var state: Dictionary = retarget.tracking
	var connection := "正在捕捉" if receiver.is_live() else ("正在打开摄像头" if running else "已停止")
	status.text = "%s · 面部 %s · 上肢 %s" % [connection, _tracking_text(state.get("face", false)), _tracking_text(state.get("pose", false))]
	var size := get_viewport().get_texture().get_size()
	render_status.text = "动捕 %.0f Hz · 渲染 %d FPS\n%d × %d" % [receiver.capture_fps if receiver.is_live() else 0.0, Engine.get_frames_per_second(), size.x, size.y]


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_H:
				hud.visible = not hud.visible
				get_viewport().set_input_as_handled()
			KEY_F12:
				save_screenshot()
				get_viewport().set_input_as_handled()


func _exit_tree() -> void:
	if video_output != null:
		video_output.stop_output()
	receiver.close()


func start_capture() -> void:
	if receiver.is_running() or actor.skeleton == null:
		return
	retarget.reset()
	if receiver.start(app_settings.capture_options):
		_was_capturing = true
		notice.text = "正在打开摄像头，请让脸、肩膀和双手进入画面。"
	else:
		notice.text = "捕捉启动失败：" + receiver.get_error()


func stop_capture() -> void:
	receiver.stop()
	_was_capturing = false
	if actor.skeleton != null:
		retarget.reset()
	if cloth_setup != null:
		cloth_setup.reset()
	notice.text = "已停止捕捉并释放摄像头。"

func _set_light() -> void:
	var azimuth := deg_to_rad(light_azimuth)
	var elevation := deg_to_rad(light_elevation)
	var to_light := Vector3(sin(azimuth) * cos(elevation), sin(elevation), cos(azimuth) * cos(elevation))
	key_light.look_at_from_position(actor.global_position + to_light * 8.0, actor.global_position)


func save_screenshot() -> void:
	var folder := ProjectSettings.globalize_path("user://captures")
	DirAccess.make_dir_recursive_absolute(folder)
	var filename := "mocap_%s_%d.png" % [Time.get_datetime_string_from_system().replace(":", "-"), Time.get_ticks_msec()]
	await RenderingServer.frame_post_draw
	var result := get_viewport().get_texture().get_image().save_png(folder.path_join(filename))
	notice.text = "已保存：" + folder.path_join(filename) if result == OK else "截图保存失败：" + error_string(result)


func _tracking_text(tracked: bool) -> String:
	return "已识别" if tracked else "未识别"


func _build_ui() -> void:
	hud = CanvasLayer.new()
	hud.name = "HUD"
	add_child(hud)
	var theme := Theme.new()
	var font := SystemFont.new()
	font.oversampling = 2.0
	font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans CJK SC"])
	theme.default_font = font
	theme.default_font_size = 16
	main_panel = preload("res://scripts/floating_panel.gd").new()
	main_panel.position = Vector2(20, 20)
	main_panel.custom_minimum_size.x = 300
	main_panel.theme = theme
	main_panel.add_theme_stylebox_override("panel", _panel_style())
	hud.add_child(main_panel)
	main_panel.setup("Honkai Render · 动捕")
	var box: VBoxContainer = main_panel.body
	var entries := GridContainer.new()
	entries.columns = 3
	entries.add_theme_constant_override("h_separation", 8)
	entries.add_theme_constant_override("v_separation", 8)
	box.add_child(entries)
	for section in ["模型", "捕捉", "映射", "画面", "场景", "应用"]:
		_button(entries, section, _open_menu.bind(section))
	var controls := HBoxContainer.new()
	box.add_child(controls)
	start_button = _button(controls, "开始捕捉", start_capture)
	start_button.disabled = true
	stop_button = _button(controls, "停止", stop_capture)
	stop_button.disabled = true
	status = _label(box, "请先导入角色", 14, Color("d8e4e6"))
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.custom_minimum_size.x = 270
	notice = _label(box, "导入 PMX 模型后即可开始捕捉。", 14, Color("d5c49c"))
	notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notice.custom_minimum_size.x = 270
	render_status = _label(box, "", 13, Color("9aabb8"))

	var model := _menu_page("模型", theme)
	model_label = _label(model, "未导入角色", 22, Color("edf2f2"))
	model_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	import_button = _button(model, "导入模型压缩包…", _show_archive_dialog)
	restore_button = _button(model, "卸载当前角色", _unload_model)
	_label(model, "可拖入 ZIP / 7z，再选择包内的 PMX。\n程序和发行包均不附带角色模型。", 15, Color("a7b7c1"))
	physics_status = _label(model, "", 14, Color("a7b7c1"))
	body_collision_toggle = CheckButton.new()
	body_collision_toggle.text = "头发与身体防穿模辅助"
	body_collision_toggle.button_pressed = body_collision_assistance
	body_collision_toggle.toggled.connect(func(enabled: bool):
		body_collision_assistance = enabled
		if cloth_setup is MMDPhysics:
			cloth_setup.set_body_collision_assistance(enabled)
		_save_preferences())
	model.add_child(body_collision_toggle)
	_button(model, "模型转换器设置…", func(): app_settings.popup_section(2))

	var graphics := _menu_page("画面", theme)
	_button(graphics, "相机与抗锯齿…", func(): app_settings.popup_section(0))
	_button(graphics, "OBS 视频输出…", func(): video_output.popup_centered())
	var views := HBoxContainer.new()
	graphics.add_child(views)
	_button(views, "正面", func(): camera.set_view("front"))
	_button(views, "侧面", func(): camera.set_view("right"))
	_button(views, "重新取景", func(): camera.frame_subject())
	light_slider = _slider(graphics, "灯光方向", -180, 180, light_azimuth, func(value: float):
		light_azimuth = value
		_set_light())
	_slider(graphics, "灯光高度", 5, 85, light_elevation, func(value: float):
		light_elevation = value
		_set_light())
	_slider(graphics, "明暗分界", -0.5, 0.7, shadow_threshold, func(value: float):
		shadow_threshold = value
		material_setup.set_shadow_threshold(value))
	_slider(graphics, "MMD 几何描边", 0, 3, outline_width, func(value: float):
		outline_width = value
		material_setup.set_outline_width(value))
	pmx_outline_toggle = CheckButton.new()
	pmx_outline_toggle.text = "使用 PMX 原始描边色"
	pmx_outline_toggle.toggled.connect(func(enabled: bool):
		material_setup.set_pmx_outline_colors(enabled)
		_save_preferences())
	graphics.add_child(pmx_outline_toggle)
	var rotate_light := CheckButton.new()
	rotate_light.text = "自动转灯"
	rotate_light.toggled.connect(func(enabled: bool): turn_light = enabled)
	graphics.add_child(rotate_light)

	var scene := _menu_page("场景", theme)
	transparent_toggle = CheckButton.new()
	transparent_toggle.text = "透明角色背景"
	transparent_toggle.button_pressed = stage.transparent
	transparent_toggle.toggled.connect(_set_transparent)
	scene.add_child(transparent_toggle)
	_label(scene, "保留系统标题栏。按 H 隐藏或恢复界面。", 15, Color("a7b7c1"))
	background_picker = ColorPickerButton.new()
	background_picker.color = stage.background_color
	background_picker.text = "背景颜色"
	background_picker.edit_alpha = false
	background_picker.color_changed.connect(func(color: Color):
		stage.set_background_color(color)
		_save_preferences())
	scene.add_child(background_picker)
	_button(scene, "添加场景 / 图片…", func(): scene_dialog.popup_centered(Vector2i(900, 600)))
	_button(scene, "清除场景", func(): stage.clear_asset(); _save_preferences())

	var application := _menu_page("应用", theme)
	_label(application, "针对米哈游卡通风格优化的实时角色动捕。\n面部、手势与上肢映射；OBS 透明视频输出。", 16, Color("d8e4e6"))
	var scale_row := HBoxContainer.new()
	application.add_child(scale_row)
	_label(scale_row, "界面缩放", 16, Color.WHITE)
	var scale_select := OptionButton.new()
	for amount in [100, 125, 150, 175, 200]:
		scale_select.add_item("%d%%" % amount)
	scale_select.item_selected.connect(func(index: int): _set_ui_scale([1.0, 1.25, 1.5, 1.75, 2.0][index]))
	scale_row.add_child(scale_select)
	menu_windows["应用"].set_meta("scale_select", scale_select)
	_label(application, "中键旋转 · Shift + 中键平移 · 滚轮缩放\n小键盘切换视角 · Home 重新取景\nH 隐藏界面 · F12 保存截图", 15, Color("a7b7c1"))


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("111820")
	style.border_color = Color("394954")
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 14
	style.content_margin_bottom = 14
	return style


func _menu_page(section: String, theme: Theme) -> VBoxContainer:
	var window := Window.new()
	window.title = section
	window.size = Vector2i(590, 540)
	window.min_size = Vector2i(490, 450)
	window.visible = false
	window.transient = true
	window.transparent = false
	window.close_requested.connect(window.hide)
	add_child(window)
	menu_windows[section] = window
	var panel := PanelContainer.new()
	panel.theme = theme
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_theme_stylebox_override("panel", _panel_style())
	window.add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 14)
	scroll.add_child(box)
	return box


func _open_menu(section: String) -> void:
	for window: Window in menu_windows.values():
		window.hide()
	mapping_panel.hide()
	app_settings.hide()
	video_output.hide()
	match section:
		"捕捉": app_settings.popup_section(1)
		"映射": mapping_panel.popup_centered(Vector2i(820, 620))
		_: menu_windows[section].popup_centered()


func _show_archive_dialog() -> void:
	for window: Window in menu_windows.values():
		window.hide()
	archive_dialog.popup_centered(Vector2i(900, 600))


func _set_ui_scale(value: float) -> void:
	_ui_scale = clampf(value, 1.0, 2.0)
	main_panel.scale = Vector2.ONE * _ui_scale
	for window: Window in menu_windows.values():
		window.content_scale_factor = _ui_scale
	mapping_panel.content_scale_factor = _ui_scale
	app_settings.content_scale_factor = _ui_scale
	video_output.content_scale_factor = _ui_scale
	capture_preview.content_scale_factor = _ui_scale
	var selector: OptionButton = menu_windows["应用"].get_meta("scale_select")
	selector.select([1.0, 1.25, 1.5, 1.75, 2.0].find(_ui_scale))
	_save_preferences()

func _label(parent: Node, text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	return label


func _button(parent: Node, text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 34
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func _slider(parent: Node, title: String, low: float, high: float, initial: float, callback: Callable) -> HSlider:
	_label(parent, title, 13, Color(0.75, 0.81, 0.9))
	var slider := HSlider.new()
	slider.min_value = low
	slider.max_value = high
	slider.step = (high - low) / 200.0
	slider.value = initial
	slider.custom_minimum_size.y = 18
	slider.value_changed.connect(callback)
	parent.add_child(slider)
	return slider


func _build_model_dialogs() -> void:
	archive_dialog = FileDialog.new()
	archive_dialog.title = "导入 PMX 模型压缩包"
	archive_dialog.access = FileDialog.ACCESS_FILESYSTEM
	archive_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	archive_dialog.filters = PackedStringArray(["*.zip,*.7z ; PMX 模型压缩包"])
	archive_dialog.file_selected.connect(func(path: String): importer.inspect_archive(path))
	add_child(archive_dialog)
	scene_dialog = FileDialog.new()
	scene_dialog.title = "添加场景或图片背景"
	scene_dialog.access = FileDialog.ACCESS_FILESYSTEM
	scene_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	scene_dialog.filters = PackedStringArray(["*.glb,*.gltf ; 3D 场景", "*.png,*.jpg,*.jpeg,*.webp ; 图片背景"])
	scene_dialog.file_selected.connect(func(path: String):
		if stage.load_asset(path):
			_save_preferences())
	add_child(scene_dialog)
	model_dialog = ConfirmationDialog.new()
	model_dialog.title = "选择压缩包内的 PMX"
	model_dialog.ok_button_text = "载入并使用"
	var layout := VBoxContainer.new()
	model_dialog.add_child(layout)
	_label(layout, "请选择要使用的角色，贴图会一并导入。", 16, Color.WHITE)
	model_list = ItemList.new()
	model_list.custom_minimum_size = Vector2(700, 330)
	model_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	model_list.item_selected.connect(func(_index: int): model_dialog.get_ok_button().disabled = false)
	model_list.item_activated.connect(func(_index: int): _convert_selected_model(); model_dialog.hide())
	layout.add_child(model_list)
	compatibility_import = CheckButton.new()
	compatibility_import.text = "使用 Blender 兼容转换（需要另装兼容组件）"
	compatibility_import.tooltip_text = "通常保持关闭，直接由 C++ 加载 PMX。仅在原生导入不支持该模型时尝试。"
	layout.add_child(compatibility_import)
	model_dialog.confirmed.connect(_convert_selected_model)
	add_child(model_dialog)


func _on_archive_ready(models: Array) -> void:
	compatibility_import.set_pressed_no_signal(false)
	archive_dialog.hide()
	scene_dialog.hide()
	mapping_panel.hide()
	if app_settings != null:
		app_settings.hide()
	_archive_models = models
	model_list.clear()
	for item: Dictionary in models:
		model_list.add_item(str(item.path))
	model_list.select(0)
	model_dialog.get_ok_button().disabled = false
	await get_tree().process_frame
	model_dialog.popup_centered(Vector2i(760, 430))
	notice.text = "发现 %d 个 PMX，请选择角色。" % models.size()


func _convert_selected_model() -> void:
	var selected := model_list.get_selected_items()
	if selected.is_empty():
		return
	importer.convert_selected(str(_archive_models[selected[0]].path), compatibility_import.button_pressed)


func _on_files_dropped(files: PackedStringArray) -> void:
	if files.size() != 1:
		notice.text = "请一次拖入一个模型 ZIP 或场景文件。"
		return
	var path := files[0]
	if path.get_extension().to_lower() in ["zip", "7z"]:
		importer.inspect_archive(path)
	elif stage.load_asset(path):
		_save_preferences()


func _adopt_model(glb_path: String, metadata: Dictionary, metadata_path: String, persist: bool = true) -> bool:
	var candidate: Node3D = actor.stage_external(glb_path)
	if candidate == null:
		notice.text = (actor.import_error + "\n" if not actor.import_error.is_empty() else "") + "模型加载失败，当前角色已保留。"
		return false
	if candidate.has_meta("pmx_metadata"):
		metadata = candidate.get_meta("pmx_metadata")
		metadata["model_file"] = glb_path
	return _install_candidate(candidate, metadata, metadata_path, persist)


func _adopt_native_model(root: Node3D, metadata: Dictionary, metadata_path: String) -> void:
	var candidate: Node3D = actor.stage_prepared(root)
	if candidate == null:
		notice.text = "模型骨骼加载失败，当前角色已保留。"
		return
	_install_candidate(candidate, metadata, metadata_path, true)


func _unload_model() -> void:
	stop_capture()
	if cloth_setup is MMDPhysics:
		cloth_setup.dispose()
	cloth_setup = null
	actor.clear_model()
	retarget = preload("res://scripts/mocap_retarget.gd").new()
	retarget.settings = mapping_settings
	_model_metadata_path = ""
	model_label.text = "未导入角色"
	_refresh_capabilities()
	_refresh_physics_status()
	_save_preferences()

func _install_candidate(candidate: Node3D, metadata: Dictionary, metadata_path: String, persist: bool) -> bool:
	var rig: Skeleton3D = actor.find_rig(candidate)
	var next_retarget := preload("res://scripts/mocap_retarget.gd").new()
	next_retarget.settings = mapping_settings
	if not next_retarget.apply(rig, candidate):
		candidate.free()
		notice.text = "该模型没有可映射的标准上肢或头部骨骼，当前角色已保留。"
		return false
	var next_materials := MarchMaterials.new()
	next_materials.apply(candidate, metadata)
	next_materials.set_shadow_threshold(shadow_threshold)
	next_materials.set_outline_width(outline_width)
	next_materials.set_pmx_outline_colors(material_setup.use_pmx_outline_colors)
	var next_cloth = null
	if metadata.get("physics") is Dictionary and not metadata.physics.get("rigid_bodies", []).is_empty():
		next_cloth = preload("res://scripts/mmd_physics.gd").new()
		next_cloth.set_body_collision_assistance(body_collision_assistance)
		if not next_cloth.apply(rig, candidate, metadata.physics):
			next_cloth.free()
			next_cloth = null
	if cloth_setup is MMDPhysics:
		cloth_setup.dispose()
	actor.commit_model(candidate)
	retarget = next_retarget
	material_setup = next_materials
	cloth_setup = next_cloth
	mapping_settings.reset_filters()
	_model_metadata_path = metadata_path
	model_label.text = str(metadata.get("name", "自选 PMX"))
	_refresh_capabilities()
	_refresh_physics_status()
	if persist:
		camera.frame_subject()
	notice.text = "已使用：" + model_label.text
	if next_cloth == null:
		notice.text += "\n未加载衣发物理；旧缓存模型请重新导入 ZIP。"
	elif not next_cloth.warnings.is_empty():
		notice.text += "\n" + "\n".join(next_cloth.warnings)
	if not retarget.warnings.is_empty():
		notice.text += "\n" + "\n".join(retarget.warnings)
	if not metadata.get("warnings", []).is_empty():
		notice.text += "\n" + "\n".join(metadata.warnings)
	if persist:
		_save_preferences()
	return true


func _refresh_physics_status() -> void:
	if cloth_setup is MMDPhysics:
		physics_status.text = "衣发物理：%d 刚体 · %d 关节" % [cloth_setup.counts.bodies, cloth_setup.counts.joints]
	elif cloth_setup != null:
		physics_status.text = "衣发物理：%d 条弹簧骨链" % cloth_setup.chains.size()
	else:
		physics_status.text = "衣发物理未加载，请重新导入含物理的 PMX。"


func _refresh_capabilities() -> void:
	if mapping_panel == null:
		return
	var available: Array = []
	for id: String in retarget.capabilities.get("channels", {}):
		if retarget.capabilities.channels[id]:
			available.append(id)
	mapping_panel.set_available_channels(available)


func _set_transparent(enabled: bool) -> void:
	stage.set_transparent(enabled)
	_save_preferences()


func _save_preferences() -> void:
	if not _preferences_ready:
		return
	var config := ConfigFile.new()
	config.set_value("application", "ui_scale", _ui_scale)
	config.set_value("model", "metadata", _model_metadata_path)
	config.set_value("stage", "color", stage.background_color)
	config.set_value("stage", "asset", stage.asset_path)
	config.set_value("stage", "transparent", stage.transparent)
	config.set_value("render", "pmx_outline_colors", material_setup.use_pmx_outline_colors)
	config.set_value("physics", "body_collision_assistance", body_collision_assistance)
	config.save("user://showcase.cfg")


func _restore_preferences() -> void:
	var config := ConfigFile.new()
	if config.load("user://showcase.cfg") != OK:
		return
	_set_ui_scale(float(config.get_value("application", "ui_scale", 1.0)))
	var color = config.get_value("stage", "color", stage.background_color)
	if color is Color:
		stage.set_background_color(color)
		background_picker.color = color
	var asset := str(config.get_value("stage", "asset", ""))
	if not asset.is_empty() and FileAccess.file_exists(asset):
		stage.load_asset(asset)
	var pmx_colors := bool(config.get_value("render", "pmx_outline_colors", false))
	material_setup.set_pmx_outline_colors(pmx_colors)
	pmx_outline_toggle.set_pressed_no_signal(pmx_colors)
	body_collision_assistance = bool(config.get_value("physics", "body_collision_assistance", true))
	body_collision_toggle.set_pressed_no_signal(body_collision_assistance)
	var metadata_path := str(config.get_value("model", "metadata", ""))
	if not metadata_path.is_empty() and FileAccess.file_exists(metadata_path):
		var metadata = JSON.parse_string(FileAccess.get_file_as_string(metadata_path))
		if metadata is Dictionary:
			var model_file := str(metadata.get("model_file", metadata_path.get_base_dir().path_join("model.glb")))
			# Old GLB caches can use their original verified archive without rewriting user files.
			if not metadata.has("model_file"):
				var source := str(metadata.get("source_pmx", "")).replace("\\", "/")
				var hash := str(metadata.get("archive_sha256", ""))
				if hash.length() == 64 and source.is_relative_path() and not ".." in source.split("/"):
					var original := ProjectSettings.globalize_path("user://model_imports/archives").path_join(hash.substr(0, 24)).path_join(source)
					if FileAccess.file_exists(original):
						model_file = original
			_adopt_model(model_file, metadata, metadata_path, false)
	var transparent: bool = bool(config.get_value("stage", "transparent", true))
	transparent_toggle.set_pressed_no_signal(transparent)
	_set_transparent(transparent)


func _apply_capture_options(_options: Dictionary) -> void:
	if receiver.is_running():
		stop_capture()
		start_capture()
	else:
		notice.text = "摄像头设置已保存，下次开始捕捉时使用。"
