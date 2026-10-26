extends Window

const RESOLUTIONS := [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160)]
const RATES := [30, 60]
const SAVE_PATH := "user://video_output.cfg"
const UI_THEME = preload("res://scripts/ui_theme.tres")

var _scene: Node3D
var _viewport: SubViewport
var _camera: Camera3D
var _bridge
var _resolution: OptionButton
var _rate: OptionButton
var _status: Label
var _start: Button
var _stop: Button
var _active_fps := 0
var settings_path := SAVE_PATH


func setup(scene: Node3D) -> void:
	_scene = scene
	title = "OBS 视频输出"
	size = Vector2i(620, 410)
	min_size = Vector2i(500, 360)
	transient = true
	visible = false
	close_requested.connect(hide)
	_viewport = SubViewport.new()
	_viewport.name = "AvatarVideo"
	_viewport.size = RESOLUTIONS[0]
	_viewport.world_3d = scene.get_world_3d()
	_viewport.transparent_bg = true
	_viewport.canvas_cull_mask = 0
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	scene.add_child(_viewport)
	_camera = Camera3D.new()
	_camera.cull_mask = 1
	_camera.environment = scene.get_node("Environment").environment.duplicate()
	_camera.environment.background_mode = Environment.BG_CLEAR_COLOR
	_viewport.add_child(_camera)
	_camera.make_current()
	_bridge = preload("res://scripts/spout_output.gd").new()
	add_child(_bridge)
	_bridge.failed.connect(func(message: String):
		_status.text = "输出失败：" + message
		_status.add_theme_color_override("font_color", UI_THEME.get_color("error", "Studio")))
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.theme_type_variation = &"StudioPanel"
	panel.theme = UI_THEME
	add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	panel.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 16)
	scroll.add_child(box)
	_label(box, "透明角色画面，不包含界面")
	_resolution = _choice(box, "输出分辨率", ["请选择分辨率", "720p · 1280 × 720", "1080p · 1920 × 1080", "1440p / 2K · 2560 × 1440", "4K · 3840 × 2160"])
	_resolution.set_item_disabled(0, true)
	_rate = _choice(box, "输出帧率", ["请选择帧率", "30 FPS", "60 FPS"])
	_rate.set_item_disabled(0, true)
	var hint := _label(box, "OBS：Spout2 Capture → BengRender\nAlpha：预乘")
	hint.tooltip_text = "OBS 需安装 Spout2 插件。添加 Spout2 Capture 来源，选择 BengRender。"
	hint.add_theme_color_override("font_color", UI_THEME.get_color("muted", "Studio"))
	var actions := HBoxContainer.new()
	box.add_child(actions)
	_start = Button.new()
	_start.theme_type_variation = &"PrimaryButton"
	_start.text = "启动输出"
	_start.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_start.pressed.connect(start_output)
	actions.add_child(_start)
	_stop = Button.new()
	_stop.text = "停止输出"
	_stop.pressed.connect(stop_output)
	actions.add_child(_stop)
	_status = _label(box, "输出未启动")
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_load_settings()


func _process(_delta: float) -> void:
	if _scene == null:
		return
	var source: Camera3D = _scene.camera
	_camera.global_transform = source.get_global_transform_interpolated()
	_camera.projection = source.projection
	_camera.fov = source.fov
	_camera.size = source.size
	_camera.near = source.near
	_camera.far = source.far
	_viewport.msaa_3d = _scene.get_viewport().msaa_3d
	_viewport.use_taa = false
	_stop.disabled = not _bridge.enabled
	_start.disabled = _resolution.selected < 1 or _rate.selected < 1
	_start.text = "应用设置" if _bridge.enabled else "启动输出"
	if _bridge.enabled:
		_status.text = "%d × %d · %d FPS · 已发送 %d 帧" % [_viewport.size.x, _viewport.size.y, _active_fps, _bridge.get_frames()]


func start_output() -> void:
	if _resolution.selected < 1 or _rate.selected < 1:
		return
	stop_output()
	_viewport.size = RESOLUTIONS[_resolution.selected - 1]
	_active_fps = RATES[_rate.selected - 1]
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	var result: Error = _bridge.start(_viewport, RATES[_rate.selected - 1])
	if result != OK:
		_status.text = "Spout 输出无法启动：" + error_string(result)
		_status.add_theme_color_override("font_color", UI_THEME.get_color("error", "Studio"))
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return
	var settings := ConfigFile.new()
	settings.set_value("output", "resolution", _resolution.selected - 1)
	settings.set_value("output", "fps", RATES[_rate.selected - 1])
	settings.save(settings_path)


func stop_output() -> void:
	if _bridge != null:
		_bridge.stop()
	if _viewport != null:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if _status != null:
		_status.text = "输出已停止"
		_status.add_theme_color_override("font_color", UI_THEME.get_color("muted", "Studio"))


func _exit_tree() -> void:
	stop_output()


func _load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(settings_path) != OK:
		return
	var resolution: int = int(config.get_value("output", "resolution", -1))
	var fps: int = int(config.get_value("output", "fps", -1))
	if resolution >= 0 and resolution < RESOLUTIONS.size():
		_resolution.select(resolution + 1)
	if fps in RATES:
		_rate.select(RATES.find(fps) + 1)


func _choice(parent: Node, label: String, values: Array) -> OptionButton:
	var row := VBoxContainer.new()
	parent.add_child(row)
	_label(row, label)
	var control := OptionButton.new()
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.fit_to_longest_item = false
	control.clip_text = true
	for value: String in values:
		control.add_item(value)
	row.add_child(control)
	return control


func _label(parent: Node, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label
