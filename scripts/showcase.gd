extends Node3D

const STUDIO_THEME := preload("res://scripts/ui_theme.tres")

@export_range(-180.0, 180.0) var light_azimuth: float = 20.0
@export_range(5.0, 85.0) var light_elevation: float = 48.4
@export_range(-0.5, 0.7) var shadow_threshold: float = 0.30
@export_range(0.0, 6.0) var outline_width: float = 2.6

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
var capture_alignment := CaptureCalibration.new()
var calibration_panel
var video_output
var capture_preview
var importer
var stage
var archive_dialog: FileDialog
var scene_dialog: FileDialog
var model_dialog: ConfirmationDialog
var model_list: ItemList
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
var shadows_enabled := true
var shadows_toggle: CheckButton
var enhanced := true
var eye_transparency := false
var eye_transparency_strength := 0.3
var enhanced_toggle: CheckButton
var eye_transparency_toggle: CheckButton
var eye_strength_slider: HSlider
var texture_panel
var _raw_capture_frame := {}
var _mapped_capture_frame := {}


func _ready() -> void:
	process_priority = -20
	TranslationServer.set_locale("zh_CN")
	mapping_settings.load_file()
	capture_alignment.load_file()
	capture_alignment.changed.connect(func(): _recenter_capture(false))
	get_window().title = ProjectSettings.get_setting("application/config/name") + " " + ProjectSettings.get_setting("application/config/version", "")
	retarget.settings = mapping_settings
	receiver_error = receiver.open()
	stage = preload("res://scripts/stage_settings.gd").new()
	add_child(stage)
	stage.setup(self)
	importer = preload("res://scripts/model_importer.gd").new()
	add_child(importer)
	importer.message.connect(func(text: String): notice.text = text)
	importer.archive_ready.connect(_on_archive_ready)
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
	capture_alignment.set_device(int(app_settings.capture_options.device))
	calibration_panel = preload("res://scripts/capture_calibration_panel.gd").new()
	add_child(calibration_panel)
	calibration_panel.setup(capture_alignment)
	app_settings.calibration_requested.connect(func():
		app_settings.hide()
		calibration_panel.popup_centered(Vector2i(850, 680)))
	video_output = preload("res://scripts/video_output_panel.gd").new()
	add_child(video_output)
	video_output.setup(self)
	capture_preview = preload("res://scripts/capture_preview.gd").new()
	add_child(capture_preview)
	capture_preview.setup(receiver)
	app_settings.tracking_mode_changed.connect(_apply_tracking_mode)
	app_settings.hand_gesture_assistance_changed.connect(func(enabled: bool): retarget.set_hand_gesture_assistance(enabled))
	retarget.set_hand_gesture_assistance(app_settings.hand_gesture_assistance)
	app_settings.recenter_requested.connect(_recenter_capture)
	_apply_tracking_mode(app_settings.tracking_mode)
	app_settings.preview_requested.connect(capture_preview.set_enabled)
	capture_preview.preview_changed.connect(app_settings.set_preview_state)
	_restore_preferences()
	_preferences_ready = true
	_set_light()
	if receiver_error != OK:
		notice.text = "原生动捕模块加载失败，请检查完整发行文件。"
	print("MOCAP_READY version=", ProjectSettings.get_setting("application/config/version", ""), " renderer=", RenderingServer.get_video_adapter_name(), " render_size=", get_viewport().get_texture().get_size())


func _process(delta: float) -> void:
	var frame: Dictionary = receiver.poll()
	if not frame.is_empty():
		_raw_capture_frame = frame
		_mapped_capture_frame = capture_alignment.correct_frame(frame)
		retarget.ingest(_mapped_capture_frame)
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
	if notice.tooltip_text != notice.text:
		notice.tooltip_text = notice.text
	start_button.disabled = running or actor.skeleton == null or importer.busy
	stop_button.disabled = not running
	import_button.disabled = importer.busy or running
	restore_button.disabled = importer.busy or actor.model_root == null
	var state: Dictionary = retarget.tracking
	var connection := "捕捉中" if receiver.is_live() else ("连接摄像头" if running else "就绪")
	var mode_name := "全身" if retarget.mode == "full_body" else "VTuber"
	status.text = "%s　%s" % [mode_name, connection] if actor.skeleton != null else "导入角色以开始"
	if running:
		status.text += "\n面部 %s　上肢 %s" % [_tracking_text(state.get("face", false)), _tracking_text(state.get("pose", false))]
		if retarget.mode == "full_body":
			status.text += "　下肢 %s" % _tracking_text(state.get("lower_body", false))
	var size := get_viewport().get_texture().get_size()
	render_status.text = "%.0f Hz　%d FPS" % [receiver.capture_fps if receiver.is_live() else 0.0, Engine.get_frames_per_second()]
	render_status.tooltip_text = "动捕更新率 / 渲染帧率　%d × %d" % [size.x, size.y]


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
	if receiver.start(app_settings.capture_options.merged({"pose_model": app_settings.pose_model})):
		_was_capturing = true
		notice.text = "请让全身入镜" if retarget.mode == "full_body" else "请让脸和双手入镜"
	else:
		notice.text = "捕捉启动失败：" + receiver.get_error()


