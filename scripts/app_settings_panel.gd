extends Window

signal capture_options_changed(options: Dictionary)
signal calibration_requested
signal preview_requested(enabled: bool)
signal tracking_mode_changed(mode: String)
signal recenter_requested
signal hand_gesture_assistance_changed(enabled: bool)

const SAVE_PATH := "user://app_settings.json"
const RESOLUTIONS := [Vector2i(640, 480), Vector2i(1280, 720), Vector2i(1920, 1080)]
const FRAME_RATES := [15, 24, 30, 60]
const STUDIO_THEME := preload("res://scripts/ui_theme.tres")

var capture_options: Dictionary = {"device": 0, "width": 640, "height": 480, "fps": 30}
var settings_path: String = SAVE_PATH
var tracking_mode := "vtuber"
var pose_model := "full"
var _pose_model_choice: OptionButton
var hand_gesture_assistance := false
var _gesture_toggle: CheckButton
var _mode: OptionButton
var _recenter_button: Button
var _camera: Camera3D
var _target_viewport: Viewport
var _defaults: Dictionary = {}
var _last_camera: Dictionary = {}
var _msaa := Viewport.MSAA_4X
var _tabs: TabContainer
var _built := false
var _refreshing := false
var _aa: OptionButton
var _projection: OptionButton
var _rows: Dictionary = {}
var _device: SpinBox
var _resolution: OptionButton
var _fps: OptionButton
var _status: Label
var _save_timer: Timer
var _preview_toggle: CheckButton


func setup(camera: Camera3D, viewport: Viewport) -> void:
	_camera = camera
	_target_viewport = viewport
	if not _built:
		_build()
	_defaults = _read_camera()
	load_settings()
	_refresh()


func set_capture_device(device: int) -> void:
	capture_options.device = clampi(device, 0, 255)
	if _built:
		_device.set_value_no_signal(float(capture_options.device))
		save_settings()


func _ready() -> void:
	if not _built:
		_build()
	close_requested.connect(_close)


func _exit_tree() -> void:
	if _save_timer != null and not _save_timer.is_stopped():
		save_settings()


func _process(_delta: float) -> void:
	if not is_instance_valid(_camera) or not is_instance_valid(_target_viewport):
		return
	var current := _read_camera()
	var msaa := int(_target_viewport.msaa_3d)
	if current != _last_camera or msaa != _msaa:
		_last_camera = current
		_msaa = msaa
		_refresh_camera()
		_queue_save()


