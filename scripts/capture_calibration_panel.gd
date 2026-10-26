extends Window

const STUDIO_THEME := preload("res://scripts/ui_theme.tres")

class PlacementView extends Control:
	signal moved(value: Vector3)
	var side := false
	var capture_position := Vector3(0, 0, 1.5)

	func _ready() -> void:
		custom_minimum_size = Vector2(270, 230)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		size_flags_vertical = Control.SIZE_EXPAND_FILL
		clip_contents = true
		mouse_default_cursor_shape = Control.CURSOR_DRAG

	func _center() -> Vector2:
		return Vector2(60, size.y * 0.5 + 10) if side else Vector2(size.x * 0.5, size.y - 62)

	func _scale() -> float:
		return minf((size.x - 140) / 4.0, (size.y - 90) / 8.0) if side else minf((size.x - 120) / 8.0, (size.y - 100) / 4.0)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed or event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			move_camera(event.position)
			accept_event()

	func move_camera(point: Vector2) -> void:
		var offset := (point - _center()) / _scale()
		var value := capture_position
		if side:
			value.z = clampf(offset.x, 0.25, 4.0)
			value.y = clampf(-offset.y, -4.0, 4.0)
		else:
			value.x = clampf(-offset.x, -4.0, 4.0)
			value.z = clampf(-offset.y, 0.25, 4.0)
		moved.emit(value)

	func _draw() -> void:
		draw_style_box(_box(), Rect2(Vector2.ZERO, size))
		var font := get_theme_default_font()
		var center := _center()
		var scale := _scale()
		for line in range(-4, 5):
			draw_line(Vector2(center.x + line * scale, 32), Vector2(center.x + line * scale, size.y), get_theme_color("grid", "Studio"))
			draw_line(Vector2(0, center.y + line * scale), Vector2(size.x, center.y + line * scale), get_theme_color("grid", "Studio"))
		draw_string(font, Vector2(14, 25), "侧视图：调整前后、高差" if side else "俯视图：调整左右、前后", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, get_theme_color("text", "Studio"))
		if side:
			_cube(center)
		else:
			_cube(center)
			draw_line(center + Vector2(0, -18), center + Vector2(0, -42), get_theme_color("accent", "Studio"), 2, true)
			draw_line(center + Vector2(0, -42), center + Vector2(-7, -31), get_theme_color("accent", "Studio"), 3, true)
			draw_line(center + Vector2(0, -42), center + Vector2(7, -31), get_theme_color("accent", "Studio"), 3, true)
			draw_string(font, center + Vector2(-32, 38), "用户正前 ↑", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, get_theme_color("accent", "Studio"))
			draw_string(font, Vector2(12, size.y - 14), "用户左侧", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, get_theme_color("muted", "Studio"))
			draw_string(font, Vector2(size.x - 78, size.y - 14), "用户右侧", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, get_theme_color("muted", "Studio"))
		var camera := center + (Vector2(capture_position.z, -capture_position.y) if side else Vector2(-capture_position.x, -capture_position.z)) * scale
		draw_line(center, camera, get_theme_color("border", "Studio"), 1, true)
		var direction := (center - camera).normalized()
		var across := direction.orthogonal()
		var front := camera + direction * 22
		var a := front + across * 13
		var b := front - across * 13
		draw_polyline(PackedVector2Array([camera, a, b, camera]), get_theme_color("accent", "Studio"), 2, true)
		draw_polyline(PackedVector2Array([a, a + Vector2(5, -5), b + Vector2(5, -5), b]), get_theme_color("accent", "Studio"), 1, true)
		draw_polyline(PackedVector2Array([camera + across * 6, camera - direction * 8, camera - across * 6]), get_theme_color("accent", "Studio"), 2, true)
		draw_string(font, camera + Vector2(16, -12), "摄像机", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, get_theme_color("accent", "Studio"))

	func _cube(center: Vector2) -> void:
		var corners := PackedVector2Array([center + Vector2(-14, -10), center + Vector2(10, -10), center + Vector2(10, 14), center + Vector2(-14, 14)])
		var depth := Vector2(7, -7)
		draw_colored_polygon(corners, get_theme_color("field", "Studio"))
		for index in 4:
			draw_line(corners[index], corners[(index + 1) % 4], get_theme_color("muted", "Studio"), 1.5, true)
			draw_line(corners[index] + depth, corners[(index + 1) % 4] + depth, get_theme_color("muted", "Studio"), 1, true)
			draw_line(corners[index], corners[index] + depth, get_theme_color("muted", "Studio"), 1, true)

	func _box() -> StyleBoxFlat:
		var style := StyleBoxFlat.new()
		style.bg_color = get_theme_color("background", "Studio")
		style.set_corner_radius_all(6)
		return style