func stop_capture() -> void:
	receiver.stop()
	_was_capturing = false
	_raw_capture_frame.clear()
	_mapped_capture_frame.clear()
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
	var theme := STUDIO_THEME
	main_panel = preload("res://scripts/floating_panel.gd").new()
	main_panel.position = Vector2(20, 20)
	main_panel.custom_minimum_size.x = 300
	main_panel.theme = theme
	main_panel.add_theme_stylebox_override("panel", _panel_style())
	hud.add_child(main_panel)
	main_panel.setup("Honkai Render")
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
	start_button.theme_type_variation = "PrimaryButton"
	start_button.disabled = true
	stop_button = _button(controls, "停止", stop_capture)
	stop_button.disabled = true
	status = _label(box, "请先导入角色", 14, STUDIO_THEME.get_color("text", "Studio"))
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.custom_minimum_size.x = 270
	notice = _label(box, "导入 PMX 模型后即可开始捕捉。", 14, STUDIO_THEME.get_color("warning", "Studio"))
	notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notice.custom_minimum_size.x = 270
	notice.max_lines_visible = 3
	notice.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	render_status = _label(box, "", 13, STUDIO_THEME.get_color("muted", "Studio"))

	var model := _menu_page("模型", theme)
	model_label = _label(model, "未导入角色", 22, STUDIO_THEME.get_color("text", "Studio"))
	model_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	import_button = _button(model, "导入模型压缩包…", _show_archive_dialog)
	import_button.theme_type_variation = "PrimaryButton"
	restore_button = _button(model, "卸载当前角色", _unload_model)
	_label(model, "拖入 ZIP / 7z，选择角色 PMX。", 15, STUDIO_THEME.get_color("muted", "Studio"))
	physics_status = _label(model, "", 14, STUDIO_THEME.get_color("muted", "Studio"))
	body_collision_toggle = CheckButton.new()
	body_collision_toggle.text = "头发碰撞辅助"
	body_collision_toggle.tooltip_text = "补充头发与身体的碰撞，效果取决于模型代理形状，不能保证任意动作都无穿模。"
	body_collision_toggle.button_pressed = body_collision_assistance
	body_collision_toggle.toggled.connect(func(enabled: bool):
		body_collision_assistance = enabled
		if cloth_setup is MMDPhysics:
			cloth_setup.set_body_collision_assistance(enabled)
		_save_preferences())
	model.add_child(body_collision_toggle)
	enhanced_toggle = CheckButton.new()
	enhanced_toggle.text = "增强表现"
	enhanced_toggle.tooltip_text = "使用几何生成的阴影／高光辅助图及手动增强贴图；关闭后保留原始贴图。"
	enhanced_toggle.button_pressed = enhanced
	enhanced_toggle.toggled.connect(func(value: bool):
		enhanced = value
		material_setup.set_enhanced(value)
		_save_preferences())
	model.add_child(enhanced_toggle)
	eye_transparency_toggle = CheckButton.new()
	eye_transparency_toggle.text = "刘海眼透"
	eye_transparency_toggle.tooltip_text = "仅在头发遮挡眉眼且接近正面时混回眼部细节。"
	eye_transparency_toggle.toggled.connect(func(value: bool):
		eye_transparency = value
		material_setup.set_eye_transparency(value, eye_transparency_strength)
		_save_preferences())
	model.add_child(eye_transparency_toggle)
	eye_strength_slider = _slider(model, "眼透强度", 0.0, 1.0, eye_transparency_strength, func(value: float):
		eye_transparency_strength = value
		material_setup.set_eye_transparency(eye_transparency, value)
		_save_preferences())
	texture_panel = preload("res://scripts/model_textures_panel.gd").new()
	add_child(texture_panel)
	_button(model, "增强贴图…", func():
		texture_panel.set_renderer(material_setup)
		texture_panel.popup_centered())

	var graphics := _menu_page("画面", theme)
	_button(graphics, "相机与抗锯齿…", func(): app_settings.popup_section(0))
	_button(graphics, "OBS 视频输出…", func(): video_output.popup_centered())
	var views := HBoxContainer.new()
	graphics.add_child(views)
	_button(views, "正面", func(): camera.set_view("front"))
	_button(views, "侧面", func(): camera.set_view("right"))
	_button(views, "重新取景", func(): camera.frame_subject())
	_slider(graphics, "描边宽度", 0, 6, outline_width, func(value: float):
		outline_width = value
		material_setup.set_outline_width(value))
	pmx_outline_toggle = CheckButton.new()
	pmx_outline_toggle.text = "使用模型描边色"
	pmx_outline_toggle.toggled.connect(func(enabled: bool):
		material_setup.set_pmx_outline_colors(enabled)
		_save_preferences())
	graphics.add_child(pmx_outline_toggle)

	var scene := _menu_page("场景", theme)
	transparent_toggle = CheckButton.new()
	transparent_toggle.text = "透明背景"
	transparent_toggle.tooltip_text = "保留系统标题栏。按 H 隐藏或恢复操作界面。"
	transparent_toggle.button_pressed = stage.transparent
	transparent_toggle.toggled.connect(_set_transparent)
	scene.add_child(transparent_toggle)
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
	_label(scene, "灯光", 18, STUDIO_THEME.get_color("text", "Studio"))
	shadows_toggle = CheckButton.new()
	shadows_toggle.text = "计算阴影"
	shadows_toggle.button_pressed = shadows_enabled
	shadows_toggle.tooltip_text = "关闭后所有材质使用照亮色，保留贴图、透明度与描边。"
	shadows_toggle.toggled.connect(_set_shadows_enabled)
	scene.add_child(shadows_toggle)
	light_slider = _slider(scene, "灯光方向", -180, 180, light_azimuth, func(value: float):
		light_azimuth = value
		_set_light())
	_slider(scene, "灯光高度", 5, 85, light_elevation, func(value: float):
		light_elevation = value
		_set_light())
	_slider(scene, "明暗分界", -0.5, 0.7, shadow_threshold, func(value: float):
		shadow_threshold = value
		material_setup.set_shadow_threshold(value))
	var rotate_light := CheckButton.new()
	rotate_light.text = "自动转灯"
	rotate_light.toggled.connect(func(enabled: bool): turn_light = enabled)
	scene.add_child(rotate_light)

	var application := _menu_page("应用", theme)
	_label(application, "实时角色动捕　OBS 透明输出", 16, STUDIO_THEME.get_color("text", "Studio"))
	var scale_row := HBoxContainer.new()
	application.add_child(scale_row)
	_label(scale_row, "界面缩放", 16, STUDIO_THEME.get_color("text", "Studio"))
	var scale_select := OptionButton.new()
	for amount in [100, 125, 150, 175, 200]:
		scale_select.add_item("%d%%" % amount)
	scale_select.item_selected.connect(func(index: int): _set_ui_scale([1.0, 1.25, 1.5, 1.75, 2.0][index]))
	scale_row.add_child(scale_select)
	menu_windows["应用"].set_meta("scale_select", scale_select)
	_label(application, "中键旋转 · Shift + 中键平移 · 滚轮缩放\n小键盘切换视角 · Home 重新取景\nH 隐藏界面 · F12 保存截图", 15, STUDIO_THEME.get_color("muted", "Studio"))
	_button(application, "保存姿态诊断…", _save_pose_diagnostic).tooltip_text = "保存当前单帧的身体／手部关键点、映射和镜头参数；不含摄像头画面、人脸点或模型文件。"