func save_settings(path: String = "") -> Error:
	var destination := settings_path if path.is_empty() else path
	var data := {"version": 1, "rendering": {"msaa_3d": _msaa}, "camera": _read_camera(), "capture": capture_options, "tracking": {"mode": tracking_mode, "hand_gestures": hand_gesture_assistance, "pose_model": pose_model}}
	var file := FileAccess.open(destination + ".tmp", FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	var result := DirAccess.rename_absolute(ProjectSettings.globalize_path(destination + ".tmp"), ProjectSettings.globalize_path(destination))
	_save_timer.stop()
	_status.text = "已保存" if result == OK else "保存失败：" + error_string(result)
	return result


func load_settings(path: String = "") -> Error:
	var source := settings_path if path.is_empty() else path
	capture_options = {"device": 0, "width": 640, "height": 480, "fps": 30}
	tracking_mode = "vtuber"
	pose_model = "full"
	hand_gesture_assistance = false
	_msaa = Viewport.MSAA_4X
	var camera_options: Dictionary = _defaults.duplicate()
	var result := OK
	if FileAccess.file_exists(source):
		var decoded = JSON.parse_string(FileAccess.get_file_as_string(source))
		if not decoded is Dictionary or decoded.get("version") != 1:
			result = ERR_PARSE_ERROR
		else:
			if decoded.get("tracking") is Dictionary and decoded.tracking.get("mode") in ["vtuber", "full_body"]:
				tracking_mode = decoded.tracking.mode
			if decoded.get("tracking") is Dictionary and decoded.tracking.get("hand_gestures") is bool:
				hand_gesture_assistance = decoded.tracking.hand_gestures
			if decoded.get("tracking") is Dictionary and decoded.tracking.get("pose_model") in ["full", "lite"]:
				pose_model = decoded.tracking.pose_model
			if decoded.get("rendering") is Dictionary and _number(decoded.rendering.get("msaa_3d")):
				_msaa = clampi(int(decoded.rendering.msaa_3d), Viewport.MSAA_DISABLED, Viewport.MSAA_8X)
			if decoded.get("camera") is Dictionary:
				var values: Dictionary = decoded.camera
				for field: String in ["fov", "distance", "focus_height"]:
					if _number(values.get(field)):
						camera_options[field] = float(values[field])
				if _number(values.get("projection")) and int(values.projection) in [Camera3D.PROJECTION_PERSPECTIVE, Camera3D.PROJECTION_ORTHOGONAL]:
					camera_options.projection = int(values.projection)
			if decoded.get("capture") is Dictionary:
				var options: Dictionary = decoded.capture
				if _number(options.get("device")):
					capture_options.device = clampi(int(options.device), 0, 255)
				if _number(options.get("width")) and _number(options.get("height")) and Vector2i(int(options.width), int(options.height)) in RESOLUTIONS:
					capture_options.width = int(options.width)
					capture_options.height = int(options.height)
				if _number(options.get("fps")) and int(options.fps) in FRAME_RATES:
					capture_options.fps = int(options.fps)
	else:
		result = ERR_FILE_NOT_FOUND
	_apply_rendering()
	_apply_camera(camera_options)
	_last_camera = _read_camera()
	if _built:
		_refresh()
		_status.text = "设置损坏，已恢复默认" if result == ERR_PARSE_ERROR else "自动保存"
	return result


func _read_camera() -> Dictionary:
	if not is_instance_valid(_camera):
		return _defaults.duplicate()
	return {"fov": _camera.fov, "distance": _camera.get("distance"), "focus_height": _camera.get("focus").y, "projection": int(_camera.projection)}


func _apply_rendering() -> void:
	if is_instance_valid(_target_viewport):
		_target_viewport.msaa_3d = _msaa as Viewport.MSAA
		_target_viewport.use_taa = false


func _apply_camera(options: Dictionary) -> void:
	if not is_instance_valid(_camera) or options.is_empty():
		return
	_camera.fov = clampf(float(options.fov), 10.0, 120.0)
	var distance := clampf(float(options.distance), 0.35, 12.0)
	var height := clampf(float(options.focus_height), -100.0, 100.0)
	_camera.set("distance", distance)
	_camera.set("framing_distance", distance)
	var focus: Vector3 = _camera.get("focus")
	focus.y = height
	_camera.set("focus", focus)
	var subject: Vector3 = _camera.get("subject_center")
	subject.y = height
	_camera.set("subject_center", subject)
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL if int(options.projection) == Camera3D.PROJECTION_ORTHOGONAL else Camera3D.PROJECTION_PERSPECTIVE
	_camera.call("_update_transform")


func _set_camera(field: String, value: float) -> void:
	if _refreshing or not is_instance_valid(_camera):
		return
	var values := _read_camera()
	values[field] = value
	_apply_camera(values)
	_last_camera = _read_camera()
	_refresh_camera()
	_queue_save()


func _refresh() -> void:
	_refresh_camera()
	_mode.select(1 if tracking_mode == "full_body" else 0)
	_recenter_button.visible = tracking_mode == "full_body"
	_gesture_toggle.set_pressed_no_signal(hand_gesture_assistance)
	_pose_model_choice.select(1 if pose_model == "lite" else 0)
	_device.set_value_no_signal(float(capture_options.device))
	_resolution.select(RESOLUTIONS.find(Vector2i(capture_options.width, capture_options.height)))
	_fps.select(FRAME_RATES.find(int(capture_options.fps)))


func _refresh_camera() -> void:
	if not _built or not is_instance_valid(_camera):
		return
	_refreshing = true
	_aa.select(_msaa)
	_projection.select(1 if _camera.projection == Camera3D.PROJECTION_ORTHOGONAL else 0)
	var values := _read_camera()
	for field: String in _rows:
		_rows[field].slider.set_value_no_signal(float(values[field]))
		_rows[field].spin.set_value_no_signal(float(values[field]))
	_refreshing = false


func _apply_capture() -> void:
	var resolution: Vector2i = RESOLUTIONS[_resolution.selected]
	pose_model = "lite" if _pose_model_choice.selected == 1 else "full"
	capture_options = {"device": int(_device.value), "width": resolution.x, "height": resolution.y, "fps": FRAME_RATES[_fps.selected]}
	save_settings()
	capture_options_changed.emit(capture_options.duplicate())
	_status.text = "已应用捕捉设置"


func _set_mode(index: int) -> void:
	tracking_mode = "full_body" if index == 1 else "vtuber"
	_recenter_button.visible = tracking_mode == "full_body"
	save_settings()
	tracking_mode_changed.emit(tracking_mode)


func _queue_save() -> void:
	_save_timer.start()
	_status.text = "正在保存…"


func _close() -> void:
	if not _save_timer.is_stopped():
		save_settings()
	hide()


func _build() -> void:
	_built = true
	title = "全局设置"
	size = Vector2i(750, 530)
	min_size = Vector2i(650, 490)
	transient = true
	visible = false
	var root := PanelContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.theme = STUDIO_THEME
	root.theme_type_variation = "StudioPanel"
	add_child(root)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 18)
	root.add_child(layout)
	var tabs := TabContainer.new()
	_tabs = tabs
	tabs.tabs_visible = false
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(tabs)
	var graphics := _page(tabs, "画面与相机")
	_aa = _choice(graphics, "抗锯齿", ["关闭", "MSAA 2×", "MSAA 4×", "MSAA 8×"])
	_aa.item_selected.connect(func(index: int): _msaa = index; _apply_rendering(); _queue_save())
	_aa.tooltip_text = "空间抗锯齿，避免时间累积产生运动重影。"
	_separator(graphics)
	_make_row(graphics, "fov", "视野角度", 10.0, 120.0, 1.0, "°")
	_make_row(graphics, "distance", "取景距离", 0.35, 12.0, 0.05, "m")
	_make_row(graphics, "focus_height", "焦点高度", -3.0, 8.0, 0.01, "m")
	_rows.focus_height.spin.allow_greater = true
	_rows.focus_height.spin.allow_lesser = true
	_projection = _choice(graphics, "投影模式", ["透视", "正交"])
	_projection.item_selected.connect(func(index: int): _set_camera("projection", float(index)))
	_label(graphics, "中键旋转　Shift + 中键平移　滚轮缩放", true).tooltip_text = "小键盘 1 / 3 / 7 切换视图，5 切换投影，Home 重新取景。"
	var capture := _page(tabs, "动捕摄像头")
	_mode = _choice(capture, "动捕模式", ["VTuber · 上半身", "全身动捕"])
	_mode.tooltip_text = "VTuber 保持下肢站姿。全身模式需双髋、膝盖及脚入镜，位置为单目估算。"
	_mode.item_selected.connect(_set_mode)
	_pose_model_choice = _choice(capture, "姿态模型", ["Full · 均衡", "Lite · 省性能"])
	_pose_model_choice.tooltip_text = "Full 默认，Lite 适合性能较弱的电脑。模型随包提供，无需联网；点击应用后生效。"
	_recenter_button = _button(capture, "重置站姿", func(): recenter_requested.emit())
	_recenter_button.tooltip_text = "全身站直后重新建立站姿与接地基准。"
	_gesture_toggle = CheckButton.new()
	_gesture_toggle.text = "手势辅助"
	_gesture_toggle.tooltip_text = "稳定接近握拳、张开或伸食指时，平滑向预制手势收敛；不确定时保留实时手指，不改变手腕方向。"
	_gesture_toggle.toggled.connect(func(enabled: bool):
		hand_gesture_assistance = enabled
		save_settings()
		hand_gesture_assistance_changed.emit(enabled))
	capture.add_child(_gesture_toggle)
	var device_row := _row(capture, "设备编号")
	_device = SpinBox.new()
	_device.min_value = 0
	_device.max_value = 255
	_device.step = 1
	device_row.add_child(_device)
	_resolution = _choice(capture, "目标分辨率", ["640 × 480", "1280 × 720", "1920 × 1080"])
	_fps = _choice(capture, "目标帧率", ["15 FPS", "24 FPS", "30 FPS", "60 FPS"])
	_device.tooltip_text = "0 通常为默认摄像头。修改设备、分辨率或帧率后点击应用。"
	_button(capture, "应用捕捉设置", _apply_capture)
	_button(capture, "相机方位校正…", func(): calibration_requested.emit())
	_preview_toggle = CheckButton.new()
	_preview_toggle.text = "摄像头预览"
	_preview_toggle.tooltip_text = "与动捕共用摄像头；关闭预览不停止动捕，不会录制画面。"
	_preview_toggle.toggled.connect(func(enabled: bool): preview_requested.emit(enabled))
	capture.add_child(_preview_toggle)
	var footer := HBoxContainer.new()
	layout.add_child(footer)
	_status = _label(footer, "自动保存", true)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button(footer, "关闭", _close)
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.4
	_save_timer.timeout.connect(save_settings)
	add_child(_save_timer)