var calibration: CaptureCalibration
var _enabled: CheckButton
var _device_label: Label
var _status: Label
var _top: PlacementView
var _side: PlacementView
var _fields := {}
var _save_timer: Timer
var _views: GridContainer
var _fields_grid: GridContainer


func setup(value: CaptureCalibration) -> void:
	calibration = value
	title = "采集相机方位校正"
	size = Vector2i(850, 680)
	min_size = Vector2i(740, 640)
	transient = true
	visible = false
	close_requested.connect(_close)
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.theme = STUDIO_THEME
	panel.theme_type_variation = "StudioPanel"
	add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var layout := VBoxContainer.new()
	layout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_theme_constant_override("separation", 12)
	scroll.add_child(layout)
	_device_label = Label.new()
	layout.add_child(_device_label)
	_enabled = CheckButton.new()
	_enabled.text = "启用方位校正"
	_enabled.toggled.connect(func(on: bool): _change({"enabled": on}))
	layout.add_child(_enabled)
	var hint := Label.new()
	hint.text = "拖动摄像机到实际位置，方块代表用户。"
	hint.tooltip_text = "默认朝向胸口，箭头为用户正前方。校正在映射前生效，不改变展示镜头。"
	layout.add_child(hint)
	var views := GridContainer.new()
	_views = views
	views.columns = 2
	views.add_theme_constant_override("h_separation", 14)
	views.add_theme_constant_override("v_separation", 14)
	views.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(views)
	_top = PlacementView.new()
	_side = PlacementView.new()
	_side.side = true
	for view in [_top, _side]:
		views.add_child(view)
		view.moved.connect(func(p: Vector3): _change({"position": [p.x, p.y, p.z]}))
	var grid := GridContainer.new()
	_fields_grid = grid
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 16)
	layout.add_child(grid)
	for item in [["x", "左右 / m（＋左）", -4, 4, 0.05], ["yaw", "偏航微调 / °", -180, 180, 1], ["y", "高差 / m（胸口为0）", -4, 4, 0.05], ["pitch", "俯仰微调 / °", -90, 90, 1], ["z", "正前距离 / m", 0.25, 4, 0.05], ["roll", "画面倾斜 / °", -180, 180, 1]]:
		var label := Label.new()
		label.text = item[1]
		grid.add_child(label)
		var spin := SpinBox.new()
		spin.min_value = item[2]
		spin.max_value = item[3]
		spin.step = item[4]
		spin.custom_minimum_size.x = 105
		grid.add_child(spin)
		_fields[item[0]] = spin
		spin.value_changed.connect(func(number: float): _field_changed(item[0], number))
	_status = Label.new()
	layout.add_child(_status)
	var footer := HBoxContainer.new()
	layout.add_child(footer)
	var reset := Button.new()
	reset.text = "复位为正前方"
	reset.pressed.connect(func(): calibration.reset_device(); _queue_save())
	footer.add_child(reset)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)
	var close := Button.new()
	close.text = "关闭"
	close.pressed.connect(_close)
	footer.add_child(close)
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.4
	_save_timer.timeout.connect(_save)
	add_child(_save_timer)
	panel.resized.connect(func():
		_views.columns = 2 if panel.size.x >= 650 else 1
		_fields_grid.columns = 4 if panel.size.x >= 700 else 2)
	calibration.changed.connect(_refresh)
	_refresh()


func _field_changed(field: String, value: float) -> void:
	if field in ["x", "y", "z"]:
		var position: Array = calibration.profile.position.duplicate()
		position[["x", "y", "z"].find(field)] = value
		_change({"position": position})
	else:
		_change({field: value})


func _change(values: Dictionary) -> void:
	if calibration.update_profile(values):
		_queue_save()


func _queue_save() -> void:
	_save_timer.start()


func _save() -> void:
	if calibration.save_file() != OK:
		_status.text = "校正设置保存失败。"


func _refresh() -> void:
	_device_label.text = "摄像头 %d" % calibration.device
	_device_label.tooltip_text = "参数按摄像头编号保存。"
	_enabled.set_pressed_no_signal(calibration.profile.enabled)
	var p: Array = calibration.profile.position
	for field in ["x", "y", "z"]:
		_fields[field].set_value_no_signal(p[["x", "y", "z"].find(field)])
	for field in ["yaw", "pitch", "roll"]:
		_fields[field].set_value_no_signal(calibration.profile[field])
	for view in [_top, _side]:
		view.capture_position = Vector3(p[0], p[1], p[2])
		view.queue_redraw()
	var a := calibration.angles()
	_status.text = "偏航 %.1f°　俯仰 %.1f°　倾斜 %.1f°" % [a.y, a.x, a.z]
	_status.tooltip_text = "校正不补全遮挡关节；预览镜像不改变校正坐标。"


func _close() -> void:
	if not _save_timer.is_stopped():
		_save_timer.stop()
		_save()
	hide()


func _exit_tree() -> void:
	if _save_timer != null and not _save_timer.is_stopped():
		_save()