func _panel_style() -> StyleBoxFlat:
	return STUDIO_THEME.get_stylebox("panel", "StudioPanel").duplicate()


func _menu_page(section: String, theme: Theme) -> VBoxContainer:
	var window := Window.new()
	window.title = section
	window.size = {"模型": Vector2i(560, 580), "画面": Vector2i(590, 400), "场景": Vector2i(590, 620), "应用": Vector2i(540, 390)}[section]
	window.min_size = Vector2i(420, 260)
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
	calibration_panel.hide()
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
	calibration_panel.content_scale_factor = _ui_scale
	texture_panel.content_scale_factor = _ui_scale
	for dialog: Window in [archive_dialog, scene_dialog, model_dialog]:
		dialog.content_scale_factor = _ui_scale
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
	_label(parent, title, 14, STUDIO_THEME.get_color("text", "Studio"))
	var slider := HSlider.new()
	slider.min_value = low
	slider.max_value = high
	slider.step = (high - low) / 200.0
	slider.value = initial
	slider.tooltip_text = "%s：%.2f" % [title, initial]
	slider.value_changed.connect(func(value: float): slider.tooltip_text = "%s：%.2f" % [title, value])
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
	_label(layout, "请选择要使用的角色，贴图会一并导入。", 16, STUDIO_THEME.get_color("text", "Studio"))
	model_list = ItemList.new()
	model_list.custom_minimum_size = Vector2(0, 180)
	model_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	model_list.item_selected.connect(func(_index: int): model_dialog.get_ok_button().disabled = false)
	model_list.item_activated.connect(func(_index: int): _convert_selected_model(); model_dialog.hide())
	layout.add_child(model_list)
	model_dialog.confirmed.connect(_convert_selected_model)
	add_child(model_dialog)