func _page(tabs: TabContainer, heading: String) -> VBoxContainer:
	var margin := MarginContainer.new()
	margin.name = heading
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 14)
	tabs.add_child(margin)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 14)
	scroll.add_child(content)
	return content


func _row(parent: Node, text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	parent.add_child(row)
	var label := _label(row, text)
	label.custom_minimum_size.x = 100
	return row


func _choice(parent: Node, label: String, options: Array) -> OptionButton:
	var row := _row(parent, label)
	var control := OptionButton.new()
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for option: String in options:
		control.add_item(option)
	row.add_child(control)
	return control


func _make_row(parent: Node, field: String, label: String, low: float, high: float, step: float, suffix: String) -> void:
	var row := _row(parent, label)
	var slider := HSlider.new()
	slider.min_value = low
	slider.max_value = high
	slider.step = step
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)
	var spin := SpinBox.new()
	spin.min_value = low
	spin.max_value = high
	spin.step = step
	spin.suffix = suffix
	spin.custom_minimum_size.x = 112
	row.add_child(spin)
	slider.value_changed.connect(func(value: float): _set_camera(field, value))
	spin.value_changed.connect(func(value: float): _set_camera(field, value))
	_rows[field] = {"slider": slider, "spin": spin}


func _label(parent: Node, text: String, muted := false) -> Label:
	var label := Label.new()
	label.text = text
	if muted:
		label.add_theme_color_override("font_color", STUDIO_THEME.get_color("muted", "Studio"))
		label.add_theme_font_size_override("font_size", 13)
	parent.add_child(label)
	return label


func _button(parent: Node, text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func _separator(parent: Node) -> void:
	parent.add_child(HSeparator.new())


static func _number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))


func popup_section(index: int) -> void:
	_tabs.current_tab = clampi(index, 0, 1)
	title = ["相机与抗锯齿", "捕捉设置"][_tabs.current_tab]
	popup_centered(Vector2i(750, 530))


func set_preview_state(enabled: bool) -> void:
	_preview_toggle.set_pressed_no_signal(enabled)