func _on_archive_ready(models: Array) -> void:
	archive_dialog.hide()
	scene_dialog.hide()
	mapping_panel.hide()
	if app_settings != null:
		app_settings.hide()
	_archive_models = models
	model_list.clear()
	for item: Dictionary in models:
		var index := model_list.add_item(str(item.path))
		model_list.set_item_tooltip(index, str(item.path))
	model_list.select(0)
	model_dialog.get_ok_button().disabled = false
	await get_tree().process_frame
	model_dialog.popup_centered(Vector2i(760, 430))
	notice.text = "发现 %d 个 PMX，请选择角色。" % models.size()


func _convert_selected_model() -> void:
	var selected := model_list.get_selected_items()
	if selected.is_empty():
		return
	importer.convert_selected(str(_archive_models[selected[0]].path))


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
	var pmx_colors: bool = material_setup.use_pmx_outline_colors
	material_setup = MarchMaterials.new()
	material_setup.set_pmx_outline_colors(pmx_colors)
	material_setup.enhanced = enhanced
	if texture_panel != null:
		texture_panel.set_renderer(material_setup)
	retarget = preload("res://scripts/mocap_retarget.gd").new()
	retarget.set_mode(app_settings.tracking_mode)
	retarget.set_hand_gesture_assistance(app_settings.hand_gesture_assistance)
	retarget.settings = mapping_settings
	_model_metadata_path = ""
	model_label.text = "未导入角色"
	_refresh_capabilities()
	_refresh_physics_status()
	_save_preferences()

func _install_candidate(candidate: Node3D, metadata: Dictionary, metadata_path: String, persist: bool) -> bool:
	var rig: Skeleton3D = actor.find_rig(candidate)
	var next_retarget := preload("res://scripts/mocap_retarget.gd").new()
	next_retarget.set_mode(app_settings.tracking_mode)
	next_retarget.set_hand_gesture_assistance(app_settings.hand_gesture_assistance)
	next_retarget.settings = mapping_settings
	if not next_retarget.apply(rig, candidate):
		candidate.free()
		notice.text = "该模型没有可映射的标准上肢或头部骨骼，当前角色已保留。"
		return false
	var next_materials := MarchMaterials.new()
	next_materials.enhanced = enhanced
	next_materials.eye_transparency = eye_transparency
	next_materials.eye_transparency_strength = eye_transparency_strength
	next_materials.apply(candidate, metadata)
	next_materials.set_shadow_threshold(shadow_threshold)
	next_materials.set_shadows_enabled(shadows_enabled)
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
	_raw_capture_frame.clear()
	_mapped_capture_frame.clear()
	actor.commit_model(candidate)
	retarget = next_retarget
	material_setup = next_materials
	if texture_panel != null:
		texture_panel.set_renderer(material_setup)
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
	config.set_value("render", "shadows_enabled", shadows_enabled)
	config.set_value("render", "enhanced", enhanced)
	config.set_value("render", "eye_transparency", eye_transparency)
	config.set_value("render", "eye_strength", eye_transparency_strength)
	config.set_value("physics", "body_collision_assistance", body_collision_assistance)
	config.save("user://showcase.cfg")


func _restore_preferences() -> void:
	var config := ConfigFile.new()
	if config.load("user://showcase.cfg") != OK:
		return
	_set_ui_scale(float(config.get_value("application", "ui_scale", 1.0)))
	_set_shadows_enabled(bool(config.get_value("render", "shadows_enabled", true)))
	enhanced = bool(config.get_value("render", "enhanced", true))
	eye_transparency = bool(config.get_value("render", "eye_transparency", false))
	eye_transparency_strength = clampf(float(config.get_value("render", "eye_strength", 0.3)), 0.0, 1.0)
	enhanced_toggle.set_pressed_no_signal(enhanced)
	eye_transparency_toggle.set_pressed_no_signal(eye_transparency)
	eye_strength_slider.set_value_no_signal(eye_transparency_strength)
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
	capture_alignment.set_device(int(_options.device))
	if receiver.is_running():
		stop_capture()
		start_capture()
	else:
		notice.text = "摄像头设置已保存，下次开始捕捉时使用。"


func _apply_tracking_mode(value: String) -> void:
	_raw_capture_frame.clear()
	_mapped_capture_frame.clear()
	retarget.set_mode(value)
	capture_preview.set_capture_mode(value)
	if cloth_setup != null:
		cloth_setup.reset()
	if _preferences_ready:
		notice.text = "全身模式：请站直并让双脚入镜" if value == "full_body" else "VTuber 模式"


func _recenter_capture(show_notice: bool = true) -> void:
	_raw_capture_frame.clear()
	_mapped_capture_frame.clear()
	retarget.recenter()
	if cloth_setup != null:
		cloth_setup.reset()
	if show_notice and notice != null:
		notice.text = "站姿已重置"


func _set_shadows_enabled(enabled: bool) -> void:
	shadows_enabled = enabled
	shadows_toggle.set_pressed_no_signal(enabled)
	key_light.shadow_enabled = enabled
	material_setup.set_shadows_enabled(enabled)
	_save_preferences()


func _pose_diagnostic() -> Dictionary:
	if _raw_capture_frame.is_empty() or actor.skeleton == null:
		return {}
	var bones := {}
	var mapping := {}
	for channel in ["left_arm", "right_arm", "left_hand", "right_hand"]:
		mapping[channel] = mapping_settings.channels.get(channel, {}).duplicate(true)
	for role in ["左肩", "左腕", "左ひじ", "左手首", "右肩", "右腕", "右ひじ", "右手首"]:
		if retarget._indices.has(role):
			var index: int = retarget._indices[role]
			var pose: Transform3D = actor.skeleton.get_bone_global_pose(index)
			var target := Transform3D(retarget._global_targets.get(index, retarget._neutral_global[index].basis), pose.origin)
			bones[role] = {"pose": _diagnostic_transform(pose), "target": _diagnostic_transform(target), "neutral": _diagnostic_transform(retarget._neutral_global[index])}
	return {"version": 1, "app_version": ProjectSettings.get_setting("application/config/version"),
		"raw": _diagnostic_frame(_raw_capture_frame), "corrected": _diagnostic_frame(_mapped_capture_frame),
		"tracking_mode": retarget.mode, "hand_gestures": app_settings.hand_gesture_assistance,
		"pose_model": receiver.pose_model,
		"mapping": mapping, "smoothing_speed": retarget.smoothing_speed,
		"calibration": capture_alignment.profile.duplicate(true), "capture": app_settings.capture_options.duplicate(),
		"camera": {"transform": _diagnostic_transform(camera.global_transform), "projection": int(camera.projection), "fov": camera.fov, "size": camera.size, "viewport": [get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y]},
		"rig_transform": _diagnostic_transform(actor.skeleton.global_transform), "bones": bones}


func _save_pose_diagnostic() -> void:
	if receiver.last_packet_ms < 0 or Time.get_ticks_msec() - receiver.last_packet_ms > 500:
		notice.text = "请在捕捉出现问题时保存姿态诊断。"
		return
	var data := _pose_diagnostic()
	if data.is_empty():
		notice.text = "没有可保存的姿态。"
		return
	var folder := ProjectSettings.globalize_path("user://diagnostics")
	if DirAccess.make_dir_recursive_absolute(folder) != OK:
		notice.text = "无法创建诊断文件夹。"
		return
	var path := folder.path_join("pose_%d.json" % Time.get_ticks_usec())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		notice.text = "姿态诊断保存失败。"
		return
	file.store_string(JSON.stringify(data, "\t"))
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK:
		notice.text = "姿态诊断写入失败。"
		return
	notice.text = "姿态诊断已保存：" + path
	if DisplayServer.get_name() != "headless":
		OS.shell_open(folder)


static func _diagnostic_frame(frame: Dictionary) -> Dictionary:
	# Export only body/hand landmarks; RGB, face data and model paths never enter diagnostics.
	return {"seq": frame.get("seq", -1), "timestamp_ms": frame.get("timestamp_ms", 0), "pose": frame.get("pose"), "hands": frame.get("hands", [])}.duplicate(true)


static func _diagnostic_transform(value: Transform3D) -> Array:
	var result := []
	for vector: Vector3 in [value.basis.x, value.basis.y, value.basis.z, value.origin]:
		result.append([vector.x, vector.y, vector.z])
	return result
